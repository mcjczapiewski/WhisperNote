import SwiftUI
import AVFoundation
import RecordKit
import UniformTypeIdentifiers

struct RecordingView: View {
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @State private var recordingName = ""
    @State private var showingNamePrompt = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var recordingToDelete: Recording?
    @State private var showingLanguageSelector = false
    @State private var recordingToTranscribe: Recording?
    @State private var groupToTranscribe: UUID?
    @State private var groupToDelete: UUID?
    @State private var showingGroupDeleteConfirmation = false
    @AppStorage("lastTranscriptionLanguage") private var selectedLanguage = "eng"
    @State private var showingAudioWarning = false
    @State private var audioWarningMessage = ""
    @State private var selectedMicrophoneId: String = ""
    @State private var showingImporter = false
    @State private var showingImportNamePrompt = false
    @State private var pendingImportURL: URL?
    @State private var importRecordingName = ""

    private let languages = [
        ("afr", "Afrikaans"),
        ("amh", "Amharic"),
        ("ara", "Arabic"),
        ("hye", "Armenian"),
        ("asm", "Assamese"),
        ("ast", "Asturian"),
        ("aze", "Azerbaijani"),
        ("bel", "Belarusian"),
        ("ben", "Bengali"),
        ("bos", "Bosnian"),
        ("bul", "Bulgarian"),
        ("mya", "Burmese"),
        ("yue", "Cantonese"),
        ("cat", "Catalan"),
        ("ceb", "Cebuano"),
        ("nya", "Chichewa"),
        ("hrv", "Croatian"),
        ("ces", "Czech"),
        ("dan", "Danish"),
        ("nld", "Dutch"),
        ("eng", "English"),
        ("est", "Estonian"),
        ("fil", "Filipino"),
        ("fin", "Finnish"),
        ("fra", "French"),
        ("ful", "Fulah"),
        ("glg", "Galician"),
        ("lug", "Ganda"),
        ("kat", "Georgian"),
        ("deu", "German"),
        ("ell", "Greek"),
        ("guj", "Gujarati"),
        ("hau", "Hausa"),
        ("heb", "Hebrew"),
        ("hin", "Hindi"),
        ("hun", "Hungarian"),
        ("isl", "Icelandic"),
        ("ibo", "Igbo"),
        ("ind", "Indonesian"),
        ("gle", "Irish"),
        ("ita", "Italian"),
        ("jpn", "Japanese"),
        ("jav", "Javanese"),
        ("kea", "Kabuverdianu"),
        ("kan", "Kannada"),
        ("kaz", "Kazakh"),
        ("khm", "Khmer"),
        ("kor", "Korean"),
        ("kur", "Kurdish"),
        ("kir", "Kyrgyz"),
        ("lao", "Lao"),
        ("lav", "Latvian"),
        ("lin", "Lingala"),
        ("lit", "Lithuanian"),
        ("luo", "Luo"),
        ("ltz", "Luxembourgish"),
        ("mkd", "Macedonian"),
        ("msa", "Malay"),
        ("mal", "Malayalam"),
        ("mlt", "Maltese"),
        ("cmn", "Mandarin Chinese"),
        ("mri", "Māori"),
        ("mar", "Marathi"),
        ("mon", "Mongolian"),
        ("nep", "Nepali"),
        ("nso", "Northern Sotho"),
        ("nor", "Norwegian"),
        ("oci", "Occitan"),
        ("ori", "Odia"),
        ("pus", "Pashto"),
        ("fas", "Persian"),
        ("pol", "Polish"),
        ("por", "Portuguese"),
        ("pan", "Punjabi"),
        ("ron", "Romanian"),
        ("rus", "Russian"),
        ("srp", "Serbian"),
        ("sna", "Shona"),
        ("snd", "Sindhi"),
        ("slk", "Slovak"),
        ("slv", "Slovenian"),
        ("som", "Somali"),
        ("spa", "Spanish"),
        ("swa", "Swahili"),
        ("swe", "Swedish"),
        ("tam", "Tamil"),
        ("tgk", "Tajik"),
        ("tel", "Telugu"),
        ("tha", "Thai"),
        ("tur", "Turkish"),
        ("ukr", "Ukrainian"),
        ("umb", "Umbundu"),
        ("urd", "Urdu"),
        ("uzb", "Uzbek"),
        ("vie", "Vietnamese"),
        ("cym", "Welsh"),
        ("wol", "Wolof"),
        ("xho", "Xhosa"),
        ("zul", "Zulu")
    ]

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

