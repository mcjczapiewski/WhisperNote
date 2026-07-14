import Foundation

struct RecordingBundleInspection: Equatable, Sendable {
    let merged: AudioFileProbe
    let microphone: AudioFileProbe
    let systemAudio: AudioFileProbe

    var hasAnyValidAudio: Bool {
        merged.isValid || microphone.isValid || systemAudio.isValid
    }

    var canRetryMerge: Bool {
        microphone.isValid && systemAudio.isValid
    }
}

struct RecoverableRecordingSession: Identifiable, Sendable {
    var id: UUID { manifest.sessionID }
    let manifest: RecordingSessionManifest
    let bundleURL: URL
    let inspection: RecordingBundleInspection

    var statusDescription: String {
        if inspection.merged.isValid { return "A completed recording is ready to recover." }
        if inspection.canRetryMerge { return "Microphone and system audio are available to merge again." }
        if inspection.microphone.isValid { return "Microphone audio is available to recover." }
        if inspection.systemAudio.isValid { return "System audio is available to recover." }
        return "No valid audio is currently available. You can retry after checking the bundle."
    }
}

struct RecoveryScanResult: Sendable {
    let sessions: [RecoverableRecordingSession]
    let corruptBundleURLs: [URL]
}

struct CorruptRecordingBundle: Identifiable, Sendable {
    var id: String { bundleURL.path }
    let bundleURL: URL
}

enum RecordingRecoveryOutcome: Sendable {
    case recovered(recording: Recording, usedFallback: Bool)
    case unavailable(RecoverableRecordingSession)
    case ignored
}

enum LegacyRecordingMigrationOutcome: Sendable {
    case migrated(ManifestBundle)
    case conclusivelyAbsentOrInvalid
    case retainedForRetry
}

struct LegacyRecordingMigrationService: Sendable {
    let manifestStore: RecordingSessionManifestStore
    let audioMerger: any AudioMerging

    func migrate(
        metadata: [String: String]?,
        recordingsDirectory: URL,
        existingRecordings: [Recording] = []
    ) async -> LegacyRecordingMigrationOutcome {
        guard let metadata,
              let name = metadata["name"],
              let dateString = metadata["date"],
              let uuidString = metadata["uuid"],
              let sessionID = UUID(uuidString: uuidString) else {
            return .conclusivelyAbsentOrInvalid
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.isLenient = false
        guard dateString.count == 15,
              dateString.allSatisfy({ $0.isNumber || $0 == "_" }),
              let createdAt = formatter.date(from: dateString),
              formatter.string(from: createdAt) == dateString else {
            return .conclusivelyAbsentOrInvalid
        }

        let folderName = "recording_\(dateString)_\(uuidString)"
        let bundleURL = recordingsDirectory.appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let bundleValues = try? bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              bundleValues?.isDirectory == true,
              bundleValues?.isSymbolicLink != true else {
            return .conclusivelyAbsentOrInvalid
        }

        if let existing = try? await manifestStore.read(from: bundleURL) {
            if let match = RecordingLibraryReferenceReconciler.matchingRecording(
                for: existing,
                bundleURL: bundleURL,
                recordingsDirectory: recordingsDirectory,
                recordings: existingRecordings
            ) {
                let reconciled = RecordingLibraryReferenceReconciler.reidentifiedManifest(
                    existing,
                    recording: match.recording,
                    audioFilename: match.audioFilename
                )
                do {
                    try await manifestStore.write(reconciled, to: bundleURL)
                    return .migrated(ManifestBundle(manifest: reconciled, bundleURL: bundleURL))
                } catch {
                    return .retainedForRetry
                }
            }
            return .migrated(ManifestBundle(manifest: existing, bundleURL: bundleURL))
        }

        var manifest = RecordingSessionManifest(
            sessionID: sessionID,
            displayName: name,
            createdAt: createdAt,
            selectedInputID: "",
            state: .failed
        )
        manifest.captureStartedAt = createdAt
        let mergedProbe = await audioMerger.probeAudio(at: manifest.url(for: manifest.mergedPath, in: bundleURL))
        let microphoneProbe = await audioMerger.probeAudio(at: manifest.url(for: manifest.microphonePath, in: bundleURL))
        let systemProbe = await audioMerger.probeAudio(at: manifest.url(for: manifest.systemAudioPath, in: bundleURL))
        guard mergedProbe.isValid || microphoneProbe.isValid || systemProbe.isValid else {
            return .conclusivelyAbsentOrInvalid
        }
        manifest.duration = max(mergedProbe.duration, microphoneProbe.duration, systemProbe.duration)
        manifest.failureCode = mergedProbe.isValid ? nil : .mergeFailed
        if let match = RecordingLibraryReferenceReconciler.matchingRecording(
            for: manifest,
            bundleURL: bundleURL,
            recordingsDirectory: recordingsDirectory,
            recordings: existingRecordings
        ) {
            manifest.state = .completed
            manifest = RecordingLibraryReferenceReconciler.reidentifiedManifest(
                manifest,
                recording: match.recording,
                audioFilename: match.audioFilename
            )
        }

        do {
            try await manifestStore.write(manifest, to: bundleURL)
            return .migrated(ManifestBundle(manifest: manifest, bundleURL: bundleURL))
        } catch {
            return .retainedForRetry
        }
    }
}

struct RecordingRecoveryService: Sendable {
    let manifestStore: RecordingSessionManifestStore
    let audioMerger: any AudioMerging

