import Foundation

enum RecordingSessionState: String, Codable, CaseIterable, Sendable {
    case preparing
    case capturing
    case paused
    case stopping
    case merging
    case completed
    case failed
    case dismissed
}

enum RecordingSessionFailureCode: String, Codable, Sendable {
    case permissionDenied
    case directoryUnavailable
    case captureFailed
    case manifestWriteFailed
    case mergeFailed
    case noValidAudio
    case metadataWriteFailed
}

struct RecordingSessionManifest: Codable, Equatable, Sendable {
    static let filename = "recording-session.json"
    static let dismissalFilename = ".recording-dismissed"

    var schemaVersion = 1
    let sessionID: UUID
    var displayName: String
    let createdAt: Date
    var updatedAt: Date
    var captureStartedAt: Date?
    var duration: TimeInterval
    var selectedInputID: String
    var microphonePath: String
    var systemAudioPath: String
    var mergedPath: String
    var resolvedAudioPath: String?
    var state: RecordingSessionState
    var retryCount: Int
    var failureCode: RecordingSessionFailureCode?

    init(
        sessionID: UUID,
        displayName: String,
        createdAt: Date,
        selectedInputID: String,
        microphonePath: String = "mic_recording.m4a",
        systemAudioPath: String = "system_recording.m4a",
        mergedPath: String = "recording.m4a",
        state: RecordingSessionState = .preparing
    ) {
        self.sessionID = sessionID
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.captureStartedAt = nil
        self.duration = 0
        self.selectedInputID = selectedInputID
        self.microphonePath = microphonePath
        self.systemAudioPath = systemAudioPath
        self.mergedPath = mergedPath
        self.resolvedAudioPath = nil
        self.state = state
        self.retryCount = 0
        self.failureCode = nil
    }

    func url(for relativePath: String, in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(relativePath)
    }

    func validatePaths(in bundleURL: URL) throws {
        guard microphonePath == "mic_recording.m4a",
              systemAudioPath == "system_recording.m4a",
              Self.isAllowedMergedPath(mergedPath),
              resolvedAudioPath == nil || [microphonePath, systemAudioPath, mergedPath].contains(resolvedAudioPath!) else {
            throw RecordingManifestValidationError.unsafePath
        }

        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        for path in [microphonePath, systemAudioPath, mergedPath] + [resolvedAudioPath].compactMap({ $0 }) {
            guard path == URL(fileURLWithPath: path).lastPathComponent,
                  !path.hasPrefix("/"),
                  !path.contains("..") else {
                throw RecordingManifestValidationError.unsafePath
            }
            let candidate = bundleURL.appendingPathComponent(path).standardizedFileURL
            let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            guard resolvedParent.path == bundle.path else {
                throw RecordingManifestValidationError.symlinkEscape
            }
            let isSymbolicLink = (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            if FileManager.default.fileExists(atPath: candidate.path) || isSymbolicLink {
                let resolvedCandidateParent = candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                guard resolvedCandidateParent.path == bundle.path else {
                    throw RecordingManifestValidationError.symlinkEscape
                }
            }
        }
    }

    private static func isAllowedMergedPath(_ path: String) -> Bool {
        guard path.hasPrefix("recording."), path == URL(fileURLWithPath: path).lastPathComponent else {
            return false
        }
        let ext = String(path.dropFirst("recording.".count))
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

enum RecordingManifestValidationError: Error, LocalizedError {
    case unsafePath
    case symlinkEscape

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The recording manifest contains an unsafe audio path."
        case .symlinkEscape: return "The recording manifest points outside its recording bundle."
        }
    }
}

struct ManifestBundle: Sendable {
    let manifest: RecordingSessionManifest
    let bundleURL: URL
}

struct ManifestScanResult: Sendable {
    let bundles: [ManifestBundle]
    let corruptBundleURLs: [URL]
}

struct RecordingLibraryReferenceReconciler {
    static func matchingRecording(
        for manifest: RecordingSessionManifest,
        bundleURL: URL,
        recordingsDirectory: URL,
        recordings: [Recording],
        fileManager: FileManager = .default
    ) -> (recording: Recording, audioFilename: String)? {
        guard isSafeDirectBundle(
            bundleURL,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager
        ) else { return nil }

        let allowedFilenames = Set([
            manifest.microphonePath,
            manifest.systemAudioPath,
            manifest.mergedPath
        ])
        for recording in recordings {
            guard let filename = safeReferencedAudioFilename(
                recording.filePath,
                in: bundleURL,
                allowedFilenames: allowedFilenames,
                fileManager: fileManager
            ) else { continue }
            return (recording, filename)
        }
        return nil
    }

