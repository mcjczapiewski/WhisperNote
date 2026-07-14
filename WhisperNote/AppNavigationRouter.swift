import SwiftUI

@MainActor
final class AppNavigationRouter: ObservableObject {
    @Published var selectedTab = 0
    @Published var transcriptID: UUID?
    @Published var summaryID: UUID?

    func openTranscript(_ id: UUID) {
        transcriptID = id
        selectedTab = 1
    }

    func openSummary(_ id: UUID) {
        summaryID = id
        selectedTab = 2
    }

    func openSettings() {
        selectedTab = 3
    }

    func consumeTranscriptRoute(_ id: UUID) {
        guard transcriptID == id else { return }
        transcriptID = nil
    }

    func consumeSummaryRoute(_ id: UUID) {
        guard summaryID == id else { return }
        summaryID = nil
    }
}
