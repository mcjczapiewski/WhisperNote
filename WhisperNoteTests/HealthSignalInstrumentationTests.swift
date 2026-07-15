import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class HealthSignalInstrumentationTests: XCTestCase {
    func testSummarySignalsAfterDurableSuccessAndCoarsensFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSignalTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signals = HealthSignalSpy()
        let manager = SummaryManager(
            initialSummariesDirectory: directory,
            apiKeyProvider: { "test-key" },
            healthSignals: signals
        )
        manager.testSummaryOperation = { _, _, _ in "safe content" }
        _ = try await manager.generateSummary(for: fixtureTranscript())
        XCTAssertEqual(signals.calls.count, 1)
        XCTAssertEqual(signals.calls[0].stage, .summary)
        XCTAssertEqual(signals.calls[0].outcome, .success)

        manager.testSummaryOperation = { _, _, _ in
            throw SummaryError.apiError(statusCode: 429)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.generateSummary(for: self.fixtureTranscript())
        }
        XCTAssertEqual(signals.calls.last?.outcome, .failure)
        XCTAssertEqual(signals.calls.last?.failure, .rateLimited)
    }

    func testFailedSummaryPersistenceDoesNotEmitCompletionAndRetryEmitsOneStageOutcomePerAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSignalTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signals = HealthSignalSpy()
        let manager = SummaryManager(
            initialSummariesDirectory: directory,
            apiKeyProvider: { "test-key" },
            healthSignals: signals
        )
        manager.testSummaryPersistenceOperation = { _, _ in throw HealthSignalTestError.persistence }
        manager.testSummaryOperation = { _, _, _ in "content" }
        await XCTAssertThrowsErrorAsync { _ = try await manager.generateSummary(for: self.fixtureTranscript()) }
        XCTAssertTrue(signals.calls.isEmpty)

        manager.testSummaryPersistenceOperation = nil
        _ = try await manager.generateSummary(for: fixtureTranscript())
        let summary = try XCTUnwrap(manager.summaries.first)
        _ = try await manager.retryGenerateSummary(id: summary.id, transcript: fixtureTranscript())
        XCTAssertEqual(signals.calls.filter { $0.stage == .summary && $0.outcome == .success }.count, 2)
    }

    func testWorkflowAndRegenerationEmitOneTerminalSignalPerAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSignalTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signals = HealthSignalSpy()
        let manager = SummaryManager(initialSummariesDirectory: directory, apiKeyProvider: { "test-key" }, healthSignals: signals)
        manager.testSummaryOperation = { _, _, _ in "workflow content" }
        let transcript = fixtureTranscript()
        let workflowID = UUID()
        _ = try await manager.summarizeForWorkflow(transcript, summaryID: workflowID, prompt: "private prompt", model: "model")
        XCTAssertEqual(signals.calls, [.init(stage: .summary, outcome: .success, failure: nil)])

        manager.testSummaryOperation = { _, _, _ in throw SummaryError.apiError(statusCode: 503) }
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.regenerateSummary(
                id: workflowID, transcript: transcript,
                snapshot: SummaryGenerationSnapshot(prompt: "private prompt", model: "model")
            )
        }
        XCTAssertEqual(signals.calls.last, .init(stage: .summary, outcome: .failure, failure: .service))

        manager.testSummaryOperation = { _, _, _ in throw SummaryError.staleLibrary }
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.regenerateSummary(
                id: workflowID, transcript: transcript,
                snapshot: SummaryGenerationSnapshot(prompt: "private prompt", model: "model")
            )
        }
        XCTAssertEqual(signals.calls.last, .init(stage: .summary, outcome: .cancelled, failure: nil))
        XCTAssertEqual(signals.calls.count, 3)
    }

    func testManualWorkflowAndGroupedTranscriptionEmitOneDurableTerminalSignal() async throws {
        let defaults = UserDefaults.standard
        let oldKey = defaults.string(forKey: "elevenlabsApiKey")
        defaults.set("test-key", forKey: "elevenlabsApiKey")
        defer {
            if let oldKey { defaults.set(oldKey, forKey: "elevenlabsApiKey") }
            else { defaults.removeObject(forKey: "elevenlabsApiKey") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSignalTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = recording(at: root.appendingPathComponent("private-audio-one.m4a"))
        let second = recording(at: root.appendingPathComponent("private-audio-two.m4a"))
        let signals = HealthSignalSpy()
        let manager = TranscriptionManager(healthSignals: signals)
        manager.testTranscriptionOperation = { _, _ in ("private content", "private formatted", nil) }

        _ = try await manager.transcribeRecording(first)
        _ = try await manager.transcribeForWorkflow(second, transcriptID: UUID(), language: "eng")
        signals.reset()
        _ = try await manager.transcribeGroup([first, second], groupId: UUID(), groupName: "private group")
        XCTAssertEqual(signals.calls, [.init(stage: .transcription, outcome: .success, failure: nil)])

        manager.testTranscriptionOperation = { _, _ in throw TranscriptionError.apiError(statusCode: 429, message: "private token") }
        await XCTAssertThrowsErrorAsync { _ = try await manager.transcribeRecording(first) }
        XCTAssertEqual(signals.calls.last, .init(stage: .transcription, outcome: .failure, failure: .rateLimited))

        manager.testTranscriptionOperation = { _, _ in throw TranscriptionError.staleLibrary }
        await XCTAssertThrowsErrorAsync { _ = try await manager.transcribeForWorkflow(second, transcriptID: UUID(), language: "eng") }
        XCTAssertEqual(signals.calls.last, .init(stage: .transcription, outcome: .cancelled, failure: nil))
    }

    private func fixtureTranscript() -> Transcript {
        Transcript(name: "private transcript title", date: Date(), content: "secret transcript body", recordingId: UUID(), status: .completed)
    }

    private func recording(at url: URL) -> Recording {
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return Recording(name: "private recording name", date: Date(), duration: 1, filePath: url)
    }
}

private enum HealthSignalTestError: Error { case persistence }

@MainActor
private final class HealthSignalSpy: HealthSignalRecording {
    struct Call: Equatable {
        let stage: TelemetryStage
        let outcome: TelemetryOutcome
        let failure: TelemetryFailureBucket?
    }

    private(set) var calls: [Call] = []

    func reset() { calls = [] }

    func recordHealthSignal(
        stage: TelemetryStage,
        outcome: TelemetryOutcome,
        startedAt: Date,
        failure: TelemetryFailureBucket?
    ) async {
        calls.append(Call(stage: stage, outcome: outcome, failure: failure))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch { }
}
