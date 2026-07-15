import Foundation
import XCTest
@testable import WhisperNote

final class TelemetryClientTests: XCTestCase {
    func testPostsExactBatchHeadersWithoutLeakingEndpointOrTokenIntoBodyOrQueue() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(1), message: "Feedback")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport()
        transport.steps = [.response(acknowledgement(accepted: [feedback.eventID]))]
        let endpoint = URL(string: "https://telemetry.example.test/webhook")!
        let client = context.client(transport: transport, endpoint: endpoint, token: "canary-token")

        let status = await client.flush()
        XCTAssertEqual(status, .sent)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WhisperNote-Token"), "canary-token")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains(endpoint.absoluteString))
        XCTAssertFalse(text.contains("canary-token"))
        XCTAssertEqual(try TelemetryJSON.decodeBatch(from: body).items.map(\.eventID), [feedback.eventID])
        let queueBytes = try Data(contentsOf: context.queue.queueFileURL)
        XCTAssertFalse(String(decoding: queueBytes, as: UTF8.self).contains("canary-token"))
    }

    func testEphemeralTransportDisablesCookiesCacheCredentialsAndRedirects() {
        let configuration = URLSessionTelemetryHTTPTransport.ephemeralConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        let delegate = TelemetryNoRedirectDelegate()
        let response = HTTPURLResponse(
            url: URL(string: "https://telemetry.example.test/redirect")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        var redirectedRequest: URLRequest?
        delegate.urlSession(
            .shared,
            task: URLSession.shared.dataTask(with: URL(string: "https://telemetry.example.test")!),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: response.url!),
            completionHandler: { redirectedRequest = $0 }
        )
        XCTAssertNil(redirectedRequest)
    }

    func testPartialAcknowledgementNeverRemovesUnleasedQueuedItem() async throws {
        let context = ClientTestContext()
        let first = context.feedback(id: context.uuid(10), message: "first")
        let second = context.feedback(id: context.uuid(11), message: "second")
        let unleased = context.feedback(id: context.uuid(12), message: "third")
        try await context.queue.enqueueFeedback(first)
        try await context.queue.enqueueFeedback(second)
        try await context.queue.enqueueFeedback(unleased)
        let transport = StubHTTPTransport()
        transport.steps = [
            .response(acknowledgement(accepted: [first.eventID], rejected: [second.eventID])),
            .failure
        ]
        let client = context.client(transport: transport, maximumBatchItems: 2)

        _ = await client.flush()

        let snapshot = try await context.queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.eventID), [unleased.eventID])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testUnleasedAndDuplicateAcknowledgementIDsRetainTheEntireLeaseForRetry() async throws {
        let cases: [(String, TelemetryHTTPResponse)] = [
            (
                "unleased",
                acknowledgement(accepted: [
                    UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-000000000001")!
                ])
            ),
            (
                "duplicate",
                acknowledgement(accepted: [
                    UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-000000000001")!,
                    UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-000000000001")!
                ])
            )
        ]

        for (_, response) in cases {
            let context = ClientTestContext()
            let feedback = context.feedback(id: context.uuid(15), message: "strict acknowledgement")
            try await context.queue.enqueueFeedback(feedback)
            let transport = StubHTTPTransport()
            transport.steps = [.response(response)]
            let client = context.client(transport: transport)

            guard case .queued = await client.flush() else { return XCTFail("Expected retry") }
            let snapshot = try await context.queue.snapshot()
            XCTAssertEqual(snapshot.items.map(\.eventID), [feedback.eventID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.queue.storageDirectory.appendingPathComponent(
                "item.quarantine.\(feedback.eventID.uuidString).json"
            ).path))
        }
    }

    func testAmbiguousFailureRetriesStableEventIDs() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(20), message: "retry")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport()
        transport.steps = [.failure, .response(acknowledgement(accepted: [feedback.eventID]))]
        let client = context.client(transport: transport, random: FixedRandom(0.5))

        let firstStatus = await client.flush()
        guard case .queued(let retryAt) = firstStatus else { return XCTFail("Expected retry") }
        XCTAssertEqual(retryAt, try telemetryTimestamp(for: context.clock.date.addingTimeInterval(30)))
        context.clock.date = context.clock.date.addingTimeInterval(31)
        let secondStatus = await client.flush()
        XCTAssertEqual(secondStatus, .sent)

        let firstBatch = try TelemetryJSON.decodeBatch(from: try XCTUnwrap(transport.requests.first?.httpBody))
        let secondBatch = try TelemetryJSON.decodeBatch(from: try XCTUnwrap(transport.requests.last?.httpBody))
        XCTAssertEqual(firstBatch.items.map(\.eventID), [feedback.eventID])
        XCTAssertEqual(secondBatch.items.map(\.eventID), [feedback.eventID])
    }

    func testOnlyOneFlushUsesTheTransportAtATime() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(30), message: "single flight")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport(delayNanoseconds: 100_000_000)
        transport.steps = [.response(acknowledgement(accepted: [feedback.eventID]))]
        let client = context.client(transport: transport)

        async let first = client.flush()
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second = client.flush()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRetryBackoffUsesFullJitterThenCapsRetryAfter() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(40), message: "backoff")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport()
        transport.steps = [
            .failure,
            .response(TelemetryHTTPResponse(statusCode: 429, headers: ["Retry-After": "99999"], body: Data()))
        ]
        let client = context.client(transport: transport, random: FixedRandom(0.5))

        _ = await client.flush()
        var snapshot = try await context.queue.snapshot()
        XCTAssertEqual(snapshot.delivery.nextAttemptAt, try telemetryTimestamp(for: context.clock.date.addingTimeInterval(30)))
        context.clock.date = context.clock.date.addingTimeInterval(31)
        _ = await client.flush()
        snapshot = try await context.queue.snapshot()
        XCTAssertEqual(snapshot.delivery.nextAttemptAt, try telemetryTimestamp(for: context.clock.date.addingTimeInterval(86_400)))
    }

    func testRetryableHTTPStatusesRetainQueueAndScheduleRetry() async throws {
        for statusCode in [408, 500, 503] {
            let context = ClientTestContext()
            let feedback = context.feedback(id: context.uuid(80 + statusCode), message: "retry \(statusCode)")
            try await context.queue.enqueueFeedback(feedback)
            let transport = StubHTTPTransport()
            transport.steps = [.response(TelemetryHTTPResponse(statusCode: statusCode, headers: [:], body: Data()))]
            let client = context.client(transport: transport, random: FixedRandom(0.5))

            guard case .queued(let retryAt) = await client.flush() else {
                return XCTFail("Expected retry for \(statusCode)")
            }
            XCTAssertEqual(retryAt, try telemetryTimestamp(for: context.clock.date.addingTimeInterval(30)))
            let snapshot = try await context.queue.snapshot()
            XCTAssertEqual(snapshot.items.map(\.eventID), [feedback.eventID])
        }
    }

    func testPermanentHTTPStatusesPauseAndRetainQueue() async throws {
        let cases: [(Int, TelemetryDeliveryPauseReason)] = [(403, .forbidden), (404, .endpointUnavailable)]
        for (statusCode, expectedStatus) in cases {
            let context = ClientTestContext()
            let feedback = context.feedback(id: context.uuid(90 + statusCode), message: "pause \(statusCode)")
            try await context.queue.enqueueFeedback(feedback)
            let transport = StubHTTPTransport()
            transport.steps = [.response(TelemetryHTTPResponse(statusCode: statusCode, headers: [:], body: Data()))]
            let client = context.client(transport: transport)

            let status = await client.flush()
            XCTAssertEqual(status, .paused(expectedStatus))
            let snapshot = try await context.queue.snapshot()
            XCTAssertEqual(snapshot.items.map(\.eventID), [feedback.eventID])
        }
    }

    func testPermanentStatusPausesAndRetainsItems() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(50), message: "retain")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport()
        transport.steps = [.response(TelemetryHTTPResponse(statusCode: 401, headers: [:], body: Data()))]
        let client = context.client(transport: transport)

        let status = await client.flush()
        XCTAssertEqual(status, .paused(.authentication))
        let snapshot = try await context.queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.eventID), [feedback.eventID])
    }

    func test413SplitsThenQuarantinesIrreducibleItem() async throws {
        let context = ClientTestContext()
        let first = context.feedback(id: context.uuid(60), message: "one")
        let second = context.feedback(id: context.uuid(61), message: "two")
        let third = context.feedback(id: context.uuid(62), message: "three")
        try await context.queue.enqueueFeedback(first)
        try await context.queue.enqueueFeedback(second)
        try await context.queue.enqueueFeedback(third)
        let transport = StubHTTPTransport()
        transport.steps = [
            .response(TelemetryHTTPResponse(statusCode: 413, headers: [:], body: Data())),
            .response(acknowledgement(accepted: [first.eventID])),
            .response(TelemetryHTTPResponse(statusCode: 413, headers: [:], body: Data())),
            .response(acknowledgement(accepted: [second.eventID])),
            .response(TelemetryHTTPResponse(statusCode: 413, headers: [:], body: Data()))
        ]
        let client = context.client(transport: transport)

        let status = await client.flush()
        XCTAssertEqual(status, .quarantined)
        let snapshot = try await context.queue.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
        let quarantine = context.queue.storageDirectory.appendingPathComponent(
            "item.quarantine.\(third.eventID.uuidString).json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try TelemetryJSON.decodeItem(from: Data(contentsOf: quarantine)).eventID, third.eventID)
    }

    func testMalformedAcknowledgementRetriesAndInvalidConfigurationNeverCreatesLiveRequest() async throws {
        let context = ClientTestContext()
        let feedback = context.feedback(id: context.uuid(70), message: "strict")
        try await context.queue.enqueueFeedback(feedback)
        let transport = StubHTTPTransport()
        transport.steps = [.response(TelemetryHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"contract_version":1,"accepted_event_ids":[],"rejected":[],"extra":true}"#.utf8)
        ))]
        let configured = context.client(transport: transport)

        guard case .queued = await configured.flush() else { return XCTFail("Expected retry") }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertThrowsError(try TelemetryTransportConfiguration(
            endpoint: URL(string: "http://telemetry.example.test")!,
            token: "token"
        ))
        let offlineTransport = StubHTTPTransport()
        let unconfigured = TelemetryClient(
            queue: context.queue,
            configuration: nil,
            transport: offlineTransport,
            clock: context.clock,
            random: FixedRandom(0)
        )
        let unconfiguredStatus = await unconfigured.flush()
        XCTAssertEqual(unconfiguredStatus, .paused(.configuration))
        XCTAssertTrue(offlineTransport.requests.isEmpty)
    }
}

