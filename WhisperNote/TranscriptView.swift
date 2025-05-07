import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @EnvironmentObject var summaryManager: SummaryManager
    @State private var selectedTranscript: Transcript?
    @State private var isTranscribing = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var transcriptToDelete: Transcript?
    @State private var isShowingExportDialog = false
    @State private var isEditingTranscript = false
    @State private var editedContent: String = ""
    @State private var showingFindReplaceDialog = false
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var showingSummaryParamsDialog = false
    @State private var meetingType: String = ""
    @State private var audience: String = ""
    @State private var selectedModel: String = "openai/gpt-4.1-mini"
    @AppStorage("defaultLLMModel") private var defaultModel = "openai/gpt-4.1-mini"

    // MARK: - Main View
    var body: some View {
        VStack {
            Text("Transcripts")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if transcriptionManager.transcripts.isEmpty {
                EmptyTranscriptView()
            } else {
                MainContentView(
                    transcriptionManager: transcriptionManager,
                    summaryManager: summaryManager,
                    selectedTranscript: $selectedTranscript,
                    transcriptToDelete: $transcriptToDelete,
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    isEditingTranscript: $isEditingTranscript,
                    editedContent: $editedContent,
                    showingFindReplaceDialog: $showingFindReplaceDialog,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    isShowingExportDialog: $isShowingExportDialog,
                    isTranscribing: $isTranscribing,
                    errorMessage: $errorMessage,
                    showingError: $showingError
                )
            }
        }
        .padding()
        .alert(isPresented: $showingError) {
            Alert(
                title: Text("Transcription Error"),
                message: Text(errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Delete Transcript", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                transcriptToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let transcript = transcriptToDelete {
                    // If the transcript being deleted is the selected one, deselect it
                    if selectedTranscript?.id == transcript.id {
                        selectedTranscript = nil
                    }

                    // Delete the transcript
                    transcriptionManager.deleteTranscript(id: transcript.id)
                    transcriptToDelete = nil
                }
            }
        } message: {
            if let transcript = transcriptToDelete {
                Text("Are you sure you want to delete the transcript \"\(transcript.name)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete this transcript? This action cannot be undone.")
            }
        }
        .fileExporter(
            isPresented: $isShowingExportDialog,
            document: createExportDocument(),
            contentType: .plainText,
            defaultFilename: createExportFilename()
        ) { result in
            switch result {
            case .success(let url):
                print("Transcript successfully exported to \(url.path)")
            case .failure(let error):
                errorMessage = "Export failed: \(error.localizedDescription)"
                showingError = true
            }
        }
        .sheet(isPresented: $showingFindReplaceDialog) {
            FindReplaceView(
                findText: $findText,
                replaceText: $replaceText,
                editedContent: $editedContent,
                showingFindReplaceDialog: $showingFindReplaceDialog
            )
        }
        .sheet(isPresented: $showingSummaryParamsDialog) {
            SummaryParametersView(
                meetingType: $meetingType,
                audience: $audience,
                selectedModel: $selectedModel,
                defaultModel: defaultModel,
                showingSummaryParamsDialog: $showingSummaryParamsDialog,
                selectedTranscript: $selectedTranscript,
                errorMessage: $errorMessage,
                showingError: $showingError,
                summaryManager: summaryManager,
                generateCustomPrompt: generateCustomPrompt
            )
        }
    }

    // Helper method to create the export document
    private func createExportDocument() -> TextDocument {
        if let selectedTranscript = selectedTranscript {
            return TextDocument(initialText: selectedTranscript.formattedContent ?? selectedTranscript.content)
        } else {
            return TextDocument(initialText: "")
        }
    }

    // Helper method to create the export filename
    private func createExportFilename() -> String {
        if let selectedTranscript = selectedTranscript {
            return "\(selectedTranscript.name).txt"
        } else {
            return "transcript.txt"
        }
    }

    // Helper method to generate a custom prompt with meeting type and audience
    private func generateCustomPrompt(meetingType: String, audience: String) -> String {
        let meetingTypeText = meetingType.isEmpty ? "meeting" : meetingType
        let audienceText = audience.isEmpty ? "all participants" : audience

        return """
        Review the provided TRANSCRIPT of the \(meetingTypeText). Identify the main participants and their roles. Note the overall structure and flow of the meeting.

        Extract the key discussion points, decisions made, and action items from the TRANSCRIPT. Organize these into a logical structure.

        Summarize the main objectives of the meeting as discussed in the TRANSCRIPT. Highlight how these objectives were addressed during the meeting.

        Identify any critical insights, innovative ideas, or important data points mentioned in the TRANSCRIPT. Ensure these are prominently featured in the final document.

        Create an executive summary that concisely captures the essence of the meeting, its outcomes, and next steps. Tailor this summary to the needs of \(audienceText).

        Develop a detailed list of action items, including responsible parties and deadlines, based on the discussions in the TRANSCRIPT.

        Extract any relevant metrics, KPIs, or quantitative data mentioned in the TRANSCRIPT. Present this information in a clear, visual format (e.g., bullet points, tables).

        Identify any risks, challenges, or concerns raised during the meeting. Summarize these along with any proposed mitigation strategies discussed.

        Compile a list of any resources, tools, or additional information mentioned or requested during the meeting.

        Create a section highlighting key decisions made and the rationale behind them, as discussed in the TRANSCRIPT.

        Develop a 'Next Steps' section that outlines the immediate actions to be taken following the meeting, based on the TRANSCRIPT content.

        If applicable, create a section that tracks progress on ongoing projects or initiatives discussed in the meeting.

        Review the document for clarity, coherence, and relevance to \(audienceText). Ensure all confidential or sensitive information is appropriately handled.

        Generate a table of contents for easy navigation of the final document.

        Provide a final summary of the valuable document created from the TRANSCRIPT, highlighting its key features and how it serves the needs of \(audienceText).

        Format the summary using Markdown syntax with:
        - # for main headings
        - ## for subheadings
        - **bold** for important points
        - - or * for bullet points
        - 1. 2. 3. for numbered lists
        - [text](link) for any links

        Make sure to use proper Markdown formatting to create a well-structured, readable summary.
        The summary should be in the same language as the TRANSCRIPT.
        """
    }
}

