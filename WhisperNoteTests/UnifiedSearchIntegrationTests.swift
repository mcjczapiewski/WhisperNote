import XCTest
@testable import WhisperNote

@MainActor
final class UnifiedSearchIntegrationTests: XCTestCase {
    func testManualSummaryStaysStaleAndGateReopensAfterRebindRollback() async throws {
        let defaults = UserDefaults.standard
        let previousPath = defaults.object(forKey: "recordingsDirectory")
        let previousKey = defaults.object(forKey: "openrouterApiKey")
        defer {
            if let previousPath { defaults.set(previousPath, forKey: "recordingsDirectory") }
            else { defaults.removeObject(forKey: "recordingsDirectory") }
            if let previousKey { defaults.set(previousKey, forKey: "openrouterApiKey") }
            else { defaults.removeObject(forKey: "openrouterApiKey") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManualRollback-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        _ = try writeLibraryFixture(root: rootA, name: "Library A")
        _ = try writeLibraryFixture(root: rootB, name: "Library B")
        defaults.set(rootA.path, forKey: "recordingsDirectory")
        defaults.set("test", forKey: "openrouterApiKey")
        let recorder = AudioRecorder()
        let transcriptionManager = TranscriptionManager()
        let summaryManager = SummaryManager()
        let workflow = PostRecordingWorkflowCoordinator(defaults: defaults)
        let controller = LibrarySearchController(
            audioRecorder: recorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflow
        )
        let didLoad = await controller.reloadLibrary()
        XCTAssertTrue(didLoad)
        let transcript = try XCTUnwrap(transcriptionManager.transcripts.first)
        summaryManager.testSummaryOperation = { _, _, _ in
            try await Task.sleep(nanoseconds: 120_000_000)
            return "stale"
        }
        let staleTask = Task { try await summaryManager.generateSummary(for: transcript) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let summariesAURL = rootA.appendingPathComponent("WhisperNote/Files/Summaries/summaries.json")
        let summariesBURL = rootB.appendingPathComponent("WhisperNote/Files/Summaries/summaries.json")
        let aAtGate = try Data(contentsOf: summariesAURL)
        let bBefore = try Data(contentsOf: summariesBURL)
        controller.testPrepareFailure = true

        let didSwitch = await controller.selectLibrary(path: rootB.path, bookmark: nil)
        XCTAssertFalse(didSwitch)
        XCTAssertFalse(summaryManager.isLibraryRebinding)
        XCTAssertEqual(defaults.string(forKey: "recordingsDirectory"), rootA.path)
        do { _ = try await staleTask.value; XCTFail("Stale summary completed after rollback") }
        catch let error as SummaryError { guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: summariesAURL), aAtGate)
        XCTAssertEqual(try Data(contentsOf: summariesBURL), bBefore)

        summaryManager.testSummaryOperation = { _, _, _ in "fresh after rollback" }
        let fresh = try await summaryManager.generateSummary(for: transcript)
        XCTAssertEqual(fresh.content, "fresh after rollback")
        XCTAssertEqual(defaults.string(forKey: "recordingsDirectory"), rootA.path)
    }

    func testDelayedManualArtifactOperationsAreInvalidatedBeforeLibraryPreferenceFlip() async throws {
        let defaults = UserDefaults.standard
        let savedValues = [
            "recordingsDirectory",
            "recordingsDirectoryBookmark",
            "elevenlabsApiKey",
            "openrouterApiKey",
        ].reduce(into: [String: Any]()) { values, key in
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        defer {
            for key in ["recordingsDirectory", "recordingsDirectoryBookmark", "elevenlabsApiKey", "openrouterApiKey"] {
                if let value = savedValues[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManualRebind-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        _ = try writeLibraryFixture(root: rootA, name: "Library A")
        _ = try writeLibraryFixture(root: rootB, name: "Library B")
        defaults.set(rootA.path, forKey: "recordingsDirectory")
        defaults.set("test", forKey: "elevenlabsApiKey")
        defaults.set("test", forKey: "openrouterApiKey")

        let recorder = AudioRecorder()
        let transcriptionManager = TranscriptionManager()
        let summaryManager = SummaryManager()
        let workflow = PostRecordingWorkflowCoordinator(defaults: defaults)
        let controller = LibrarySearchController(
            audioRecorder: recorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflow
        )
        let didLoadA = await controller.reloadLibrary()
        XCTAssertTrue(didLoadA)
        let recording = try XCTUnwrap(recorder.recordings.first)
        let transcript = try XCTUnwrap(transcriptionManager.transcripts.first)
        transcriptionManager.testTranscriptionOperation = { _, _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return ("stale transcript", "stale transcript", nil)
        }
        summaryManager.testSummaryOperation = { _, _, _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return "stale summary"
        }

        let staleTranscriptTask = Task { try await transcriptionManager.transcribeRecording(recording) }
        let staleSummaryTask = Task { try await summaryManager.generateSummary(for: transcript) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let transcriptsAURL = rootA.appendingPathComponent("WhisperNote/Files/Transcripts/transcripts.json")
        let summariesAURL = rootA.appendingPathComponent("WhisperNote/Files/Summaries/summaries.json")
        let transcriptsBURL = rootB.appendingPathComponent("WhisperNote/Files/Transcripts/transcripts.json")
        let summariesBURL = rootB.appendingPathComponent("WhisperNote/Files/Summaries/summaries.json")
        let recordingsAURL = rootA.appendingPathComponent("WhisperNote/Files/Recordings/recordings.json")
        let recordingsBURL = rootB.appendingPathComponent("WhisperNote/Files/Recordings/recordings.json")
        let transcriptsAAtGate = try Data(contentsOf: transcriptsAURL)
        let summariesAAtGate = try Data(contentsOf: summariesAURL)
        let transcriptsBBefore = try Data(contentsOf: transcriptsBURL)
        let summariesBBefore = try Data(contentsOf: summariesBURL)
        let recordingsABefore = try Data(contentsOf: recordingsAURL)
        let recordingsBBefore = try Data(contentsOf: recordingsBURL)
        let groupID = UUID()
        recorder.recordings[0].groupId = groupID

        controller.testClosedGateDelayNanoseconds = 100_000_000
        let switchTask = Task { await controller.selectLibrary(path: rootB.path, bookmark: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(transcriptionManager.isLibraryRebinding)
        XCTAssertTrue(summaryManager.isLibraryRebinding)
        await recorder.deleteRecording(id: recording.id)
        await recorder.deleteGroup(groupId: groupID)
        XCTAssertEqual(recorder.recordings.count, 1)
        XCTAssertEqual(try Data(contentsOf: recordingsAURL), recordingsABefore)
        XCTAssertEqual(try Data(contentsOf: recordingsBURL), recordingsBBefore)
        do {
            _ = try await transcriptionManager.transcribeRecording(recording)
            XCTFail("A new manual transcription must be rejected while rebind gates are closed")
        } catch let error as TranscriptionError {
            guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await summaryManager.generateSummary(for: transcript)
            XCTFail("A new manual summary must be rejected while rebind gates are closed")
        } catch let error as SummaryError {
            guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let didSwitch = await switchTask.value
        XCTAssertTrue(didSwitch)
        do { _ = try await staleTranscriptTask.value; XCTFail("Stale transcription completed") }
        catch let error as TranscriptionError { guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") } }
        do { _ = try await staleSummaryTask.value; XCTFail("Stale summary completed") }
        catch let error as SummaryError { guard case .staleLibrary = error else { return XCTFail("Unexpected error: \(error)") } }

        XCTAssertEqual(try Data(contentsOf: transcriptsAURL), transcriptsAAtGate)
        XCTAssertEqual(try Data(contentsOf: summariesAURL), summariesAAtGate)
        XCTAssertEqual(try Data(contentsOf: transcriptsBURL), transcriptsBBefore)
        XCTAssertEqual(try Data(contentsOf: summariesBURL), summariesBBefore)
        XCTAssertEqual(try Data(contentsOf: recordingsAURL), recordingsABefore)
        XCTAssertEqual(try Data(contentsOf: recordingsBURL), recordingsBBefore)
        XCTAssertEqual(transcriptionManager.transcripts.map(\.name), ["Library B"])
        XCTAssertEqual(summaryManager.summaries.map(\.name), ["Library B"])
    }

    func testRejectedCandidateLeavesActiveLibraryAndCandidateBytesUntouched() async throws {
        let defaults = UserDefaults.standard
        let previousPath = defaults.object(forKey: "recordingsDirectory")
        let previousBookmark = defaults.object(forKey: "recordingsDirectoryBookmark")
        defer {
            if let previousPath { defaults.set(previousPath, forKey: "recordingsDirectory") }
            else { defaults.removeObject(forKey: "recordingsDirectory") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "recordingsDirectoryBookmark") }
            else { defaults.removeObject(forKey: "recordingsDirectoryBookmark") }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRollback-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        _ = try writeLibraryFixture(root: rootA, name: "Library A")
        _ = try writeLibraryFixture(root: rootB, name: "Library B")
        let corruptURL = rootB.appendingPathComponent("WhisperNote/Files/Transcripts/transcripts.json")
        let corruptBytes = Data("not-json".utf8)
        try corruptBytes.write(to: corruptURL)

        defaults.set(rootA.path, forKey: "recordingsDirectory")
        defaults.removeObject(forKey: "recordingsDirectoryBookmark")
        let recorder = AudioRecorder()
        let transcriptionManager = TranscriptionManager()
        let summaryManager = SummaryManager()
        let workflow = PostRecordingWorkflowCoordinator(defaults: defaults)
        let controller = LibrarySearchController(
            audioRecorder: recorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflow
        )
        let didLoadA = await controller.reloadLibrary()
        XCTAssertTrue(didLoadA)

        let didSelectB = await controller.selectLibrary(path: rootB.path, bookmark: nil)
        XCTAssertFalse(didSelectB)
        XCTAssertEqual(defaults.string(forKey: "recordingsDirectory"), rootA.path)
        XCTAssertEqual(recorder.recordings.map(\.name), ["Library A"])
        XCTAssertEqual(transcriptionManager.transcripts.map(\.name), ["Library A"])
        XCTAssertEqual(summaryManager.summaries.map(\.name), ["Library A"])
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
    }

    func testCoordinatedLibraryRebindKeepsPostSwitchMutationsInSelectedRoot() async throws {
        let defaults = UserDefaults.standard
        let previousPath = defaults.object(forKey: "recordingsDirectory")
        let previousBookmark = defaults.object(forKey: "recordingsDirectoryBookmark")
        defer {
            if let previousPath { defaults.set(previousPath, forKey: "recordingsDirectory") }
            else { defaults.removeObject(forKey: "recordingsDirectory") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "recordingsDirectoryBookmark") }
            else { defaults.removeObject(forKey: "recordingsDirectoryBookmark") }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRebind-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        let fixtureA = try writeLibraryFixture(root: rootA, name: "Library A")
        let fixtureB = try writeLibraryFixture(root: rootB, name: "Library B")

        defaults.set(rootA.path, forKey: "recordingsDirectory")
        defaults.removeObject(forKey: "recordingsDirectoryBookmark")
        let recorder = AudioRecorder()
        let transcriptionManager = TranscriptionManager()
        let summaryManager = SummaryManager()
        let workflow = PostRecordingWorkflowCoordinator(defaults: defaults)
        let controller = LibrarySearchController(
            audioRecorder: recorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflow
        )
        await controller.reloadLibrary()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.recordings.map(\.name), ["Library A"])
        XCTAssertEqual(transcriptionManager.transcripts.map(\.name), ["Library A"])
        XCTAssertEqual(summaryManager.summaries.map(\.name), ["Library A"])
        XCTAssertEqual(controller.metadata.tags.map(\.name), ["Library A tag"])
        XCTAssertEqual(workflow.jobs.map(\.recordingName), ["Library A"])

        let delayedImportSource = root.appendingPathComponent("delayed-import.m4a")
        try Data("audio".utf8).write(to: delayedImportSource)
        recorder.testImportDelayNanoseconds = 150_000_000
        recorder.importRecording(from: delayedImportSource)
        await Task.yield()
        defaults.set(rootB.path, forKey: "recordingsDirectory")
        await controller.reloadLibrary()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.recordings.map(\.name), ["Library B"])
        XCTAssertEqual(transcriptionManager.transcripts.map(\.name), ["Library B"])
        XCTAssertEqual(summaryManager.summaries.map(\.name), ["Library B"])
        XCTAssertEqual(controller.metadata.tags.map(\.name), ["Library B tag"])
        XCTAssertEqual(workflow.jobs.map(\.recordingName), ["Library B"])
        let recordingsInA = try JSONDecoder().decode(
            [Recording].self,
            from: Data(contentsOf: rootA.appendingPathComponent("WhisperNote/Files/Recordings/recordings.json"))
        )
        XCTAssertEqual(recordingsInA.map(\.name), ["Library A"])

        summaryManager.deleteSummary(id: fixtureB.summary.id)
        let summariesInA = try JSONDecoder().decode([Summary].self, from: Data(contentsOf: fixtureA.summariesURL))
        let summariesInB = try JSONDecoder().decode([Summary].self, from: Data(contentsOf: fixtureB.summariesURL))
        XCTAssertEqual(summariesInA.map(\.name), ["Library A"], "A must never be overwritten by a mutation in B")
        XCTAssertTrue(summariesInB.isEmpty)

        defaults.set(rootA.path, forKey: "recordingsDirectory")
        await controller.reloadLibrary()
        XCTAssertEqual(summaryManager.summaries.map(\.name), ["Library A"])
    }

    func testRouteResolverFindsGroupedAndUngroupedTargetsAndReportsMissingItems() {
        let groupID = UUID(), groupedID = UUID(), singleID = UUID()
        let grouped = Recording(id: groupedID, name: "Grouped", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/grouped"), groupId: groupID, groupName: "Group")
        let single = Recording(id: singleID, name: "Single", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/single"))

        XCTAssertEqual(RecordingRouteResolver.resolve(.recording(groupedID), recordings: [grouped, single]), .recording(id: groupedID, groupID: groupID))
        XCTAssertEqual(RecordingRouteResolver.resolve(.recording(singleID), recordings: [grouped, single]), .recording(id: singleID, groupID: nil))
        XCTAssertEqual(RecordingRouteResolver.resolve(.group(groupID), recordings: [grouped, single]), .group(id: groupID, highlightedRecordingID: groupedID))
        XCTAssertEqual(RecordingRouteResolver.resolve(.recording(UUID()), recordings: [grouped]), .missingRecording)
        XCTAssertEqual(RecordingRouteResolver.resolve(.group(UUID()), recordings: [grouped]), .missingGroup)
    }

    func testRecordingRoutesSelectTabAndConsumeOnlyMatchingDestination() {
        let router = AppNavigationRouter()
        let recordingID = UUID()
        router.openRecording(recordingID)

        XCTAssertEqual(router.selectedTab, 0)
        XCTAssertEqual(router.recordingID, recordingID)
        let firstRequestID = router.recordingRouteRequestID
        router.consumeRecordingRoute(UUID())
        XCTAssertEqual(router.recordingID, recordingID, "A missing row must preserve the pending route")
        router.consumeRecordingRoute(recordingID)
        XCTAssertNil(router.recordingID)

        router.openRecording(recordingID)
        XCTAssertEqual(router.recordingID, recordingID)
        XCTAssertNotEqual(
            router.recordingRouteRequestID,
            firstRequestID,
            "Opening the same destination again must create a fresh scroll/highlight request"
        )
    }

    func testGroupedRouteDoesNotDisturbExistingTranscriptAndSummaryRoutes() {
        let router = AppNavigationRouter()
        let transcriptID = UUID()
        let summaryID = UUID()
        let groupID = UUID()

        router.openTranscript(transcriptID)
        router.openSummary(summaryID)
        router.openRecordingGroup(groupID)

        XCTAssertEqual(router.selectedTab, 0)
        XCTAssertEqual(router.recordingGroupID, groupID)
        XCTAssertEqual(router.transcriptID, transcriptID)
        XCTAssertEqual(router.summaryID, summaryID)
        router.consumeRecordingGroupRoute(UUID())
        XCTAssertEqual(router.recordingGroupID, groupID)
        router.consumeRecordingGroupRoute(groupID)
        XCTAssertNil(router.recordingGroupID)
    }
}

private struct LibraryFixture {
    let summary: Summary
    let summariesURL: URL
}

@MainActor
private func writeLibraryFixture(root: URL, name: String) throws -> LibraryFixture {
    let base = root.appendingPathComponent("WhisperNote/Files", isDirectory: true)
    let recordingsDirectory = base.appendingPathComponent("Recordings", isDirectory: true)
    let transcriptsDirectory = base.appendingPathComponent("Transcripts", isDirectory: true)
    let summariesDirectory = base.appendingPathComponent("Summaries", isDirectory: true)
    let processingDirectory = base.appendingPathComponent("Processing", isDirectory: true)
    for directory in [recordingsDirectory, transcriptsDirectory, summariesDirectory, processingDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let recording = Recording(name: name, date: Date(), duration: 1, filePath: recordingsDirectory.appendingPathComponent("audio.m4a"))
    try Data("fixture audio".utf8).write(to: recording.filePath)
    let transcript = Transcript(name: name, date: Date(), content: name, recordingId: recording.id, status: .completed)
    let summary = Summary(name: name, date: Date(), content: name, transcriptId: transcript.id, model: "test", prompt: "", status: .completed)
    let job = ProcessingJob(
        recordingID: recording.id,
        recordingName: name,
        snapshot: .init(language: "eng", shouldSummarize: false, modelID: "test", templateID: "test", prompt: "", shouldNotify: false)
    )
    try JSONEncoder().encode([recording]).write(to: recordingsDirectory.appendingPathComponent("recordings.json"), options: .atomic)
    try JSONEncoder().encode([transcript]).write(to: transcriptsDirectory.appendingPathComponent("transcripts.json"), options: .atomic)
    let summariesURL = summariesDirectory.appendingPathComponent("summaries.json")
    try JSONEncoder().encode([summary]).write(to: summariesURL, options: .atomic)
    try JSONEncoder().encode([job]).write(to: processingDirectory.appendingPathComponent("processing-jobs.json"), options: .atomic)
    try JSONEncoder().encode(LibraryMetadataEnvelope(tags: [.init(name: "\(name) tag")]))
        .write(to: base.appendingPathComponent("library-metadata.json"), options: .atomic)
    return LibraryFixture(summary: summary, summariesURL: summariesURL)
}
