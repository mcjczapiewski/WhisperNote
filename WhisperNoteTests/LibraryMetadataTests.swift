import XCTest
@testable import WhisperNote

final class LibraryMetadataTests: XCTestCase {
    func testMissingFileStartsWithCurrentEmptySchemaAndRoundTripsTypedKeys() async throws {
        let context = try Context()
        let repository = context.repository
        let empty = try await repository.snapshot()
        XCTAssertEqual(empty, LibraryMetadataEnvelope())

        let sharedID = UUID()
        let recording = LibraryItemKey(kind: .recording, id: sharedID)
        let transcript = LibraryItemKey(kind: .transcript, id: sharedID)
        let tag = try await repository.createTag(name: " Project Alpha ")
        try await repository.assignTag(id: tag.id, to: recording)
        try await repository.setFavorite(true, for: transcript)

        let reloaded = LibraryMetadataRepository(fileURL: context.url)
        let recordingMetadata = try await reloaded.metadata(for: recording)
        let transcriptMetadata = try await reloaded.metadata(for: transcript)
        XCTAssertEqual(recordingMetadata.tagIDs, [tag.id])
        XCTAssertFalse(recordingMetadata.isFavorite)
        XCTAssertTrue(transcriptMetadata.isFavorite)
    }

    func testBackwardCompatibleMissingOptionalFieldsUseDefaults() async throws {
        let context = try Context()
        let key = LibraryItemKey(kind: .summary, id: UUID())
        let keyData = try JSONEncoder().encode(key)
        let keyJSON = try XCTUnwrap(String(data: keyData, encoding: .utf8))
        try Data("{\"items\":[{\"key\":\(keyJSON)}]}".utf8).write(to: context.url)

        let snapshot = try await context.repository.snapshot()
        XCTAssertEqual(snapshot.version, LibraryMetadataEnvelope.currentVersion)
        XCTAssertEqual(snapshot.tags, [])
        XCTAssertEqual(snapshot.items, [LibraryItemMetadata(key: key)])
    }

    func testCorruptFileIsPreservedAndErrorSurfaced() async throws {
        let context = try Context()
        let original = Data("not-json".utf8)
        try original.write(to: context.url)

        do {
            _ = try await context.repository.snapshot()
            XCTFail("Expected corrupt metadata error")
        } catch is LibraryMetadataRepositoryError {}
        XCTAssertEqual(try Data(contentsOf: context.url), original)
    }

    func testFailedAtomicWriteLeavesOldFileIntact() async throws {
        let context = try Context()
        let old = try JSONEncoder().encode(LibraryMetadataEnvelope())
        try old.write(to: context.url)
        let repository = LibraryMetadataRepository(
            fileURL: context.url,
            fileAccess: FailingWriteFileAccess()
        )

        do {
            _ = try await repository.createTag(name: "Cannot Save")
            XCTFail("Expected write error")
        } catch is LibraryMetadataRepositoryError {}
        XCTAssertEqual(try Data(contentsOf: context.url), old)
    }

    func testTagUniquenessIsCaseDiacriticWidthAndWhitespaceInsensitive() async throws {
        let context = try Context()
        _ = try await context.repository.createTag(name: "  Café   Notes ")
        for duplicate in ["cafe notes", "CAFE NOTES", "Ｃａｆｅ　Ｎｏｔｅｓ"] {
            do {
                _ = try await context.repository.createTag(name: duplicate)
                XCTFail("Expected duplicate for \(duplicate)")
            } catch LibraryMetadataRepositoryError.duplicateTagName {}
        }
        let snapshot = try await context.repository.snapshot()
        XCTAssertEqual(snapshot.tags.map(\.name), ["Café Notes"])
    }

    func testRenameAndDeleteCascadeAssignments() async throws {
        let context = try Context()
        let key = LibraryItemKey(kind: .recording, id: UUID())
        let tag = try await context.repository.createTag(name: "Old")
        try await context.repository.assignTag(id: tag.id, to: key)
        let renamed = try await context.repository.renameTag(id: tag.id, to: "New Name")
        XCTAssertEqual(renamed.name, "New Name")
        let assignedMetadata = try await context.repository.metadata(for: key)
        XCTAssertEqual(assignedMetadata.tagIDs, [tag.id])

        try await context.repository.deleteTag(id: tag.id)
        let snapshot = try await context.repository.snapshot()
        XCTAssertEqual(snapshot.tags, [])
        XCTAssertEqual(snapshot.items, [])
    }

