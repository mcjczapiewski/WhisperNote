import Foundation

// MARK: - Recording Model
struct Recording: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var duration: TimeInterval
    var filePath: URL
    var systemAudioFilePath: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, date, duration, filePath, systemAudioFilePath
    }
}

// MARK: - Transcript Model
struct Transcript: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var content: String
    var formattedContent: String?
    var recordingId: UUID
    var status: ProcessingStatus
    var jsonFilePath: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, date, content, formattedContent, recordingId, status, jsonFilePath
    }

    static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Summary Model
struct Summary: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var content: String
    var transcriptId: UUID
    var model: String
    var prompt: String
    var status: ProcessingStatus

    enum CodingKeys: String, CodingKey {
        case id, name, date, content, transcriptId, model, prompt, status
    }

    static func == (lhs: Summary, rhs: Summary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Processing Status
enum ProcessingStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}
