import Foundation
import XCTest
@testable import WhisperNote

final class TelemetryQueueTests: XCTestCase {
    func testDefaultsOffWithoutIdentifierOrFile() async throws {
        let context = QueueTestContext()
        let queue = context.queue()

        let snapshot = try await queue.snapshot()

        XCTAssertFalse(snapshot.consent.enabled)
        XCTAssertNil(snapshot.installID)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(context.access.fileExists(at: queue.queueFileURL))
    }

    func testEnableOptOutAndReconsentUseFreshIdentityAndInvalidateGeneration() async throws {
        let context = QueueTestContext()
        let invalidations = Invalidations()
        let queue = context.queue { invalidations.append($0) }

        let firstID = try await queue.enableConsent(version: 1)
        XCTAssertEqual(firstID, context.ids.values[0])
        let repeatedID = try await queue.enableConsent(version: 1)
        XCTAssertEqual(repeatedID, firstID)
        try await queue.enqueueHealth(context.milestone(installID: firstID))
        let generation = try await queue.snapshot().delivery.generation

        try await queue.optOut()
        let optedOut = try await queue.snapshot()
        XCTAssertFalse(optedOut.consent.enabled)
        XCTAssertNil(optedOut.installID)
        XCTAssertTrue(optedOut.items.isEmpty)
        XCTAssertTrue(optedOut.milestoneMarkers.isEmpty)
        XCTAssertEqual(optedOut.delivery.generation, generation + 1)
        XCTAssertEqual(invalidations.values, [generation + 1])
        XCTAssertFalse(context.access.fileExists(at: queue.queueFileURL))
        XCTAssertFalse(context.access.fileExists(at: queue.storageDirectory))
        XCTAssertTrue(context.access.fileExists(at: queue.consentFileURL))
        let durableConsent = String(
            decoding: try context.access.read(from: queue.consentFileURL),
            as: UTF8.self
        )
        XCTAssertFalse(durableConsent.contains(firstID.uuidString))
        XCTAssertFalse(durableConsent.contains("install_id"))
        XCTAssertFalse(durableConsent.contains("items"))
        XCTAssertFalse(durableConsent.contains("queue"))

        let restartedQueue = context.queue()
        let restarted = try await restartedQueue.snapshot()
        XCTAssertFalse(restarted.consent.enabled)
        XCTAssertEqual(restarted.consent.version, 1)
        XCTAssertEqual(restarted.consent.changedAt, optedOut.consent.changedAt)
        XCTAssertNil(restarted.installID)
        XCTAssertTrue(restarted.items.isEmpty)

        let secondID = try await restartedQueue.enableConsent(version: 1)
        XCTAssertNotEqual(secondID, firstID)
    }

    func testOptOutMoveFailureRollsBackWithoutPublishingPartialState() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        try await queue.enqueueHealth(context.milestone(installID: installID))
        let before = try await queue.snapshot()
        context.access.failNextMove = true

        await XCTAssertThrowsErrorAsync { try await queue.optOut() }

