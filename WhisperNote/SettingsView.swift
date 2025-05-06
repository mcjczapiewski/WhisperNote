import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("elevenlabsApiKey") private var elevenlabsApiKey = ""
    @AppStorage("openrouterApiKey") private var openrouterApiKey = ""
    @AppStorage("defaultLLMModel") private var defaultLLMModel = "gpt-4"
    @AppStorage("audioFormat") private var audioFormat = "wav"
    @AppStorage("audioQuality") private var audioQuality = "high"
    @AppStorage("recordingsDirectory") private var recordingsDirectory = ""

    @State private var isShowingDirectoryPicker = false
    @State private var selectedDirectoryDisplayName = "Default (Documents)"

    private let llmModels = ["gpt-4", "gpt-3.5-turbo", "claude-3-opus", "claude-3-sonnet", "mistral-large", "llama-3"]
    private let audioFormats = ["wav", "mp3"]
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

            // LLM Model Selection
            GroupBox(label: Text("Language Model").font(.headline)) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Select your preferred language model for generating summaries")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Default LLM Model", selection: $defaultLLMModel) {
                        ForEach(llmModels, id: \.self) { model in
                            Text(model).tag(model)
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
                    Text("Configure audio recording format and quality")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Audio Format")
                            .frame(width: 120, alignment: .leading)

                        Picker("Audio Format", selection: $audioFormat) {
                            ForEach(audioFormats, id: \.self) { format in
                                Text(format.uppercased()).tag(format)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 150)
                    }
                    .padding(.top, 5)

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

                    Divider()
                        .padding(.vertical, 5)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recordings Location")
                            .font(.subheadline)

                        HStack {
                            Text(selectedDirectoryDisplayName)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Change...") {
                                isShowingDirectoryPicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 5)
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
                    let selectedURL = try result.get().first!

                    // Verify we have access to this directory
                    let canAccess = selectedURL.startAccessingSecurityScopedResource()
                    defer {
                        if canAccess {
                            selectedURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    // Store the bookmark data for persistent access
                    let bookmarkData = try selectedURL.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )

                    // Save the bookmark data to UserDefaults
                    UserDefaults.standard.set(bookmarkData, forKey: "recordingsDirectoryBookmark")

                    // Save the path string for easier reference
                    recordingsDirectory = selectedURL.path

                    // Update the display name
                    selectedDirectoryDisplayName = selectedURL.lastPathComponent
                } catch {
                    print("Error selecting directory: \(error.localizedDescription)")
                }
            }

            Spacer()

            // About Section
            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Text("WhisperNote")
                        .font(.headline)

                    Text("Version 1.0.0")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
