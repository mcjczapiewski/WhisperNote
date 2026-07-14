import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioRecorder: AudioRecorder
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var workflowCoordinator = PostRecordingWorkflowCoordinator()
    @StateObject private var navigationRouter = AppNavigationRouter()

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
            }
        }
        .padding()
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
        .task {
            guard !WhisperNoteRuntime.isUnitTestMode else { return }
            await workflowCoordinator.attach(
                transcriptionManager: transcriptionManager,
                summaryManager: summaryManager,
                recordings: { audioRecorder.recordings }
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await audioRecorder.checkAndRequestPermissions()
        }
    }
}
