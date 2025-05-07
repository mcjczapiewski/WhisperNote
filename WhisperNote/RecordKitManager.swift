import Foundation
import SwiftUI
import AVFoundation
import RecordKit

/// A manager class for handling recording using RecordKit
public class RecordKitManager: ObservableObject {
    /// Shared instance for use across the app
    public static let shared = RecordKitManager()

    @Published public var isRecording = false
    @Published public var isPaused = false
    @Published public var recordingDuration: TimeInterval = 0
    @Published public var recordingName: String = ""
    @Published public var isMicrophoneMuted = false

    private var recorder: RKRecorder?
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var recordingURL: URL?

    // Status messages
    @Published public var statusMessage: String = ""
    @Published public var hasError = false
    @Published public var errorMessage: String = ""

    // Available devices
    @Published public var availableWindows: [RKWindow] = []
    @Published public var availableCameras: [RKCamera] = []
    @Published public var availableMicrophones: [RKMicrophone] = []
    @Published public var availableAppleDevices: [RKAppleDevice] = []

    public init() {
        Task {
            await refreshDevices()
        }
    }

    /// Refresh the list of available devices
    public func refreshDevices() async {
        do {
            // Use the updated API methods based on the documentation
            availableWindows = try await RKRecorder.getWindows()
            availableCameras = RKRecorder.getCameras()
            availableMicrophones = RKRecorder.getMicrophones()
            availableAppleDevices = await RKRecorder.getAppleDevices()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusMessage = "Found \(self.availableWindows.count) windows, \(self.availableMicrophones.count) microphones, \(self.availableCameras.count) cameras"
                self.hasError = false
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.hasError = true
                self.errorMessage = "Error refreshing devices: \(error.localizedDescription)"
            }
        }
    }

    /// Start recording with RecordKit
    public func startRecording(name: String, outputDirectory: URL) async throws {
        guard !isRecording else {
            print("Already recording")
            return
        }

        // Create a unique filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        let filename = "\(name)_\(dateString)"

        // Create the output URL
        let outputURL = outputDirectory.appendingPathComponent(filename)
        self.recordingURL = outputURL

        do {
            // Create sources array for the recorder based on the documentation
            var sources: [RKRecordingSource] = []

            // Add microphone if available
            if let microphone = availableMicrophones.first {
                sources.append(.webcam(microphoneID: microphone.id, cameraID: nil))
            }

            // Add system audio recording
            sources.append(.systemAudio)

            // Create the recorder with sources
            recorder = RKRecorder(sources)

            // Set the output file path
            recorder?.outputURL = outputURL

            // Prepare the recorder (this will trigger permission requests)
            try await recorder?.prepare()

            // Start recording
            recorder?.start()

            // Update state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isRecording = true
                self.recordingName = name
                self.recordingStartTime = Date()
                self.startTimer()
                self.statusMessage = "Recording started"
                self.hasError = false
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.hasError = true
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Stop the current recording
    public func stopRecording() async throws -> URL? {
        guard isRecording, let recorder = recorder else {
            print("Not recording")
            return nil
        }

        do {
            // Stop the recording
            try await recorder.stop()
            print("Recording stopped")

            // Update state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isRecording = false
                self.isPaused = false
                self.stopTimer()
                self.statusMessage = "Recording stopped"
                self.hasError = false
            }

            return self.recordingURL
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.hasError = true
                self.errorMessage = "Failed to stop recording: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Pause the current recording
    public func pauseRecording() {
        guard isRecording, !isPaused, let _ = recorder else {
            print("Not recording or already paused")
            return
        }

        // RecordKit doesn't have pause/resume functionality
        // We'll just stop the timer to simulate pausing

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPaused = true
            self.stopTimer()
            self.statusMessage = "Recording paused (timer only)"
        }
    }

    /// Resume a paused recording
    public func resumeRecording() {
        guard isRecording, isPaused else {
            print("Not recording or not paused")
            return
        }

        // RecordKit doesn't have pause/resume functionality
        // We'll just restart the timer to simulate resuming

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPaused = false
            self.startTimer()
            self.statusMessage = "Recording resumed (timer only)"
        }
    }

    /// Toggle microphone mute state
    public func toggleMicrophoneMute() {
        isMicrophoneMuted.toggle()

        // RecordKit doesn't have direct microphone muting
        // We'll use the system-wide muting from AudioRecorder

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMessage = self.isMicrophoneMuted ? "Microphone muted" : "Microphone unmuted"
        }
    }

    /// Set microphone mute state directly
    public func setMicrophoneMute(muted: Bool) {
        if isMicrophoneMuted != muted {
            isMicrophoneMuted = muted

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusMessage = self.isMicrophoneMuted ? "Microphone muted" : "Microphone unmuted"
            }
        }
    }

    // MARK: - Private methods

    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // We'll handle Sendable conformance in a separate extension
}

// Make the class conform to Sendable to avoid warnings
extension RecordKitManager: @unchecked Sendable {}
