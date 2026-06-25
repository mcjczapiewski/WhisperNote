import SwiftUI
import RecordKit
import os.log

@main
struct WhisperNoteApp: App {
    @StateObject private var audioRecorder = AudioRecorder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "WhisperNoteApp")

    init() {
        // Migrate stale defaultLLMModel stored value to a valid model id.
        // ponytail: one-time migration, no abstraction needed
        let key = "defaultLLMModel"
        let stored = UserDefaults.standard.string(forKey: key)
        if stored == nil || !llmModels.contains(where: { $0.id == stored }) {
            UserDefaults.standard.set(defaultLLMModelId, forKey: key)
        }
    }

    /// Check and request all necessary permissions at app startup.
    /// Called from ContentView.task so macOS has registered the process and status reads correctly.
    static func checkAndRequestAllPermissions() async {
        // Create a logger for this static method
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "WhisperNoteApp")

        // Log current authorization status
        let micStatus = RKAuthorization.microphone
        let systemAudioStatus = RKAuthorization.systemAudioRecording

        logger.info("Current authorization status - Microphone: \(micStatus.rawValue), System Audio: \(systemAudioStatus)")

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

        // Set a flag to indicate that permissions have been checked at startup
        UserDefaults.standard.set(true, forKey: "permissionsCheckedAtStartup")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(audioRecorder)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
