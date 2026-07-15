import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class SummaryTemplateIntegrationTests: XCTestCase {
    func testControllerFreezesExactDefaultThenRepositoryEditAndDeleteCannotChangeSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SummaryTemplateRepository(fileURL: root.appendingPathComponent("templates.json"))
        let custom = try await repository.create(name: "Weekly", prompt: "prompt-v1")
        try await repository.setDefault(id: custom.id)
        let controller = SummaryTemplateController(repository: repository)
        await controller.load()

        let frozen = await controller.defaultSelectionSnapshot(model: "model-v1")
        _ = try await repository.update(id: custom.id, name: "Weekly changed", prompt: "prompt-v2")
        try await repository.delete(id: custom.id)

        XCTAssertEqual(frozen.templateID, custom.stableSelectionID)
        XCTAssertEqual(frozen.templateName, "Weekly")
        XCTAssertEqual(frozen.prompt, "prompt-v1")
        XCTAssertEqual(frozen.model, "model-v1")

        await controller.load()
        let replacement = await controller.defaultSelectionSnapshot(model: "model-v2")
        XCTAssertEqual(replacement.templateID, SummaryTemplatePresetCatalog.meetingMinutesID)
        XCTAssertEqual(replacement.prompt, SummaryTemplatePresetCatalog.meetingMinutesPrompt)
    }

    func testControllerUsesInMemoryMeetingMinutesFallbackWithoutOverwritingCorruptStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("templates.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let controller = SummaryTemplateController(
            repository: SummaryTemplateRepository(fileURL: url)
        )

        await controller.load()
        let snapshot = await controller.defaultSelectionSnapshot(model: "model")

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.templates.map(\.stableSelectionID), [SummaryTemplatePresetCatalog.meetingMinutesID])
        XCTAssertEqual(snapshot.prompt, SummaryTemplatePresetCatalog.meetingMinutesPrompt)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testFailedControllerRebindPreservesHealthyPublishedStateAndNotice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthyURL = root.appendingPathComponent("healthy/templates.json")
        let corruptURL = root.appendingPathComponent("corrupt/templates.json")
        let repository = SummaryTemplateRepository(fileURL: healthyURL)
        let custom = try await repository.create(name: "Default custom", prompt: "custom prompt")
        try await repository.setDefault(id: custom.id)
        try await repository.delete(id: custom.id)
        let controller = SummaryTemplateController(repository: repository)
        await controller.load()
        controller.select(SummaryTemplatePresetCatalog.actionItemsID)
        let priorTemplates = controller.templates
        let priorSelection = controller.selectedTemplateID
        let priorNotice = controller.notice
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: corruptURL)

        await controller.rebind(to: corruptURL)

        XCTAssertEqual(controller.templates, priorTemplates)
        XCTAssertEqual(controller.selectedTemplateID, priorSelection)
        XCTAssertEqual(controller.notice, priorNotice)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
    }

    func testGenerationPersistsExactSnapshotProvenance() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = configuredManager(directory: root)
        let transcript = makeTranscript()
        let snapshot = SummaryGenerationSnapshot(
            templateID: "action-items-v1",
            templateName: "Action Items",
            prompt: "exact prompt",
            model: "exact model"
        )
        manager.testSummaryOperation = { prompt, model, _ in
            XCTAssertEqual(prompt, snapshot.prompt)
            XCTAssertEqual(model, snapshot.model)
            return "generated"
        }

        let summary = try await manager.generateSummary(for: transcript, snapshot: snapshot)

        XCTAssertEqual(summary.content, "generated")
        XCTAssertEqual(summary.prompt, snapshot.prompt)
        XCTAssertEqual(summary.model, snapshot.model)
        XCTAssertEqual(summary.templateID, snapshot.templateID)
        XCTAssertEqual(summary.templateName, snapshot.templateName)
        let persisted = try JSONDecoder().decode(
            [Summary].self,
            from: Data(contentsOf: root.appendingPathComponent("summaries.json"))
        )
        XCTAssertEqual(persisted.first?.prompt, snapshot.prompt)
        XCTAssertEqual(persisted.first?.model, snapshot.model)
    }

    func testRetryUsesStoredPromptModelAndProvenanceAndFailurePreservesExistingSummary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = configuredManager(directory: root)
        let transcript = makeTranscript()
        let original = Summary(
            name: "Original",
            date: Date(),
            content: "old content",
            transcriptId: transcript.id,
            model: "stored-model",
            prompt: "stored-prompt",
            templateID: UUID().uuidString.lowercased(),
            templateName: "Deleted template",
            status: .failed
        )
        manager.acceptLibrary(summaries: [original], summariesDirectory: root)
        manager.testSummaryOperation = { prompt, model, _ in
            XCTAssertEqual(prompt, "stored-prompt")
            XCTAssertEqual(model, "stored-model")
            return "retried"
        }

        let retried = try await manager.retryGenerateSummary(id: original.id, transcript: transcript)
        XCTAssertEqual(retried.content, "retried")
        XCTAssertEqual(retried.templateID, original.templateID)

        manager.testSummaryOperation = { _, _, _ in throw TestFailure.expected }
        do {
            _ = try await manager.regenerateSummary(
                id: original.id,
                transcript: transcript,
                snapshot: SummaryGenerationSnapshot(prompt: "new", model: "new-model")
            )
            XCTFail("Expected regeneration to fail")
        } catch { }

        let preserved = try XCTUnwrap(manager.summary(id: original.id))
        XCTAssertEqual(preserved.content, retried.content)
        XCTAssertEqual(preserved.prompt, retried.prompt)
        XCTAssertEqual(preserved.model, retried.model)
        XCTAssertEqual(preserved.templateID, retried.templateID)
        XCTAssertEqual(preserved.status, retried.status)
    }

    func testManualGenerationFinalWriteFailureLeavesDurableAndPublishedInProgressStateCoherent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = configuredManager(directory: root)
        let transcript = makeTranscript()
        var writeCount = 0
        manager.testSummaryPersistenceOperation = { candidate, url in
            writeCount += 1
            if writeCount == 3 { throw TestFailure.expected }
            try JSONEncoder().encode(candidate).write(to: url, options: .atomic)
        }
        manager.testSummaryOperation = { _, _, _ in "completed content" }

        do {
            _ = try await manager.generateSummary(
                for: transcript,
                snapshot: SummaryGenerationSnapshot(prompt: "prompt", model: "model")
            )
            XCTFail("Expected final persistence to fail")
        } catch { }

        let published = try XCTUnwrap(manager.summaries.first)
        let durable = try XCTUnwrap(JSONDecoder().decode(
            [Summary].self,
            from: Data(contentsOf: root.appendingPathComponent("summaries.json"))
        ).first)
        XCTAssertEqual(published.status, .inProgress)
        XCTAssertEqual(durable.status, .inProgress)
        XCTAssertEqual(published.id, durable.id)
        XCTAssertEqual(published.content, durable.content)
    }

    func testManualGenerationInitialWriteFailurePublishesNothingAndPreservesExistingStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = configuredManager(directory: root)
        let storeURL = root.appendingPathComponent("summaries.json")
        let bytesBefore = try Data(contentsOf: storeURL)
        manager.testSummaryPersistenceOperation = { _, _ in throw TestFailure.expected }
        manager.testSummaryOperation = { _, _, _ in
            XCTFail("Network must not start before the pending artifact is durable")
            return "unreachable"
        }

        do {
            _ = try await manager.generateSummary(
                for: makeTranscript(),
                snapshot: SummaryGenerationSnapshot(prompt: "prompt", model: "model")
            )
            XCTFail("Expected initial persistence to fail")
        } catch { }

        XCTAssertTrue(manager.summaries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: storeURL), bytesBefore)
    }

    func testManualGenerationLibraryEpochFailureLeavesDiskAndMemoryCoherent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = configuredManager(directory: root)
        let transcript = makeTranscript()
        manager.testSummaryOperation = { _, _, _ in
            XCTAssertTrue(manager.beginLibraryRebind())
            return "stale content"
        }

        do {
            _ = try await manager.generateSummary(
                for: transcript,
                snapshot: SummaryGenerationSnapshot(prompt: "prompt", model: "model")
            )
            XCTFail("Expected stale library failure")
        } catch let error as SummaryError {
            guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let published = try XCTUnwrap(manager.summaries.first)
        let durable = try XCTUnwrap(JSONDecoder().decode(
            [Summary].self,
            from: Data(contentsOf: root.appendingPathComponent("summaries.json"))
        ).first)
        XCTAssertEqual(published.status, .inProgress)
        XCTAssertEqual(durable.status, .inProgress)
        XCTAssertEqual(published.id, durable.id)
        manager.finishLibraryRebind()
    }

    private func configuredManager(directory: URL) -> SummaryManager {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SummaryManager(
            initialSummariesDirectory: directory,
            apiKeyProvider: { "test-key" }
        )
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            name: "Transcript",
            date: Date(),
            content: "Transcript body",
            recordingId: UUID(),
            status: .completed
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperNote-SummaryTemplateIntegration-\(UUID().uuidString)")
    }
}

private enum TestFailure: Error {
    case expected
}
