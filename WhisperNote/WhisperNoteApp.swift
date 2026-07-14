import SwiftUI

enum WhisperNoteRuntime {
    static var isUnitTestMode: Bool {
        let process = ProcessInfo.processInfo
        let arguments = process.arguments
        let argumentMode = arguments.enumerated().contains { index, argument in
            argument == "-WHISPERNOTE_TEST_MODE" &&
                arguments.indices.contains(index + 1) && arguments[index + 1] == "unit"
        } || arguments.contains("-WHISPERNOTE_TEST_MODE unit")
        let explicitMode = process.environment["WHISPERNOTE_TEST_MODE"] == "unit" || argumentMode
        // UI-test launches may deliberately receive app arguments, but are not injected
        // unit-test hosts. Requiring both signals keeps their real interface available.
        let isInjectedUnitTestHost = process.environment.keys.contains("XCTestConfigurationFilePath")
        // LaunchServices currently drops scheme-defined environment and arguments for
        // hosted macOS tests, so allowlist this embedded unit-test bundle as the fallback.
        let isWhisperNoteUnitTestBundle =
            process.environment["XCTestBundlePath"] == "Contents/PlugIns/WhisperNoteTests.xctest" &&
            process.environment["XCInjectBundleInto"] != nil
        return isInjectedUnitTestHost && (explicitMode || isWhisperNoteUnitTestBundle)
    }
}

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
            if WhisperNoteRuntime.isUnitTestMode {
                Color.clear
            } else {
                ContentView()
                    .frame(minWidth: 800, minHeight: 600)
                    .environmentObject(audioRecorder)
            }
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
