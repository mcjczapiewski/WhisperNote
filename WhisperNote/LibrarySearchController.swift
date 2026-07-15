import Combine
import Foundation

struct LibrarySearchSnapshot: Sendable {
    let recordings: [Recording]
    let transcripts: [Transcript]
    let summaries: [Summary]
    let jobs: [ProcessingJob]
}

private struct LibraryCandidateSnapshot: Sendable {
    let baseURL: URL
    let recordingsURL: URL
    let transcriptsURL: URL
    let summariesURL: URL
    let jobsURL: URL
    let metadataURL: URL
    let recordings: [Recording]
    let transcripts: [Transcript]
    let summaries: [Summary]
    let jobs: [ProcessingJob]
}

enum LibraryRebindError: LocalizedError {
    case recordingInProgress
    case unreadableArtifacts(Error)

    var errorDescription: String? {
        switch self {
        case .recordingInProgress:
            return "Stop the current recording before changing the library location."
        case .unreadableArtifacts(let error):
            return "The selected library could not be loaded and was left read-only: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class LibrarySearchController: ObservableObject {
    @Published private(set) var metadata = LibraryMetadataEnvelope()
    @Published private(set) var index = UnifiedSearchIndex(
        recordings: [], transcripts: [], summaries: [], jobs: [], metadata: .init()
    )
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRebuilding = false
    @Published private(set) var isRebinding = false

    private var repository: LibraryMetadataRepository
    private let audioRecorder: AudioRecorder
    private let transcriptionManager: TranscriptionManager
    private let summaryManager: SummaryManager
    private let workflowCoordinator: PostRecordingWorkflowCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var rebuildTask: Task<Void, Never>?
    private var generation = 0
    private var restrictJobsToCurrentRecordings = false
    private var pendingRebindError: String?
    private var metadataMutationsInFlight = 0
    private var metadataDrainWaiters: [CheckedContinuation<Void, Never>] = []
    var testClosedGateDelayNanoseconds: UInt64 = 0
    var testPrepareFailure = false

    init(
        audioRecorder: AudioRecorder,
        transcriptionManager: TranscriptionManager,
        summaryManager: SummaryManager,
        workflowCoordinator: PostRecordingWorkflowCoordinator,
        repository: LibraryMetadataRepository? = nil
    ) {
        self.audioRecorder = audioRecorder
        self.transcriptionManager = transcriptionManager
        self.summaryManager = summaryManager
        self.workflowCoordinator = workflowCoordinator
        self.repository = repository ?? LibraryMetadataRepository()
        subscribe()
        scheduleRebuild(delayNanoseconds: 0)
    }

    deinit { rebuildTask?.cancel() }

    func results(for query: UnifiedSearchQuery) -> [UnifiedSearchResult] {
        index.search(query)
    }

    func metadata(for key: LibraryItemKey) -> LibraryItemMetadata {
        metadata.items.first(where: { $0.key == key }) ?? LibraryItemMetadata(key: key)
    }

    func setFavorite(_ value: Bool, for key: LibraryItemKey) async {
        let repository = repository
        await mutate { try await repository.setFavorite(value, for: key) }
    }

    func assignTag(_ tagID: UUID, to key: LibraryItemKey) async {
        let repository = repository
        await mutate { try await repository.assignTag(id: tagID, to: key) }
    }

    func removeTag(_ tagID: UUID, from key: LibraryItemKey) async {
        let repository = repository
        await mutate { try await repository.removeTag(id: tagID, from: key) }
    }

    func createTag(named name: String, assigningTo key: LibraryItemKey? = nil) async {
        let repository = repository
        await mutate {
            let tag = try await repository.createTag(name: name)
            if let key { try await repository.assignTag(id: tag.id, to: key) }
        }
    }

    func renameTag(_ id: UUID, to name: String) async {
        let repository = repository
        await mutate { _ = try await repository.renameTag(id: id, to: name) }
    }

    func deleteTag(_ id: UUID) async {
        let repository = repository
        await mutate { try await repository.deleteTag(id: id) }
    }

    func clearError() { errorMessage = nil }

    /// The single live-library switch boundary. Old workflow writers are stopped
    /// before every artifact store, job store, metadata sidecar, and search projection
    /// moves to the newly selected DirectoryManager root.
    @discardableResult
    func reloadLibrary() async -> Bool {
        guard !isRebinding else { return false }
        guard audioRecorder.currentRecording == nil,
              !audioRecorder.isStartingRecording,
              !audioRecorder.isStoppingRecording else {
            errorMessage = LibraryRebindError.recordingInProgress.localizedDescription
            return false
        }
        do {
            let candidate = try Self.preflight(
                baseURL: DirectoryManager.shared.candidateBaseDirectory(
                    selectedRootPath: UserDefaults.standard.string(forKey: "recordingsDirectory")
                )
            )
            guard await closeLibraryMutationGates() else {
                throw LibraryRebindError.recordingInProgress
            }
            do {
                if testPrepareFailure { throw CocoaError(.fileWriteUnknown) }
                try Self.prepareDirectories(for: candidate)
            } catch {
                reopenPreviousLibraryAfterRollback()
                throw error
            }
            await acceptPreflighted(candidate)
            return true
        } catch {
            errorMessage = LibraryRebindError.unreadableArtifacts(error).localizedDescription
            return false
        }
    }

    /// Applies location preferences only after the recording lifecycle is idle, then
    /// immediately enters the coordinated rebind before any further UI mutation.
    @discardableResult
    func selectLibrary(path: String?, bookmark: Data?) async -> Bool {
        guard audioRecorder.currentRecording == nil,
              !audioRecorder.isStartingRecording,
              !audioRecorder.isStoppingRecording,
              !isRebinding else {
            errorMessage = LibraryRebindError.recordingInProgress.localizedDescription
            return false
        }
        let defaults = UserDefaults.standard
        let candidateBase = DirectoryManager.shared.candidateBaseDirectory(selectedRootPath: path)
        let candidate: LibraryCandidateSnapshot
        do {
            candidate = try Self.preflight(baseURL: candidateBase)
        } catch {
            errorMessage = "The selected library could not be loaded; the previous library remains active."
            return false
        }
        guard await closeLibraryMutationGates() else {
            errorMessage = LibraryRebindError.recordingInProgress.localizedDescription
            return false
        }
        do {
            if testPrepareFailure { throw CocoaError(.fileWriteUnknown) }
            try Self.prepareDirectories(for: candidate)
        } catch {
            reopenPreviousLibraryAfterRollback()
            errorMessage = "The selected library is not writable; the previous library remains active."
            return false
        }
        if let path, !path.isEmpty {
            defaults.set(path, forKey: "recordingsDirectory")
            if let bookmark { defaults.set(bookmark, forKey: "recordingsDirectoryBookmark") }
            else { defaults.removeObject(forKey: "recordingsDirectoryBookmark") }
        } else {
            defaults.removeObject(forKey: "recordingsDirectory")
            defaults.removeObject(forKey: "recordingsDirectoryBookmark")
        }
        await acceptPreflighted(candidate)
        return true
    }

    private func acceptPreflighted(_ candidate: LibraryCandidateSnapshot) async {
        await audioRecorder.acceptLibrary(
            recordings: candidate.recordings,
            recordingsDirectory: candidate.recordingsURL.deletingLastPathComponent()
        )
        transcriptionManager.acceptLibrary(
            transcripts: candidate.transcripts,
            transcriptsDirectory: candidate.transcriptsURL.deletingLastPathComponent()
        )
        summaryManager.acceptLibrary(
            summaries: candidate.summaries,
            summariesDirectory: candidate.summariesURL.deletingLastPathComponent()
        )
        repository = LibraryMetadataRepository(fileURL: candidate.metadataURL)
        workflowCoordinator.acceptLibrary(storeURL: candidate.jobsURL, jobs: candidate.jobs)
        restrictJobsToCurrentRecordings = false
        transcriptionManager.finishLibraryRebind()
        summaryManager.finishLibraryRebind()
        audioRecorder.finishLibraryRebind()
        workflowCoordinator.finishLibraryRebind()
        isRebinding = false
        scheduleRebuild(delayNanoseconds: 0)
    }

    private func closeLibraryMutationGates() async -> Bool {
        guard audioRecorder.beginLibraryRebind() else { return false }
        guard transcriptionManager.beginLibraryRebind() else {
            audioRecorder.finishLibraryRebind()
            return false
        }
        guard summaryManager.beginLibraryRebind() else {
            transcriptionManager.finishLibraryRebind()
            audioRecorder.finishLibraryRebind()
            return false
        }
        guard workflowCoordinator.beginLibraryRebind() else {
            summaryManager.finishLibraryRebind()
            transcriptionManager.finishLibraryRebind()
            audioRecorder.finishLibraryRebind()
            return false
        }
        isRebinding = true
        rebuildTask?.cancel()
        await audioRecorder.waitForDeletionActionsToDrain()
        await waitForMetadataMutationsToDrain()
        await workflowCoordinator.suspendForLibraryRebind()
        if testClosedGateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: testClosedGateDelayNanoseconds)
        }
        return true
    }

