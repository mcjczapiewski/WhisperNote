import XCTest
@testable import WhisperNote

final class SummaryTemplateRepositoryTests: XCTestCase {
    func testFirstLoadSeedsFiveStablePresetsAndMeetingMinutesDefault() async throws {
        let context = try Context()
        let templates = try await context.repository.templates()

        XCTAssertEqual(templates.count, 5)
        XCTAssertEqual(templates.map(\.presetID), [
            "meeting-minutes-v1",
            "action-items-v1",
            "client-follow-up-v1",
            "interview-notes-v1",
            "learning-notes-v1"
        ])
        XCTAssertEqual(templates.map(\.id), SummaryTemplatePresetCatalog.presets.map(\.id))
        XCTAssertEqual(templates.map(\.sortOrder), Array(0..<5))
        XCTAssertEqual(templates.filter(\.isDefault).map(\.presetID), ["meeting-minutes-v1"])
        let notice = await context.repository.consumeNotice()
        XCTAssertNil(notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.url.path))
    }

    @MainActor
    func testMeetingMinutesPromptMatchesSummaryManagerByteForByte() throws {
        let defaults = UserDefaults.standard
        let priorPath = defaults.object(forKey: "recordingsDirectory")
        let priorBookmark = defaults.object(forKey: "recordingsDirectoryBookmark")
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryPromptParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defaults.removeObject(forKey: "recordingsDirectoryBookmark")
        defaults.set(temporaryRoot.path, forKey: "recordingsDirectory")
        defer {
            if let priorPath { defaults.set(priorPath, forKey: "recordingsDirectory") }
            else { defaults.removeObject(forKey: "recordingsDirectory") }
            if let priorBookmark { defaults.set(priorBookmark, forKey: "recordingsDirectoryBookmark") }
            else { defaults.removeObject(forKey: "recordingsDirectoryBookmark") }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        XCTAssertEqual(
            SummaryTemplatePresetCatalog.meetingMinutesPrompt,
            SummaryManager().getDefaultPrompt()
        )
        let expectedURL = temporaryRoot
            .appendingPathComponent("WhisperNote/Files/Templates", isDirectory: true)
            .appendingPathComponent("summary-templates.json")
        XCTAssertEqual(DirectoryManager.shared.getSummaryTemplatesURL(), expectedURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expectedURL.deletingLastPathComponent().path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDirectoryManagerBuildsLockedTemplatesPath() {
        let base = URL(fileURLWithPath: "/tmp/WhisperNote/Files", isDirectory: true)
        XCTAssertEqual(
            DirectoryManager.summaryTemplatesURL(baseDirectory: base).path,
            "/tmp/WhisperNote/Files/Templates/summary-templates.json"
        )
    }

    func testRepeatedLoadIsIdempotentAndStable() async throws {
        let context = try Context()
        let first = try await context.repository.templates()
        let firstBytes = try Data(contentsOf: context.url)

        let secondRepository = SummaryTemplateRepository(fileURL: context.url)
        let second = try await secondRepository.templates()

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: context.url), firstBytes)
    }

    func testPresetRevisionUpsertKeepsDurableUUIDDefaultAndUserCopyUntouched() async throws {
        let context = try Context()
        let seeded = try await context.repository.templates()
        let meeting = try XCTUnwrap(seeded.first(where: { $0.presetID == SummaryTemplatePresetCatalog.meetingMinutesID }))
        let copyID = UUID()
        let copy = try await context.repository.duplicate(id: meeting.id, newID: copyID)
        _ = try await context.repository.update(id: copy.id, name: "My Minutes", prompt: "My independent prompt")

        var envelope = try decodeEnvelope(at: context.url)
        let presetIndex = try XCTUnwrap(envelope.templates.firstIndex(where: { $0.presetID == SummaryTemplatePresetCatalog.meetingMinutesID }))
        envelope.templates[presetIndex].prompt = "old preset revision"
        envelope.templates[presetIndex].name = "Old Preset Name"
        try encodeEnvelope(envelope, to: context.url)

        let reloaded = SummaryTemplateRepository(fileURL: context.url)
        let templates = try await reloaded.templates()
        let updatedPreset = try XCTUnwrap(templates.first(where: { $0.presetID == SummaryTemplatePresetCatalog.meetingMinutesID }))
        let preservedCopy = try XCTUnwrap(templates.first(where: { $0.id == copyID }))
        XCTAssertEqual(updatedPreset.id, meeting.id)
        XCTAssertEqual(updatedPreset.prompt, SummaryTemplatePresetCatalog.meetingMinutesPrompt)
        XCTAssertEqual(updatedPreset.name, "Meeting Minutes")
        XCTAssertTrue(updatedPreset.isDefault)
        XCTAssertEqual(preservedCopy.name, "My Minutes")
        XCTAssertEqual(preservedCopy.prompt, "My independent prompt")
        XCTAssertNil(preservedCopy.presetID)
    }

    func testCRUDDuplicateDefaultDeleteFallbackAndOneShotNoticeRoundTrip() async throws {
        let context = try Context()
        _ = try await context.repository.templates()
        let customID = UUID()
        let createdAt = Date(timeIntervalSince1970: 10.123456)
        let updatedAt = Date(timeIntervalSince1970: 20.654321)
        let created = try await context.repository.create(
            name: "  Weekly   Review  ",
            prompt: "  Review the week.  ",
            id: customID,
            now: createdAt
        )
        XCTAssertEqual(created.name, "Weekly Review")
        XCTAssertEqual(created.prompt, "Review the week.")
        let updated = try await context.repository.update(
            id: customID,
            name: "Weekly Digest",
            prompt: "Updated prompt",
            now: updatedAt
        )
        XCTAssertEqual(updated.id, customID)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)

        let duplicate = try await context.repository.duplicate(id: customID, newID: UUID())
        XCTAssertEqual(duplicate.name, "Weekly Digest Copy")
        XCTAssertEqual(duplicate.prompt, "Updated prompt")
        XCTAssertNil(duplicate.presetID)
        try await context.repository.setDefault(id: customID)
        let selectedCustom = try await context.repository.defaultTemplate()
        XCTAssertEqual(selectedCustom.id, customID)

        try await context.repository.delete(id: customID)
        let fallbackDefault = try await context.repository.defaultTemplate()
        let fallbackNotice = await context.repository.consumeNotice()
        let consumedNotice = await context.repository.consumeNotice()
        XCTAssertEqual(fallbackDefault.presetID, SummaryTemplatePresetCatalog.meetingMinutesID)
        XCTAssertEqual(fallbackNotice, .defaultChangedToMeetingMinutes)
        XCTAssertNil(consumedNotice)

        let reloaded = SummaryTemplateRepository(fileURL: context.url)
        let reloadedTemplates = try await reloaded.templates()
        XCTAssertFalse(reloadedTemplates.contains(where: { $0.id == customID }))
        let reloadedDuplicate = try XCTUnwrap(reloadedTemplates.first(where: { $0.id == duplicate.id }))
        XCTAssertEqual(reloadedDuplicate.createdAt, duplicate.createdAt)
        XCTAssertEqual(reloadedDuplicate.updatedAt, duplicate.updatedAt)
        XCTAssertEqual(reloadedTemplates.filter(\.isDefault).count, 1)
    }

    func testBuiltInsAreImmutableAndNondeletableButDuplicable() async throws {
        let context = try Context()
        let templates = try await context.repository.templates()
        let meeting = try XCTUnwrap(templates.first)

        await assertThrowsBuiltIn { try await context.repository.update(id: meeting.id, name: "Changed", prompt: "Changed") }
        await assertThrowsBuiltIn { try await context.repository.delete(id: meeting.id) }
        let copy = try await context.repository.duplicate(id: meeting.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNil(copy.presetID)
        XCTAssertEqual(copy.prompt, meeting.prompt)
    }

    func testCustomReorderKeepsCanonicalPresetSectionAndPersistsContiguousOrder() async throws {
        let context = try Context()
        _ = try await context.repository.templates()
        let one = try await context.repository.create(name: "One", prompt: "One")
        let two = try await context.repository.create(name: "Two", prompt: "Two")
        let three = try await context.repository.create(name: "Three", prompt: "Three")

        try await context.repository.reorderCustomTemplates(ids: [three.id, one.id, two.id])
        let templates = try await context.repository.templates()
        XCTAssertEqual(Array(templates.prefix(5)).map(\.presetID), SummaryTemplatePresetCatalog.presets.map(\.presetID))
        XCTAssertEqual(Array(templates.dropFirst(5)).map(\.id), [three.id, one.id, two.id])
        XCTAssertEqual(templates.map(\.sortOrder), Array(templates.indices))

        do {
            try await context.repository.reorderCustomTemplates(ids: [one.id, two.id])
            XCTFail("Expected invalid reorder")
        } catch SummaryTemplateRepositoryError.invalidReorder {}
        let unchanged = try await context.repository.templates()
        XCTAssertEqual(unchanged, templates)
    }

    func testValidationRejectsEmptyOversizedAndNormalizedDuplicateWithoutMutation() async throws {
        let context = try Context()
        _ = try await context.repository.templates()
        _ = try await context.repository.create(name: "Café   Notes", prompt: "Valid")
        let before = try await context.repository.templates()
        let bytesBefore = try Data(contentsOf: context.url)

        for invalidName in ["   ", String(repeating: "n", count: 81)] {
            do {
                _ = try await context.repository.create(name: invalidName, prompt: "Valid")
                XCTFail("Expected invalid name")
            } catch is SummaryTemplateRepositoryError {}
        }
        for invalidPrompt in ["\n\t", String(repeating: "p", count: 20_001)] {
            do {
                _ = try await context.repository.create(name: UUID().uuidString, prompt: invalidPrompt)
                XCTFail("Expected invalid prompt")
            } catch is SummaryTemplateRepositoryError {}
        }
        do {
            _ = try await context.repository.create(name: "  CAFE　NOTES ", prompt: "Duplicate")
            XCTFail("Expected normalized duplicate")
        } catch SummaryTemplateRepositoryError.duplicateName {}

        let after = try await context.repository.templates()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: context.url), bytesBefore)
    }

    func testMalformedDefaultsRepairToMeetingMinutesAndNoticeOnce() async throws {
        let context = try Context()
        var templates = SummaryTemplatePresetCatalog.presets
        templates[0].isDefault = false
        templates[1].isDefault = true
        templates[2].isDefault = true
        try encodeEnvelope(SummaryTemplateEnvelope(templates: templates), to: context.url)

        let loaded = try await context.repository.templates()
        let fallbackNotice = await context.repository.consumeNotice()
        let consumedNotice = await context.repository.consumeNotice()
        XCTAssertEqual(loaded.filter(\.isDefault).map(\.presetID), [SummaryTemplatePresetCatalog.meetingMinutesID])
        XCTAssertEqual(fallbackNotice, .defaultChangedToMeetingMinutes)
        XCTAssertNil(consumedNotice)
        XCTAssertEqual(try decodeEnvelope(at: context.url).templates.filter(\.isDefault).count, 1)
    }

    func testSuccessfulRebindClearsStaleFallbackNoticeAndFailedRebindPreservesIt() async throws {
        let first = try Context()
        var malformed = SummaryTemplatePresetCatalog.presets
        malformed[0].isDefault = false
        try encodeEnvelope(SummaryTemplateEnvelope(templates: malformed), to: first.url)
        _ = try await first.repository.templates()

        let corruptURL = first.directory.appendingPathComponent("corrupt-candidate.json")
        try Data("broken".utf8).write(to: corruptURL)
        do {
            _ = try await first.repository.rebind(to: corruptURL)
            XCTFail("Expected failed rebind")
        } catch SummaryTemplateRepositoryError.corruptFile {}
        let preservedNotice = await first.repository.consumeNotice()
        XCTAssertEqual(preservedNotice, .defaultChangedToMeetingMinutes)

        // Re-create the stale notice, then prove a healthy candidate replaces it with nil.
        try encodeEnvelope(SummaryTemplateEnvelope(templates: malformed), to: first.url)
        let reloadedA = SummaryTemplateRepository(fileURL: first.url)
        _ = try await reloadedA.templates()
        let healthy = try Context()
        _ = try await healthy.repository.templates()
        _ = try await reloadedA.rebind(to: healthy.url)
        let clearedNotice = await reloadedA.consumeNotice()
        XCTAssertNil(clearedNotice)
    }

    func testRecognizedPresetRequiresCanonicalUUIDAndLeavesFileUntouched() async throws {
        let context = try Context()
        var templates = SummaryTemplatePresetCatalog.presets
        templates[0].id = UUID()
        let invalid = SummaryTemplateEnvelope(templates: templates)
        try encodeEnvelope(invalid, to: context.url)
        let bytes = try Data(contentsOf: context.url)

        do {
            _ = try await context.repository.templates()
            XCTFail("Expected preset identity mismatch")
        } catch SummaryTemplateRepositoryError.presetIdentityMismatch(
            presetID: SummaryTemplatePresetCatalog.meetingMinutesID,
            expected: SummaryTemplatePresetCatalog.presets[0].id,
            actual: templates[0].id
        ) {}
        XCTAssertEqual(try Data(contentsOf: context.url), bytes)
    }

    func testUnknownPresetIsPreservedImmutableAndOrderedBeforeCustomRows() async throws {
        let context = try Context()
        let unknownID = UUID()
        let customID = UUID()
        let unknown = SummaryTemplate(
            id: unknownID,
            presetID: "future-preset-v9",
            name: "Future Preset",
            prompt: "Future prompt",
            createdAt: Date(timeIntervalSince1970: 111.25),
            updatedAt: Date(timeIntervalSince1970: 222.5),
            sortOrder: 99
        )
        let custom = SummaryTemplate(
            id: customID,
            name: "Custom",
            prompt: "Custom prompt",
            sortOrder: 0
        )
        try encodeEnvelope(
            SummaryTemplateEnvelope(templates: SummaryTemplatePresetCatalog.presets + [custom, unknown]),
            to: context.url
        )

        let loaded = try await context.repository.templates()
        let preserved = try XCTUnwrap(loaded.first(where: { $0.id == unknownID }))
        XCTAssertEqual(preserved.presetID, unknown.presetID)
        XCTAssertEqual(preserved.name, unknown.name)
        XCTAssertEqual(preserved.prompt, unknown.prompt)
        XCTAssertEqual(preserved.createdAt, unknown.createdAt)
        XCTAssertEqual(preserved.updatedAt, unknown.updatedAt)
        XCTAssertTrue(preserved.isBuiltIn)
        XCTAssertLessThan(
            try XCTUnwrap(loaded.firstIndex(where: { $0.id == unknownID })),
            try XCTUnwrap(loaded.firstIndex(where: { $0.id == customID }))
        )

        await assertThrowsBuiltIn {
            try await context.repository.update(id: unknownID, name: "Changed", prompt: "Changed")
        }
        await assertThrowsBuiltIn { try await context.repository.delete(id: unknownID) }
        do {
            try await context.repository.reorderCustomTemplates(ids: [customID, unknownID])
            XCTFail("Future presets must not enter custom reorder operations")
        } catch SummaryTemplateRepositoryError.invalidReorder {}

        let duplicate = try await context.repository.duplicate(id: unknownID)
        XCTAssertNil(duplicate.presetID)
        XCTAssertEqual(duplicate.prompt, unknown.prompt)
        let reseeded = try await SummaryTemplateRepository(fileURL: context.url).templates()
        let afterReload = try XCTUnwrap(reseeded.first(where: { $0.id == unknownID }))
        XCTAssertEqual(afterReload.name, unknown.name)
        XCTAssertEqual(afterReload.prompt, unknown.prompt)
        XCTAssertEqual(afterReload.createdAt, unknown.createdAt)
        XCTAssertEqual(afterReload.updatedAt, unknown.updatedAt)
    }

    func testCorruptAndFutureSchemaFilesAreUntouched() async throws {
        let corruptContext = try Context()
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: corruptContext.url)
        do {
            _ = try await corruptContext.repository.templates()
            XCTFail("Expected corrupt file error")
        } catch SummaryTemplateRepositoryError.corruptFile {}
        XCTAssertEqual(try Data(contentsOf: corruptContext.url), corrupt)

        let futureContext = try Context()
        let future = Data("{\"schemaVersion\":99,\"templates\":[]}".utf8)
        try future.write(to: futureContext.url)
        do {
            _ = try await futureContext.repository.templates()
            XCTFail("Expected future schema error")
        } catch SummaryTemplateRepositoryError.unsupportedSchemaVersion(99) {}
        XCTAssertEqual(try Data(contentsOf: futureContext.url), future)
    }

    func testFailedAtomicWritePreservesDiskAndPublishedCache() async throws {
        let context = try Context()
        let access = ToggleWriteFileAccess()
        let repository = SummaryTemplateRepository(fileURL: context.url, fileAccess: access)
        let before = try await repository.templates()
        let bytesBefore = try Data(contentsOf: context.url)
        access.failWrites = true

        do {
            _ = try await repository.create(name: "Cannot Save", prompt: "Prompt")
            XCTFail("Expected write failure")
        } catch SummaryTemplateRepositoryError.writeFailed {}
        let after = try await repository.templates()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: context.url), bytesBefore)
    }

    func testRebindLoadsIndependentLibrariesWithoutMergingAndFailedCandidateKeepsBinding() async throws {
        let first = try Context()
        _ = try await first.repository.templates()
        let firstCustom = try await first.repository.create(name: "First Library", prompt: "First")
        let second = try Context()
        _ = try await second.repository.templates()
        let secondCustom = try await second.repository.create(name: "Second Library", prompt: "Second")

        let rebound = try await first.repository.rebind(to: second.url)
        XCTAssertTrue(rebound.contains(where: { $0.id == secondCustom.id }))
        XCTAssertFalse(rebound.contains(where: { $0.id == firstCustom.id }))

        let corruptURL = second.directory.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corruptURL)
        do {
            _ = try await first.repository.rebind(to: corruptURL)
            XCTFail("Expected corrupt candidate rejection")
        } catch SummaryTemplateRepositoryError.corruptFile {}
        let stillRebound = try await first.repository.templates()
        XCTAssertEqual(stillRebound, rebound)
    }

    func testConcurrentActorCreatesHaveNoLostUpdatesAndStableUniqueIDs() async throws {
        let context = try Context()
        _ = try await context.repository.templates()
        let created = try await withThrowingTaskGroup(of: SummaryTemplate.self) { group in
            for index in 0..<30 {
                group.addTask {
                    try await context.repository.create(name: "Concurrent \(index)", prompt: "Prompt \(index)")
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let templates = try await context.repository.templates()
        XCTAssertEqual(templates.count, 35)
        XCTAssertEqual(Set(created.map(\.id)).count, 30)
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
        XCTAssertEqual(templates.map(\.sortOrder), Array(templates.indices))
        XCTAssertEqual(templates.filter(\.isDefault).count, 1)
    }

    func testSelectionIdentitySupportsPresetAndUUIDAliases() {
        let preset = SummaryTemplatePresetCatalog.presets[0]
        XCTAssertEqual(preset.stableSelectionID, "meeting-minutes-v1")
        XCTAssertTrue(preset.matchesSelectionID("meeting-minutes-v1"))
        XCTAssertTrue(preset.matchesSelectionID(preset.id.uuidString.lowercased()))
        let custom = SummaryTemplate(name: "Custom", prompt: "Prompt")
        XCTAssertEqual(custom.stableSelectionID, custom.id.uuidString.lowercased())
        XCTAssertTrue(custom.matchesSelectionID(custom.id.uuidString.uppercased()))
    }

    private func assertThrowsBuiltIn(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected immutable built-in error", file: file, line: line)
        } catch SummaryTemplateRepositoryError.builtInIsImmutable {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private struct Context: Sendable {
    let directory: URL
    let url: URL
    let repository: SummaryTemplateRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryTemplateRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("summary-templates.json")
        repository = SummaryTemplateRepository(fileURL: url)
    }
}

private final class ToggleWriteFileAccess: SummaryTemplateFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _failWrites = false

    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        if failWrites { throw ExpectedFailure() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private struct ExpectedFailure: Error {}
}

private func decodeEnvelope(at url: URL) throws -> SummaryTemplateEnvelope {
    try JSONDecoder().decode(SummaryTemplateEnvelope.self, from: Data(contentsOf: url))
}

private func encodeEnvelope(_ envelope: SummaryTemplateEnvelope, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(envelope).write(to: url, options: .atomic)
}