    static func reidentifiedManifest(
        _ manifest: RecordingSessionManifest,
        recording: Recording,
        audioFilename: String
    ) -> RecordingSessionManifest {
        var reconciled = RecordingSessionManifest(
            sessionID: recording.id,
            displayName: recording.name,
            createdAt: manifest.createdAt,
            selectedInputID: manifest.selectedInputID,
            microphonePath: manifest.microphonePath,
            systemAudioPath: manifest.systemAudioPath,
            mergedPath: manifest.mergedPath,
            state: manifest.state
        )
        reconciled.updatedAt = Date()
        reconciled.captureStartedAt = recording.date
        reconciled.duration = recording.duration
        reconciled.resolvedAudioPath = audioFilename
        reconciled.retryCount = manifest.retryCount
        reconciled.failureCode = manifest.failureCode
        return reconciled
    }

    private static func isSafeDirectBundle(
        _ bundleURL: URL,
        recordingsDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        let standardizedBundle = bundleURL.standardizedFileURL
        let standardizedRoot = recordingsDirectory.standardizedFileURL
        guard standardizedBundle.deletingLastPathComponent().path == standardizedRoot.path,
              let values = try? standardizedBundle.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        return true
    }

    private static func safeReferencedAudioFilename(
        _ audioURL: URL,
        in bundleURL: URL,
        allowedFilenames: Set<String>,
        fileManager: FileManager
    ) -> String? {
        let candidate = audioURL.standardizedFileURL
        let bundle = bundleURL.standardizedFileURL
        let filename = candidate.lastPathComponent
        guard allowedFilenames.contains(filename),
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              candidate.deletingLastPathComponent().path == bundle.path else { return nil }

        let canonicalBundle = bundle.resolvingSymlinksInPath()
        let isSymlink = (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if fileManager.fileExists(atPath: candidate.path) || isSymlink {
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            guard resolvedCandidate.deletingLastPathComponent().path == canonicalBundle.path else {
                return nil
            }
        } else {
            guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalBundle.path else {
                return nil
            }
        }
        return filename
    }
}

actor RecordingSessionManifestStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    func write(_ manifest: RecordingSessionManifest, to bundleURL: URL) throws {
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try validateBundleDirectory(bundleURL)
        try manifest.validatePaths(in: bundleURL)
        let data = try encoder.encode(manifest)
        try data.write(
            to: bundleURL.appendingPathComponent(RecordingSessionManifest.filename),
            options: .atomic
        )
    }

