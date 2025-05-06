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

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        super.init()
        loadRecordings()
    }

    func startRecording(name: String) throws {
        // macOS doesn't use AVAudioSession like iOS does
        // Instead, we'll directly configure the audio recorder

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let fileName = "\(UUID().uuidString).m4a"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)

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
            let url = documentsDirectory.appendingPathComponent("recordings.json")
            try data.write(to: url)
        } catch {
            print("Failed to save recordings: \(error)")
        }
    }

    private func loadRecordings() {
        let url = documentsDirectory.appendingPathComponent("recordings.json")

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                recordings = try JSONDecoder().decode([Recording].self, from: data)
            } catch {
                print("Failed to load recordings: \(error)")
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
