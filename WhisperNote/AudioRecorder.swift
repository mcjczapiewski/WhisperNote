import Foundation
import AVFoundation
import SwiftUI
import AppKit
import CoreAudio
import RecordKit
import os.log

class AudioRecorder: NSObject, ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentRecording: Recording?
    @Published var isMicrophoneMuted = false // Default to unmuted
    @Published var lastError: String? // Surfaced to the UI (stop/merge/import failures)

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
    @Published var rkAvailableMicrophones: [RKMicrophone] = []

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

    // MARK: - RecordKit Methods

    /// Refresh the list of available RecordKit devices and check permissions
    func refreshRecordKitDevices() async {
        // Check current authorization status
        let micStatus = RKAuthorization.microphone
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Current authorization status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")

        // Only request microphone permission if not already granted
        if micStatus != .authorized {
            let micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
            logger.info("Microphone permission request result: \(micPermissionGranted)")
        }

        // Don't request system audio permissions here
        // These will be requested only when needed for recording

        // Force refresh the permission status by checking again
        let updatedMicStatus = RKAuthorization.microphone
        let updatedSystemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Updated authorization status - Microphone: \(updatedMicStatus.rawValue), System Audio: \(updatedSystemAudioStatus)")

        // Load available microphones
        await loadAvailableMicrophones()
    }

    /// Load available microphones without checking permissions
    func loadAvailableMicrophones() async {
        // Get available microphones using the non-deprecated API
        let microphones = RKMicrophone.microphones
        logger.info("Found \(microphones.count) microphones")

        // Update published property on main thread
        await MainActor.run {
            self.rkAvailableMicrophones = microphones
        }

        // Get the system's current default input device
        var systemDefaultDeviceID: AudioDeviceID = 0
        var systemDefaultDeviceName: String? = nil

        do {
            // Get the device ID
            systemDefaultDeviceID = try getDefaultInputDevice()
            logger.info("System default input device ID: \(systemDefaultDeviceID)")

            // Get the device name
            systemDefaultDeviceName = getDeviceName(for: systemDefaultDeviceID)
            if let name = systemDefaultDeviceName {
                logger.info("System default input device name: \(name)")
            }

            // Try to find this device in our available microphones using multiple matching strategies

            // Try name match first (most reliable)
            if let name = systemDefaultDeviceName,
               let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.localizedName.contains(name) || name.contains($0.localizedName) }) {
                logger.info("Found system default microphone by name match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            }
            // Try exact ID match
            else if let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.id == String(systemDefaultDeviceID) }) {
                logger.info("Found system default microphone by exact ID match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            }
            // Try partial ID match
            else if let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.id.contains(String(systemDefaultDeviceID)) }) {
                logger.info("Found system default microphone by partial ID match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            }
            else {
                logger.warning("Could not find system default microphone in available microphones")
            }
        } catch {
            logger.error("Failed to get system default input device: \(error.localizedDescription)")
        }

        // Update the preferred microphone to the system default
        if let preferredMic = RKMicrophone.preferred {
            logger.info("RecordKit preferred microphone: \(preferredMic.localizedName) (ID: \(preferredMic.id))")
        } else {
            logger.info("No RecordKit preferred microphone found")
        }
    }

    deinit {
        microphoneStateTimer?.invalidate()
    }

    func startRecording(name: String, microphoneId: String = "") throws {
        // We'll check permissions in the Task below, but also check microphone status synchronously
        if RKAuthorization.microphone == .denied {
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

        // IMPORTANT: Do NOT create the directory - RecordKit needs to create it itself
        // If we create it first, RecordKit will fail with "directory already exists" error

        // Check if the directory already exists (extremely unlikely with UUID)
        if FileManager.default.fileExists(atPath: uniqueDirectory.path) {
            // If it somehow exists, try to remove it first
            do {
                logger.info("Removing existing directory at: \(uniqueDirectory.path)")
                try FileManager.default.removeItem(at: uniqueDirectory)
            } catch {
                logger.error("Failed to remove existing directory: \(error.localizedDescription)")
                throw AudioRecorderError.directoryError
            }
        }

        // Store the recording metadata for later use
        let metadata = [
            "name": sanitizedName,
            "date": dateString,
            "uuid": uuid
        ]
        UserDefaults.standard.set(metadata, forKey: "lastRecordingMetadata")

        // Store the expected output URL with the final output filename
        self.rkRecordingURL = uniqueDirectory.appendingPathComponent("recording.m4a")
        logger.info("Using unique directory: \(uniqueDirectory.path)")

        // Start a Task to handle the async RecordKit operations
        Task {
            do {
                // Check permissions using our consolidated method
                let micPermissionGranted = await checkAndRequestPermissions()

                if !micPermissionGranted {
                    await MainActor.run {
                        logger.error("Microphone permission denied")
                    }
                    throw AudioRecorderError.permissionDenied
                }

                // Check system audio permission
                let systemAudioPermissionGranted = RKAuthorization.systemAudioRecording
                if !systemAudioPermissionGranted {
                    logger.info("System audio permission is required for recording")
                    throw AudioRecorderError.permissionDenied
                }

                // Refresh available microphones
                let microphones = RKMicrophone.microphones
                print("Found \(microphones.count) microphones for recording")

                // Update published property on main thread
                await MainActor.run {
                    self.rkAvailableMicrophones = microphones
                }

                // Create sources array for the recorder
                var sources: [RKRecorder.SchemaItem] = []

                // Log all available microphones
                let availableMics = rkAvailableMicrophones
                logger.info("Available microphones: \(availableMics.map { "\($0.localizedName) (ID: \($0.id))" }.joined(separator: ", "))")

                // Create unique output filenames for each source
                let microphoneFilename = "mic_recording.m4a"
                let systemAudioFilename = "system_recording.m4a"
                // The merged file will be named "recording.m4a"

                // Check if a specific microphone was selected
                if !microphoneId.isEmpty {
                    // Use the selected microphone if it exists
                    if let selectedMic = availableMics.first(where: { $0.id == microphoneId }) {
                        sources.append(.microphone(microphoneID: selectedMic.id, output: .singleFile(filename: microphoneFilename)))
                        logger.info("Using selected microphone: \(selectedMic.localizedName) (ID: \(selectedMic.id))")
                    } else {
                        logger.warning("Selected microphone ID \(microphoneId) not found, falling back to default")
                        // Fall back to default selection logic
                        await selectDefaultMicrophone(sources: &sources, microphoneFilename: microphoneFilename)
                    }
                } else {
                    // No specific microphone selected, use default selection logic
                    await selectDefaultMicrophone(sources: &sources, microphoneFilename: microphoneFilename)
                }

                // Add system audio recording with a different output filename
                sources.append(.systemAudio(output: .singleFile(filename: systemAudioFilename)))
                logger.info("Added system audio source with single file output")

                // Get the output directory path from rkRecordingURL
                let outputDirectory = rkRecordingURL!.deletingLastPathComponent()

                // IMPORTANT: Make sure the directory does NOT exist before creating the recorder
                // RecordKit will fail with "directory already exists" error if it does
                if FileManager.default.fileExists(atPath: outputDirectory.path) {
                    do {
                        logger.info("Removing existing directory at: \(outputDirectory.path)")
                        try FileManager.default.removeItem(at: outputDirectory)
                    } catch {
                        logger.error("Failed to remove existing directory: \(error.localizedDescription)")
                        throw AudioRecorderError.directoryError
                    }
                }

                logger.info("Using output directory: \(outputDirectory.path)")

                // Create settings to ensure consistent sample rates and prevent audio speed issues
                let settings = RKRecorder.Settings(
                    allowFrameReordering: false,
                    updatesUserPreferred: true
                )

                // Note: RecordKit doesn't support direct sample rate and channel count settings
                // We'll handle sample rate issues during the merging process

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
                        let systemAudioStatus = RKAuthorization.systemAudioRecording

                        logger.error("Current permission status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")

                        // Show more detailed error message
                        logger.error("""
                        Permission error: \(error.localizedDescription)

                        Current permission status:
                        - Microphone: \(micStatus.rawValue)
                        - System Audio: \(systemAudioStatus)

                        Please check that WhisperNote has all required permissions in System Settings > Privacy & Security.
                        You may need to restart the app after granting permissions.
                        """)

                        // Try to request permissions again
                        Task {
                            _ = await self.checkAndRequestPermissions()
                        }

                    } else if error.localizedDescription.contains("directory") ||
                              error.localizedDescription.contains("outputDirectory") ||
                              error.localizedDescription.contains("Cannot Save") {
                        logger.error("This appears to be a directory or file error: \(error.localizedDescription)")

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

                        // Log detailed information about the error
                        if let nsError = error as NSError? {
                            logger.error("Error domain: \(nsError.domain), code: \(nsError.code)")
                            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                                logger.error("Underlying error domain: \(underlyingError.domain), code: \(underlyingError.code)")
                            }
                            if let recoverySuggestion = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
                                logger.error("Recovery suggestion: \(recoverySuggestion)")

                                // If the error is about a file already existing, log more details
                                if recoverySuggestion.contains("already in use") {
                                    logger.error("File name conflict detected. Using different filenames for microphone and system audio.")
                                }
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

                        // Log detailed information about the error
                        if let nsError = error as NSError? {
                            logger.error("Error domain: \(nsError.domain), code: \(nsError.code)")
                            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                                logger.error("Underlying error domain: \(underlyingError.domain), code: \(underlyingError.code)")
                            }
                        }
                    }
                }

                // Rethrow as our custom error with more detailed information
                if error.localizedDescription.contains("microphone access") {
                    // Check status but don't need to use it
                    _ = RKAuthorization.microphone
                    throw AudioRecorderError.permissionDenied
                } else if error.localizedDescription.contains("system audio") {
                    // Check status but don't need to use it
                    _ = RKAuthorization.systemAudioRecording
                    throw AudioRecorderError.permissionDenied
                } else if error.localizedDescription.contains("directory") ||
                          error.localizedDescription.contains("outputDirectory") ||
                          error.localizedDescription.contains("Cannot Save") {
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

                    // Find and merge the audio files in the bundle directory
                    // Use a local function to find the audio file URLs and merge them
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
                // Reset recording state so the UI isn't stuck "recording", and surface the error.
                await MainActor.run {
                    isRecording = false
                    isPaused = false
                    durationTimer?.invalidate()
                    self.currentRecording = nil
                    startTime = nil
                    accumulatedTime = 0
                    recordingDuration = 0
                    rkRecorder = nil
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

    // Get the name of an audio device from its ID
    private func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        // Safety check - don't proceed with invalid device IDs
        if deviceID == 0 {
            return nil
        }

        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if the device has a name property
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            return nil
        }

        // Get the size of the property
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        if status != noErr {
            return nil
        }

        // Use a safer approach with withUnsafeMutablePointer
        var deviceName: CFString? = nil
        withUnsafeMutablePointer(to: &deviceName) { ptr in
            status = AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                ptr
            )
        }

        if status != noErr {
            return nil
        }

        // Convert to Swift string if possible
        return deviceName as String?
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

    // MARK: - Permissions and Diagnostics

    // Check and request all necessary permissions
    func checkAndRequestPermissions() async -> Bool {
        // Check if permissions were already checked at app startup
        let permissionsChecked = UserDefaults.standard.bool(forKey: "permissionsCheckedAtStartup")

        // If permissions were already checked at startup, just check the current status
        if permissionsChecked {
            // Check current authorization status
            let micStatus = RKAuthorization.microphone
            let systemAudioStatus = RKAuthorization.systemAudioRecording

            // Only log if we don't have all permissions
            if micStatus != .authorized || !systemAudioStatus {
                logger.info("Current authorization status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")
            }

            UserDefaults.standard.set(systemAudioStatus, forKey: "lastSystemAudioStatus")

            // Return true if we have microphone permission
            return micStatus == .authorized
        }

        // If permissions weren't checked at startup, do a full check
        logger.info("Checking and requesting permissions...")

        // Check current authorization status
        let micStatus = RKAuthorization.microphone
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Current authorization status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")

        // Only request microphone permission if not already granted
        if micStatus != .authorized {
            let micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
            logger.info("Microphone permission request result: \(micPermissionGranted)")

            // Force refresh the microphone status
            let updatedMicStatus = RKAuthorization.microphone
            logger.info("Updated microphone status after request: \(updatedMicStatus.rawValue)")
        }

        // Always request system audio permission if not already granted
        if !systemAudioStatus {
            // Request system audio recording permission
            logger.info("Requesting system audio recording permission...")

            // Use the specific method for system audio
            RKAuthorization.requestSystemAudioRecording()

            // Force refresh the system audio status
            let updatedSystemAudioStatus = RKAuthorization.systemAudioRecording
            logger.info("Updated system audio status after request: \(updatedSystemAudioStatus)")
        }

        // Final check of all permissions after requests
        let finalMicStatus = RKAuthorization.microphone
        let finalSystemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Final permission status - Microphone: \(finalMicStatus.rawValue), System Audio: \(finalSystemAudioStatus)")

        // Store the current permission status in UserDefaults
        UserDefaults.standard.set(finalSystemAudioStatus, forKey: "lastSystemAudioStatus")

        // Set the flag to indicate that permissions have been checked
        UserDefaults.standard.set(true, forKey: "permissionsCheckedAtStartup")

        await loadAvailableMicrophones()

        // Return true if we have microphone permission
        return finalMicStatus == .authorized
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

        // Audio-only preset. MediumQuality is a *video* preset and silently fails to export
        // an audio-only composition — that was the root cause of the save-on-stop error.
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            logger.error("Failed to create export session")
            throw AudioRecorderError.recordingFailed
        }

        // Configure the export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        // Set audio mix time pitch algorithm to optimize quality while maintaining smaller file size
        exportSession.audioTimePitchAlgorithm = .timeDomain // Use timeDomain instead of spectral for better compression

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
        exportSession.audioMix = audioMix

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

        // Export the composition
        await exportSession.export()

        // Surface the real export error instead of masking it.
        guard exportSession.status == .completed else {
            let exportError = exportSession.error
            logger.error("Export failed (status \(exportSession.status.rawValue)): \(exportError?.localizedDescription ?? "unknown")")
            throw exportError ?? AudioRecorderError.recordingFailed
        }

        // Log the final file size
        if let mergedFileSize = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber {
            let finalSize = mergedFileSize.int64Value
            let totalOriginalSize = microphoneFileSize + systemAudioFileSize
            let compressionRatio = Double(finalSize) / Double(totalOriginalSize)

            logger.info("Merged file size: \(ByteCountFormatter.string(fromByteCount: finalSize, countStyle: .file))")
            logger.info("Compression ratio: \(String(format: "%.2f", compressionRatio * 100))% of original combined size")
        }

        logger.info("Audio files successfully merged to: \(outputURL.path)")
        return outputURL
    }

    func importRecording(from sourceURL: URL) {
        importRecordings(from: [sourceURL])
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
                    let recording = try await importSingle(from: sourceURL, groupId: groupId, groupName: groupName)
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

    private func importSingle(from sourceURL: URL, groupId: UUID?, groupName: String?) async throws -> Recording {
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
        let name = sourceURL.deletingPathExtension().lastPathComponent
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

    /// Helper method to select a default microphone using a fallback strategy
    private func selectDefaultMicrophone(sources: inout [RKRecorder.SchemaItem], microphoneFilename: String) async {
        // Use the already loaded microphones instead of refreshing again
        let microphones = self.rkAvailableMicrophones

        // If we don't have any microphones loaded yet, load them now
        if microphones.isEmpty {
            // Get available microphones using the non-deprecated API
            let freshMicrophones = RKMicrophone.microphones

            // Update published property on main thread
            await MainActor.run {
                self.rkAvailableMicrophones = freshMicrophones
            }
        }

        // Log all available microphones for debugging (only if we have a reasonable number)
        if self.rkAvailableMicrophones.count < 10 {
            logger.info("Available microphones for selection: \(self.rkAvailableMicrophones.map { "\($0.localizedName) (ID: \($0.id))" }.joined(separator: ", "))")
        } else {
            logger.info("Found \(self.rkAvailableMicrophones.count) available microphones for selection")
        }

        // Get the system's current default input device
        var systemDefaultDeviceID: AudioDeviceID = 0
        var systemDefaultDeviceName: String? = nil

        do {
            // Get the device ID
            systemDefaultDeviceID = try getDefaultInputDevice()

            // Get the device name
            systemDefaultDeviceName = getDeviceName(for: systemDefaultDeviceID)
        } catch {
            logger.error("Failed to get system default input device: \(error.localizedDescription)")
        }

        // Try name match first (most reliable)
        if let name = systemDefaultDeviceName,
           let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.localizedName.contains(name) || name.contains($0.localizedName) }) {
            sources.append(.microphone(microphoneID: systemDefaultMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using system default microphone by name match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            return
        }

        // Try exact ID match
        if let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.id == String(systemDefaultDeviceID) }) {
            sources.append(.microphone(microphoneID: systemDefaultMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using system default microphone by exact ID match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            return
        }

        // Try partial ID match
        if let systemDefaultMic = rkAvailableMicrophones.first(where: { $0.id.contains(String(systemDefaultDeviceID)) }) {
            sources.append(.microphone(microphoneID: systemDefaultMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using system default microphone by partial ID match: \(systemDefaultMic.localizedName) (ID: \(systemDefaultMic.id))")
            return
        }

        // If that fails, try to use RecordKit's preferred microphone
        if let preferredMic = RKMicrophone.preferred {
            // Use system's preferred microphone from RecordKit
            sources.append(.microphone(microphoneID: preferredMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using RecordKit's preferred microphone: \(preferredMic.localizedName) (ID: \(preferredMic.id))")
            return
        }

        // If no preferred microphone is available, try to find a physical microphone
        let physicalMics = rkAvailableMicrophones.filter { mic in
            let name = mic.localizedName.lowercased()
            return !name.contains("blackhole") &&
                   !name.contains("virtual") &&
                   !name.contains("loopback") &&
                   !name.contains("aggregate")
        }

        if let physicalMic = physicalMics.first {
            // Fall back to the first physical microphone we found
            sources.append(.microphone(microphoneID: physicalMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using physical microphone: \(physicalMic.localizedName) (ID: \(physicalMic.id))")
        } else if let defaultMic = rkAvailableMicrophones.first {
            // Last resort: use the first available microphone
            sources.append(.microphone(microphoneID: defaultMic.id, output: .singleFile(filename: microphoneFilename)))
            logger.info("Using default microphone: \(defaultMic.localizedName) (ID: \(defaultMic.id))")
        } else {
            logger.warning("No microphones available for recording")
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