    func read(from bundleURL: URL) throws -> RecordingSessionManifest {
        try validateBundleDirectory(bundleURL)
        let url = bundleURL.appendingPathComponent(RecordingSessionManifest.filename)
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: url))
        try manifest.validatePaths(in: bundleURL)
        return manifest
    }

    /// Completes recovery as one actor-isolated compare-and-set operation. Keeping the
    /// dismissal check and atomic write in the same actor turn prevents a concurrent
    /// Dismiss action from being overwritten after recovery has already checked state.
    func completeIfNotDismissed(
        in bundleURL: URL,
        duration: TimeInterval,
        resolvedAudioPath: String,
        clearFailure: Bool
    ) throws -> RecordingSessionManifest? {
        var manifest = try read(from: bundleURL)
        guard manifest.state != .dismissed else { return nil }
        manifest.state = .completed
        manifest.updatedAt = Date()
        manifest.duration = duration > 0 ? duration : manifest.duration
        manifest.resolvedAudioPath = resolvedAudioPath
        if clearFailure { manifest.failureCode = nil }
        try write(manifest, to: bundleURL)
        return manifest
    }

    func scan(recordingsDirectory: URL) throws -> ManifestScanResult {
        let contents = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var bundles: [ManifestBundle] = []
        var corruptBundleURLs: [URL] = []

        for bundleURL in contents {
            let dismissalURL = bundleURL.appendingPathComponent(RecordingSessionManifest.dismissalFilename)
            guard !fileManager.fileExists(atPath: dismissalURL.path) else { continue }
            let manifestURL = bundleURL.appendingPathComponent(RecordingSessionManifest.filename)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let values = try? bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                corruptBundleURLs.append(bundleURL)
                continue
            }

            do {
                bundles.append(ManifestBundle(manifest: try read(from: bundleURL), bundleURL: bundleURL))
            } catch {
                corruptBundleURLs.append(bundleURL)
            }
        }

        return ManifestScanResult(bundles: bundles, corruptBundleURLs: corruptBundleURLs)
    }

    private func validateBundleDirectory(_ bundleURL: URL) throws {
        let values = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RecordingManifestValidationError.symlinkEscape
        }
    }
}

enum RecordingLifecyclePhase: Equatable, Sendable {
    case idle
    case starting
    case capturing
    case paused
    case stopping
}

struct RecordingLifecycleGate: Sendable {
    private(set) var phase: RecordingLifecyclePhase = .idle

    mutating func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    mutating func didStart() {
        phase = .capturing
    }

    mutating func didFailStart() {
        phase = .idle
    }

    mutating func pause() -> Bool {
        guard phase == .capturing else { return false }
        phase = .paused
        return true
    }

    mutating func resume() -> Bool {
        guard phase == .paused else { return false }
        phase = .capturing
        return true
    }

    mutating func beginStop() -> Bool {
        guard phase == .capturing || phase == .paused else { return false }
        phase = .stopping
        return true
    }

    mutating func finishStop() {
        phase = .idle
    }
}

struct InitialRecordingRecoveryGate: Sendable {
    private(set) var isComplete = false

    var canStartRecording: Bool { isComplete }

    mutating func finish() {
        isComplete = true
    }
}

struct FailedStartRecoveryPolicy {
    static func shouldSurfaceSession(captureDidBegin: Bool) -> Bool {
        captureDidBegin
    }
}

struct RecordingLibraryUpdate {
    static func replacingAudio(in recordings: [Recording], with replacement: Recording) -> [Recording] {
        guard let index = recordings.firstIndex(where: { $0.id == replacement.id }) else {
            return recordings + [replacement]
        }
        var updated = recordings
        updated[index].filePath = replacement.filePath
        updated[index].duration = replacement.duration
        updated[index].systemAudioFilePath = replacement.systemAudioFilePath
        return updated
    }
}

struct RecordingSessionActionGate: Sendable {
    private(set) var inFlight: Set<UUID> = []

    mutating func begin(_ id: UUID) -> Bool {
        guard inFlight.insert(id).inserted else { return false }
        return true
    }

    mutating func finish(_ id: UUID) {
        inFlight.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        inFlight.contains(id)
    }
}

@MainActor
final class RecordingLibraryMutationCoordinator {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init() { }

    func withLock<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum RecordingDeletionStage: Equatable, Sendable {
    case preparation
    case metadata
    case files
}

struct RecordingDeletionTransactionError: LocalizedError {
    let stage: RecordingDeletionStage
    let operationError: Error
    let rollbackErrors: [Error]

    var errorDescription: String? {
        let rollbackSuffix = rollbackErrors.isEmpty
            ? ""
            : " Rollback also reported: \(rollbackErrors.map(\.localizedDescription).joined(separator: "; "))"
        return "Deletion failed during \(stageDescription): \(operationError.localizedDescription).\(rollbackSuffix)"
    }

