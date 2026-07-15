import Foundation

struct SummaryTemplate: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var presetID: String?
    var name: String
    var prompt: String
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        presetID: String? = nil,
        name: String,
        prompt: String,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.presetID = presetID
        self.name = name
        self.prompt = prompt
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }

    /// Any preset row is immutable. Unknown preset identities may belong to a newer
    /// app version and must remain forward-compatible instead of becoming editable.
    var isBuiltIn: Bool { presetID != nil }

    var isRecognizedPreset: Bool {
        presetID.map(SummaryTemplatePresetCatalog.isRecognized) ?? false
    }

    /// Durable selection value used by later UI/workflow integration. Built-ins keep
    /// their shipped string identity while custom rows use their stable UUID.
    var stableSelectionID: String {
        presetID ?? id.uuidString.lowercased()
    }

    /// Accepts both the current stable selection value and the UUID alias. The UUID
    /// alias keeps early local builds compatible without changing shipped preset IDs.
    func matchesSelectionID(_ selectionID: String) -> Bool {
        selectionID == presetID || selectionID.caseInsensitiveCompare(id.uuidString) == .orderedSame
    }
}

struct SummaryTemplateEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var templates: [SummaryTemplate]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        templates: [SummaryTemplate] = []
    ) {
        self.schemaVersion = schemaVersion
        self.templates = templates
    }
}

enum SummaryTemplatePresetCatalog {
    static let meetingMinutesID = "meeting-minutes-v1"
    static let actionItemsID = "action-items-v1"
    static let clientFollowUpID = "client-follow-up-v1"
    static let interviewNotesID = "interview-notes-v1"
    static let learningNotesID = "learning-notes-v1"

    static let meetingMinutesPrompt = """
    Identify key points, action items, decisions made, and any important discussions from TRANSCRIPT.
    Organize the information in a clear and concise manner, ensure accuracy, and capture the essence of the meeting.
    Include relevant details such as attendee names, time stamps, and any follow-up actions required.
    The meeting minutes should serve as a comprehensive record of the meeting for future reference and accountability.

    Format the summary using Markdown syntax with:
    - # for main headings
    - ## for subheadings
    - **bold** for important points
    - - or * for bullet points
    - 1. 2. 3. for numbered lists
    - [text](link) for any links

    Make sure to use proper Markdown formatting to create a well-structured, readable summary.
    The summary should be in the same language as the TRANSCRIPT.
    """

    static let presets: [SummaryTemplate] = {
        let revisionDate = Date(timeIntervalSince1970: 1_735_689_600)
        return [
            SummaryTemplate(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                presetID: meetingMinutesID,
                name: "Meeting Minutes",
                prompt: meetingMinutesPrompt,
                isDefault: true,
                createdAt: revisionDate,
                updatedAt: revisionDate,
                sortOrder: 0
            ),
            SummaryTemplate(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                presetID: actionItemsID,
                name: "Action Items",
                prompt: """
                Extract every concrete action item from TRANSCRIPT.
                Group actions by owner, include deadlines and dependencies when stated, and clearly mark missing owners or dates.
                Separate confirmed commitments from suggestions. Do not invent details.
                Use concise Markdown and write in the same language as TRANSCRIPT.
                """,
                createdAt: revisionDate,
                updatedAt: revisionDate,
                sortOrder: 1
            ),
            SummaryTemplate(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
                presetID: clientFollowUpID,
                name: "Client Follow-up",
                prompt: """
                Turn TRANSCRIPT into concise client follow-up notes.
                Summarize the client's goals, decisions, open questions, concerns, commitments, and next steps.
                Clearly distinguish our actions from the client's actions and include dates only when stated.
                Use professional Markdown in the same language as TRANSCRIPT. Do not invent details.
                """,
                createdAt: revisionDate,
                updatedAt: revisionDate,
                sortOrder: 2
            ),
            SummaryTemplate(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
                presetID: interviewNotesID,
                name: "Interview Notes",
                prompt: """
                Summarize TRANSCRIPT as structured interview notes.
                Capture the candidate's experience, skills, examples, motivations, questions, strengths, concerns, and agreed next steps.
                Attribute statements accurately and separate evidence from interviewer impressions.
                Use clear Markdown in the same language as TRANSCRIPT. Do not invent details.
                """,
                createdAt: revisionDate,
                updatedAt: revisionDate,
                sortOrder: 3
            ),
            SummaryTemplate(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
                presetID: learningNotesID,
                name: "Learning Notes",
                prompt: """
                Convert TRANSCRIPT into useful learning notes.
                Explain the main concepts, supporting examples, definitions, unresolved questions, and practical takeaways.
                End with a short review checklist and suggested follow-up topics grounded only in the transcript.
                Use readable Markdown in the same language as TRANSCRIPT.
                """,
                createdAt: revisionDate,
                updatedAt: revisionDate,
                sortOrder: 4
            )
        ]
    }()

    static func isRecognized(_ presetID: String) -> Bool {
        presets.contains(where: { $0.presetID == presetID })
    }

    static func preset(id: String) -> SummaryTemplate? {
        presets.first(where: { $0.presetID == id })
    }
}

enum SummaryTemplateRepositoryNotice: Equatable, Sendable {
    case defaultChangedToMeetingMinutes
}
