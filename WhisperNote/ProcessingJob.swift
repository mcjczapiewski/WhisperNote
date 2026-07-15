import Foundation

enum ProcessingJobState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case waitingForRecording
    case waitingForTranscriptionKey
    case transcribing
    case transcriptionFailed
    case waitingForSummaryKey
    case summarizing
    case summaryFailed
    case completed
    case cancelled

    var isTerminal: Bool { self == .completed || self == .cancelled }
    var canRetry: Bool {
        switch self {
        case .waitingForRecording, .waitingForTranscriptionKey, .transcriptionFailed,
             .waitingForSummaryKey, .summaryFailed:
            return true
        default:
            return false
        }
    }

    var isAutomaticRelaunchState: Bool {
        self == .queued || self == .transcribing || self == .summarizing
    }
}

struct ProcessingJobSnapshot: Codable, Equatable, Sendable {
    static let meetingMinutesTemplateID = "meeting-minutes-v1"

    var language: String
    var shouldSummarize: Bool
    var modelID: String
    var templateID: String
    var templateName: String?
    var prompt: String
    var shouldNotify: Bool

    init(
        language: String,
        shouldSummarize: Bool,
        modelID: String,
        templateID: String,
        templateName: String? = nil,
        prompt: String,
        shouldNotify: Bool
    ) {
        self.language = language
        self.shouldSummarize = shouldSummarize
        self.modelID = modelID
        self.templateID = templateID
        self.templateName = templateName
        self.prompt = prompt
        self.shouldNotify = shouldNotify
    }

    static func defaults(_ defaults: UserDefaults = .standard, prompt: String) -> Self {
        Self.defaults(
            defaults,
            generation: SummaryGenerationSnapshot(
                templateID: meetingMinutesTemplateID,
                templateName: "Meeting Minutes",
                prompt: prompt,
                model: defaults.string(forKey: "autoSummaryModel") ?? defaultLLMModelId
            )
        )
    }

    static func defaults(
        _ defaults: UserDefaults = .standard,
        generation: SummaryGenerationSnapshot
    ) -> Self {
        let autoTranscribe = defaults.bool(forKey: "autoTranscribeAfterRecording")
        return Self(
            language: defaults.string(forKey: "autoTranscriptionLanguage") ?? "eng",
            shouldSummarize: autoTranscribe && defaults.bool(forKey: "autoSummarizeAfterRecording"),
            modelID: generation.model,
            templateID: generation.templateID ?? meetingMinutesTemplateID,
            templateName: generation.templateName,
            prompt: generation.prompt,
            shouldNotify: defaults.bool(forKey: "processingCompletionNotifications")
        )
    }
}

struct ProcessingJob: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var recordingID: UUID
    var transcriptID: UUID
    var summaryID: UUID
    var recordingName: String
    var snapshot: ProcessingJobSnapshot
    var state: ProcessingJobState
    var attempt: Int
    var failureMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var notificationSentAt: Date?

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        transcriptID: UUID = UUID(),
        summaryID: UUID = UUID(),
        recordingName: String,
        snapshot: ProcessingJobSnapshot,
        state: ProcessingJobState = .queued,
        now: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.transcriptID = transcriptID
        self.summaryID = summaryID
        self.recordingName = recordingName
        self.snapshot = snapshot
        self.state = state
        self.attempt = 0
        self.failureMessage = nil
        self.createdAt = now
        self.updatedAt = now
        self.notificationSentAt = nil
    }

    @discardableResult
    mutating func transition(to newState: ProcessingJobState, failure: String? = nil, now: Date = Date()) -> Bool {
        guard Self.allowsTransition(from: state, to: newState) else { return false }
        state = newState
        failureMessage = failure
        updatedAt = now
        return true
    }

    private static func allowsTransition(from oldState: ProcessingJobState, to newState: ProcessingJobState) -> Bool {
        if oldState == newState { return true }
        if newState == .cancelled { return !oldState.isTerminal }
        switch oldState {
        case .queued:
            return [.waitingForRecording, .waitingForTranscriptionKey, .transcribing, .waitingForSummaryKey, .summarizing, .completed].contains(newState)
        case .waitingForRecording, .waitingForTranscriptionKey, .transcriptionFailed:
            return newState == .queued || newState == .waitingForTranscriptionKey || newState == .transcribing
        case .transcribing:
            return [.waitingForTranscriptionKey, .transcriptionFailed, .waitingForSummaryKey, .summarizing, .completed].contains(newState)
        case .waitingForSummaryKey, .summaryFailed:
            return newState == .queued || newState == .waitingForSummaryKey || newState == .summarizing
        case .summarizing:
            return newState == .waitingForSummaryKey || newState == .summaryFailed || newState == .completed
        case .completed, .cancelled:
            return false
        }
    }
}

enum ProcessingJobStoreError: LocalizedError {
    case corruptStore
    case staleGeneration

    var errorDescription: String? {
        switch self {
        case .corruptStore:
            return "Processing history could not be read. The existing file was left untouched."
        case .staleGeneration:
            return "Processing history changed libraries before the write completed."
        }
    }
}

final class ProcessingJobPersistenceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func invalidate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func withValidGeneration<T>(_ expectedGeneration: Int, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { throw ProcessingJobStoreError.staleGeneration }
        return try operation()
    }
}

actor ProcessingJobStore {
    private let fileURL: URL
    private let saveDelayNanoseconds: UInt64
    private var cachedJobs: [ProcessingJob]?

    init(fileURL: URL? = nil, saveDelayNanoseconds: UInt64 = 0) {
        self.saveDelayNanoseconds = saveDelayNanoseconds
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = DirectoryManager.shared.getBaseDirectory()
                .appendingPathComponent("Processing", isDirectory: true)
                .appendingPathComponent("processing-jobs.json")
        }
    }

    func load() throws -> [ProcessingJob] {
        if let cachedJobs { return cachedJobs }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedJobs = []
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let jobs = try JSONDecoder().decode([ProcessingJob].self, from: data)
            cachedJobs = jobs
            return jobs
        } catch {
            throw ProcessingJobStoreError.corruptStore
        }
    }

    @discardableResult
    func createIfAbsent(
        _ job: ProcessingJob,
        lease: ProcessingJobPersistenceLease? = nil,
        expectedGeneration: Int? = nil
    ) throws -> ProcessingJob {
        var jobs = try load()
        if let existing = jobs.first(where: { $0.recordingID == job.recordingID }) {
            return existing
        }
        jobs.append(job)
        if let lease, let expectedGeneration {
            try lease.withValidGeneration(expectedGeneration) { try persist(jobs) }
        } else {
            try persist(jobs)
        }
        return job
    }

    func save(
        _ job: ProcessingJob,
        lease: ProcessingJobPersistenceLease? = nil,
        expectedGeneration: Int? = nil
    ) async throws {
        var jobs = try load()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        if saveDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: saveDelayNanoseconds)
        }
        if let lease, let expectedGeneration {
            try lease.withValidGeneration(expectedGeneration) { try persist(jobs) }
        } else {
            try persist(jobs)
        }
    }

    private func persist(_ jobs: [ProcessingJob]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
        cachedJobs = jobs
    }
}