    func scan(recordingsDirectory: URL, excluding existingIDs: Set<UUID>) async throws -> RecoveryScanResult {
        let scan = try await manifestStore.scan(recordingsDirectory: recordingsDirectory)
        var sessions: [RecoverableRecordingSession] = []

        for bundle in scan.bundles {
            guard bundle.manifest.state != .dismissed else { continue }
            let inspected = await inspect(manifest: bundle.manifest, bundleURL: bundle.bundleURL)
            if existingIDs.contains(bundle.manifest.sessionID) {
                // A raw-track fallback is already a valid library entry, but the user
                // must retain the option to rebuild and replace it with the merged track.
                if bundle.manifest.failureCode == .mergeFailed, inspected.inspection.canRetryMerge {
                    sessions.append(inspected)
                }
            } else {
                sessions.append(inspected)
            }
        }

        return RecoveryScanResult(
            sessions: sessions.sorted { $0.manifest.createdAt < $1.manifest.createdAt },
            corruptBundleURLs: scan.corruptBundleURLs
        )
    }

    func inspect(
        manifest: RecordingSessionManifest,
        bundleURL: URL
    ) async -> RecoverableRecordingSession {
        async let merged = audioMerger.probeAudio(at: manifest.url(for: manifest.mergedPath, in: bundleURL))
        async let microphone = audioMerger.probeAudio(at: manifest.url(for: manifest.microphonePath, in: bundleURL))
        async let systemAudio = audioMerger.probeAudio(at: manifest.url(for: manifest.systemAudioPath, in: bundleURL))

        return await RecoverableRecordingSession(
            manifest: manifest,
            bundleURL: bundleURL,
            inspection: RecordingBundleInspection(
                merged: merged,
                microphone: microphone,
                systemAudio: systemAudio
            )
        )
    }

    func recover(_ session: RecoverableRecordingSession) async throws -> RecordingRecoveryOutcome {
        var manifest = try await manifestStore.read(from: session.bundleURL)
        guard manifest.state != .dismissed else { return .ignored }

        // Always re-probe. Manifest state and paths are hints; actual file validity is authoritative.
        let refreshed = await inspect(manifest: manifest, bundleURL: session.bundleURL)
        let inspection = refreshed.inspection
        let mergedURL = manifest.url(for: manifest.mergedPath, in: session.bundleURL)
        let microphoneURL = manifest.url(for: manifest.microphonePath, in: session.bundleURL)
        let systemURL = manifest.url(for: manifest.systemAudioPath, in: session.bundleURL)

        if inspection.merged.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: mergedURL,
                probe: inspection.merged,
                usedFallback: false
            )
        }

        if inspection.canRetryMerge {
            manifest.state = .merging
            manifest.retryCount += 1
            manifest.updatedAt = Date()
            manifest.failureCode = nil
            try await manifestStore.write(manifest, to: session.bundleURL)

            do {
                let outputURL = try await audioMerger.merge(
                    microphoneURL: microphoneURL,
                    systemAudioURL: systemURL,
                    outputURL: mergedURL
                )
                let outputProbe = await audioMerger.probeAudio(at: outputURL)
                guard outputProbe.isValid else { throw AudioRecorderError.recordingFailed }
                return try await complete(
                    manifest: &manifest,
                    bundleURL: session.bundleURL,
                    audioURL: outputURL,
                    probe: outputProbe,
                    usedFallback: false
                )
            } catch {
                // Preserve both raw tracks and retain a coarse failure marker. The normal
                // tolerance remains microphone-first, then system-only if necessary.
                manifest.state = .failed
                manifest.failureCode = .mergeFailed
                manifest.updatedAt = Date()
                try await manifestStore.write(manifest, to: session.bundleURL)

                if inspection.microphone.isValid {
                    return try await complete(
                        manifest: &manifest,
                        bundleURL: session.bundleURL,
                        audioURL: microphoneURL,
                        probe: inspection.microphone,
                        usedFallback: true
                    )
                }
                if inspection.systemAudio.isValid {
                    return try await complete(
                        manifest: &manifest,
                        bundleURL: session.bundleURL,
                        audioURL: systemURL,
                        probe: inspection.systemAudio,
                        usedFallback: true
                    )
                }
            }
        }

