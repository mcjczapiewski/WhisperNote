import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

struct SettingsView: View {
    @EnvironmentObject private var audioRecorder: AudioRecorder
    @EnvironmentObject private var workflowCoordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject private var shortcutManager: GlobalShortcutManager
    @EnvironmentObject private var librarySearch: LibrarySearchController
    @EnvironmentObject private var summaryTemplateController: SummaryTemplateController
    @EnvironmentObject private var telemetryController: TelemetryController
    @AppStorage("defaultLLMModel") private var defaultLLMModel = defaultLLMModelId
    @AppStorage("audioQuality") private var audioQuality = "high"
    @AppStorage("recordingsDirectory") private var recordingsDirectory = ""
    @AppStorage("elevenlabsApiKey") private var elevenlabsApiKey = ""
    @AppStorage("openrouterApiKey") private var openrouterApiKey = ""
    @AppStorage("autoTranscribeAfterRecording") private var autoTranscribeAfterRecording = false
    @AppStorage("autoTranscriptionLanguage") private var autoTranscriptionLanguage = "eng"
    @AppStorage("autoSummarizeAfterRecording") private var autoSummarizeAfterRecording = false
    @AppStorage("autoSummaryModel") private var autoSummaryModel = defaultLLMModelId
    @AppStorage("processingCompletionNotifications") private var processingCompletionNotifications = false
    @AppStorage("telemetryWebhookEndpoint") private var telemetryWebhookEndpoint = ""

    @State private var isShowingDirectoryPicker = false
    @State private var selectedDirectoryDisplayName = "Default (Documents)"
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isShowingChangelog = false
    @State private var isShowingTemplateLibrary = false
    @State private var isShowingFeedback = false
    @State private var isShowingTelemetryOptOutConfirmation = false
    @State private var telemetryWebhookToken = ""

    private let audioQualities = ["low", "medium", "high"]

    init() {
        // Load the saved directory path when the view is initialized
        if !recordingsDirectory.isEmpty {
            // Extract the last path component for display
            let url = URL(fileURLWithPath: recordingsDirectory)
            selectedDirectoryDisplayName = url.lastPathComponent
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 20)

            // API Keys Section
            GroupBox(label: Text("API Keys").font(.headline)) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Enter your API keys to enable transcription and summarization features")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("ElevenLabs API Key")
                            .font(.subheadline)

                        SecureField("Enter ElevenLabs API Key", text: $elevenlabsApiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("OpenRouter API Key")
                            .font(.subheadline)

                        SecureField("Enter OpenRouter API Key", text: $openrouterApiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.top, 10)
                }
                .padding()
            }
            .padding(.horizontal)

            GroupBox(label: Text("Privacy & Feedback").font(.headline)) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Optional product telemetry is off by default. You can send product feedback whether or not telemetry is enabled.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("When enabled, WhisperNote may send only app version and build, macOS major/minor version, coarse feature outcomes and timing buckets, and a weekly-active signal. Optional feedback sends only its category, message, and the same runtime versions. It never sends audio, transcript or summary text, prompts, file names or paths, recordings, API keys, endpoint URLs, header tokens, device identifiers, or your install identifier in feedback.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(
                        "Enable optional product telemetry",
                        isOn: Binding(
                            get: { telemetryController.consent.enabled },
                            set: { enabled in
                                if enabled {
                                    Task { await telemetryController.enableTelemetry() }
                                } else {
                                    isShowingTelemetryOptOutConfirmation = true
                                }
                            }
                        )
                    )
                    .accessibilityLabel("Enable optional product telemetry")