    private var stageDescription: String {
        switch stage {
        case .preparation: return "recovery-state preparation"
        case .metadata: return "library metadata update"
        case .files: return "audio file removal"
        }
    }
}

/// Keeps persisted library metadata from pointing at deleted audio. Managed recording
/// manifests are dismissed first so a crash cannot resurrect a deletion in progress;
/// the reduced library is then persisted before any audio is removed. Any failure
/// restores the previous manifest state and, after a file failure, the previous library.
struct RecordingDeletionTransaction {
    static func execute(
        currentRecordings: [Recording],
        deleting recordingID: UUID,
        prepareForDeletion: () async throws -> Void,
        rollbackPreparation: () async throws -> Void,
        persistRecordings: ([Recording]) throws -> Void,
        deleteFiles: () throws -> Void
    ) async throws -> [Recording] {
        let remainingRecordings = currentRecordings.filter { $0.id != recordingID }
        guard remainingRecordings.count != currentRecordings.count else {
            return currentRecordings
        }

        do {
            try await prepareForDeletion()
        } catch {
            var rollbackErrors: [Error] = []
            do { try await rollbackPreparation() } catch { rollbackErrors.append(error) }
            throw RecordingDeletionTransactionError(
                stage: .preparation,
                operationError: error,
                rollbackErrors: rollbackErrors
            )
        }

        do {
            try persistRecordings(remainingRecordings)
        } catch {
            var rollbackErrors: [Error] = []
            do { try await rollbackPreparation() } catch { rollbackErrors.append(error) }
            throw RecordingDeletionTransactionError(
                stage: .metadata,
                operationError: error,
                rollbackErrors: rollbackErrors
            )
        }

        do {
            try deleteFiles()
        } catch {
            var rollbackErrors: [Error] = []
            // Restore recovery eligibility first. If metadata rollback then fails, the
            // manifest still makes the preserved audio recoverable on the next launch.
            do { try await rollbackPreparation() } catch { rollbackErrors.append(error) }
            do { try persistRecordings(currentRecordings) } catch { rollbackErrors.append(error) }
            throw RecordingDeletionTransactionError(
                stage: .files,
                operationError: error,
                rollbackErrors: rollbackErrors
            )
        }

        return remainingRecordings
    }
}

struct RecordingBundleDeletionPolicy {
    static func deletionURL(
        for recording: Recording,
        recordingsDirectory: URL,
        hasManifest: Bool
    ) -> URL {
        let audioURL = recording.filePath.standardizedFileURL
        let bundleURL = audioURL.deletingLastPathComponent()
        let rootURL = recordingsDirectory.standardizedFileURL
        guard bundleURL.deletingLastPathComponent().path == rootURL.path else { return audioURL }
        if hasManifest { return bundleURL }

        let filename = audioURL.lastPathComponent
        if isExactLegacyBundleName(bundleURL.lastPathComponent, prefix: "recording_"),
           ["recording.m4a", "mic_recording.m4a", "system_recording.m4a"].contains(filename) {
            return bundleURL
        }
        if isExactLegacyBundleName(bundleURL.lastPathComponent, prefix: "import_"),
           filename.hasPrefix("recording."), filename == URL(fileURLWithPath: filename).lastPathComponent {
            return bundleURL
        }
        return audioURL
    }

    private static func isExactLegacyBundleName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        let components = suffix.split(separator: "_", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 8, components[0].allSatisfy(\.isNumber),
              components[1].count == 6, components[1].allSatisfy(\.isNumber),
              UUID(uuidString: String(components[2])) != nil else { return false }
        return true
    }
}

struct RecordingManifestRepairCandidate {
    static func audioFilename(in bundleURL: URL, fileManager: FileManager = .default) -> String? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = contents.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name.hasPrefix("recording."), name == URL(fileURLWithPath: name).lastPathComponent else {
                return nil
            }
            let ext = String(name.dropFirst("recording.".count))
            guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                return nil
            }
            return name
        }
        return candidates.sorted { lhs, rhs in
            if lhs == "recording.m4a" { return true }
            if rhs == "recording.m4a" { return false }
            return lhs < rhs
        }.first
    }
}
