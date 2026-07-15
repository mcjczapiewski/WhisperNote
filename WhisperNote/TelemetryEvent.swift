import Foundation

enum TelemetrySchema {
    static let contractVersion = 1
    static let itemSchemaVersion = 1
    static let maximumBatchItems = 20
    static let maximumBatchBytes = 64 * 1024
    static let maximumFeedbackCharacters = 2_000
}

enum TelemetryValidationError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidAppVersion
    case invalidAppBuild
    case invalidOSVersion
    case invalidWeekStart
    case invalidEventShape
    case invalidFeedbackMessage
    case emptyBatch
    case tooManyItems
    case duplicateEventID
    case batchTooLarge
    case unsupportedContractVersion
    case unsupportedItemSchemaVersion
    case invalidEndpoint
}

enum TelemetryItemKind: String, Codable, CaseIterable, Sendable {
    case healthEvent = "health_event"
    case feedback
}

enum TelemetryHealthEventName: String, Codable, CaseIterable, Sendable {
    case firstRecordingCompleted = "first_recording_completed"
    case firstTranscriptCompleted = "first_transcript_completed"
    case firstSummaryCompleted = "first_summary_completed"
    case weeklyActive = "weekly_active"
    case stageOutcome = "stage_outcome"
}

enum TelemetryStage: String, Codable, CaseIterable, Sendable {
    case recordingFinalize = "recording_finalize"
    case transcription
    case summary
}

enum TelemetryOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case failure
    case cancelled
}

enum TelemetryDurationBucket: String, Codable, CaseIterable, Sendable {
    case lessThanOneSecond = "lt_1s"
    case oneToFiveSeconds = "1_5s"
    case fiveToFifteenSeconds = "5_15s"
    case fifteenToSixtySeconds = "15_60s"
    case oneToFiveMinutes = "1_5m"
    case fiveToFifteenMinutes = "5_15m"
    case fifteenToThirtyMinutes = "15_30m"
    case thirtyToSixtyMinutes = "30_60m"
    case atLeastSixtyMinutes = "gte_60m"
    case unknown
}

enum TelemetryFailureBucket: String, Codable, CaseIterable, Sendable {
    case permission
    case noAudio = "no_audio"
    case device
    case storage
    case network
    case timeout
    case rateLimited = "rate_limited"
    case authentication
    case service
    case decode
    case persistence
    case cancelled
    case unknown
}

enum TelemetryFeedbackCategory: String, Codable, CaseIterable, Sendable {
    case bug
    case idea
    case usability
    case other
}

struct TelemetryTimestamp: Codable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw TelemetryValidationError.invalidTimestamp }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

