import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @EnvironmentObject var summaryManager: SummaryManager
    @EnvironmentObject private var navigationRouter: AppNavigationRouter
    @State private var selectedTranscript: Transcript?
    @State private var selectedTranscriptIDs: Set<UUID> = []
    @State private var isTranscribing = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var transcriptToDelete: Transcript?
    @State private var transcriptIDsToDelete: Set<UUID> = []
    @State private var isShowingExportDialog = false
    @State private var exportDocument = TextDocument(initialText: "")
    @State private var exportFilename = "transcript.txt"
    @State private var isEditingTranscript = false
    @State private var editedContent: String = ""
    @State private var showingFindReplaceDialog = false
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var searchText = ""
    @State private var showingSummaryParamsDialog = false
    @State private var meetingType: String = ""
    @State private var audience: String = ""
    @State private var selectedModel: String = defaultLLMModelId
    @AppStorage("defaultLLMModel") private var defaultModel = defaultLLMModelId

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
                TranscriptContentView(
                    transcriptionManager: transcriptionManager,
                    summaryManager: summaryManager,
                    selectedTranscript: $selectedTranscript,
                    selectedTranscriptIDs: $selectedTranscriptIDs,
                    transcriptToDelete: $transcriptToDelete,
                    transcriptIDsToDelete: $transcriptIDsToDelete,
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    isEditingTranscript: $isEditingTranscript,
                    editedContent: $editedContent,
                    showingFindReplaceDialog: $showingFindReplaceDialog,
                    searchText: $searchText,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    isTranscribing: $isTranscribing,
                    errorMessage: $errorMessage,
                    showingError: $showingError,
                    prepareExport: prepareExport
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
                transcriptIDsToDelete.removeAll()
            }
            Button("Delete", role: .destructive) {
                let ids = transcriptIDsToDelete.isEmpty ? Set(transcriptToDelete.map { [$0.id] } ?? []) : transcriptIDsToDelete
                if ids.contains(selectedTranscript?.id ?? UUID()) { selectedTranscript = nil }
                selectedTranscriptIDs.subtract(ids)
                for id in ids { transcriptionManager.deleteTranscript(id: id) }
                transcriptToDelete = nil
                transcriptIDsToDelete.removeAll()
            }
        } message: {
            if transcriptIDsToDelete.count > 1 {
                Text("Are you sure you want to delete \(transcriptIDsToDelete.count) transcripts? This action cannot be undone.")
            } else if let transcript = transcriptToDelete {
                Text("Are you sure you want to delete the transcript \"\(transcript.name)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete this transcript? This action cannot be undone.")
            }
        }
        .fileExporter(
            isPresented: $isShowingExportDialog,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
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
        .onAppear { selectRoutedTranscript() }
        .onChange(of: navigationRouter.transcriptID) { _ in selectRoutedTranscript() }
    }

    private func selectRoutedTranscript() {
        guard let id = navigationRouter.transcriptID,
              let transcript = transcriptionManager.transcripts.first(where: { $0.id == id }) else { return }
        selectedTranscript = transcript
        selectedTranscriptIDs = [id]
        navigationRouter.consumeTranscriptRoute(id)
    }

    private func prepareExport(for transcript: Transcript) {
        exportDocument = TextDocument(initialText: transcript.formattedContent ?? transcript.content)
        exportFilename = "\(transcript.name).txt"
        isShowingExportDialog = true
    }

    // Helper method to generate a custom prompt with recording type and audience
    private func generateCustomPrompt(meetingType: String, audience: String) -> String {
        let meetingTypeText = meetingType.isEmpty ? "recording" : meetingType
        let audienceText = audience.isEmpty ? "all participants" : audience

        return """
        Review the provided TRANSCRIPT from the \(meetingTypeText). Identify the main speakers, participants, topics, and overall structure where applicable.

        Extract the key ideas, discussion points, decisions, action items, examples, explanations, and follow-up items from the TRANSCRIPT. Include only the sections that are relevant to this transcript type.

        Summarize the main objectives or purpose of the recording as reflected in the TRANSCRIPT. Highlight how these objectives were addressed.

        Identify any critical insights, important concepts, innovative ideas, examples, frameworks, or data points mentioned in the TRANSCRIPT. Ensure these are prominently featured in the final document.

        Create a concise overview that captures the essence, outcomes, and practical value of the transcript. Tailor the output to the needs of \(audienceText).

        If the TRANSCRIPT contains action items, create a detailed list including responsible parties and deadlines when available.

        Extract any relevant metrics, KPIs, quantitative data, dates, names, resources, links, tools, or references mentioned in the TRANSCRIPT. Present this information clearly using bullet points or tables where useful.

        Identify any risks, challenges, concerns, open questions, or unresolved issues raised in the TRANSCRIPT. Summarize any proposed mitigation strategies or answers discussed.

        Compile a list of any resources, tools, readings, references, or additional information mentioned or requested.

        If decisions are made, create a section highlighting the decisions and the rationale behind them.

        If next steps are discussed, create a 'Next Steps' section that outlines the immediate actions to be taken.

        If applicable, create a section that tracks progress on ongoing projects, learning topics, initiatives, or themes discussed in the transcript.

        Review the document for clarity, coherence, and relevance to \(audienceText). Ensure all confidential or sensitive information is appropriately handled.

        Generate a table of contents for easy navigation of the final document.

        Provide a final summary of the document created from the TRANSCRIPT, highlighting its key takeaways and how it serves the needs of \(audienceText).

        Format the summary using Markdown syntax with:
        - # for main headings
        - ## for subheadings
        - **bold** for important points
        - - or * for bullet points
        - 1. 2. 3. for numbered lists
        - [text](link) for any links

        Make sure to use proper Markdown formatting to create a well-structured, readable summary.
        IMPORTANT: The summary should be in the same language as the TRANSCRIPT.
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

// MARK: - Transcript Content View
struct TranscriptContentView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var summaryManager: SummaryManager
    @Binding var selectedTranscript: Transcript?
    @Binding var selectedTranscriptIDs: Set<UUID>
    @Binding var transcriptToDelete: Transcript?
    @Binding var transcriptIDsToDelete: Set<UUID>
    @Binding var showingDeleteConfirmation: Bool
    @Binding var isEditingTranscript: Bool
    @Binding var editedContent: String
    @Binding var showingFindReplaceDialog: Bool
    @Binding var searchText: String
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var isTranscribing: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool
    let prepareExport: (Transcript) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with transcript list
            TranscriptSidebarView(
                transcriptionManager: transcriptionManager,
                selectedTranscript: $selectedTranscript,
                selectedTranscriptIDs: $selectedTranscriptIDs,
                transcriptToDelete: $transcriptToDelete,
                transcriptIDsToDelete: $transcriptIDsToDelete,
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
                    searchText: $searchText,
                    showingSummaryParamsDialog: $showingSummaryParamsDialog,
                    selectedTranscriptBinding: $selectedTranscript,
                    isTranscribing: $isTranscribing,
                    errorMessage: $errorMessage,
                    showingError: $showingError,
                    prepareExport: prepareExport
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
    @Binding var selectedTranscriptIDs: Set<UUID>
    @Binding var transcriptToDelete: Transcript?
    @Binding var transcriptIDsToDelete: Set<UUID>
    @Binding var showingDeleteConfirmation: Bool

    var body: some View {
        List(selection: $selectedTranscriptIDs) {
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
                        transcriptIDsToDelete = selectedTranscriptIDs.contains(transcript.id) ? selectedTranscriptIDs : [transcript.id]
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
                .contextMenu {
                    Button(action: {
                        FinderHelper.showInFinder(transcriptFinderURL(transcript))
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                    }

                    Button(action: {
                        transcriptToDelete = transcript
                        transcriptIDsToDelete = selectedTranscriptIDs.contains(transcript.id) ? selectedTranscriptIDs : [transcript.id]
                        showingDeleteConfirmation = true
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedTranscriptIDs.contains(transcript.id) ? Color.blue.opacity(0.18) : Color.black.opacity(0.10))
                        .padding(.vertical, 2)
                )
                .tag(transcript.id)
            }
            .onDelete { indexSet in
                let ids = Set(indexSet.map { transcriptionManager.transcripts[$0].id })
                if let firstTranscript = transcriptionManager.transcripts.first(where: { ids.contains($0.id) }) {
                    transcriptToDelete = firstTranscript
                    transcriptIDsToDelete = ids
                    showingDeleteConfirmation = true
                }
            }
        }
        .frame(width: 250)
        .listStyle(SidebarListStyle())
        .scrollContentBackground(.hidden)
        .onChange(of: selectedTranscriptIDs) { ids in
            selectedTranscript = transcriptionManager.transcripts.first(where: { ids.contains($0.id) })
        }
    }

    private func transcriptFinderURL(_ transcript: Transcript) -> URL {
        transcript.jsonFilePath ?? DirectoryManager.shared.getTranscriptsDirectory().appendingPathComponent("transcripts.json")
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
    @Binding var searchText: String
    @Binding var showingSummaryParamsDialog: Bool
    @Binding var selectedTranscriptBinding: Transcript?
    @Binding var isTranscribing: Bool
    @Binding var errorMessage: String
    @Binding var showingError: Bool
    let prepareExport: (Transcript) -> Void

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                Text(selectedTranscript.name)
                    .font(.headline)

                LibraryMetadataControls(itemKey: LibraryItemKey(kind: .transcript, id: selectedTranscript.id))

                Spacer()
                }

                HStack(spacing: 8) {
                ReadOnlyTextSearchField(text: $searchText, content: selectedTranscript.formattedContent ?? selectedTranscript.content)

                Spacer()
                Button(action: {
                    if selectedTranscript.status == .completed {
                        prepareExport(selectedTranscript)
                    }
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .libraryActionButton()
                .disabled(selectedTranscript.status != .completed)

                Button(action: {
                    // Generate summary with parameters
                    showingSummaryParamsDialog = true
                }) {
                    Label("Generate Summary", systemImage: "list.bullet.clipboard")
                }
                .libraryActionButton()
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
                .libraryActionButton()
                .disabled(selectedTranscript.status != .completed)

Button(action: {
    // Store the current transcript ID
    let currentTranscriptId = selectedTranscript.id

    // Deselect to force UI update
    selectedTranscriptBinding = nil

    // Reload all transcripts on the main thread
    DispatchQueue.main.async {
        transcriptionManager.reloadTranscripts()
        // Re-select the updated transcript after a short delay to ensure state propagation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let refreshedTranscript = transcriptionManager.transcripts.first(where: { $0.id == currentTranscriptId }) {
                selectedTranscriptBinding = refreshedTranscript
            }
        }
    }
}) {
    Label("Refresh", systemImage: "arrow.clockwise")
}
.libraryActionButton()
.help("Refresh transcript content")
                }
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
                        ReadOnlyTranscriptTextView(
                            text: selectedTranscript.formattedContent ?? selectedTranscript.content,
                            searchText: searchText
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                // ponytail: group transcripts use groupId as recordingId, so this single-recording
                                // lookup misses them and Retry shows "Original recording not found"; wire group-retry only if needed.
                                if let recording = recordings.first(where: { $0.id == selectedTranscript.recordingId }) {
                                    // Remove the failed transcript
                                    transcriptionManager.transcripts.removeAll(where: { $0.id == selectedTranscript.id })

                                    // Create a new transcription and auto-select it
                                    let completed = try await transcriptionManager.transcribeRecording(recording)
                                    selectedTranscriptBinding = completed
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
    @EnvironmentObject private var summaryTemplateController: SummaryTemplateController
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

    @State private var isPromptPreviewVisible = false
    @State private var isEnhancingPrompt = false
    @State private var isSavingTemplate = false
    @State private var draftState = SummaryTemplateDraftState()
    @State private var saveTemplateName = ""
    @State private var templateOperationMessage: String?

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
                HStack {
                    Text("Summary Template:")
                    Spacer()
                    SummaryTemplatePicker(
                        controller: summaryTemplateController,
                        selectedTemplateID: draftState.sourceTemplateID,
                        allowsCustom: true,
                        onSelect: selectTemplate
                    )
                }
                Text("Draft: \(draftState.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Recording Type:")
                TextField("e.g., Team Meeting, Workshop, Lecture, Interview", text: $meetingType)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: meetingType) { _ in
                        updatePromptPreviewIfNeeded()
                    }

                Text("Target Audience:")
                TextField("e.g., Team Members, Management, Clients", text: $audience)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: audience) { _ in
                        updatePromptPreviewIfNeeded()
                    }

                Text("Language Model:")
                Picker("Select LLM Model", selection: $selectedModel) {
                    ForEach(llmModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: .infinity)
                .onChange(of: selectedModel) { draftState.setModel($0) }
            }
            .padding()

            HStack {
                Button("Preview Prompt") {
                    showPromptPreview(overwriteExistingPrompt: true)
                }

                Button {
                    enhancePrompt()
                } label: {
                    if isEnhancingPrompt {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Enhancing...")
                        }
                    } else {
                        Text("Enhance Prompt")
                    }
                }
                .disabled(isEnhancingPrompt || promptForGeneration().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if isPromptPreviewVisible {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt Preview")
                        .font(.headline)
                    Text("Edit this prompt if needed. The text shown here will be used when you generate the summary.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: Binding(
                        get: { draftState.prompt },
                        set: {
                            draftState.editPrompt($0)
                            clearTemplateFeedback()
                        }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .border(Color.secondary.opacity(0.3))

                    HStack {
                        TextField("Name for saved template", text: $saveTemplateName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: saveTemplateName) { _ in clearTemplateFeedback() }
                        Button("Save as Template") {
                            saveTemplate()
                        }
                        .disabled(isSavingTemplate || !canSaveTemplate)
                        Button("Update Template") {
                            updateTemplate()
                        }
                        .disabled(isSavingTemplate || !draftState.canUpdateSourceTemplate)
                    }
                    if let message = summaryTemplateController.errorMessage ?? templateOperationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(summaryTemplateController.errorMessage == nil ? .secondary : .red)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Cancel") {
                    showingSummaryParamsDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Generate Summary") {
                    if let selectedTranscript = selectedTranscript {
                        showingSummaryParamsDialog = false
                        draftState.setModel(selectedModel)
                        let snapshot = draftState.snapshot()

                        // Generate summary
                        Task {
                            do {
                                // Pass the selected model to the summary manager
                                _ = try await summaryManager.generateSummary(
                                    for: selectedTranscript,
                                    snapshot: snapshot
                                )
                            } catch {
                                errorMessage = error.localizedDescription
                                showingError = true
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEnhancingPrompt || promptForGeneration().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 680, height: isPromptPreviewVisible ? 720 : 420)
        .padding()
        .task {
            await initializeDefaultWhenAvailable()
        }
        .onChange(of: summaryTemplateController.templates) { _ in initializePublishedDefaultIfAvailable() }
        .onChange(of: summaryTemplateController.isLibraryRebinding) { rebinding in
            if !rebinding { initializePublishedDefaultIfAvailable() }
        }
        .onDisappear { draftState.invalidateRequests() }
    }

    private func promptForGeneration() -> String {
        if draftState.isInitialized {
            return draftState.prompt
        }

        return generateCustomPrompt(recordingTypeForPrompt(), audienceForPrompt())
    }

    private func showPromptPreview(overwriteExistingPrompt: Bool) {
        if overwriteExistingPrompt || !draftState.isDirty {
            draftState.chooseGuided(
                prompt: generateCustomPrompt(recordingTypeForPrompt(), audienceForPrompt()),
                model: selectedModel
            )
        }
        isPromptPreviewVisible = true
    }

    private func updatePromptPreviewIfNeeded() {
        guard isPromptPreviewVisible else { return }
        draftState.refreshGuidedPrompt(generateCustomPrompt(recordingTypeForPrompt(), audienceForPrompt()))
    }

    private func enhancePrompt() {
        guard !isEnhancingPrompt else { return }
        showPromptPreview(overwriteExistingPrompt: false)
        let promptToEnhance = promptForGeneration()
        let context = draftState.requestContext()
        isEnhancingPrompt = true

        Task {
            do {
                let enhancedPrompt = try await summaryManager.enhancePrompt(promptToEnhance, model: context.model)
                if draftState.applyEnhancedPrompt(enhancedPrompt, ifUnchanged: context) {
                    isPromptPreviewVisible = true
                }
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isEnhancingPrompt = false
        }
    }

    private func recordingTypeForPrompt() -> String {
        let trimmed = meetingType.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "General Recording" : trimmed
    }

    private func audienceForPrompt() -> String {
        let trimmed = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Broad Audience" : trimmed
    }

    private var selectedSourceTemplate: SummaryTemplate? {
        summaryTemplateController.template(matching: draftState.sourceTemplateID)
    }

    private func selectTemplate(_ selectionID: String?) {
        clearTemplateFeedback()
        guard let template = summaryTemplateController.template(matching: selectionID) else {
            draftState.chooseGuided(
                prompt: generateCustomPrompt(recordingTypeForPrompt(), audienceForPrompt()),
                model: selectedModel
            )
            isPromptPreviewVisible = true
            return
        }
        draftState.selectTemplate(template, model: selectedModel)
        isPromptPreviewVisible = true
    }

    private var canSaveTemplate: Bool {
        let name = saveTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        return draftState.canSaveAsTemplate
            && !name.isEmpty
            && name.count <= SummaryTemplateRepository.maximumNameLength
    }

    private func saveTemplate() {
        guard !isSavingTemplate, canSaveTemplate else { return }
        let name = saveTemplateName
        let context = draftState.requestContext()
        isSavingTemplate = true
        clearTemplateFeedback()
        Task {
            defer { isSavingTemplate = false }
            guard let created = await summaryTemplateController.create(name: name, prompt: context.prompt) else { return }
            if draftState.acceptSavedTemplate(created, ifUnchanged: context) {
                if saveTemplateName == name { saveTemplateName = "" }
                templateOperationMessage = "Template saved."
            } else {
                templateOperationMessage = "Template saved, but the newer draft was kept unchanged."
            }
        }
    }

    private func updateTemplate() {
        guard !isSavingTemplate, draftState.canUpdateSourceTemplate,
              let source = selectedSourceTemplate, !source.isBuiltIn else { return }
        let context = draftState.requestContext()
        isSavingTemplate = true
        clearTemplateFeedback()
        Task {
            defer { isSavingTemplate = false }
            guard let updated = await summaryTemplateController.update(
                id: source.id, name: source.name, prompt: context.prompt
            ) else { return }
            if draftState.acceptUpdatedSource(updated, ifUnchanged: context) {
                templateOperationMessage = "Template updated."
            } else {
                templateOperationMessage = "Template updated, but the newer draft was kept unchanged."
            }
        }
    }

    private func clearTemplateFeedback() {
        templateOperationMessage = nil
        summaryTemplateController.clearError()
    }

    private func initializeDefaultWhenAvailable() async {
        guard !summaryTemplateController.isLibraryRebinding else { return }
        if summaryTemplateController.templates.isEmpty {
            guard await summaryTemplateController.load() else { return }
        }
        initializePublishedDefaultIfAvailable()
    }

    private func initializePublishedDefaultIfAvailable() {
        guard !summaryTemplateController.isLibraryRebinding,
              !summaryTemplateController.templates.isEmpty else { return }
        draftState.initializeDefaultIfPristine(
            summaryTemplateController.defaultTemplateValue,
            model: selectedModel.isEmpty ? defaultModel : selectedModel
        )
        isPromptPreviewVisible = draftState.isInitialized
    }
}
