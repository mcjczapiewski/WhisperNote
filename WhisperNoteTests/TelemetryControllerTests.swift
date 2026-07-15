import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class TelemetryControllerTests: XCTestCase {
    func testDefaultOffButConfiguredByDefaultNeverSendsWithoutConsent() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        await controller.bootstrap()
        await controller.flush()

        XCTAssertFalse(controller.consent.enabled)
        // Delivery is configured out of the box via the baked-in default endpoint,
        // but with consent off and an empty queue nothing is ever sent.
        XCTAssertTrue(controller.isConfigured)
        XCTAssertEqual(controller.status, .inactive)
        XCTAssertTrue(context.acknowledgingTransport.requests.isEmpty)
    }

    func testEmptyStoredConfigurationResolvesToBakedInDefault() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        // No stored endpoint or token, yet delivery is configured from the default.
        XCTAssertNil(context.defaults.string(forKey: TelemetryController.endpointPreferenceKey))
        XCTAssertNil(try context.credentials.readToken())

        await controller.bootstrap()

        XCTAssertTrue(controller.isConfigured)
        XCTAssertFalse(controller.hasStoredCredential) // no user override present
    }

    func testFeedbackAfterOptOutStillDeliversViaDefault() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        await controller.enableTelemetry()
        await controller.optOutAndPurge()
        let optedOut = try await context.queue.snapshot()
        XCTAssertFalse(optedOut.consent.enabled)
        XCTAssertNil(optedOut.installID)

        let submitted = await controller.submitFeedback(category: .bug, message: "Still reachable after opt-out.")
        XCTAssertEqual(submitted, .sent, controller.feedbackStatusMessage ?? "No feedback status")
        let request = try XCTUnwrap(context.acknowledgingTransport.requests.first)
        let batch = try TelemetryJSON.decodeBatch(from: try XCTUnwrap(request.httpBody))
        guard case .feedback = try XCTUnwrap(batch.items.first) else {
            return XCTFail("Expected feedback payload")
        }
        // Opt-out cleared identity, so a later feedback still carries no install id.
        let snapshot = try await context.queue.snapshot()
        XCTAssertNil(snapshot.installID)
    }

    func testConfigurationConsentOptOutAndReenableUseFreshIdentity() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "local-test-token"
        )
        XCTAssertTrue(saved)
        await controller.enableTelemetry()
        let first = try await context.queue.snapshot()
        let firstIdentity = try XCTUnwrap(first.installID)
        XCTAssertTrue(first.consent.enabled)
        XCTAssertEqual(first.consent.version, TelemetryController.consentVersion)

        await controller.optOutAndPurge()
        let optedOut = try await context.queue.snapshot()
        XCTAssertFalse(optedOut.consent.enabled)
        XCTAssertNil(optedOut.installID)
        XCTAssertTrue(optedOut.items.isEmpty)

        await controller.enableTelemetry()
        let reenabled = try await context.queue.snapshot()
        XCTAssertNotEqual(try XCTUnwrap(reenabled.installID), firstIdentity)
    }

    func testFeedbackWhileOffOmitsInstallIdentityAndCanSend() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()
        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "local-test-token"
        )
        XCTAssertTrue(saved)

        let submitted = await controller.submitFeedback(category: .idea, message: "Please add a shortcut.")
        XCTAssertEqual(submitted, .sent, controller.feedbackStatusMessage ?? "No feedback status")

        let request = try XCTUnwrap(context.acknowledgingTransport.requests.first)
        let batch = try TelemetryJSON.decodeBatch(from: try XCTUnwrap(request.httpBody))
        guard case .feedback = try XCTUnwrap(batch.items.first) else {
            return XCTFail("Expected feedback payload")
        }
        let snapshot = try await context.queue.snapshot()
        XCTAssertFalse(snapshot.consent.enabled)
        XCTAssertNil(snapshot.installID)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testValidationStateAndPublicStatusNeverExposeEndpointOrToken() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()
        let endpoint = "http://private.example.test/path"
        let token = "do-not-expose-this-token"

        let saved = await controller.saveConfiguration(endpoint: endpoint, token: token)
        XCTAssertFalse(saved)
        XCTAssertFalse(controller.isConfigured)
        XCTAssertEqual(controller.status, .configurationRequired)
        XCTAssertFalse(controller.status.message.contains(endpoint))
        XCTAssertFalse(controller.status.message.contains(token))
        XCTAssertNil(context.defaults.string(forKey: TelemetryController.endpointPreferenceKey))
        XCTAssertNil(context.defaults.string(forKey: "telemetryWebhookToken"))
        let submitted = await controller.submitFeedback(category: .bug, message: "")
        XCTAssertEqual(submitted, .failed)
        XCTAssertFalse((controller.feedbackStatusMessage ?? "").contains(endpoint))
        XCTAssertFalse((controller.feedbackStatusMessage ?? "").contains(token))
    }

    func testForegroundUsesInjectedAppSupportQueueAndRecordsWeeklyOnlyWithConsent() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()
        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "local-test-token"
        )
        XCTAssertTrue(saved)

        await controller.applicationDidBecomeActive()
        XCTAssertTrue(context.acknowledgingTransport.requests.isEmpty)

        await controller.enableTelemetry()
        await controller.applicationDidBecomeActive()
        XCTAssertTrue(context.queue.storageDirectory.path.hasPrefix(context.root.path))
        XCTAssertFalse(context.queue.storageDirectory.path.contains("/Library/"))
        XCTAssertFalse(context.acknowledgingTransport.requests.isEmpty)
    }

    func testTokenUsesCredentialStoreNotUserDefaultsAndClearDeletesIt() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "credential-only-token"
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(try context.credentials.readToken(), "credential-only-token")
        XCTAssertNil(context.defaults.string(forKey: "telemetryWebhookToken"))
        XCTAssertTrue(controller.hasStoredCredential)

        await controller.clearConfiguration()
        XCTAssertNil(try context.credentials.readToken())
        XCTAssertFalse(controller.hasStoredCredential)
    }

    func testOptOutInvalidatesSuspendedDeliveryWithoutRestoringQueueOrIdentity() async throws {
        let transport = SuspendedControllerTransport()
        let context = ControllerTestContext(transport: transport)
        let controller = context.controller()
        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "local-test-token"
        )
        XCTAssertTrue(saved)
        let submitTask = Task { await controller.submitFeedback(category: .bug, message: "In-flight feedback") }
        let started = await eventually { transport.requestCount == 1 }
        XCTAssertTrue(started)

        await controller.optOutAndPurge()
        transport.resumeAcceptedResponse()
        let submission = await submitTask.value
        XCTAssertEqual(submission, .failed)

        let snapshot = try await context.queue.snapshot()
        XCTAssertFalse(snapshot.consent.enabled)
        XCTAssertNil(snapshot.installID)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(controller.status, .inactive)
    }

    func testConfigurationChangeInvalidatesSuspendedAcknowledgement() async throws {
        let transport = SuspendedControllerTransport()
        let context = ControllerTestContext(transport: transport)
        let controller = context.controller()
        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/first",
            token: "first-token"
        )
        XCTAssertTrue(saved)
        let submitTask = Task { await controller.submitFeedback(category: .idea, message: "Do not acknowledge with old config") }
        let started = await eventually { transport.requestCount == 1 }
        XCTAssertTrue(started)

        let replaced = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/second",
            token: "second-token"
        )
        XCTAssertTrue(replaced)
        transport.resumeAcceptedResponse()
        _ = await submitTask.value

        let snapshot = try await context.queue.snapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(try context.credentials.readToken(), "second-token")
    }

    func testScheduledRetryIsInjectableAndCancelledByConfigurationChange() async throws {
        let scheduler = ManualRetryScheduler()
        let transport = SequencedControllerTransport(results: [.failure, .accepted])
        let context = ControllerTestContext(transport: transport, retryScheduler: scheduler)
        let controller = context.controller()
        let saved = await controller.saveConfiguration(
            endpoint: "https://telemetry.example.test/webhook",
            token: "local-test-token"
        )
        XCTAssertTrue(saved)

        let submission = await controller.submitFeedback(category: .idea, message: "Retry this")
        XCTAssertEqual(submission, .queued)
        let scheduled = await eventually { scheduler.waitCount == 1 }
        XCTAssertTrue(scheduled)
        await controller.clearConfiguration()
        scheduler.fireNext()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testHealthSignalsRequireConsentAndMilestonesAreDeduplicated() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()

        await controller.recordHealthSignal(
            stage: .summary, outcome: .success, startedAt: Date(), failure: nil
        )
        let beforeConsent = try await context.queue.snapshot()
        XCTAssertTrue(beforeConsent.items.isEmpty)

        await controller.enableTelemetry()
        await controller.recordHealthSignal(
            stage: .summary, outcome: .success, startedAt: Date(), failure: nil
        )
        await controller.recordHealthSignal(
            stage: .summary, outcome: .success, startedAt: Date(), failure: nil
        )

        let items = try await context.queue.snapshot().items
        let events = items.compactMap { if case .health(let event) = $0 { return event }; return nil }
        XCTAssertEqual(events.filter { $0.eventName == .stageOutcome }.count, 2)
        XCTAssertEqual(events.filter { $0.eventName == .firstSummaryCompleted }.count, 1)
    }

    func testQueuedHealthPayloadExcludesSensitiveWorkflowCanaries() async throws {
        let context = ControllerTestContext()
        let controller = context.controller()
        await controller.enableTelemetry()
        await controller.recordHealthSignal(
            stage: .transcription, outcome: .failure, startedAt: Date(), failure: .rateLimited
        )
        let snapshot = try await context.queue.snapshot()
        let batch = try TelemetryBatch(
            batchID: UUID(), sentAt: try TelemetryTimestamp(rawValue: "2026-07-15T12:00:00Z"), items: snapshot.items
        )
        let canaries = [
            "private recording name", "private transcript body", "/tmp/private-audio.m4a",
            "elevenlabs-api-key", "webhook-token"
        ]
        XCTAssertEqual(
            try TelemetryLeakScanner.findings(in: TelemetryJSON.encodeBatch(batch), canaries: canaries),
            []
        )
    }
}

