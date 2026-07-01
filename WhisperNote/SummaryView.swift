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
                .contextMenu {
                    Button(action: {
                        FinderHelper.showInFinder(summaryFinderURL())
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                    }

                    Button(action: {
                        summaryToDelete = summary
                        showingDeleteConfirmation = true
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .background(selectedSummary?.id == summary.id ? Color.blue.opacity(0.1) : Color.clear)
            }
        }
        .frame(width: 250)
        .listStyle(SidebarListStyle())
    }

    private func summaryFinderURL() -> URL {
        DirectoryManager.shared.getSummariesDirectory().appendingPathComponent("summaries.json")
    }
}

private enum SummaryPrintMarginPreset: String, CaseIterable, Identifiable {
    case narrow
    case normal
    case wide
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .narrow:
            return "Narrow"
        case .normal:
            return "Normal"
        case .wide:
            return "Wide"
        case .custom:
            return "Custom"
        }
    }

    var description: String {
        switch self {
        case .narrow:
            return "0.5 cm"
        case .normal:
            return "1.5 cm"
        case .wide:
            return "2.5 cm"
        case .custom:
            return "Custom value"
        }
    }

    func marginCentimeters(customValue: Double) -> Double {
        switch self {
        case .narrow:
            return 0.5
        case .normal:
            return 1.5
        case .wide:
            return 2.5
        case .custom:
            return max(0, customValue)
        }
    }
}

private struct SummaryPrintOptionsView: View {
    @Binding var presetRawValue: String
    @Binding var customMarginCentimeters: Double
    let onCancel: () -> Void
    let onPrint: () -> Void

    private var selectedPreset: SummaryPrintMarginPreset {
        SummaryPrintMarginPreset(rawValue: presetRawValue) ?? .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDF / Print Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Margins")
                    .fontWeight(.medium)

                Picker("Margin", selection: $presetRawValue) {
                    ForEach(SummaryPrintMarginPreset.allCases) { preset in
                        Text("\(preset.displayName) (\(preset.description))").tag(preset.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if selectedPreset == .custom {
                HStack {
                    Text("Custom margin")

                    TextField("Margin", value: $customMarginCentimeters, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Text("cm")
                        .foregroundColor(.secondary)
                }
            }

            Text("The selected margin is applied before the macOS print dialog opens. Use Save as PDF in that dialog to export a PDF.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    onPrint()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
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
    @State private var showingRetryError = false
    @State private var retryError = ""
    @State private var showingPrintOptions = false
    @AppStorage("summaryPrintMarginPreset") private var printMarginPresetRawValue = SummaryPrintMarginPreset.normal.rawValue
    @AppStorage("summaryPrintCustomMarginCentimeters") private var customPrintMarginCentimeters = 1.5

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
                    showingPrintOptions = true
                }) {
                    Label("Print / PDF", systemImage: "printer")
                }
                .disabled(selectedSummary.status != .completed)

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
                        Task {
                            do {
                                let id = selectedSummary.id
                                let tm = TranscriptionManager()
                                guard let transcript = tm.transcripts.first(where: { $0.id == selectedSummary.transcriptId }) else {
                                    throw NSError(domain: "SummaryView", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "Original transcript not found"])
                                }
                                let updated = try await summaryManager.retryGenerateSummary(id: id, transcript: transcript)
                                selectedSummaryBinding = updated
                            } catch {
                                retryError = error.localizedDescription
                                showingRetryError = true
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Retry Failed", isPresented: $showingRetryError) {
                    Button("OK") { }
                } message: {
                    Text(retryError)
                }
            }
        }
        .sheet(isPresented: $showingPrintOptions) {
            SummaryPrintOptionsView(
                presetRawValue: $printMarginPresetRawValue,
                customMarginCentimeters: $customPrintMarginCentimeters,
                onCancel: {
                    showingPrintOptions = false
                },
                onPrint: {
                    let preset = SummaryPrintMarginPreset(rawValue: printMarginPresetRawValue) ?? .normal
                    let marginCentimeters = preset.marginCentimeters(customValue: customPrintMarginCentimeters)
                    showingPrintOptions = false
                    printSummary(selectedSummary, marginCentimeters: marginCentimeters)
                }
            )
        }
    }

    private func printSummary(_ summary: Summary, marginCentimeters: Double) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(MarkdownTextRenderer.attributedText(from: summary.content))

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let marginPoints = marginCentimeters / 2.54 * 72
        printInfo.topMargin = marginPoints
        printInfo.bottomMargin = marginPoints
        printInfo.leftMargin = marginPoints
        printInfo.rightMargin = marginPoints
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        NSPrintOperation(view: textView, printInfo: printInfo).run()
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
    @State private var selectedModel: String = defaultLLMModelId
    @State private var isEnhancingPrompt = false

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
                    ForEach(llmModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
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
                .disabled(isEnhancingPrompt || customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
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
                .disabled(isEnhancingPrompt || customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
        .padding()
        .onAppear {
            // Initialize with the default model or the model from the selected summary
            if let summary = selectedSummary {
                // Only update if the model is valid (not empty)
                if !summary.model.isEmpty {
                    selectedModel = summary.model
                } else {
                    // Fallback to default model if summary model is empty
                    selectedModel = summaryManager.defaultModel
                }
                customPrompt = summary.prompt
            } else {
                // Make sure we have a valid model selection
                selectedModel = summaryManager.defaultModel
                customPrompt = summaryManager.getDefaultPrompt()
            }

            if selectedModel.isEmpty {
                selectedModel = defaultLLMModelId
            }
        }
    }

    private func enhancePrompt() {
        let promptToEnhance = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptToEnhance.isEmpty else { return }

        isEnhancingPrompt = true
        Task {
            do {
                customPrompt = try await summaryManager.enhancePrompt(promptToEnhance, model: selectedModel)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isEnhancingPrompt = false
        }
    }
}

extension SummaryView {
    // Helper method to create the export document
    private func createExportDocument() -> TextDocument {
        if let summary = selectedSummary {
            let text = exportFormat == TextDocument.markdownUTType
                ? summary.content
                : MarkdownTextRenderer.plainText(from: summary.content)
            return TextDocument(initialText: text, contentType: exportFormat)
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
