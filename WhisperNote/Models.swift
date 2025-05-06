import Foundation

// MARK: - Recording Model
struct Recording: Identifiable, Codable {
    var id = UUID()
    var name: String
    var date: Date
    var duration: TimeInterval
    var filePath: URL
    
    enum CodingKeys: String, CodingKey {
        case id, name, date, duration, filePath
    }
}

// MARK: - Transcript Model
struct Transcript: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var date: Date
    var content: String
    var recordingId: UUID
    var status: ProcessingStatus
    
    enum CodingKeys: String, CodingKey {
        case id, name, date, content, recordingId, status
    }
    
    static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Summary Model
struct Summary: Identifiable, Codable, Hashable {
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
enum ProcessingStatus: String, Codable {
    case pending
    case inProgress
    case completed
    case failed
}