    func testConcurrentMutationsHaveNoLostUpdatesAndAssignmentsAreIdempotent() async throws {
        let context = try Context()
        let key = LibraryItemKey(kind: .summary, id: UUID())
        let tags = try await withThrowingTaskGroup(of: LibraryTag.self) { group in
            for index in 0..<20 {
                group.addTask { try await context.repository.createTag(name: "Tag \(index)") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for tag in tags {
                group.addTask {
                    try await context.repository.assignTag(id: tag.id, to: key)
                    try await context.repository.assignTag(id: tag.id, to: key)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await context.repository.snapshot()
        let metadata = try await context.repository.metadata(for: key)
        XCTAssertEqual(snapshot.tags.count, 20)
        XCTAssertEqual(metadata.tagIDs, Set(tags.map(\.id)))
    }

    func testReconcileUnknownTagsAndOnlyPrunesArtifactsWithAuthoritativeSet() async throws {
        let context = try Context()
        let keep = LibraryItemKey(kind: .recording, id: UUID())
        let remove = LibraryItemKey(kind: .transcript, id: UUID())
        let known = LibraryTag(name: "Known")
        let unknownID = UUID()
        let envelope = LibraryMetadataEnvelope(
            tags: [known],
            items: [
                LibraryItemMetadata(key: keep, isFavorite: true, tagIDs: [known.id, unknownID]),
                LibraryItemMetadata(key: remove, tagIDs: [unknownID])
            ]
        )
        try JSONEncoder().encode(envelope).write(to: context.url)

        try await context.repository.reconcile()
        var snapshot = try await context.repository.snapshot()
        let keptMetadata = try await context.repository.metadata(for: keep)
        let retainedMetadata = try await context.repository.metadata(for: remove)
        XCTAssertEqual(Set(snapshot.items.map(\.key)), [keep, remove])
        XCTAssertEqual(keptMetadata.tagIDs, [known.id])
        XCTAssertEqual(retainedMetadata.tagIDs, [])

        try await context.repository.reconcile(existingItemKeys: [keep])
        snapshot = try await context.repository.snapshot()
        XCTAssertEqual(snapshot.items.map(\.key), [keep])
    }

    func testReconcilePreservesStableGroupMetadataWhileGroupExists() async throws {
        let context = try Context()
        let group = LibraryItemKey(kind: .group, id: UUID())
        let deletedMember = LibraryItemKey(kind: .recording, id: UUID())
        try await context.repository.setFavorite(true, for: group)
        try await context.repository.setFavorite(true, for: deletedMember)

        try await context.repository.reconcile(existingItemKeys: [group])

        let snapshot = try await context.repository.snapshot()
        XCTAssertEqual(snapshot.items, [LibraryItemMetadata(key: group, isFavorite: true)])
    }

    func testReconcileMigratesLegacyMemberMetadataToStableGroupKey() async throws {
        let context = try Context()
        let groupID = UUID()
        let group = LibraryItemKey(kind: .group, id: groupID)
        let legacyMember = LibraryItemKey(kind: .recording, id: UUID())
        let tag = try await context.repository.createTag(name: "Migrated")
        try await context.repository.setFavorite(true, for: legacyMember)
        try await context.repository.assignTag(id: tag.id, to: legacyMember)

        try await context.repository.reconcile(
            existingItemKeys: [group, legacyMember],
            logicalGroupByItemKey: [legacyMember: groupID]
        )
        try await context.repository.reconcile(existingItemKeys: [group])

        let migrated = try await context.repository.metadata(for: group)
        XCTAssertTrue(migrated.isFavorite)
        XCTAssertEqual(migrated.tagIDs, [tag.id])
        let removedLegacyMetadata = try await context.repository.metadata(for: legacyMember)
        XCTAssertEqual(removedLegacyMetadata, .init(key: legacyMember))

        try await context.repository.setFavorite(false, for: group)
        try await context.repository.removeTag(id: tag.id, from: group)
        try await context.repository.reconcile(
            existingItemKeys: [group],
            logicalGroupByItemKey: [legacyMember: groupID]
        )
        let cleared = try await context.repository.metadata(for: group)
        XCTAssertFalse(cleared.isFavorite)
        XCTAssertTrue(cleared.tagIDs.isEmpty, "Cleared metadata must not resurrect from a migrated legacy row")
    }
}

private struct Context {
    let directory: URL
    let url: URL
    let repository: LibraryMetadataRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("library-metadata.json")
        repository = LibraryMetadataRepository(fileURL: url)
    }
}

private struct FailingWriteFileAccess: LibraryMetadataFileAccess {
    struct ExpectedFailure: Error {}

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        throw ExpectedFailure()
    }
}
