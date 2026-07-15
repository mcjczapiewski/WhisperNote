import Foundation
import XCTest
@testable import WhisperNote

final class TelemetryEventTests: XCTestCase {
    private let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let installID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let batchID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let feedbackID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    func testByteExactHealthFeedbackAndBatchFixtures() throws {
        let health = try stageEvent()
        let feedback = try feedback(eventID: feedbackID, message: "  Make the button clearer.  ")

        XCTAssertEqual(
            String(decoding: try TelemetryJSON.encodeItem(.health(health)), as: UTF8.self),
            #"{"app_build":"42","app_version":"1.4.6","duration_bucket":"5_15s","event_id":"11111111-1111-1111-1111-111111111111","event_name":"stage_outcome","failure_bucket":"network","install_id":"22222222-2222-2222-2222-222222222222","kind":"health_event","occurred_at":"2026-07-15T09:30:00Z","os_version":"14.2","outcome":"failure","schema_version":1,"stage":"transcription"}"#
        )
        XCTAssertEqual(
            String(decoding: try TelemetryJSON.encodeItem(.feedback(feedback)), as: UTF8.self),
            #"{"app_build":"42","app_version":"1.4.6","category":"usability","event_id":"44444444-4444-4444-4444-444444444444","kind":"feedback","message":"Make the button clearer.","occurred_at":"2026-07-15T09:30:00Z","os_version":"14.2","schema_version":1}"#
        )

        let batch = try TelemetryBatch(
            batchID: batchID,
            sentAt: timestamp(),
            items: [.health(health), .feedback(feedback)]
        )
        let expected = #"{"batch_id":"33333333-3333-3333-3333-333333333333","contract_version":1,"items":[{"app_build":"42","app_version":"1.4.6","duration_bucket":"5_15s","event_id":"11111111-1111-1111-1111-111111111111","event_name":"stage_outcome","failure_bucket":"network","install_id":"22222222-2222-2222-2222-222222222222","kind":"health_event","occurred_at":"2026-07-15T09:30:00Z","os_version":"14.2","outcome":"failure","schema_version":1,"stage":"transcription"},{"app_build":"42","app_version":"1.4.6","category":"usability","event_id":"44444444-4444-4444-4444-444444444444","kind":"feedback","message":"Make the button clearer.","occurred_at":"2026-07-15T09:30:00Z","os_version":"14.2","schema_version":1}],"sent_at":"2026-07-15T09:30:00Z"}"#
        let encoded = try TelemetryJSON.encodeBatch(batch)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        XCTAssertEqual(try TelemetryJSON.decodeBatch(from: encoded), batch)
    }

    func testEveryClosedEnumValueRoundTrips() throws {
        try assertRoundTrips(TelemetryHealthEventName.allCases)
        try assertRoundTrips(TelemetryStage.allCases)
        try assertRoundTrips(TelemetryOutcome.allCases)
        try assertRoundTrips(TelemetryDurationBucket.allCases)
        try assertRoundTrips(TelemetryFailureBucket.allCases)
        try assertRoundTrips(TelemetryFeedbackCategory.allCases)
        try assertRoundTrips(TelemetryDiagnosticCode.allCases)
    }

    func testMilestoneWeeklyAndStageShapesAreStrict() throws {
        for name in [
            TelemetryHealthEventName.firstRecordingCompleted,
            .firstTranscriptCompleted,
            .firstSummaryCompleted,
        ] {
            XCTAssertNoThrow(try health(eventName: name))
            XCTAssertThrowsError(try health(eventName: name, duration: .unknown))
        }

        XCTAssertNoThrow(try health(eventName: .weeklyActive, weekStart: TelemetryWeekStart(rawValue: "2026-07-13")))
        XCTAssertThrowsError(try health(eventName: .weeklyActive))
        XCTAssertThrowsError(try health(eventName: .weeklyActive, weekStart: TelemetryWeekStart(rawValue: "2026-07-14")))

        XCTAssertNoThrow(try health(eventName: .stageOutcome, stage: .summary, outcome: .success, duration: .oneToFiveSeconds))
        XCTAssertNoThrow(try health(eventName: .stageOutcome, stage: .recordingFinalize, outcome: .cancelled, failure: .cancelled))
        XCTAssertThrowsError(try health(eventName: .stageOutcome, stage: .summary, outcome: .success, failure: .service))
        XCTAssertThrowsError(try health(eventName: .stageOutcome, stage: .summary, outcome: .failure))
        XCTAssertThrowsError(try health(eventName: .stageOutcome, stage: .summary, outcome: .failure, failure: .cancelled))
        XCTAssertThrowsError(try health(eventName: .stageOutcome, outcome: .failure, failure: .unknown))
    }

