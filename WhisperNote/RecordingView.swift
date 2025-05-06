import SwiftUI
import AVFoundation

struct RecordingView: View {
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @State private var recordingName = ""
    @State private var showingNamePrompt = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var recordingToDelete: Recording?

    var body: some View {
        VStack {
            Text("WhisperNote")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if let currentRecording = audioRecorder.currentRecording {
                Text("Recording: \(currentRecording.name)")
                    .font(.headline)
                    .padding(.bottom, 10)

                Text(formatDuration(audioRecorder.recordingDuration))
                    .font(.system(size: 48, weight: .medium, design: .monospaced))
                    .padding()

                HStack(spacing: 30) {
                    Button(action: {
                        if audioRecorder.isRecording {
                            audioRecorder.pauseRecording()
                        } else {
                            audioRecorder.resumeRecording()
                        }
                    }) {
                        Image(systemName: audioRecorder.isRecording ? "pause.circle.fill" : "play.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(audioRecorder.isRecording ? .orange : .green)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        audioRecorder.stopRecording()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "mic.circle")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.blue)

                    Text("Ready to Record")
                        .font(.title)

                    Text("Click the button below to start recording your meeting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button(action: {
                        showingNamePrompt = true
                    }) {
                        Text("Start Recording")
                            .font(.headline)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 20)
                }
                .padding()
            }

            Spacer()

            if !audioRecorder.recordings.isEmpty {
                Text("Recent Recordings")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading)

                List {
                    ForEach(audioRecorder.recordings) { recording in
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(.blue)

                            VStack(alignment: .leading) {
                                Text(recording.name)
                                    .font(.headline)

                                Text(recording.date, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button(action: {
                                recordingToDelete = recording
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.horizontal, 5)

                            Button(action: {
                                // Start transcription process
                                Task {
                                    do {
                                        // Create a local variable for this specific transcription task
                                        // This allows multiple transcription tasks to run concurrently
                                        let transcriptionTask = try await transcriptionManager.transcribeRecording(recording)
                                        print("Transcription completed: \(transcriptionTask.id)")
                                    } catch {
                                        alertMessage = error.localizedDescription
                                        showingAlert = true
                                    }
                                }
                            }) {
                                HStack {
                                    Text("Transcribe")
                                        .font(.caption)

                                    // Show a small indicator if any transcription is in progress for this recording
                                    if transcriptionManager.transcripts.contains(where: {
                                        $0.recordingId == recording.id && $0.status == .inProgress
                                    }) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .frame(width: 10, height: 10)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(5)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(
                                // Disable if there's a completed transcript for this recording
                                transcriptionManager.transcripts.contains(where: {
                                    $0.recordingId == recording.id && $0.status == .completed
                                }) ||
                                // Or if transcription is in progress
                                transcriptionManager.transcripts.contains(where: {
                                    $0.recordingId == recording.id && $0.status == .inProgress
                                })
                            )
                        }
                        .padding(.vertical, 5)
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("Recording Error"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showingNamePrompt) {
            VStack(spacing: 20) {
                Text("Name Your Recording")
                    .font(.headline)

                TextField("Recording Name", text: $recordingName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                HStack {
                    Button("Cancel") {
                        recordingName = ""
                        showingNamePrompt = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Start Recording") {
                        if !recordingName.isEmpty {
                            do {
                                try audioRecorder.startRecording(name: recordingName)
                                showingNamePrompt = false
                                recordingName = ""
                            } catch {
                                alertMessage = error.localizedDescription
                                showingAlert = true
                                showingNamePrompt = false
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordingName.isEmpty)
                }
                .padding()
            }
            .frame(width: 300, height: 200)
            .padding()
        }
        .alert("Delete Recording", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                recordingToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let recording = recordingToDelete {
                    // Delete the recording
                    audioRecorder.deleteRecording(id: recording.id)
                    recordingToDelete = nil
                }
            }
        } message: {
            if let recording = recordingToDelete {
                Text("Are you sure you want to delete the recording \"\(recording.name)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete this recording? This action cannot be undone.")
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
