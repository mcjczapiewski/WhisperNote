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

    var body: some View {
        VStack {
            Text("Summaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if summaryManager.summaries.isEmpty {
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
            } else {
                HStack(spacing: 0) {
                    // Sidebar with summary list and refresh button
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                summaryManager.reloadSummaries()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 5)
                            .help("Refresh summaries list")
                        }

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
                    .frame(width: 250)

                    // Divider
                    Divider()

                    // Summary content
                    if let selectedSummary = selectedSummary {
                        VStack {
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
                            }
                            .padding()

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
                                    Markdown(selectedSummary.content)
                                        .textSelection(.enabled)
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
                    } else {
                        Text("Select a summary to view")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
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
            VStack(spacing: 20) {
                Text("Regenerate Summary")
                    .font(.headline)

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
                                        // Generate a new summary with the custom prompt
                                        _ = try await summaryManager.generateSummary(for: transcript, with: customPrompt)
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
            .frame(width: 500, height: 400)
            .padding()
            .onAppear {
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