    func testTimestampAndVersionFieldsRejectNonCanonicalOrOverSpecificValues() throws {
        XCTAssertNoThrow(try TelemetryTimestamp(rawValue: "2026-07-15T09:30:00.123Z"))
        XCTAssertThrowsError(try TelemetryTimestamp(rawValue: "2026-07-15T09:30:00+02:00"))
        XCTAssertThrowsError(try TelemetryTimestamp(rawValue: "not-a-date"))
        XCTAssertNoThrow(try TelemetryRuntimeContext(appVersion: "1.4.6-beta.1+7", appBuild: "42.1", osVersion: "14.2"))
        XCTAssertThrowsError(try TelemetryRuntimeContext(appVersion: "1.4", appBuild: "42", osVersion: "14.2"))
        XCTAssertThrowsError(try TelemetryRuntimeContext(appVersion: "1.4.6", appBuild: "build-42", osVersion: "14.2"))
        XCTAssertThrowsError(try TelemetryRuntimeContext(appVersion: "1.4.6", appBuild: "42", osVersion: "14.2.1"))
    }

    func testFeedbackTrimsAndEnforcesOneThroughTwoThousandCharacters() throws {
        XCTAssertEqual(try feedback(message: "  hello\n").message, "hello")
        XCTAssertThrowsError(try feedback(message: " \n "))
        XCTAssertNoThrow(try feedback(message: String(repeating: "é", count: 2_000)))
        XCTAssertThrowsError(try feedback(message: String(repeating: "é", count: 2_001)))
    }

