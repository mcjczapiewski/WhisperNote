import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var summaryManager: SummaryManager
    @EnvironmentObject private var workflowCoordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject private var navigationRouter: AppNavigationRouter
    @EnvironmentObject private var librarySearch: LibrarySearchController

    var body: some View {
        VStack(spacing: 8) {
            ProcessingStatusView()
                .environmentObject(workflowCoordinator)
                .environmentObject(navigationRouter)
                .padding(.horizontal)

            TabView(selection: $navigationRouter.selectedTab) {
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

            SettingsView()
                .environmentObject(transcriptionManager)
                .environmentObject(summaryManager)
                .environmentObject(workflowCoordinator)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)

            UnifiedSearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(4)
            }
            .disabled(librarySearch.isRebinding)
        }
        .padding()
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}
