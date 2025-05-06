import Foundation
import AVFoundation
import SwiftUI
import AppKit

class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentRecording: Recording?

    private var audioRecorder: AVAudioRecorder?
    private var durationTimer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0

    @AppStorage("audioFormat") private var audioFormat = "wav"
    @AppStorage("audioQuality") private var audioQuality = "high"

    private let directoryManager = DirectoryManager.shared
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        super.init()
        loadRecordings()
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

            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()

            isRecording = true
            isPaused = false
            startTime = Date()
            recordingDuration = 0

            // Create a new recording object
            let newRecording = Recording(
                name: name,
                date: Date(),
                duration: 0,
                filePath: fileURL
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

        audioRecorder?.pause()
        isRecording = false
        isPaused = true

        // Calculate accumulated time
        accumulatedTime += Date().timeIntervalSince(startTime)
        durationTimer?.invalidate()
    }

    func resumeRecording() {
        guard !isRecording, isPaused else { return }

        audioRecorder?.record()
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

        audioRecorder?.stop()
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
            filePath: currentRecording.filePath
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

            // Delete the audio file
            do {
                try FileManager.default.removeItem(at: recording.filePath)
                print("Deleted audio file at: \(recording.filePath.path)")
            } catch {
                print("Error deleting audio file: \(error.localizedDescription)")
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
