import Foundation
import XCTest
@testable import WhisperNote

final class ProcessingJobTests: XCTestCase {
    func testDefaultsAreOffAndSummaryCannotRunWithoutTranscription() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "autoSummarizeAfterRecording")
        let snapshot = ProcessingJobSnapshot.defaults(defaults, prompt: "prompt")
        XCTAssertFalse(defaults.bool(forKey: "autoTranscribeAfterRecording"))
        XCTAssertFalse(snapshot.shouldSummarize)
        XCTAssertFalse(snapshot.shouldNotify)
        XCTAssertEqual(snapshot.templateID, ProcessingJobSnapshot.meetingMinutesTemplateID)
    }

    func testSnapshotFreezesLanguageModelTemplateAndPrompt() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        defaults.set(true, forKey: "autoSummarizeAfterRecording")
        defaults.set("pol", forKey: "autoTranscriptionLanguage")
        defaults.set("model-a", forKey: "autoSummaryModel")
        let snapshot = ProcessingJobSnapshot.defaults(defaults, prompt: "minutes-v1")
        defaults.set("eng", forKey: "autoTranscriptionLanguage")
        defaults.set("model-b", forKey: "autoSummaryModel")
        XCTAssertEqual(snapshot.language, "pol")
        XCTAssertEqual(snapshot.modelID, "model-a")
        XCTAssertEqual(snapshot.prompt, "minutes-v1")
        XCTAssertTrue(snapshot.shouldSummarize)
    }

    func testStateCapabilities() {
        XCTAssertTrue(ProcessingJobState.completed.isTerminal)
        XCTAssertTrue(ProcessingJobState.cancelled.isTerminal)
        XCTAssertTrue(ProcessingJobState.transcriptionFailed.canRetry)
        XCTAssertTrue(ProcessingJobState.waitingForSummaryKey.canRetry)
        XCTAssertFalse(ProcessingJobState.transcribing.canRetry)

        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var job = ProcessingJob(recordingID: UUID(), recordingName: "Test", snapshot: snapshot)
        XCTAssertTrue(job.transition(to: .transcribing))
        XCTAssertTrue(job.transition(to: .completed))
        XCTAssertFalse(job.transition(to: .queued))
        XCTAssertEqual(job.state, .completed)
    }

    func testArtifactUpsertPublishesOnlyAfterPersistenceForBothArtifactTypes() throws {
        let recordingID = UUID()
        let pendingTranscript = Transcript(name: "T", date: Date(), content: "", recordingId: recordingID, status: .inProgress)
        var completedTranscript = pendingTranscript
        completedTranscript.content = "done"
        completedTranscript.status = .completed
        var publishedTranscripts = [pendingTranscript]
        XCTAssertThrowsError(try ArtifactUpsertTransaction.commit(
            current: publishedTranscripts,
            artifact: completedTranscript,
            persist: { _ in throw TestFailure.expected },
            publish: { publishedTranscripts = $0 }
        ))
        XCTAssertEqual(publishedTranscripts.first?.status, .inProgress)

        let pendingSummary = Summary(name: "S", date: Date(), content: "", transcriptId: pendingTranscript.id, model: "m", prompt: "p", status: .inProgress)
        var completedSummary = pendingSummary
        completedSummary.content = "done"
        completedSummary.status = .completed
        var publishedSummaries = [pendingSummary]
        XCTAssertThrowsError(try ArtifactUpsertTransaction.commit(
            current: publishedSummaries,
            artifact: completedSummary,
            persist: { _ in throw TestFailure.expected },
            publish: { publishedSummaries = $0 }
        ))
        XCTAssertEqual(publishedSummaries.first?.status, .inProgress)

        var persistenceFinished = false
        try ArtifactUpsertTransaction.commit(
            current: publishedTranscripts,
            artifact: completedTranscript,
            persist: { _ in persistenceFinished = true },
            publish: {
                XCTAssertTrue(persistenceFinished)
                publishedTranscripts = $0
            }
        )
        XCTAssertEqual(publishedTranscripts.first?.status, .completed)
    }

    func testSharedLanguageCatalogRetainsFullElevenLabsSelection() {
        let languages = RecordingView.TranscriptionLanguageCatalog.all
        XCTAssertGreaterThan(languages.count, 80)
        XCTAssertEqual(Set(languages.map(\.0)).count, languages.count)
        XCTAssertTrue(languages.contains(where: { $0.0 == "eng" && $0.1 == "English" }))
        XCTAssertTrue(languages.contains(where: { $0.0 == "pol" && $0.1 == "Polish" }))
        XCTAssertTrue(languages.contains(where: { $0.0 == "zul" && $0.1 == "Zulu" }))
    }

    func testStoreRoundTripAndDedupeByRecordingID() async throws {
        let url = temporaryStoreURL()
        let store = ProcessingJobStore(fileURL: url)
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        let recordingID = UUID()
        let first = ProcessingJob(recordingID: recordingID, recordingName: "One", snapshot: snapshot)
        let duplicate = ProcessingJob(recordingID: recordingID, recordingName: "Two", snapshot: snapshot)
        let created = try await store.createIfAbsent(first)
        let deduplicated = try await store.createIfAbsent(duplicate)
        let loaded = try await store.load()
        XCTAssertEqual(created.id, first.id)
        XCTAssertEqual(deduplicated.id, first.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptStoreIsReportedAndNotOverwritten() async throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let store = ProcessingJobStore(fileURL: url)
        do {
            _ = try await store.load()
            XCTFail("Expected corrupt store error")
        } catch is ProcessingJobStoreError { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    @MainActor
    func testNavigationRoutesToArtifactsAndSettings() {
        let router = AppNavigationRouter()
        let transcriptID = UUID()
        router.openTranscript(transcriptID)
        XCTAssertEqual(router.selectedTab, 1)
        XCTAssertEqual(router.transcriptID, transcriptID)
        router.consumeTranscriptRoute(transcriptID)
        XCTAssertNil(router.transcriptID)
        let summaryID = UUID()
        router.openSummary(summaryID)
        XCTAssertEqual(router.selectedTab, 2)
        XCTAssertEqual(router.summaryID, summaryID)
        router.consumeSummaryRoute(summaryID)
        XCTAssertNil(router.summaryID)
        router.openSettings()
        XCTAssertEqual(router.selectedTab, 3)
    }

    @MainActor
    func testRoutesAreConsumedOnlyAfterMatchingArtifactAndCannotOverrideLaterManualSelection() {
        let router = AppNavigationRouter()
        let routedTranscript = UUID()
        let missingTranscript = UUID()
        router.openTranscript(routedTranscript)
        router.consumeTranscriptRoute(missingTranscript)
        XCTAssertEqual(router.transcriptID, routedTranscript, "A missing or mismatched artifact must leave the route pending")
        router.consumeTranscriptRoute(routedTranscript)
        XCTAssertNil(router.transcriptID)

        let manuallySelectedTranscript = UUID()
        var selection = manuallySelectedTranscript
        if let staleRoute = router.transcriptID { selection = staleRoute }
        XCTAssertEqual(selection, manuallySelectedTranscript, "Revisiting the tab must preserve manual selection after route consumption")

        let routedSummary = UUID()
        router.openSummary(routedSummary)
        router.consumeSummaryRoute(UUID())
        XCTAssertEqual(router.summaryID, routedSummary)
        router.consumeSummaryRoute(routedSummary)
        XCTAssertNil(router.summaryID)

        let manuallySelectedSummary = UUID()
        var summarySelection = manuallySelectedSummary
        if let staleRoute = router.summaryID { summarySelection = staleRoute }
        XCTAssertEqual(summarySelection, manuallySelectedSummary)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "ProcessingJobTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessingJobTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("processing-jobs.json")
    }
}

@MainActor
final class PostRecordingWorkflowCoordinatorTests: XCTestCase {
    func testDelayedCancelInvalidatedByRebindRollbackKeepsDurableStateAndResumes() async throws {
        let defaultsName = "CoordinatorCancelRollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let recording = Recording(name: "Resume after rollback", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/resume-after-rollback.m4a"))
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var waiting = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        waiting.transition(to: .waitingForTranscriptionKey)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("CancelRollback-\(UUID().uuidString)/jobs.json")
        try await ProcessingJobStore(fileURL: storeURL).save(waiting)
        let durableBytes = try Data(contentsOf: storeURL)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(
            store: ProcessingJobStore(fileURL: storeURL, saveDelayNanoseconds: 120_000_000),
            notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording] }
        )
        defaults.set("key", forKey: "elevenlabsApiKey")

        let cancelTask = Task { await coordinator.cancel(waiting.id) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(coordinator.beginLibraryRebind())
        await coordinator.suspendForLibraryRebind()
        XCTAssertEqual(try Data(contentsOf: storeURL), durableBytes)
        XCTAssertEqual(coordinator.jobs.first?.state, .waitingForTranscriptionKey)
        XCTAssertEqual(coordinator.jobs.first?.attempt, waiting.attempt)

        coordinator.resumeAfterLibraryRebindCancellation()
        await cancelTask.value
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(log.values, ["transcript"])
    }

    func testClosedRebindGateRejectsCallbacksAndInvalidatesDelayedStoreContinuation() async throws {
        let defaultsName = "CoordinatorRebindGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        defaults.set("key", forKey: "elevenlabsApiKey")
        defaults.set("key", forKey: "openrouterApiKey")
        let recording = Recording(name: "Existing", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/existing.m4a"))
        let newRecording = Recording(name: "Rejected", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/rejected.m4a"))
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var failed = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        failed.transition(to: .transcribing)
        failed.transition(to: .transcriptionFailed, failure: "failed")
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("RebindGate-\(UUID().uuidString)/jobs.json")
        try await ProcessingJobStore(fileURL: storeURL).save(failed)
        let bytesBefore = try Data(contentsOf: storeURL)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(
            store: ProcessingJobStore(fileURL: storeURL, saveDelayNanoseconds: 120_000_000),
            notifier: MockNotifier(),
            defaults: defaults,
            credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording, newRecording] }
        )

        coordinator.retry(failed.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(coordinator.beginLibraryRebind())
        await coordinator.recordingDidSave(newRecording)
        coordinator.retry(failed.id)
        await coordinator.cancel(failed.id)
        coordinator.transcriptionCredentialDidChange()
        coordinator.summaryCredentialDidChange()
        await coordinator.suspendForLibraryRebind()

        XCTAssertEqual(try Data(contentsOf: storeURL), bytesBefore)
        XCTAssertEqual(coordinator.jobs.count, 1)
        XCTAssertEqual(coordinator.jobs.first?.state, .transcriptionFailed)
        XCTAssertEqual(coordinator.jobs.first?.attempt, failed.attempt)
        XCTAssertTrue(log.values.isEmpty)
        coordinator.finishLibraryRebind()
    }

    func testHappyPathOrdersTranscriptBeforeSummaryAndDeduplicatesStop() async throws {
        let harness = await makeHarness(summarize: true, notify: false)
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        XCTAssertEqual(harness.coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(harness.log, ["transcript", "summary"])
        let job = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(harness.transcriber.lastID, job.transcriptID)
        XCTAssertEqual(harness.summarizer.lastID, job.summaryID)

        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        XCTAssertEqual(harness.coordinator.jobs.count, 1)
        XCTAssertEqual(harness.log, ["transcript", "summary"])
    }

    func testWorkflowCapturesDefaultTemplateOnceAndRetryIgnoresLaterTemplateChanges() async throws {
        let harness = await makeHarness(summarize: true, notify: false)
        let original = SummaryGenerationSnapshot(
            templateID: "custom-template-id",
            templateName: "Original template",
            prompt: "original frozen prompt",
            model: "original frozen model"
        )
        let provider = MockTemplateProvider(snapshot: original)
        harness.coordinator.attachTemplateProvider(provider)
        harness.summarizer.failNext = true

        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let failed = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .summaryFailed)
        XCTAssertEqual(failed.snapshot.templateID, original.templateID)
        XCTAssertEqual(failed.snapshot.templateName, original.templateName)
        XCTAssertEqual(failed.snapshot.prompt, original.prompt)
        XCTAssertEqual(failed.snapshot.modelID, original.model)
        XCTAssertEqual(provider.callCount, 1)

        provider.snapshot = SummaryGenerationSnapshot(
            templateID: SummaryTemplatePresetCatalog.meetingMinutesID,
            templateName: "Meeting Minutes",
            prompt: "replacement after edit or delete",
            model: "replacement-model"
        )
        harness.coordinator.retry(failed.id)
        await harness.coordinator.waitForCurrentTasks()

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(harness.summarizer.snapshots.last, original)
        XCTAssertEqual(harness.coordinator.jobs.first?.state, .completed)

        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        XCTAssertEqual(provider.callCount, 1)
    }

    func testOverlappingSavedCallbacksCoalesceSuspendedDefaultResolutionAndCreateOneJob() async throws {
        let harness = await makeHarness(summarize: true, notify: false)
        let expected = SummaryGenerationSnapshot(
            templateID: "coalesced-template",
            templateName: "Coalesced",
            prompt: "one deterministic prompt",
            model: "one deterministic model"
        )
        let provider = SuspendingTemplateProvider()
        harness.coordinator.attachTemplateProvider(provider)

        let first = Task { await harness.coordinator.recordingDidSave(harness.recording) }
        await provider.waitUntilCalled()
        let second = Task { await harness.coordinator.recordingDidSave(harness.recording) }
        await Task.yield()
        XCTAssertEqual(provider.callCount, 1)
        provider.resume(with: expected)
        await first.value
        await second.value
        await harness.coordinator.waitForCurrentTasks()

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(harness.coordinator.jobs.count, 1)
        let job = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(job.snapshot.templateID, expected.templateID)
        XCTAssertEqual(job.snapshot.templateName, expected.templateName)
        XCTAssertEqual(job.snapshot.prompt, expected.prompt)
        XCTAssertEqual(job.snapshot.modelID, expected.model)
    }

    func testRebindDrainsAdmittedSuspendedHandoffIntoOldStoreBeforeSuccessfulSwitch() async throws {
        let harness = await makeHarness(summarize: false, notify: false)
        let provider = SuspendingTemplateProvider()
        harness.coordinator.attachTemplateProvider(provider)
        let callback = Task { await harness.coordinator.recordingDidSave(harness.recording) }
        await provider.waitUntilCalled()

        XCTAssertTrue(harness.coordinator.beginLibraryRebind())
        let rejectedRecording = Recording(
            name: "After close",
            date: Date(),
            duration: 1,
            filePath: URL(fileURLWithPath: "/tmp/after-close.m4a")
        )
        await harness.coordinator.recordingDidSave(rejectedRecording)
        var suspendFinished = false
        let suspension = Task {
            await harness.coordinator.suspendForLibraryRebind()
            suspendFinished = true
        }
        await Task.yield()
        XCTAssertFalse(suspendFinished)

        let frozen = SummaryGenerationSnapshot(
            templateID: "old-library-template",
            templateName: "Old library",
            prompt: "old library prompt",
            model: "old library model"
        )
        provider.resume(with: frozen)
        await callback.value
        await suspension.value

        let oldJobs = try await ProcessingJobStore(fileURL: harness.storeURL).load()
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(oldJobs.count, 1)
        XCTAssertEqual(oldJobs.first?.recordingID, harness.recording.id)
        XCTAssertEqual(oldJobs.first?.snapshot.prompt, frozen.prompt)
        XCTAssertEqual(oldJobs.first?.state, .queued)

        let newStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorRebindTarget-\(UUID().uuidString)/jobs.json")
        harness.coordinator.acceptLibrary(storeURL: newStoreURL, jobs: [])
        harness.coordinator.finishLibraryRebind()
        XCTAssertTrue(harness.coordinator.jobs.isEmpty)
        let oldJobsAfterSwitch = try await ProcessingJobStore(fileURL: harness.storeURL).load()
        XCTAssertEqual(oldJobsAfterSwitch.count, 1)
    }

    func testRebindRollbackKeepsAndResumesAdmittedSuspendedHandoffInOldStore() async throws {
        let harness = await makeHarness(summarize: false, notify: false)
        let provider = SuspendingTemplateProvider()
        harness.coordinator.attachTemplateProvider(provider)
        let callback = Task { await harness.coordinator.recordingDidSave(harness.recording) }
        await provider.waitUntilCalled()
        XCTAssertTrue(harness.coordinator.beginLibraryRebind())
        let suspension = Task { await harness.coordinator.suspendForLibraryRebind() }
        await Task.yield()

        let frozen = SummaryGenerationSnapshot(
            templateID: "rollback-template",
            templateName: "Rollback",
            prompt: "rollback prompt",
            model: "rollback model"
        )
        provider.resume(with: frozen)
        await callback.value
        await suspension.value
        let oldJobsBeforeRollback = try await ProcessingJobStore(fileURL: harness.storeURL).load()
        XCTAssertEqual(oldJobsBeforeRollback.count, 1)

        harness.coordinator.resumeAfterLibraryRebindCancellation()
        await harness.coordinator.waitForCurrentTasks()

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(harness.coordinator.jobs.count, 1)
        XCTAssertEqual(harness.coordinator.jobs.first?.state, .completed)
        let durable = try await ProcessingJobStore(fileURL: harness.storeURL).load()
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(durable.first?.state, .completed)
        XCTAssertEqual(durable.first?.snapshot.prompt, frozen.prompt)
    }

    func testRelaunchedRetryUsesDurableTemplateSnapshotWithoutResolvingCurrentDefault() async throws {
        let harness = await makeHarness(summarize: true, notify: false)
        let original = SummaryGenerationSnapshot(
            templateID: "deleted-custom-id",
            templateName: "Deleted custom",
            prompt: "durable prompt",
            model: "durable model"
        )
        let initialProvider = MockTemplateProvider(snapshot: original)
        harness.coordinator.attachTemplateProvider(initialProvider)
        harness.summarizer.failNext = true
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let failed = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .summaryFailed)

        let log = WorkflowCallLog()
        let transcriber = MockTranscriber(log: log)
        let summarizer = MockSummarizer(log: log)
        let currentProvider = MockTemplateProvider(snapshot: SummaryGenerationSnapshot(
            templateID: SummaryTemplatePresetCatalog.meetingMinutesID,
            templateName: "Meeting Minutes",
            prompt: "current prompt",
            model: "current model"
        ))
        let relaunched = PostRecordingWorkflowCoordinator(
            store: ProcessingJobStore(fileURL: harness.storeURL),
            notifier: MockNotifier(),
            defaults: harness.defaults,
            credentialDebounceNanoseconds: 0
        )
        relaunched.attachTemplateProvider(currentProvider)
        await relaunched.attach(
            transcriptionManager: transcriber,
            summaryManager: summarizer,
            recordings: { [harness.recording] }
        )
        relaunched.retry(failed.id)
        await relaunched.waitForCurrentTasks()

        XCTAssertEqual(currentProvider.callCount, 0)
        XCTAssertEqual(summarizer.snapshots.last, original)
        XCTAssertEqual(relaunched.jobs.first?.state, .completed)
    }

    func testMissingKeysWaitThenRetryWithSameArtifactID() async throws {
        let harness = await makeHarness(summarize: false, notify: false, keys: false)
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let waiting = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(waiting.state, .waitingForTranscriptionKey)
        harness.defaults.set("key", forKey: "elevenlabsApiKey")
        harness.coordinator.retry(waiting.id)
        await harness.coordinator.waitForCurrentTasks()
        let completed = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.transcriptID, waiting.transcriptID)
    }

    func testFailureRetryReusesStableTranscriptID() async throws {
        let harness = await makeHarness(summarize: false, notify: false)
        harness.transcriber.failNext = true
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let failed = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .transcriptionFailed)
        harness.coordinator.retry(failed.id)
        await harness.coordinator.waitForCurrentTasks()
        XCTAssertEqual(harness.coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(harness.transcriber.ids, [failed.transcriptID, failed.transcriptID])
    }

    func testDeniedNotificationNeverFailsCompletedPipeline() async throws {
        let harness = await makeHarness(summarize: false, notify: true)
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let job = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(job.state, .completed)
        XCTAssertNotNil(job.notificationSentAt)
        let notificationCount = await harness.notifier.deliveryCount()
        XCTAssertEqual(notificationCount, 1)
    }

    func testRelaunchSkipsCompletedArtifactAndFinishesTransientJob() async throws {
        let defaultsName = "CoordinatorRelaunchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set("key", forKey: "elevenlabsApiKey")
        let recording = Recording(name: "Relaunch", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/relaunch.m4a"))
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var job = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        job.transition(to: .transcribing)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("Relaunch-\(UUID().uuidString)/jobs.json")
        let store = ProcessingJobStore(fileURL: storeURL)
        try await store.save(job)
        let log = WorkflowCallLog()
        let transcriber = MockTranscriber(log: log)
        transcriber.artifacts[job.transcriptID] = Transcript(
            id: job.transcriptID, name: recording.name, date: Date(), content: "durable",
            recordingId: recording.id, status: .completed
        )
        let coordinator = PostRecordingWorkflowCoordinator(store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0)
        await coordinator.attach(
            transcriptionManager: transcriber,
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording] }
        )
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(coordinator.jobs.first?.state, .completed)
        XCTAssertTrue(transcriber.ids.isEmpty)
    }

    func testSummaryFailureRetryReusesSummaryIDWithoutRetranscribing() async throws {
        let harness = await makeHarness(summarize: true, notify: false)
        harness.summarizer.failNext = true
        await harness.coordinator.recordingDidSave(harness.recording)
        await harness.coordinator.waitForCurrentTasks()
        let failed = try XCTUnwrap(harness.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .summaryFailed)
        harness.coordinator.retry(failed.id)
        await harness.coordinator.waitForCurrentTasks()
        XCTAssertEqual(harness.coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(harness.transcriber.ids.count, 1)
        XCTAssertEqual(harness.summarizer.ids, [failed.summaryID, failed.summaryID])
    }

    func testMissingRecordingWaitsAndCanBeCancelled() async throws {
        let defaultsName = "CoordinatorMissingRecording.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        defaults.set("key", forKey: "elevenlabsApiKey")
        let recording = Recording(name: "Missing", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/missing.m4a"))
        let log = WorkflowCallLog()
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("Missing-\(UUID().uuidString)/jobs.json")
        let coordinator = PostRecordingWorkflowCoordinator(
            store: ProcessingJobStore(fileURL: storeURL),
            notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [] }
        )
        await coordinator.recordingDidSave(recording)
        await coordinator.waitForCurrentTasks()
        let waiting = try XCTUnwrap(coordinator.jobs.first)
        XCTAssertEqual(waiting.state, .waitingForRecording)
        await coordinator.cancel(waiting.id)
        XCTAssertEqual(coordinator.jobs.first?.state, .cancelled)
        XCTAssertTrue(log.values.isEmpty)
        let reloaded = try await ProcessingJobStore(fileURL: storeURL).load()
        XCTAssertEqual(reloaded.first?.state, .cancelled)
    }

    func testFailedJobsStayIdleOnAttachAndCredentialChangesUntilExplicitRetry() async throws {
        let defaultsName = "CoordinatorFailedRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set("key", forKey: "elevenlabsApiKey")
        defaults.set("key", forKey: "openrouterApiKey")
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: true, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        let firstRecording = Recording(name: "Transcript failure", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/first.m4a"))
        let secondRecording = Recording(name: "Summary failure", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/second.m4a"))
        var transcriptionFailed = ProcessingJob(recordingID: firstRecording.id, recordingName: firstRecording.name, snapshot: snapshot)
        transcriptionFailed.transition(to: .transcribing)
        transcriptionFailed.transition(to: .transcriptionFailed, failure: "failed")
        var summaryFailed = ProcessingJob(recordingID: secondRecording.id, recordingName: secondRecording.name, snapshot: snapshot)
        summaryFailed.transition(to: .transcribing)
        summaryFailed.transition(to: .summarizing)
        summaryFailed.transition(to: .summaryFailed, failure: "failed")
        let store = ProcessingJobStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("FailedRelaunch-\(UUID().uuidString)/jobs.json"))
        try await store.save(transcriptionFailed)
        try await store.save(summaryFailed)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0)
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [firstRecording, secondRecording] }
        )
        await coordinator.waitForCurrentTasks()
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertEqual(Set(coordinator.jobs.map(\.state)), [.transcriptionFailed, .summaryFailed])

        coordinator.transcriptionCredentialDidChange()
        coordinator.summaryCredentialDidChange()
        await coordinator.waitForCurrentTasks()
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertEqual(Set(coordinator.jobs.map(\.state)), [.transcriptionFailed, .summaryFailed])

        coordinator.retry(transcriptionFailed.id)
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(log.values, ["transcript", "summary"])
        XCTAssertEqual(coordinator.jobs.first(where: { $0.id == transcriptionFailed.id })?.state, .completed)
        XCTAssertEqual(coordinator.jobs.first(where: { $0.id == summaryFailed.id })?.state, .summaryFailed)
    }

    func testCredentialResumeOnlyStartsMatchingWaitingStateWhenKeyIsNonempty() async throws {
        let defaultsName = "CoordinatorCredentialResume.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let recording = Recording(name: "Waiting", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/waiting.m4a"))
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var waiting = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        waiting.transition(to: .waitingForTranscriptionKey)
        let store = ProcessingJobStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("CredentialResume-\(UUID().uuidString)/jobs.json"))
        try await store.save(waiting)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0)
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording] }
        )
        coordinator.transcriptionCredentialDidChange()
        await coordinator.waitForCurrentTasks()
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertEqual(coordinator.jobs.first?.state, .waitingForTranscriptionKey)

        defaults.set("key", forKey: "elevenlabsApiKey")
        coordinator.transcriptionCredentialDidChange()
        coordinator.transcriptionCredentialDidChange()
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(log.values, ["transcript"])
        XCTAssertEqual(coordinator.jobs.first?.state, .completed)
    }

    func testAttachResumesBothWaitingKeyStagesOnlyWhenMatchingKeysExist() async throws {
        let defaultsName = "CoordinatorAttachWaitingKeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set("elevenlabs", forKey: "elevenlabsApiKey")
        defaults.set("openrouter", forKey: "openrouterApiKey")
        let transcriptRecording = Recording(name: "Needs transcript", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/transcript.m4a"))
        let summaryRecording = Recording(name: "Needs summary", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/summary.m4a"))
        let transcriptSnapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        let summarySnapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: true, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var transcriptJob = ProcessingJob(recordingID: transcriptRecording.id, recordingName: transcriptRecording.name, snapshot: transcriptSnapshot)
        transcriptJob.transition(to: .waitingForTranscriptionKey)
        var summaryJob = ProcessingJob(recordingID: summaryRecording.id, recordingName: summaryRecording.name, snapshot: summarySnapshot)
        summaryJob.transition(to: .waitingForSummaryKey)
        let store = ProcessingJobStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("AttachWaitingKeys-\(UUID().uuidString)/jobs.json"))
        try await store.save(transcriptJob)
        try await store.save(summaryJob)
        let log = WorkflowCallLog()
        let transcriber = MockTranscriber(log: log)
        transcriber.artifacts[summaryJob.transcriptID] = Transcript(
            id: summaryJob.transcriptID, name: summaryRecording.name, date: Date(), content: "durable",
            recordingId: summaryRecording.id, status: .completed
        )
        let summarizer = MockSummarizer(log: log)
        let coordinator = PostRecordingWorkflowCoordinator(
            store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(
            transcriptionManager: transcriber,
            summaryManager: summarizer,
            recordings: { [transcriptRecording, summaryRecording] }
        )
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(transcriber.ids, [transcriptJob.transcriptID])
        XCTAssertEqual(summarizer.ids, [summaryJob.summaryID])
        XCTAssertTrue(coordinator.jobs.allSatisfy { $0.state == .completed })
    }

    func testCredentialDebounceCancelsFirstCharacterResume() async throws {
        let defaultsName = "CoordinatorCredentialDebounce.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let recording = Recording(name: "Debounced", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/debounced.m4a"))
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        var waiting = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        waiting.transition(to: .waitingForTranscriptionKey)
        let store = ProcessingJobStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("CredentialDebounce-\(UUID().uuidString)/jobs.json"))
        try await store.save(waiting)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(
            store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 50_000_000
        )
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording] }
        )
        defaults.set("f", forKey: "elevenlabsApiKey")
        coordinator.transcriptionCredentialDidChange()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(log.values.isEmpty)
        defaults.set("final-key", forKey: "elevenlabsApiKey")
        coordinator.transcriptionCredentialDidChange()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(log.values.isEmpty)
        await coordinator.waitForCurrentTasks()
        XCTAssertEqual(log.values, ["transcript"])
    }

    func testCancelledJobRejectsStaleInFlightPersistenceBeforeAndAfterAwait() async throws {
        let defaultsName = "CoordinatorCancelRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let snapshot = ProcessingJobSnapshot(language: "eng", shouldSummarize: false, modelID: "m", templateID: "t", prompt: "p", shouldNotify: false)
        let recording = Recording(name: "Cancel race", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/cancel-race.m4a"))
        var stale = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        stale.transition(to: .waitingForRecording)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("CancelRace-\(UUID().uuidString)/jobs.json")
        let store = ProcessingJobStore(fileURL: storeURL, saveDelayNanoseconds: 50_000_000)
        try await store.save(stale)
        let log = WorkflowCallLog()
        let coordinator = PostRecordingWorkflowCoordinator(
            store: store, notifier: MockNotifier(), defaults: defaults, credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(
            transcriptionManager: MockTranscriber(log: log),
            summaryManager: MockSummarizer(log: log),
            recordings: { [recording] }
        )
        let staleSave = Task { await coordinator.persist(stale) }
        try await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.cancel(stale.id)
        let staleSaveAccepted = await staleSave.value
        XCTAssertFalse(staleSaveAccepted)
        XCTAssertEqual(coordinator.jobs.first?.state, .cancelled)
        let reloaded = try await ProcessingJobStore(fileURL: storeURL).load()
        XCTAssertEqual(reloaded.first?.state, .cancelled)
        let secondStaleSaveAccepted = await coordinator.persist(stale)
        XCTAssertFalse(secondStaleSaveAccepted)
    }

    private func makeHarness(summarize: Bool, notify: Bool, keys: Bool = true) async -> Harness {
        let defaultsName = "CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        defaults.set(summarize, forKey: "autoSummarizeAfterRecording")
        defaults.set(notify, forKey: "processingCompletionNotifications")
        if keys {
            defaults.set("key", forKey: "elevenlabsApiKey")
            defaults.set("key", forKey: "openrouterApiKey")
        }
        let recording = Recording(name: "Test", date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/test.m4a"))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorTests-\(UUID().uuidString)")
            .appendingPathComponent("jobs.json")
        let log = WorkflowCallLog()
        let transcriber = MockTranscriber(log: log)
        let summarizer = MockSummarizer(log: log)
        let notifier = MockNotifier()
        let coordinator = PostRecordingWorkflowCoordinator(
            store: ProcessingJobStore(fileURL: storeURL), notifier: notifier, defaults: defaults,
            credentialDebounceNanoseconds: 0
        )
        await coordinator.attach(transcriptionManager: transcriber, summaryManager: summarizer, recordings: { [recording] })
        return Harness(coordinator: coordinator, transcriber: transcriber, summarizer: summarizer, notifier: notifier, defaults: defaults, recording: recording, storeURL: storeURL, logObject: log)
    }
}

@MainActor
private final class WorkflowCallLog {
    var values: [String] = []
}

@MainActor
private final class MockTranscriber: WorkflowTranscribing {
    var artifacts: [UUID: Transcript] = [:]
    var ids: [UUID] = []
    var failNext = false
    let log: WorkflowCallLog
    init(log: WorkflowCallLog) { self.log = log }
    var lastID: UUID? { ids.last }
    func transcript(id: UUID) -> Transcript? { artifacts[id] }
    func transcribeForWorkflow(_ recording: Recording, transcriptID: UUID, language: String) async throws -> Transcript {
        ids.append(transcriptID); log.values.append("transcript")
        if failNext { failNext = false; throw TestFailure.expected }
        let result = Transcript(id: transcriptID, name: recording.name, date: Date(), content: "text", recordingId: recording.id, status: .completed)
        artifacts[transcriptID] = result
        return result
    }
}

@MainActor
private final class MockSummarizer: WorkflowSummarizing {
    var artifacts: [UUID: Summary] = [:]
    var ids: [UUID] = []
    var failNext = false
    var snapshots: [SummaryGenerationSnapshot] = []
    let log: WorkflowCallLog
    init(log: WorkflowCallLog) { self.log = log }
    var lastID: UUID? { ids.last }
    func summary(id: UUID) -> Summary? { artifacts[id] }
    func defaultWorkflowPrompt() -> String { "Meeting minutes" }
    func summarizeForWorkflow(_ transcript: Transcript, summaryID: UUID, prompt: String, model: String) async throws -> Summary {
        ids.append(summaryID); log.values.append("summary")
        if failNext { failNext = false; throw TestFailure.expected }
        let result = Summary(id: summaryID, name: transcript.name, date: Date(), content: "summary", transcriptId: transcript.id, model: model, prompt: prompt, status: .completed)
        artifacts[summaryID] = result
        return result
    }
    func summarizeForWorkflow(_ transcript: Transcript, summaryID: UUID, snapshot: SummaryGenerationSnapshot) async throws -> Summary {
        snapshots.append(snapshot)
        return try await summarizeForWorkflow(
            transcript,
            summaryID: summaryID,
            prompt: snapshot.prompt,
            model: snapshot.model
        )
    }
}

@MainActor
private final class MockTemplateProvider: WorkflowTemplateProviding {
    var snapshot: SummaryGenerationSnapshot
    var callCount = 0
    init(snapshot: SummaryGenerationSnapshot) { self.snapshot = snapshot }
    func defaultSelectionSnapshot(model: String) async -> SummaryGenerationSnapshot {
        callCount += 1
        return snapshot
    }
}

@MainActor
private final class SuspendingTemplateProvider: WorkflowTemplateProviding {
    private var continuation: CheckedContinuation<SummaryGenerationSnapshot, Never>?
    private(set) var callCount = 0

    func defaultSelectionSnapshot(model: String) async -> SummaryGenerationSnapshot {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilCalled() async {
        while continuation == nil { await Task.yield() }
    }

    func resume(with snapshot: SummaryGenerationSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private actor MockNotifier: ProcessingNotifying {
    var count = 0
    func notifyCompletion(for job: ProcessingJob) async -> ProcessingNotificationResult {
        count += 1
        return .denied
    }
    func deliveryCount() -> Int { count }
}

private enum TestFailure: Error { case expected }

@MainActor
private struct Harness {
    let coordinator: PostRecordingWorkflowCoordinator
    let transcriber: MockTranscriber
    let summarizer: MockSummarizer
    let notifier: MockNotifier
    let defaults: UserDefaults
    let recording: Recording
    let storeURL: URL
    let logObject: WorkflowCallLog
    var log: [String] { logObject.values }
}
