import Foundation
import SwiftUI

@MainActor
protocol WorkflowTranscribing: AnyObject {
    func transcript(id: UUID) -> Transcript?
    func transcribeForWorkflow(_ recording: Recording, transcriptID: UUID, language: String) async throws -> Transcript
}

@MainActor
protocol WorkflowSummarizing: AnyObject {
    func summary(id: UUID) -> Summary?
    func summarizeForWorkflow(_ transcript: Transcript, summaryID: UUID, prompt: String, model: String) async throws -> Summary
    func defaultWorkflowPrompt() -> String
}

extension TranscriptionManager: WorkflowTranscribing { }
extension SummaryManager: WorkflowSummarizing {
    func defaultWorkflowPrompt() -> String { getDefaultPrompt() }
}

@MainActor
final class PostRecordingWorkflowCoordinator: ObservableObject {
    @Published private(set) var jobs: [ProcessingJob] = []
    @Published private(set) var storeError: String?

    private var store: ProcessingJobStore
    private let notifier: any ProcessingNotifying
    private let defaults: UserDefaults
    private let credentialDebounceNanoseconds: UInt64
    private var transcriptionManager: (any WorkflowTranscribing)?
    private var summaryManager: (any WorkflowSummarizing)?
    private var recordings: () -> [Recording] = { [] }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptionCredentialTask: Task<Void, Never>?
    private var summaryCredentialTask: Task<Void, Never>?
    private var transcriptionCredentialGeneration = 0
    private var summaryCredentialGeneration = 0
    private var hasLoaded = false
    private let persistenceLease = ProcessingJobPersistenceLease()
    private var libraryGeneration = 0
    private(set) var isLibraryRebinding = false
    private var cancellationsPending: Set<UUID> = []

    init(
        store: ProcessingJobStore = ProcessingJobStore(),
        notifier: any ProcessingNotifying = NotificationService(),
        defaults: UserDefaults = .standard,
        credentialDebounceNanoseconds: UInt64 = 650_000_000
    ) {
        self.store = store
        self.notifier = notifier
        self.defaults = defaults
        self.credentialDebounceNanoseconds = credentialDebounceNanoseconds
    }

