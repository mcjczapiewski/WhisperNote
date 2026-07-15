import Foundation

enum TelemetryClientError: Error, Equatable, Sendable {
    case missingConfiguration
    case invalidToken
    case malformedAcknowledgement
}

enum TelemetryDeliveryPauseReason: String, Equatable, Sendable {
    case configuration
    case authentication
    case forbidden
    case endpointUnavailable = "endpoint_unavailable"
    case validation
}

enum TelemetryClientStatus: Equatable, Sendable {
    case idle
    case sent
    case queued(nextAttemptAt: TelemetryTimestamp?)
    case paused(TelemetryDeliveryPauseReason)
    case quarantined
}

struct TelemetryTransportConfiguration: Sendable, Equatable {
    let endpoint: URL
    let token: String

    init(endpoint: URL, token: String) throws {
        try TelemetryEndpointValidator.validate(endpoint)
        guard !token.isEmpty,
              token.rangeOfCharacter(from: .newlines) == nil else {
            throw TelemetryClientError.invalidToken
        }
        self.endpoint = endpoint
        self.token = token
    }
}

struct TelemetryHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol TelemetryHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse
}

protocol TelemetryBackoffRandom: Sendable {
    func nextUnitInterval() -> Double
}

struct SystemTelemetryBackoffRandom: TelemetryBackoffRandom {
    func nextUnitInterval() -> Double { Double.random(in: 0...1) }
}

final class TelemetryNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class URLSessionTelemetryHTTPTransport: NSObject, TelemetryHTTPTransport, @unchecked Sendable {
    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private let session: URLSession
    private let redirectDelegate: TelemetryNoRedirectDelegate