@MainActor
private final class ControllerTestContext {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryControllerTests-\(UUID())")
    let defaults: UserDefaults
    let defaultsSuite: String
    let acknowledgingTransport: ControllerAcknowledgingTransport
    let transport: any TelemetryHTTPTransport
    let credentials = ControllerCredentialStore()
    let clock = ControllerMutableClock(date: Date())
    let retryScheduler: any TelemetryRetryScheduling
    let queue: TelemetryQueue
    let client: TelemetryClient

    init(
        transport: (any TelemetryHTTPTransport)? = nil,
        retryScheduler: any TelemetryRetryScheduling = SystemTelemetryRetryScheduler()
    ) {
        let suite = "TelemetryControllerTests-\(UUID())"
        defaultsSuite = suite
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let selectedTransport = transport ?? ControllerAcknowledgingTransport()
        self.transport = selectedTransport
        acknowledgingTransport = selectedTransport as? ControllerAcknowledgingTransport ?? ControllerAcknowledgingTransport()
        self.retryScheduler = retryScheduler
        let queue = TelemetryQueue(applicationSupportRoot: root, clock: clock)
        self.queue = queue
        client = TelemetryClient(
            queue: queue,
            configuration: nil,
            transport: selectedTransport,
            clock: clock,
            random: ControllerFixedRandom(1)
        )
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    func controller() -> TelemetryController {
        TelemetryController(
            queue: queue,
            client: client,
            defaults: defaults,
            credentialStore: credentials,
            now: { self.clock.now() },
            runtimeContext: {
                try TelemetryRuntimeContext(appVersion: "1.4.0", appBuild: "1", osVersion: "14.2")
            },
            retryScheduler: retryScheduler
        )
    }
}

private final class ControllerCredentialStore: TelemetryCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func readToken() throws -> String? { lock.withLock { token } }
    func saveToken(_ token: String) throws { lock.withLock { self.token = token } }
    func deleteToken() throws { lock.withLock { token = nil } }
}

