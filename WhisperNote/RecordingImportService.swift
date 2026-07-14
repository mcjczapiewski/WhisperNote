import Foundation

struct RecordingImportFailure: Equatable, Sendable {
    let filename: String
    let message: String
}

struct RecordingImportBatchResult: Sendable {
    let recordings: [Recording]
    let failures: [RecordingImportFailure]
}

final class RecordingImportService: @unchecked Sendable {
    private let audioMerger: any AudioMerging
    private let manifestStore: RecordingSessionManifestStore
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        audioMerger: any AudioMerging,
        manifestStore: RecordingSessionManifestStore = RecordingSessionManifestStore(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.audioMerger = audioMerger
        self.manifestStore = manifestStore
        self.fileManager = fileManager
        self.now = now
        self.makeUUID = makeUUID
    }

    func importBatch(
        from sourceURLs: [URL],
        into recordingsDirectory: URL,
        groupId: UUID?,
        groupName: String?
    ) async -> RecordingImportBatchResult {
        var recordings: [Recording] = []
        var failures: [RecordingImportFailure] = []

        for sourceURL in sourceURLs {
            do {
                recordings.append(try await importSingle(
                    from: sourceURL,
                    into: recordingsDirectory,
                    groupId: groupId,
                    groupName: groupName,
                    customName: nil
                ))
            } catch {
                failures.append(RecordingImportFailure(
                    filename: sourceURL.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        return RecordingImportBatchResult(recordings: recordings, failures: failures)
    }

    func importSingle(
        from sourceURL: URL,
        into recordingsDirectory: URL,
        groupId: UUID?,
        groupName: String?,
        customName: String?
    ) async throws -> Recording {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let timestamp = now()
        let sessionID = makeUUID()
        let stagingURL = recordingsDirectory.appendingPathComponent(
            ".import_staging_\(sessionID.uuidString)",
            isDirectory: true
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let stagedAudioURL = stagingURL.appendingPathComponent("recording.\(pathExtension)")
        try fileManager.copyItem(at: sourceURL, to: stagedAudioURL)

        let probe = await audioMerger.probeAudio(at: stagedAudioURL)
        guard probe.isValid, probe.duration.isFinite, probe.duration > 0 else {
            throw AudioRecorderError.invalidAudio
        }

        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let trimmedName = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedName.isEmpty ? sourceName : trimmedName
        var manifest = RecordingSessionManifest(
            sessionID: sessionID,
            displayName: displayName,
            createdAt: timestamp,
            selectedInputID: "",
            mergedPath: stagedAudioURL.lastPathComponent,
            state: .preparing
        )
        manifest.duration = probe.duration
        try await manifestStore.write(manifest, to: stagingURL)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let finalBundleURL = recordingsDirectory.appendingPathComponent(
            "import_\(formatter.string(from: timestamp))_\(sessionID.uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: stagingURL, to: finalBundleURL)
        committed = true

        let finalAudioURL = finalBundleURL.appendingPathComponent(stagedAudioURL.lastPathComponent)
        manifest.state = .completed
        manifest.resolvedAudioPath = finalAudioURL.lastPathComponent
        manifest.updatedAt = Date()
        try await manifestStore.write(manifest, to: finalBundleURL)

        return Recording(
            id: sessionID,
            name: displayName,
            date: timestamp,
            duration: probe.duration,
            filePath: finalAudioURL,
            systemAudioFilePath: nil,
            groupId: groupId,
            groupName: groupName
        )
    }

    /// Hidden staging bundles are never committed library entries. Removing them at
    /// launch makes crashes before the atomic move self-cleaning; final import bundles
    /// carry a normal recording manifest and are reconciled by launch recovery.
    func cleanupInterruptedStaging(in recordingsDirectory: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for url in contents where url.lastPathComponent.hasPrefix(".import_staging_") {
            try fileManager.removeItem(at: url)
        }
    }
}
