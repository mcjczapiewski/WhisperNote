import Foundation

enum TelemetryQueueError: Error, Equatable, Sendable {
    case invalidConsentVersion
    case healthConsentRequired
    case installIdentityMismatch
    case feedbackCapacityExceeded
    case healthCapacityExceeded
    case invalidBatchLimit
    case queueCapacityExceeded
    case invalidStoredEnvelope
    case privacyPurgeRollbackFailed
}

enum TelemetryEnqueueResult: Equatable, Sendable {
    case enqueued
    case deduplicated
}

struct TelemetryDeliveryState: Codable, Equatable, Sendable {
    var generation: UInt64
    var consecutiveFailures: Int
    var nextAttemptAt: TelemetryTimestamp?

    static let initial = TelemetryDeliveryState(
        generation: 0,
        consecutiveFailures: 0,
        nextAttemptAt: nil
    )
}

struct TelemetryDeliveryLease: Equatable, Sendable {
    let generation: UInt64
    let batch: TelemetryBatch
}

struct TelemetryQueueSnapshot: Equatable, Sendable {
    let consent: TelemetryConsentState
    let installID: UUID?
    let milestoneMarkers: Set<TelemetryHealthEventName>
    let weeklyMarker: TelemetryWeekStart?
    let items: [TelemetryItem]
    let delivery: TelemetryDeliveryState
}

protocol TelemetryQueueFileAccess: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
    func move(from source: URL, to destination: URL) throws
    func remove(at url: URL) throws
    func contents(of directory: URL) throws -> [URL]
}

