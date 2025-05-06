import Foundation
import AVFoundation
import AppKit

class SystemAudioCapture: NSObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isCapturing = false

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func startCapturing(to fileURL: URL) throws {
        // Initialize the audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw SystemAudioCaptureError.engineInitializationFailed
        }

        // Get the input node (this will be the system audio input)
        let inputNode = audioEngine.inputNode

        // Configure the audio format
        let format = inputNode.outputFormat(forBus: 0)

        // Create an audio file for recording
        do {
            audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        } catch {
            throw SystemAudioCaptureError.fileCreationFailed
        }

        // Install a tap on the input node to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] (buffer, time) in
            guard let self = self, let audioFile = self.audioFile else { return }

            do {
                try audioFile.write(from: buffer)
            } catch {
                print("Error writing to audio file: \(error)")
            }
        }

        // Start the audio engine
        do {
            try audioEngine.start()
            isCapturing = true
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SystemAudioCaptureError.engineStartFailed
        }
    }

    func stopCapturing() -> URL? {
        guard let audioEngine = audioEngine, isCapturing else {
            return nil
        }

        // Stop the audio engine
        audioEngine.stop()

        // Remove the tap
        audioEngine.inputNode.removeTap(onBus: 0)

        // Get the file URL
        let fileURL = audioFile?.url

        // Clean up
        audioFile = nil
        self.audioEngine = nil
        isCapturing = false

        return fileURL
    }

    // Helper method to check if a virtual audio device is available
    static func hasVirtualAudioDevice() -> Bool {
        // Get the available input devices using AVCaptureDeviceDiscoverySession
        let discoverySession = AVCaptureDeviceDiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        guard let devices = discoverySession?.devices else {
            return false
        }

        // Check if any of the devices might be a virtual audio device
        // This is a simplistic check - in a real app, you'd want to be more specific
        for device in devices {
            if device.localizedName.lowercased().contains("blackhole") ||
               device.localizedName.lowercased().contains("loopback") ||
               device.localizedName.lowercased().contains("virtual") {
                return true
            }
        }

        return false
    }

    // Helper method to get a list of available audio devices
    static func getAvailableAudioDevices() -> [String] {
        let discoverySession = AVCaptureDeviceDiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        guard let devices = discoverySession?.devices else {
            return []
        }

        return devices.map { $0.localizedName }
    }
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case engineInitializationFailed
    case fileCreationFailed
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .engineInitializationFailed:
            return "Failed to initialize audio engine."
        case .fileCreationFailed:
            return "Failed to create audio file for recording."
        case .engineStartFailed:
            return "Failed to start audio engine. Make sure a virtual audio device is installed and configured."
        }
    }
}
