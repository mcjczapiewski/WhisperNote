import SwiftUI

struct SettingsView: View {
    @AppStorage("elevenlabsApiKey") private var elevenlabsApiKey = ""
    @AppStorage("openrouterApiKey") private var openrouterApiKey = ""
    @AppStorage("defaultLLMModel") private var defaultLLMModel = "gpt-4"
    @AppStorage("audioFormat") private var audioFormat = "wav"
    @AppStorage("audioQuality") private var audioQuality = "high"
    
    private let llmModels = ["gpt-4", "gpt-3.5-turbo", "claude-3-opus", "claude-3-sonnet", "mistral-large", "llama-3"]
    private let audioFormats = ["wav", "mp3"]
    private let audioQualities = ["low", "medium", "high"]
    
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
                }
                .padding()
            }
            .padding(.horizontal)
            
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
