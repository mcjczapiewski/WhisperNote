import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var summaryManager = SummaryManager()

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingView()
                .environmentObject(audioRecorder)
                .environmentObject(transcriptionManager)
                .tabItem {
                    Label("Recording", systemImage: "mic")
                }
                .tag(0)

            TranscriptView()
                .environmentObject(transcriptionManager)
                .environmentObject(summaryManager)
                .tabItem {
                    Label("Transcripts", systemImage: "doc.text")
                }
                .tag(1)

            SummaryView()
                .environmentObject(summaryManager)
                .tabItem {
                    Label("Summaries", systemImage: "list.bullet.clipboard")
                }
                .tag(2)

            SettingsView()
                .environmentObject(transcriptionManager)
                .environmentObject(summaryManager)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .padding()
    }
}