struct LocalTelemetryQueueFileAccess: TelemetryQueueFileAccess {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data { try Data(contentsOf: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func move(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func remove(at url: URL) throws {
        guard fileExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func contents(of directory: URL) throws -> [URL] {
        guard fileExists(at: directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }
}

actor TelemetryQueue {
    static let envelopeSchemaVersion = 1
    static let maximumItems = 500
    static let maximumStoredBytes = 1_048_576
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    nonisolated let storageDirectory: URL
    nonisolated var queueFileURL: URL { storageDirectory.appendingPathComponent("queue.json") }
    nonisolated let consentFileURL: URL

    private let fileAccess: any TelemetryQueueFileAccess
    private let clock: any TelemetryQueueClock
    private let uuidGenerator: any TelemetryUUIDGenerating
    private let generationInvalidated: @Sendable (UInt64) -> Void
    private var loadedEnvelope: TelemetryQueueEnvelope?
    private var loadedConsent: TelemetryConsentState?

    init(
        applicationSupportRoot: URL? = nil,
        fileAccess: any TelemetryQueueFileAccess = LocalTelemetryQueueFileAccess(),
        clock: any TelemetryQueueClock = SystemTelemetryQueueClock(),
        uuidGenerator: any TelemetryUUIDGenerating = SystemTelemetryUUIDGenerator(),
        generationInvalidated: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        let root = applicationSupportRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let appDirectory = root.appendingPathComponent("com.czapiewski.whispernote", isDirectory: true)
        storageDirectory = appDirectory
            .appendingPathComponent("Telemetry", isDirectory: true)
        consentFileURL = appDirectory.appendingPathComponent("telemetry-consent.json")
        self.fileAccess = fileAccess
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.generationInvalidated = generationInvalidated
    }

    func consentSnapshot() throws -> TelemetryConsentSnapshot {
        let envelope = try currentEnvelope()
        return TelemetryConsentSnapshot(consent: try currentConsent(), installID: envelope.installID)
    }

    func snapshot() throws -> TelemetryQueueSnapshot {
        let envelope = try currentEnvelope()
        return TelemetryQueueSnapshot(
            consent: try currentConsent(),
            installID: envelope.installID,
            milestoneMarkers: Set(envelope.milestoneMarkers),
            weeklyMarker: envelope.weeklyMarker,
            items: envelope.items,
            delivery: envelope.delivery
        )
    }

    @discardableResult
    func enableConsent(version: Int) throws -> UUID {
        guard version > 0 else { throw TelemetryQueueError.invalidConsentVersion }
        var candidate = try currentEnvelope()
        let consent = try currentConsent()
        if consent.enabled, let installID = candidate.installID { return installID }
        let installID = uuidGenerator.next()
        let enabled = try TelemetryConsentStore.enabled(
            version: version,
            at: clock.now(),
            installID: installID
        )
        candidate.installID = enabled.1
        candidate.milestoneMarkers = []
        candidate.weeklyMarker = nil
        try commitEnvelopeAndConsent(candidate, consent: enabled.0)
        return installID
    }

    func optOut() throws {
        var candidate = try currentEnvelope(pruningExpired: false)
        let consent = try currentConsent()
        candidate.delivery.generation &+= 1
        let disabledConsent = try TelemetryConsentStore.disabled(
            version: consent.version,
            at: clock.now()
        )
        candidate.installID = nil
        candidate.milestoneMarkers = []
        candidate.weeklyMarker = nil
        candidate.items = []
        candidate.delivery.consecutiveFailures = 0
        candidate.delivery.nextAttemptAt = nil
        try purgeStorageAtomically(persisting: disabledConsent)
        loadedEnvelope = candidate
        loadedConsent = disabledConsent
        generationInvalidated(candidate.delivery.generation)
    }

    @discardableResult
    func enqueueHealth(_ event: TelemetryHealthEvent) throws -> TelemetryEnqueueResult {
        var candidate = try currentEnvelope()
        guard try currentConsent().enabled, let installID = candidate.installID else {
            throw TelemetryQueueError.healthConsentRequired
        }
        guard event.installID == installID else {
            throw TelemetryQueueError.installIdentityMismatch
        }
        if candidate.items.contains(where: { $0.eventID == event.eventID }) {
            return .deduplicated
        }

        switch event.eventName {
        case .firstRecordingCompleted, .firstTranscriptCompleted, .firstSummaryCompleted:
            if candidate.milestoneMarkers.contains(event.eventName) { return .deduplicated }
            candidate.milestoneMarkers.append(event.eventName)
            candidate.milestoneMarkers.sort { $0.rawValue < $1.rawValue }
        case .weeklyActive:
            guard let weekStart = event.weekStart else { throw TelemetryQueueError.invalidStoredEnvelope }
            if let marker = candidate.weeklyMarker, weekStart.rawValue <= marker.rawValue {
                return .deduplicated
            }
            candidate.weeklyMarker = weekStart
        case .stageOutcome:
            break
        }

        candidate.items.append(.health(event))
        try enforceBounds(
            on: &candidate,
            insertedKind: .healthEvent,
            insertedEventID: event.eventID
        )
        try commit(candidate)
        return .enqueued
    }

    @discardableResult
    func enqueueFeedback(_ feedback: TelemetryFeedback) throws -> TelemetryEnqueueResult {
        var candidate = try currentEnvelope()
        if candidate.items.contains(where: { $0.eventID == feedback.eventID }) {
            return .deduplicated
        }
        candidate.items.append(.feedback(feedback))
        try enforceBounds(
            on: &candidate,
            insertedKind: .feedback,
            insertedEventID: feedback.eventID
        )
        try commit(candidate)
        return .enqueued
    }

    func nextBatch(maxItems: Int = TelemetrySchema.maximumBatchItems) throws -> TelemetryDeliveryLease? {
        guard (1...TelemetrySchema.maximumBatchItems).contains(maxItems) else {
            throw TelemetryQueueError.invalidBatchLimit
        }
        let envelope = try currentEnvelope()
        guard !envelope.items.isEmpty else { return nil }
        let sentAt = try telemetryTimestamp(for: clock.now())
        let batchID = uuidGenerator.next()
        let selected = try selectDeliveryItems(
            envelope.items,
            limit: maxItems,
            batchID: batchID,
            sentAt: sentAt
        )
        guard !selected.isEmpty else { return nil }
        return TelemetryDeliveryLease(
            generation: envelope.delivery.generation,
            batch: try TelemetryBatch(
                batchID: batchID,
                sentAt: sentAt,
                items: selected
            )
        )
    }

    @discardableResult
    func acknowledge(
        _ lease: TelemetryDeliveryLease,
        acceptedEventIDs: Set<UUID>
    ) throws -> Bool {
        var candidate = try currentEnvelope()
        guard candidate.delivery.generation == lease.generation else { return false }
        let leasedEventIDs = Set(lease.batch.items.map(\.eventID))
        let acknowledgedEventIDs = acceptedEventIDs.intersection(leasedEventIDs)
        candidate.items.removeAll { acknowledgedEventIDs.contains($0.eventID) }
        candidate.delivery.consecutiveFailures = 0
        candidate.delivery.nextAttemptAt = nil
        try commit(candidate)
        return true
    }

    @discardableResult
    func quarantine(
        _ lease: TelemetryDeliveryLease,
        eventIDs: Set<UUID>
    ) throws -> Bool {
        var candidate = try currentEnvelope()
        guard candidate.delivery.generation == lease.generation else { return false }
        let leasedEventIDs = Set(lease.batch.items.map(\.eventID))
        let quarantinedIDs = eventIDs.intersection(leasedEventIDs)
        let items = candidate.items.filter { quarantinedIDs.contains($0.eventID) }
        for item in items {
            let destination = storageDirectory.appendingPathComponent(
                "item.quarantine.\(item.eventID.uuidString).json"
            )
            try fileAccess.createDirectory(at: storageDirectory)
            try fileAccess.writeAtomically(try TelemetryJSON.encodeItem(item), to: destination)
        }
        candidate.items.removeAll { quarantinedIDs.contains($0.eventID) }
        candidate.delivery.consecutiveFailures = 0
        candidate.delivery.nextAttemptAt = nil
        try commit(candidate)
        return true
    }

    @discardableResult
    func updateDeliveryState(
        consecutiveFailures: Int,
        nextAttemptAt: Date?,
        generation: UInt64
    ) throws -> Bool {
        var candidate = try currentEnvelope()
        guard candidate.delivery.generation == generation else { return false }
        candidate.delivery.consecutiveFailures = max(0, consecutiveFailures)
        candidate.delivery.nextAttemptAt = try nextAttemptAt.map(telemetryTimestamp(for:))
        try commit(candidate)
        return true
    }

    private func currentEnvelope(pruningExpired: Bool = true) throws -> TelemetryQueueEnvelope {
        let consent = try currentConsent()
        if loadedEnvelope == nil { loadedEnvelope = try loadEnvelope(consent: consent) }
        guard var envelope = loadedEnvelope else { throw TelemetryQueueError.invalidStoredEnvelope }
        if pruningExpired, pruneExpired(from: &envelope) {
            try commit(envelope)
        }
        return envelope
    }

    private func currentConsent() throws -> TelemetryConsentState {
        if let loadedConsent { return loadedConsent }
        let consent: TelemetryConsentState
        if fileAccess.fileExists(at: consentFileURL) {
            consent = try TelemetryConsentStore.decode(fileAccess.read(from: consentFileURL))
        } else {
            consent = .disabled
        }
        loadedConsent = consent
        return consent
    }

    private func loadEnvelope(consent: TelemetryConsentState) throws -> TelemetryQueueEnvelope {
        guard fileAccess.fileExists(at: queueFileURL) else { return .empty }
        let data = try fileAccess.read(from: queueFileURL)
        guard data.count <= Self.maximumStoredBytes else {
            try quarantineCurrentFile()
            return .empty
        }
        do {
            let header = try JSONDecoder().decode(TelemetryQueueEnvelopeHeader.self, from: data)
            guard header.schemaVersion == Self.envelopeSchemaVersion else {
                try quarantineCurrentFile()
                return .empty
            }
            let envelope = try JSONDecoder().decode(TelemetryQueueEnvelope.self, from: data)
            guard try isValid(envelope, consent: consent) else {
                try quarantineCurrentFile()
                return .empty
            }
            return envelope
        } catch {
            try quarantineCurrentFile()
            return .empty
        }
    }

    private func isValid(
        _ envelope: TelemetryQueueEnvelope,
        consent: TelemetryConsentState
    ) throws -> Bool {
        guard envelope.schemaVersion == Self.envelopeSchemaVersion,
              Set(envelope.items.map(\.eventID)).count == envelope.items.count,
              Set(envelope.milestoneMarkers).count == envelope.milestoneMarkers.count,
              envelope.items.count <= Self.maximumItems else { return false }
        if consent.enabled {
            guard let installID = envelope.installID,
                  let consentVersion = consent.version,
                  consentVersion > 0,
                  consent.changedAt != nil else { return false }
            for item in envelope.items {
                if case .health(let health) = item, health.installID != installID { return false }
            }
        } else {
            guard envelope.installID == nil,
                  !envelope.items.contains(where: {
                      if case .health = $0 { return true }
                      return false
                  }) else { return false }
        }
        return true
    }

    private func pruneExpired(from envelope: inout TelemetryQueueEnvelope) -> Bool {
        let cutoff = clock.now().addingTimeInterval(-Self.retentionInterval)
        let originalCount = envelope.items.count
        envelope.items.removeAll { item in
            guard let occurredAt = telemetryDate(from: occurredAt(of: item)) else { return true }
            return occurredAt < cutoff
        }
        return envelope.items.count != originalCount
    }

    private func enforceBounds(
        on envelope: inout TelemetryQueueEnvelope,
        insertedKind: TelemetryItemKind,
        insertedEventID: UUID
    ) throws {
        _ = pruneExpired(from: &envelope)
        while true {
            let exceedsCount = envelope.items.count > Self.maximumItems
            let exceedsSize = try encoded(envelope).count > Self.maximumStoredBytes
            guard exceedsCount || exceedsSize else { break }
            guard let oldestHealthIndex = envelope.items.firstIndex(where: {
                if case .health = $0 { return true }
                return false
            }) else {
                throw insertedKind == .feedback
                    ? TelemetryQueueError.feedbackCapacityExceeded
                    : TelemetryQueueError.healthCapacityExceeded
            }
            envelope.items.remove(at: oldestHealthIndex)
        }
        guard envelope.items.contains(where: { $0.eventID == insertedEventID }) else {
            throw insertedKind == .feedback
                ? TelemetryQueueError.feedbackCapacityExceeded
                : TelemetryQueueError.healthCapacityExceeded
        }
    }

    private func commit(_ envelope: TelemetryQueueEnvelope) throws {
        let data = try encoded(envelope)
        guard data.count <= Self.maximumStoredBytes else {
            throw TelemetryQueueError.queueCapacityExceeded
        }
        try fileAccess.createDirectory(at: storageDirectory)
        try fileAccess.writeAtomically(data, to: queueFileURL)
        loadedEnvelope = envelope
    }

    private func commitEnvelopeAndConsent(
        _ envelope: TelemetryQueueEnvelope,
        consent: TelemetryConsentState
    ) throws {
        let priorQueueData = fileAccess.fileExists(at: queueFileURL)
            ? try fileAccess.read(from: queueFileURL)
            : nil
        let data = try encoded(envelope)
        try fileAccess.createDirectory(at: storageDirectory)
        try fileAccess.writeAtomically(data, to: queueFileURL)
        do {
            try persistConsent(consent)
        } catch {
            if let priorQueueData {
                try? fileAccess.writeAtomically(priorQueueData, to: queueFileURL)
            } else {
                try? fileAccess.remove(at: queueFileURL)
            }
            throw error
        }
        loadedEnvelope = envelope
        loadedConsent = consent
    }

    private func persistConsent(_ consent: TelemetryConsentState) throws {
        try fileAccess.createDirectory(at: consentFileURL.deletingLastPathComponent())
        try fileAccess.writeAtomically(TelemetryConsentStore.encode(consent), to: consentFileURL)
    }

    private func encoded(_ envelope: TelemetryQueueEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    private func quarantineCurrentFile() throws {
        guard fileAccess.fileExists(at: queueFileURL) else { return }
        try fileAccess.createDirectory(at: storageDirectory)
        let destination = storageDirectory.appendingPathComponent(
            "queue.quarantine.\(uuidGenerator.next().uuidString).json"
        )
        try fileAccess.move(from: queueFileURL, to: destination)
    }

    private func purgeStorageAtomically(persisting disabledConsent: TelemetryConsentState) throws {
        let priorConsentData = fileAccess.fileExists(at: consentFileURL)
            ? try fileAccess.read(from: consentFileURL)
            : nil
        let purgeDirectory = storageDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Telemetry.purge.\(uuidGenerator.next().uuidString)",
                isDirectory: true
            )
        let movedQueueStorage = fileAccess.fileExists(at: storageDirectory)
        if movedQueueStorage {
            try fileAccess.move(from: storageDirectory, to: purgeDirectory)
        }
        do {
            try persistConsent(disabledConsent)
            if movedQueueStorage { try fileAccess.remove(at: purgeDirectory) }
        } catch {
            var rollbackSucceeded = true
            do {
                if let priorConsentData {
                    try fileAccess.writeAtomically(priorConsentData, to: consentFileURL)
                } else {
                    try fileAccess.remove(at: consentFileURL)
                }
            } catch {
                rollbackSucceeded = false
            }
            if movedQueueStorage {
                do {
                    try fileAccess.move(from: purgeDirectory, to: storageDirectory)
                } catch {
                    rollbackSucceeded = false
                }
            }
            guard rollbackSucceeded else { throw TelemetryQueueError.privacyPurgeRollbackFailed }
            throw error
        }
    }

    private func selectDeliveryItems(
        _ items: [TelemetryItem],
        limit: Int,
        batchID: UUID,
        sentAt: TelemetryTimestamp
    ) throws -> [TelemetryItem] {
        let feedback = items.filter {
            if case .feedback = $0 { return true }
            return false
        }
        let health = items.filter {
            if case .health = $0 { return true }
            return false
        }
        var selected: [TelemetryItem] = []
        if let oldestHealth = health.first {
            if feedback.isEmpty || limit == 1 {
                if try batchFits([oldestHealth], batchID: batchID, sentAt: sentAt) {
                    selected.append(oldestHealth)
                }
            } else {
                for item in feedback.prefix(min(3, limit - 1)) {
                    let withReservedHealth = selected + [item, oldestHealth]
                    guard try batchFits(withReservedHealth, batchID: batchID, sentAt: sentAt) else {
                        break
                    }
                    selected.append(item)
                }
                if try batchFits(selected + [oldestHealth], batchID: batchID, sentAt: sentAt) {
                    selected.append(oldestHealth)
                }
            }
        }

        let selectedIDs = Set(selected.map(\.eventID))
        var blockedKinds: Set<TelemetryItemKind> = []
        for item in items where selected.count < limit && !selectedIDs.contains(item.eventID) {
            let kind: TelemetryItemKind
            switch item {
            case .health: kind = .healthEvent
            case .feedback: kind = .feedback
            }
            guard !blockedKinds.contains(kind) else { continue }
            if try batchFits(selected + [item], batchID: batchID, sentAt: sentAt) {
                selected.append(item)
            } else {
                blockedKinds.insert(kind)
            }
        }
        return selected
    }

    private func batchFits(
        _ items: [TelemetryItem],
        batchID: UUID,
        sentAt: TelemetryTimestamp
    ) throws -> Bool {
        guard !items.isEmpty else { return true }
        let batch = try TelemetryBatch(batchID: batchID, sentAt: sentAt, items: items)
        do {
            _ = try TelemetryJSON.encodeBatch(batch)
            return true
        } catch TelemetryValidationError.batchTooLarge {
            return false
        }
    }

    private func occurredAt(of item: TelemetryItem) -> TelemetryTimestamp {
        switch item {
        case .health(let event): event.occurredAt
        case .feedback(let feedback): feedback.occurredAt
        }
    }
}

private struct TelemetryQueueEnvelopeHeader: Decodable {
    let schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
    }
}

private struct TelemetryQueueEnvelope: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var installID: UUID?
    var milestoneMarkers: [TelemetryHealthEventName]
    var weeklyMarker: TelemetryWeekStart?
    var items: [TelemetryItem]
    var delivery: TelemetryDeliveryState

    static let empty = TelemetryQueueEnvelope(
        schemaVersion: TelemetryQueue.envelopeSchemaVersion,
        installID: nil,
        milestoneMarkers: [],
        weeklyMarker: nil,
        items: [],
        delivery: .initial
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installID = "install_id"
        case milestoneMarkers = "milestone_markers"
        case weeklyMarker = "weekly_marker"
        case items
        case delivery
    }
}
