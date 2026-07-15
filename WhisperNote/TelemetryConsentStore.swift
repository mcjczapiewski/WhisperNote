import Foundation

struct TelemetryConsentState: Codable, Equatable, Sendable {
    let enabled: Bool
    let version: Int?
    let changedAt: TelemetryTimestamp?

    static let disabled = TelemetryConsentState(enabled: false, version: nil, changedAt: nil)
}

struct TelemetryConsentSnapshot: Equatable, Sendable {
    let consent: TelemetryConsentState
    let installID: UUID?
}

protocol TelemetryQueueClock: Sendable {
    func now() -> Date
}

struct SystemTelemetryQueueClock: TelemetryQueueClock {
    func now() -> Date { Date() }
}

protocol TelemetryUUIDGenerating: Sendable {
    func next() -> UUID
}

struct SystemTelemetryUUIDGenerator: TelemetryUUIDGenerating {
    func next() -> UUID { UUID() }
}

enum TelemetryConsentStore {
    static let schemaVersion = 1

    static func enabled(
        version: Int,
        at date: Date,
        installID: UUID
    ) throws -> (TelemetryConsentState, UUID) {
        guard version > 0 else { throw TelemetryQueueError.invalidConsentVersion }
        return (
            TelemetryConsentState(
                enabled: true,
                version: version,
                changedAt: try telemetryTimestamp(for: date)
            ),
            installID
        )
    }

    static func disabled(version: Int?, at date: Date) throws -> TelemetryConsentState {
        TelemetryConsentState(
            enabled: false,
            version: version,
            changedAt: try telemetryTimestamp(for: date)
        )
    }

    static func encode(_ state: TelemetryConsentState) throws -> Data {
        let envelope = TelemetryConsentEnvelope(schemaVersion: schemaVersion, consent: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> TelemetryConsentState {
        let envelope = try JSONDecoder().decode(TelemetryConsentEnvelope.self, from: data)
        guard envelope.schemaVersion == schemaVersion,
              envelope.consent.changedAt != nil,
              envelope.consent.version.map({ $0 > 0 }) ?? true else {
            throw TelemetryQueueError.invalidStoredEnvelope
        }
        if envelope.consent.enabled, envelope.consent.version == nil {
            throw TelemetryQueueError.invalidStoredEnvelope
        }
        return envelope.consent
    }
}

private struct TelemetryConsentEnvelope: Codable {
    let schemaVersion: Int
    let consent: TelemetryConsentState

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case consent
    }
}

func telemetryTimestamp(for date: Date) throws -> TelemetryTimestamp {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return try TelemetryTimestamp(rawValue: formatter.string(from: date))
}

func telemetryDate(from timestamp: TelemetryTimestamp) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = timestamp.rawValue.contains(".")
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter.date(from: timestamp.rawValue)
}
