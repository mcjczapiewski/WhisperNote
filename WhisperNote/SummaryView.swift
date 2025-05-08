import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

struct SummaryView: View {
    @EnvironmentObject var summaryManager: SummaryManager
    @State private var selectedSummary: Summary?
    @State private var isGenerating = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var customPrompt = ""
    @State private var showingPromptEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var summaryToDelete: Summary?
    @State private var isShowingExportDialog = false
    @State private var isShowingExportOptions = false
    @State private var showingSummaryParamsDialog = false
    @State private var meetingType: String = ""
    @State private var audience: String = ""
    // Define the export format separately to avoid complex expressions
    @State private var exportFormat: UTType = .plainText

    // Initialize with markdown format in onAppear

    // MARK: - Main View
    var body: some View {
        VStack {
            Text("Summaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if summaryManager.summaries.isEmpty {
                EmptySummaryView()
            } else {
                MainContentView(
                    summaryManager: summaryManager,
                    selectedSummary: $selectedSummary,
                    summaryToDelete: $summaryToDelete,
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    isShowingExportOptions: $isShowingExportOptions,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    exportFormat: $exportFormat,
                    isShowingExportDialog: $isShowingExportDialog
                )
            }
        }
        .padding()
        .onAppear {
            // Set the markdown format on appear to avoid complex expression in property initialization
            exportFormat = TextDocument.markdownUTType
        }
        .alert(isPresented: $showingError) {
            Alert(
                title: Text("Summary Generation Error"),
                message: Text(errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showingPromptEditor) {
            CustomPromptEditorView(
                customPrompt: $customPrompt,
                showingPromptEditor: $showingPromptEditor,
                selectedSummary: $selectedSummary,
                isGenerating: $isGenerating,
                errorMessage: $errorMessage,
                showingError: $showingError,
                summaryManager: summaryManager
            )
        }
        .alert("Delete Summary", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                summaryToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let summary = summaryToDelete {
                    // If the summary being deleted is the selected one, deselect it
                    if selectedSummary?.id == summary.id {
                        selectedSummary = nil
                    }

                    // Delete the summary
                    summaryManager.deleteSummary(id: summary.id)
                    summaryToDelete = nil
                }
            }
        } message: {
            if let summary = summaryToDelete {
                Text("Are you sure you want to delete the summary \"\(summary.name)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete this summary? This action cannot be undone.")
            }
        }
        .fileExporter(
            isPresented: $isShowingExportDialog,
            document: createExportDocument(),
            contentType: exportFormat,
            defaultFilename: createExportFilename()
        ) { result in
            switch result {
            case .success(let url):
                print("Summary successfully exported to \(url.path)")
            case .failure(let error):
                errorMessage = "Export failed: \(error.localizedDescription)"
                showingError = true
            }
        }
        .sheet(isPresented: $showingSummaryParamsDialog) {
            RegenerateSummaryView(
                customPrompt: $customPrompt,
                showingSummaryParamsDialog: $showingSummaryParamsDialog,
                selectedSummary: $selectedSummary,
                isGenerating: $isGenerating,
                errorMessage: $errorMessage,
                showingError: $showingError,
                summaryManager: summaryManager
            )
        }
    }
}

// MARK: - Empty State View
struct EmptySummaryView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "list.bullet.clipboard")
                .resizable()
                .frame(width: 80, height: 100)
                .foregroundColor(.blue)

            Text("No Summaries Yet")
                .font(.title)

            Text("Generate a summary from a transcript to get started")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Main Content View
struct MainContentView: View {
    @ObservedObject var summaryManager: SummaryManager
    @Binding var selectedSummary: Summary?
    @Binding var summaryToDelete: Summary?
    @Binding var showingDeleteConfirmation: Bool
    @Binding var isShowingExportOptions: Bool
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var exportFormat: UTType
    @Binding var isShowingExportDialog: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with summary list
            SummarySidebarView(
                summaryManager: summaryManager,
                selectedSummary: $selectedSummary,
                summaryToDelete: $summaryToDelete,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )

            // Divider
            Divider()

