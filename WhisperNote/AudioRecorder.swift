import Foundation
import AVFoundation
import SwiftUI
import AppKit
import CoreAudio
import AudioUnit
import os.log

struct MicDevice: Identifiable, Equatable {
    let id: String
    let localizedName: String
}

enum RecordingStartOutcome {
    case started(Recording)
    case alreadyActive(Recording?)
}

enum RecordingStopOutcome {
    case saved(Recording)
    case alreadyStopped
    case alreadyStopping
    case recoverable(RecoverableRecordingSession)
}

enum LibraryPersistenceError: LocalizedError {
    case staleGeneration

    var errorDescription: String? {
        "The operation was cancelled because the active library changed."
    }
}

protocol MicrophoneAudioWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: MicrophoneAudioWriting { }

/// The audio render callback's complete mutable boundary. AVAudioEngine can deliver a
/// final callback while a tap is being removed, so file ownership, warm-up mutation,
/// writes, reset, and invalidation must share one lock instead of reaching into
/// AudioRecorder's UI-owned state.
final class MicrophoneCaptureSession: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: (any MicrophoneAudioWriting)?
    private var warmupFramesRemaining: AVAudioFramePosition
    private var isActive = true

    init(writer: any MicrophoneAudioWriting, warmupFrames: AVAudioFramePosition) {
        self.writer = writer
        self.warmupFramesRemaining = max(0, warmupFrames)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, let writer else { return nil }

        applyWarmupMute(to: buffer)
        try? writer.write(from: buffer)
        return Self.normalizedLevel(in: buffer)
    }

    func resetWarmup(frames: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        warmupFramesRemaining = max(0, frames)
    }

    /// Waits for an in-flight write, then makes every later render callback a no-op.
    func stop() {
        lock.lock()
        isActive = false
        writer = nil
        warmupFramesRemaining = 0
        lock.unlock()
    }

    func remainingWarmupFrames() -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return warmupFramesRemaining
    }

    private func applyWarmupMute(to buffer: AVAudioPCMBuffer) {
        guard warmupFramesRemaining > 0, buffer.frameLength > 0 else { return }
        let framesToMute = AVAudioFrameCount(
            min(warmupFramesRemaining, AVAudioFramePosition(buffer.frameLength))
        )
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            let bytesPerFrame = Int(audioBuffer.mDataByteSize) / Int(buffer.frameLength)
            memset(data, 0, Int(framesToMute) * bytesPerFrame)
        }
        warmupFramesRemaining -= AVAudioFramePosition(framesToMute)
    }

    private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(channelCount * frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (Double(decibels) + 60) / 60))
    }
}

