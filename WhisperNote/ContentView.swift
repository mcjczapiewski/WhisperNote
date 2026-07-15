import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var summaryManager: SummaryManager
    @EnvironmentObject private var workflowCoordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject private var navigationRouter: AppNavigationRouter
    @EnvironmentObject private var librarySearch: LibrarySearchController

    // ponytail: local mirror so NSTabView's write-back on tab click doesn't mutate
    // the router's @Published mid-view-update ("Publishing changes from within view
    // updates"). Router stays the source of truth via the two onChange syncs below.
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selectedTab) {
                RecordingView()
                    .environmentObject(audioRecorder)
                    .environmentObject(transcriptionManager)
                    .environmentObject(workflowCoordinator)
                    .environmentObject(navigationRouter)
                    .tabItem {
                        Label("Recording", systemImage: "mic")
                    }
                    .tag(0)

            TranscriptView()
                .environmentObject(transcriptionManager)
                .environmentObject(summaryManager)
                .environmentObject(navigationRouter)
                .tabItem {
                    Label("Transcripts", systemImage: "doc.text")
                }
                .tag(1)

            SummaryView()
                .environmentObject(summaryManager)
                .environmentObject(navigationRouter)
                .tabItem {
                    Label("Summaries", systemImage: "list.bullet.clipboard")
                }
                .tag(2)

            UnifiedSearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(3)

            SettingsView()
                .environmentObject(transcriptionManager)
                .environmentObject(summaryManager)
                .environmentObject(workflowCoordinator)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(4)
            }
            .disabled(librarySearch.isRebinding)
        }
        .padding()
        .onChange(of: selectedTab) { navigationRouter.selectedTab = $0 }
        .onChange(of: navigationRouter.selectedTab) { selectedTab = $0 }
        .onAppear {
            selectedTab = navigationRouter.selectedTab
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}
