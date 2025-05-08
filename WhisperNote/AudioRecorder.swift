import Foundation
import AVFoundation
import SwiftUI
import AppKit
import CoreAudio
import RecordKit
import os.log

class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentRecording: Recording?
    @Published var isMicrophoneMuted = false

    private var audioRecorder: AVAudioRecorder?
    private var systemAudioCapture = SystemAudioCapture()
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

    // RecordKit properties
    private var rkRecorder: RKRecorder?
    private var rkRecordingStartTime: Date?
    private var rkRecordingURL: URL?
    private var rkAvailableMicrophones: [RKMicrophone] = []

    override init() {
        super.init()
        loadRecordings()
        updateMicrophoneMuteState()

        // Set up a timer to periodically check microphone state
        microphoneStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMicrophoneMuteState()
        }

        // Initialize RecordKit
        Task {
            await refreshRecordKitDevices()
        }
    }

    // MARK: - RecordKit Methods

    /// Refresh the list of available RecordKit devices and check permissions
    private func refreshRecordKitDevices() async {
        // Check current authorization status
        let micStatus = RKAuthorization.microphone
        let screenStatus = RKAuthorization.screenRecording
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Current authorization status - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")

        // Only request microphone permission if not already granted
        if micStatus != .authorized {
            let micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
            logger.info("Microphone permission request result: \(micPermissionGranted)")
        }

        // Don't request screen recording or system audio permissions here
        // These will be requested only when needed for recording

        // Force refresh the permission status by checking again
        let updatedMicStatus = RKAuthorization.microphone
        let updatedScreenStatus = RKAuthorization.screenRecording
        let updatedSystemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Updated authorization status - Microphone: \(updatedMicStatus.rawValue), Screen Recording: \(updatedScreenStatus), System Audio: \(updatedSystemAudioStatus)")

        // Get available microphones using the non-deprecated API
        rkAvailableMicrophones = RKMicrophone.microphones
        logger.info("Found \(self.rkAvailableMicrophones.count) microphones")
    }

    deinit {
        microphoneStateTimer?.invalidate()
    }

    func startRecording(name: String) throws {
        // We'll check permissions in the Task below, but also check microphone status synchronously
        if RKAuthorization.microphone == .denied {
            print("Microphone permission is denied")
            throw AudioRecorderError.permissionDenied
        }

        // Get the base recordings directory from the directory manager
        let baseDirectory = directoryManager.getRecordingsDirectory()

        // Create a unique subdirectory for this recording
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"  // Added milliseconds for more uniqueness
        let dateString = dateFormatter.string(from: Date())
        let recordingDirName = "\(name)_\(dateString)"
        // We'll use a unique directory name with random suffix instead

        // Always add a random suffix to ensure uniqueness
        let randomSuffix = Int.random(in: 10000...99999)
        let uniqueDirName = "\(recordingDirName)_\(randomSuffix)"
        let uniqueDirectory = baseDirectory.appendingPathComponent(uniqueDirName)

        // Check if the directory already exists (extremely unlikely with the random suffix)
        if FileManager.default.fileExists(atPath: uniqueDirectory.path) {
            // Try to remove it first
            do {
                try FileManager.default.removeItem(at: uniqueDirectory)
                print("Removed existing directory: \(uniqueDirectory.path)")
            } catch {
                print("Failed to remove existing directory: \(error.localizedDescription)")

                // Try with another random suffix
                let newRandomSuffix = Int.random(in: 100000...999999)
                let newUniqueDirName = "\(recordingDirName)_\(newRandomSuffix)"
                let newUniqueDirectory = baseDirectory.appendingPathComponent(newUniqueDirName)

                if FileManager.default.fileExists(atPath: newUniqueDirectory.path) {
                    print("Error: Could not create a unique recording directory")
                    throw AudioRecorderError.directoryError
                }

                // Use the new directory
                self.rkRecordingURL = newUniqueDirectory.appendingPathComponent("recording.m4a")
                print("Using alternative unique directory: \(newUniqueDirectory.path)")
                return
            }
        }

        // Store the expected output URL
        self.rkRecordingURL = uniqueDirectory.appendingPathComponent("recording.m4a")
        print("Using unique directory: \(uniqueDirectory.path)")

        // Start a Task to handle the async RecordKit operations
        Task {
            do {
                // Check current authorization status
                let micStatus = RKAuthorization.microphone
                let screenStatus = RKAuthorization.screenRecording
                let systemAudioStatus = RKAuthorization.systemAudioRecording

                logger.info("Recording authorization status - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")

                // Only request microphone permission if not already granted
                var micPermissionGranted = micStatus == .authorized
                if !micPermissionGranted {
                    micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
                    logger.info("Microphone permission request result: \(micPermissionGranted)")

                    // Force refresh the microphone status
                    let updatedMicStatus = RKAuthorization.microphone
                    logger.info("Updated microphone status after request: \(updatedMicStatus.rawValue)")

                    // Update our local variable based on the refreshed status
                    micPermissionGranted = updatedMicStatus == .authorized

                    if !micPermissionGranted {
                        await MainActor.run {
                            logger.error("Microphone permission denied")
                        }
                        throw AudioRecorderError.permissionDenied
                    }
                }

                // Always check screen recording permission
                var screenPermissionGranted = screenStatus
                if !screenPermissionGranted {
                    logger.info("Requesting screen recording permission...")
                    RKAuthorization.requestScreenRecording()
                    UserDefaults.standard.set(true, forKey: "lastScreenRecordingStatus")

                    // Force refresh the screen recording status
                    screenPermissionGranted = RKAuthorization.screenRecording
                    logger.info("Updated screen recording status after request: \(screenPermissionGranted)")
                } else {
                    logger.info("Screen recording permission already granted")
                }

                // Always check system audio permission
                var systemAudioPermissionGranted = systemAudioStatus
                if !systemAudioPermissionGranted {
                    logger.info("Requesting system audio recording permission...")
                    RKAuthorization.requestSystemAudioRecording()
                    UserDefaults.standard.set(true, forKey: "lastSystemAudioStatus")

                    // Force refresh the system audio status
                    systemAudioPermissionGranted = RKAuthorization.systemAudioRecording
                    logger.info("Updated system audio status after request: \(systemAudioPermissionGranted)")
                } else {
                    logger.info("System audio permission already granted")
                }

                // Final check of all permissions after requests
                let finalMicStatus = RKAuthorization.microphone
                let finalScreenStatus = RKAuthorization.screenRecording
                let finalSystemAudioStatus = RKAuthorization.systemAudioRecording

                logger.info("Final permission status before recording - Microphone: \(finalMicStatus.rawValue), Screen Recording: \(finalScreenStatus), System Audio: \(finalSystemAudioStatus)")

                // Refresh available microphones
                rkAvailableMicrophones = RKMicrophone.microphones
                print("Found \(rkAvailableMicrophones.count) microphones for recording")

                // Create sources array for the recorder
                var sources: [RKRecorder.SchemaItem] = []

                // Use the system's preferred microphone if available, otherwise try to find the default one
                if let preferredMic = RKMicrophone.preferred {
                    sources.append(.microphone(microphoneID: preferredMic.id, output: .singleFile(filename: "recording")))
                    print("Using preferred microphone: \(preferredMic.localizedName) (ID: \(preferredMic.id))")
                } else if let defaultMic = rkAvailableMicrophones.first {
                    sources.append(.microphone(microphoneID: defaultMic.id, output: .singleFile(filename: "recording")))
                    print("Using default microphone: \(defaultMic.localizedName) (ID: \(defaultMic.id))")
                } else {
                    print("Warning: No microphones available for recording")
                }

                // Add system audio recording with single file output option
                sources.append(.systemAudio(output: .singleFile(filename: "recording")))
                print("Added system audio source with single file output")

                // Create the recorder with sources and the unique output directory
                // Use the directory path from rkRecordingURL
                let outputDirectory = rkRecordingURL!.deletingLastPathComponent()

                // Do NOT create the directory - RecordKit needs to create it itself
                // If we create it first, RecordKit will fail with "directory already exists" error

                print("Using output directory: \(outputDirectory.path)")

                // Create settings to ensure consistent sample rates and prevent audio speed issues
                let settings = RKRecorder.Settings(allowFrameReordering: false, updatesUserPreferred: true)

                // Initialize recorder with our settings
                rkRecorder = RKRecorder(sources, outputDirectory: outputDirectory, settings: settings)

                // Prepare the recorder (this will trigger permission requests)
                print("Preparing recorder...")
                try await rkRecorder?.prepare()
                print("Recorder prepared successfully")

                // Start recording
                print("Starting recording...")
                try await rkRecorder?.start()
                logger.info("Recording started successfully")

                // Update UI on main thread
                await MainActor.run {
                    // Update our state
                    self.isRecording = true
                    self.isPaused = false
                    self.rkRecordingStartTime = Date()

                    // Create a new recording object (placeholder until recording is complete)
                    let outputDirectory = rkRecordingURL!.deletingLastPathComponent()
                    let placeholderURL = outputDirectory.appendingPathComponent("\(name)_placeholder.\(audioFormat)")
                    let newRecording = Recording(
                        name: name,
                        date: Date(),
                        duration: 0,
                        filePath: placeholderURL,
                        systemAudioFilePath: nil // RecordKit handles both in one file
                    )

                    self.currentRecording = newRecording

                    // Start our own timer to update UI
                    self.startTime = Date()
                    self.accumulatedTime = 0

                    // Start the timer to update duration
                    self.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        guard let self = self else { return }

                        // Calculate duration from start time
                        if let startTime = self.startTime {
                            self.recordingDuration = Date().timeIntervalSince(startTime) + self.accumulatedTime
                        }

                        // Update the current recording duration
                        self.currentRecording?.duration = self.recordingDuration
                    }
                }
            } catch {
                // Handle errors on main thread
                await MainActor.run {
                    logger.error("RecordKit recording failed: \(error.localizedDescription)")

                    // Check if this is a permissions error
                    if error.localizedDescription.contains("microphone access") ||
                       error.localizedDescription.contains("permission") {
                        logger.error("This appears to be a permissions error")

                        // Check all permission statuses again
                        let micStatus = RKAuthorization.microphone
                        let screenStatus = RKAuthorization.screenRecording
                        let systemAudioStatus = RKAuthorization.systemAudioRecording

                        logger.error("Current permission status - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")

                        // Show more detailed error message
                        logger.error("""
                        Permission error: \(error.localizedDescription)

                        Current permission status:
                        - Microphone: \(micStatus.rawValue)
                        - Screen Recording: \(screenStatus)
                        - System Audio: \(systemAudioStatus)

                        Please check that WhisperNote has all required permissions in System Settings > Privacy & Security.
                        You may need to restart the app after granting permissions.
                        """)

                        // Try to request permissions again
                        Task {
                            _ = await self.checkAndRequestPermissions()
                        }

                    } else if error.localizedDescription.contains("directory") || error.localizedDescription.contains("outputDirectory") {
                        logger.error("This appears to be a directory error: \(error.localizedDescription)")

                        // Try to delete the directory and recreate it
                        if let outputDir = rkRecordingURL?.deletingLastPathComponent() {
                            do {
                                logger.info("Attempting to remove existing directory: \(outputDir.path)")
                                try FileManager.default.removeItem(at: outputDir)
                                logger.info("Successfully removed directory")
                            } catch {
                                logger.error("Failed to remove directory: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        logger.error("Unknown RecordKit error: \(error)")

                        // Log additional diagnostic information
                        let micStatus = RKAuthorization.microphone
                        let screenStatus = RKAuthorization.screenRecording
                        let systemAudioStatus = RKAuthorization.systemAudioRecording

                        logger.error("Current permission status during error - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")
                        logger.error("Available microphones: \(self.rkAvailableMicrophones.count)")
                    }
                }

                // Rethrow as our custom error with more detailed information
                if error.localizedDescription.contains("microphone access") {
                    let micStatus = RKAuthorization.microphone
                    throw AudioRecorderError.permissionDenied
                } else if error.localizedDescription.contains("screen recording") {
                    let screenStatus = RKAuthorization.screenRecording
                    throw AudioRecorderError.permissionDenied
                } else if error.localizedDescription.contains("system audio") {
                    let systemAudioStatus = RKAuthorization.systemAudioRecording
                    throw AudioRecorderError.permissionDenied
                } else if error.localizedDescription.contains("directory") || error.localizedDescription.contains("outputDirectory") {
                    throw AudioRecorderError.directoryError
                } else {
                    throw AudioRecorderError.recordingFailed
                }
            }
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        // RecordKit doesn't have pause/resume functionality
        // We'll just stop the timer to simulate pausing

        // Update our state
        isRecording = false
        isPaused = true

        // Calculate accumulated time for our UI
        if let startTime = startTime {
            accumulatedTime += Date().timeIntervalSince(startTime)
        }
        durationTimer?.invalidate()
    }

    func resumeRecording() {
        guard !isRecording, isPaused else { return }

        // RecordKit doesn't have pause/resume functionality
        // We'll just restart the timer to simulate resuming

        // Update our state
        isRecording = true
        isPaused = false
        startTime = Date()

        // Restart the timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Calculate duration from start time
            if let startTime = self.startTime {
                self.recordingDuration = Date().timeIntervalSince(startTime) + self.accumulatedTime
            }

            // Update the current recording duration
            self.currentRecording?.duration = self.recordingDuration
        }
    }

    func stopRecording() {
        guard let currentRecording = currentRecording else { return }

        // Stop recording with RecordKit
        Task {
            do {
                // Stop the recording
                if let recorder = rkRecorder {
                    let result = try await recorder.stop()
                    logger.info("Recording stopped")

                    // Get the bundle URL from the result
                    let bundleURL = result.bundleURL

                    // Find the actual audio file in the bundle directory
                    // Use a local function to find the audio file URL to avoid capture issues
                    func findAudioFileURL() -> URL {
                        do {
                            // Look for audio files in the bundle directory
                            let fileManager = FileManager.default
                            let bundleContents = try fileManager.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)

                            // Find the first audio file (should be the recording)
                            if let audioURL = bundleContents.first(where: { url in
                                let pathExtension = url.pathExtension.lowercased()
                                return pathExtension == "m4a" || pathExtension == "wav" || pathExtension == "mp4"
                            }) {
                                print("Found audio file: \(audioURL.path)")
                                return audioURL
                            } else {
                                print("No audio file found in bundle directory: \(bundleURL.path)")
                                // Fall back to the bundle URL itself
                                return bundleURL
                            }
                        } catch {
                            print("Error examining bundle directory: \(error.localizedDescription)")
                            // Fall back to the bundle URL
                            return bundleURL
                        }
                    }

                    // Get the audio file URL
                    let audioFileURL = findAudioFileURL()

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
                            systemAudioFilePath: nil  // RecordKit handles both in one file
                        )

                        // Add to recordings array
                        recordings.append(finalRecording)

                        // Reset state
                        self.currentRecording = nil
                        startTime = nil
                        accumulatedTime = 0
                        recordingDuration = 0
                        rkRecorder = nil

                        // Save recordings to disk
                        saveRecordings()
                    }
                }
            } catch {
                logger.error("Error stopping RecordKit recording: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            // Handle recording failure
            print("Recording failed")
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
        do {
            // Get the system microphone mute state
            let systemMuted = try isMicrophoneMutedSystem()

            // Update our state with the system state
            isMicrophoneMuted = systemMuted
        } catch {
            // Silently fail - don't log every time
        }
    }

    // MARK: - Permissions and Diagnostics

    // Check and request all necessary permissions
    func checkAndRequestPermissions() async -> Bool {
        logger.info("Checking and requesting permissions...")

        // Check current authorization status
        let micStatus = RKAuthorization.microphone
        let screenStatus = RKAuthorization.screenRecording
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Current authorization status - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")

        // Get the last known status from UserDefaults (for reference only)
        _ = UserDefaults.standard.bool(forKey: "lastScreenRecordingStatus")
        _ = UserDefaults.standard.bool(forKey: "lastSystemAudioStatus")

        // Only request microphone permission if not already granted
        var micPermissionGranted = micStatus == .authorized
        if !micPermissionGranted {
            micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
            logger.info("Microphone permission request result: \(micPermissionGranted)")

            // Force refresh the microphone status
            let updatedMicStatus = RKAuthorization.microphone
            logger.info("Updated microphone status after request: \(updatedMicStatus.rawValue)")

            // Update our local variable based on the refreshed status
            micPermissionGranted = updatedMicStatus == .authorized
        }

        // Always request screen recording permission if not already granted
        // The RecordKit API returns a Bool for screen recording permission
        if !screenStatus {
            // Request screen recording permission (needed for system audio)
            logger.info("Requesting screen recording permission...")
            RKAuthorization.requestScreenRecording()

            // Store that we've requested it
            UserDefaults.standard.set(true, forKey: "lastScreenRecordingStatus")

            // Force refresh the screen recording status
            let updatedScreenStatus = RKAuthorization.screenRecording
            logger.info("Updated screen recording status after request: \(updatedScreenStatus)")
        } else {
            logger.info("Screen recording permission already granted")
        }

        // Always request system audio permission if not already granted
        if !systemAudioStatus {
            // Request system audio recording permission
            logger.info("Requesting system audio recording permission...")
            RKAuthorization.requestSystemAudioRecording()

            // Store that we've requested it
            UserDefaults.standard.set(true, forKey: "lastSystemAudioStatus")

            // Force refresh the system audio status
            let updatedSystemAudioStatus = RKAuthorization.systemAudioRecording
            logger.info("Updated system audio status after request: \(updatedSystemAudioStatus)")
        } else {
            logger.info("System audio permission already granted")
        }

        // Final check of all permissions after requests
        let finalMicStatus = RKAuthorization.microphone
        let finalScreenStatus = RKAuthorization.screenRecording
        let finalSystemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Final permission status - Microphone: \(finalMicStatus.rawValue), Screen Recording: \(finalScreenStatus), System Audio: \(finalSystemAudioStatus)")

        // Return true if we have microphone permission
        return finalMicStatus == .authorized
    }

    // Check if the app has been granted screen recording permission
    func hasScreenRecordingPermission() -> Bool {
        // Force a fresh check of the permission status
        let status = RKAuthorization.screenRecording
        logger.info("Current screen recording permission status: \(status)")
        return status
    }

    // Check if the app has been granted system audio recording permission
    func hasSystemAudioPermission() -> Bool {
        // Force a fresh check of the permission status
        let status = RKAuthorization.systemAudioRecording
        logger.info("Current system audio permission status: \(status)")
        return status
    }

    // Check if the app has been granted microphone permission
    func hasMicrophonePermission() -> Bool {
        // Force a fresh check of the permission status
        let status = RKAuthorization.microphone
        logger.info("Current microphone permission status: \(status.rawValue)")
        return status == .authorized
    }

    // Check if system audio capture is likely to work
    func checkSystemAudioCapture() -> (isReady: Bool, message: String) {
        // Refresh RecordKit devices
        Task {
            await refreshRecordKitDevices()
        }

        // Check all permission statuses
        let micStatus = RKAuthorization.microphone
        let screenStatus = RKAuthorization.screenRecording
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Checking system audio capture readiness - Microphone: \(micStatus.rawValue), Screen Recording: \(screenStatus), System Audio: \(systemAudioStatus)")

        // Build a status message with all permission states
        var statusMessage = """
        Current permission status:
        - Microphone: \(micStatus == .authorized ? "✓ Granted" : "❌ Missing")
        - Screen Recording: \(screenStatus ? "✓ Granted" : "❌ Missing")
        - System Audio: \(systemAudioStatus ? "✓ Granted" : "❌ Missing")
        """

        // Check microphone permission status
        if micStatus == .denied {
            return (false, "\(statusMessage)\n\nMicrophone access is denied. Please enable it in System Settings > Privacy & Security > Microphone, then restart the app.")
        }

        // Check screen recording permission
        if !screenStatus {
            return (false, "\(statusMessage)\n\nScreen recording permission is required to capture system audio. Please grant this permission when prompted.")
        }

        // Check system audio permission
        if !systemAudioStatus {
            return (false, "\(statusMessage)\n\nSystem audio recording permission is required. Please grant this permission when prompted.")
        }

        // Check if we have microphones available
        let hasMicrophones = !rkAvailableMicrophones.isEmpty
        if !hasMicrophones {
            return (false, "\(statusMessage)\n\nNo microphones detected. Please check your audio devices.")
        }

        // Add microphone information to the status message
        statusMessage += "\n\nAvailable microphones: \(rkAvailableMicrophones.count)"
        if let preferredMic = RKMicrophone.preferred {
            statusMessage += "\nPreferred microphone: \(preferredMic.localizedName)"
        }

        // Check if Bluetooth headphones are connected
        let hasBluetoothHeadphones = SystemAudioCapture.isBluetoothHeadphonesConnected()
        if hasBluetoothHeadphones {
            statusMessage += "\n\nBluetooth headphones detected. This may affect audio quality."
            return (true, "\(statusMessage)\n\nRecordKit is ready to record, but be aware that Bluetooth headphones may cause issues with system audio capture.")
        }

        // Check for virtual audio device
        let hasVirtualDevice = SystemAudioCapture.hasVirtualAudioDevice()
        if !hasVirtualDevice {
            statusMessage += "\n\nNo virtual audio device detected. System audio may not be captured properly."
            return (true, "\(statusMessage)\n\nRecordKit will attempt to record, but system audio may not be captured properly without a virtual audio device like BlackHole.")
        }

        // If we get here, everything looks good
        return (true, "\(statusMessage)\n\nSystem audio capture is properly configured. RecordKit will record both microphone and system audio.")
    }
}

// MARK: - Errors

enum AudioRecorderError: Error, LocalizedError {
    case sessionSetupFailed
    case recordingFailed
    case permissionDenied
    case systemAudioCaptureFailed
    case bluetoothDeviceIssue
    case directoryError

    var errorDescription: String? {
        switch self {
        case .sessionSetupFailed:
            return "Failed to set up audio session. Please check microphone permissions."
        case .recordingFailed:
            return "Failed to start recording. Please try again."
        case .permissionDenied:
            return "Permission denied. Please check that WhisperNote has all required permissions in System Settings > Privacy & Security, then restart the app."
        case .systemAudioCaptureFailed:
            return "Failed to capture system audio. Please check your system audio settings."
        case .bluetoothDeviceIssue:
            return "There was an issue with Bluetooth audio device. Please try using a different audio output device."
        case .directoryError:
            return "There was an issue with the recording directory. Please try again with a different recording name."
        }
    }
}
