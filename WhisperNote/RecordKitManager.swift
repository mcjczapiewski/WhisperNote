import Foundation
import SwiftUI
import AVFoundation
import RecordKit

/// A manager class for handling recording using RecordKit
class RecordKitManager: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingName: String = ""
    @Published var isMicrophoneMuted = false
    
    private var recorder: RKRecorder?
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var recordingURL: URL?
    
    // Status messages
    @Published var statusMessage: String = ""
    @Published var hasError = false
    @Published var errorMessage: String = ""
    
    // Available devices
    @Published var availableWindows: [RKWindow] = []
    @Published var availableCameras: [RKCamera] = []
    @Published var availableMicrophones: [RKMicrophone] = []
    @Published var availableAppleDevices: [RKAppleDevice] = []
    
    init() {
        Task {
            await refreshDevices()
        }
    }
    
    /// Refresh the list of available devices
    func refreshDevices() async {
        do {
            availableWindows = try await RKRecorder.getWindows()
            availableCameras = RKRecorder.getCameras()
            availableMicrophones = RKRecorder.getMicrophones()
            availableAppleDevices = await RKRecorder.getAppleDevices()
            
            DispatchQueue.main.async {
                self.statusMessage = "Found \(self.availableWindows.count) windows, \(self.availableMicrophones.count) microphones, \(self.availableCameras.count) cameras"
                self.hasError = false
            }
        } catch {
            DispatchQueue.main.async {
                self.hasError = true
                self.errorMessage = "Error refreshing devices: \(error.localizedDescription)"
            }
        }
    }
    
    /// Start recording with RecordKit
    func startRecording(name: String, outputDirectory: URL) async throws {
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
            // Configure the recorder with available devices
            var sources: [RKRecordingSource] = []
            
            // Add microphone if available
            if let microphone = availableMicrophones.first {
                sources.append(.microphone(microphoneID: microphone.id))
            }
            
            // Add system audio recording
            sources.append(.systemAudio)
            
            // Create the recorder
            recorder = RKRecorder(sources)
            
            // Prepare the recorder (this will trigger permission requests)
            try await recorder?.prepare()
            
            // Start recording
            recorder?.start()
            
            // Update state
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingName = name
                self.recordingStartTime = Date()
                self.startTimer()
                self.statusMessage = "Recording started"
                self.hasError = false
            }
        } catch {
            DispatchQueue.main.async {
                self.hasError = true
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
            }
            throw error
        }
    }
    
    /// Stop the current recording
    func stopRecording() async throws -> URL? {
        guard isRecording, let recorder = recorder else {
            print("Not recording")
            return nil
        }
        
        do {
            // Stop the recording
            let result = try await recorder.stop()
            print("Recording stopped: \(result)")
            
            // Update state
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.stopTimer()
                self.statusMessage = "Recording stopped"
                self.hasError = false
            }
            
            return self.recordingURL
        } catch {
            DispatchQueue.main.async {
                self.hasError = true
                self.errorMessage = "Failed to stop recording: \(error.localizedDescription)"
            }
            throw error
        }
    }
    
    /// Pause the current recording
    func pauseRecording() {
        guard isRecording, !isPaused, let recorder = recorder else {
            print("Not recording or already paused")
            return
        }
        
        recorder.pause()
        
        DispatchQueue.main.async {
            self.isPaused = true
            self.stopTimer()
            self.statusMessage = "Recording paused"
        }
    }
    
    /// Resume a paused recording
    func resumeRecording() {
        guard isRecording, isPaused, let recorder = recorder else {
            print("Not recording or not paused")
            return
        }
        
        recorder.resume()
        
        DispatchQueue.main.async {
            self.isPaused = false
            self.startTimer()
            self.statusMessage = "Recording resumed"
        }
    }
    
    /// Toggle microphone mute state
    func toggleMicrophoneMute() {
        isMicrophoneMuted.toggle()
        
        // Implement microphone muting logic here
        // This would depend on RecordKit's API for muting
        
        DispatchQueue.main.async {
            self.statusMessage = self.isMicrophoneMuted ? "Microphone muted" : "Microphone unmuted"
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
}
