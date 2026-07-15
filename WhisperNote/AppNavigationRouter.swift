import SwiftUI

enum RecordingRouteRequest: Equatable {
    case recording(UUID)
    case group(UUID)
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

    func openTranscript(_ id: UUID) {
        transcriptID = id
        selectedTab = 1
    }

    func openSummary(_ id: UUID) {
        summaryID = id
        selectedTab = 2
    }

    func openSettings() {
        selectedTab = 4
    }

    func consumeTranscriptRoute(_ id: UUID) {
        guard transcriptID == id else { return }
        transcriptID = nil
    }

    func consumeSummaryRoute(_ id: UUID) {
        guard summaryID == id else { return }
        summaryID = nil
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
