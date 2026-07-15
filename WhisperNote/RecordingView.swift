import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct RecordingView: View {
    private struct RoutedScrollRequest: Equatable {
        let id: UUID
        let target: String
    }
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var transcriptionManager: TranscriptionManager
    @EnvironmentObject var workflowCoordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject var navigationRouter: AppNavigationRouter
    @EnvironmentObject var commandCoordinator: RecordingCommandCoordinator
    @State private var recordingName = ""
    @State private var showingNamePrompt = false
    @State private var recordToResults = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var recordingToDelete: Recording?
    @State private var recordingIDsToDelete: Set<UUID> = []
    @State private var selectedRecordingIDs: Set<UUID> = []
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
    @State private var expandedGroups: Set<UUID> = []
    @State private var routedRecordingID: UUID?
    @State private var routedScrollRequest: RoutedScrollRequest?
    @State private var routedRequestID: UUID?

    enum TranscriptionLanguageCatalog {
        static let all: [(String, String)] = [
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
    }

    private let languages = TranscriptionLanguageCatalog.all

    var body: some View {
        VStack {
            Text("WhisperNote")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if !audioRecorder.recoverableSessions.isEmpty || !audioRecorder.corruptRecordingBundles.isEmpty {
                recoveryPanel
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }

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
                        Task {
                            if audioRecorder.isRecording {
                                await commandCoordinator.pause()
                            } else {
                                await commandCoordinator.resume()
                                if let error = commandCoordinator.lastError {
                                    alertMessage = "Couldn't resume recording: \(error)"
                                    showingAlert = true
                                }
                            }
                        }
                    }) {
                        Image(systemName: audioRecorder.isRecording ? "pause.circle.fill" : "play.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(audioRecorder.isRecording ? .orange : .green)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        Task {
                            _ = await commandCoordinator.stop()
                        }
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(audioRecorder.isStoppingRecording || commandCoordinator.isBusy)
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
                                    recordToResults = UserDefaults.standard.bool(forKey: "autoTranscribeAfterRecording")

                                    // Refresh available microphones before showing the popup
                                    // This ensures we get the current system default microphone
                                    Task {
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
                    .disabled(!audioRecorder.isInitialRecoveryComplete)

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

                ScrollViewReader { proxy in
                List(selection: $selectedRecordingIDs) {
                    let ungrouped = audioRecorder.recordings.filter { $0.groupId == nil }
                    let grouped = Dictionary(grouping: audioRecorder.recordings.filter { $0.groupId != nil },
                                             by: { $0.groupId! })

                    ForEach(Array(grouped.keys), id: \.self) { gid in
                        let members = grouped[gid] ?? []
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedGroups.contains(gid) },
                            set: { isExpanded in
                                if isExpanded { expandedGroups.insert(gid) }
                                else { expandedGroups.remove(gid) }
                            }
                        )) {
                            ForEach(members) { recording in
                                recordingRow(recording)
                                    .tag(recording.id)
                                    .id(routeID(forRecording: recording.id))
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

                                LibraryMetadataControls(itemKey: LibraryItemKey(kind: .group, id: gid))

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
                        .listRowBackground(recordingListRowBackground)
                        .id(routeID(forGroup: gid))
                    }

                    ForEach(ungrouped) { recording in
                        recordingRow(recording)
                            .tag(recording.id)
                            .listRowBackground(recordingListRowBackground)
                            .id(routeID(forRecording: recording.id))
                    }
                }
                .frame(height: 200)
                .scrollContentBackground(.hidden)
                .onChange(of: routedScrollRequest) { request in
                    guard let request else { return }
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(request.target, anchor: .center) }
                    }
                }
                }
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

                Toggle("Record to Results", isOn: $recordToResults)
                    .help("Transcribe this recording after it is saved, and create a summary if enabled in Settings.")

                // Microphone selection
                VStack(alignment: .leading) {
                    Text("Select Microphone:")
                        .fontWeight(.medium)

                    Picker("Microphone", selection: $selectedMicrophoneId) {
                        // Default option - system preferred microphone
                        Text("System Default").tag("")

                        // List all available microphones
                        ForEach(audioRecorder.availableMicrophones, id: \.id) { mic in
                            Text(mic.localizedName).tag(mic.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: .infinity)

                    if let selectedMic = audioRecorder.availableMicrophones.first(where: { $0.id == selectedMicrophoneId }) {
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
                        beginRecording()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        recordingName.isEmpty ||
                        audioRecorder.isStartingRecording ||
                        !audioRecorder.isInitialRecoveryComplete
                    )
                }
                .padding()
            }
            .frame(width: 400, height: 390)
            .padding()
        }
        .alert("Delete Recording", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                recordingToDelete = nil
                recordingIDsToDelete.removeAll()
            }
            Button("Delete", role: .destructive) {
                let ids = recordingIDsToDelete.isEmpty ? Set(recordingToDelete.map { [$0.id] } ?? []) : recordingIDsToDelete
                if !ids.isEmpty {
                    Task {
                        for id in ids { await audioRecorder.deleteRecording(id: id) }
                    }
                }
                selectedRecordingIDs.subtract(ids)
                recordingToDelete = nil
                recordingIDsToDelete.removeAll()
            }
        } message: {
            if recordingIDsToDelete.count > 1 {
                Text("Are you sure you want to delete \(recordingIDsToDelete.count) recordings? This action cannot be undone.")
            } else if let recording = recordingToDelete {
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
                    Task {
                        await audioRecorder.deleteGroup(groupId: gid)
                    }
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
        .onAppear { consumeRecordingRouteIfAvailable() }
        .onChange(of: navigationRouter.recordingRouteRequestID) { _ in consumeRecordingRouteIfAvailable() }
        .onChange(of: audioRecorder.recordings.map(\.id)) { _ in consumeRecordingRouteIfAvailable() }

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

                ProcessingStatusView(recordingID: recording.id, compact: true)
                    .environmentObject(workflowCoordinator)
                    .environmentObject(navigationRouter)
            }

            Spacer()

            LibraryMetadataControls(itemKey: LibraryItemKey(kind: .recording, id: recording.id))

            Button(action: {
                recordingToDelete = recording
                recordingIDsToDelete = selectedRecordingIDs.contains(recording.id) ? selectedRecordingIDs : [recording.id]
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
                recordingIDsToDelete = selectedRecordingIDs.contains(recording.id) ? selectedRecordingIDs : [recording.id]
                showingDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedRecordingIDs.contains(recording.id) || routedRecordingID == recording.id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private func consumeRecordingRouteIfAvailable() {
        let requestID = navigationRouter.recordingRouteRequestID
        if let id = navigationRouter.recordingID {
            switch RecordingRouteResolver.resolve(.recording(id), recordings: audioRecorder.recordings) {
            case .recording(_, let groupID):
                routedRecordingID = id
                routedRequestID = requestID
                if let groupID { expandedGroups.insert(groupID) }
                routedScrollRequest = .init(id: requestID, target: routeID(forRecording: id))
                scheduleHighlightClear(for: requestID)
            case .missingRecording:
                alertMessage = "The selected recording is no longer available in this library."
                showingAlert = true
            default: break
            }
            navigationRouter.consumeRecordingRoute(id)
        }
        if let groupID = navigationRouter.recordingGroupID {
            switch RecordingRouteResolver.resolve(.group(groupID), recordings: audioRecorder.recordings) {
            case .group(_, let highlightedRecordingID):
                expandedGroups.insert(groupID)
                routedRecordingID = highlightedRecordingID
                routedRequestID = requestID
                routedScrollRequest = .init(id: requestID, target: routeID(forGroup: groupID))
                scheduleHighlightClear(for: requestID)
            case .missingGroup:
                alertMessage = "The selected recording group is no longer available in this library."
                showingAlert = true
            default: break
            }
            navigationRouter.consumeRecordingGroupRoute(groupID)
        }
    }

    private func scheduleHighlightClear(for requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard routedRequestID == requestID else { return }
            routedRecordingID = nil
            routedRequestID = nil
        }
    }

    private func routeID(forRecording id: UUID) -> String { "recording-\(id.uuidString)" }
    private func routeID(forGroup id: UUID) -> String { "group-\(id.uuidString)" }

    private var recoveryPanel: some View {
        GroupBox("Interrupted Recordings") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(audioRecorder.recoverableSessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.manifest.displayName)
                            .font(.headline)
                        Text(session.statusDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            if !audioRecorder.recordings.contains(where: { $0.id == session.id }) {
                                Button("Recover") {
                                    Task { await audioRecorder.recoverSession(id: session.id) }
                                }
                            }
                            if session.inspection.canRetryMerge {
                                Button("Retry Merge") {
                                    Task { await audioRecorder.retryMergeSession(id: session.id) }
                                }
                            }
                            Button("Show in Finder") {
                                FinderHelper.showInFinder(session.bundleURL)
                            }
                            Button("Dismiss", role: .destructive) {
                                Task { await audioRecorder.dismissRecoverySession(id: session.id) }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioRecorder.isRecoveryActionInFlight(id: session.id))
                    }

                    if session.id != audioRecorder.recoverableSessions.last?.id {
                        Divider()
                    }
                }

                if !audioRecorder.recoverableSessions.isEmpty,
                   !audioRecorder.corruptRecordingBundles.isEmpty {
                    Divider()
                }

                ForEach(audioRecorder.corruptRecordingBundles) { bundle in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bundle.bundleURL.lastPathComponent)
                            .font(.headline)
                        Text("The recovery manifest is damaged or unsafe. Known audio files can be repaired when the folder has a trustworthy session ID.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Recover Known Files") {
                                Task { await audioRecorder.recoverCorruptBundle(bundle) }
                            }
                            Button("Show in Finder") {
                                FinderHelper.showInFinder(bundle.bundleURL)
                            }
                            Button("Dismiss", role: .destructive) {
                                audioRecorder.dismissCorruptBundle(bundle)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioRecorder.isCorruptRecoveryActionInFlight(id: bundle.id))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func beginRecording() {
        let name = recordingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if SystemAudioCapture.isBluetoothHeadphonesConnected() {
            audioWarningMessage = "Bluetooth headphones detected. Audio quality may be affected.\n\nAvailable audio devices: \(SystemAudioCapture.getAvailableAudioDevices().joined(separator: ", "))"
            showingAudioWarning = true
        }

        Task {
            do {
                let outcome = try await commandCoordinator.start(
                    name: name,
                    microphoneId: selectedMicrophoneId,
                    recordToResults: recordToResults
                )
                switch outcome {
                case .started:
                    recordingName = ""
                    showingNamePrompt = false
                case .alreadyActive:
                    alertMessage = "A recording is already starting or in progress."
                    showingAlert = true
                }
            } catch {
                presentRecordingStartError(error)
                showingNamePrompt = false
            }
        }
    }

    private func presentRecordingStartError(_ error: Error) {
        if let recorderError = error as? AudioRecorderError, recorderError == .permissionDenied {
            alertMessage = """
            Permission error

            Current permission status:
            Microphone: \(audioRecorder.hasMicrophonePermission() ? "✓ Granted" : "❌ Missing")
            System Audio: \(audioRecorder.hasSystemAudioPermission() ? "✓ Granted" : "❌ Missing")

            Please enable all permissions in System Settings > Privacy & Security, then restart the app.
            """
        } else {
            alertMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
        showingAlert = true
    }

    private var recordingListRowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.10))
            .padding(.vertical, 2)
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