        let after = try await queue.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertTrue(context.access.fileExists(at: queue.queueFileURL))
        let restarted = try await context.queue().snapshot()
        XCTAssertEqual(restarted, before)
    }

    func testOptOutRemoveFailureRestoresQueueAndPriorDurableConsent() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        try await queue.enqueueHealth(context.milestone(installID: installID))
        let before = try await queue.snapshot()
        context.access.failNextRemove = true

        await XCTAssertThrowsErrorAsync { try await queue.optOut() }

        let after = try await queue.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertTrue(context.access.fileExists(at: queue.queueFileURL))
        let restarted = try await context.queue().snapshot()
        XCTAssertEqual(restarted, before)
    }

    func testExplicitFeedbackQueuesWhileOffWithoutCreatingIdentity() async throws {
        let context = QueueTestContext()
        let queue = context.queue()

        let result = try await queue.enqueueFeedback(context.feedback())
        XCTAssertEqual(result, .enqueued)
        let snapshot = try await queue.snapshot()

        XCTAssertFalse(snapshot.consent.enabled)
        XCTAssertNil(snapshot.installID)
        XCTAssertEqual(snapshot.items.count, 1)
        guard case .feedback = snapshot.items[0] else { return XCTFail("Expected feedback") }
    }

    func testFailedAtomicWritePreservesDiskAndPublishedState() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        try await queue.enqueueFeedback(context.feedback(message: "first"))
        let beforeBytes = try context.access.read(from: queue.queueFileURL)
        let before = try await queue.snapshot()
        context.access.failWrites = true

        await XCTAssertThrowsErrorAsync {
            try await queue.enqueueFeedback(context.feedback(id: context.uuid(90), message: "second"))
        }

        XCTAssertEqual(try context.access.read(from: queue.queueFileURL), beforeBytes)
        let after = try await queue.snapshot()
        XCTAssertEqual(after, before)
    }

    func testCorruptAndFutureEnvelopeAreQuarantinedAndNeverPublished() async throws {
        for data in [Data("not-json".utf8), Data(#"{"schema_version":99,"items":["secret"]}"#.utf8)] {
            let context = QueueTestContext()
            let queue = context.queue()
            try context.access.createDirectory(at: queue.storageDirectory)
            try context.access.writeAtomically(data, to: queue.queueFileURL)

            let snapshot = try await queue.snapshot()

            XCTAssertTrue(snapshot.items.isEmpty)
            XCTAssertFalse(snapshot.consent.enabled)
            XCTAssertFalse(context.access.fileExists(at: queue.queueFileURL))
            XCTAssertEqual(context.access.quarantineFiles(in: queue.storageDirectory).count, 1)
            try await queue.optOut()
            XCTAssertTrue(context.access.quarantineFiles(in: queue.storageDirectory).isEmpty)
        }
    }

    func testThirtyDayRetentionBoundary() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        try await queue.enqueueFeedback(context.feedback())

        context.clock.date = context.clock.date.addingTimeInterval(TelemetryQueue.retentionInterval)
        let atBoundary = try await queue.snapshot()
        XCTAssertEqual(atBoundary.items.count, 1)
        context.clock.date = context.clock.date.addingTimeInterval(1)
        let expired = try await queue.snapshot()
        XCTAssertEqual(expired.items.count, 0)
    }

    func testFiveHundredItemBoundEvictsOldestHealthBeforeFeedback() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        let firstHealthID = context.uuid(1_000)
        for index in 0..<TelemetryQueue.maximumItems {
            try await queue.enqueueHealth(context.stageEvent(
                id: index == 0 ? firstHealthID : context.uuid(1_001 + index),
                installID: installID
            ))
        }

        let feedback = context.feedback(id: context.uuid(3_000))
        let result = try await queue.enqueueFeedback(feedback)
        XCTAssertEqual(result, .enqueued)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.count, TelemetryQueue.maximumItems)
        XCTAssertFalse(snapshot.items.contains(where: { $0.eventID == firstHealthID }))
        XCTAssertTrue(snapshot.items.contains(where: { $0.eventID == feedback.eventID }))
    }

    func testFeedbackCapacityNeverSilentlyEvictsFeedback() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        var acceptedIDs: [UUID] = []
        var rejected = false
        for index in 0..<TelemetryQueue.maximumItems + 1 {
            let feedback = context.feedback(
                id: context.uuid(5_000 + index),
                message: String(repeating: "🛡️", count: TelemetrySchema.maximumFeedbackCharacters)
            )
            do {
                try await queue.enqueueFeedback(feedback)
                acceptedIDs.append(feedback.eventID)
            } catch TelemetryQueueError.feedbackCapacityExceeded {
                rejected = true
                break
            }
        }
        let snapshot = try await queue.snapshot()
        XCTAssertTrue(rejected)
        XCTAssertFalse(acceptedIDs.isEmpty)
        XCTAssertEqual(Set(snapshot.items.map(\.eventID)), Set(acceptedIDs))
    }

    func testMilestoneAndWeeklyDedupeAreAtomic() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        let milestone = context.milestone(installID: installID)
        let milestoneResult = try await queue.enqueueHealth(milestone)
        XCTAssertEqual(milestoneResult, .enqueued)
        let repeatedMilestoneResult = try await queue.enqueueHealth(
            context.milestone(id: context.uuid(7_001), installID: installID)
        )
        XCTAssertEqual(repeatedMilestoneResult, .deduplicated)

        let week = try TelemetryWeekStart(rawValue: "2026-07-13")
        let weeklyResult = try await queue.enqueueHealth(
            context.weekly(installID: installID, week: week)
        )
        XCTAssertEqual(weeklyResult, .enqueued)
        let repeatedWeeklyResult = try await queue.enqueueHealth(
            context.weekly(id: context.uuid(7_002), installID: installID, week: week)
        )
        XCTAssertEqual(repeatedWeeklyResult, .deduplicated)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.weeklyMarker, week)
    }

    func testFailedMilestoneWriteDoesNotPublishMarker() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        context.access.failWrites = true
        await XCTAssertThrowsErrorAsync {
            try await queue.enqueueHealth(context.milestone(installID: installID))
        }
        context.access.failWrites = false

        let retryResult = try await queue.enqueueHealth(
            context.milestone(id: context.uuid(8_001), installID: installID)
        )
        XCTAssertEqual(retryResult, .enqueued)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.count, 1)
    }

    func testConcurrentActorEnqueuesHaveNoLostUpdates() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    _ = try await queue.enqueueFeedback(context.feedback(id: context.uuid(9_000 + index)))
                }
            }
            try await group.waitForAll()
        }
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.count, 100)
    }

    func testStorageIsUnderInjectedAppSupportAndNeverLibraryRoot() async throws {
        let context = QueueTestContext()
        let libraryRoot = context.root.appendingPathComponent("SelectedLibrary")
        let queue = context.queue()
        try await queue.enqueueFeedback(context.feedback())

        XCTAssertTrue(queue.storageDirectory.path.hasPrefix(context.appSupport.path))
        XCTAssertFalse(queue.storageDirectory.path.hasPrefix(libraryRoot.path))
        XCTAssertTrue(context.access.writtenURLs.allSatisfy { $0.path.hasPrefix(context.appSupport.path) })
    }

    func testStaleDeliveryGenerationCannotAcknowledgePostOptOutFeedback() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let firstFeedback = context.feedback()
        try await queue.enqueueFeedback(firstFeedback)
        let possibleStaleLease = try await queue.nextBatch()
        let staleLease = try XCTUnwrap(possibleStaleLease)

        try await queue.optOut()
        let newFeedback = context.feedback(id: context.uuid(10_001), message: "after opt out")
        try await queue.enqueueFeedback(newFeedback)
        let acknowledged = try await queue.acknowledge(
            staleLease,
            acceptedEventIDs: Set(staleLease.batch.items.map(\.eventID))
        )
        XCTAssertFalse(acknowledged)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.eventID), [newFeedback.eventID])
    }

    func testAcknowledgementOnlyRemovesAcceptedIDsFromItsLease() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let first = context.feedback(id: context.uuid(11_001), message: "first")
        let second = context.feedback(id: context.uuid(11_002), message: "second")
        let unleased = context.feedback(id: context.uuid(11_003), message: "unleased")
        try await queue.enqueueFeedback(first)
        try await queue.enqueueFeedback(second)
        let possibleLease = try await queue.nextBatch(maxItems: 2)
        let lease = try XCTUnwrap(possibleLease)
        try await queue.enqueueFeedback(unleased)

        let acknowledged = try await queue.acknowledge(
            lease,
            acceptedEventIDs: [first.eventID, unleased.eventID]
        )

        XCTAssertTrue(acknowledged)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.eventID), [second.eventID, unleased.eventID])
    }

    func testBatchPrioritizesBoundedFeedbackHeadThenHealthInClassOrder() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let installID = try await queue.enableConsent(version: 1)
        let healthOne = context.stageEvent(id: context.uuid(12_001), installID: installID)
        let healthTwo = context.stageEvent(id: context.uuid(12_002), installID: installID)
        try await queue.enqueueHealth(healthOne)
        try await queue.enqueueHealth(healthTwo)
        let feedback = (0..<5).map {
            context.feedback(id: context.uuid(12_100 + $0), message: "feedback \($0)")
        }
        for item in feedback { try await queue.enqueueFeedback(item) }

        let possibleLease = try await queue.nextBatch(maxItems: 5)
        let lease = try XCTUnwrap(possibleLease)

        XCTAssertEqual(
            lease.batch.items.map(\.eventID),
            feedback.prefix(3).map(\.eventID) + [healthOne.eventID, healthTwo.eventID]
        )
    }

    func testNearLimitMultibyteFeedbackReservesHealthWhenCombinedBatchFits() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let feedback = context.feedback(
            id: context.uuid(13_001),
            message: "a" + String(repeating: "\u{0301}", count: 30_000)
        )
        try await queue.enqueueFeedback(feedback)
        let installID = try await queue.enableConsent(version: 1)
        let health = context.stageEvent(id: context.uuid(13_002), installID: installID)
        try await queue.enqueueHealth(health)

        let possibleLease = try await queue.nextBatch(maxItems: 2)
        let lease = try XCTUnwrap(possibleLease)

        XCTAssertEqual(lease.batch.items.map(\.eventID), [feedback.eventID, health.eventID])
        XCTAssertLessThanOrEqual(
            try TelemetryJSON.encodeBatch(lease.batch).count,
            TelemetrySchema.maximumBatchBytes
        )
    }

    func testOversizedFeedbackDoesNotPreventLaterEligibleHealthFromBatching() async throws {
        let context = QueueTestContext()
        let queue = context.queue()
        let feedback = context.feedback(
            id: context.uuid(14_001),
            message: "a" + String(repeating: "\u{0301}", count: 40_000)
        )
        try await queue.enqueueFeedback(feedback)
        let installID = try await queue.enableConsent(version: 1)
        let health = context.stageEvent(id: context.uuid(14_002), installID: installID)
        try await queue.enqueueHealth(health)

        let possibleLease = try await queue.nextBatch(maxItems: 2)
        let lease = try XCTUnwrap(possibleLease)

        XCTAssertEqual(lease.batch.items.map(\.eventID), [health.eventID])
        XCTAssertLessThanOrEqual(
            try TelemetryJSON.encodeBatch(lease.batch).count,
            TelemetrySchema.maximumBatchBytes
        )
    }
}