private final class ClientTestContext: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryClientTests-\(UUID())")
    let clock = ClientMutableClock(date: Date(timeIntervalSince1970: 1_752_573_600))
    let ids = ClientUUIDGenerator()
    lazy var queue = TelemetryQueue(
        applicationSupportRoot: root,
        clock: clock,
        uuidGenerator: ids
    )

    func client(
        transport: any TelemetryHTTPTransport,
        endpoint: URL = URL(string: "https://telemetry.example.test/webhook")!,
        token: String = "test-token",
        random: any TelemetryBackoffRandom = FixedRandom(0),
        maximumBatchItems: Int = TelemetrySchema.maximumBatchItems
    ) -> TelemetryClient {
        TelemetryClient(
            queue: queue,
            configuration: try! TelemetryTransportConfiguration(endpoint: endpoint, token: token),
            transport: transport,
            clock: clock,
            random: random,
            uuidGenerator: ids,
            maximumBatchItems: maximumBatchItems
        )
    }

    func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "CCCCCCCC-CCCC-CCCC-CCCC-%012d", value))!
    }

    func feedback(id: UUID, message: String) -> TelemetryFeedback {
        try! TelemetryFeedback(
            eventID: id,
            occurredAt: telemetryTimestamp(for: clock.date),
            runtime: try! TelemetryRuntimeContext(appVersion: "1.4.6", appBuild: "1", osVersion: "14.2"),
            category: .idea,
            message: message
        )
    }
}