                    if let version = telemetryController.consent.version,
                       let changedAt = telemetryController.consent.changedAt {
                        Text("Consent version \(version), last changed \(changedAt.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No telemetry consent has been recorded.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Local delivery configuration")
                        .font(.subheadline.weight(.medium))
                    Text("The endpoint stays on this Mac. The header token is stored in your macOS Keychain and is never included in telemetry payloads or status messages.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("HTTPS endpoint", text: $telemetryWebhookEndpoint)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityLabel("Telemetry HTTPS endpoint")
                    SecureField("Header token", text: $telemetryWebhookToken)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityLabel("Telemetry header token")

                    if telemetryController.hasStoredCredential {
                        Text("A header token is already stored in Keychain. Leave this field blank to keep it, or enter a replacement.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Save Delivery Configuration") {
                            Task {
                                _ = await telemetryController.saveConfiguration(
                                    endpoint: telemetryWebhookEndpoint,
                                    token: telemetryWebhookToken
                                )
                            }
                        }
                        .accessibilityLabel("Save telemetry delivery configuration")

                        Button("Clear") {
                            telemetryWebhookEndpoint = ""
                            telemetryWebhookToken = ""
                            Task { await telemetryController.clearConfiguration() }
                        }
                        .accessibilityLabel("Clear telemetry delivery configuration")
                    }

                    HStack {
                        Text("Queue: \(telemetryController.queuedItemCount) item\(telemetryController.queuedItemCount == 1 ? "" : "s")")
                        Spacer()
                        Text(telemetryController.status.message)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Telemetry queue and delivery status")

                    HStack {
                        Button("Send Product Feedback…") {
                            isShowingFeedback = true
                        }
                        .accessibilityLabel("Open product feedback form")

                        Spacer()

                        if telemetryController.consent.enabled {
                            Button("Opt Out and Purge…", role: .destructive) {
                                isShowingTelemetryOptOutConfirmation = true
                            }
                            .accessibilityLabel("Opt out and purge telemetry")
                        }
                    }
                }
                .padding()
            }
            .padding(.horizontal)

            GroupBox(label: Text("Global Recording Shortcut").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Control quick recording while another app is active. The shortcut is disabled until you enable it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Toggle(
                        "Enable global start/stop shortcut",
                        isOn: Binding(
                            get: { shortcutManager.isEnabled },
                            set: { shortcutManager.setEnabled($0) }
                        )
                    )

                    HStack {
                        Text("Shortcut")
                        ShortcutCaptureView(
                            shortcut: shortcutManager.shortcut,
                            onCapture: { shortcutManager.updateShortcut($0) }
                        )
                        .frame(width: 150, height: 30)
                        .help("Click, then press the desired shortcut")
                        Button("Restore ⌥⌘R") { shortcutManager.restoreSuggested() }
                    }

                    if let error = shortcutManager.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }
            .padding(.horizontal)

            GroupBox(label: Text("Record to Results").font(.headline)) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Optionally process a live recording after it has been saved successfully. Defaults are captured when processing begins.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Toggle("Automatically transcribe new recordings", isOn: $autoTranscribeAfterRecording)

                    Picker("Transcription Language", selection: $autoTranscriptionLanguage) {
                        ForEach(RecordingView.TranscriptionLanguageCatalog.all, id: \.0) { language in
                            Text(language.1).tag(language.0)
                        }
                    }
                    .disabled(!autoTranscribeAfterRecording)

                    Toggle("Automatically create a summary", isOn: $autoSummarizeAfterRecording)
                        .disabled(!autoTranscribeAfterRecording)

                    Picker("Summary Model", selection: $autoSummaryModel) {
                        ForEach(llmModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .disabled(!autoTranscribeAfterRecording || !autoSummarizeAfterRecording)

                    HStack(alignment: .center) {
                        Text("Template")
                        Spacer()
                        SummaryTemplatePicker(
                            controller: summaryTemplateController,
                            selectedTemplateID: summaryTemplateController.defaultTemplateValue.stableSelectionID,
                            onSelect: { selectionID in
                                guard let template = summaryTemplateController.template(matching: selectionID) else { return }
                                Task { await summaryTemplateController.setDefault(id: template.id) }
                            }
                        )
                    }
                    .font(.subheadline)
                    .disabled(!autoTranscribeAfterRecording || !autoSummarizeAfterRecording)

                    Button("Manage Summary Templates…") {
                        isShowingTemplateLibrary = true
                    }
                    .disabled(librarySearch.isRebinding || summaryTemplateController.isLibraryRebinding)

                    Toggle("Notify when results are ready", isOn: $processingCompletionNotifications)
                        .disabled(!autoTranscribeAfterRecording)
                }
                .padding()
            }
            .padding(.horizontal)

            // LLM Model Selection
            GroupBox(label: Text("Language Model").font(.headline)) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Select your preferred language model for generating summaries")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Default LLM Model", selection: $defaultLLMModel) {
                        ForEach(llmModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding(.top, 5)
                }
                .padding()
            }
            .padding(.horizontal)

