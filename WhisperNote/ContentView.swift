import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingView()
                .tabItem {
                    Label("Recording", systemImage: "mic")
                }
                .tag(0)
            
            TranscriptView()
                .tabItem {
                    Label("Transcripts", systemImage: "doc.text")
                }
                .tag(1)
            
            SummaryView()
                .tabItem {
                    Label("Summaries", systemImage: "list.bullet.clipboard")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .padding()
    }
}
