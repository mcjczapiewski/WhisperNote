import SwiftUI
import RecordKit
import os.log

@main
struct WhisperNoteApp: App {
    @StateObject private var audioRecorder = AudioRecorder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "WhisperNoteApp")

    init() {
        // We need to use a static method to avoid capturing self in the Task
        // Check and request all permissions at app startup
        Task {
            await WhisperNoteApp.checkAndRequestAllPermissions()
        }
    }

    /// Check and request all necessary permissions at app startup
    private static func checkAndRequestAllPermissions() async {
        // Create a logger for this static method
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "WhisperNoteApp")

        // Log current authorization status
        let micStatus = RKAuthorization.microphone
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("App startup authorization status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")

        // Request microphone permission if not already granted
        var micPermissionGranted = micStatus == .authorized
        if !micPermissionGranted {
            micPermissionGranted = await RKAuthorization.requestMicrophoneAccess()
            logger.info("Microphone permission request result: \(micPermissionGranted)")

            // Force refresh the microphone status
            let updatedMicStatus = RKAuthorization.microphone
            logger.info("Updated microphone status after request: \(updatedMicStatus.rawValue)")
        }

        // Request system audio recording permission
        if !systemAudioStatus {
            logger.info("Requesting system audio recording permission...")

            // Request system audio recording permission
            RKAuthorization.requestSystemAudioRecording()

            // Force refresh the system audio status
            let updatedSystemAudioStatus = RKAuthorization.systemAudioRecording
            logger.info("Updated system audio status after request: \(updatedSystemAudioStatus)")
        }

        // Final check of all permissions after requests
        let finalMicStatus = RKAuthorization.microphone
        let finalSystemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Final app startup permission status - Microphone: \(finalMicStatus.rawValue), System Audio: \(finalSystemAudioStatus)")

        // Store the current permission status in UserDefaults
        UserDefaults.standard.set(finalSystemAudioStatus, forKey: "lastSystemAudioStatus")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(audioRecorder)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
