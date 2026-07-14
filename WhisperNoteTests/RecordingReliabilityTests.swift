import AVFoundation
import Foundation
import XCTest
@testable import WhisperNote

final class RecordingReliabilityTests: XCTestCase {
    func testHostedAppUsesExplicitUnitTestMode() throws {
        guard ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else {
            throw XCTSkip("Only applies to the hosted Xcode test process")
        }
        let testEnvironment = ProcessInfo.processInfo.environment.filter {
            $0.key.contains("XCTest") || $0.key.contains("Inject")
        }
        XCTAssertTrue(
            WhisperNoteRuntime.isUnitTestMode,
            "Hosted arguments: \(ProcessInfo.processInfo.arguments); test environment: \(testEnvironment)"
        )
    }

    func testManifestAtomicRoundTripCoversEveryState() async throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("recording", isDirectory: true)
        let store = RecordingSessionManifestStore()

        for state in RecordingSessionState.allCases {
            var manifest = makeManifest(state: state)
            manifest.duration = 12.5
            manifest.retryCount = 2
            manifest.failureCode = state == .failed ? .mergeFailed : nil
            try await store.write(manifest, to: bundle)
            let decoded = try await store.read(from: bundle)
            XCTAssertEqual(decoded, manifest)

            let filenames = try FileManager.default.contentsOfDirectory(atPath: bundle.path)
            XCTAssertEqual(filenames, [RecordingSessionManifest.filename])
        }
    }

    func testManifestScanReportsCorruptAndIgnoresLegacyManifestlessBundles() async throws {
        let root = try temporaryDirectory()
        let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: corrupt.appendingPathComponent(RecordingSessionManifest.filename)
        )
        try Data("legacy audio".utf8).write(to: legacy.appendingPathComponent("recording.m4a"))

        let scan = try await RecordingSessionManifestStore().scan(recordingsDirectory: root)
        XCTAssertTrue(scan.bundles.isEmpty)
        XCTAssertEqual(scan.corruptBundleURLs.map(\.lastPathComponent), [corrupt.lastPathComponent])
    }

    func testRecoveryPrefersValidMergedAudioRegardlessOfStaleManifestState() async throws {
        let context = try await recoveryContext(
            state: .preparing,
            probes: ["recording.m4a": AudioFileProbe(isValid: true, duration: 8)]
        )
        let scan = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: []
        )
        let session = try XCTUnwrap(scan.sessions.first)

        let outcome = try await context.service.recover(session)
        let recording = try recoveredRecording(from: outcome)
        let mergeCalls = await context.merger.mergeCallCount()
        XCTAssertEqual(recording.id, context.manifest.sessionID)
        XCTAssertEqual(recording.filePath.lastPathComponent, "recording.m4a")
        XCTAssertEqual(mergeCalls, 0)
    }

    func testRecoveryRetriesMergeAndCompletesWithStableSessionID() async throws {
        let valid = AudioFileProbe(isValid: true, duration: 10)
        let context = try await recoveryContext(
            state: .merging,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: true
        )
        let scan = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: []
        )
        let session = try XCTUnwrap(scan.sessions.first)

        let outcome = try await context.service.recover(session)
        let recording = try recoveredRecording(from: outcome)
        let savedManifest = try await context.store.read(from: context.bundle)
        let mergeCalls = await context.merger.mergeCallCount()
        XCTAssertEqual(recording.id, context.manifest.sessionID)
        XCTAssertEqual(recording.filePath.lastPathComponent, "recording.m4a")
        XCTAssertEqual(savedManifest.state, .completed)
        XCTAssertEqual(savedManifest.retryCount, 1)
        XCTAssertEqual(mergeCalls, 1)
    }

    func testMergeFailureFallsBackToMicrophoneAndPreservesRawTracks() async throws {
        let valid = AudioFileProbe(isValid: true, duration: 9)
        let context = try await recoveryContext(
            state: .stopping,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: false
        )
        let microphoneURL = context.bundle.appendingPathComponent("mic_recording.m4a")
        let systemURL = context.bundle.appendingPathComponent("system_recording.m4a")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        let session = await context.service.inspect(manifest: context.manifest, bundleURL: context.bundle)

        let outcome = try await context.service.recover(session)
        guard case .recovered(let recording, let usedFallback) = outcome else {
            return XCTFail("Expected fallback recovery")
        }
        let savedManifest = try await context.store.read(from: context.bundle)
        XCTAssertTrue(usedFallback)
        XCTAssertEqual(recording.filePath, microphoneURL)
        XCTAssertEqual(savedManifest.state, .completed)
        XCTAssertEqual(savedManifest.failureCode, .mergeFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testFallbackRemainsRetryableAcrossRelaunchAndFailedRetry() async throws {
        let valid = AudioFileProbe(isValid: true, duration: 9)
        let context = try await recoveryContext(
            state: .stopping,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: false
        )
        let session = await context.service.inspect(manifest: context.manifest, bundleURL: context.bundle)
        _ = try await context.service.recover(session)

        let relaunched = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: [context.manifest.sessionID]
        )
        let retryable = try XCTUnwrap(relaunched.sessions.first)
        XCTAssertTrue(retryable.inspection.canRetryMerge)

        guard case .unavailable = try await context.service.retryMerge(retryable) else {
            return XCTFail("A failed retry must remain actionable")
        }
        let afterFailure = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: [context.manifest.sessionID]
        )
        XCTAssertEqual(afterFailure.sessions.map(\.id), [context.manifest.sessionID])
        let failedManifest = try await context.store.read(from: context.bundle)
        XCTAssertEqual(failedManifest.failureCode, .mergeFailed)
    }

    func testSuccessfulRetryRepointsExistingLibraryEntryWithoutDuplicate() {
        let id = UUID()
        let fallback = makeRecording(id: id)
        let merged = Recording(
            id: id,
            name: fallback.name,
            date: fallback.date,
            duration: 12,
            filePath: URL(fileURLWithPath: "/tmp/recording.m4a"),
            systemAudioFilePath: nil,
            groupId: nil,
            groupName: nil
        )

        let updated = RecordingLibraryUpdate.replacingAudio(in: [fallback], with: merged)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.id, id)
        XCTAssertEqual(updated.first?.filePath, merged.filePath)
        XCTAssertEqual(updated.first?.duration, 12)
    }

    func testRecoverySupportsMicOnlySystemOnlyAndNoAudio() async throws {
        for (filename, expected) in [
            ("mic_recording.m4a", "mic_recording.m4a"),
            ("system_recording.m4a", "system_recording.m4a")
        ] {
            let context = try await recoveryContext(
                state: .capturing,
                probes: [filename: AudioFileProbe(isValid: true, duration: 4)]
            )
            let session = await context.service.inspect(manifest: context.manifest, bundleURL: context.bundle)
            let outcome = try await context.service.recover(session)
            XCTAssertEqual(try recoveredRecording(from: outcome).filePath.lastPathComponent, expected)
        }

        let empty = try await recoveryContext(state: .failed, probes: [:])
        let session = await empty.service.inspect(manifest: empty.manifest, bundleURL: empty.bundle)
        guard case .unavailable = try await empty.service.recover(session) else {
            return XCTFail("Expected unavailable recovery")
        }
        let failedManifest = try await empty.store.read(from: empty.bundle)
        XCTAssertEqual(failedManifest.failureCode, .noValidAudio)
    }

    func testRecoveryScanIsIdempotentAndSkipsDismissedExistingAndLegacyBundles() async throws {
        let context = try await recoveryContext(
            state: .completed,
            probes: ["recording.m4a": AudioFileProbe(isValid: true, duration: 3)]
        )
        let legacy = context.root.appendingPathComponent("recording_legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let excludedScan = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: [context.manifest.sessionID]
        )
        XCTAssertEqual(excludedScan.sessions.count, 0)

        var dismissed = context.manifest
        dismissed.state = .dismissed
        try await context.store.write(dismissed, to: context.bundle)
        let dismissedScan = try await context.service.scan(
            recordingsDirectory: context.root,
            excluding: []
        )
        XCTAssertEqual(dismissedScan.sessions.count, 0)
    }

    func testLifecycleGateRejectsDuplicateStartAndStopIncludingPausedStop() {
        var gate = RecordingLifecycleGate()
        XCTAssertTrue(gate.beginStart())
        XCTAssertFalse(gate.beginStart())
        gate.didStart()
        XCTAssertTrue(gate.pause())
        XCTAssertTrue(gate.beginStop())
        XCTAssertFalse(gate.beginStop())
        gate.finishStop()
        XCTAssertEqual(gate.phase, .idle)
    }

    func testInitialRecoveryGateBlocksStartUntilScanFinishes() {
        var gate = InitialRecordingRecoveryGate()
        XCTAssertFalse(gate.canStartRecording)
        gate.finish()
        XCTAssertTrue(gate.canStartRecording)
    }

    func testFailedStartRecoveryPolicyOnlySurfacesAfterCaptureBegins() {
        XCTAssertFalse(FailedStartRecoveryPolicy.shouldSurfaceSession(captureDidBegin: false))
        XCTAssertTrue(FailedStartRecoveryPolicy.shouldSurfaceSession(captureDidBegin: true))
    }

    func testMicrophoneCaptureSessionSerializesResetWithInFlightCallback() throws {
        let writer = BlockingMicrophoneWriter(blockFirstWrite: true)
        let session = MicrophoneCaptureSession(writer: writer, warmupFrames: 0)
        let firstBuffer = try makePCMBuffer(frames: 4, value: 1)
        let callbackFinished = expectation(description: "render callback finished")
        DispatchQueue.global().async {
            _ = session.process(firstBuffer)
            callbackFinished.fulfill()
        }
        XCTAssertEqual(writer.waitUntilFirstWriteStarts(), .success)

        let resetAttempted = DispatchSemaphore(value: 0)
        let resetFinished = expectation(description: "warmup reset finished")
        DispatchQueue.global().async {
            resetAttempted.signal()
            session.resetWarmup(frames: 4)
            resetFinished.fulfill()
        }
        XCTAssertEqual(resetAttempted.wait(timeout: .now() + 1), .success)
        writer.allowFirstWriteToFinish()
        wait(for: [callbackFinished, resetFinished], timeout: 2)

        let resumedBuffer = try makePCMBuffer(frames: 4, value: 1)
        XCTAssertNotNil(session.process(resumedBuffer))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: resumedBuffer.floatChannelData?[0], count: 4)), [0, 0, 0, 0])
        XCTAssertEqual(writer.writeCount, 2)
    }

    func testMicrophoneCaptureSessionStopWaitsForWriteAndRejectsLateCallback() throws {
        let writer = BlockingMicrophoneWriter(blockFirstWrite: true)
        let session = MicrophoneCaptureSession(writer: writer, warmupFrames: 2)
        let firstBuffer = try makePCMBuffer(frames: 4, value: 1)
        let callbackFinished = expectation(description: "render callback finished")
        DispatchQueue.global().async {
            _ = session.process(firstBuffer)
            callbackFinished.fulfill()
        }
        XCTAssertEqual(writer.waitUntilFirstWriteStarts(), .success)

        let stopAttempted = DispatchSemaphore(value: 0)
        let stopFinished = expectation(description: "capture stop finished")
        DispatchQueue.global().async {
            stopAttempted.signal()
            session.stop()
            stopFinished.fulfill()
        }
        XCTAssertEqual(stopAttempted.wait(timeout: .now() + 1), .success)
        writer.allowFirstWriteToFinish()
        wait(for: [callbackFinished, stopFinished], timeout: 2)

        let lateBuffer = try makePCMBuffer(frames: 4, value: 1)
        XCTAssertNil(session.process(lateBuffer))
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(session.remainingWarmupFrames(), 0)
    }

    func testMicrophoneCaptureSessionPreservesWarmupAndWritesRealAudioFile() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("mic.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let session = MicrophoneCaptureSession(writer: writer, warmupFrames: 2)
            let buffer = try makePCMBuffer(frames: 4, value: 0.5, format: format)
            XCTAssertNotNil(session.process(buffer))
            XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: 4)), [0, 0, 0.5, 0.5])
            XCTAssertEqual(session.remainingWarmupFrames(), 0)
            session.stop()
        }

        let reader = try AVAudioFile(forReading: url)
        let persisted = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4))
        try reader.read(into: persisted)
        XCTAssertEqual(persisted.frameLength, 4)
        let samples = try XCTUnwrap(persisted.floatChannelData?[0])
        XCTAssertEqual(samples[0], Float(0), accuracy: 0.0001)
        XCTAssertEqual(samples[1], Float(0), accuracy: 0.0001)
        XCTAssertEqual(samples[2], Float(0.5), accuracy: 0.0001)
    }

    func testSessionActionGateSerializesRecoverRetryAndDismiss() {
        let id = UUID()
        var gate = RecordingSessionActionGate()
        XCTAssertTrue(gate.begin(id))
        XCTAssertFalse(gate.begin(id), "A conflicting action for the same session must be rejected")
        XCTAssertTrue(gate.contains(id))
        gate.finish(id)
        XCTAssertTrue(gate.begin(id))
    }

    func testDismissDuringMergeAbortsCompletionDeterministically() async throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("recording_20260714_120000_\(UUID().uuidString)")
        let store = RecordingSessionManifestStore()
        let manifest = makeManifest(state: .failed)
        try await store.write(manifest, to: bundle)
        let merger = SuspendingAudioMerger()
        let service = RecordingRecoveryService(manifestStore: store, audioMerger: merger)
        let session = await service.inspect(manifest: manifest, bundleURL: bundle)

        let retryTask = Task { try await service.retryMerge(session) }
        await merger.waitForMergeStart()
        var dismissed = try await store.read(from: bundle)
        dismissed.state = .dismissed
        try await store.write(dismissed, to: bundle)
        await merger.finishMerge()

        guard case .ignored = try await retryTask.value else {
            return XCTFail("Completion must re-read and honor a dismissal that wins the race")
        }
        let finalManifest = try await store.read(from: bundle)
        XCTAssertEqual(finalManifest.state, .dismissed)
    }

    func testManifestCompletionCASNeverOverwritesDismissedState() async throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("recording", isDirectory: true)
        let store = RecordingSessionManifestStore()
        var manifest = makeManifest(state: .dismissed)
        manifest.failureCode = .mergeFailed
        try await store.write(manifest, to: bundle)

        let completed = try await store.completeIfNotDismissed(
            in: bundle,
            duration: 8,
            resolvedAudioPath: "recording.m4a",
            clearFailure: true
        )

        XCTAssertNil(completed)
        let persisted = try await store.read(from: bundle)
        XCTAssertEqual(persisted.state, .dismissed)
        XCTAssertEqual(persisted.failureCode, .mergeFailed)
    }

    @MainActor
    func testGlobalLibraryCoordinatorSerializesDeletionSnapshots() async {
        let coordinator = RecordingLibraryMutationCoordinator()
        let barrier = MutationBarrier()
        let firstID = UUID()
        let secondID = UUID()
        var library = [firstID, secondID]

        let firstDelete = Task { @MainActor in
            await coordinator.withLock {
                let snapshot = library
                await barrier.pause()
                library = snapshot.filter { $0 != firstID }
            }
        }
        await barrier.waitUntilPaused()
        let secondDelete = Task { @MainActor in
            await coordinator.withLock {
                let snapshot = library
                library = snapshot.filter { $0 != secondID }
            }
        }
        await barrier.resume()
        await firstDelete.value
        await secondDelete.value

        XCTAssertTrue(library.isEmpty, "A later deletion must not resurrect the first deleted row")
    }

    @MainActor
    func testGlobalLibraryCoordinatorSerializesDeleteAgainstInsert() async {
        let coordinator = RecordingLibraryMutationCoordinator()
        let barrier = MutationBarrier()
        let deletingID = UUID()
        let insertedID = UUID()
        var library = [deletingID]

        let deletion = Task { @MainActor in
            await coordinator.withLock {
                let snapshot = library
                await barrier.pause()
                library = snapshot.filter { $0 != deletingID }
            }
        }
        await barrier.waitUntilPaused()
        let insertion = Task { @MainActor in
            await coordinator.withLock {
                library.append(insertedID)
            }
        }
        await barrier.resume()
        await deletion.value
        await insertion.value

        XCTAssertEqual(library, [insertedID])
    }

    func testDeletionMetadataFailureLeavesAudioAndOriginalLibraryIntact() async throws {
        let deletingID = UUID()
        let original = [makeRecording(id: deletingID), makeRecording(id: UUID())]
        let persisted = original
        var manifestDismissed = false
        var didAttemptFileDeletion = false

        do {
            _ = try await RecordingDeletionTransaction.execute(
                currentRecordings: original,
                deleting: deletingID,
                prepareForDeletion: { manifestDismissed = true },
                rollbackPreparation: { manifestDismissed = false },
                persistRecordings: { _ in throw TestError.forcedMetadataFailure },
                deleteFiles: { didAttemptFileDeletion = true }
            )
            XCTFail("Expected metadata failure")
        } catch let error as RecordingDeletionTransactionError {
            XCTAssertEqual(error.stage, .metadata)
        }

        XCTAssertEqual(persisted.map(\.id), original.map(\.id))
        XCTAssertFalse(manifestDismissed)
        XCTAssertFalse(didAttemptFileDeletion)
    }

    func testDeletionFileFailureRollsBackManifestAndPersistedMetadata() async throws {
        let deletingID = UUID()
        let original = [makeRecording(id: deletingID), makeRecording(id: UUID())]
        var persisted = original
        var persistedCounts: [Int] = []
        var manifestDismissed = false

        do {
            _ = try await RecordingDeletionTransaction.execute(
                currentRecordings: original,
                deleting: deletingID,
                prepareForDeletion: { manifestDismissed = true },
                rollbackPreparation: { manifestDismissed = false },
                persistRecordings: {
                    persisted = $0
                    persistedCounts.append($0.count)
                },
                deleteFiles: { throw TestError.forcedFileFailure }
            )
            XCTFail("Expected file failure")
        } catch let error as RecordingDeletionTransactionError {
            XCTAssertEqual(error.stage, .files)
            XCTAssertTrue(error.rollbackErrors.isEmpty)
        }

        XCTAssertEqual(persistedCounts, [1, 2])
        XCTAssertEqual(persisted.map(\.id), original.map(\.id))
        XCTAssertFalse(manifestDismissed)
    }

    func testRecoverAndRetryMergeHaveDistinctBehavior() async throws {
        let valid = AudioFileProbe(isValid: true, duration: 6)
        let recoverContext = try await recoveryContext(
            state: .failed,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: true
        )
        let recoverSession = await recoverContext.service.inspect(
            manifest: recoverContext.manifest,
            bundleURL: recoverContext.bundle
        )
        let recovered = try await recoverContext.service.recoverAvailableAudio(recoverSession)
        XCTAssertEqual(try recoveredRecording(from: recovered).filePath.lastPathComponent, "mic_recording.m4a")
        let recoverMergeCalls = await recoverContext.merger.mergeCallCount()
        XCTAssertEqual(recoverMergeCalls, 0)

        let retryContext = try await recoveryContext(
            state: .failed,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: true
        )
        let retrySession = await retryContext.service.inspect(
            manifest: retryContext.manifest,
            bundleURL: retryContext.bundle
        )
        let retried = try await retryContext.service.retryMerge(retrySession)
        XCTAssertEqual(try recoveredRecording(from: retried).filePath.lastPathComponent, "recording.m4a")
        let retryMergeCalls = await retryContext.merger.mergeCallCount()
        XCTAssertEqual(retryMergeCalls, 1)

        let failedRetryContext = try await recoveryContext(
            state: .failed,
            probes: ["mic_recording.m4a": valid, "system_recording.m4a": valid],
            mergeSucceeds: false
        )
        let failedRetrySession = await failedRetryContext.service.inspect(
            manifest: failedRetryContext.manifest,
            bundleURL: failedRetryContext.bundle
        )
        guard case .unavailable = try await failedRetryContext.service.retryMerge(failedRetrySession) else {
            return XCTFail("A failed explicit retry must remain recoverable")
        }
        let failedRetryManifest = try await failedRetryContext.store.read(from: failedRetryContext.bundle)
        XCTAssertEqual(failedRetryManifest.failureCode, .mergeFailed)
    }

    func testLegacyMetadataMigratesOnlyExactBundleThenSupportsRecoveryAndDeletion() async throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let date = "20260714_120000"
        let exactBundle = root.appendingPathComponent("recording_\(date)_\(id.uuidString)", isDirectory: true)
        let unrelatedBundle = root.appendingPathComponent("recording_\(date)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exactBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedBundle, withIntermediateDirectories: true)
        let valid = AudioFileProbe(isValid: true, duration: 7)
        let merger = FakeAudioMerger(probes: ["mic_recording.m4a": valid], mergeSucceeds: false)
        let store = RecordingSessionManifestStore()
        let migration = LegacyRecordingMigrationService(manifestStore: store, audioMerger: merger)

        let outcome = await migration.migrate(
            metadata: ["name": "Legacy", "date": date, "uuid": id.uuidString],
            recordingsDirectory: root
        )
        guard case .migrated(let migrated) = outcome else { return XCTFail("Expected exact legacy migration") }
        XCTAssertEqual(migrated.manifest.sessionID, id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: unrelatedBundle.appendingPathComponent(RecordingSessionManifest.filename).path
        ))

        let service = RecordingRecoveryService(manifestStore: store, audioMerger: merger)
        let session = await service.inspect(manifest: migrated.manifest, bundleURL: exactBundle)
        let recording = try recoveredRecording(from: try await service.recoverAvailableAudio(session))
        XCTAssertEqual(recording.id, id)

        var persisted = [recording]
        let originalManifest = try await store.read(from: exactBundle)
        persisted = try await RecordingDeletionTransaction.execute(
            currentRecordings: persisted,
            deleting: id,
            prepareForDeletion: {
                var dismissed = originalManifest
                dismissed.state = .dismissed
                try await store.write(dismissed, to: exactBundle)
            },
            rollbackPreparation: { try await store.write(originalManifest, to: exactBundle) },
            persistRecordings: { persisted = $0 },
            deleteFiles: { try FileManager.default.removeItem(at: exactBundle) }
        )
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactBundle.path))
    }

    func testLegacyMetadataReconcilesFolderUUIDToExistingRecordingIdentityWithoutDuplicate() async throws {
        let root = try temporaryDirectory()
        let folderID = UUID()
        let existingID = UUID()
        let date = "20260714_120000"
        let bundle = root.appendingPathComponent(
            "recording_\(date)_\(folderID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let audioURL = bundle.appendingPathComponent("recording.m4a")
        try Data("legacy".utf8).write(to: audioURL)
        let existing = Recording(
            id: existingID,
            name: "Already indexed",
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            duration: 42,
            filePath: audioURL,
            systemAudioFilePath: nil,
            groupId: nil,
            groupName: nil
        )
        let valid = AudioFileProbe(isValid: true, duration: 7)
        let merger = FakeAudioMerger(probes: ["recording.m4a": valid], mergeSucceeds: false)
        let store = RecordingSessionManifestStore()
        let migration = LegacyRecordingMigrationService(manifestStore: store, audioMerger: merger)

        let outcome = await migration.migrate(
            metadata: ["name": "Stale metadata name", "date": date, "uuid": folderID.uuidString],
            recordingsDirectory: root,
            existingRecordings: [existing]
        )
        guard case .migrated(let migrated) = outcome else { return XCTFail("Expected reconciled migration") }
        XCTAssertEqual(migrated.manifest.sessionID, existingID)
        XCTAssertEqual(migrated.manifest.displayName, existing.name)
        XCTAssertEqual(migrated.manifest.duration, existing.duration)
        XCTAssertEqual(migrated.manifest.resolvedAudioPath, "recording.m4a")
        XCTAssertEqual(migrated.manifest.state, .completed)

        let service = RecordingRecoveryService(manifestStore: store, audioMerger: merger)
        let relaunchScan = try await service.scan(recordingsDirectory: root, excluding: [existingID])
        XCTAssertTrue(relaunchScan.sessions.isEmpty, "Relaunch must not create a folder-UUID duplicate")

        var library = [existing]
        let originalManifest = try await store.read(from: bundle)
        library = try await RecordingDeletionTransaction.execute(
            currentRecordings: library,
            deleting: existingID,
            prepareForDeletion: {
                var dismissed = originalManifest
                dismissed.state = .dismissed
                try await store.write(dismissed, to: bundle)
            },
            rollbackPreparation: { try await store.write(originalManifest, to: bundle) },
            persistRecordings: { library = $0 },
            deleteFiles: { try FileManager.default.removeItem(at: bundle) }
        )
        XCTAssertTrue(library.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testLaunchPathReconciliationRepairsPreviouslyMigratedWrongIDManifest() async throws {
        let root = try temporaryDirectory()
        let folderID = UUID()
        let existingID = UUID()
        let bundle = root.appendingPathComponent(
            "recording_20260714_120000_\(folderID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let audioURL = bundle.appendingPathComponent("recording.m4a")
        try Data("legacy".utf8).write(to: audioURL)
        var wrongIdentity = RecordingSessionManifest(
            sessionID: folderID,
            displayName: "Folder identity",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            selectedInputID: "",
            state: .completed
        )
        wrongIdentity.resolvedAudioPath = "recording.m4a"
        let store = RecordingSessionManifestStore()
        try await store.write(wrongIdentity, to: bundle)
        let existing = Recording(
            id: existingID,
            name: "Library identity",
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            duration: 21,
            filePath: audioURL,
            systemAudioFilePath: nil,
            groupId: nil,
            groupName: nil
        )

        let match = try XCTUnwrap(RecordingLibraryReferenceReconciler.matchingRecording(
            for: wrongIdentity,
            bundleURL: bundle,
            recordingsDirectory: root,
            recordings: [existing]
        ))
        let reconciled = RecordingLibraryReferenceReconciler.reidentifiedManifest(
            wrongIdentity,
            recording: match.recording,
            audioFilename: match.audioFilename
        )
        try await store.write(reconciled, to: bundle)

        let savedManifest = try await store.read(from: bundle)
        XCTAssertEqual(savedManifest.sessionID, existingID)
        let service = RecordingRecoveryService(
            manifestStore: store,
            audioMerger: FakeAudioMerger(
                probes: ["recording.m4a": AudioFileProbe(isValid: true, duration: 21)],
                mergeSucceeds: false
            )
        )
        let scan = try await service.scan(recordingsDirectory: root, excluding: [existingID])
        XCTAssertTrue(scan.sessions.isEmpty)
    }

    func testLegacyPathReconciliationNormalizesSafePathsAndRejectsEscapes() throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent(
            "recording_20260714_120000_\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let audioURL = bundle.appendingPathComponent("recording.m4a")
        try Data("inside".utf8).write(to: audioURL)
        let manifest = makeManifest(state: .completed)
        let normalizedPath = bundle.appendingPathComponent("temporary").appendingPathComponent("..")
            .appendingPathComponent("recording.m4a")
        XCTAssertNotNil(RecordingLibraryReferenceReconciler.matchingRecording(
            for: manifest,
            bundleURL: bundle,
            recordingsDirectory: root,
            recordings: [makeRecording(id: UUID(), filePath: normalizedPath)]
        ))

        let outside = root.appendingPathComponent("outside.m4a")
        try Data("outside".utf8).write(to: outside)
        XCTAssertNil(RecordingLibraryReferenceReconciler.matchingRecording(
            for: manifest,
            bundleURL: bundle,
            recordingsDirectory: root,
            recordings: [makeRecording(id: UUID(), filePath: outside)]
        ))

        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.createSymbolicLink(at: audioURL, withDestinationURL: outside)
        XCTAssertNil(RecordingLibraryReferenceReconciler.matchingRecording(
            for: manifest,
            bundleURL: bundle,
            recordingsDirectory: root,
            recordings: [makeRecording(id: UUID(), filePath: audioURL)]
        ))
    }

    func testLegacyMigrationRejectsSymlinkedBundleAndScanReportsItCorrupt() async throws {
        let root = try temporaryDirectory()
        let folderID = UUID()
        let date = "20260714_120000"
        let externalBundle = root.appendingPathComponent("external", isDirectory: true)
        let store = RecordingSessionManifestStore()
        try await store.write(makeManifest(state: .failed), to: externalBundle)
        let symlinkBundle = root.appendingPathComponent(
            "recording_\(date)_\(folderID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: symlinkBundle, withDestinationURL: externalBundle)
        let migration = LegacyRecordingMigrationService(
            manifestStore: store,
            audioMerger: FakeAudioMerger(
                probes: ["recording.m4a": AudioFileProbe(isValid: true, duration: 1)],
                mergeSucceeds: false
            )
        )

        let outcome = await migration.migrate(
            metadata: ["name": "Unsafe", "date": date, "uuid": folderID.uuidString],
            recordingsDirectory: root,
            existingRecordings: []
        )
        guard case .conclusivelyAbsentOrInvalid = outcome else {
            return XCTFail("A symlinked legacy bundle must not be migrated")
        }
        let scan = try await store.scan(recordingsDirectory: root)
        XCTAssertEqual(scan.corruptBundleURLs.map(\.lastPathComponent), [symlinkBundle.lastPathComponent])
    }

    func testManifestlessLegacyRecordingBundleDeletionRequiresExactDirectKnownShape() throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let exactBundle = root.appendingPathComponent(
            "recording_20260714_120000_\(id.uuidString)",
            isDirectory: true
        )
        let knownAudio = exactBundle.appendingPathComponent("mic_recording.m4a")
        let knownRecording = makeRecording(id: id, filePath: knownAudio)
        XCTAssertEqual(
            RecordingBundleDeletionPolicy.deletionURL(
                for: knownRecording,
                recordingsDirectory: root,
                hasManifest: false
            ),
            exactBundle
        )

        let unknownAudio = exactBundle.appendingPathComponent("notes.txt")
        XCTAssertEqual(
            RecordingBundleDeletionPolicy.deletionURL(
                for: makeRecording(id: UUID(), filePath: unknownAudio),
                recordingsDirectory: root,
                hasManifest: false
            ),
            unknownAudio
        )
        let nestedAudio = root.appendingPathComponent("nested").appendingPathComponent(exactBundle.lastPathComponent)
            .appendingPathComponent("recording.m4a")
        XCTAssertEqual(
            RecordingBundleDeletionPolicy.deletionURL(
                for: makeRecording(id: UUID(), filePath: nestedAudio),
                recordingsDirectory: root,
                hasManifest: false
            ),
            nestedAudio
        )
    }

    func testImportCrashBoundariesCleanStagingAndRecoverFinalManifest() async throws {
        let root = try temporaryDirectory()
        let staging = root.appendingPathComponent(".import_staging_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("recording.m4a"))
        let merger = FakeAudioMerger(
            probes: [
                "recording.m4a": AudioFileProbe(isValid: true, duration: 2),
                "recording.wav": AudioFileProbe(isValid: true, duration: 2)
            ],
            mergeSucceeds: false
        )
        let store = RecordingSessionManifestStore()
        let importer = RecordingImportService(audioMerger: merger, manifestStore: store)
        try importer.cleanupInterruptedStaging(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let final = root.appendingPathComponent("import_20260714_120000_\(UUID().uuidString)", isDirectory: true)
        var manifest = RecordingSessionManifest(
            sessionID: UUID(),
            displayName: "Interrupted import",
            createdAt: Date(),
            selectedInputID: "",
            mergedPath: "recording.wav",
            state: .preparing
        )
        manifest.duration = 2
        try await store.write(manifest, to: final)
        let service = RecordingRecoveryService(manifestStore: store, audioMerger: merger)
        let scan = try await service.scan(recordingsDirectory: root, excluding: [])
        XCTAssertEqual(scan.sessions.map(\.id), [manifest.sessionID])
        let importSession = try XCTUnwrap(scan.sessions.first)
        let importOutcome = try await service.recoverAvailableAudio(importSession)
        XCTAssertEqual(try recoveredRecording(from: importOutcome).id, manifest.sessionID)
    }

    func testUnsafeManifestPathsAndSymlinkEscapesAreReportedCorruptAndDismissible() async throws {
        let root = try temporaryDirectory()
        let store = RecordingSessionManifestStore()
        for unsafePath in ["../recording.m4a", "/tmp/recording.m4a"] {
            let bundle = root.appendingPathComponent("unsafe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            var manifest = makeManifest(state: .failed)
            manifest.mergedPath = unsafePath
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: bundle.appendingPathComponent(RecordingSessionManifest.filename))
        }

        let outside = root.appendingPathComponent("outside.m4a")
        try Data("audio".utf8).write(to: outside)
        let symlinkBundle = root.appendingPathComponent("symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkBundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkBundle.appendingPathComponent("recording.m4a"),
            withDestinationURL: outside
        )
        do {
            try await store.write(makeManifest(state: .failed), to: symlinkBundle)
            XCTFail("Expected symlink escape rejection")
        } catch { }

        let firstScan = try await store.scan(recordingsDirectory: root)
        XCTAssertEqual(firstScan.corruptBundleURLs.count, 2)
        let dismissed = try XCTUnwrap(firstScan.corruptBundleURLs.first)
        try Data("dismissed".utf8).write(
            to: dismissed.appendingPathComponent(RecordingSessionManifest.dismissalFilename),
            options: .atomic
        )
        let secondScan = try await store.scan(recordingsDirectory: root)
        XCTAssertEqual(secondScan.corruptBundleURLs.count, 1)
    }

    func testCorruptImportedManifestRepairAcceptsOnlyDirectRegularRecordingFile() throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("import_20260714_120000_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: bundle.appendingPathComponent("recording.wav"))
        let outside = root.appendingPathComponent("outside.mp3")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("recording.mp3"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("recording.aac"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(RecordingManifestRepairCandidate.audioFilename(in: bundle), "recording.wav")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("recording.wav"))
        XCTAssertNil(RecordingManifestRepairCandidate.audioFilename(in: bundle))
    }

    func testImportRollbackRemovesStagingForInvalidAudioAndUnavailableRoot() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("broken.wav")
        try Data("invalid".utf8).write(to: source)
        let destination = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let merger = FakeAudioMerger(probes: [:], mergeSucceeds: false)
        let importer = RecordingImportService(audioMerger: merger)

        do {
            _ = try await importer.importSingle(
                from: source,
                into: destination,
                groupId: nil,
                groupName: nil,
                customName: nil
            )
            XCTFail("Expected invalid audio")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

        let fileRoot = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: fileRoot)
        do {
            _ = try await importer.importSingle(
                from: source,
                into: fileRoot,
                groupId: nil,
                groupName: nil,
                customName: nil
            )
            XCTFail("Expected unavailable destination")
        } catch { }
    }

    func testBatchImportReportsPartialFailureExplicitlyWithoutOrphans() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let validSource = root.appendingPathComponent("valid.wav")
        let invalidSource = root.appendingPathComponent("invalid.wav")
        try Data("valid".utf8).write(to: validSource)
        try Data("invalid".utf8).write(to: invalidSource)
        let merger = FakeAudioMerger(probes: [:], mergeSucceeds: false, probeFileContents: true)
        let importer = RecordingImportService(audioMerger: merger)

        let result = await importer.importBatch(
            from: [validSource, invalidSource],
            into: destination,
            groupId: UUID(),
            groupName: "Batch"
        )

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.failures.map(\.filename), ["invalid.wav"])
        let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(contents.filter { $0.hasPrefix("import_") }.count, 1)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".import_staging_") })
    }

    func testRuntimeGeneratedShortAudioFixtureCanBeProbedAndImported() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("fixture.caf")
        try makeShortAudioFixture(at: source)
        let destination = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let merger = AVFoundationAudioMerger()
        let probe = await merger.probeAudio(at: source)
        XCTAssertTrue(probe.isValid)

        let recording = try await RecordingImportService(audioMerger: merger).importSingle(
            from: source,
            into: destination,
            groupId: nil,
            groupName: nil,
            customName: "Fixture"
        )
        XCTAssertEqual(recording.name, "Fixture")
        XCTAssertGreaterThan(recording.duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.filePath.path))
    }

    private func makeManifest(state: RecordingSessionState) -> RecordingSessionManifest {
        var manifest = RecordingSessionManifest(
            sessionID: UUID(),
            displayName: "Interrupted session",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            selectedInputID: "test-input",
            state: state
        )
        manifest.captureStartedAt = Date(timeIntervalSinceReferenceDate: 1_001)
        return manifest
    }

    private func makeRecording(
        id: UUID,
        filePath: URL? = nil
    ) -> Recording {
        Recording(
            id: id,
            name: "Recording \(id.uuidString)",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            duration: 1,
            filePath: filePath ?? URL(fileURLWithPath: "/tmp/\(id.uuidString).m4a"),
            systemAudioFilePath: nil,
            groupId: nil,
            groupName: nil
        )
    }

    private func recoveryContext(
        state: RecordingSessionState,
        probes: [String: AudioFileProbe],
        mergeSucceeds: Bool = false
    ) async throws -> RecoveryContext {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("recording_bundle", isDirectory: true)
        let store = RecordingSessionManifestStore()
        let manifest = makeManifest(state: state)
        try await store.write(manifest, to: bundle)
        let merger = FakeAudioMerger(probes: probes, mergeSucceeds: mergeSucceeds)
        return RecoveryContext(
            root: root,
            bundle: bundle,
            manifest: manifest,
            store: store,
            merger: merger,
            service: RecordingRecoveryService(manifestStore: store, audioMerger: merger)
        )
    }

    private func recoveredRecording(from outcome: RecordingRecoveryOutcome) throws -> Recording {
        guard case .recovered(let recording, _) = outcome else {
            throw TestError.expectedRecovery
        }
        return recording
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeShortAudioFixture(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = sin(Float(index) * 0.05) * 0.1
            }
        }
        try file.write(from: buffer)
    }

    private func makePCMBuffer(
        frames: AVAudioFrameCount,
        value: Float,
        format: AVAudioFormat? = nil
    ) throws -> AVAudioPCMBuffer {
        let format = try format ?? XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) { samples[index] = value }
        }
        return buffer
    }
}

