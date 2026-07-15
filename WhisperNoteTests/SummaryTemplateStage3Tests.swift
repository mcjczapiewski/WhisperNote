import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class SummaryTemplateStage3Tests: XCTestCase {
    func testPreflightMissingStoreIsReadOnlyUntilAccept() async throws {
        let root = temporaryRoot("MissingPreflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeURL = root.appendingPathComponent("A/templates.json")
        let candidateURL = root.appendingPathComponent("B/Templates/summary-templates.json")
        let repository = SummaryTemplateRepository(fileURL: activeURL)
        _ = try await repository.templates()

        let candidate = try await repository.preflight(fileURL: candidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))

        let accepted = try await repository.accept(candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertEqual(accepted.count, SummaryTemplatePresetCatalog.presets.count)
        XCTAssertEqual(accepted.first(where: \.isDefault)?.presetID, SummaryTemplatePresetCatalog.meetingMinutesID)
    }

    func testPreflightRejectsCandidateChangedBeforeAcceptWithoutOverwritingBytes() async throws {
        let root = temporaryRoot("StaleCandidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeURL = root.appendingPathComponent("A/templates.json")
        let candidateURL = root.appendingPathComponent("B/Templates/summary-templates.json")
        let repository = SummaryTemplateRepository(fileURL: activeURL)
        _ = try await repository.templates()
        let candidate = try await repository.preflight(fileURL: candidateURL)
        try FileManager.default.createDirectory(at: candidateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let changedBytes = Data("external change".utf8)
        try changedBytes.write(to: candidateURL)

        do {
            _ = try await repository.accept(candidate)
            XCTFail("Expected stale candidate rejection")
        } catch SummaryTemplateRepositoryError.candidateChanged(let url) {
            XCTAssertEqual(url, candidateURL)
        }
        XCTAssertEqual(try Data(contentsOf: candidateURL), changedBytes)
        let activeDefault = try await repository.defaultTemplate()
        XCTAssertEqual(activeDefault.presetID, SummaryTemplatePresetCatalog.meetingMinutesID)
    }

    func testControllerCRUDDefaultFallbackAndMutationGate() async throws {
        let root = temporaryRoot("ControllerCRUD")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SummaryTemplateController(
            repository: SummaryTemplateRepository(fileURL: root.appendingPathComponent("templates.json"))
        )
        await controller.load()
        let createdResult = await controller.create(name: "Weekly", prompt: "Prompt one")
        let custom = try XCTUnwrap(createdResult)
        let editedResult = await controller.update(id: custom.id, name: "Weekly", prompt: "Prompt two")
        let edited = try XCTUnwrap(editedResult)
        XCTAssertEqual(edited.prompt, "Prompt two")
        let copyResult = await controller.duplicate(id: custom.id)
        let copy = try XCTUnwrap(copyResult)
        XCTAssertNotEqual(copy.id, custom.id)
        await controller.setDefault(id: custom.id)
        XCTAssertEqual(controller.defaultTemplateValue.id, custom.id)

        let didClose = await controller.beginLibraryRebind()
        XCTAssertTrue(didClose)
        let blocked = await controller.create(name: "Blocked", prompt: "Must not save")
        XCTAssertNil(blocked)
        XCTAssertNil(controller.templates.first(where: { $0.name == "Blocked" }))
        controller.resumeAfterLibraryRebindCancellation()

        await controller.delete(id: custom.id)
        XCTAssertEqual(controller.defaultTemplateValue.presetID, SummaryTemplatePresetCatalog.meetingMinutesID)
        XCTAssertEqual(controller.notice, .defaultChangedToMeetingMinutes)
    }

    func testCoordinatedTemplateSwitchAtoBtoAAndNewJobUsesBDefault() async throws {
        let context = try await makeLibraryContext()
        defer { context.restore() }
        let defaultA = try writeTemplateLibrary(root: context.rootA, name: "A Default", prompt: "A prompt")
        let defaultB = try writeTemplateLibrary(root: context.rootB, name: "B Default", prompt: "B prompt")
        await context.templateController.load()
        context.workflow.attachTemplateProvider(context.templateController)
        await context.workflow.attach(
            transcriptionManager: context.transcriptionManager,
            summaryManager: context.summaryManager,
            recordings: { [context.recording] }
        )
        let didLoadA = await context.librarySearch.reloadLibrary()
        XCTAssertTrue(didLoadA)
        XCTAssertEqual(context.templateController.defaultTemplateValue.id, defaultA.id)

        let didSelectB = await context.librarySearch.selectLibrary(path: context.rootB.path, bookmark: nil)
        XCTAssertTrue(didSelectB)
        XCTAssertEqual(context.templateController.defaultTemplateValue.id, defaultB.id)
        await context.workflow.recordingDidSave(context.recording)
        let job = try XCTUnwrap(context.workflow.job(for: context.recording.id))
        XCTAssertEqual(job.snapshot.templateID, defaultB.stableSelectionID)
        XCTAssertEqual(job.snapshot.prompt, "B prompt")

        let didReturnA = await context.librarySearch.selectLibrary(path: context.rootA.path, bookmark: nil)
        XCTAssertTrue(didReturnA)
        XCTAssertEqual(context.templateController.defaultTemplateValue.id, defaultA.id)
    }

    func testCorruptCandidateAndPrepareRollbackPreserveActiveStateNoticeAndBytes() async throws {
        let context = try await makeLibraryContext()
        defer { context.restore() }
        let defaultA = try writeTemplateLibrary(root: context.rootA, name: "A Default", prompt: "A prompt")
        await context.templateController.load()
        let didLoadA = await context.librarySearch.reloadLibrary()
        XCTAssertTrue(didLoadA)
        context.templateController.select(defaultA.stableSelectionID)
        let priorTemplates = context.templateController.templates
        let priorSelection = context.templateController.selectedTemplateID
        let priorNotice = context.templateController.notice

        let candidateURL = DirectoryManager.summaryTemplatesURL(
            baseDirectory: context.rootB.appendingPathComponent("WhisperNote/Files")
        )
        try FileManager.default.createDirectory(at: candidateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: candidateURL)
        let corruptSwitch = await context.librarySearch.selectLibrary(path: context.rootB.path, bookmark: nil)
        XCTAssertFalse(corruptSwitch)
        XCTAssertEqual(try Data(contentsOf: candidateURL), corrupt)
        XCTAssertEqual(context.templateController.templates, priorTemplates)
        XCTAssertEqual(context.templateController.selectedTemplateID, priorSelection)
        XCTAssertEqual(context.templateController.notice, priorNotice)

        let validB = try writeTemplateLibrary(root: context.rootB, name: "B Default", prompt: "B prompt")
        let validBytes = try Data(contentsOf: candidateURL)
        context.librarySearch.testPrepareFailure = true
        let rollbackSwitch = await context.librarySearch.selectLibrary(path: context.rootB.path, bookmark: nil)
        XCTAssertFalse(rollbackSwitch)
        XCTAssertEqual(try Data(contentsOf: candidateURL), validBytes)
        XCTAssertEqual(context.templateController.defaultTemplateValue.id, defaultA.id)
        XCTAssertNotEqual(context.templateController.defaultTemplateValue.id, validB.id)
        XCTAssertFalse(context.templateController.isLibraryRebinding)
    }

    func testMissingCandidateSeedsOnlyAfterSuccessfulCoordinatedSwitch() async throws {
        let context = try await makeLibraryContext()
        defer { context.restore() }
        _ = try writeTemplateLibrary(root: context.rootA, name: "A Default", prompt: "A prompt")
        await context.templateController.load()
        let didLoadA = await context.librarySearch.reloadLibrary()
        XCTAssertTrue(didLoadA)
        let missingURL = DirectoryManager.summaryTemplatesURL(
            baseDirectory: context.rootB.appendingPathComponent("WhisperNote/Files")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        let didSelectB = await context.librarySearch.selectLibrary(path: context.rootB.path, bookmark: nil)
        XCTAssertTrue(didSelectB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertEqual(context.templateController.defaultTemplateValue.presetID, SummaryTemplatePresetCatalog.meetingMinutesID)
    }

    func testStage3SourceWiringFreezesSnapshotsAndNeverDeleteFirstRegenerates() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WhisperNote")
        let appModel = try String(contentsOf: sourceRoot.appendingPathComponent("WhisperNoteAppModel.swift"))
        let app = try String(contentsOf: sourceRoot.appendingPathComponent("WhisperNoteApp.swift"))
        let transcript = try String(contentsOf: sourceRoot.appendingPathComponent("TranscriptView.swift"))
        let summary = try String(contentsOf: sourceRoot.appendingPathComponent("SummaryView.swift"))
        let settings = try String(contentsOf: sourceRoot.appendingPathComponent("SettingsView.swift"))
        let templateLibrary = try String(contentsOf: sourceRoot.appendingPathComponent("SummaryTemplateLibraryView.swift"))

        XCTAssertTrue(appModel.contains("let summaryTemplateController: SummaryTemplateController"))
        XCTAssertTrue(appModel.contains("attachTemplateProvider(summaryTemplateController)"))
        XCTAssertTrue(app.contains("environmentObject(model.summaryTemplateController)"))
        XCTAssertTrue(settings.contains("Manage Summary Templates"))
        XCTAssertTrue(transcript.contains("snapshot: snapshot"))
        XCTAssertTrue(transcript.contains("Save as Template"))
        XCTAssertTrue(transcript.contains("Update Template"))
        XCTAssertTrue(templateLibrary.contains("trimmedName.count > SummaryTemplateRepository.maximumNameLength"))
        XCTAssertTrue(templateLibrary.contains("trimmedPrompt.count > SummaryTemplateRepository.maximumPromptLength"))
        XCTAssertTrue(templateLibrary.contains("let succeeded = await onSave(name, prompt)"))
        XCTAssertTrue(templateLibrary.contains("if succeeded { dismiss() }"))
        XCTAssertTrue(templateLibrary.contains(".disabled(isSaving || validationMessage != nil)"))
        let regeneration = try XCTUnwrap(summary.range(of: "struct RegenerateSummaryView"))
        let regenerationSource = String(summary[regeneration.lowerBound...])
        XCTAssertTrue(regenerationSource.contains("regenerateSummary("))
        XCTAssertFalse(regenerationSource.contains("deleteSummary(id: selectedSummary.id)"))
    }

    private func makeLibraryContext() async throws -> Stage3LibraryContext {
        let defaults = UserDefaults.standard
        let previousPath = defaults.object(forKey: "recordingsDirectory")
        let previousBookmark = defaults.object(forKey: "recordingsDirectoryBookmark")
        let previousAuto = defaults.object(forKey: "autoTranscribeAfterRecording")
        let root = temporaryRoot("Library")
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        try writeEmptyArtifacts(root: rootA)
        try writeEmptyArtifacts(root: rootB)
        defaults.removeObject(forKey: "recordingsDirectoryBookmark")
        defaults.set(rootA.path, forKey: "recordingsDirectory")
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        let recorder = AudioRecorder()
        let transcriptionManager = TranscriptionManager()
        let summaryManager = SummaryManager()
        let workflow = PostRecordingWorkflowCoordinator(defaults: defaults, credentialDebounceNanoseconds: 0)
        let templateURL = DirectoryManager.summaryTemplatesURL(
            baseDirectory: rootA.appendingPathComponent("WhisperNote/Files")
        )
        let templateController = SummaryTemplateController(
            repository: SummaryTemplateRepository(fileURL: templateURL)
        )
        let librarySearch = LibrarySearchController(
            audioRecorder: recorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflow,
            summaryTemplateController: templateController
        )
        return Stage3LibraryContext(
            root: root, rootA: rootA, rootB: rootB, previousPath: previousPath,
            previousBookmark: previousBookmark,
            previousAuto: previousAuto, recorder: recorder,
            transcriptionManager: transcriptionManager, summaryManager: summaryManager,
            workflow: workflow, templateController: templateController,
            librarySearch: librarySearch
        )
    }

    private func writeEmptyArtifacts(root: URL) throws {
        let base = root.appendingPathComponent("WhisperNote/Files")
        for relative in ["Recordings/recordings.json", "Transcripts/transcripts.json", "Summaries/summaries.json", "Processing/processing-jobs.json"] {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: url)
        }
    }

    @discardableResult
    private func writeTemplateLibrary(root: URL, name: String, prompt: String) throws -> SummaryTemplate {
        var presets = SummaryTemplatePresetCatalog.presets.map { template -> SummaryTemplate in
            var template = template
            template.isDefault = false
            return template
        }
        let custom = SummaryTemplate(name: name, prompt: prompt, isDefault: true, sortOrder: presets.count)
        presets.append(custom)
        let url = DirectoryManager.summaryTemplatesURL(baseDirectory: root.appendingPathComponent("WhisperNote/Files"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SummaryTemplateEnvelope(templates: presets)).write(to: url)
        return custom
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperNote-Stage3-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private struct Stage3LibraryContext {
    let root: URL
    let rootA: URL
    let rootB: URL
    let previousPath: Any?
    let previousBookmark: Any?
    let previousAuto: Any?
    let recorder: AudioRecorder
    let transcriptionManager: TranscriptionManager
    let summaryManager: SummaryManager
    let workflow: PostRecordingWorkflowCoordinator
    let templateController: SummaryTemplateController
    let librarySearch: LibrarySearchController
    let recording = Recording(
        name: "New recording", date: Date(), duration: 1,
        filePath: URL(fileURLWithPath: "/tmp/stage3-recording.m4a")
    )

    func restore() {
        let defaults = UserDefaults.standard
        if let previousPath { defaults.set(previousPath, forKey: "recordingsDirectory") }
        else { defaults.removeObject(forKey: "recordingsDirectory") }
        if let previousBookmark { defaults.set(previousBookmark, forKey: "recordingsDirectoryBookmark") }
        else { defaults.removeObject(forKey: "recordingsDirectoryBookmark") }
        if let previousAuto { defaults.set(previousAuto, forKey: "autoTranscribeAfterRecording") }
        else { defaults.removeObject(forKey: "autoTranscribeAfterRecording") }
        try? FileManager.default.removeItem(at: root)
    }
}