                AudioLevelMeter(level: audioRecorder.audioLevel, isActive: audioRecorder.isRecording)
                    .padding(.bottom, 12)

                // Mute microphone button
                Button(action: {
                    audioRecorder.toggleMicrophoneMute()
                }) {
                    Image(systemName: audioRecorder.isMicrophoneMuted ? "mic.slash.circle.fill" : "mic.circle.fill")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundColor(audioRecorder.isMicrophoneMuted ? .red : .blue)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, 10)
                .help(audioRecorder.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone")

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
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 100, height: 100)

                    Text("Ready to Record")
                        .font(.title)

                    Text("Click the button below to start recording your meeting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Check for Bluetooth headphones
                    if SystemAudioCapture.isBluetoothHeadphonesConnected() {
                        VStack(spacing: 10) {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)

                                Text("Bluetooth headphones detected")
                                    .font(.caption)
                                    .foregroundColor(.blue)

                                Button(action: {
                                    audioWarningMessage = "When using Bluetooth headphones, audio quality may be affected.\n\nAvailable audio devices: \(SystemAudioCapture.getAvailableAudioDevices().joined(separator: ", "))"
                                    showingAudioWarning = true
                                }) {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 5)
                    }

                    Button(action: {
                        // First check permissions before showing the name prompt
                        Task {
                            // Check all permissions
                            let hasMicPermission = audioRecorder.hasMicrophonePermission()
                            let hasSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                            print("Current permissions - Mic: \(hasMicPermission), System Audio: \(hasSystemAudioPermission)")

                            // If we don't have all required permissions, show a message first
                            if !hasMicPermission || !hasSystemAudioPermission {
                                await MainActor.run {
                                    audioWarningMessage = """
                                    WhisperNote needs the following permissions:

                                    Microphone: \(hasMicPermission ? "✓ Granted" : "❌ Missing")
                                    System Audio: \(hasSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                    When prompted, please click "Open System Settings" and enable WhisperNote in the list.
                                    You may need to restart the app after granting permissions.
                                    """
                                    showingAudioWarning = true
                                }
                            }

                            // Now check and request all permissions
                            let permissionsGranted = await audioRecorder.checkAndRequestPermissions()

                            // Check permissions again after the request
                            let updatedMicPermission = audioRecorder.hasMicrophonePermission()
                            let updatedSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                            print("Updated permissions - Mic: \(updatedMicPermission), System Audio: \(updatedSystemAudioPermission)")

                            // Update UI on main thread
                            await MainActor.run {
                                if permissionsGranted {
                                    // Even if microphone permission is granted, warn about other missing permissions
                                    if !updatedSystemAudioPermission {
                                        audioWarningMessage = """
                                        Some permissions are still missing:

                                        Microphone: \(updatedMicPermission ? "✓ Granted" : "❌ Missing")
                                        System Audio: \(updatedSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                        You can proceed with recording, but some features may not work properly.
                                        To fix this, grant System Audio Recording in System Settings > Privacy & Security, then quit and reopen WhisperNote — the permission only takes effect after a restart.
                                        """
                                        showingAudioWarning = true
                                    }

                                    // Reset selected microphone to default (system preferred)
                                    selectedMicrophoneId = ""

                                    // Refresh available microphones before showing the popup
                                    // This ensures we get the current system default microphone
                                    Task {
                                        // Note: refreshPreferred method doesn't exist in this version of RecordKit
                                        // We'll just use the current preferred microphone

                                        // Just load available microphones without full permission check
                                        await audioRecorder.loadAvailableMicrophones()

                                        // Update UI on main thread
                                        await MainActor.run {
                                            showingNamePrompt = true
                                        }
                                    }
                                } else {
                                    // Show detailed permission error
                                    alertMessage = """
                                    Permission error. Current status:

                                    Microphone: \(updatedMicPermission ? "✓ Granted" : "❌ Missing")
                                    System Audio: \(updatedSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                    Please enable all permissions in System Settings > Privacy & Security, then restart the app.
                                    """
                                    showingAlert = true
                                }
                            }
                        }
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

                    Button(action: { showingImporter = true }) {
                        Label("Import Audio File(s)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
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
                    let ungrouped = audioRecorder.recordings.filter { $0.groupId == nil }
                    let grouped = Dictionary(grouping: audioRecorder.recordings.filter { $0.groupId != nil },
                                             by: { $0.groupId! })

                    ForEach(Array(grouped.keys), id: \.self) { gid in
                        let members = grouped[gid] ?? []
                        DisclosureGroup {
                            ForEach(members) { recording in
                                recordingRow(recording)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)

                                VStack(alignment: .leading) {
                                    Text(members.first?.groupName ?? "Imported batch")
                                        .font(.headline)
                                    Text("\(members.count) files")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    groupToDelete = gid
                                    showingGroupDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.horizontal, 5)

                                Button(action: {
                                    recordingToTranscribe = nil
                                    groupToTranscribe = gid
                                    showingLanguageSelector = true
                                }) {
                                    HStack {
                                        Text("Transcribe")
                                            .font(.caption)

                                        if transcriptionManager.transcripts.contains(where: {
                                            $0.recordingId == gid && $0.status == .inProgress
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
                                    transcriptionManager.transcripts.contains(where: {
                                        $0.recordingId == gid && ($0.status == .completed || $0.status == .inProgress)
                                    })
                                )
                            }
                        }
                    }

                    ForEach(ungrouped) { recording in
                        recordingRow(recording)
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .onAppear {
            // Safely initialize audio-related components when the view appears
            Task {
                // Just load available microphones without full permission check
                await audioRecorder.loadAvailableMicrophones()
            }
        }
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("Recording Error"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Audio System Information", isPresented: $showingAudioWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(audioWarningMessage)
        }
        .sheet(isPresented: $showingNamePrompt) {
            VStack(spacing: 20) {
                Text("Name Your Recording")
                    .font(.headline)

                TextField("Recording Name", text: $recordingName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                // Microphone selection
                VStack(alignment: .leading) {
                    Text("Select Microphone:")
                        .fontWeight(.medium)

                    Picker("Microphone", selection: $selectedMicrophoneId) {
                        // Default option - system preferred microphone
                        Text("System Default").tag("")

                        // List all available microphones
                        ForEach(audioRecorder.rkAvailableMicrophones, id: \.id) { mic in
                            Text(mic.localizedName).tag(mic.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)

                    if let selectedMic = audioRecorder.rkAvailableMicrophones.first(where: { $0.id == selectedMicrophoneId }) {
                        Text("Selected: \(selectedMic.localizedName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedMicrophoneId.isEmpty {
                        Text("Selected: System Default")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Button("Cancel") {
                        recordingName = ""
                        showingNamePrompt = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Start Recording") {
                        if !recordingName.isEmpty {
                            // Check if Bluetooth headphones are connected and warn the user
                            if SystemAudioCapture.isBluetoothHeadphonesConnected() {
                                // We'll still proceed, but show a warning first
                                audioWarningMessage = "Bluetooth headphones detected. Audio quality may be affected.\n\nAvailable audio devices: \(SystemAudioCapture.getAvailableAudioDevices().joined(separator: ", "))"
                                showingAudioWarning = true

                                // Proceed with recording
                                do {
                                    try audioRecorder.startRecording(name: recordingName, microphoneId: selectedMicrophoneId)
                                    showingNamePrompt = false
                                    recordingName = ""
                                } catch let error as AudioRecorderError {
                                    // Handle our custom error types
                                    switch error {
                                    case .permissionDenied:
                                        // Check all permissions again
                                        let hasMicPermission = audioRecorder.hasMicrophonePermission()
                                        let hasSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                                        alertMessage = """
                                        Permission error

                                        Current permission status:
                                        Microphone: \(hasMicPermission ? "✓ Granted" : "❌ Missing")
                                        System Audio: \(hasSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                        Please enable all permissions in System Settings > Privacy & Security, then restart the app.
                                        """
                                    case .directoryError:
                                        alertMessage = "There was an issue with the recording directory. Please try again with a different recording name."
                                    case .recordingFailed:
                                        alertMessage = "Failed to start recording. Please check your audio setup and try again."
                                    default:
                                        alertMessage = error.localizedDescription
                                    }
                                    showingAlert = true
                                    showingNamePrompt = false
                                } catch {
                                    // Handle other errors with more detailed information
                                    print("Recording error: \(error.localizedDescription)")

                                    // Check permissions to provide more context
                                    let hasMicPermission = audioRecorder.hasMicrophonePermission()
                                    let hasSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                                    alertMessage = """
                                    Recording error: \(error.localizedDescription)

                                    Current permission status:
                                    Microphone: \(hasMicPermission ? "✓ Granted" : "❌ Missing")
                                    System Audio: \(hasSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                    Please check your system settings and try again.
                                    """
                                    showingAlert = true
                                    showingNamePrompt = false
                                }
                            } else {
                                // No Bluetooth headphones, proceed normally
                                do {
                                    try audioRecorder.startRecording(name: recordingName, microphoneId: selectedMicrophoneId)
                                    showingNamePrompt = false
                                    recordingName = ""
                                } catch let error as AudioRecorderError {
                                    // Handle our custom error types
                                    switch error {
                                    case .permissionDenied:
                                        // Check all permissions again
                                        let hasMicPermission = audioRecorder.hasMicrophonePermission()
                                        let hasSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                                        alertMessage = """
                                        Permission error

                                        Current permission status:
                                        Microphone: \(hasMicPermission ? "✓ Granted" : "❌ Missing")
                                        System Audio: \(hasSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                        Please enable all permissions in System Settings > Privacy & Security, then restart the app.
                                        """
                                    case .directoryError:
                                        alertMessage = "There was an issue with the recording directory. Please try again with a different recording name."
                                    case .recordingFailed:
                                        alertMessage = "Failed to start recording. Please check your audio setup and try again."
                                    default:
                                        alertMessage = error.localizedDescription
                                    }
                                    showingAlert = true
                                    showingNamePrompt = false
                                } catch {
                                    // Handle other errors with more detailed information
                                    print("Recording error: \(error.localizedDescription)")

                                    // Check permissions to provide more context
                                    let hasMicPermission = audioRecorder.hasMicrophonePermission()
                                    let hasSystemAudioPermission = audioRecorder.hasSystemAudioPermission()

                                    alertMessage = """
                                    Recording error: \(error.localizedDescription)

                                    Current permission status:
                                    Microphone: \(hasMicPermission ? "✓ Granted" : "❌ Missing")
                                    System Audio: \(hasSystemAudioPermission ? "✓ Granted" : "❌ Missing")

                                    Please check your system settings and try again.
                                    """
                                    showingAlert = true
                                    showingNamePrompt = false
                                }
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordingName.isEmpty)
                }
                .padding()
            }
            .frame(width: 400, height: 350)
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
        .sheet(isPresented: $showingLanguageSelector) {
            VStack(spacing: 20) {
                Text("Select Transcription Language")
                    .font(.headline)

                VStack(alignment: .leading) {
                    Text("Select a language:")
                        .fontWeight(.medium)

                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(languages, id: \.0) { language in
                            Text(language.1).tag(language.0)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)

                    Text("Current: \(languages.first(where: { $0.0 == selectedLanguage })?.1 ?? "English")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()

                HStack {
                    Button("Cancel") {
                        recordingToTranscribe = nil
                        groupToTranscribe = nil
                        showingLanguageSelector = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Start Transcription") {
                        let language = selectedLanguage
                        if let gid = groupToTranscribe {
                            let members = audioRecorder.recordings.filter { $0.groupId == gid }
                            let groupName = members.first?.groupName ?? "Imported batch"
                            groupToTranscribe = nil
                            showingLanguageSelector = false
                            Task {
                                do {
                                    let transcriptionTask = try await transcriptionManager.transcribeGroup(members, groupId: gid, groupName: groupName, language: language)
                                    print("Group transcription completed: \(transcriptionTask.id)")
                                } catch {
                                    alertMessage = error.localizedDescription
                                    showingAlert = true
                                }
                            }
                        } else if let recording = recordingToTranscribe {
                            recordingToTranscribe = nil
                            showingLanguageSelector = false

                            // Start transcription process with selected language
                            Task {
                                do {
                                    // Create a local variable for this specific transcription task
                                    // This allows multiple transcription tasks to run concurrently
                                    let transcriptionTask = try await transcriptionManager.transcribeRecording(recording, language: language)
                                    print("Transcription completed: \(transcriptionTask.id)")
                                } catch {
                                    alertMessage = error.localizedDescription
                                    showingAlert = true
                                }
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 450, height: 220)
            .padding()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if urls.count == 1, let url = urls.first {
                    pendingImportURL = url
                    importRecordingName = url.deletingPathExtension().lastPathComponent
                    showingImportNamePrompt = true
                } else {
                    audioRecorder.importRecordings(from: urls)
                }
            case .failure(let error):
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
        .sheet(isPresented: $showingImportNamePrompt) {
            VStack(spacing: 20) {
                Text("Name Imported Recording")
                    .font(.headline)

                TextField("Recording Name", text: $importRecordingName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                HStack {
                    Button("Cancel") {
                        pendingImportURL = nil
                        importRecordingName = ""
                        showingImportNamePrompt = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Import") {
                        if let url = pendingImportURL {
                            audioRecorder.importRecording(from: url, named: importRecordingName)
                        }
                        pendingImportURL = nil
                        importRecordingName = ""
                        showingImportNamePrompt = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importRecordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(width: 400, height: 180)
            .padding()
        }
        .alert("Delete Group", isPresented: $showingGroupDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                groupToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let gid = groupToDelete {
                    audioRecorder.deleteGroup(groupId: gid)
                    groupToDelete = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete this imported group and all its files? This action cannot be undone.")
        }
        .onChange(of: audioRecorder.lastError) { error in
            if let error {
                alertMessage = error
                showingAlert = true
                audioRecorder.lastError = nil
            }
        }

    }

    @ViewBuilder
    private func recordingRow(_ recording: Recording) -> some View {
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
                // Show language selector before starting transcription
                groupToTranscribe = nil
                recordingToTranscribe = recording
                showingLanguageSelector = true
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
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {
                FinderHelper.showInFinder(recording.filePath)
            }) {
                Label("Show in Finder", systemImage: "folder")
            }

            Button(action: {
                recordingToDelete = recording
                showingDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
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

private struct AudioLevelMeter: View {
    let level: Double
    let isActive: Bool

    private var displayLevel: Double {
        isActive ? max(level, 0.03) : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundColor(isActive ? .green : .secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.16))

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.green, .yellow, .orange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * CGFloat(displayLevel))
                    }
                }
                .frame(width: 180, height: 10)

                Text(isActive ? "Input live" : "Input paused")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 75, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.08), value: displayLevel)
    }
}
