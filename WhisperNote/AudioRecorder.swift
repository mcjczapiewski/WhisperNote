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

    private var durationTimer: Timer?
    private var microphoneStateTimer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0

    @AppStorage("audioQuality") private var audioQuality = "high"
    private let audioFormat = "m4a"

    private let directoryManager = DirectoryManager.shared
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    // Logging
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "AudioRecorder")
    private let debugLogger = DebugLogger.shared
    private let mergedAudioSampleRate = 48_000.0
    private let mergedAudioBitRate = 64_000
    private let mergedAudioChannels = 1

    // Recording state (Core Audio process tap + AVAudioEngine, replacing RecordKit)
    private var recordingEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var systemAudioTap: SystemAudioTap?
    private var recordingDirectoryURL: URL?

    override init() {
        super.init()
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

    func startRecording(name: String, microphoneId: String = "") throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            print("Microphone permission is denied")
            throw AudioRecorderError.permissionDenied
        }

        // Get the base recordings directory from the directory manager
        let baseDirectory = directoryManager.getRecordingsDirectory()

        // Create a completely unique directory using UUID
        let uuid = UUID().uuidString
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = dateFormatter.string(from: Date())

        // Sanitize the name to remove characters that might cause issues in filenames
        let sanitizedName = name.replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)

        // Create a unique directory name with UUID to ensure uniqueness
        let uniqueDirName = "recording_\(dateString)_\(uuid)"
        let uniqueDirectory = baseDirectory.appendingPathComponent(uniqueDirName)

        if FileManager.default.fileExists(atPath: uniqueDirectory.path) {
            do {
                try FileManager.default.removeItem(at: uniqueDirectory)
            } catch {
                logger.error("Failed to remove existing directory: \(error.localizedDescription)")
                throw AudioRecorderError.directoryError
            }
        }
        do {
            try FileManager.default.createDirectory(at: uniqueDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create recording directory: \(error.localizedDescription)")
            throw AudioRecorderError.directoryError
        }

        // Store the recording metadata for later use
        let metadata = [
            "name": sanitizedName,
            "date": dateString,
            "uuid": uuid
        ]
        UserDefaults.standard.set(metadata, forKey: "lastRecordingMetadata")

        self.recordingDirectoryURL = uniqueDirectory
        logger.info("Using unique directory: \(uniqueDirectory.path)")

        Task {
            do {
                let micPermissionGranted = await checkAndRequestPermissions()
                guard micPermissionGranted else {
                    logger.error("Microphone permission denied")
                    throw AudioRecorderError.permissionDenied
                }

                let micURL = uniqueDirectory.appendingPathComponent("mic_recording.m4a")
                let systemURL = uniqueDirectory.appendingPathComponent("system_recording.m4a")

                try startMicCapture(to: micURL, microphoneId: microphoneId)

                let tap = SystemAudioTap()
                try tap.start(outputURL: systemURL)
                self.systemAudioTap = tap

                await MainActor.run {
                    self.isRecording = true
                    self.isPaused = false

                    let placeholderURL = uniqueDirectory.appendingPathComponent("\(name)_placeholder.\(audioFormat)")
                    let newRecording = Recording(
                        name: name,
                        date: Date(),
                        duration: 0,
                        filePath: placeholderURL,
                        systemAudioFilePath: nil // Merged into a single file at stop time
                    )
                    self.currentRecording = newRecording

                    self.startTime = Date()
                    self.accumulatedTime = 0
                    self.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        if let startTime = self.startTime {
                            self.recordingDuration = Date().timeIntervalSince(startTime) + self.accumulatedTime
                        }
                        self.currentRecording?.duration = self.recordingDuration
                    }
                }
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
                await MainActor.run {
                    self.stopMicCapture()
                    self.systemAudioTap?.stop()
                    self.systemAudioTap = nil
                    self.lastError = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        // Actually stop capturing — the paused interval is not written to either file.
        recordingEngine?.pause()
        systemAudioTap?.pause()

        isRecording = false
        isPaused = true

        if let startTime = startTime {
            accumulatedTime += Date().timeIntervalSince(startTime)
        }
        durationTimer?.invalidate()
    }

    func resumeRecording() {
        guard !isRecording, isPaused else { return }

        try? recordingEngine?.start()
        systemAudioTap?.resume()

        isRecording = true
        isPaused = false
        startTime = Date()

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
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
        micFile = file

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak engine] buffer, _ in
            guard let self, let engine, self.recordingEngine === engine else { return }
            try? self.micFile?.write(from: buffer)

            guard let channelData = buffer.floatChannelData else { return }
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            guard channelCount > 0, frameLength > 0 else { return }

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
            let normalizedLevel = max(0, min(1, (Double(decibels) + 60) / 60))

            DispatchQueue.main.async { [weak self, weak engine] in
                guard let self, self.recordingEngine === engine else { return }
                self.audioLevel = self.isRecording ? normalizedLevel : 0
            }
        }

        engine.prepare()
        try engine.start()
        recordingEngine = engine
    }

    private func stopMicCapture() {
        recordingEngine?.inputNode.removeTap(onBus: 0)
        recordingEngine?.stop()
        recordingEngine = nil
        micFile = nil
        audioLevel = 0
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

    func stopRecording() {
        guard let currentRecording = currentRecording else { return }
        guard let bundleURL = recordingDirectoryURL else { return }

        // Stop capture immediately so both files are fully flushed before we merge them.
        stopMicCapture()
        systemAudioTap?.stop()
        systemAudioTap = nil

        Task {
            do {
                // Find and merge the audio files in the bundle directory
                func findAndMergeAudioFiles() async throws -> URL {
                    do {
                        // Look for audio files in the bundle directory
                        let fileManager = FileManager.default
                        let bundleContents = try fileManager.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)

                        // Log all files found in the bundle
                        logger.info("Files in bundle: \(bundleContents.map { $0.lastPathComponent }.joined(separator: ", "))")

                        // First check if we already have a merged recording file
                        if let mergedAudioURL = bundleContents.first(where: { url in
                            return url.lastPathComponent == "recording.m4a"
                        }) {
                            logger.info("Found existing merged audio file: \(mergedAudioURL.path)")
                            return mergedAudioURL
                        }

                        // Find the microphone audio file
                        guard let micAudioURL = bundleContents.first(where: { url in
                            return url.lastPathComponent == "mic_recording.m4a"
                        }) else {
                            logger.warning("Microphone audio file not found")

                            // If no microphone file, look for any audio file
                            if let audioURL = bundleContents.first(where: { url in
                                let pathExtension = url.pathExtension.lowercased()
                                return pathExtension == "m4a" || pathExtension == "wav" || pathExtension == "mp4" || pathExtension == "mov"
                            }) {
                                logger.info("Found generic audio file: \(audioURL.path)")
                                return audioURL
                            } else {
                                logger.warning("No audio file found in bundle directory: \(bundleURL.path)")
                                throw AudioRecorderError.recordingFailed
                            }
                        }

                        // Find the system audio file
                        guard let systemAudioURL = bundleContents.first(where: { url in
                            return url.lastPathComponent == "system_recording.m4a"
                        }) else {
                            logger.warning("System audio file not found, using microphone audio only")
                            return micAudioURL
                        }

                        // Create the output URL for the merged file
                        let mergedAudioURL = bundleURL.appendingPathComponent("recording.m4a")

                        // Merge the audio files
                        logger.info("Merging microphone and system audio files...")
                        do {
                            // Merge the audio files using AVFoundation
                            let mergedURL = try await mergeAudioFiles(
                                microphoneURL: micAudioURL,
                                systemAudioURL: systemAudioURL,
                                outputURL: mergedAudioURL
                            )
                            logger.info("Audio files successfully merged to: \(mergedURL.path)")
                            return mergedURL
                        } catch {
                            logger.error("Failed to merge audio files: \(error.localizedDescription)")
                            // Preserve the recording: keep the microphone audio and warn
                            // the user rather than silently dropping system audio.
                            await MainActor.run {
                                lastError = "Saved microphone audio, but system audio couldn't be merged: \(error.localizedDescription)"
                            }
                            return micAudioURL
                        }
                    } catch {
                        logger.error("Error examining bundle directory: \(error.localizedDescription)")
                        throw error
                    }
                }

                // Get the audio file URL by finding and merging the files
                let audioFileURL = try await findAndMergeAudioFiles()

                await MainActor.run {
                    // Update state
                    isRecording = false
                    isPaused = false
                    durationTimer?.invalidate()

                    // Update the final duration
                    if let startTime = startTime {
                        accumulatedTime += Date().timeIntervalSince(startTime)
                    }

                    // Create the final recording object with the correct duration and file path
                    let recordingPath = audioFileURL

                    let finalRecording = Recording(
                        id: currentRecording.id,
                        name: currentRecording.name,
                        date: currentRecording.date,
                        duration: accumulatedTime,
                        filePath: recordingPath,
                        systemAudioFilePath: nil
                    )

                    // Add to recordings array
                    recordings.append(finalRecording)

                    // Reset state
                    self.currentRecording = nil
                    startTime = nil
                    accumulatedTime = 0
                    recordingDuration = 0
                    recordingDirectoryURL = nil

                    // Save recordings to disk
                    saveRecordings()
                }
            } catch {
                logger.error("Error stopping recording: \(error.localizedDescription)")
                // Reset recording state so the UI isn't stuck "recording", and surface the error.
                await MainActor.run {
                    isRecording = false
                    isPaused = false
                    durationTimer?.invalidate()
                    self.currentRecording = nil
                    startTime = nil
                    accumulatedTime = 0
                    recordingDuration = 0
                    recordingDirectoryURL = nil
                    lastError = "Couldn't save the recording: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Persistence

    private func saveRecordings() {
        do {
            let data = try JSONEncoder().encode(recordings)
            let directory = directoryManager.getRecordingsDirectory()
            let url = directory.appendingPathComponent("recordings.json")
            try data.write(to: url)
        } catch {
            print("Failed to save recordings: \(error)")
        }
    }

    // Delete a recording by ID
    func deleteRecording(id: UUID) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            let recording = recordings[index]

            // Check if the file is in a RecordKit bundle directory
            let fileURL = recording.filePath
            let isInBundle = fileURL.pathComponents.contains { $0.contains("_20") && ($0.contains("-") || $0.contains("_")) }

            if isInBundle {
                // Try to delete the parent directory (the bundle)
                let bundleURL = fileURL.deletingLastPathComponent()
                do {
                    try FileManager.default.removeItem(at: bundleURL)
                    print("Deleted recording bundle directory at: \(bundleURL.path)")
                } catch {
                    print("Error deleting recording bundle directory: \(error.localizedDescription)")

                    // Fall back to deleting just the file
                    do {
                        try FileManager.default.removeItem(at: recording.filePath)
                        print("Deleted audio file at: \(recording.filePath.path)")
                    } catch {
                        print("Error deleting audio file: \(error.localizedDescription)")
                    }
                }
            } else {
                // Just delete the individual file
                do {
                    try FileManager.default.removeItem(at: recording.filePath)
                    print("Deleted audio file at: \(recording.filePath.path)")
                } catch {
                    print("Error deleting audio file: \(error.localizedDescription)")
                }
            }

            // Remove from recordings array
            recordings.remove(at: index)
            saveRecordings()
        }
    }

    private func loadRecordings() {
        // Try to load from custom directory first
        let customDirectory = directoryManager.getRecordingsDirectory()
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

    // Check and request microphone permission. System audio needs none (Core Audio
    // process taps have no TCC prompt), unlike RecordKit's separate system-audio permission.
    func checkAndRequestPermissions() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            logger.info("Microphone permission request result: \(granted)")
        }

        await loadAvailableMicrophones()

        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // Check if the app has been granted system audio recording permission
    func hasSystemAudioPermission() -> Bool {
        true
    }

    // Check if the app has been granted microphone permission
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Merge two audio files into a single file
    /// - Parameters:
    ///   - microphoneURL: URL of the microphone audio file
    ///   - systemAudioURL: URL of the system audio file
    ///   - outputURL: URL where the merged file will be saved
    /// - Returns: URL of the merged file
    private func mergeAudioFiles(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL {
        logger.info("Merging audio files: \(microphoneURL.lastPathComponent) and \(systemAudioURL.lastPathComponent)")

        // Get file sizes for logging
        let microphoneFileSize = (try? FileManager.default.attributesOfItem(atPath: microphoneURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let systemAudioFileSize = (try? FileManager.default.attributesOfItem(atPath: systemAudioURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        logger.info("Original file sizes - Microphone: \(ByteCountFormatter.string(fromByteCount: microphoneFileSize, countStyle: .file)), System Audio: \(ByteCountFormatter.string(fromByteCount: systemAudioFileSize, countStyle: .file))")

        // Check if both files exist
        guard FileManager.default.fileExists(atPath: microphoneURL.path) else {
            logger.error("Microphone audio file not found at: \(microphoneURL.path)")
            throw AudioRecorderError.fileNotFound
        }

        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            logger.error("System audio file not found at: \(systemAudioURL.path)")
            throw AudioRecorderError.fileNotFound
        }

        // Create AVAssets for both files
        let microphoneAsset = AVAsset(url: microphoneURL)
        let systemAudioAsset = AVAsset(url: systemAudioURL)

        // Get audio tracks from the assets
        guard let microphoneTrack = try? await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let systemAudioTrack = try? await systemAudioAsset.loadTracks(withMediaType: .audio).first else {
            logger.error("Failed to get audio tracks from assets")
            throw AudioRecorderError.recordingFailed
        }

        // Get the time ranges for both tracks
        let microphoneDuration = try await microphoneAsset.load(.duration)
        let systemAudioDuration = try await systemAudioAsset.load(.duration)

        logger.info("Microphone duration: \(microphoneDuration.seconds) seconds")
        logger.info("System audio duration: \(systemAudioDuration.seconds) seconds")

        // Check if microphone file is significantly smaller than system audio file
        // This could indicate that the microphone was muted or has silence compression
        let sizeRatio = Double(microphoneFileSize) / Double(systemAudioFileSize)
        let hasSignificantSizeDifference = sizeRatio < 0.1 // Microphone file is less than 10% of system audio file

        if hasSignificantSizeDifference {
            logger.info("Detected significant file size difference: microphone file is \(Int(sizeRatio * 100))% of system audio file size")
            logger.info("This suggests the microphone may have been muted or contains mostly silence")
        }

        // Check if there's a significant difference in durations (more than 10%)
        let durationRatio = microphoneDuration.seconds / systemAudioDuration.seconds
        let hasDurationDiscrepancy = abs(durationRatio - 1.0) > 0.1

        if hasDurationDiscrepancy {
            logger.warning("Detected significant duration discrepancy between microphone and system audio: ratio = \(durationRatio)")
            logger.warning("This may indicate different sample rates. Will attempt to correct during merging.")
        }

        // Get the format descriptions to check sample rates
        if let microphoneFormatObj = try await microphoneTrack.load(.formatDescriptions).first,
           let systemAudioFormatObj = try await systemAudioTrack.load(.formatDescriptions).first {

            // These objects are already CMFormatDescription objects, no need to cast
            let microphoneFormat = microphoneFormatObj
            let systemAudioFormat = systemAudioFormatObj

            if let micASBD = CMAudioFormatDescriptionGetStreamBasicDescription(microphoneFormat)?.pointee,
               let sysASBD = CMAudioFormatDescriptionGetStreamBasicDescription(systemAudioFormat)?.pointee {

                logger.info("Microphone sample rate: \(micASBD.mSampleRate) Hz, channels: \(micASBD.mChannelsPerFrame)")
                logger.info("System audio sample rate: \(sysASBD.mSampleRate) Hz, channels: \(sysASBD.mChannelsPerFrame)")

                // Check if sample rates are different
                if abs(micASBD.mSampleRate - sysASBD.mSampleRate) > 1.0 {
                    logger.warning("Different sample rates detected between microphone and system audio")
                }
            }
        }

        // Check specifically for MacBook internal microphone, which is known to have sample rate issues
        let microphoneAssetName = microphoneURL.lastPathComponent.lowercased()
        if microphoneAssetName.contains("macbook") ||
           microphoneAssetName.contains("built-in") ||
           microphoneAssetName.contains("internal") {
            logger.warning("Detected MacBook internal microphone usage, which may have sample rate synchronization issues")
        }

        // Create a composition
        let composition = AVMutableComposition()

        // Create audio tracks in the composition
        guard let compositionTrack1 = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionTrack2 = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            logger.error("Failed to create composition tracks")
            throw AudioRecorderError.recordingFailed
        }

        // Insert both tracks over their common (shorter) duration. AVAssetExportSession
        // mixes all audio tracks in the output, and clamping to the shorter length keeps a
        // sample-rate/length mismatch from corrupting the export.
        // ponytail: drops the old CMTimeMapping "speed adjustment" path — it was built then
        // discarded (AVMutableCompositionTrack can't apply a time map), so it never did anything.
        let commonDuration = min(microphoneDuration, systemAudioDuration)
        let commonTimeRange = CMTimeRange(start: .zero, duration: commonDuration)
        do {
            try compositionTrack1.insertTimeRange(commonTimeRange, of: microphoneTrack, at: .zero)
            try compositionTrack2.insertTimeRange(commonTimeRange, of: systemAudioTrack, at: .zero)
        } catch {
            logger.error("Failed to insert time ranges: \(error.localizedDescription)")
            throw AudioRecorderError.recordingFailed
        }

        // Set audio mixing to ensure both tracks are audible
        let audioMix = AVMutableAudioMix()

        // Create audio mix parameters for both tracks
        let track1MixParameters = AVMutableAudioMixInputParameters(track: compositionTrack1)
        track1MixParameters.trackID = compositionTrack1.trackID
        track1MixParameters.setVolume(1.0, at: .zero)

        let track2MixParameters = AVMutableAudioMixInputParameters(track: compositionTrack2)
        track2MixParameters.trackID = compositionTrack2.trackID
        track2MixParameters.setVolume(1.0, at: .zero)

        // If there's a significant duration discrepancy, adjust the playback rate using audio processing tap
        if hasDurationDiscrepancy {
            logger.info("Setting up audio mix parameters to handle duration discrepancy")
        }

        audioMix.inputParameters = [track1MixParameters, track2MixParameters]

        // Remove the output file if it already exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
                logger.info("Removed existing file at: \(outputURL.path)")
            } catch {
                logger.error("Failed to remove existing file: \(error.localizedDescription)")
                throw AudioRecorderError.fileOperationFailed
            }
        }

        logger.info("Exporting merged audio as AAC mono, sample rate \(self.mergedAudioSampleRate), bitrate \(self.mergedAudioBitRate)")
        debugLogger.log(
            "Merge export started. micSize=\(microphoneFileSize) systemSize=\(systemAudioFileSize) duration=\(commonDuration.seconds) output=\(outputURL.lastPathComponent) settings=aac mono \(mergedAudioBitRate)bps \(Int(mergedAudioSampleRate))Hz",
            area: .recordings,
            contextURL: outputURL
        )

        do {
            try await exportMixedAudio(composition: composition, audioMix: audioMix, outputURL: outputURL)
        } catch {
            debugLogger.log("Merge export failed. error=\(error.localizedDescription)", area: .recordings, contextURL: outputURL)
            throw error
        }

        // Log the final file size
        if let mergedFileSize = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber {
            let finalSize = mergedFileSize.int64Value
            let totalOriginalSize = microphoneFileSize + systemAudioFileSize
            let compressionRatio = Double(finalSize) / Double(totalOriginalSize)

            logger.info("Merged file size: \(ByteCountFormatter.string(fromByteCount: finalSize, countStyle: .file))")
            logger.info("Compression ratio: \(String(format: "%.2f", compressionRatio * 100))% of original combined size")
            debugLogger.log(
                "Merge export completed. outputSize=\(finalSize) compressionRatio=\(String(format: "%.2f", compressionRatio * 100))%",
                area: .recordings,
                contextURL: outputURL
            )
        }

        logger.info("Audio files successfully merged to: \(outputURL.path)")
        return outputURL
    }

    private func exportMixedAudio(composition: AVMutableComposition, audioMix: AVMutableAudioMix, outputURL: URL) async throws {
        let reader = try AVAssetReader(asset: composition)

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: mergedAudioSampleRate,
            AVNumberOfChannelsKey: mergedAudioChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let audioTracks = composition.tracks(withMediaType: .audio)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: readerSettings)
        readerOutput.audioMix = audioMix

        guard reader.canAdd(readerOutput) else {
            throw AudioRecorderError.recordingFailed
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: mergedAudioSampleRate,
            AVNumberOfChannelsKey: mergedAudioChannels,
            AVEncoderBitRateKey: mergedAudioBitRate
        ]

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw AudioRecorderError.recordingFailed
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? AudioRecorderError.recordingFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? AudioRecorderError.recordingFailed
        }

        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "WhisperNote.AudioMergeWriter")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sampleBuffer) {
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            continuation.resume(throwing: writer.error ?? AudioRecorderError.recordingFailed)
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if reader.status == .failed || reader.status == .cancelled {
                                continuation.resume(throwing: reader.error ?? AudioRecorderError.recordingFailed)
                            } else if writer.status == .failed || writer.status == .cancelled {
                                continuation.resume(throwing: writer.error ?? AudioRecorderError.recordingFailed)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                }
            }
        }
    }

    func importRecording(from sourceURL: URL) {
        importRecording(from: sourceURL, named: nil)
    }

    func importRecording(from sourceURL: URL, named customName: String?) {
        Task {
            do {
                let recording = try await importSingle(from: sourceURL, groupId: nil, groupName: nil, customName: customName)
                await MainActor.run {
                    recordings.append(recording)
                    saveRecordings()
                }
            } catch {
                await MainActor.run {
                    lastError = "Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Import one or more audio files. When more than one file is given, they share a
    /// single groupId/groupName so the UI can show them as one collapsible group.
    func importRecordings(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let groupId: UUID? = urls.count > 1 ? UUID() : nil
        let groupName: String? = groupId == nil ? nil : {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return "Imported batch — \(df.string(from: Date())) (\(urls.count) files)"
        }()

        Task {
            var imported: [Recording] = []
            for sourceURL in urls {
                do {
                    let recording = try await importSingle(from: sourceURL, groupId: groupId, groupName: groupName, customName: nil)
                    imported.append(recording)
                } catch {
                    await MainActor.run {
                        lastError = "Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            guard !imported.isEmpty else { return }
            let importedFinal = imported
            await MainActor.run {
                recordings.append(contentsOf: importedFinal)
                saveRecordings()
            }
        }
    }

    private func importSingle(from sourceURL: URL, groupId: UUID?, groupName: String?, customName: String?) async throws -> Recording {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let uniqueDir = directoryManager.getRecordingsDirectory()
            .appendingPathComponent("import_\(dateFormatter.string(from: Date()))_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destURL = uniqueDir.appendingPathComponent("recording.\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let duration = try await AVAsset(url: destURL).load(.duration).seconds
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let trimmedCustomName = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedCustomName.isEmpty ? sourceName : trimmedCustomName
        debugLogger.log("Imported recording. source=\(sourceURL.path) destination=\(destURL.path) name=\(name) duration=\(duration)", area: .recordings, contextURL: destURL)
        return Recording(name: name, date: Date(), duration: duration,
                         filePath: destURL, systemAudioFilePath: nil,
                         groupId: groupId, groupName: groupName)
    }

    /// Delete every recording belonging to a group.
    func deleteGroup(groupId: UUID) {
        let ids = recordings.filter { $0.groupId == groupId }.map { $0.id }
        for id in ids {
            deleteRecording(id: id)
        }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case recordingFailed
    case permissionDenied
    case directoryError
    case fileNotFound
    case fileOperationFailed

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
        }
    }
}
