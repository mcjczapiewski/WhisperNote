import XCTest
@testable import WhisperNote

final class UnifiedSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroupingCollapsesMembersAndAggregatesArtifactsMetadataAndDestination() {
        let groupID = id(10), firstID = id(11), secondID = id(12), transcriptID = id(13), summaryID = id(14), tagID = id(15)
        let recordings = [
            recording(firstID, "First member", daysAgo: 3, groupID: groupID, groupName: "Launch Group"),
            recording(secondID, "Second member", daysAgo: 2, groupID: groupID, groupName: "Launch Group")
        ]
        let transcript = self.transcript(transcriptID, "Transcript", recordingID: groupID, content: "alpha transcript phrase", daysAgo: 1)
        let summary = self.summary(summaryID, "Decision memo", transcriptID: transcriptID, content: "approved launch", daysAgo: 0)
        let metadata = LibraryMetadataEnvelope(
            tags: [LibraryTag(id: tagID, name: "Priority")],
            items: [
                LibraryItemMetadata(key: .init(kind: .recording, id: secondID), isFavorite: true, tagIDs: [tagID]),
                LibraryItemMetadata(key: .init(kind: .summary, id: summaryID), tagIDs: [tagID])
            ]
        )
        let index = UnifiedSearchIndex(recordings: recordings, transcripts: [transcript], summaries: [summary], jobs: [], metadata: metadata)