    func attach(
        transcriptionManager: any WorkflowTranscribing,
        summaryManager: any WorkflowSummarizing,
        recordings: @escaping () -> [Recording]
    ) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let store = store
        self.transcriptionManager = transcriptionManager
        self.summaryManager = summaryManager
        self.recordings = recordings
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let loadedJobs = try await store.load()
            guard generation == libraryGeneration, !isLibraryRebinding else { return }
            jobs = loadedJobs
            storeError = nil
            for job in jobs where shouldResumeOnAttach(job) { start(job.id) }
        } catch {
            guard generation == libraryGeneration, !isLibraryRebinding else { return }
            storeError = error.localizedDescription
        }
    }

    /// Called only for a live recording's successful, durable stop outcome.
    func recordingDidSave(_ recording: Recording) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let store = store
        guard defaults.bool(forKey: "autoTranscribeAfterRecording"), let summaryManager else { return }
        let snapshot = ProcessingJobSnapshot.defaults(defaults, prompt: summaryManager.defaultWorkflowPrompt())
        let proposed = ProcessingJob(recordingID: recording.id, recordingName: recording.name, snapshot: snapshot)
        do {
            let job = try await store.createIfAbsent(
                proposed,
                lease: persistenceLease,
                expectedGeneration: generation
            )
            guard generation == libraryGeneration, !isLibraryRebinding else { return }
            storeError = nil
            replaceLocally(job)
            start(job.id)
        } catch {
            guard generation == libraryGeneration, !isLibraryRebinding else { return }
            storeError = error.localizedDescription
        }
    }

    func retry(_ id: UUID) {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let store = store
        guard var job = jobs.first(where: { $0.id == id }), job.state.canRetry else { return }
        job.attempt += 1
        job.transition(to: .queued)
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            guard await self.persist(job, generation: generation, store: store), !Task.isCancelled else {
                self.tasks[id] = nil
                return
            }
            await self.run(id, generation: generation, store: store)
            self.tasks[id] = nil
        }
    }

    func cancel(_ id: UUID) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let store = store
        tasks[id]?.cancel()
        tasks[id] = nil
        guard var job = jobs.first(where: { $0.id == id }), !job.state.isTerminal else { return }
        guard cancellationsPending.insert(id).inserted else { return }
        defer {
            cancellationsPending.remove(id)
            if !isLibraryRebinding,
               let durableJob = jobs.first(where: { $0.id == id }),
               shouldResumeOnAttach(durableJob) {
                start(id)
            }
        }
        job.transition(to: .cancelled)
        _ = await persist(job, generation: generation, store: store)
    }

    func transcriptionCredentialDidChange() {
        guard !isLibraryRebinding else { return }
        transcriptionCredentialTask?.cancel()
        transcriptionCredentialGeneration += 1
        let generation = transcriptionCredentialGeneration
        let libraryGeneration = self.libraryGeneration
        transcriptionCredentialTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.transcriptionCredentialGeneration == generation {
                    self.transcriptionCredentialTask = nil
                }
            }
            try? await Task.sleep(nanoseconds: self.credentialDebounceNanoseconds)
            guard !Task.isCancelled,
                  !self.isLibraryRebinding,
                  self.libraryGeneration == libraryGeneration,
                  self.hasKey("elevenlabsApiKey") else { return }
            for job in self.jobs where job.state == .waitingForTranscriptionKey { self.start(job.id) }
        }
    }

    func summaryCredentialDidChange() {
        guard !isLibraryRebinding else { return }
        summaryCredentialTask?.cancel()
        summaryCredentialGeneration += 1
        let generation = summaryCredentialGeneration
        let libraryGeneration = self.libraryGeneration
        summaryCredentialTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.summaryCredentialGeneration == generation {
                    self.summaryCredentialTask = nil
                }
            }
            try? await Task.sleep(nanoseconds: self.credentialDebounceNanoseconds)
            guard !Task.isCancelled,
                  !self.isLibraryRebinding,
                  self.libraryGeneration == libraryGeneration,
                  self.hasKey("openrouterApiKey") else { return }
            for job in self.jobs where job.state == .waitingForSummaryKey { self.start(job.id) }
        }
    }

    func job(for recordingID: UUID) -> ProcessingJob? {
        jobs.first(where: { $0.recordingID == recordingID })
    }

    func waitForCurrentTasks() async {
        while true {
            let workflowTasks = Array(tasks.values)
            let credentialTasks = [transcriptionCredentialTask, summaryCredentialTask].compactMap { $0 }
            guard !workflowTasks.isEmpty || !credentialTasks.isEmpty else { return }
            for task in credentialTasks { await task.value }
            for task in workflowTasks { await task.value }
        }
    }

    /// Stops every writer tied to the previous library before DirectoryManager is
    /// allowed to feed the managers a newly selected root.
    func beginLibraryRebind() -> Bool {
        guard !isLibraryRebinding else { return false }
        isLibraryRebinding = true
        libraryGeneration = persistenceLease.invalidate()
        transcriptionCredentialGeneration += 1
        summaryCredentialGeneration += 1
        transcriptionCredentialTask?.cancel()
        summaryCredentialTask?.cancel()
        tasks.values.forEach { $0.cancel() }
        return true
    }

    func suspendForLibraryRebind() async {
        if !isLibraryRebinding { _ = beginLibraryRebind() }
        transcriptionCredentialTask?.cancel()
        summaryCredentialTask?.cancel()
        transcriptionCredentialTask = nil
        summaryCredentialTask = nil
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        for task in running { await task.value }
        tasks.removeAll()
    }

    func resumeAfterLibraryRebindCancellation() {
        isLibraryRebinding = false
        for job in jobs where !cancellationsPending.contains(job.id) && shouldResumeOnAttach(job) {
            start(job.id)
        }
    }

    func rebindStore(to fileURL: URL) async {
        guard isLibraryRebinding else { return }
        let generation = libraryGeneration
        let candidateStore = ProcessingJobStore(fileURL: fileURL)
        do {
            let loadedJobs = try await candidateStore.load()
            guard generation == libraryGeneration, isLibraryRebinding else { return }
            store = candidateStore
            jobs = loadedJobs
            storeError = nil
        } catch {
            guard generation == libraryGeneration, isLibraryRebinding else { return }
            jobs = []
            storeError = error.localizedDescription
        }
    }

    /// Publishes an already preflight-validated store. Jobs cannot start until this
    /// acceptance point, after every artifact manager has moved to the same root.
    func acceptLibrary(storeURL: URL, jobs acceptedJobs: [ProcessingJob]) {
        store = ProcessingJobStore(fileURL: storeURL)
        jobs = acceptedJobs.sorted { $0.createdAt > $1.createdAt }
        storeError = nil
    }

    func finishLibraryRebind() {
        isLibraryRebinding = false
        for job in jobs where !cancellationsPending.contains(job.id) && shouldResumeOnAttach(job) {
            start(job.id)
        }
    }

    private func start(_ id: UUID) {
        guard !isLibraryRebinding, !cancellationsPending.contains(id) else { return }
        let generation = libraryGeneration
        let store = store
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            await self?.run(id, generation: generation, store: store)
            self?.tasks[id] = nil
        }
    }

    private func run(_ id: UUID, generation: Int, store: ProcessingJobStore) async {
        guard generation == libraryGeneration, !isLibraryRebinding else { return }
        guard var job = jobs.first(where: { $0.id == id }), !job.state.isTerminal,
              let transcriptionManager, let summaryManager else { return }
        guard !Task.isCancelled else { return }

        guard let recording = recordings().first(where: { $0.id == job.recordingID }) else {
            job.transition(to: .waitingForRecording, failure: "The saved recording is not currently available.")
            _ = await persist(job, generation: generation, store: store)
            return
        }

        var transcript: Transcript
        if let existing = transcriptionManager.transcript(id: job.transcriptID), existing.status == .completed {
            transcript = existing
        } else {
            guard hasKey("elevenlabsApiKey") else {
                job.transition(to: .waitingForTranscriptionKey, failure: "Add an ElevenLabs API key in Settings to continue.")
                _ = await persist(job, generation: generation, store: store)
                return
            }
            job.transition(to: .transcribing)
            guard await persist(job, generation: generation, store: store), !Task.isCancelled else { return }
            do {
                transcript = try await transcriptionManager.transcribeForWorkflow(
                    recording, transcriptID: job.transcriptID, language: job.snapshot.language
                )
            } catch {
                guard !Task.isCancelled else { return }
                job.transition(to: .transcriptionFailed, failure: error.localizedDescription)
                _ = await persist(job, generation: generation, store: store)
                return
            }
        }

        if job.snapshot.shouldSummarize {
            if summaryManager.summary(id: job.summaryID)?.status != .completed {
                guard hasKey("openrouterApiKey") else {
                    job.transition(to: .waitingForSummaryKey, failure: "Add an OpenRouter API key in Settings to continue.")
                    _ = await persist(job, generation: generation, store: store)
                    return
                }
                job.transition(to: .summarizing)
                guard await persist(job, generation: generation, store: store), !Task.isCancelled else { return }
                do {
                    _ = try await summaryManager.summarizeForWorkflow(
                        transcript,
                        summaryID: job.summaryID,
                        prompt: job.snapshot.prompt,
                        model: job.snapshot.modelID
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    job.transition(to: .summaryFailed, failure: error.localizedDescription)
                    _ = await persist(job, generation: generation, store: store)
                    return
                }
            }
        }

        guard !Task.isCancelled else { return }
        job.transition(to: .completed)
        guard await persist(job, generation: generation, store: store) else { return }
        if job.snapshot.shouldNotify, job.notificationSentAt == nil {
            _ = await notifier.notifyCompletion(for: job)
            job.notificationSentAt = Date()
            _ = await persist(job, generation: generation, store: store)
        }
    }

    private func hasKey(_ key: String) -> Bool {
        !(defaults.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func persist(
        _ job: ProcessingJob,
        generation: Int? = nil,
        store capturedStore: ProcessingJobStore? = nil
    ) async -> Bool {
        guard !isLibraryRebinding else { return false }
        let expectedGeneration = generation ?? libraryGeneration
        let store = capturedStore ?? store
        guard expectedGeneration == libraryGeneration else { return false }
        if job.state != .cancelled, cancellationsPending.contains(job.id) { return false }
        if job.state != .cancelled,
           jobs.first(where: { $0.id == job.id })?.state == .cancelled {
            return false
        }
        do {
            try await store.save(
                job,
                lease: persistenceLease,
                expectedGeneration: expectedGeneration
            )
            guard expectedGeneration == libraryGeneration, !isLibraryRebinding else { return false }
            if job.state != .cancelled, cancellationsPending.contains(job.id) { return false }
            if job.state != .cancelled,
               jobs.first(where: { $0.id == job.id })?.state == .cancelled {
                return false
            }
            storeError = nil
            replaceLocally(job)
            return true
        } catch {
            guard expectedGeneration == libraryGeneration, !isLibraryRebinding else { return false }
            storeError = error.localizedDescription
            return false
        }
    }

    private func replaceLocally(_ job: ProcessingJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        jobs.sort { $0.createdAt > $1.createdAt }
    }

    private func shouldResumeOnAttach(_ job: ProcessingJob) -> Bool {
        if job.state.isAutomaticRelaunchState { return true }
        if job.state == .waitingForTranscriptionKey { return hasKey("elevenlabsApiKey") }
        if job.state == .waitingForSummaryKey { return hasKey("openrouterApiKey") }
        return false
    }
}
