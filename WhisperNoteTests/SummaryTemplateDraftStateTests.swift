import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class SummaryTemplateDraftStateTests: XCTestCase {
    func testDefaultInitializationIsExactAndNeverOverwritesExplicitOrDirtyDraft() {
        let defaultTemplate = SummaryTemplate(name: "Library Default", prompt: "Exact default", isDefault: true)
        let replacement = SummaryTemplate(name: "Replacement", prompt: "Replacement prompt", isDefault: true)

        var state = SummaryTemplateDraftState()
        state.initializeDefaultIfPristine(defaultTemplate, model: "model-a")
        XCTAssertEqual(state.displayName, "Library Default")
        XCTAssertEqual(
            state.snapshot(),
            SummaryGenerationSnapshot(
                templateID: defaultTemplate.stableSelectionID,
                templateName: defaultTemplate.name,
                prompt: "Exact default",
                model: "model-a"
            )
        )
        state.initializeDefaultIfPristine(replacement, model: "model-b")
        XCTAssertEqual(state.prompt, "Exact default")

        state.editPrompt("User edit")
        state.initializeDefaultIfPristine(replacement, model: "model-b")
        XCTAssertEqual(state.prompt, "User edit")
        XCTAssertEqual(state.displayName, "Custom")

        var guided = SummaryTemplateDraftState()
        guided.chooseGuided(prompt: "Guided choice", model: "model-g")
        guided.initializeDefaultIfPristine(defaultTemplate, model: "model-a")
        XCTAssertEqual(guided.prompt, "Guided choice")
        XCTAssertNil(guided.sourceTemplateID)
    }

    func testTemplateEditEnhanceSaveUpdateAndSnapshotsHaveExactProvenance() {
        let source = SummaryTemplate(name: "Weekly", prompt: "Original")
        var state = SummaryTemplateDraftState()
        state.selectTemplate(source, model: "model-a")
        XCTAssertFalse(state.canUpdateSourceTemplate)

        state.editPrompt("Edited")
        XCTAssertEqual(state.displayName, "Custom")
        XCTAssertTrue(state.canSaveAsTemplate)
        XCTAssertTrue(state.canUpdateSourceTemplate)
        XCTAssertEqual(state.snapshot().templateID, source.stableSelectionID)
        XCTAssertEqual(state.snapshot().templateName, "Weekly")
        XCTAssertEqual(state.snapshot().prompt, "Edited")

        let enhancementContext = state.requestContext()
        XCTAssertTrue(state.applyEnhancedPrompt("Enhanced", ifUnchanged: enhancementContext))
        XCTAssertEqual(state.snapshot().prompt, "Enhanced")
        let saved = SummaryTemplate(name: "Saved", prompt: "Enhanced")
        let saveContext = state.requestContext()
        XCTAssertTrue(state.acceptSavedTemplate(saved, ifUnchanged: saveContext))
        XCTAssertEqual(state.displayName, "Saved")
        XCTAssertFalse(state.canUpdateSourceTemplate)
        XCTAssertEqual(state.snapshot().templateID, saved.stableSelectionID)
    }

    func testHistoricalRegenerationPreservesRecordedProvenanceUntilExplicitReplacement() {
        let summary = Summary(
            name: "Summary", date: Date(), content: "Content", transcriptId: UUID(),
            model: "historical-model", prompt: "Historical prompt",
            templateID: "historical-template", templateName: "Historical Template", status: .completed
        )
        var state = SummaryTemplateDraftState()
        state.initializeHistorical(summary, fallbackModel: "fallback")
        XCTAssertEqual(
            state.snapshot(),
            SummaryGenerationSnapshot(
                templateID: "historical-template", templateName: "Historical Template",
                prompt: "Historical prompt", model: "historical-model"
            )
        )
        state.editPrompt("Historical edit")
        XCTAssertEqual(state.snapshot().templateID, "historical-template")
        XCTAssertEqual(state.displayName, "Custom")

        let replacement = SummaryTemplate(name: "Replacement", prompt: "Replacement prompt")
        state.selectTemplate(replacement, model: "replacement-model")
        XCTAssertEqual(state.snapshot().templateID, replacement.stableSelectionID)
        XCTAssertEqual(state.snapshot().prompt, "Replacement prompt")
    }

    func testManualEnhancementIgnoresCompletionAfterEditOrTemplateSwitch() async {
        let first = SummaryTemplate(name: "First", prompt: "First prompt")
        let second = SummaryTemplate(name: "Second", prompt: "Second prompt")
        var state = SummaryTemplateDraftState()
        state.selectTemplate(first, model: "model")

        let editContext = state.requestContext()
        await Task.yield()
        state.editPrompt("Newer manual edit")
        XCTAssertFalse(state.applyEnhancedPrompt("Stale enhancement", ifUnchanged: editContext))
        XCTAssertEqual(state.prompt, "Newer manual edit")
        XCTAssertEqual(state.sourceTemplateID, first.stableSelectionID)

        let switchContext = state.requestContext()
        await Task.yield()
        state.selectTemplate(second, model: "model")
        XCTAssertFalse(state.applyEnhancedPrompt("Another stale enhancement", ifUnchanged: switchContext))
        XCTAssertEqual(state.prompt, "Second prompt")
        XCTAssertEqual(state.sourceTemplateID, second.stableSelectionID)
    }

    func testRegenerationEnhancementIgnoresCompletionAfterEditOrTemplateSwitch() async {
        let summary = Summary(
            name: "Summary", date: Date(), content: "Content", transcriptId: UUID(),
            model: "model", prompt: "Historical", templateID: "old", templateName: "Old", status: .completed
        )
        let replacement = SummaryTemplate(name: "Replacement", prompt: "Replacement")
        var state = SummaryTemplateDraftState()
        state.initializeHistorical(summary, fallbackModel: "fallback")

        let editContext = state.requestContext()
        await Task.yield()
        state.editPrompt("New regeneration edit")
        XCTAssertFalse(state.applyEnhancedPrompt("Stale", ifUnchanged: editContext))
        XCTAssertEqual(state.prompt, "New regeneration edit")
        XCTAssertEqual(state.sourceTemplateID, "old")

        let switchContext = state.requestContext()
        await Task.yield()
        state.selectTemplate(replacement, model: "model")
        XCTAssertFalse(state.applyEnhancedPrompt("Stale again", ifUnchanged: switchContext))
        XCTAssertEqual(state.sourceTemplateID, replacement.stableSelectionID)
        XCTAssertEqual(state.prompt, "Replacement")
    }

    func testSaveAndUpdateCompletionsPersistButCannotReplaceNewerDraft() async {
        let source = SummaryTemplate(name: "Source", prompt: "Original")
        let saved = SummaryTemplate(name: "Saved", prompt: "Captured edit")
        var state = SummaryTemplateDraftState()
        state.selectTemplate(source, model: "model")
        state.editPrompt("Captured edit")

        let saveContext = state.requestContext()
        await Task.yield()
        state.editPrompt("Newer than save")
        XCTAssertFalse(state.acceptSavedTemplate(saved, ifUnchanged: saveContext))
        XCTAssertEqual(state.prompt, "Newer than save")
        XCTAssertEqual(state.sourceTemplateID, source.stableSelectionID)

        let updateContext = state.requestContext()
        await Task.yield()
        state.chooseGuided(prompt: "New guided choice", model: "model")
        let updated = SummaryTemplate(id: source.id, name: source.name, prompt: "Newer than save")
        XCTAssertFalse(state.acceptUpdatedSource(updated, ifUnchanged: updateContext))
        XCTAssertEqual(state.prompt, "New guided choice")
        XCTAssertNil(state.sourceTemplateID)
    }

    func testRejectedLoadDuringRebindLeavesDraftPristineUntilBPublishes() async throws {
        let aURL = URL(fileURLWithPath: "/tmp/rejected-load-a.json")
        let bURL = URL(fileURLWithPath: "/tmp/rejected-load-b.json")
        let access = MappedSummaryTemplateFileAccess(dataByURL: [
            aURL: try encodedLibrary(customName: "A", prompt: "A prompt"),
            bURL: try encodedLibrary(customName: "B", prompt: "B prompt")
        ])
        let controller = SummaryTemplateController(
            repository: SummaryTemplateRepository(fileURL: aURL, fileAccess: access)
        )
        var state = SummaryTemplateDraftState()

        let closed = await controller.beginLibraryRebind()
        XCTAssertTrue(closed)
        let admitted = await controller.load()
        XCTAssertFalse(admitted)
        if admitted {
            state.initializeDefaultIfPristine(controller.defaultTemplateValue, model: "model")
        }
        XCTAssertFalse(state.isInitialized)

        let candidate = try await controller.preflight(fileURL: bURL)
        try await controller.accept(candidate)
        controller.finishLibraryRebind()
        state.initializeDefaultIfPristine(controller.defaultTemplateValue, model: "model")
        XCTAssertTrue(state.isInitialized)
        XCTAssertEqual(state.prompt, "B prompt")
        XCTAssertEqual(state.sourceTemplateName, "B")
    }

    func testPreflightReadsOnceAndRejectsScriptedABABytes() async throws {
        let url = URL(fileURLWithPath: "/tmp/scripted-summary-templates.json")
        let a = try encodedLibrary(customName: "A", prompt: "A prompt")
        let b = try encodedLibrary(customName: "B", prompt: "B prompt")
        let access = ScriptedSummaryTemplateFileAccess(reads: [a, b, a])
        let repository = SummaryTemplateRepository(fileURL: url, fileAccess: access)

        let candidate = try await repository.preflight(fileURL: url)
        XCTAssertEqual(access.readCount, 1)
        do {
            _ = try await repository.accept(candidate)
            XCTFail("Expected the intervening B bytes to reject A")
        } catch SummaryTemplateRepositoryError.candidateChanged(let changedURL) {
            XCTAssertEqual(changedURL, url)
        }
        XCTAssertEqual(access.readCount, 2)
        XCTAssertEqual(access.writeCount, 0)
    }

    func testLoadDrainsBeforeRebindAndClosedGateRejectsNewLoads() async throws {
        let aURL = URL(fileURLWithPath: "/tmp/controller-library-a.json")
        let bURL = URL(fileURLWithPath: "/tmp/controller-library-b.json")
        let a = try encodedLibrary(customName: "A", prompt: "A prompt")
        let b = try encodedLibrary(customName: "B", prompt: "B prompt")
        let access = BlockingSummaryTemplateFileAccess(dataByURL: [aURL: a, bURL: b])
        let controller = SummaryTemplateController(
            repository: SummaryTemplateRepository(fileURL: aURL, fileAccess: access)
        )

        let load = Task { await controller.load() }
        let deadline = ContinuousClock.now + .seconds(2)
        while access.readCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(access.readCount, 1)
        let close = Task { await controller.beginLibraryRebind() }
        while !controller.isLibraryRebinding { await Task.yield() }
        let readsBeforeRejectedLoad = access.readCount
        let rejectedLoad = await controller.reload()
        XCTAssertFalse(rejectedLoad)
        XCTAssertEqual(access.readCount, readsBeforeRejectedLoad)

        access.release.signal()
        let loadedA = await load.value
        let closed = await close.value
        XCTAssertTrue(loadedA)
        XCTAssertTrue(closed)
        let candidate = try await controller.preflight(fileURL: bURL)
        try await controller.accept(candidate)
        controller.finishLibraryRebind()

        XCTAssertEqual(controller.defaultTemplateValue.name, "B")
        XCTAssertEqual(controller.defaultTemplateValue.prompt, "B prompt")
        XCTAssertFalse(controller.templates.contains(where: { $0.name == "A" }))
    }

    private func encodedLibrary(customName: String, prompt: String) throws -> Data {
        var templates = SummaryTemplatePresetCatalog.presets.map { template in
            var template = template
            template.isDefault = false
            return template
        }
        templates.append(SummaryTemplate(name: customName, prompt: prompt, isDefault: true, sortOrder: templates.count))
        return try JSONEncoder().encode(SummaryTemplateEnvelope(templates: templates))
    }
}

