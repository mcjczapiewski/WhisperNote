import Foundation

// MARK: - Recording Model
struct Recording: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var duration: TimeInterval
    var filePath: URL
    var systemAudioFilePath: URL?
    var groupId: UUID?
    var groupName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, date, duration, filePath, systemAudioFilePath, groupId, groupName
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

// MARK: - LLM Models
struct LLMModel: Identifiable {
    let id: String       // OpenRouter model ID used as the stored value
    let displayName: String
}

let llmModels: [LLMModel] = [
    LLMModel(id: "deepseek/deepseek-v4-flash",    displayName: "DeepSeek v4 Flash — $0.089 / $0.224"),
    LLMModel(id: "openai/gpt-4o-mini",            displayName: "GPT-4o Mini — $0.15 / $0.60"),
    LLMModel(id: "google/gemini-3-flash-preview", displayName: "Gemini 3 Flash — $0.50 / $3"),
    LLMModel(id: "z-ai/glm-5.2",                  displayName: "GLM-5.2 — $0.95 / $3"),
    LLMModel(id: "x-ai/grok-4.3",                 displayName: "Grok 4.3 — $1.25 / $2.50"),
]

let defaultLLMModelId = "openai/gpt-4o-mini"

enum ArtifactPersistenceError: LocalizedError {
    case transcript(Error)
    case summary(Error)

    var errorDescription: String? {
        switch self {
        case .transcript(let error):
            return "The transcript could not be saved: \(error.localizedDescription)"
        case .summary(let error):
            return "The summary could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Builds a replacement array off to the side and publishes it only after the
/// caller's durable write succeeds. Shared by workflow transcript and summary
/// upserts so an in-memory completed artifact can never outrun its disk record.
struct ArtifactUpsertTransaction {
    static func commit<Element: Identifiable>(
        current: [Element],
        artifact: Element,
        persist: ([Element]) throws -> Void,
        publish: ([Element]) -> Void
    ) throws where Element.ID: Equatable {
        var candidate = current
        if let index = candidate.firstIndex(where: { $0.id == artifact.id }) {
            candidate[index] = artifact
        } else {
            candidate.append(artifact)
        }
        try persist(candidate)
        publish(candidate)
    }
}