class AudioRecorder: NSObject, ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentRecording: Recording?
    @Published var isMicrophoneMuted = false // Default to unmuted
    @Published var lastError: String? // Surfaced to the UI (stop/merge/import failures)
    @Published var audioLevel: Double = 0
    @Published var availableMicrophones: [MicDevice] = []
    @Published var recoverableSessions: [RecoverableRecordingSession] = []
    @Published var corruptRecordingBundles: [CorruptRecordingBundle] = []
    @Published private(set) var isLibraryRebinding = false
    @Published private(set) var corruptRecoveryActionsInFlight: Set<String> = []
    @Published private(set) var recoveryActionsInFlight: Set<UUID> = []
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published private(set) var isInitialRecoveryComplete = false

    private var durationTimer: Timer?
    private var microphoneStateTimer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0

    @AppStorage("audioQuality") private var audioQuality = "high"
    private lazy var directoryManager = DirectoryManager.shared
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let manifestStore: RecordingSessionManifestStore
    private let recoveryService: RecordingRecoveryService
    private let legacyMigrationService: LegacyRecordingMigrationService
    private let importService: RecordingImportService
    private let libraryMutations = RecordingLibraryMutationCoordinator()
    private var boundRecordingsDirectory = DirectoryManager.shared.getRecordingsDirectory()
    private var libraryGeneration = 0
    var testImportDelayNanoseconds: UInt64 = 0

    // Logging
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "AudioRecorder")
    // Recording state (Core Audio process tap + AVAudioEngine, replacing RecordKit)
    private var recordingEngine: AVAudioEngine?
    private var microphoneCaptureSession: MicrophoneCaptureSession?
    private var systemAudioTap: SystemAudioTap?
    private var micAudioLevel: Double = 0
    private var systemAudioLevel: Double = 0
    private var systemAudioPermissionAvailable = true
    private var recordingDirectoryURL: URL?
    private var currentManifest: RecordingSessionManifest?
    private var lifecycleGate = RecordingLifecycleGate()
    private var initialRecoveryGate = InitialRecordingRecoveryGate()
    private var recoveryActionGate = RecordingSessionActionGate()
    private var deletionActionGate = RecordingSessionActionGate()
    private var deletionActionsInFlight: Set<UUID> = []
    private var deletionDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let micWarmupMuteDuration = 0.97

    override init() {
        let manifestStore = RecordingSessionManifestStore()
        let audioMerger = AVFoundationAudioMerger()
        self.manifestStore = manifestStore
        self.recoveryService = RecordingRecoveryService(
            manifestStore: manifestStore,
            audioMerger: audioMerger
        )
        self.legacyMigrationService = LegacyRecordingMigrationService(
            manifestStore: manifestStore,
            audioMerger: audioMerger
        )
        self.importService = RecordingImportService(audioMerger: audioMerger, manifestStore: manifestStore)
        super.init()
        guard !WhisperNoteRuntime.isUnitTestMode else { return }
        loadRecordings()

        // Start with microphone unmuted
        isMicrophoneMuted = false

        // Try to set system microphone to unmuted at startup
        do {
            try setMicrophoneMuteSystem(muted: false)
        } catch {
            // Silently fail if we can't set the microphone state
        }

        // Set up a timer to periodically check microphone state
        microphoneStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMicrophoneMuteState()
        }

        // Load devices without prompting; ContentView triggers the permission flow after launch.
        Task {
            await loadAvailableMicrophones()
        }

        Task { @MainActor [weak self] in
            await self?.recoverInterruptedSessionsOnLaunch()
        }
    }

    // MARK: - Microphone Devices

    /// Load available microphones without checking permissions.
    func loadAvailableMicrophones() async {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { MicDevice(id: $0.uniqueID, localizedName: $0.localizedName) }

        await MainActor.run {
            self.availableMicrophones = devices
        }
    }

    deinit {
        microphoneStateTimer?.invalidate()
        stopMicCapture()
        systemAudioTap?.stop()
    }

    @MainActor
    func startRecording(name: String, microphoneId: String = "") async throws -> RecordingStartOutcome {
        guard !isLibraryRebinding else { throw AudioRecorderError.recoveryInProgress }
        guard initialRecoveryGate.canStartRecording else {
            throw AudioRecorderError.recoveryInProgress
        }
        guard lifecycleGate.beginStart() else {
            return .alreadyActive(currentRecording)
        }
        isStartingRecording = true
        defer { isStartingRecording = false }

        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied,
              await checkAndRequestPermissions() else {
            lifecycleGate.didFailStart()
            throw AudioRecorderError.permissionDenied
        }

        let sessionID = UUID()
        let createdAt = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let bundleURL = boundRecordingsDirectory.appendingPathComponent(
            "recording_\(formatter.string(from: createdAt))_\(sessionID.uuidString)",
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } catch {
            lifecycleGate.didFailStart()
            throw AudioRecorderError.directoryError
        }

        var manifest = RecordingSessionManifest(
            sessionID: sessionID,
            displayName: name,
            createdAt: createdAt,
            selectedInputID: microphoneId
        )

        do {
            try await manifestStore.write(manifest, to: bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            lifecycleGate.didFailStart()
            throw AudioRecorderError.manifestWriteFailed
        }

        recordingDirectoryURL = bundleURL
        currentManifest = manifest
        let microphoneURL = manifest.url(for: manifest.microphonePath, in: bundleURL)
        let systemURL = manifest.url(for: manifest.systemAudioPath, in: bundleURL)

        var captureDidBegin = false
        do {
            try startMicCapture(to: microphoneURL, microphoneId: microphoneId)
            captureDidBegin = true

            let tap = SystemAudioTap()
            tap.levelHandler = { [weak self, weak tap] level in
                DispatchQueue.main.async { [weak self, weak tap] in
                    guard let self, let tap, self.systemAudioTap === tap else { return }
                    self.systemAudioLevel = self.isRecording ? level : 0
                    self.updateAudioLevel()
                }
            }
            systemAudioTap = tap
            try tap.start(outputURL: systemURL)

            manifest.state = .capturing
            manifest.captureStartedAt = Date()
            manifest.updatedAt = Date()
            try await manifestStore.write(manifest, to: bundleURL)
            currentManifest = manifest

            let recording = Recording(
                id: sessionID,
                name: name,
                date: manifest.captureStartedAt ?? createdAt,
                duration: 0,
                filePath: microphoneURL,
                systemAudioFilePath: nil
            )
            currentRecording = recording
            isRecording = true
            isPaused = false
            startTime = Date()
            accumulatedTime = 0
            lifecycleGate.didStart()
            startDurationTimer()
            return .started(recording)
        } catch {
            stopMicCapture()
            systemAudioTap?.stop()
            systemAudioTap = nil
            systemAudioLevel = 0
            updateAudioLevel()

            manifest.state = .failed
            manifest.failureCode = .captureFailed
            manifest.updatedAt = Date()
            try? await manifestStore.write(manifest, to: bundleURL)
            if FailedStartRecoveryPolicy.shouldSurfaceSession(captureDidBegin: captureDidBegin) {
                let recoverable = await recoveryService.inspect(manifest: manifest, bundleURL: bundleURL)
                addRecoverableSessionAtMostOnce(recoverable)
            }
            currentManifest = nil
            recordingDirectoryURL = nil
            lifecycleGate.didFailStart()
            throw error
        }
    }

    @MainActor
    func pauseRecording() async {
        guard lifecycleGate.pause() else { return }

        // Actually stop capturing — the paused interval is not written to either file.
        recordingEngine?.pause()
        systemAudioTap?.pause()

        isRecording = false
        isPaused = true
        micAudioLevel = 0
        systemAudioLevel = 0
        updateAudioLevel()

        if let startTime = startTime {
            accumulatedTime += Date().timeIntervalSince(startTime)
        }
        startTime = nil
        durationTimer?.invalidate()

        if var manifest = currentManifest, let bundleURL = recordingDirectoryURL {
            manifest.state = .paused
            manifest.duration = accumulatedTime
            manifest.updatedAt = Date()
            do {
                try await manifestStore.write(manifest, to: bundleURL)
                currentManifest = manifest
            } catch {
                lastError = "Recording paused, but its recovery state couldn't be saved."
            }
        }
    }

    @MainActor
    func resumeRecording() async throws {
        guard lifecycleGate.phase == .paused else { return }

        resetMicWarmupMute()
        try recordingEngine?.start()
        systemAudioTap?.resume()
        guard lifecycleGate.resume() else { return }

        micAudioLevel = 0
        systemAudioLevel = 0
        updateAudioLevel()
        isRecording = true
        isPaused = false
        startTime = Date()
        startDurationTimer()

        if var manifest = currentManifest, let bundleURL = recordingDirectoryURL {
            manifest.state = .capturing
            manifest.duration = accumulatedTime
            manifest.updatedAt = Date()
            do {
                try await manifestStore.write(manifest, to: bundleURL)
                currentManifest = manifest
            } catch {
                lastError = "Recording resumed, but its recovery state couldn't be saved."
            }
        }
    }

    @MainActor
    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let startTime = self.startTime {
                self.recordingDuration = Date().timeIntervalSince(startTime) + self.accumulatedTime
            }
            self.currentRecording?.duration = self.recordingDuration
        }
    }

    /// Starts the mic AVAudioEngine tap: writes to `url` and drives the live level meter.
    private func startMicCapture(to url: URL, microphoneId: String) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if !microphoneId.isEmpty {
            selectInputDevice(uid: microphoneId, on: engine)
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.recordingFailed
        }
        logger.info("Mic capture format: sampleRate=\(format.sampleRate) channels=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)")

        let file = try AVAudioFile(
            forWriting: url,
            settings: SystemAudioTap.aacSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let captureSession = MicrophoneCaptureSession(
            writer: file,
            warmupFrames: AVAudioFramePosition(format.sampleRate * micWarmupMuteDuration)
        )

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak captureSession] buffer, _ in
            guard let captureSession, let normalizedLevel = captureSession.process(buffer) else { return }

            DispatchQueue.main.async { [weak self, weak captureSession] in
                guard let self, let captureSession,
                      self.microphoneCaptureSession === captureSession else { return }
                self.micAudioLevel = self.isRecording ? normalizedLevel : 0
                self.updateAudioLevel()
            }
        }

        recordingEngine = engine
        microphoneCaptureSession = captureSession
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopMicCapture()
            throw error
        }
    }

    private func stopMicCapture() {
        let engine = recordingEngine
        let captureSession = microphoneCaptureSession
        captureSession?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        recordingEngine = nil
        microphoneCaptureSession = nil
        micAudioLevel = 0
        updateAudioLevel()
    }

    private func updateAudioLevel() {
        audioLevel = isRecording ? max(micAudioLevel, systemAudioLevel) : 0
    }

    private func resetMicWarmupMute() {
        guard let format = recordingEngine?.inputNode.outputFormat(forBus: 0), format.sampleRate > 0 else {
            return
        }
        microphoneCaptureSession?.resetWarmup(
            frames: AVAudioFramePosition(format.sampleRate * micWarmupMuteDuration)
        )
    }

    /// Redirects the engine's input to a specific device by AVCaptureDevice.uniqueID
    /// (which is the CoreAudio device UID on macOS). No-op if the device can't be found.
    private func selectInputDevice(uid: String, on engine: AVAudioEngine) {
        guard let deviceID = allInputDeviceIDs().first(where: { deviceUID(for: $0) == uid }),
              let audioUnit = engine.inputNode.audioUnit else { return }
        var mutableDeviceID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    @MainActor
    func stopRecording() async -> RecordingStopOutcome {
        guard currentRecording != nil, let bundleURL = recordingDirectoryURL,
              var manifest = currentManifest else {
            return lifecycleGate.phase == .stopping ? .alreadyStopping : .alreadyStopped
        }
        guard lifecycleGate.beginStop() else {
            return lifecycleGate.phase == .stopping ? .alreadyStopping : .alreadyStopped
        }

        isStoppingRecording = true
        defer { isStoppingRecording = false }

        if isRecording, let startTime {
            accumulatedTime += Date().timeIntervalSince(startTime)
        }
        let finalDuration = max(accumulatedTime, recordingDuration)
        durationTimer?.invalidate()
        startTime = nil
        isRecording = false
        isPaused = false

        // Capture must be stopped before probing or merging so both files are flushed.
        stopMicCapture()
        systemAudioTap?.stop()
        systemAudioTap = nil
        systemAudioLevel = 0
        updateAudioLevel()

        manifest.state = .stopping
        manifest.duration = finalDuration
        manifest.updatedAt = Date()
        do {
            try await manifestStore.write(manifest, to: bundleURL)
            currentManifest = manifest
        } catch {
            lastError = "Audio capture stopped, but its recovery state couldn't be updated."
        }

        let session = await recoveryService.inspect(manifest: manifest, bundleURL: bundleURL)
        do {
            switch try await recoveryService.recover(session) {
            case .recovered(let recording, let usedFallback):
                do {
                    try await libraryMutations.withLock {
                        try addRecordingAtMostOnce(recording)
                    }
                    if usedFallback {
                        lastError = "The recording was saved from an available raw track because the combined export was unavailable."
                        await retainMergeRetryIfAvailable(in: bundleURL)
                    }
                    resetActiveRecordingState()
                    return .saved(recording)
                } catch {
                    var failedManifest = (try? await manifestStore.read(from: bundleURL)) ?? manifest
                    failedManifest.state = .failed
                    failedManifest.failureCode = .metadataWriteFailed
                    failedManifest.updatedAt = Date()
                    try? await manifestStore.write(failedManifest, to: bundleURL)
                    let recoverable = await recoveryService.inspect(
                        manifest: failedManifest,
                        bundleURL: bundleURL
                    )
                    addRecoverableSessionAtMostOnce(recoverable)
                    resetActiveRecordingState()
                    lastError = "The audio is preserved, but its recording entry couldn't be saved. Use Recover to retry."
                    return .recoverable(recoverable)
                }

            case .unavailable(let recoverable):
                addRecoverableSessionAtMostOnce(recoverable)
                resetActiveRecordingState()
                lastError = "The recording session is preserved, but no usable audio could be finalized yet."
                return .recoverable(recoverable)

            case .ignored:
                resetActiveRecordingState()
                return .alreadyStopped
            }
        } catch {
            let recoverable = await recoveryService.inspect(manifest: manifest, bundleURL: bundleURL)
            addRecoverableSessionAtMostOnce(recoverable)
            resetActiveRecordingState()
            lastError = "The recording session is preserved for recovery: \(error.localizedDescription)"
            return .recoverable(recoverable)
        }
    }

    // MARK: - Persistence

    @MainActor
    private func resetActiveRecordingState() {
        lifecycleGate.finishStop()
        currentRecording = nil
        currentManifest = nil
        startTime = nil
        accumulatedTime = 0
        recordingDuration = 0
        recordingDirectoryURL = nil
    }

    @MainActor
    private func addRecordingAtMostOnce(
        _ recording: Recording,
        directory: URL? = nil,
        expectedGeneration: Int? = nil
    ) throws {
        if let expectedGeneration, expectedGeneration != libraryGeneration {
            throw LibraryPersistenceError.staleGeneration
        }
        guard !recordings.contains(where: { $0.id == recording.id }) else { return }
        recordings.append(recording)
        do {
            try saveRecordings(directory: directory, expectedGeneration: expectedGeneration)
        } catch {
            recordings.removeAll { $0.id == recording.id }
            throw error
        }
    }

    @MainActor
    private func replaceRecordingAudioAtomically(with replacement: Recording) throws {
        let updatedRecordings = RecordingLibraryUpdate.replacingAudio(in: recordings, with: replacement)
        try saveRecordings(updatedRecordings)
        recordings = updatedRecordings
    }

    @MainActor
    private func addRecoverableSessionAtMostOnce(_ session: RecoverableRecordingSession) {
        recoverableSessions.removeAll { $0.id == session.id }
        recoverableSessions.append(session)
        recoverableSessions.sort { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    private func saveRecordings(
        _ recordingsToSave: [Recording]? = nil,
        directory: URL? = nil,
        expectedGeneration: Int? = nil
    ) throws {
        if let expectedGeneration, expectedGeneration != libraryGeneration {
            throw LibraryPersistenceError.staleGeneration
        }
        let data = try JSONEncoder().encode(recordingsToSave ?? recordings)
        let url = (directory ?? boundRecordingsDirectory).appendingPathComponent("recordings.json")
        try data.write(to: url, options: .atomic)
    }

    // Delete a recording by ID
    @MainActor
    func deleteRecording(id: UUID) async {
        guard !isLibraryRebinding else { return }
        guard deletionActionGate.begin(id) else { return }
        deletionActionsInFlight.insert(id)
        defer {
            deletionActionGate.finish(id)
            deletionActionsInFlight.remove(id)
            if deletionActionsInFlight.isEmpty {
                let waiters = deletionDrainWaiters
                deletionDrainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        await libraryMutations.withLock {
            await deleteRecordingLocked(id: id)
        }
    }

    @MainActor
    private func deleteRecordingLocked(id: UUID) async {
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        let originalRecordings = recordings
        let bundleURL = recording.filePath.deletingLastPathComponent()
        let manifestURL = bundleURL.appendingPathComponent(RecordingSessionManifest.filename)
        let hasManifest = FileManager.default.fileExists(atPath: manifestURL.path)
        let deletionURL = RecordingBundleDeletionPolicy.deletionURL(
            for: recording,
            recordingsDirectory: recordingsDirectory,
            hasManifest: hasManifest
        )
        let originalManifest = hasManifest ? try? await manifestStore.read(from: bundleURL) : nil

        do {
            let updatedRecordings = try await RecordingDeletionTransaction.execute(
                currentRecordings: originalRecordings,
                deleting: id,
                prepareForDeletion: {
                    guard generation == self.libraryGeneration,
                          recordingsDirectory == self.boundRecordingsDirectory else {
                        throw LibraryPersistenceError.staleGeneration
                    }
                    guard var manifest = originalManifest else { return }
                    manifest.state = .dismissed
                    manifest.updatedAt = Date()
                    try await self.manifestStore.write(manifest, to: bundleURL)
                },
                rollbackPreparation: {
                    guard let originalManifest else { return }
                    try await self.manifestStore.write(originalManifest, to: bundleURL)
                },
                persistRecordings: {
                    try self.saveRecordings(
                        $0,
                        directory: recordingsDirectory,
                        expectedGeneration: generation
                    )
                },
                deleteFiles: {
                    guard generation == self.libraryGeneration,
                          recordingsDirectory == self.boundRecordingsDirectory else {
                        throw LibraryPersistenceError.staleGeneration
                    }
                    guard FileManager.default.fileExists(atPath: deletionURL.path) else { return }
                    try FileManager.default.removeItem(at: deletionURL)
                }
            )
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            recordings = updatedRecordings
            recoverableSessions.removeAll { $0.id == id }
        } catch {
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            lastError = "Couldn't delete \(recording.name): \(error.localizedDescription)"
        }
    }

    private func loadRecordings() {
        // Try to load from custom directory first
        let customDirectory = boundRecordingsDirectory
        let customUrl = customDirectory.appendingPathComponent("recordings.json")

        if FileManager.default.fileExists(atPath: customUrl.path) {
            do {
                let data = try Data(contentsOf: customUrl)
                recordings = try JSONDecoder().decode([Recording].self, from: data)
                return
            } catch {
                print("Failed to load recordings from custom directory: \(error)")
            }
        }

        // Fall back to default directory if needed
        let defaultUrl = documentsDirectory.appendingPathComponent("recordings.json")
        if FileManager.default.fileExists(atPath: defaultUrl.path) {
            do {
                let data = try Data(contentsOf: defaultUrl)
                recordings = try JSONDecoder().decode([Recording].self, from: data)
            } catch {
                print("Failed to load recordings from default directory: \(error)")
            }
        }
    }

    /// Replaces the in-memory recording library from the currently selected root.
    /// Call only from the coordinated library-rebind boundary while writes are paused.
    @MainActor
    func reloadRecordingsForCurrentLibrary() async throws {
        guard currentRecording == nil, !isStartingRecording, !isStoppingRecording else {
            throw LibraryRebindError.recordingInProgress
        }
        let url = boundRecordingsDirectory.appendingPathComponent("recordings.json")
        recordings = try Self.decodeLibraryArray([Recording].self, at: url)
        recoverableSessions = []
        await recoverInterruptedSessionsOnLaunch()
    }

    @MainActor
    func clearRecordingsForLibraryRebindFailure() {
        recordings = []
        recoverableSessions = []
    }

    @MainActor
    func acceptLibrary(recordings: [Recording], recordingsDirectory: URL) async {
        libraryGeneration += 1
        boundRecordingsDirectory = recordingsDirectory
        self.recordings = recordings
        recoverableSessions = []
        await recoverInterruptedSessionsOnLaunch()
    }

    @MainActor
    func beginLibraryRebind() -> Bool {
        guard !isLibraryRebinding,
              currentRecording == nil,
              !isStartingRecording,
              !isStoppingRecording else { return false }
        isLibraryRebinding = true
        libraryGeneration += 1
        return true
    }

    @MainActor
    func finishLibraryRebind() {
        isLibraryRebinding = false
    }

    func waitForDeletionActionsToDrain() async {
        guard !deletionActionsInFlight.isEmpty else { return }
        await withCheckedContinuation { continuation in
            deletionDrainWaiters.append(continuation)
        }
    }

    nonisolated private static func decodeLibraryArray<T: Decodable>(
        _ type: [T].Type,
        at url: URL
    ) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @MainActor
    private func recoverInterruptedSessionsOnLaunch() async {
        defer {
            initialRecoveryGate.finish()
            isInitialRecoveryComplete = true
        }
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        do {
            try importService.cleanupInterruptedStaging(in: recordingsDirectory)
            await migrateLegacyInterruptedRecordingIfNeeded(
                in: recordingsDirectory,
                expectedGeneration: generation
            )
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            let scan = try await recoveryService.scan(
                recordingsDirectory: recordingsDirectory,
                excluding: Set(recordings.map(\.id)).union([currentManifest?.sessionID].compactMap { $0 })
            )
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }

            for scannedSession in scan.sessions {
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                guard currentManifest?.sessionID != scannedSession.id else { continue }
                var session = scannedSession

                if let match = RecordingLibraryReferenceReconciler.matchingRecording(
                    for: session.manifest,
                    bundleURL: session.bundleURL,
                    recordingsDirectory: recordingsDirectory,
                    recordings: recordings
                ), match.recording.id != session.id {
                    let reconciledManifest = RecordingLibraryReferenceReconciler.reidentifiedManifest(
                        session.manifest,
                        recording: match.recording,
                        audioFilename: match.audioFilename
                    )
                    do {
                        try await manifestStore.write(reconciledManifest, to: session.bundleURL)
                        guard generation == libraryGeneration,
                              recordingsDirectory == boundRecordingsDirectory else { return }
                        session = await recoveryService.inspect(
                            manifest: reconciledManifest,
                            bundleURL: session.bundleURL
                        )
                        guard generation == libraryGeneration,
                              recordingsDirectory == boundRecordingsDirectory else { return }
                    } catch {
                        // The existing library row already owns this safe bundle. Never
                        // create a second row with the stale folder UUID if reconciliation
                        // cannot be persisted; the next launch will retry the rewrite.
                        lastError = "Couldn't reconcile a legacy recording entry: \(error.localizedDescription)"
                        continue
                    }
                }

                if recordings.contains(where: { $0.id == session.id }) {
                    if session.manifest.failureCode == .mergeFailed,
                       session.inspection.canRetryMerge {
                        addRecoverableSessionAtMostOnce(session)
                    }
                    continue
                }
                do {
                    switch try await recoveryService.recover(session) {
                    case .recovered(let recording, let usedFallback):
                        guard generation == libraryGeneration,
                              recordingsDirectory == boundRecordingsDirectory else { return }
                        do {
                            try await libraryMutations.withLock {
                                try addRecordingAtMostOnce(
                                    recording,
                                    directory: recordingsDirectory,
                                    expectedGeneration: generation
                                )
                            }
                            if usedFallback {
                                lastError = "Recovered \(recording.name) from an available raw audio track."
                                await retainMergeRetryIfAvailable(
                                    in: session.bundleURL,
                                    expectedGeneration: generation
                                )
                            }
                        } catch {
                            addRecoverableSessionAtMostOnce(session)
                        }
                    case .unavailable(let recoverable):
                        guard generation == libraryGeneration else { return }
                        addRecoverableSessionAtMostOnce(recoverable)
                    case .ignored:
                        break
                    }
                } catch {
                    guard generation == libraryGeneration else { return }
                    addRecoverableSessionAtMostOnce(session)
                }
            }

            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            corruptRecordingBundles = scan.corruptBundleURLs.map(CorruptRecordingBundle.init(bundleURL:))
            if !scan.corruptBundleURLs.isEmpty {
                lastError = "Some interrupted recording manifests are damaged. Their folders were preserved for inspection."
            }
        } catch {
            if !Task.isCancelled,
               generation == libraryGeneration,
               recordingsDirectory == boundRecordingsDirectory {
                lastError = "Couldn't scan interrupted recordings: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func migrateLegacyInterruptedRecordingIfNeeded(
        in recordingsDirectory: URL,
        expectedGeneration: Int
    ) async {
        let defaults = UserDefaults.standard
        let rawMetadata = defaults.dictionary(forKey: "lastRecordingMetadata")
        let metadata = rawMetadata?.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
        }
        let result = await legacyMigrationService.migrate(
            metadata: metadata,
            recordingsDirectory: recordingsDirectory,
            existingRecordings: recordings
        )
        guard expectedGeneration == libraryGeneration,
              recordingsDirectory == boundRecordingsDirectory else { return }
        switch result {
        case .migrated, .conclusivelyAbsentOrInvalid:
            defaults.removeObject(forKey: "lastRecordingMetadata")
        case .retainedForRetry:
            break
        }
    }

    @MainActor
    private func retainMergeRetryIfAvailable(
        in bundleURL: URL,
        expectedGeneration: Int? = nil
    ) async {
        guard let manifest = try? await manifestStore.read(from: bundleURL),
              manifest.failureCode == .mergeFailed else { return }
        if let expectedGeneration, expectedGeneration != libraryGeneration { return }
        let session = await recoveryService.inspect(manifest: manifest, bundleURL: bundleURL)
        if let expectedGeneration, expectedGeneration != libraryGeneration { return }
        if session.inspection.canRetryMerge {
            addRecoverableSessionAtMostOnce(session)
        }
    }

    @MainActor
    func recoverSession(id: UUID) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        guard let session = recoverableSessions.first(where: { $0.id == id }),
              !recordings.contains(where: { $0.id == id }) else { return }
        guard recoveryActionGate.begin(id) else { return }
        recoveryActionsInFlight.insert(id)
        defer {
            recoveryActionGate.finish(id)
            recoveryActionsInFlight.remove(id)
        }

        do {
            switch try await recoveryService.recoverAvailableAudio(session) {
            case .recovered(let recording, let usedFallback):
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                let insertionAllowed = try await libraryMutations.withLock {
                    guard generation == self.libraryGeneration else { return false }
                    guard await recoveryMetadataInsertionIsAllowed(for: session) else { return false }
                    guard generation == self.libraryGeneration,
                          recordingsDirectory == self.boundRecordingsDirectory else { return false }
                    try addRecordingAtMostOnce(
                        recording,
                        directory: recordingsDirectory,
                        expectedGeneration: generation
                    )
                    return true
                }
                guard insertionAllowed else {
                    return
                }
                recoverableSessions.removeAll { $0.id == id }
                if usedFallback {
                    lastError = "Recovered \(recording.name) from an available raw audio track."
                }
            case .unavailable(let refreshed):
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                addRecoverableSessionAtMostOnce(refreshed)
                lastError = refreshed.statusDescription
            case .ignored:
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                recoverableSessions.removeAll { $0.id == id }
            }
        } catch {
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            lastError = "Recovery failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func retryMergeSession(id: UUID) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        guard let session = recoverableSessions.first(where: { $0.id == id }),
              session.inspection.canRetryMerge else { return }
        guard recoveryActionGate.begin(id) else { return }
        recoveryActionsInFlight.insert(id)
        defer {
            recoveryActionGate.finish(id)
            recoveryActionsInFlight.remove(id)
        }

        do {
            switch try await recoveryService.retryMerge(session) {
            case .recovered(let recording, _):
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                do {
                    let replacementAllowed = try await libraryMutations.withLock {
                        guard generation == self.libraryGeneration else { return false }
                        guard await recoveryMetadataInsertionIsAllowed(for: session) else { return false }
                        guard generation == self.libraryGeneration,
                              recordingsDirectory == self.boundRecordingsDirectory else { return false }
                        try replaceRecordingAudioAtomically(with: recording)
                        return true
                    }
                    guard replacementAllowed else {
                        return
                    }
                } catch {
                    guard generation == libraryGeneration,
                          recordingsDirectory == boundRecordingsDirectory else { return }
                    // The merged file is valid, but keep the retry marker until its
                    // library entry can be atomically repointed on a later attempt.
                    if var retryManifest = try? await manifestStore.read(from: session.bundleURL) {
                        guard generation == libraryGeneration,
                              recordingsDirectory == boundRecordingsDirectory else { return }
                        retryManifest.state = .completed
                        retryManifest.failureCode = .mergeFailed
                        retryManifest.resolvedAudioPath = recordings.first(where: { $0.id == id })?.filePath.lastPathComponent
                        retryManifest.updatedAt = Date()
                        try? await manifestStore.write(retryManifest, to: session.bundleURL)
                    }
                    guard generation == libraryGeneration,
                          recordingsDirectory == boundRecordingsDirectory else { return }
                    await retainMergeRetryIfAvailable(in: session.bundleURL, expectedGeneration: generation)
                    throw error
                }
                recoverableSessions.removeAll { $0.id == id }
            case .unavailable(let refreshed):
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                addRecoverableSessionAtMostOnce(refreshed)
                lastError = "The merge retry failed. Both raw tracks remain available; use Recover to save one of them."
            case .ignored:
                guard generation == libraryGeneration,
                      recordingsDirectory == boundRecordingsDirectory else { return }
                recoverableSessions.removeAll { $0.id == id }
            }
        } catch {
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            lastError = "Merge retry failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func dismissRecoverySession(id: UUID) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        guard let session = recoverableSessions.first(where: { $0.id == id }) else { return }
        guard recoveryActionGate.begin(id) else { return }
        recoveryActionsInFlight.insert(id)
        defer {
            recoveryActionGate.finish(id)
            recoveryActionsInFlight.remove(id)
        }
        do {
            try await recoveryService.dismiss(session)
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            recoverableSessions.removeAll { $0.id == id }
        } catch {
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            lastError = "Couldn't dismiss the recovery session: \(error.localizedDescription)"
        }
    }

    func isRecoveryActionInFlight(id: UUID) -> Bool {
        recoveryActionsInFlight.contains(id)
    }

    private func recoveryMetadataInsertionIsAllowed(for session: RecoverableRecordingSession) async -> Bool {
        guard let latest = try? await manifestStore.read(from: session.bundleURL) else { return false }
        return latest.state != .dismissed
    }

    @MainActor
    func recoverCorruptBundle(_ bundle: CorruptRecordingBundle) async {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let recordingsDirectory = boundRecordingsDirectory
        guard corruptRecoveryActionsInFlight.insert(bundle.id).inserted else { return }
        defer { corruptRecoveryActionsInFlight.remove(bundle.id) }
        let suffix = String(bundle.bundleURL.lastPathComponent.suffix(36))
        guard let sessionID = UUID(uuidString: suffix) else {
            lastError = "This damaged bundle has no trustworthy session identifier. Use Show in Finder to inspect it."
            return
        }

        let createdAt = (try? bundle.bundleURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var manifest = RecordingSessionManifest(
            sessionID: sessionID,
            displayName: bundle.bundleURL.lastPathComponent,
            createdAt: createdAt,
            selectedInputID: "",
            state: .failed
        )
        if let importedAudioFilename = RecordingManifestRepairCandidate.audioFilename(in: bundle.bundleURL) {
            manifest.mergedPath = importedAudioFilename
        }
        manifest.failureCode = .manifestWriteFailed

        do {
            try manifest.validatePaths(in: bundle.bundleURL)
            let candidate = await recoveryService.inspect(manifest: manifest, bundleURL: bundle.bundleURL)
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            guard candidate.inspection.hasAnyValidAudio else {
                lastError = "No valid known audio files were found in this damaged bundle."
                return
            }
            try await manifestStore.write(manifest, to: bundle.bundleURL)
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            corruptRecordingBundles.removeAll { $0.id == bundle.id }
            addRecoverableSessionAtMostOnce(candidate)
            await recoverSession(id: sessionID)
        } catch {
            guard generation == libraryGeneration,
                  recordingsDirectory == boundRecordingsDirectory else { return }
            lastError = "Couldn't repair the damaged recording manifest: \(error.localizedDescription)"
        }
    }

    @MainActor
    func dismissCorruptBundle(_ bundle: CorruptRecordingBundle) {
        guard !isLibraryRebinding else { return }
        guard !corruptRecoveryActionsInFlight.contains(bundle.id) else { return }
        do {
            try Data("dismissed".utf8).write(
                to: bundle.bundleURL.appendingPathComponent(RecordingSessionManifest.dismissalFilename),
                options: .atomic
            )
            corruptRecordingBundles.removeAll { $0.id == bundle.id }
        } catch {
            lastError = "Couldn't dismiss the damaged recording bundle: \(error.localizedDescription)"
        }
    }

    func isCorruptRecoveryActionInFlight(id: String) -> Bool {
        corruptRecoveryActionsInFlight.contains(id)
    }

    // MARK: - Microphone Control

    // Get the default input device ID
    private func getDefaultInputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not find the default input device."])
        }

        return deviceID
    }

    // All current audio device IDs (input and output)
    private func allInputDeviceIDs() -> [AudioDeviceID] {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize) == noErr else {
            return []
        }
        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs
    }

    // The CoreAudio UID string for a device (matches AVCaptureDevice.uniqueID for audio devices)
    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    // Check if the microphone is currently muted
    private func isMicrophoneMutedSystem() throws -> Bool {
        let deviceID = try getDefaultInputDevice()
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if the device supports the mute property
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            return false
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &muted
        )

        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to get audio device property."])
        }

        return muted == 1
    }

    // Mute or unmute the microphone
    private func setMicrophoneMuteSystem(muted: Bool) throws {
        let deviceID = try getDefaultInputDevice()
        var mutedValue: UInt32 = muted ? 1 : 0

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if the device supports the mute property
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Device does not support mute property."])
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutedValue
        )

        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to set audio device property."])
        }
    }

    // Public methods for controlling microphone mute

    func toggleMicrophoneMute() {
        // Toggle the mute state
        let newMuteState = !isMicrophoneMuted

        // Update our state
        isMicrophoneMuted = newMuteState
        print("Microphone mute toggled: \(isMicrophoneMuted)")

        // Update system-wide mute
        do {
            try setMicrophoneMuteSystem(muted: isMicrophoneMuted)
        } catch {
            print("Failed to toggle system microphone mute: \(error.localizedDescription)")
        }
    }

    func setMicrophoneMute(muted: Bool) {
        do {
            // Set system-wide mute
            try setMicrophoneMuteSystem(muted: muted)

            // Update our state
            isMicrophoneMuted = muted

            print("Microphone mute set to: \(isMicrophoneMuted)")
        } catch {
            print("Failed to set microphone mute state: \(error.localizedDescription)")
        }
    }

    func updateMicrophoneMuteState() {
        // Skip this check if we're not recording to avoid unnecessary device access
        // This helps prevent range errors when switching tabs
        if !isRecording && !isPaused {
            return
        }

        do {
            // Get the system microphone mute state
            let systemMuted = try isMicrophoneMutedSystem()

            // Update our state with the system state
            isMicrophoneMuted = systemMuted
        } catch {
            // Silently fail - don't log every time
        }
    }

    // MARK: - Permissions

    // Check and request microphone permission, and touch the process-tap path so macOS
    // shows the system-audio permission prompt before the first recording.
    func checkAndRequestPermissions() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            logger.info("Microphone permission request result: \(granted)")
        }

        systemAudioPermissionAvailable = await MainActor.run {
            SystemAudioTap.requestPermissionPrompt()
        }

        await loadAvailableMicrophones()

        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // Check if the app has been granted system audio recording permission
    func hasSystemAudioPermission() -> Bool {
        systemAudioPermissionAvailable
    }

    // Check if the app has been granted microphone permission
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func importRecording(from sourceURL: URL) {
        importRecording(from: sourceURL, named: nil)
    }

    func importRecording(from sourceURL: URL, named customName: String?) {
        guard !isLibraryRebinding else { return }
        let generation = libraryGeneration
        let targetDirectory = boundRecordingsDirectory
        Task { @MainActor in
            do {
                if testImportDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: testImportDelayNanoseconds)
                }
                let recording = try await importService.importSingle(
                    from: sourceURL,
                    into: targetDirectory,
                    groupId: nil,
                    groupName: nil,
                    customName: customName
                )
                guard generation == libraryGeneration else {
                    try? FileManager.default.removeItem(at: recording.filePath.deletingLastPathComponent())
                    return
                }
                do {
                    try await libraryMutations.withLock {
                        try addRecordingAtMostOnce(recording)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: recording.filePath.deletingLastPathComponent())
                    throw error
                }
            } catch {
                lastError = "Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Import one or more audio files. When more than one file is given, they share a
    /// single groupId/groupName so the UI can show them as one collapsible group.
    func importRecordings(from urls: [URL]) {
        guard !urls.isEmpty, !isLibraryRebinding else { return }
        let groupId: UUID? = urls.count > 1 ? UUID() : nil
        let groupName: String? = groupId == nil ? nil : {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return "Imported batch — \(df.string(from: Date())) (\(urls.count) files)"
        }()
        let generation = libraryGeneration
        let targetDirectory = boundRecordingsDirectory

        Task { @MainActor in
            if testImportDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: testImportDelayNanoseconds)
            }
            let result = await importService.importBatch(
                from: urls,
                into: targetDirectory,
                groupId: groupId,
                groupName: groupName
            )

            guard generation == libraryGeneration else {
                for recording in result.recordings {
                    try? FileManager.default.removeItem(at: recording.filePath.deletingLastPathComponent())
                }
                return
            }

            if !result.recordings.isEmpty {
                let didPersist = await libraryMutations.withLock {
                    let insertedIDs = Set(result.recordings.map(\.id))
                    recordings.append(contentsOf: result.recordings.filter { recording in
                        !recordings.contains(where: { $0.id == recording.id })
                    })
                    do {
                        try saveRecordings()
                        return true
                    } catch {
                        recordings.removeAll { insertedIDs.contains($0.id) }
                        return false
                    }
                }
                if !didPersist {
                    for recording in result.recordings {
                        try? FileManager.default.removeItem(at: recording.filePath.deletingLastPathComponent())
                    }
                    lastError = "The imported files were rolled back because their metadata couldn't be saved."
                    return
                }
            }

            if !result.failures.isEmpty {
                let failedNames = result.failures.map(\.filename).joined(separator: ", ")
                lastError = "Imported \(result.recordings.count) of \(urls.count) files. Failed: \(failedNames)."
            }
        }
    }

    /// Delete every recording belonging to a group.
    @MainActor
    func deleteGroup(groupId: UUID) async {
        guard !isLibraryRebinding else { return }
        let ids = recordings.filter { $0.groupId == groupId }.map { $0.id }
        for id in ids {
            await deleteRecording(id: id)
        }
    }
}

enum AudioRecorderError: Error, LocalizedError, Equatable {
    case recordingFailed
    case permissionDenied
    case directoryError
    case fileNotFound
    case fileOperationFailed
    case manifestWriteFailed
    case invalidAudio
    case recoveryInProgress

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            return "Failed to start recording. Please try again."
        case .permissionDenied:
            return "Permission denied. Please check that WhisperNote has all required permissions in System Settings > Privacy & Security, then restart the app."
        case .directoryError:
            return "There was an issue with the recording directory or file. This could be because a file with the same name already exists or the directory couldn't be created. The app will try to use different filenames for microphone and system audio to avoid conflicts. Please try again with a different recording name if the issue persists."
        case .fileNotFound:
            return "Audio file not found. The recording may have failed or been moved."
        case .fileOperationFailed:
            return "Failed to perform file operation. Please try again."
        case .manifestWriteFailed:
            return "The recording recovery manifest couldn't be saved."
        case .invalidAudio:
            return "The selected file does not contain valid playable audio."
        case .recoveryInProgress:
            return "WhisperNote is still checking interrupted recordings. Try starting again in a moment."
        }
    }
}