private final class ScriptedSummaryTemplateFileAccess: SummaryTemplateFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data]
    private var _readCount = 0
    private var _writeCount = 0

    init(reads: [Data]) { self.reads = reads }
    var readCount: Int { lock.withLock { _readCount } }
    var writeCount: Int { lock.withLock { _writeCount } }
    func fileExists(at url: URL) -> Bool { true }
    func read(from url: URL) throws -> Data {
        try lock.withLock {
            _readCount += 1
            guard !reads.isEmpty else { throw ScriptError.exhausted }
            return reads.removeFirst()
        }
    }
    func writeAtomically(_ data: Data, to url: URL) throws { lock.withLock { _writeCount += 1 } }
    private enum ScriptError: Error { case exhausted }
}

private final class BlockingSummaryTemplateFileAccess: SummaryTemplateFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let dataByURL: [URL: Data]
    private var blockFirstRead = true
    private var _readCount = 0
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(dataByURL: [URL: Data]) { self.dataByURL = dataByURL }
    var readCount: Int { lock.withLock { _readCount } }
    func fileExists(at url: URL) -> Bool { dataByURL[url] != nil }
    func read(from url: URL) throws -> Data {
        let shouldBlock = lock.withLock { () -> Bool in
            _readCount += 1
            defer { blockFirstRead = false }
            return blockFirstRead
        }
        if shouldBlock {
            started.signal()
            release.wait()
        }
        guard let data = dataByURL[url] else { throw ReadError.missing }
        return data
    }
    func writeAtomically(_ data: Data, to url: URL) throws {}
    private enum ReadError: Error { case missing }
}

private final class MappedSummaryTemplateFileAccess: SummaryTemplateFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var dataByURL: [URL: Data]
    init(dataByURL: [URL: Data]) { self.dataByURL = dataByURL }
    func fileExists(at url: URL) -> Bool { lock.withLock { dataByURL[url] != nil } }
    func read(from url: URL) throws -> Data {
        try lock.withLock {
            guard let data = dataByURL[url] else { throw ReadError.missing }
            return data
        }
    }
    func writeAtomically(_ data: Data, to url: URL) throws { lock.withLock { dataByURL[url] = data } }
    private enum ReadError: Error { case missing }
}