struct TelemetryAppVersion: Codable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else {
            throw TelemetryValidationError.invalidAppVersion
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TelemetryBuildVersion: Codable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let pattern = #"^(0|[1-9]\d*)(?:\.(0|[1-9]\d*)){0,2}$"#
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else {
            throw TelemetryValidationError.invalidAppBuild
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TelemetryOSVersion: Codable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)$"#
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else {
            throw TelemetryValidationError.invalidOSVersion
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TelemetryWeekStart: Codable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard rawValue.range(of: pattern, options: .regularExpression) != nil,
              let date = formatter.date(from: rawValue),
              formatter.string(from: date) == rawValue,
              formatter.calendar.component(.weekday, from: date) == 2 else {
            throw TelemetryValidationError.invalidWeekStart
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TelemetryRuntimeContext: Codable, Equatable, Sendable {
    let appVersion: TelemetryAppVersion
    let appBuild: TelemetryBuildVersion
    let osVersion: TelemetryOSVersion

    init(appVersion: String, appBuild: String, osVersion: String) throws {
        self.appVersion = try TelemetryAppVersion(rawValue: appVersion)
        self.appBuild = try TelemetryBuildVersion(rawValue: appBuild)
        self.osVersion = try TelemetryOSVersion(rawValue: osVersion)
    }
}

struct TelemetryHealthEvent: Codable, Equatable, Sendable {
    let eventID: UUID
    let occurredAt: TelemetryTimestamp
    let runtime: TelemetryRuntimeContext
    let installID: UUID
    let eventName: TelemetryHealthEventName
    let stage: TelemetryStage?
    let outcome: TelemetryOutcome?
    let durationBucket: TelemetryDurationBucket?
    let failureBucket: TelemetryFailureBucket?
    let weekStart: TelemetryWeekStart?

    var kind: TelemetryItemKind { .healthEvent }
    var schemaVersion: Int { TelemetrySchema.itemSchemaVersion }

    init(
        eventID: UUID,
        occurredAt: TelemetryTimestamp,
        runtime: TelemetryRuntimeContext,
        installID: UUID,
        eventName: TelemetryHealthEventName,
        stage: TelemetryStage? = nil,
        outcome: TelemetryOutcome? = nil,
        durationBucket: TelemetryDurationBucket? = nil,
        failureBucket: TelemetryFailureBucket? = nil,
        weekStart: TelemetryWeekStart? = nil
    ) throws {
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.runtime = runtime
        self.installID = installID
        self.eventName = eventName
        self.stage = stage
        self.outcome = outcome
        self.durationBucket = durationBucket
        self.failureBucket = failureBucket
        self.weekStart = weekStart
        try validateShape()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case eventID = "event_id"
        case schemaVersion = "schema_version"
        case occurredAt = "occurred_at"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case osVersion = "os_version"
        case installID = "install_id"
        case eventName = "event_name"
        case stage
        case outcome
        case durationBucket = "duration_bucket"
        case failureBucket = "failure_bucket"
        case weekStart = "week_start"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(TelemetryItemKind.self, forKey: .kind) == .healthEvent else {
            throw TelemetryValidationError.invalidEventShape
        }
        guard try container.decode(Int.self, forKey: .schemaVersion) == TelemetrySchema.itemSchemaVersion else {
            throw TelemetryValidationError.unsupportedItemSchemaVersion
        }
        eventID = try container.decode(UUID.self, forKey: .eventID)
        occurredAt = try container.decode(TelemetryTimestamp.self, forKey: .occurredAt)
        runtime = TelemetryRuntimeContext(
            appVersion: try container.decode(TelemetryAppVersion.self, forKey: .appVersion),
            appBuild: try container.decode(TelemetryBuildVersion.self, forKey: .appBuild),
            osVersion: try container.decode(TelemetryOSVersion.self, forKey: .osVersion)
        )
        installID = try container.decode(UUID.self, forKey: .installID)
        eventName = try container.decode(TelemetryHealthEventName.self, forKey: .eventName)
        stage = try container.decodeIfPresent(TelemetryStage.self, forKey: .stage)
        outcome = try container.decodeIfPresent(TelemetryOutcome.self, forKey: .outcome)
        durationBucket = try container.decodeIfPresent(TelemetryDurationBucket.self, forKey: .durationBucket)
        failureBucket = try container.decodeIfPresent(TelemetryFailureBucket.self, forKey: .failureBucket)
        weekStart = try container.decodeIfPresent(TelemetryWeekStart.self, forKey: .weekStart)
        try validateShape()
    }

    func encode(to encoder: Encoder) throws {
        try validateShape()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(runtime.appVersion, forKey: .appVersion)
        try container.encode(runtime.appBuild, forKey: .appBuild)
        try container.encode(runtime.osVersion, forKey: .osVersion)
        try container.encode(installID, forKey: .installID)
        try container.encode(eventName, forKey: .eventName)
        try container.encodeIfPresent(stage, forKey: .stage)
        try container.encodeIfPresent(outcome, forKey: .outcome)
        try container.encodeIfPresent(durationBucket, forKey: .durationBucket)
        try container.encodeIfPresent(failureBucket, forKey: .failureBucket)
        try container.encodeIfPresent(weekStart, forKey: .weekStart)
    }

    private func validateShape() throws {
        switch eventName {
        case .firstRecordingCompleted, .firstTranscriptCompleted, .firstSummaryCompleted:
            guard stage == nil, outcome == nil, durationBucket == nil,
                  failureBucket == nil, weekStart == nil else {
                throw TelemetryValidationError.invalidEventShape
            }
        case .weeklyActive:
            guard weekStart != nil, stage == nil, outcome == nil,
                  durationBucket == nil, failureBucket == nil else {
                throw TelemetryValidationError.invalidEventShape
            }
        case .stageOutcome:
            guard stage != nil, let outcome, weekStart == nil else {
                throw TelemetryValidationError.invalidEventShape
            }
            switch outcome {
            case .success:
                guard failureBucket == nil else { throw TelemetryValidationError.invalidEventShape }
            case .failure:
                guard let failureBucket, failureBucket != .cancelled else {
                    throw TelemetryValidationError.invalidEventShape
                }
            case .cancelled:
                guard failureBucket == .cancelled else { throw TelemetryValidationError.invalidEventShape }
            }
        }
    }
}

struct TelemetryFeedback: Codable, Equatable, Sendable {
    let eventID: UUID
    let occurredAt: TelemetryTimestamp
    let runtime: TelemetryRuntimeContext
    let category: TelemetryFeedbackCategory
    let message: String

    var kind: TelemetryItemKind { .feedback }
    var schemaVersion: Int { TelemetrySchema.itemSchemaVersion }

    init(
        eventID: UUID,
        occurredAt: TelemetryTimestamp,
        runtime: TelemetryRuntimeContext,
        category: TelemetryFeedbackCategory,
        message: String
    ) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= TelemetrySchema.maximumFeedbackCharacters else {
            throw TelemetryValidationError.invalidFeedbackMessage
        }
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.runtime = runtime
        self.category = category
        self.message = trimmed
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case eventID = "event_id"
        case schemaVersion = "schema_version"
        case occurredAt = "occurred_at"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case osVersion = "os_version"
        case category
        case message
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(TelemetryItemKind.self, forKey: .kind) == .feedback else {
            throw TelemetryValidationError.invalidEventShape
        }
        guard try container.decode(Int.self, forKey: .schemaVersion) == TelemetrySchema.itemSchemaVersion else {
            throw TelemetryValidationError.unsupportedItemSchemaVersion
        }
        try self.init(
            eventID: container.decode(UUID.self, forKey: .eventID),
            occurredAt: container.decode(TelemetryTimestamp.self, forKey: .occurredAt),
            runtime: TelemetryRuntimeContext(
                appVersion: container.decode(TelemetryAppVersion.self, forKey: .appVersion),
                appBuild: container.decode(TelemetryBuildVersion.self, forKey: .appBuild),
                osVersion: container.decode(TelemetryOSVersion.self, forKey: .osVersion)
            ),
            category: container.decode(TelemetryFeedbackCategory.self, forKey: .category),
            message: container.decode(String.self, forKey: .message)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(runtime.appVersion, forKey: .appVersion)
        try container.encode(runtime.appBuild, forKey: .appBuild)
        try container.encode(runtime.osVersion, forKey: .osVersion)
        try container.encode(category, forKey: .category)
        try container.encode(message, forKey: .message)
    }
}

enum TelemetryItem: Codable, Equatable, Sendable {
    case health(TelemetryHealthEvent)
    case feedback(TelemetryFeedback)

    var eventID: UUID {
        switch self {
        case .health(let event): event.eventID
        case .feedback(let feedback): feedback.eventID
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TelemetryDiscriminatorKey.self)
        switch try container.decode(TelemetryItemKind.self, forKey: .kind) {
        case .healthEvent: self = .health(try TelemetryHealthEvent(from: decoder))
        case .feedback: self = .feedback(try TelemetryFeedback(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .health(let event): try event.encode(to: encoder)
        case .feedback(let feedback): try feedback.encode(to: encoder)
        }
    }
}

struct TelemetryBatch: Codable, Equatable, Sendable {
    let batchID: UUID
    let sentAt: TelemetryTimestamp
    let items: [TelemetryItem]

    var contractVersion: Int { TelemetrySchema.contractVersion }

    init(batchID: UUID, sentAt: TelemetryTimestamp, items: [TelemetryItem]) throws {
        guard !items.isEmpty else { throw TelemetryValidationError.emptyBatch }
        guard items.count <= TelemetrySchema.maximumBatchItems else {
            throw TelemetryValidationError.tooManyItems
        }
        guard Set(items.map(\.eventID)).count == items.count else {
            throw TelemetryValidationError.duplicateEventID
        }
        self.batchID = batchID
        self.sentAt = sentAt
        self.items = items
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version"
        case batchID = "batch_id"
        case sentAt = "sent_at"
        case items
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .contractVersion) == TelemetrySchema.contractVersion else {
            throw TelemetryValidationError.unsupportedContractVersion
        }
        try self.init(
            batchID: container.decode(UUID.self, forKey: .batchID),
            sentAt: container.decode(TelemetryTimestamp.self, forKey: .sentAt),
            items: container.decode([TelemetryItem].self, forKey: .items)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(items, forKey: .items)
    }
}

enum TelemetryJSON {
    static func encodeItem(_ item: TelemetryItem) throws -> Data {
        try encoder().encode(item)
    }

    static func decodeItem(from data: Data) throws -> TelemetryItem {
        try JSONDecoder().decode(TelemetryItem.self, from: data)
    }

    static func encodeBatch(_ batch: TelemetryBatch) throws -> Data {
        let data = try encoder().encode(batch)
        guard data.count <= TelemetrySchema.maximumBatchBytes else {
            throw TelemetryValidationError.batchTooLarge
        }
        return data
    }

    static func decodeBatch(from data: Data) throws -> TelemetryBatch {
        guard data.count <= TelemetrySchema.maximumBatchBytes else {
            throw TelemetryValidationError.batchTooLarge
        }
        return try JSONDecoder().decode(TelemetryBatch.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum TelemetryEndpointValidator {
    static func validate(_ endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw TelemetryValidationError.invalidEndpoint
        }
    }
}

enum TelemetryDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case queued
    case sent
    case retryScheduled = "retry_scheduled"
    case deliveryPaused = "delivery_paused"
    case itemQuarantined = "item_quarantined"
    case validationRejected = "validation_rejected"
}

struct TelemetryDiagnostic: Codable, Equatable, Sendable {
    let code: TelemetryDiagnosticCode
    let itemCount: Int

    init(code: TelemetryDiagnosticCode, itemCount: Int) {
        self.code = code
        self.itemCount = max(0, itemCount)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case itemCount = "item_count"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(TelemetryDiagnosticCode.self, forKey: .code)
        itemCount = max(0, try container.decode(Int.self, forKey: .itemCount))
    }
}

struct TelemetryLeakFinding: Equatable, Sendable {
    let path: String
    let canaryIndex: Int
}

enum TelemetryLeakScanner {
    static func findings(
        in data: Data,
        canaries: [String],
        exemptFeedbackMessage: Bool = true
    ) throws -> [TelemetryLeakFinding] {
        let object = try JSONSerialization.jsonObject(with: data)
        let normalizedCanaries = canaries.map { $0.folding(options: [.caseInsensitive], locale: .current) }
        var results: [TelemetryLeakFinding] = []
        scan(
            object,
            path: "$",
            insideFeedback: false,
            canaries: normalizedCanaries,
            exemptFeedbackMessage: exemptFeedbackMessage,
            results: &results
        )
        return results
    }

    private static func scan(
        _ value: Any,
        path: String,
        insideFeedback: Bool,
        canaries: [String],
        exemptFeedbackMessage: Bool,
        results: inout [TelemetryLeakFinding]
    ) {
        if let dictionary = value as? [String: Any] {
            let isFeedback = insideFeedback || (dictionary["kind"] as? String == TelemetryItemKind.feedback.rawValue)
            for (key, nested) in dictionary {
                appendMatches(in: key, path: "\(path).<key>", canaries: canaries, results: &results)
                if exemptFeedbackMessage, isFeedback, key == "message" { continue }
                scan(
                    nested,
                    path: "\(path).\(key)",
                    insideFeedback: isFeedback,
                    canaries: canaries,
                    exemptFeedbackMessage: exemptFeedbackMessage,
                    results: &results
                )
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                scan(
                    nested,
                    path: "\(path)[\(index)]",
                    insideFeedback: insideFeedback,
                    canaries: canaries,
                    exemptFeedbackMessage: exemptFeedbackMessage,
                    results: &results
                )
            }
        } else if let string = value as? String {
            appendMatches(in: string, path: path, canaries: canaries, results: &results)
        }
    }

    private static func appendMatches(
        in value: String,
        path: String,
        canaries: [String],
        results: inout [TelemetryLeakFinding]
    ) {
        let normalized = value.folding(options: [.caseInsensitive], locale: .current)
        for (index, canary) in canaries.enumerated() where !canary.isEmpty && normalized.contains(canary) {
            results.append(TelemetryLeakFinding(path: path, canaryIndex: index))
        }
    }
}

private struct TelemetryDiscriminatorKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static let kind = TelemetryDiscriminatorKey(stringValue: "kind")!
}

private struct TelemetryAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Keys.Type
) throws where Keys.AllCases: Sequence {
    let container = try decoder.container(keyedBy: TelemetryAnyCodingKey.self)
    let allowedNames = Set(Keys.allCases.map(\.stringValue))
    let unknown = container.allKeys.map(\.stringValue).filter { !allowedNames.contains($0) }
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown telemetry fields are not allowed.")
        )
    }
}

private extension TelemetryRuntimeContext {
    init(
        appVersion: TelemetryAppVersion,
        appBuild: TelemetryBuildVersion,
        osVersion: TelemetryOSVersion
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
    }
}