// MARK: - Empty State View
struct EmptyTranscriptView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .resizable()
                .frame(width: 80, height: 100)
                .foregroundColor(.blue)

            Text("No Transcripts Yet")
                .font(.title)

            Text("Transcribe a recording from the Recording tab to get started")
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
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var summaryManager: SummaryManager
    @Binding var selectedTranscript: Transcript?
    @Binding var transcriptToDelete: Transcript?
    @Binding var showingDeleteConfirmation: Bool
    @Binding var isEditingTranscript: Bool
    @Binding var editedContent: String
    @Binding var showingFindReplaceDialog: Bool
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var isShowingExportDialog: Bool
    @Binding var isTranscribing: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with transcript list
            TranscriptSidebarView(
                transcriptionManager: transcriptionManager,
                selectedTranscript: $selectedTranscript,
                transcriptToDelete: $transcriptToDelete,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )

            // Divider
            Divider()

            // Transcript content
            if let selectedTranscript = selectedTranscript {
                TranscriptDetailView(
                    selectedTranscript: selectedTranscript,
                    transcriptionManager: transcriptionManager,
                    summaryManager: summaryManager,
                    isEditingTranscript: $isEditingTranscript,
                    editedContent: $editedContent,
                    showingFindReplaceDialog: $showingFindReplaceDialog,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    isShowingExportDialog: $isShowingExportDialog,
                    selectedTranscriptBinding: $selectedTranscript,
                    isTranscribing: $isTranscribing,
                    errorMessage: $errorMessage,
                    showingError: $showingError
                )
            } else {
                Text("Select a transcript to view")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Sidebar View
struct TranscriptSidebarView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @Binding var selectedTranscript: Transcript?
    @Binding var transcriptToDelete: Transcript?
    @Binding var showingDeleteConfirmation: Bool

    var body: some View {
        List {
            ForEach(transcriptionManager.transcripts) { transcript in
                HStack {
                    VStack(alignment: .leading) {
                        Text(transcript.name)
                            .font(.headline)

                        Text(transcript.date, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        transcriptToDelete = transcript
                        showingDeleteConfirmation = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 5)

                    if transcript.status == .inProgress {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else if transcript.status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if transcript.status == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTranscript = transcript
                }
                .contextMenu {
                    Button(action: {
                        transcriptToDelete = transcript
                        showingDeleteConfirmation = true
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .background(selectedTranscript?.id == transcript.id ? Color.blue.opacity(0.1) : Color.clear)
            }
            .onDelete { indexSet in
                let transcriptsToDelete = indexSet.map { transcriptionManager.transcripts[$0] }
                if let firstTranscript = transcriptsToDelete.first {
                    transcriptToDelete = firstTranscript
                    showingDeleteConfirmation = true
                }
            }
        }
        .frame(width: 250)
        .listStyle(SidebarListStyle())
    }
}

// MARK: - Detail View
struct TranscriptDetailView: View {
    let selectedTranscript: Transcript
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var summaryManager: SummaryManager
    @Binding var isEditingTranscript: Bool
    @Binding var editedContent: String
    @Binding var showingFindReplaceDialog: Bool
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var isShowingExportDialog: Bool
    @Binding var selectedTranscriptBinding: Transcript?
    @Binding var isTranscribing: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool

    var body: some View {
        VStack {
            // Toolbar
            HStack {
                Text(selectedTranscript.name)
                    .font(.headline)

                Spacer()

                Button(action: {
                    if selectedTranscript.status == .completed {
                        isShowingExportDialog = true
                    }
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedTranscript.status != .completed)

                Button(action: {
                    // Generate summary with parameters
                    showingSummaryParamsDialog = true
                }) {
                    Label("Generate Summary", systemImage: "list.bullet.clipboard")
                }
                .disabled(selectedTranscript.status != .completed ||
                          summaryManager.summaries.contains(where: { $0.transcriptId == selectedTranscript.id }))

                Button(action: {
                    if !isEditingTranscript {
                        // Start editing
                        editedContent = selectedTranscript.formattedContent ?? selectedTranscript.content
                        isEditingTranscript = true
                    } else {
                        // Save changes
                        transcriptionManager.updateTranscriptContent(id: selectedTranscript.id, newContent: editedContent)
                        isEditingTranscript = false
                    }
                }) {
                    Label(isEditingTranscript ? "Save" : "Edit", systemImage: isEditingTranscript ? "checkmark" : "pencil")
                }
                .disabled(selectedTranscript.status != .completed)

                Button(action: {
                    // Store the current transcript ID
                    let currentTranscriptId = selectedTranscript.id

                    // Reload all transcripts
                    transcriptionManager.reloadTranscripts()

                    // Find and update the selected transcript with the refreshed data
                    if let refreshedTranscript = transcriptionManager.transcripts.first(where: { $0.id == currentTranscriptId }) {
                        selectedTranscriptBinding = refreshedTranscript
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh transcript content")
            }
            .padding()

            // Content based on status
            if selectedTranscript.status == .inProgress {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(2)

                    Text("Transcribing...")
                        .font(.headline)
                        .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTranscript.status == .completed {
                VStack {
                    if isEditingTranscript {
                        HStack {
                            Button(action: {
                                showingFindReplaceDialog = true
                            }) {
                                Label("Find & Replace", systemImage: "magnifyingglass")
                            }

                            Spacer()
                        }
                        .padding(.horizontal)

                        TextEditor(text: $editedContent)
                            .font(.body)
                            .padding()
                            .border(Color.gray.opacity(0.2))
                    } else {
                        ScrollView {
                            if let formattedContent = selectedTranscript.formattedContent, !formattedContent.isEmpty {
                                Text(formattedContent)
                                    .padding()
                                    .textSelection(.enabled)
                            } else {
                                Text(selectedTranscript.content)
                                    .padding()
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if selectedTranscript.status == .failed {
                VStack {
                    Image(systemName: "exclamationmark.circle")
                        .resizable()
                        .frame(width: 50, height: 50)
                        .foregroundColor(.red)

                    Text("Transcription Failed")
                        .font(.headline)
                        .padding(.top, 10)

                    Button("Retry") {
                        // Retry transcription
                        Task {
                            do {
                                isTranscribing = true
                                // Find the original recording
                                let audioRecorder = AudioRecorder()
                                let recordings = audioRecorder.recordings
                                if let recording = recordings.first(where: { $0.id == selectedTranscript.recordingId }) {
                                    // Remove the failed transcript
                                    transcriptionManager.transcripts.removeAll(where: { $0.id == selectedTranscript.id })

                                    // Create a new transcription
                                    _ = try await transcriptionManager.transcribeRecording(recording)
                                } else {
                                    throw NSError(domain: "TranscriptView", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "Original recording not found"])
                                }
                                isTranscribing = false
                            } catch {
                                isTranscribing = false
                                errorMessage = error.localizedDescription
                                showingError = true
                            }
                        }
                    }
                    .disabled(isTranscribing)
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Find and Replace View
struct FindReplaceView: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var editedContent: String
    @Binding var showingFindReplaceDialog: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Find and Replace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text("Find:")
                TextField("Text to find", text: $findText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Text("Replace with:")
                TextField("Replacement text", text: $replaceText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()

            HStack {
                Button("Cancel") {
                    showingFindReplaceDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Replace All") {
                    if !findText.isEmpty {
                        editedContent = editedContent.replacingOccurrences(of: findText, with: replaceText)
                        showingFindReplaceDialog = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(findText.isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 250)
        .padding()
    }
}

// MARK: - Summary Parameters View
struct SummaryParametersView: View {
    @Binding var meetingType: String
    @Binding var audience: String
    @Binding var selectedModel: String
    let defaultModel: String
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var selectedTranscript: Transcript?
    @Binding var errorMessage: String
    @Binding var showingError: Bool
    @ObservedObject var summaryManager: SummaryManager
    let generateCustomPrompt: (String, String) -> String

    var body: some View {
        VStack(spacing: 20) {
            Text("Summary Parameters")
                .font(.headline)
                .onAppear {
                    // Initialize with default values when dialog opens
                    if selectedModel.isEmpty {
                        selectedModel = defaultModel
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("Meeting Type:")
                TextField("e.g., Team Meeting, Client Call, Interview", text: $meetingType)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: meetingType) { newValue in
                        if newValue.isEmpty {
                            meetingType = "General Meeting"
                        }
                    }

                Text("Target Audience:")
                TextField("e.g., Team Members, Management, Clients", text: $audience)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: audience) { newValue in
                        if newValue.isEmpty {
                            audience = "Broad Audience"
                        }
                    }

                Text("Language Model:")
                Picker("Select LLM Model", selection: $selectedModel) {
                    Text("GPT-4.1 Mini").tag("openai/gpt-4.1-mini")
                    Text("Gemini 2.5 Flash").tag("google/gemini-2.5-flash-preview")
                    Text("DeepSeek Chat v3").tag("deepseek/deepseek-chat-v3-0324")
                    Text("Gemini 2.5 Pro").tag("google/gemini-2.5-pro-exp-03-25")
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: .infinity)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    showingSummaryParamsDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Generate Summary") {
                    if let selectedTranscript = selectedTranscript {
                        showingSummaryParamsDialog = false

                        // Apply default values if fields are empty
                        let finalMeetingType = meetingType.isEmpty ? "General Meeting" : meetingType
                        let finalAudience = audience.isEmpty ? "Broad Audience" : audience

                        // Generate custom prompt with meeting type and audience
                        let customPrompt = generateCustomPrompt(finalMeetingType, finalAudience)

                        // Generate summary
                        Task {
                            do {
                                // Pass the selected model to the summary manager
                                _ = try await summaryManager.generateSummary(
                                    for: selectedTranscript,
                                    with: customPrompt,
                                    model: selectedModel
                                )
                            } catch {
                                errorMessage = error.localizedDescription
                                showingError = true
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 380)
        .padding()
    }
}
