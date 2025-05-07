import Foundation
import AVFoundation
import SwiftUI
import AppKit
import CoreAudio

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

    override init() {
        super.init()
        loadRecordings()
        updateMicrophoneMuteState()
    }

    deinit {
        microphoneStateTimer?.invalidate()
    }

    func startRecording(name: String) throws {
        // macOS doesn't use AVAudioSession like iOS does
        // Instead, we'll directly configure the audio recorder

        // Configure audio settings based on user preferences
        var settings: [String: Any] = [
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2
        ]

        // Set format based on user preference
        if audioFormat == "wav" {
            settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsFloatKey] = false
        } else {
            // Default to mp3/m4a
            settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
        }

        // Set quality based on user preference
        switch audioQuality {
        case "low":
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.low.rawValue
        case "medium":
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
        default:
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        }

        // Get the file URL from the directory manager
        let fileURL = directoryManager.getURLForNewRecording(name: name, format: audioFormat)

        // Create a separate file URL for system audio
        let systemAudioFileURL = fileURL.deletingPathExtension().appendingPathExtension("system.\(audioFormat)")

        do {
            // Request microphone permission if needed
            if #available(macOS 10.14, *) {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    // We should request permission here, but for simplicity we'll assume it's granted
                    break
                case .restricted, .denied:
                    throw AudioRecorderError.permissionDenied
                case .authorized:
                    break
                @unknown default:
                    break
                }
            }

            // Start recording microphone audio
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()

            // Start capturing system audio
            do {
                try systemAudioCapture.startCapturing(to: systemAudioFileURL)
                print("System audio capture started")
            } catch {
                print("Failed to start system audio capture: \(error.localizedDescription)")
                // Continue with microphone recording even if system audio fails
            }

            isRecording = true
            isPaused = false
            startTime = Date()
            recordingDuration = 0

            // Create a new recording object
            let newRecording = Recording(
                name: name,
                date: Date(),
                duration: 0,
                filePath: fileURL,
                systemAudioFilePath: systemAudioFileURL
            )

            currentRecording = newRecording

            // Start the timer to update duration
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.startTime else { return }
                self.recordingDuration = self.accumulatedTime + Date().timeIntervalSince(startTime)

                // Update the current recording duration
                self.currentRecording?.duration = self.recordingDuration
            }
        } catch {
            throw AudioRecorderError.recordingFailed
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused, let startTime = startTime else { return }

        // Pause microphone recording
        audioRecorder?.pause()

        // Pause system audio capture
        systemAudioCapture.pauseCapturing()

        isRecording = false
        isPaused = true

        // Calculate accumulated time
        accumulatedTime += Date().timeIntervalSince(startTime)
        durationTimer?.invalidate()
    }

    func resumeRecording() {
        guard !isRecording, isPaused else { return }

        // Resume microphone recording
        audioRecorder?.record()

        // Resume system audio capture
        systemAudioCapture.resumeCapturing()

        isRecording = true
        isPaused = false
        startTime = Date()

        // Restart the timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedTime + Date().timeIntervalSince(startTime)

            // Update the current recording duration
            self.currentRecording?.duration = self.recordingDuration
        }
    }

    func stopRecording() {
        guard let currentRecording = currentRecording else { return }

        // Stop microphone recording
        audioRecorder?.stop()

        // Stop system audio capture
        if let systemAudioURL = systemAudioCapture.stopCapturing() {
            print("System audio capture stopped, file saved at: \(systemAudioURL.path)")
        }

        isRecording = false
        isPaused = false
        durationTimer?.invalidate()

        // Update the final duration
        if let startTime = startTime {
            accumulatedTime += Date().timeIntervalSince(startTime)
        }

        // Create the final recording object with the correct duration
        let finalRecording = Recording(
            id: currentRecording.id,
            name: currentRecording.name,
            date: currentRecording.date,
            duration: accumulatedTime,
            filePath: currentRecording.filePath,
            systemAudioFilePath: currentRecording.systemAudioFilePath
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

            // Delete the system audio file if it exists
            if let systemAudioFilePath = recording.systemAudioFilePath {
                do {
                    try FileManager.default.removeItem(at: systemAudioFilePath)
                    print("Deleted system audio file at: \(systemAudioFilePath.path)")
                } catch {
                    print("Error deleting system audio file: \(error.localizedDescription)")
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
        do {
            let currentlyMuted = try isMicrophoneMutedSystem()
            try setMicrophoneMuteSystem(muted: !currentlyMuted)
            isMicrophoneMuted = !currentlyMuted
            print("Microphone mute toggled: \(isMicrophoneMuted)")
        } catch {
            print("Failed to toggle microphone mute: \(error.localizedDescription)")
        }
    }

    func setMicrophoneMute(muted: Bool) {
        do {
            try setMicrophoneMuteSystem(muted: muted)
            isMicrophoneMuted = muted
            print("Microphone mute set to: \(isMicrophoneMuted)")
        } catch {
            print("Failed to set microphone mute state: \(error.localizedDescription)")
        }
    }

    func updateMicrophoneMuteState() {
        do {
            isMicrophoneMuted = try isMicrophoneMutedSystem()
        } catch {
            // Silently fail - don't log every time
        }
    }
}

// MARK: - Errors

enum AudioRecorderError: Error, LocalizedError {
    case sessionSetupFailed
    case recordingFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .sessionSetupFailed:
            return "Failed to set up audio session. Please check microphone permissions."
        case .recordingFailed:
            return "Failed to start recording. Please try again."
        case .permissionDenied:
            return "Microphone access is denied. Please enable it in System Preferences > Security & Privacy > Privacy > Microphone."
        }
    }
}
