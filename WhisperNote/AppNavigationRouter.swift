import SwiftUI

enum RecordingRouteRequest: Equatable {
    case recording(UUID)
    case group(UUID)
}

struct DocumentSearchRoute: Equatable {
    let itemID: UUID
    let text: String
    let matchIndex: Int
    let focusLocation: Int?

    init(itemID: UUID, text: String, matchIndex: Int, focusLocation: Int? = nil) {
        self.itemID = itemID
        self.text = text
        self.matchIndex = matchIndex
        self.focusLocation = focusLocation
    }
}

enum RecordingRouteResolution: Equatable {
    case recording(id: UUID, groupID: UUID?)
    case group(id: UUID, highlightedRecordingID: UUID)
    case missingRecording
    case missingGroup
}

enum RecordingRouteResolver {
    static func resolve(
        _ request: RecordingRouteRequest,
        recordings: [Recording]
    ) -> RecordingRouteResolution {
        switch request {
        case .recording(let id):
            guard let recording = recordings.first(where: { $0.id == id }) else {
                return .missingRecording
            }
            return .recording(id: id, groupID: recording.groupId)
        case .group(let id):
            guard let recording = recordings.first(where: { $0.groupId == id }) else {
                return .missingGroup
            }
            return .group(id: id, highlightedRecordingID: recording.id)
        }
    }
}

@MainActor
final class AppNavigationRouter: ObservableObject {
    @Published var selectedTab = 0
    @Published var transcriptID: UUID?
    @Published var summaryID: UUID?
    @Published var recordingID: UUID?
    @Published var recordingGroupID: UUID?
    @Published private(set) var transcriptSearchRoute: DocumentSearchRoute?
    @Published private(set) var summarySearchRoute: DocumentSearchRoute?
    @Published private(set) var recordingRouteRequestID = UUID()

    func openRecording(_ id: UUID) {
        recordingID = id
        recordingGroupID = nil
        recordingRouteRequestID = UUID()
        selectedTab = 0
    }

    func openRecordingGroup(_ id: UUID) {
        recordingGroupID = id
        recordingID = nil
        recordingRouteRequestID = UUID()
        selectedTab = 0
    }

    func openTranscript(
        _ id: UUID,
        searchText: String? = nil,
        matchIndex: Int = 0,
        focusLocation: Int? = nil
    ) {
        transcriptID = id
        transcriptSearchRoute = searchText.map {
            DocumentSearchRoute(itemID: id, text: $0, matchIndex: matchIndex, focusLocation: focusLocation)
        }
        selectedTab = 1
    }

    func openSummary(
        _ id: UUID,
        searchText: String? = nil,
        matchIndex: Int = 0,
        focusLocation: Int? = nil
    ) {
        summaryID = id
        summarySearchRoute = searchText.map {
            DocumentSearchRoute(itemID: id, text: $0, matchIndex: matchIndex, focusLocation: focusLocation)
        }
        selectedTab = 2
    }

    func openSettings() {
        selectedTab = 4
    }

    func consumeTranscriptRoute(_ id: UUID) {
        guard transcriptID == id else { return }
        transcriptID = nil
    }

    func consumeTranscriptSearchRoute(for id: UUID) -> DocumentSearchRoute? {
        guard transcriptSearchRoute?.itemID == id else { return nil }
        defer { transcriptSearchRoute = nil }
        return transcriptSearchRoute
    }

    func consumeSummaryRoute(_ id: UUID) {
        guard summaryID == id else { return }
        summaryID = nil
    }

    func consumeSummarySearchRoute(for id: UUID) -> DocumentSearchRoute? {
        guard summarySearchRoute?.itemID == id else { return nil }
        defer { summarySearchRoute = nil }
        return summarySearchRoute
    }

    func consumeRecordingRoute(_ id: UUID) {
        guard recordingID == id else { return }
        recordingID = nil
    }

    func consumeRecordingGroupRoute(_ id: UUID) {
        guard recordingGroupID == id else { return }
        recordingGroupID = nil
    }
}