private final class QueueTestContext: @unchecked Sendable {
    let root: URL
    let appSupport: URL
    let access = MemoryTelemetryQueueFileAccess()
    let clock = MutableTelemetryClock(date: Date(timeIntervalSince1970: 1_752_573_600))
    let ids: SequenceUUIDGenerator

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryQueueTests-\(UUID())")
        appSupport = root.appendingPathComponent("ApplicationSupport")
        ids = SequenceUUIDGenerator(values: (1...2_000).map { index in
            UUID(uuidString: String(format: "AAAAAAAA-AAAA-AAAA-AAAA-%012d", index))!
        })
    }

    func queue(
        invalidated: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) -> TelemetryQueue {
        TelemetryQueue(
            applicationSupportRoot: appSupport,
            fileAccess: access,
            clock: clock,
            uuidGenerator: ids,
            generationInvalidated: invalidated
        )
    }

    func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "BBBBBBBB-BBBB-BBBB-BBBB-%012d", index))!
    }

    func feedback(
        id: UUID? = nil,
        message: String = "Explicit feedback"
    ) -> TelemetryFeedback {
        try! TelemetryFeedback(
            eventID: id ?? uuid(1),
            occurredAt: telemetryTimestamp(for: clock.date),
            runtime: runtime(),
            category: .idea,
            message: message
        )
    }

    func milestone(id: UUID? = nil, installID: UUID) -> TelemetryHealthEvent {
        try! TelemetryHealthEvent(
            eventID: id ?? uuid(2),
            occurredAt: telemetryTimestamp(for: clock.date),
            runtime: runtime(),
            installID: installID,
            eventName: .firstRecordingCompleted
        )
    }

    func weekly(id: UUID? = nil, installID: UUID, week: TelemetryWeekStart) -> TelemetryHealthEvent {
        try! TelemetryHealthEvent(
            eventID: id ?? uuid(3),
            occurredAt: telemetryTimestamp(for: clock.date),
            runtime: runtime(),
            installID: installID,
            eventName: .weeklyActive,
            weekStart: week
        )
    }

    func stageEvent(id: UUID, installID: UUID) -> TelemetryHealthEvent {
        try! TelemetryHealthEvent(
            eventID: id,
            occurredAt: telemetryTimestamp(for: clock.date),
            runtime: runtime(),
            installID: installID,
            eventName: .stageOutcome,
            stage: .summary,
            outcome: .success,
            durationBucket: .oneToFiveSeconds
        )
    }

    private func runtime() -> TelemetryRuntimeContext {
        try! TelemetryRuntimeContext(appVersion: "1.4.6", appBuild: "1", osVersion: "14.2")
    }
}