private final class ClientMutableClock: TelemetryQueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(date: Date) { value = date }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func now() -> Date { date }
}

private final class ClientUUIDGenerator: TelemetryUUIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 1
    func next() -> UUID {
        lock.withLock {
            defer { index += 1 }
            return UUID(uuidString: String(format: "DDDDDDDD-DDDD-DDDD-DDDD-%012d", index))!
        }
    }
}

private struct FixedRandom: TelemetryBackoffRandom {
    let value: Double
    init(_ value: Double) { self.value = value }
    func nextUnitInterval() -> Double { value }
}

private enum StubStep {
    case response(TelemetryHTTPResponse)
    case failure
}

private final class StubHTTPTransport: TelemetryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSteps: [StubStep] = []
    private var storedRequests: [URLRequest] = []
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) { self.delayNanoseconds = delayNanoseconds }

    var steps: [StubStep] {
        get { lock.withLock { storedSteps } }
        set { lock.withLock { storedSteps = newValue } }
    }
    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        let step = lock.withLock { () -> StubStep in
            storedRequests.append(request)
            return storedSteps.isEmpty ? .failure : storedSteps.removeFirst()
        }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        switch step {
        case .response(let response): return response
        case .failure: throw URLError(.networkConnectionLost)
        }
    }
}

private func acknowledgement(
    accepted: [UUID],
    rejected: [UUID] = [],
    retryAfter: Int? = nil
) -> TelemetryHTTPResponse {
    var object: [String: Any] = [
        "contract_version": 1,
        "accepted_event_ids": accepted.map(\.uuidString),
        "rejected": rejected.map { ["event_id": $0.uuidString, "reason_code": "invalid_item"] }
    ]
    if let retryAfter { object["retry_after_seconds"] = retryAfter }
    return TelemetryHTTPResponse(
        statusCode: 200,
        headers: [:],
        body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}