            // Audio Settings
            GroupBox(label: Text("Audio Settings").font(.headline)) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Configure audio recording quality")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Audio Quality")
                            .frame(width: 120, alignment: .leading)

                        Picker("Audio Quality", selection: $audioQuality) {
                            ForEach(audioQualities, id: \.self) { quality in
                                Text(quality.capitalized).tag(quality)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 150)
                    }
                    .padding(.top, 5)

                    Divider()
                        .padding(.vertical, 5)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recordings Location")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Choose where to save your recordings and transcripts")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            VStack(alignment: .leading) {
                                Text(selectedDirectoryDisplayName)
                                    .fontWeight(.medium)

                                if !recordingsDirectory.isEmpty {
                                    Text(recordingsDirectory)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .truncationMode(.middle)
                                        .lineLimit(1)
                                } else {
                                    Text("Using default Documents directory")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Change...") {
                                isShowingDirectoryPicker = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(audioRecorder.currentRecording != nil || librarySearch.isRebinding)
                        }
                        .padding(.vertical, 5)

                        if !recordingsDirectory.isEmpty {
                            Button("Reset to Default") {
                                Task {
                                    if await librarySearch.selectLibrary(path: nil, bookmark: nil) {
                                        recordingsDirectory = ""
                                        selectedDirectoryDisplayName = "Default (Documents)"
                                    }
                                }
                            }
                            .font(.caption)
                            .padding(.top, 5)
                            .disabled(audioRecorder.currentRecording != nil || librarySearch.isRebinding)
                        }
                    }
                }
                .padding()
            }
            .padding(.horizontal)
            .fileImporter(
                isPresented: $isShowingDirectoryPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let selectedURL = try? result.get().first else {
                        print("No directory selected or selection was cancelled")
                        return
                    }
                    guard audioRecorder.currentRecording == nil,
                          !audioRecorder.isStartingRecording,
                          !audioRecorder.isStoppingRecording else {
                        alertMessage = "Stop the current recording before changing the library location."
                        showAlert = true
                        return
                    }

                    // Verify we have access to this directory
                    let canAccess = selectedURL.startAccessingSecurityScopedResource()
                    if !canAccess {
                        alertMessage = "Unable to access the selected directory. Please choose a different location."
                        showAlert = true
                        print("Unable to access the selected directory: \(selectedURL.path)")
                        return
                    }

                    defer {
                        selectedURL.stopAccessingSecurityScopedResource()
                    }

                    // Verify it's a directory
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        alertMessage = "Selected path is not a valid directory. Please choose a different location."
                        showAlert = true
                        print("Selected path is not a directory: \(selectedURL.path)")
                        return
                    }

                    // Store the bookmark data for persistent access
                    let bookmarkData = try selectedURL.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )

                    // Create a test file to verify write access
                    let testFilePath = selectedURL.appendingPathComponent(".write_test")
                    do {
                        try "Test write access".write(to: testFilePath, atomically: true, encoding: .utf8)
                        try FileManager.default.removeItem(at: testFilePath)
                        print("Successfully verified write access to: \(selectedURL.path)")
                    } catch {
                        alertMessage = "Cannot write to the selected directory. Please choose a location with write permissions."
                        showAlert = true
                        print("Warning: Cannot write to selected directory: \(error.localizedDescription)")

                        // Revert the changes since we can't use this directory
                        return
                    }
                    Task {
                        if await librarySearch.selectLibrary(path: selectedURL.path, bookmark: bookmarkData) {
                            recordingsDirectory = selectedURL.path
                            selectedDirectoryDisplayName = selectedURL.lastPathComponent
                        }
                    }
                } catch {
                    alertMessage = "Error selecting directory: \(error.localizedDescription)"
                    showAlert = true
                    print("Error selecting directory: \(error.localizedDescription)")
                }
            }

            Spacer()

            // About Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WhisperNote")
                                .font(.headline)

                            Text("Version \(appVersion)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("View Changelog") {
                            isShowingChangelog = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 5)
            }
            .padding(.horizontal)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Settings Error"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isShowingChangelog) {
            ChangelogView()
        }
        .sheet(isPresented: $isShowingTemplateLibrary) {
            SummaryTemplateLibraryView()
        }
        .sheet(isPresented: $isShowingFeedback) {
            ProductFeedbackView()
                .environmentObject(telemetryController)
        }
        .confirmationDialog(
            "Opt out and purge telemetry?",
            isPresented: $isShowingTelemetryOptOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Opt Out and Purge", role: .destructive) {
                Task { await telemetryController.optOutAndPurge() }
            }
            Button("Keep Telemetry Enabled", role: .cancel) { }
        } message: {
            Text("This permanently removes the local telemetry queue, install identifier, endpoint, and Keychain token. Optional feedback remains available after you configure delivery again.")
        }
        .onChange(of: autoTranscribeAfterRecording) { enabled in
            if !enabled { autoSummarizeAfterRecording = false }
        }
        .onChange(of: elevenlabsApiKey) { _ in workflowCoordinator.transcriptionCredentialDidChange() }
        .onChange(of: openrouterApiKey) { _ in workflowCoordinator.summaryCredentialDidChange() }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.7"
    }
}

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changelog")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                Markdown(ChangelogLoader.load())
                    .padding()
            }
        }
        .frame(width: 640, height: 560)
    }
}

/// Reads the single canonical CHANGELOG.md at the repo root — no separate in-app copy to keep in sync.
enum ChangelogLoader {
    static func load() -> String {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        // ponytail: `swift run` has no Bundle.main resources (repo-root files are outside the
        // SPM target), so fall back to reading straight from the source checkout via this
        // file's own compile-time path. Irrelevant for the packaged .app, which always hits
        // the Bundle.main branch above.
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WhisperNote/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("CHANGELOG.md")
        return (try? String(contentsOf: devURL, encoding: .utf8)) ?? "Changelog unavailable."
    }
}