private final class MemoryTelemetryQueueFileAccess: TelemetryQueueFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var directories: Set<URL> = []
    private var shouldFailWrites = false
    private var shouldFailNextMove = false
    private var shouldFailNextRemove = false
    private var storedWrittenURLs: [URL] = []

    var failWrites: Bool {
        get { lock.withLock { shouldFailWrites } }
        set { lock.withLock { shouldFailWrites = newValue } }
    }

    var writtenURLs: [URL] { lock.withLock { storedWrittenURLs } }

    var failNextMove: Bool {
        get { lock.withLock { shouldFailNextMove } }
        set { lock.withLock { shouldFailNextMove = newValue } }
    }

    var failNextRemove: Bool {
        get { lock.withLock { shouldFailNextRemove } }
        set { lock.withLock { shouldFailNextRemove = newValue } }
    }

    func createDirectory(at url: URL) throws { lock.withLock { _ = directories.insert(url) } }
    func fileExists(at url: URL) -> Bool { lock.withLock { files[url] != nil || directories.contains(url) } }
    func read(from url: URL) throws -> Data {
        try lock.withLock {
            guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return data
        }
    }
    func writeAtomically(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if shouldFailWrites { throw CocoaError(.fileWriteUnknown) }
            files[url] = data
            storedWrittenURLs.append(url)
        }
    }
    func move(from source: URL, to destination: URL) throws {
        try lock.withLock {
            if shouldFailNextMove {
                shouldFailNextMove = false
                throw CocoaError(.fileWriteUnknown)
            }
            if directories.remove(source) != nil {
                directories.insert(destination)
                let nestedDirectories = directories.filter { $0.path.hasPrefix(source.path + "/") }
                for directory in nestedDirectories {
                    directories.remove(directory)
                    directories.insert(rebased(directory, from: source, to: destination))
                }
                let nestedFiles = files.filter { $0.key.path.hasPrefix(source.path + "/") }
                for (url, data) in nestedFiles {
                    files.removeValue(forKey: url)
                    files[rebased(url, from: source, to: destination)] = data
                }
                return
            }
            guard let data = files.removeValue(forKey: source) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            files[destination] = data
        }
    }
    func remove(at url: URL) throws {
        try lock.withLock {
            if shouldFailNextRemove {
                shouldFailNextRemove = false
                throw CocoaError(.fileWriteUnknown)
            }
            _ = files.removeValue(forKey: url)
            if directories.remove(url) != nil {
                files = files.filter { !$0.key.path.hasPrefix(url.path + "/") }
                directories = directories.filter { !$0.path.hasPrefix(url.path + "/") }
            }
        }
    }
    func contents(of directory: URL) throws -> [URL] {
        lock.withLock { files.keys.filter { $0.deletingLastPathComponent() == directory } }
    }
    func quarantineFiles(in directory: URL) -> [URL] {
        lock.withLock {
            files.keys.filter {
                $0.deletingLastPathComponent() == directory && $0.lastPathComponent.hasPrefix("queue.quarantine.")
            }
        }
    }

    private func rebased(_ url: URL, from source: URL, to destination: URL) -> URL {
        let suffix = String(url.path.dropFirst(source.path.count + 1))
        return destination.appendingPathComponent(suffix)
    }
}

private final class MutableTelemetryClock: TelemetryQueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDate: Date
    init(date: Date) { storedDate = date }
    var date: Date {
        get { lock.withLock { storedDate } }
        set { lock.withLock { storedDate = newValue } }
    }
    func now() -> Date { date }
}

private final class SequenceUUIDGenerator: TelemetryUUIDGenerating, @unchecked Sendable {
    let values: [UUID]
    private let lock = NSLock()
    private var index = 0
    init(values: [UUID]) { self.values = values }
    func next() -> UUID {
        lock.withLock {
            defer { index += 1 }
            return values[index % values.count]
        }
    }
}

private final class Invalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt64] = []
    var values: [UInt64] { lock.withLock { stored } }
    func append(_ value: UInt64) { lock.withLock { stored.append(value) } }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch { }
}