private final class ControllerMutableClock: TelemetryQueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
}

private struct ControllerFixedRandom: TelemetryBackoffRandom {
    let value: Double
    init(_ value: Double) { self.value = value }
    func nextUnitInterval() -> Double { value }
}

private final class SuspendedControllerTransport: TelemetryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<TelemetryHTTPResponse, Error>?

    var requestCount: Int { lock.withLock { requests.count } }

    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        lock.withLock { requests.append(request) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func resumeAcceptedResponse() {
        let state: (CheckedContinuation<TelemetryHTTPResponse, Error>?, URLRequest?) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.requests.last)
        }
        let batch = try? state.1.flatMap { try TelemetryJSON.decodeBatch(from: $0.httpBody ?? Data()) }
        state.0?.resume(returning: ControllerAcknowledgingTransport.acceptance(for: batch))
    }
}

private final class SequencedControllerTransport: TelemetryHTTPTransport, @unchecked Sendable {
    enum Result { case failure, accepted }

    private let lock = NSLock()
    private var results: [Result]
    private var requests: [URLRequest] = []

    init(results: [Result]) { self.results = results }
    var requestCount: Int { lock.withLock { requests.count } }

    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        let result = lock.withLock { () -> Result in
            requests.append(request)
            return results.isEmpty ? .failure : results.removeFirst()
        }
        switch result {
        case .failure: throw URLError(.networkConnectionLost)
        case .accepted:
            let batch = try TelemetryJSON.decodeBatch(from: request.httpBody ?? Data())
            return ControllerAcknowledgingTransport.acceptance(for: batch)
        }
    }
}

private final class ManualRetryScheduler: TelemetryRetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var waitCount: Int { lock.withLock { continuations.count } }

    func sleep(until date: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func fireNext() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }
}

private func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private final class ControllerAcknowledgingTransport: TelemetryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func execute(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        lock.withLock { storedRequests.append(request) }
        let batch = try TelemetryJSON.decodeBatch(from: request.httpBody ?? Data())
        return Self.acceptance(for: batch)
    }

    static func acceptance(for batch: TelemetryBatch? = nil) -> TelemetryHTTPResponse {
        let acknowledgement: [String: Any] = [
            "contract_version": 1,
            "accepted_event_ids": batch?.items.map { $0.eventID.uuidString } ?? [],
            "rejected": []
        ]
        return TelemetryHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
        )
    }

    static func acceptance() -> TelemetryHTTPResponse {
        TelemetryHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: [
                "contract_version": 1,
                "accepted_event_ids": [],
                "rejected": []
            ], options: [.sortedKeys])
        )
    }
}