    override init() {
        let delegate = TelemetryNoRedirectDelegate()
        redirectDelegate = delegate
        session = URLSession(
            configuration: Self.ephemeralConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        super.init()
    }

    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TelemetryClientError.malformedAcknowledgement
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return TelemetryHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}

actor TelemetryClient {
    private enum SendResult {
        case progressed
        case retry(retryAfter: TimeInterval?)
        case paused(TelemetryDeliveryPauseReason)
        case quarantined
        case invalidated
    }

    private static let retryNominals: [TimeInterval] = [60, 300, 900, 3_600, 21_600, 86_400]
    private static let maximumRetryAfter: TimeInterval = 86_400

    private let queue: TelemetryQueue
    // Configuration is held only by this client. It is intentionally not part of the
    // durable queue envelope, so changing the local endpoint or token only affects a
    // later delivery attempt.
    private var configuration: TelemetryTransportConfiguration?
    private let transport: any TelemetryHTTPTransport
    private let clock: any TelemetryQueueClock
    private let random: any TelemetryBackoffRandom
    private let uuidGenerator: any TelemetryUUIDGenerating
    private let maximumBatchItems: Int
    private var isFlushing = false
    private var status: TelemetryClientStatus = .idle
    private var deliveryGeneration: UInt64 = 0

    init(
        queue: TelemetryQueue,
        configuration: TelemetryTransportConfiguration?,
        transport: any TelemetryHTTPTransport = URLSessionTelemetryHTTPTransport(),
        clock: any TelemetryQueueClock = SystemTelemetryQueueClock(),
        random: any TelemetryBackoffRandom = SystemTelemetryBackoffRandom(),
        uuidGenerator: any TelemetryUUIDGenerating = SystemTelemetryUUIDGenerator(),
        maximumBatchItems: Int = TelemetrySchema.maximumBatchItems
    ) {
        self.queue = queue
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
        self.random = random
        self.uuidGenerator = uuidGenerator
        self.maximumBatchItems = min(max(1, maximumBatchItems), TelemetrySchema.maximumBatchItems)
    }

    func currentStatus() -> TelemetryClientStatus { status }

    func updateConfiguration(_ configuration: TelemetryTransportConfiguration?) {
        guard self.configuration != configuration else { return }
        deliveryGeneration &+= 1
        self.configuration = configuration
        if configuration == nil {
            status = .paused(.configuration)
        } else if case .paused(.configuration) = status {
            status = .idle
        }
    }

    /// Invalidates an in-flight response without mutating the durable queue. Opt-out
    /// separately advances the queue generation, so a racing acknowledgement is stale.
    func invalidateDelivery() {
        deliveryGeneration &+= 1
        status = .idle
    }

    func flush() async -> TelemetryClientStatus {
        guard !isFlushing else { return statusForConcurrentFlush() }
        guard let configuration else {
            status = .paused(.configuration)
            return status
        }
        let generation = deliveryGeneration
        isFlushing = true
        defer { isFlushing = false }

        do {
            let snapshot = try await queue.snapshot()
            if let nextAttemptAt = snapshot.delivery.nextAttemptAt,
               let nextAttempt = telemetryDate(from: nextAttemptAt),
               nextAttempt > clock.now() {
                status = .queued(nextAttemptAt: nextAttemptAt)
                return status
            }

            var madeProgress = false
            var quarantinedItem = false
            while true {
                guard isCurrentDelivery(generation) else {
                    status = .idle
                    return status
                }
                guard let lease = try await queue.nextBatch(maxItems: maximumBatchItems) else {
                    status = quarantinedItem ? .quarantined : (madeProgress ? .sent : .idle)
                    return status
                }
                switch await send(lease, configuration: configuration, generation: generation) {
                case .progressed:
                    madeProgress = true
                case .quarantined:
                    madeProgress = true
                    quarantinedItem = true
                case .retry(let retryAfter):
                    return await scheduleRetry(for: lease, retryAfter: retryAfter, generation: generation)
                case .paused(let reason):
                    status = .paused(reason)
                    return status
                case .invalidated:
                    status = .idle
                    return status
                }
            }
        } catch {
            status = .paused(.validation)
            return status
        }
    }

    private func statusForConcurrentFlush() -> TelemetryClientStatus {
        switch status {
        case .idle, .sent: return .queued(nextAttemptAt: nil)
        default: return status
        }
    }

    private func send(
        _ lease: TelemetryDeliveryLease,
        configuration: TelemetryTransportConfiguration,
        generation: UInt64
    ) async -> SendResult {
        guard isCurrentDelivery(generation) else { return .invalidated }
        let request: URLRequest
        do {
            request = try makeRequest(for: lease.batch, configuration: configuration)
        } catch {
            return .paused(.configuration)
        }

        do {
            let response = try await transport.execute(request)
            guard isCurrentDelivery(generation) else { return .invalidated }
            return try await classify(response, lease: lease, generation: generation)
        } catch is CancellationError {
            return isCurrentDelivery(generation) ? .retry(retryAfter: nil) : .invalidated
        } catch {
            return isCurrentDelivery(generation) ? .retry(retryAfter: nil) : .invalidated
        }
    }

    private func classify(
        _ response: TelemetryHTTPResponse,
        lease: TelemetryDeliveryLease,
        generation: UInt64
    ) async throws -> SendResult {
        guard isCurrentDelivery(generation) else { return .invalidated }
        switch response.statusCode {
        case 200...299:
            let acknowledgement: TelemetryAcknowledgement
            do {
                acknowledgement = try JSONDecoder().decode(TelemetryAcknowledgement.self, from: response.body)
            } catch {
                return .retry(retryAfter: nil)
            }
            let leasedIDs = Set(lease.batch.items.map(\.eventID))
            let accepted = Set(acknowledgement.acceptedEventIDs)
            let rejected = Set(acknowledgement.rejected.map(\.eventID))
            guard accepted.isSubset(of: leasedIDs),
                  rejected.isSubset(of: leasedIDs),
                  accepted.isDisjoint(with: rejected) else {
                return .retry(retryAfter: nil)
            }
            guard !accepted.isEmpty || !rejected.isEmpty else { return .retry(retryAfter: nil) }
            if !accepted.isEmpty {
                guard isCurrentDelivery(generation) else { return .invalidated }
                guard try await queue.acknowledge(lease, acceptedEventIDs: accepted) else { return .progressed }
            }
            if !rejected.isEmpty {
                guard isCurrentDelivery(generation) else { return .invalidated }
                guard try await queue.quarantine(lease, eventIDs: rejected) else { return .progressed }
            }
            if let retryAfter = acknowledgement.retryAfterSeconds {
                return .retry(retryAfter: TimeInterval(retryAfter))
            }
            return rejected.isEmpty ? .progressed : .quarantined

        case 413:
            return await splitAndSend(lease, generation: generation)

        case 401:
            return .paused(.authentication)
        case 403:
            return .paused(.forbidden)
        case 404:
            return .paused(.endpointUnavailable)
        case 408, 429, 500...599:
            return .retry(retryAfter: retryAfter(from: response.headers))
        default:
            return .paused(.validation)
        }
    }

    private func splitAndSend(_ lease: TelemetryDeliveryLease, generation: UInt64) async -> SendResult {
        guard isCurrentDelivery(generation) else { return .invalidated }
        guard let configuration else { return .paused(.configuration) }
        let items = lease.batch.items
        guard items.count > 1 else {
            do {
                _ = try await queue.quarantine(lease, eventIDs: Set(items.map(\.eventID)))
                return .quarantined
            } catch {
                return .retry(retryAfter: nil)
            }
        }

        let splitIndex = items.count / 2
        let groups = [Array(items[..<splitIndex]), Array(items[splitIndex...])]
        var result: SendResult = .progressed
        for group in groups {
            do {
                let batch = try TelemetryBatch(
                    batchID: uuidGenerator.next(),
                    sentAt: lease.batch.sentAt,
                    items: group
                )
                let child = TelemetryDeliveryLease(generation: lease.generation, batch: batch)
                let childResult = await send(child, configuration: configuration, generation: generation)
                switch childResult {
                case .progressed, .quarantined:
                    if case .quarantined = childResult { result = .quarantined }
                case .retry, .paused, .invalidated:
                    return childResult
                }
            } catch {
                return .retry(retryAfter: nil)
            }
        }
        return result
    }

    private func scheduleRetry(
        for lease: TelemetryDeliveryLease,
        retryAfter: TimeInterval?,
        generation: UInt64
    ) async -> TelemetryClientStatus {
        do {
            guard isCurrentDelivery(generation) else {
                status = .idle
                return status
            }
            let snapshot = try await queue.snapshot()
            let failureNumber = snapshot.delivery.consecutiveFailures + 1
            let delay: TimeInterval
            if let retryAfter {
                delay = min(max(0, retryAfter), Self.maximumRetryAfter)
            } else {
                let nominal = Self.retryNominals[min(failureNumber - 1, Self.retryNominals.count - 1)]
                delay = nominal * min(max(0, random.nextUnitInterval()), 1)
            }
            let nextAttempt = clock.now().addingTimeInterval(delay)
            let updated = try await queue.updateDeliveryState(
                consecutiveFailures: failureNumber,
                nextAttemptAt: nextAttempt,
                generation: lease.generation
            )
            guard updated else {
                status = .idle
                return status
            }
            let timestamp = try telemetryTimestamp(for: nextAttempt)
            status = .queued(nextAttemptAt: timestamp)
            return status
        } catch {
            status = .paused(.validation)
            return status
        }
    }

    private func isCurrentDelivery(_ generation: UInt64) -> Bool {
        deliveryGeneration == generation && !Task.isCancelled
    }

    private func makeRequest(
        for batch: TelemetryBatch,
        configuration: TelemetryTransportConfiguration
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.token, forHTTPHeaderField: "X-WhisperNote-Token")
        request.httpBody = try TelemetryJSON.encodeBatch(batch)
        return request
    }

