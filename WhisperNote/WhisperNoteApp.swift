import SwiftUI

@main
struct WhisperNoteApp: App {
    @StateObject private var audioRecorder = AudioRecorder()

    init() {
        // Migrate stale defaultLLMModel stored value to a valid model id.
        // ponytail: one-time migration, no abstraction needed
        let key = "defaultLLMModel"
        let stored = UserDefaults.standard.string(forKey: key)
        if stored == nil || !llmModels.contains(where: { $0.id == stored }) {
            UserDefaults.standard.set(defaultLLMModelId, forKey: key)
        }
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
