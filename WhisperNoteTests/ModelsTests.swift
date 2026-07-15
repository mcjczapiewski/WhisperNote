import Foundation
import XCTest
@testable import WhisperNote

final class ModelsTests: XCTestCase {
    func testRecordingCodableRoundTrip() throws {
        let recording = Recording(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Client call",
            date: Date(timeIntervalSinceReferenceDate: 123_456),
            duration: 1_234.5,
            filePath: URL(fileURLWithPath: "/tmp/whispernote-tests/recording.m4a"),
            systemAudioFilePath: URL(fileURLWithPath: "/tmp/whispernote-tests/system.m4a"),
            groupId: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            groupName: "Imported batch"
        )

        let decoded = try roundTrip(recording, as: Recording.self)

        XCTAssertEqual(decoded.id, recording.id)
        XCTAssertEqual(decoded.name, recording.name)
        XCTAssertEqual(decoded.date, recording.date)
        XCTAssertEqual(decoded.duration, recording.duration)
        XCTAssertEqual(decoded.filePath, recording.filePath)
        XCTAssertEqual(decoded.systemAudioFilePath, recording.systemAudioFilePath)
        XCTAssertEqual(decoded.groupId, recording.groupId)
        XCTAssertEqual(decoded.groupName, recording.groupName)
    }

    func testTranscriptCodableRoundTrip() throws {
        let transcript = Transcript(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Planning session",
            date: Date(timeIntervalSinceReferenceDate: 234_567),
            content: "Plain transcript",
            formattedContent: "[speaker_0]\nPlain transcript",
            recordingId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            status: .completed,
            jsonFilePath: URL(fileURLWithPath: "/tmp/whispernote-tests/transcript.json")
        )

        let decoded = try roundTrip(transcript, as: Transcript.self)

        XCTAssertEqual(decoded.id, transcript.id)
        XCTAssertEqual(decoded.name, transcript.name)
        XCTAssertEqual(decoded.date, transcript.date)
        XCTAssertEqual(decoded.content, transcript.content)
        XCTAssertEqual(decoded.formattedContent, transcript.formattedContent)
        XCTAssertEqual(decoded.recordingId, transcript.recordingId)
        XCTAssertEqual(decoded.status, transcript.status)
        XCTAssertEqual(decoded.jsonFilePath, transcript.jsonFilePath)
    }

    func testSummaryCodableRoundTrip() throws {
        let summary = Summary(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Planning summary",
            date: Date(timeIntervalSinceReferenceDate: 345_678),
            content: "- Decision",
            transcriptId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            model: defaultLLMModelId,
            prompt: "Summarize this transcript.",
            templateID: "action-items-v1",
            templateName: "Action Items",
            status: .inProgress
        )

        let decoded = try roundTrip(summary, as: Summary.self)

        XCTAssertEqual(decoded.id, summary.id)
        XCTAssertEqual(decoded.name, summary.name)
        XCTAssertEqual(decoded.date, summary.date)
        XCTAssertEqual(decoded.content, summary.content)
        XCTAssertEqual(decoded.transcriptId, summary.transcriptId)
        XCTAssertEqual(decoded.model, summary.model)
        XCTAssertEqual(decoded.prompt, summary.prompt)
        XCTAssertEqual(decoded.templateID, summary.templateID)
        XCTAssertEqual(decoded.templateName, summary.templateName)
        XCTAssertEqual(decoded.status, summary.status)
    }

    func testSummaryDecodesLegacyPayloadWithoutTemplateProvenance() throws {
        let payload = LegacySummary(
            id: UUID(),
            name: "Legacy summary",
            date: Date(timeIntervalSinceReferenceDate: 42),
            content: "Stored content",
            transcriptId: UUID(),
            model: "legacy-model",
            prompt: "legacy-prompt",
            status: .completed
        )

        let decoded = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(payload))

        XCTAssertNil(decoded.templateID)
        XCTAssertNil(decoded.templateName)
        XCTAssertEqual(decoded.prompt, "legacy-prompt")
        XCTAssertEqual(decoded.model, "legacy-model")
    }

    func testProcessingJobSnapshotDecodesLegacyMeetingMinutesIdentity() throws {
        let payload = LegacyProcessingJobSnapshot(
            language: "eng",
            shouldSummarize: true,
            modelID: "legacy-model",
            templateID: "meeting-minutes-v1",
            prompt: "frozen-prompt",
            shouldNotify: false
        )

        let decoded = try JSONDecoder().decode(
            ProcessingJobSnapshot.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(decoded.templateID, ProcessingJobSnapshot.meetingMinutesTemplateID)
        XCTAssertNil(decoded.templateName)
        XCTAssertEqual(decoded.prompt, "frozen-prompt")
        XCTAssertEqual(decoded.modelID, "legacy-model")
    }

    func testRecordingDecodesLegacyPayloadWithoutGroupingFields() throws {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let payload = LegacyRecording(
            id: id,
            name: "Legacy recording",
            date: Date(timeIntervalSinceReferenceDate: 456_789),
            duration: 42,
            filePath: URL(fileURLWithPath: "/tmp/whispernote-tests/legacy.m4a")
        )

        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(payload))

        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.systemAudioFilePath)
        XCTAssertNil(decoded.groupId)
        XCTAssertNil(decoded.groupName)
    }

    func testTranscriptDecodesLegacyPayloadWithoutOptionalPresentationFields() throws {
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let payload = LegacyTranscript(
            id: id,
            name: "Legacy transcript",
            date: Date(timeIntervalSinceReferenceDate: 567_890),
            content: "Legacy content",
            recordingId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            status: .completed
        )

        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(payload))

        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.formattedContent)
        XCTAssertNil(decoded.jsonFilePath)
    }

    func testProcessingStatusRawValuesAndCodableRoundTrip() throws {
        let statuses: [(ProcessingStatus, String)] = [
            (.pending, "pending"),
            (.inProgress, "inProgress"),
            (.completed, "completed"),
            (.failed, "failed")
        ]

        XCTAssertEqual(Set(statuses.map(\.1)).count, statuses.count)
        for (status, expectedRawValue) in statuses {
            XCTAssertEqual(status.rawValue, expectedRawValue)
            XCTAssertEqual(try roundTrip(status, as: ProcessingStatus.self), status)
        }
    }

    func testLanguageModelConfigurationInvariants() {
        XCTAssertFalse(llmModels.isEmpty)
        XCTAssertEqual(Set(llmModels.map(\.id)).count, llmModels.count)
        XCTAssertTrue(llmModels.allSatisfy { !$0.id.isEmpty && !$0.displayName.isEmpty })
        XCTAssertTrue(llmModels.contains { $0.id == defaultLLMModelId })
        XCTAssertEqual(defaultLLMModelId, "openai/gpt-4o-mini")
    }

    private func roundTrip<Value: Codable>(_ value: Value, as type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct LegacyRecording: Encodable {
    let id: UUID
    let name: String
    let date: Date
    let duration: TimeInterval
    let filePath: URL
}

private struct LegacyTranscript: Encodable {
    let id: UUID
    let name: String
    let date: Date
    let content: String
    let recordingId: UUID
    let status: ProcessingStatus
}

private struct LegacySummary: Encodable {
    let id: UUID
    let name: String
    let date: Date
    let content: String
    let transcriptId: UUID
    let model: String
    let prompt: String
    let status: ProcessingStatus
}

private struct LegacyProcessingJobSnapshot: Encodable {
    let language: String
    let shouldSummarize: Bool
    let modelID: String
    let templateID: String
    let prompt: String
    let shouldNotify: Bool
}
