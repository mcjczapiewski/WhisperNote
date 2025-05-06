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

    var body: some View {
        VStack {
            Text("Transcripts")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if transcriptionManager.transcripts.isEmpty {
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
            } else {
                HStack(spacing: 0) {
                    // Sidebar with transcript list
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

                    // Divider
                    Divider()

                    // Transcript content
                    if let selectedTranscript = selectedTranscript {
                        VStack {
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
                                    // Generate summary
                                    Task {
                                        do {
                                            _ = try await summaryManager.generateSummary(for: selectedTranscript)
                                        } catch {
                                            errorMessage = error.localizedDescription
                                            showingError = true
                                        }
                                    }
                                }) {
                                    Label("Generate Summary", systemImage: "list.bullet.clipboard")
                                }
                                .disabled(selectedTranscript.status != .completed ||
                                          summaryManager.summaries.contains(where: { $0.transcriptId == selectedTranscript.id }))

                                Button(action: {
                                    transcriptToDelete = selectedTranscript
                                    showingDeleteConfirmation = true
                                }) {
                                    Label("Delete", systemImage: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding()

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
                                ScrollView {
                                    Text(selectedTranscript.content)
                                        .padding()
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
                    } else {
                        Text("Select a transcript to view")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
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
            document: selectedTranscript != nil ? TextDocument(initialText: selectedTranscript!.content) : TextDocument(initialText: ""),
            contentType: .plainText,
            defaultFilename: selectedTranscript != nil ? "\(selectedTranscript!.name).txt" : "transcript.txt"
        ) { result in
            switch result {
            case .success(let url):
                print("Transcript successfully exported to \(url.path)")
            case .failure(let error):
                errorMessage = "Export failed: \(error.localizedDescription)"
                showingError = true
            }
        }
    }
}


