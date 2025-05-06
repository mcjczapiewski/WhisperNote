import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @EnvironmentObject var summaryManager: SummaryManager
    @State private var selectedTranscript: Transcript?
    @State private var isTranscribing = false
    @State private var showingError = false
    @State private var errorMessage = ""

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
                    List(transcriptionManager.transcripts, selection: $selectedTranscript) { transcript in
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
                                    // Export transcript
                                }) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }

                                Button(action: {
                                    // Generate summary
                                    if let transcript = selectedTranscript {
                                        Task {
                                            do {
                                                _ = try await summaryManager.generateSummary(for: transcript)
                                            } catch {
                                                errorMessage = error.localizedDescription
                                                showingError = true
                                            }
                                        }
                                    }
                                }) {
                                    Label("Generate Summary", systemImage: "list.bullet.clipboard")
                                }
                                .disabled(selectedTranscript?.status != .completed ||
                                          summaryManager.summaries.contains(where: { $0.transcriptId == selectedTranscript?.id }))
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
                                        if let transcript = selectedTranscript {
                                            Task {
                                                do {
                                                    isTranscribing = true
                                                    // Find the original recording
                                                    let audioRecorder = AudioRecorder()
                                                    let recordings = audioRecorder.recordings
                                                    if let recording = recordings.first(where: { $0.id == transcript.recordingId }) {
                                                        // Remove the failed transcript
                                                        transcriptionManager.transcripts.removeAll(where: { $0.id == transcript.id })

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
    }
}