    func testHealthRequiresInstallIdentityAndFeedbackCannotCarryIt() throws {
        let healthJSON = String(decoding: try TelemetryJSON.encodeItem(.health(stageEvent())), as: UTF8.self)
        let feedbackJSON = String(decoding: try TelemetryJSON.encodeItem(.feedback(feedback())), as: UTF8.self)
        XCTAssertTrue(healthJSON.contains(#""install_id""#))
        XCTAssertFalse(feedbackJSON.contains("install_id"))

        let healthWithoutID = healthJSON.replacingOccurrences(
            of: ",\"install_id\":\"22222222-2222-2222-2222-222222222222\"",
            with: ""
        )
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: Data(healthWithoutID.utf8)))

        let feedbackWithID = feedbackJSON.dropLast() + ",\"install_id\":\"22222222-2222-2222-2222-222222222222\"}"
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: Data(feedbackWithID.utf8)))
    }

    func testStrictDecoderRejectsUnknownKeysEnumsKindsAndSchemaVersions() throws {
        let health = String(decoding: try TelemetryJSON.encodeItem(.health(stageEvent())), as: UTF8.self)
        let extra = health.dropLast() + ",\"artifact_id\":\"forbidden\"}"
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: Data(extra.utf8)))
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: replacing(health, "\"network\"", "\"raw_error\"")))
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: replacing(health, "\"health_event\"", "\"analytics\"")))
        XCTAssertThrowsError(try TelemetryJSON.decodeItem(from: replacing(health, "\"schema_version\":1", "\"schema_version\":2")))

        let batch = try TelemetryJSON.encodeBatch(
            TelemetryBatch(batchID: batchID, sentAt: timestamp(), items: [.health(stageEvent())])
        )
        let batchText = String(decoding: batch, as: UTF8.self)
        let extraBatch = batchText.dropLast() + ",\"metadata\":{}}"
        XCTAssertThrowsError(try TelemetryJSON.decodeBatch(from: Data(extraBatch.utf8)))
        XCTAssertThrowsError(try TelemetryJSON.decodeBatch(from: replacing(batchText, "\"contract_version\":1", "\"contract_version\":9")))
    }

    func testBatchCardinalityAndEncodedSizeLimits() throws {
        XCTAssertThrowsError(try TelemetryBatch(batchID: batchID, sentAt: timestamp(), items: []))
        let twenty = try (0..<20).map { index in
            TelemetryItem.feedback(try feedback(eventID: indexedUUID(index), message: "x"))
        }
        let twentyOne = twenty + [.feedback(try feedback(eventID: indexedUUID(20), message: "x"))]
        XCTAssertNoThrow(try TelemetryBatch(batchID: batchID, sentAt: timestamp(), items: twenty))
        XCTAssertThrowsError(try TelemetryBatch(batchID: batchID, sentAt: timestamp(), items: twentyOne)) { error in
            XCTAssertEqual(error as? TelemetryValidationError, .tooManyItems)
        }

        let large = try TelemetryBatch(
            batchID: batchID,
            sentAt: timestamp(),
            items: (0..<20).map { index in
                .feedback(try feedback(eventID: UUID(), message: "\(index)" + String(repeating: "x", count: 1_998)))
            }
        )
        XCTAssertLessThanOrEqual(try TelemetryJSON.encodeBatch(large).count, TelemetrySchema.maximumBatchBytes)

        let multibyte = try TelemetryBatch(
            batchID: batchID,
            sentAt: timestamp(),
            items: (0..<20).map { _ in
                .feedback(try feedback(eventID: UUID(), message: String(repeating: "🛡️", count: 2_000)))
            }
        )
        XCTAssertThrowsError(try TelemetryJSON.encodeBatch(multibyte)) { error in
            XCTAssertEqual(error as? TelemetryValidationError, .batchTooLarge)
        }
        let oversized = Data(repeating: 0x20, count: TelemetrySchema.maximumBatchBytes + 1)
        XCTAssertThrowsError(try TelemetryJSON.decodeBatch(from: oversized))
    }

    func testBatchRejectsDuplicateEventIDsThatWouldMakeAcknowledgementsAmbiguous() throws {
        let duplicateItems: [TelemetryItem] = [
            .health(try stageEvent()),
            .feedback(try feedback(eventID: eventID)),
        ]
        XCTAssertThrowsError(
            try TelemetryBatch(batchID: batchID, sentAt: timestamp(), items: duplicateItems)
        ) { error in
            XCTAssertEqual(error as? TelemetryValidationError, .duplicateEventID)
        }

        let valid = try TelemetryBatch(
            batchID: batchID,
            sentAt: timestamp(),
            items: [.health(try stageEvent()), .feedback(try feedback(eventID: feedbackID))]
        )
        let duplicatedWireData = replacing(
            String(decoding: try TelemetryJSON.encodeBatch(valid), as: UTF8.self),
            feedbackID.uuidString,
            eventID.uuidString
        )
        XCTAssertThrowsError(try TelemetryJSON.decodeBatch(from: duplicatedWireData)) { error in
            XCTAssertEqual(error as? TelemetryValidationError, .duplicateEventID)
        }
    }

    func testEndpointRequiresPlainHTTPSAuthorityWithoutSecretsOrTrackingComponents() throws {
        XCTAssertNoThrow(try TelemetryEndpointValidator.validate(URL(string: "https://telemetry.example.com/webhook/opaque")!))
        for value in [
            "http://telemetry.example.com/hook",
            "file:///tmp/hook",
            "https://user:secret@telemetry.example.com/hook",
            "https://telemetry.example.com/hook?token=secret",
            "https://telemetry.example.com/hook#fragment",
            "https:///missing-host",
        ] {
            XCTAssertThrowsError(try TelemetryEndpointValidator.validate(URL(string: value)!))
        }
    }

    func testRecursiveLeakScannerCoversHealthBatchDiagnosticsAndExemptsOnlyFeedbackMessage() throws {
        let canaries = [
            "sk-live-secret", "Private transcript", "/Users/alice/Recordings",
            "https://secret.example/webhook", "raw upstream response", "artifact-canary-id",
        ]
        let healthData = try TelemetryJSON.encodeItem(.health(stageEvent()))
        XCTAssertEqual(try TelemetryLeakScanner.findings(in: healthData, canaries: canaries), [])

        let batch = try TelemetryBatch(
            batchID: batchID,
            sentAt: timestamp(),
            items: [.health(stageEvent()), .feedback(try feedback(eventID: feedbackID, message: canaries.joined(separator: " | ")))]
        )
        let batchData = try TelemetryJSON.encodeBatch(batch)
        XCTAssertEqual(try TelemetryLeakScanner.findings(in: batchData, canaries: canaries), [])
        XCTAssertEqual(
            Set(try TelemetryLeakScanner.findings(
                in: batchData, canaries: canaries, exemptFeedbackMessage: false
            ).map(\.canaryIndex)),
            Set(canaries.indices)
        )

        let diagnostic = TelemetryDiagnostic(code: .deliveryPaused, itemCount: 3)
        let diagnosticData = try JSONEncoder().encode(diagnostic)
        XCTAssertEqual(try TelemetryLeakScanner.findings(in: diagnosticData, canaries: canaries), [])

        let leakedOutsideMessage = #"{"kind":"feedback","message":"safe","category":"sk-live-secret"}"#
        XCTAssertEqual(
            try TelemetryLeakScanner.findings(in: Data(leakedOutsideMessage.utf8), canaries: canaries),
            [TelemetryLeakFinding(path: "$.category", canaryIndex: 0)]
        )
    }

    func testRedactedDiagnosticHasClosedFieldsAndRejectsExtras() throws {
        let diagnostic = TelemetryDiagnostic(code: .retryScheduled, itemCount: -4)
        let data = try JSONEncoder().encode(diagnostic)
        XCTAssertEqual(try JSONDecoder().decode(TelemetryDiagnostic.self, from: data).itemCount, 0)
        XCTAssertThrowsError(try JSONDecoder().decode(
            TelemetryDiagnostic.self,
            from: Data(#"{"code":"queued","item_count":1,"url":"https://secret.example"}"#.utf8)
        ))
    }

    private func stageEvent() throws -> TelemetryHealthEvent {
        try health(
            eventName: .stageOutcome,
            stage: .transcription,
            outcome: .failure,
            duration: .fiveToFifteenSeconds,
            failure: .network
        )
    }

    private func health(
        eventName: TelemetryHealthEventName,
        stage: TelemetryStage? = nil,
        outcome: TelemetryOutcome? = nil,
        duration: TelemetryDurationBucket? = nil,
        failure: TelemetryFailureBucket? = nil,
        weekStart: TelemetryWeekStart? = nil
    ) throws -> TelemetryHealthEvent {
        try TelemetryHealthEvent(
            eventID: eventID,
            occurredAt: timestamp(),
            runtime: runtime(),
            installID: installID,
            eventName: eventName,
            stage: stage,
            outcome: outcome,
            durationBucket: duration,
            failureBucket: failure,
            weekStart: weekStart
        )
    }

    private func feedback(
        eventID: UUID? = nil,
        message: String = "Helpful feedback"
    ) throws -> TelemetryFeedback {
        try TelemetryFeedback(
            eventID: eventID ?? self.eventID,
            occurredAt: timestamp(),
            runtime: runtime(),
            category: .usability,
            message: message
        )
    }

    private func timestamp() throws -> TelemetryTimestamp {
        try TelemetryTimestamp(rawValue: "2026-07-15T09:30:00Z")
    }

    private func runtime() throws -> TelemetryRuntimeContext {
        try TelemetryRuntimeContext(appVersion: "1.4.6", appBuild: "42", osVersion: "14.2")
    }

    private func replacing(_ string: String, _ target: String, _ replacement: String) -> Data {
        Data(string.replacingOccurrences(of: target, with: replacement).utf8)
    }

    private func indexedUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }

    private func assertRoundTrips<Value: Codable & Equatable>(_ values: [Value]) throws {
        for value in values {
            XCTAssertEqual(try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value)), value)
        }
    }
}