    private func reopenPreviousLibraryAfterRollback() {
        transcriptionManager.finishLibraryRebind()
        summaryManager.finishLibraryRebind()
        audioRecorder.finishLibraryRebind()
        isRebinding = false
        workflowCoordinator.resumeAfterLibraryRebindCancellation()
        scheduleRebuild(delayNanoseconds: 0)
    }

    private func waitForMetadataMutationsToDrain() async {
        guard metadataMutationsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            metadataDrainWaiters.append(continuation)
        }
    }

    nonisolated private static func preflight(baseURL: URL) throws -> LibraryCandidateSnapshot {
        try validateWritableAncestor(for: baseURL)
        let recordingsURL = baseURL.appendingPathComponent("Recordings/recordings.json")
        let transcriptsURL = baseURL.appendingPathComponent("Transcripts/transcripts.json")
        let summariesURL = baseURL.appendingPathComponent("Summaries/summaries.json")
        let jobsURL = baseURL.appendingPathComponent("Processing/processing-jobs.json")
        let metadataURL = baseURL.appendingPathComponent("library-metadata.json")
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: [T].Type, at url: URL) throws -> [T] {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try decoder.decode(type, from: Data(contentsOf: url))
        }
        let recordings = try decode([Recording].self, at: recordingsURL)
        let transcripts = try decode([Transcript].self, at: transcriptsURL)
        let summaries = try decode([Summary].self, at: summariesURL)
        let jobs = try decode([ProcessingJob].self, at: jobsURL)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let metadata = try decoder.decode(
                LibraryMetadataEnvelope.self,
                from: Data(contentsOf: metadataURL)
            )
            guard metadata.version <= LibraryMetadataEnvelope.currentVersion else {
                throw LibraryMetadataRepositoryError.unsupportedVersion(metadata.version)
            }
        }
        return LibraryCandidateSnapshot(
            baseURL: baseURL,
            recordingsURL: recordingsURL,
            transcriptsURL: transcriptsURL,
            summariesURL: summariesURL,
            jobsURL: jobsURL,
            metadataURL: metadataURL,
            recordings: recordings,
            transcripts: transcripts,
            summaries: summaries,
            jobs: jobs
        )
    }

    nonisolated private static func validateWritableAncestor(for baseURL: URL) throws {
        var candidate = baseURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              manager.isWritableFile(atPath: candidate.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    nonisolated private static func prepareDirectories(for candidate: LibraryCandidateSnapshot) throws {
        let manager = FileManager.default
        for directory in [
            candidate.baseURL,
            candidate.recordingsURL.deletingLastPathComponent(),
            candidate.transcriptsURL.deletingLastPathComponent(),
            candidate.summariesURL.deletingLastPathComponent(),
            candidate.jobsURL.deletingLastPathComponent(),
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func scheduleRebuild(delayNanoseconds: UInt64 = 150_000_000) {
        guard !isRebinding else { return }
        rebuildTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        let repository = repository
        let jobs = workflowCoordinator.jobs
        let restrictJobsToCurrentRecordings = restrictJobsToCurrentRecordings
        let manager = DirectoryManager.shared
        let recordingsURL = manager.getRecordingsDirectory().appendingPathComponent("recordings.json")
        let transcriptsURL = manager.getTranscriptsDirectory().appendingPathComponent("transcripts.json")
        let summariesURL = manager.getSummariesDirectory().appendingPathComponent("summaries.json")
        isRebuilding = true
        rebuildTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            do {
                let metadata = try await repository.snapshot()
                let snapshot = try await Task.detached(priority: .utility) {
                    try Self.loadLibrarySnapshot(
                        recordingsURL: recordingsURL,
                        transcriptsURL: transcriptsURL,
                        summariesURL: summariesURL,
                        jobs: jobs,
                        restrictJobsToCurrentRecordings: restrictJobsToCurrentRecordings
                    )
                }.value
                guard !Task.isCancelled else { return }
                let existingKeys = Set(snapshot.recordings.map { LibraryItemKey(kind: .recording, id: $0.id) })
                    .union(snapshot.transcripts.map { LibraryItemKey(kind: .transcript, id: $0.id) })
                    .union(snapshot.summaries.map { LibraryItemKey(kind: .summary, id: $0.id) })
                    .union(snapshot.recordings.compactMap { recording in
                        recording.groupId.map { LibraryItemKey(kind: .group, id: $0) }
                    })
                var groupByRecordingID: [UUID: UUID] = [:]
                for recording in snapshot.recordings where groupByRecordingID[recording.id] == nil {
                    if let groupID = recording.groupId { groupByRecordingID[recording.id] = groupID }
                }
                for groupID in snapshot.recordings.compactMap(\.groupId) {
                    groupByRecordingID[groupID] = groupID
                }
                var groupByTranscriptID: [UUID: UUID] = [:]
                var logicalGroupByItemKey: [LibraryItemKey: UUID] = [:]
                for recording in snapshot.recordings {
                    if let groupID = recording.groupId {
                        logicalGroupByItemKey[LibraryItemKey(kind: .recording, id: recording.id)] = groupID
                    }
                }
                for transcript in snapshot.transcripts {
                    if let groupID = groupByRecordingID[transcript.recordingId] {
                        groupByTranscriptID[transcript.id] = groupID
                        logicalGroupByItemKey[LibraryItemKey(kind: .transcript, id: transcript.id)] = groupID
                    }
                }
                for summary in snapshot.summaries {
                    if let groupID = groupByTranscriptID[summary.transcriptId] {
                        logicalGroupByItemKey[LibraryItemKey(kind: .summary, id: summary.id)] = groupID
                    }
                }
                try await repository.reconcile(
                    existingItemKeys: existingKeys,
                    logicalGroupByItemKey: logicalGroupByItemKey
                )
                let reconciled = try await repository.snapshot()
                let built = await Task.detached(priority: .utility) {
                    UnifiedSearchIndex(
                        recordings: snapshot.recordings,
                        transcripts: snapshot.transcripts,
                        summaries: snapshot.summaries,
                        jobs: snapshot.jobs,
                        metadata: reconciled
                    )
                }.value
                guard let self, requestedGeneration == self.generation, !Task.isCancelled else { return }
                self.metadata = reconciled
                self.index = built
                self.errorMessage = self.pendingRebindError
                self.pendingRebindError = nil
                self.isRebuilding = false
                _ = metadata // Preserve the initial read as an early corruption/version gate.
            } catch {
                guard let self, requestedGeneration == self.generation, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isRebuilding = false
            }
        }
    }

    private func mutate(_ operation: @escaping @Sendable () async throws -> Void) async {
        guard !isRebinding else {
            errorMessage = "Library changes are paused while the selected library is changing."
            return
        }
        metadataMutationsInFlight += 1
        defer {
            metadataMutationsInFlight -= 1
            if metadataMutationsInFlight == 0 {
                let waiters = metadataDrainWaiters
                metadataDrainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        do {
            try await operation()
            if !isRebinding { scheduleRebuild(delayNanoseconds: 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subscribe() {
        audioRecorder.$recordings.map { _ in () }
            .merge(with: transcriptionManager.$transcripts.map { _ in () })
            .merge(with: summaryManager.$summaries.map { _ in () })
            .merge(with: workflowCoordinator.$jobs.map { _ in () })
            .dropFirst(4)
            .sink { [weak self] in self?.scheduleRebuild() }
            .store(in: &cancellables)
    }

    nonisolated private static func loadLibrarySnapshot(
        recordingsURL: URL,
        transcriptsURL: URL,
        summariesURL: URL,
        jobs: [ProcessingJob],
        restrictJobsToCurrentRecordings: Bool
    ) throws -> LibrarySearchSnapshot {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: [T].Type, at url: URL) throws -> [T] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return []
            }
            return try decoder.decode(type, from: Data(contentsOf: url))
        }
        let recordings: [Recording] = try decode([Recording].self, at: recordingsURL)
        let transcripts: [Transcript] = try decode([Transcript].self, at: transcriptsURL)
        let summaries: [Summary] = try decode([Summary].self, at: summariesURL)
        let currentJobs: [ProcessingJob]
        if restrictJobsToCurrentRecordings {
            let recordingIDs = Set(recordings.map(\.id))
            currentJobs = jobs.filter { recordingIDs.contains($0.recordingID) }
        } else {
            currentJobs = jobs
        }
        return LibrarySearchSnapshot(recordings: recordings, transcripts: transcripts, summaries: summaries, jobs: currentJobs)
    }
}