        let result = index.search(.init(text: "approved launch", favoritesOnly: true, tagIDs: [tagID]), now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, .group(groupID))
        XCTAssertEqual(result[0].title, "Launch Group")
        XCTAssertEqual(result[0].destination, .summary(summaryID))
        XCTAssertEqual(result[0].tags.map(\.name), ["Priority"])
        XCTAssertEqual(result[0].status, .completed)
    }

    func testTranscriptMissingRecordingAndSummaryMissingTranscriptHaveTypedOrphanRoots() {
        let staleTranscript = transcript(id(20), "Lost transcript", recordingID: id(21), content: "recoverable words")
        let siblingTranscript = transcript(id(25), "Second attempt", recordingID: staleTranscript.recordingId, content: "shared root")
        let attachedSummary = summary(id(22), "Attached summary", transcriptID: staleTranscript.id, content: "still attached")
        let orphanSummary = summary(id(23), "Detached summary", transcriptID: id(24), content: "missing transcript")
        let index = UnifiedSearchIndex(recordings: [], transcripts: [staleTranscript, siblingTranscript], summaries: [attachedSummary, orphanSummary], jobs: [], metadata: .init())

        let transcriptResult = index.search(.init(text: "still attached"), now: now).first
        XCTAssertEqual(transcriptResult?.key, .recording(staleTranscript.recordingId))
        XCTAssertEqual(transcriptResult?.destination, .summary(attachedSummary.id))
        XCTAssertEqual(transcriptResult?.isOrphan, true)
        XCTAssertEqual(transcriptResult?.isStale, true)
        XCTAssertEqual(transcriptResult?.status, .needsAttention)
        XCTAssertEqual(index.search(.init(text: "recoverable shared"), now: now).map(\.key), [.recording(staleTranscript.recordingId)])

        let summaryResult = index.search(.init(text: "missing transcript"), now: now).first
        XCTAssertEqual(summaryResult?.key, .orphanSummary(orphanSummary.id))
        XCTAssertEqual(summaryResult?.destination, .summary(orphanSummary.id))
    }

    func testNormalizationAndANDTermsCanSpanArtifactsAndTags() {
        let recordingID = id(30), transcriptID = id(31), summaryID = id(32), tagID = id(33)
        let index = UnifiedSearchIndex(
            recordings: [recording(recordingID, "Ｃａｆé Planning")],
            transcripts: [transcript(transcriptID, "Transcript", recordingID: recordingID, content: "budget")],
            summaries: [summary(summaryID, "Summary", transcriptID: transcriptID, content: "timeline")],
            jobs: [],
            metadata: .init(tags: [.init(id: tagID, name: "Déjà Vu")], items: [.init(key: .init(kind: .recording, id: recordingID), tagIDs: [tagID])])
        )

        XCTAssertEqual(index.search(.init(text: "CAFE budget timeline deja"), now: now).map(\.key), [.recording(recordingID)])
        XCTAssertTrue(index.search(.init(text: "cafe absent"), now: now).isEmpty)
    }

    func testContentMatchesIncludeOneSentencePreviewForEveryOccurrence() {
        let recordingID = id(34), transcriptID = id(35)
        let content = "First context. Alpha decision recorded. Middle context. Alpha decision confirmed. Final context."
        let index = UnifiedSearchIndex(
            recordings: [recording(recordingID, "Meeting")],
            transcripts: [transcript(
                transcriptID,
                "Transcript",
                recordingID: recordingID,
                content: content
            )],
            summaries: [], jobs: [], metadata: .init()
        )

        let previews = index.search(.init(text: "alpha decision"), now: now).first?.previews
        XCTAssertEqual(previews?.count, 2)
        XCTAssertEqual(previews?.first?.match, "Alpha decision recorded.")
        XCTAssertEqual(previews?.first?.matchIndex, 1)
        XCTAssertEqual(previews?.first?.location, (content as NSString).range(of: "Alpha decision recorded.").location)
        XCTAssertEqual(previews?.last?.match, "Alpha decision confirmed.")
        XCTAssertEqual(previews?.last?.matchIndex, 3)
        XCTAssertEqual(previews?.last?.location, (content as NSString).range(of: "Alpha decision confirmed.").location)
    }

    func testFiltersFavoriteStatusesDatesCustomAndTags() {
        let favoriteID = id(40), processingID = id(41), failedID = id(42), oldID = id(43), tagID = id(44)
        var activeJob = job(recordingID: processingID, name: "Processing", state: .transcribing)
        activeJob.updatedAt = now
        let metadata = LibraryMetadataEnvelope(
            tags: [.init(id: tagID, name: "Work")],
            items: [.init(key: .init(kind: .recording, id: favoriteID), isFavorite: true, tagIDs: [tagID])]
        )
        let index = UnifiedSearchIndex(
            recordings: [
                recording(favoriteID, "Today done", daysAgo: 0),
                recording(processingID, "Processing", daysAgo: 3),
                recording(failedID, "Failed", daysAgo: 20),
                recording(oldID, "Old raw", daysAgo: 60)
            ],
            transcripts: [
                transcript(id(45), "Done", recordingID: favoriteID, status: .completed, daysAgo: 0),
                transcript(id(46), "Failed", recordingID: failedID, status: .failed, daysAgo: 20)
            ],
            summaries: [], jobs: [activeJob], metadata: metadata
        )

        XCTAssertEqual(index.search(.init(favoritesOnly: true), now: now).map(\.key), [.recording(favoriteID)])
        XCTAssertEqual(index.search(.init(status: .processing), now: now).map(\.key), [.recording(processingID)])
        XCTAssertEqual(index.search(.init(status: .needsAttention), now: now).map(\.key), [.recording(failedID)])
        XCTAssertEqual(index.search(.init(status: .unprocessed), now: now).map(\.key), [.recording(oldID)])
        XCTAssertEqual(index.search(.init(status: .completed, tagIDs: [tagID]), now: now).map(\.key), [.recording(favoriteID)])
        XCTAssertEqual(Set(index.search(.init(date: .last7Days), now: now).map(\.key)), [.recording(favoriteID), .recording(processingID)])
        XCTAssertEqual(index.search(.init(date: .last30Days), now: now).count, 3)
        XCTAssertEqual(index.search(.init(date: .custom(date(daysAgo: 25), date(daysAgo: 15))), now: now).map(\.key), [.recording(failedID)])
    }

    func testRankingBucketsThenNewestAndStableTypedKey() {
        let exact = id(50), prefix = id(51), contains = id(52), tag = id(53), content = id(54), tagID = id(55)
        let recordings = [
            recording(exact, "alpha", daysAgo: 10), recording(prefix, "alpha plan", daysAgo: 0),
            recording(contains, "project alpha note", daysAgo: 0), recording(tag, "Tagged", daysAgo: 0),
            recording(content, "Content", daysAgo: 0)
        ]
        let metadata = LibraryMetadataEnvelope(tags: [.init(id: tagID, name: "alpha")], items: [.init(key: .init(kind: .recording, id: tag), tagIDs: [tagID])])
        let index = UnifiedSearchIndex(
            recordings: recordings,
            transcripts: [transcript(id(56), "Words", recordingID: content, content: "alpha")],
            summaries: [], jobs: [], metadata: metadata
        )
        XCTAssertEqual(index.search(.init(text: "alpha"), now: now).map(\.key), [
            .recording(exact), .recording(prefix), .recording(contains), .recording(tag), .recording(content)
        ])

        let sameDate = date(daysAgo: 0)
        let stableA = Recording(id: id(1), name: "same", date: sameDate, duration: 1, filePath: URL(fileURLWithPath: "/a"))
        let stableB = Recording(id: id(2), name: "same", date: sameDate, duration: 1, filePath: URL(fileURLWithPath: "/b"))
        let stable = UnifiedSearchIndex(recordings: [stableB, stableA], transcripts: [], summaries: [], jobs: [], metadata: .init())
        XCTAssertEqual(stable.search(.init(), now: now).map(\.key), [.recording(stableA.id), .recording(stableB.id)])
    }

    func testFallbackPrefersNewestCompletedSummaryThenTranscriptThenRoot() {
        let recordingID = id(60), transcriptID = id(61), oldSummary = id(62), newSummary = id(63)
        let index = UnifiedSearchIndex(
            recordings: [recording(recordingID, "Recording")],
            transcripts: [transcript(transcriptID, "Transcript", recordingID: recordingID, daysAgo: 2)],
            summaries: [
                summary(oldSummary, "Old", transcriptID: transcriptID, daysAgo: 1),
                summary(newSummary, "New", transcriptID: transcriptID, daysAgo: 0)
            ], jobs: [], metadata: .init()
        )
        XCTAssertEqual(index.search(.init(), now: now).first?.destination, .summary(newSummary))

        let noSummary = UnifiedSearchIndex(recordings: [recording(recordingID, "Recording")], transcripts: [transcript(transcriptID, "Transcript", recordingID: recordingID)], summaries: [], jobs: [], metadata: .init())
        XCTAssertEqual(noSummary.search(.init(), now: now).first?.destination, .transcript(transcriptID))

        let raw = UnifiedSearchIndex(recordings: [recording(recordingID, "Recording")], transcripts: [], summaries: [], jobs: [], metadata: .init())
        XCTAssertEqual(raw.search(.init(), now: now).first?.destination, .recording(recordingID))
    }

    func testRebuildReflectsEditsAndDeletedRelationshipsDoNotLeak() {
        let recordingID = id(70), tagID = id(71)
        let originalMetadata = LibraryMetadataEnvelope(tags: [.init(id: tagID, name: "Original")], items: [.init(key: .init(kind: .recording, id: recordingID), isFavorite: true, tagIDs: [tagID])])
        let original = UnifiedSearchIndex(recordings: [recording(recordingID, "Before")], transcripts: [], summaries: [], jobs: [], metadata: originalMetadata)
        XCTAssertEqual(original.search(.init(text: "before", favoritesOnly: true), now: now).count, 1)

        let rebuilt = UnifiedSearchIndex(recordings: [recording(recordingID, "After")], transcripts: [], summaries: [], jobs: [], metadata: .init())
        XCTAssertTrue(rebuilt.search(.init(text: "before"), now: now).isEmpty)
        XCTAssertEqual(rebuilt.search(.init(text: "after"), now: now).count, 1)
        XCTAssertTrue(rebuilt.search(.init(favoritesOnly: true), now: now).isEmpty)

        let deleted = UnifiedSearchIndex(recordings: [], transcripts: [], summaries: [], jobs: [], metadata: originalMetadata)
        XCTAssertTrue(deleted.search(.init(), now: now).isEmpty)
    }

    func testDuplicateArtifactAndTagIdentifiersAreDeterministicAndNeverTrap() {
        let sharedRecordingID = id(80), sharedTranscriptID = id(81), tagID = id(82)
        let first = recording(sharedRecordingID, "First recording")
        let duplicate = recording(sharedRecordingID, "Duplicate recording", groupID: id(83), groupName: "Wrong group")
        let firstTranscript = transcript(sharedTranscriptID, "First transcript", recordingID: sharedRecordingID, content: "first content")
        let duplicateTranscript = transcript(sharedTranscriptID, "Duplicate transcript", recordingID: id(84), content: "duplicate content")
        let attachedSummary = summary(id(85), "Attached", transcriptID: sharedTranscriptID, content: "kept relationship")
        let metadata = LibraryMetadataEnvelope(
            tags: [.init(id: tagID, name: "First tag"), .init(id: tagID, name: "Duplicate tag")],
            items: [.init(key: .init(kind: .recording, id: sharedRecordingID), tagIDs: [tagID])]
        )

        let index = UnifiedSearchIndex(
            recordings: [first, duplicate],
            transcripts: [firstTranscript, duplicateTranscript],
            summaries: [attachedSummary], jobs: [], metadata: metadata
        )

        XCTAssertEqual(index.search(.init(text: "kept relationship"), now: now).first?.key, .recording(sharedRecordingID))
        XCTAssertEqual(index.search(.init(text: "first tag"), now: now).first?.tags.map(\.name), ["First tag"])
    }

    func testGroupMetadataSurvivesDeletionOfTheOriginallyTaggedMember() {
        let groupID = id(90), firstID = id(91), remainingID = id(92), tagID = id(93)
        let metadata = LibraryMetadataEnvelope(
            tags: [.init(id: tagID, name: "Group tag")],
            items: [.init(key: .init(kind: .group, id: groupID), isFavorite: true, tagIDs: [tagID])]
        )
        let original = UnifiedSearchIndex(
            recordings: [
                recording(firstID, "First", groupID: groupID, groupName: "Stable group"),
                recording(remainingID, "Remaining", groupID: groupID, groupName: "Stable group")
            ], transcripts: [], summaries: [], jobs: [], metadata: metadata
        )
        XCTAssertEqual(original.search(.init(favoritesOnly: true, tagIDs: [tagID]), now: now).count, 1)

        let afterDeletion = UnifiedSearchIndex(
            recordings: [recording(remainingID, "Remaining", groupID: groupID, groupName: "Stable group")],
            transcripts: [], summaries: [], jobs: [], metadata: metadata
        )
        XCTAssertEqual(afterDeletion.search(.init(favoritesOnly: true, tagIDs: [tagID]), now: now).first?.key, .group(groupID))
    }

    func testTenThousandCombinedArtifactsPerformance() throws {
        #if DEBUG
        throw XCTSkip("Run the 10k threshold benchmark in Release mode to avoid debug-build noise")
        #else
        let count = 3_334
        var recordings: [Recording] = [], transcripts: [Transcript] = [], summaries: [Summary] = []
        recordings.reserveCapacity(count); transcripts.reserveCapacity(count); summaries.reserveCapacity(count)
        for value in 0..<count {
            let recordingID = benchmarkID(value * 3), transcriptID = benchmarkID(value * 3 + 1), summaryID = benchmarkID(value * 3 + 2)
            recordings.append(Recording(id: recordingID, name: "Meeting \(value)", date: now.addingTimeInterval(Double(-value)), duration: 60, filePath: URL(fileURLWithPath: "/\(value)")))
            transcripts.append(Transcript(id: transcriptID, name: "Transcript \(value)", date: now, content: "roadmap alpha \(value)", recordingId: recordingID, status: .completed))
            summaries.append(Summary(id: summaryID, name: "Summary \(value)", date: now, content: "decision beta \(value)", transcriptId: transcriptID, model: "test", prompt: "", status: .completed))
        }
        var rebuildSamples: [TimeInterval] = [], querySamples: [TimeInterval] = []
        var index: UnifiedSearchIndex?
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            index = UnifiedSearchIndex(recordings: recordings, transcripts: transcripts, summaries: summaries, jobs: [], metadata: .init())
            rebuildSamples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        _ = index?.search(.init(text: "roadmap decision"), now: now)
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = index?.search(.init(text: "roadmap decision"), now: now)
            querySamples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let rebuildP95 = percentile95(rebuildSamples), queryP95 = percentile95(querySamples)
        print("UnifiedSearch 10k: rebuild p95=\(rebuildP95)s, warm query p95=\(queryP95)s")
        XCTAssertLessThanOrEqual(rebuildP95, 1.0)
        XCTAssertLessThanOrEqual(queryP95, 0.1)
        #endif
    }

    private func recording(_ id: UUID, _ name: String, daysAgo: Int = 0, groupID: UUID? = nil, groupName: String? = nil) -> Recording {
        Recording(id: id, name: name, date: date(daysAgo: daysAgo), duration: 60, filePath: URL(fileURLWithPath: "/\(id)"), groupId: groupID, groupName: groupName)
    }

    private func transcript(_ id: UUID, _ name: String, recordingID: UUID, content: String = "", status: ProcessingStatus = .completed, daysAgo: Int = 0) -> Transcript {
        Transcript(id: id, name: name, date: date(daysAgo: daysAgo), content: content, recordingId: recordingID, status: status)
    }

    private func summary(_ id: UUID, _ name: String, transcriptID: UUID, content: String = "", daysAgo: Int = 0) -> Summary {
        Summary(id: id, name: name, date: date(daysAgo: daysAgo), content: content, transcriptId: transcriptID, model: "test", prompt: "", status: .completed)
    }

    private func job(recordingID: UUID, name: String, state: ProcessingJobState) -> ProcessingJob {
        var value = ProcessingJob(recordingID: recordingID, recordingName: name, snapshot: .init(language: "eng", shouldSummarize: true, modelID: "test", templateID: "test", prompt: "", shouldNotify: false), now: now)
        value.state = state
        return value
    }

    private func date(daysAgo: Int) -> Date { now.addingTimeInterval(Double(-daysAgo * 86_400)) }
    private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    private func benchmarkID(_ value: Int) -> UUID { id(value + 1_000) }

    #if !DEBUG
    private func percentile95(_ samples: [TimeInterval]) -> TimeInterval {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    #endif
}