    private func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return min(seconds, Self.maximumRetryAfter)
    }
}

private enum TelemetryRejectionReason: String, Codable, CaseIterable, Sendable {
    case invalidItem = "invalid_item"
    case invalidFeedback = "invalid_feedback"
    case unsupportedContract = "unsupported_contract"
    case duplicate
    case tooLarge = "too_large"
    case validation
}

private struct TelemetryRejectedAcknowledgement: Decodable, Sendable {
    let eventID: UUID
    let reasonCode: TelemetryRejectionReason

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventID = "event_id"
        case reasonCode = "reason_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw TelemetryClientError.malformedAcknowledgement
        }
        eventID = try container.decode(UUID.self, forKey: .eventID)
        reasonCode = try container.decode(TelemetryRejectionReason.self, forKey: .reasonCode)
    }
}

private struct TelemetryAcknowledgement: Decodable, Sendable {
    let acceptedEventIDs: [UUID]
    let rejected: [TelemetryRejectedAcknowledgement]
    let retryAfterSeconds: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version"
        case acceptedEventIDs = "accepted_event_ids"
        case rejected
        case retryAfterSeconds = "retry_after_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed = Set(CodingKeys.allCases)
        guard Set(container.allKeys).isSubset(of: allowed),
              try container.decode(Int.self, forKey: .contractVersion) == TelemetrySchema.contractVersion else {
            throw TelemetryClientError.malformedAcknowledgement
        }
        acceptedEventIDs = try container.decode([UUID].self, forKey: .acceptedEventIDs)
        rejected = try container.decode([TelemetryRejectedAcknowledgement].self, forKey: .rejected)
        retryAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        guard Set(acceptedEventIDs).count == acceptedEventIDs.count,
              Set(rejected.map(\.eventID)).count == rejected.count,
              retryAfterSeconds.map({ (0...86_400).contains($0) }) ?? true else {
            throw TelemetryClientError.malformedAcknowledgement
        }
    }
}