            // Summary content
            if let selectedSummary = selectedSummary {
                SummaryDetailView(
                    selectedSummary: selectedSummary,
                    summaryManager: summaryManager,
                    isShowingExportOptions: $isShowingExportOptions,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    exportFormat: $exportFormat,
                    isShowingExportDialog: $isShowingExportDialog,
                    selectedSummaryBinding: $selectedSummary
                )
            } else {
                Text("Select a summary to view")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Sidebar View
struct SummarySidebarView: View {
    @ObservedObject var summaryManager: SummaryManager
    @Binding var selectedSummary: Summary?
    @Binding var summaryToDelete: Summary?
    @Binding var showingDeleteConfirmation: Bool

    var body: some View {
        List {
            ForEach(summaryManager.summaries) { summary in
                HStack {
                    VStack(alignment: .leading) {
                        Text(summary.name)
                            .font(.headline)

                        Text(summary.date, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        summaryToDelete = summary
                        showingDeleteConfirmation = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 5)

                    if summary.status == .inProgress {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else if summary.status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if summary.status == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedSummary = summary
                }
                .background(selectedSummary?.id == summary.id ? Color.blue.opacity(0.1) : Color.clear)
            }
        }
        .frame(width: 250)
        .listStyle(SidebarListStyle())
    }
}

// MARK: - Detail View
struct SummaryDetailView: View {
    let selectedSummary: Summary
    @ObservedObject var summaryManager: SummaryManager
    @Binding var isShowingExportOptions: Bool
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var exportFormat: UTType
    @Binding var isShowingExportDialog: Bool
    @Binding var selectedSummaryBinding: Summary?

    var body: some View {
        VStack {
            // Toolbar
            HStack {
                Text(selectedSummary.name)
                    .font(.headline)

                Spacer()

                Button(action: {
                    if selectedSummary.status == .completed {
                        isShowingExportOptions = true
                    }
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedSummary.status != .completed)
                .confirmationDialog("Export Format", isPresented: $isShowingExportOptions) {
                    Button("Markdown (.md)") {
                        exportFormat = TextDocument.markdownUTType
                        isShowingExportDialog = true
                    }

                    Button("Plain Text (.txt)") {
                        exportFormat = .plainText
                        isShowingExportDialog = true
                    }

                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Choose export format")
                }

                Button(action: {
                    // Show dialog for regenerating summary
                    showingSummaryParamsDialog = true
                }) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }

Button(action: {
    // Store the current summary ID
    let currentSummaryId = selectedSummary.id

    // Deselect to force UI update
    selectedSummaryBinding = nil

    // Reload all summaries on the main thread
    DispatchQueue.main.async {
        summaryManager.reloadSummaries()
        // Re-select the updated summary after a short delay to ensure state propagation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let refreshedSummary = summaryManager.summaries.first(where: { $0.id == currentSummaryId }) {
                selectedSummaryBinding = refreshedSummary
            }
        }
    }
}) {
    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
}
.help("Refresh summary content")
            }
            .padding()

            // Content based on status
            if selectedSummary.status == .inProgress {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(2)

                    Text("Generating Summary...")
                        .font(.headline)
                        .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedSummary.status == .completed {
                ScrollView {
                    // Wrap the Markdown view in a VStack with a fixed width to avoid layout issues
                    VStack {
                        Markdown(selectedSummary.content)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            } else if selectedSummary.status == .failed {
                VStack {
                    Image(systemName: "exclamationmark.circle")
                        .resizable()
                        .frame(width: 50, height: 50)
                        .foregroundColor(.red)

                    Text("Summary Generation Failed")
                        .font(.headline)
                        .padding(.top, 10)

                    Button("Retry") {
                        // Retry summary generation
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Custom Prompt Editor View
struct CustomPromptEditorView: View {
    @Binding var customPrompt: String
    @Binding var showingPromptEditor: Bool
    @Binding var selectedSummary: Summary?
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool
    @ObservedObject var summaryManager: SummaryManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Customize Summary Prompt")
                .font(.headline)

            TextEditor(text: $customPrompt)
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.2))
                .padding()

            HStack {
                Button("Cancel") {
                    showingPromptEditor = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Generate Summary") {
                    if !customPrompt.isEmpty && selectedSummary != nil {
                        // Find the transcript for this summary
                        Task {
                            do {
                                isGenerating = true
                                showingPromptEditor = false

                                // Delete the existing summary
                                if let selectedSummary = selectedSummary {
                                    summaryManager.deleteSummary(id: selectedSummary.id)

                                    // Find the transcript for this summary
                                    let transcriptionManager = TranscriptionManager()
                                    if let transcript = transcriptionManager.transcripts.first(where: { $0.id == selectedSummary.transcriptId }) {
                                        // Generate a new summary with the custom prompt
                                        _ = try await summaryManager.generateSummary(for: transcript, with: customPrompt)
                                    } else {
                                        throw NSError(domain: "SummaryView", code: 1,
                                                     userInfo: [NSLocalizedDescriptionKey: "Original transcript not found"])
                                    }
                                }
                                isGenerating = false
                            } catch {
                                isGenerating = false
                                errorMessage = error.localizedDescription
                                showingError = true
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customPrompt.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .padding()
    }
}

// MARK: - Regenerate Summary View
struct RegenerateSummaryView: View {
    @Binding var customPrompt: String
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var selectedSummary: Summary?
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool
    @ObservedObject var summaryManager: SummaryManager
    @State private var selectedModel: String = ""

    private let llmModels = ["openai/gpt-4.1-mini", "google/gemini-2.5-flash-preview", "deepseek/deepseek-chat-v3-0324", "google/gemini-2.5-pro-exp-03-25"]

    // Initialize the selected model when the view appears
    var body: some View {
        VStack(spacing: 20) {
            Text("Regenerate Summary")
                .font(.headline)

            // LLM Model Selection
            VStack(alignment: .leading) {
                Text("Language Model:")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Select LLM Model", selection: $selectedModel) {
                    Text("GPT-4.1 Mini").tag("openai/gpt-4.1-mini")
                    Text("Gemini 2.5 Flash").tag("google/gemini-2.5-flash-preview")
                    Text("DeepSeek Chat v3").tag("deepseek/deepseek-chat-v3-0324")
                    Text("Gemini 2.5 Pro").tag("google/gemini-2.5-pro-exp-03-25")
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)

            Text("Edit Prompt:")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            TextEditor(text: $customPrompt)
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.2))
                .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    showingSummaryParamsDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Regenerate") {
                    if let selectedSummary = selectedSummary {
                        showingSummaryParamsDialog = false

                        // Find the transcript for this summary
                        Task {
                            do {
                                isGenerating = true

                                // Delete the existing summary
                                summaryManager.deleteSummary(id: selectedSummary.id)

                                // Find the transcript for this summary
                                let transcriptionManager = TranscriptionManager()
                                if let transcript = transcriptionManager.transcripts.first(where: { $0.id == selectedSummary.transcriptId }) {
                                    // Generate a new summary with the custom prompt and selected model
                                    _ = try await summaryManager.generateSummary(for: transcript, with: customPrompt, model: selectedModel)
                                } else {
                                    throw NSError(domain: "SummaryView", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "Original transcript not found"])
                                }
                                isGenerating = false
                            } catch {
                                isGenerating = false
                                errorMessage = error.localizedDescription
                                showingError = true
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customPrompt.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .padding()
        .onAppear {
            // Initialize with the default model or the model from the selected summary
            if let summary = selectedSummary {
                selectedModel = summary.model
                customPrompt = summary.prompt
            } else {
                selectedModel = summaryManager.defaultModel
                customPrompt = summaryManager.getDefaultPrompt()
            }
        }
    }
}

extension SummaryView {
    // Helper method to create the export document
    private func createExportDocument() -> TextDocument {
        if let summary = selectedSummary {
            return TextDocument(initialText: summary.content, contentType: exportFormat)
        } else {
            return TextDocument(initialText: "", contentType: exportFormat)
        }
    }

    // Helper method to create the export filename
    private func createExportFilename() -> String {
        let fileExtension = exportFormat == TextDocument.markdownUTType ? ".md" : ".txt"
        if let summary = selectedSummary {
            return "\(summary.name)_summary\(fileExtension)"
        } else {
            return "summary\(fileExtension)"
        }
    }
}