        if inspection.microphone.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: microphoneURL,
                probe: inspection.microphone,
                usedFallback: true
            )
        }
        if inspection.systemAudio.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: systemURL,
                probe: inspection.systemAudio,
                usedFallback: true
            )
        }

        manifest.state = .failed
        manifest.failureCode = .noValidAudio
        manifest.updatedAt = Date()
        try await manifestStore.write(manifest, to: session.bundleURL)
        return .unavailable(await inspect(manifest: manifest, bundleURL: session.bundleURL))
    }

    /// Explicit UI recovery: save the best audio that already exists without attempting
    /// a new merge. This gives Recover a predictable raw-track fallback while Retry Merge
    /// remains a distinct request to rebuild the combined recording.
    func recoverAvailableAudio(_ session: RecoverableRecordingSession) async throws -> RecordingRecoveryOutcome {
        var manifest = try await manifestStore.read(from: session.bundleURL)
        guard manifest.state != .dismissed else { return .ignored }

        let refreshed = await inspect(manifest: manifest, bundleURL: session.bundleURL)
        let inspection = refreshed.inspection
        if inspection.merged.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: manifest.url(for: manifest.mergedPath, in: session.bundleURL),
                probe: inspection.merged,
                usedFallback: false
            )
        }
        if inspection.microphone.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: manifest.url(for: manifest.microphonePath, in: session.bundleURL),
                probe: inspection.microphone,
                usedFallback: true
            )
        }
        if inspection.systemAudio.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: manifest.url(for: manifest.systemAudioPath, in: session.bundleURL),
                probe: inspection.systemAudio,
                usedFallback: true
            )
        }

        manifest.state = .failed
        manifest.failureCode = .noValidAudio
        manifest.updatedAt = Date()
        try await manifestStore.write(manifest, to: session.bundleURL)
        return .unavailable(await inspect(manifest: manifest, bundleURL: session.bundleURL))
    }

    /// Explicit UI merge retry. Unlike normal stop/launch finalization, a failed retry
    /// remains recoverable instead of silently accepting a raw-track fallback.
    func retryMerge(_ session: RecoverableRecordingSession) async throws -> RecordingRecoveryOutcome {
        var manifest = try await manifestStore.read(from: session.bundleURL)
        guard manifest.state != .dismissed else { return .ignored }

        let refreshed = await inspect(manifest: manifest, bundleURL: session.bundleURL)
        let inspection = refreshed.inspection
        if inspection.merged.isValid {
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: manifest.url(for: manifest.mergedPath, in: session.bundleURL),
                probe: inspection.merged,
                usedFallback: false
            )
        }
        guard inspection.canRetryMerge else { return .unavailable(refreshed) }

        let microphoneURL = manifest.url(for: manifest.microphonePath, in: session.bundleURL)
        let systemURL = manifest.url(for: manifest.systemAudioPath, in: session.bundleURL)
        let mergedURL = manifest.url(for: manifest.mergedPath, in: session.bundleURL)
        manifest.state = .merging
        manifest.retryCount += 1
        manifest.failureCode = nil
        manifest.updatedAt = Date()
        try await manifestStore.write(manifest, to: session.bundleURL)

        do {
            let outputURL = try await audioMerger.merge(
                microphoneURL: microphoneURL,
                systemAudioURL: systemURL,
                outputURL: mergedURL
            )
            let outputProbe = await audioMerger.probeAudio(at: outputURL)
            guard outputProbe.isValid else { throw AudioRecorderError.recordingFailed }
            return try await complete(
                manifest: &manifest,
                bundleURL: session.bundleURL,
                audioURL: outputURL,
                probe: outputProbe,
                usedFallback: false
            )
        } catch {
            manifest.state = .failed
            manifest.failureCode = .mergeFailed
            manifest.updatedAt = Date()
            try await manifestStore.write(manifest, to: session.bundleURL)
            return .unavailable(await inspect(manifest: manifest, bundleURL: session.bundleURL))
        }
    }

    func dismiss(_ session: RecoverableRecordingSession) async throws {
        var manifest = try await manifestStore.read(from: session.bundleURL)
        manifest.state = .dismissed
        manifest.updatedAt = Date()
        try await manifestStore.write(manifest, to: session.bundleURL)
    }

    private func complete(
        manifest: inout RecordingSessionManifest,
        bundleURL: URL,
        audioURL: URL,
        probe: AudioFileProbe,
        usedFallback: Bool
    ) async throws -> RecordingRecoveryOutcome {
        guard let completed = try await manifestStore.completeIfNotDismissed(
            in: bundleURL,
            duration: probe.duration,
            resolvedAudioPath: audioURL.lastPathComponent,
            clearFailure: !usedFallback
        ) else { return .ignored }
        manifest = completed

        return .recovered(
            recording: Recording(
                id: manifest.sessionID,
                name: manifest.displayName,
                date: manifest.captureStartedAt ?? manifest.createdAt,
                duration: manifest.duration,
                filePath: audioURL,
                systemAudioFilePath: nil
            ),
            usedFallback: usedFallback
        )
    }
}
