import Foundation
import AVFoundation
import SwiftUI
import AppKit
import CoreAudio
import RecordKit

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

    @AppStorage("audioFormat") private var audioFormat = "wav"
    @AppStorage("audioQuality") private var audioQuality = "high"

    private let directoryManager = DirectoryManager.shared
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    // RecordKit manager instance
    private let recordKitManager = RecordKitManager()

    override init() {
        super.init()
        loadRecordings()
        updateMicrophoneMuteState()

        // Set up a timer to periodically check microphone state
        microphoneStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMicrophoneMuteState()
        }
    }

    deinit {
        microphoneStateTimer?.invalidate()
    }

    func startRecording(name: String) throws {
        // Get the file URL from the directory manager
        let outputDirectory = directoryManager.getRecordingsDirectory()

        // Start a Task to handle the async RecordKit operations
        Task {
            do {
                // Start recording with RecordKit
                try await recordKitManager.startRecording(name: name, outputDirectory: outputDirectory)

                // Update UI on main thread
                await MainActor.run {
                    // Sync our state with RecordKit manager
                    self.isRecording = recordKitManager.isRecording
                    self.isPaused = recordKitManager.isPaused
                    self.isMicrophoneMuted = recordKitManager.isMicrophoneMuted
                    self.recordingDuration = recordKitManager.recordingDuration

                    // Create a new recording object (placeholder until recording is complete)
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
                        // Update our duration from RecordKit
                        self.recordingDuration = recordKitManager.recordingDuration

                        // Update the current recording duration
                        self.currentRecording?.duration = self.recordingDuration
                    }
                }
            } catch {
                // Handle errors on main thread
                await MainActor.run {
                    print("RecordKit recording failed: \(error.localizedDescription)")
                }
                throw AudioRecorderError.recordingFailed
            }
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        // Pause recording with RecordKit
        recordKitManager.pauseRecording()

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

        // Resume recording with RecordKit
        recordKitManager.resumeRecording()

        // Update our state
        isRecording = true
        isPaused = false
        startTime = Date()

        // Restart the timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Update our duration from RecordKit
            self.recordingDuration = recordKitManager.recordingDuration

            // Update the current recording duration
            self.currentRecording?.duration = self.recordingDuration
        }
    }

    func stopRecording() {
        guard let currentRecording = currentRecording else { return }

        // Stop recording with RecordKit
        Task {
            do {
                // Stop the recording and get the final URL
                if let finalURL = try await recordKitManager.stopRecording() {
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
                        let finalRecording = Recording(
                            id: currentRecording.id,
                            name: currentRecording.name,
                            date: currentRecording.date,
                            duration: accumulatedTime,
                            filePath: finalURL,
                            systemAudioFilePath: nil  // RecordKit handles both in one file
                        )

                        // Add to recordings array
                        recordings.append(finalRecording)

                        // Reset state
                        self.currentRecording = nil
                        startTime = nil
                        accumulatedTime = 0
                        recordingDuration = 0

                        // Save recordings to disk
                        saveRecordings()
                    }
                }
            } catch {
                print("Error stopping RecordKit recording: \(error.localizedDescription)")
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

            // Delete the microphone audio file
            do {
                try FileManager.default.removeItem(at: recording.filePath)
                print("Deleted audio file at: \(recording.filePath.path)")
            } catch {
                print("Error deleting audio file: \(error.localizedDescription)")
            }

            // No longer need to delete system audio files

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

        // Update RecordKit's state
        recordKitManager.setMicrophoneMute(muted: newMuteState)

        // Update our state
        isMicrophoneMuted = newMuteState
        print("Microphone mute toggled: \(isMicrophoneMuted)")

        // Also update system-wide mute
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

            // Update RecordKit's state
            recordKitManager.setMicrophoneMute(muted: muted)

            print("Microphone mute set to: \(isMicrophoneMuted)")
        } catch {
            print("Failed to set microphone mute state: \(error.localizedDescription)")
        }
    }

    func updateMicrophoneMuteState() {
        do {
            // Get the system microphone mute state
            let systemMuted = try isMicrophoneMutedSystem()

            // If we're recording, sync our state with RecordKit
            if isRecording {
                isMicrophoneMuted = recordKitManager.isMicrophoneMuted
            } else {
                // Otherwise use the system state
                isMicrophoneMuted = systemMuted

                // Also update RecordKit's state to match
                recordKitManager.setMicrophoneMute(muted: systemMuted)
            }
        } catch {
            // Silently fail - don't log every time
        }
    }

    // MARK: - System Audio Diagnostics

    // Check if system audio capture is likely to work
    func checkSystemAudioCapture() -> (isReady: Bool, message: String) {
        // Refresh RecordKit devices
        Task {
            await recordKitManager.refreshDevices()
        }

        // Check if RecordKit has any error messages
        if recordKitManager.hasError {
            return (false, recordKitManager.errorMessage)
        }

        // Check if we have microphones available
        let hasMicrophones = !recordKitManager.availableMicrophones.isEmpty
        if !hasMicrophones {
            return (false, "No microphones detected. Please check your audio devices.")
        }

        // RecordKit can capture system audio directly, but we'll still check for virtual audio device
        // as a diagnostic step to help users understand their setup
        let hasVirtualDevice = SystemAudioCapture.hasVirtualAudioDevice()

        // Check if Bluetooth headphones are connected
        let hasBluetoothHeadphones = SystemAudioCapture.isBluetoothHeadphonesConnected()

        if !hasVirtualDevice {
            // RecordKit can still work without a virtual device, but we'll warn the user
            return (true, "RecordKit is ready to record, but no virtual audio device was detected. For best results with system audio, consider installing BlackHole, Loopback, or another virtual audio device.")
        } else if hasBluetoothHeadphones {
            return (true, "RecordKit is ready to record. Bluetooth headphones detected - make sure your system audio is routed through a virtual audio device for best results.")
        }

        // If we get here, everything looks good
        return (true, "System audio capture is properly configured. RecordKit is ready to record both microphone and system audio.")
    }
}

// MARK: - Errors

enum AudioRecorderError: Error, LocalizedError {
    case sessionSetupFailed
    case recordingFailed
    case permissionDenied
    case systemAudioCaptureFailed
    case bluetoothDeviceIssue

    var errorDescription: String? {
        switch self {
        case .sessionSetupFailed:
            return "Failed to set up audio session. Please check microphone permissions."
        case .recordingFailed:
            return "Failed to start recording. Please try again."
        case .permissionDenied:
            return "Microphone access is denied. Please enable it in System Preferences > Security & Privacy > Privacy > Microphone."
        case .systemAudioCaptureFailed:
            return "Failed to capture system audio. Make sure a virtual audio device is installed and configured correctly."
        case .bluetoothDeviceIssue:
            return "There was an issue with Bluetooth audio device. Make sure your virtual audio device is configured to capture Bluetooth audio output."
        }
    }
}