private struct RecoveryContext {
    let root: URL
    let bundle: URL
    let manifest: RecordingSessionManifest
    let store: RecordingSessionManifestStore
    let merger: FakeAudioMerger
    let service: RecordingRecoveryService
}

private actor FakeAudioMerger: AudioMerging {
    private var probes: [String: AudioFileProbe]
    private let mergeSucceeds: Bool
    private let probeFileContents: Bool
    private var mergeCalls = 0

    init(
        probes: [String: AudioFileProbe],
        mergeSucceeds: Bool,
        probeFileContents: Bool = false
    ) {
        self.probes = probes
        self.mergeSucceeds = mergeSucceeds
        self.probeFileContents = probeFileContents
    }

    func probeAudio(at url: URL) async -> AudioFileProbe {
        if let probe = probes[url.path] ?? probes[url.lastPathComponent] { return probe }
        if probeFileContents, let data = try? Data(contentsOf: url), data == Data("valid".utf8) {
            return AudioFileProbe(isValid: true, duration: 1)
        }
        return .invalid
    }

    func merge(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL {
        mergeCalls += 1
        guard mergeSucceeds else { throw TestError.fakeMergeFailure }
        try Data("merged".utf8).write(to: outputURL)
        probes[outputURL.path] = AudioFileProbe(isValid: true, duration: 10)
        return outputURL
    }

    func mergeCallCount() -> Int {
        mergeCalls
    }
}

private actor SuspendingAudioMerger: AudioMerging {
    private var mergeStarted = false
    private var mergeFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func probeAudio(at url: URL) async -> AudioFileProbe {
        switch url.lastPathComponent {
        case "mic_recording.m4a", "system_recording.m4a":
            return AudioFileProbe(isValid: true, duration: 5)
        case "recording.m4a" where mergeFinished:
            return AudioFileProbe(isValid: true, duration: 5)
        default:
            return .invalid
        }
    }

    func merge(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL {
        mergeStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        mergeFinished = true
        return outputURL
    }

    func waitForMergeStart() async {
        guard !mergeStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishMerge() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor MutationBarrier {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class BlockingMicrophoneWriter: MicrophoneAudioWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let blockFirstWrite: Bool
    private let firstWriteStarted = DispatchSemaphore(value: 0)
    private let firstWriteMayFinish = DispatchSemaphore(value: 0)
    private var writes = 0

    init(blockFirstWrite: Bool) {
        self.blockFirstWrite = blockFirstWrite
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        writes += 1
        let shouldBlock = blockFirstWrite && writes == 1
        lock.unlock()
        if shouldBlock {
            firstWriteStarted.signal()
            firstWriteMayFinish.wait()
        }
    }

    func waitUntilFirstWriteStarts() -> DispatchTimeoutResult {
        firstWriteStarted.wait(timeout: .now() + 1)
    }

    func allowFirstWriteToFinish() {
        firstWriteMayFinish.signal()
    }
}

private enum TestError: Error {
    case expectedRecovery
    case fakeMergeFailure
    case forcedMetadataFailure
    case forcedFileFailure
}
