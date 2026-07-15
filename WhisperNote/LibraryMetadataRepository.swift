import Foundation

protocol LibraryMetadataFileAccess: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct LocalLibraryMetadataFileAccess: LibraryMetadataFileAccess {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

enum LibraryMetadataRepositoryError: LocalizedError {
    case corruptFile(URL, Error)
    case unsupportedVersion(Int)
    case writeFailed(URL, Error)
    case invalidTagName
    case duplicateTagName(String)
    case tagNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .corruptFile(let url, let error):
            return "Library metadata at \(url.path) is unreadable and was left unchanged: \(error.localizedDescription)"
        case .unsupportedVersion(let version):
            return "Library metadata version \(version) is not supported."
        case .writeFailed(let url, let error):
            return "Library metadata could not be saved to \(url.path): \(error.localizedDescription)"
        case .invalidTagName:
            return "Tag names cannot be empty."
        case .duplicateTagName(let name):
            return "A tag named “\(name)” already exists."
        case .tagNotFound:
            return "The selected tag no longer exists."
        }
    }
}

actor LibraryMetadataRepository {
    private let fileURL: URL
    private let fileAccess: any LibraryMetadataFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL = DirectoryManager.shared.getLibraryMetadataURL(),
        fileAccess: any LibraryMetadataFileAccess = LocalLibraryMetadataFileAccess()
    ) {
        self.fileURL = fileURL
        self.fileAccess = fileAccess
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func snapshot() throws -> LibraryMetadataEnvelope {
        try load()
    }

    func metadata(for key: LibraryItemKey) throws -> LibraryItemMetadata {
        try load().items.first(where: { $0.key == key }) ?? LibraryItemMetadata(key: key)
    }

    @discardableResult
    func createTag(name: String) throws -> LibraryTag {
        let displayName = Self.cleanedTagName(name)
        guard !displayName.isEmpty else { throw LibraryMetadataRepositoryError.invalidTagName }

        var envelope = try load()
        try ensureUnique(displayName, in: envelope.tags, excluding: nil)
        let tag = LibraryTag(name: displayName)
        envelope.tags.append(tag)
        try persist(envelope)
        return tag
    }

    @discardableResult
    func renameTag(id: UUID, to name: String) throws -> LibraryTag {
        let displayName = Self.cleanedTagName(name)
        guard !displayName.isEmpty else { throw LibraryMetadataRepositoryError.invalidTagName }

        var envelope = try load()
        guard let index = envelope.tags.firstIndex(where: { $0.id == id }) else {
            throw LibraryMetadataRepositoryError.tagNotFound(id)
        }
        try ensureUnique(displayName, in: envelope.tags, excluding: id)
        envelope.tags[index].name = displayName
        try persist(envelope)
        return envelope.tags[index]
    }

    func deleteTag(id: UUID) throws {
        var envelope = try load()
        guard envelope.tags.contains(where: { $0.id == id }) else {
            throw LibraryMetadataRepositoryError.tagNotFound(id)
        }
        envelope.tags.removeAll(where: { $0.id == id })
        for index in envelope.items.indices {
            envelope.items[index].tagIDs.remove(id)
        }
        pruneEmptyItems(in: &envelope)
        try persist(envelope)
    }

    func setFavorite(_ isFavorite: Bool, for key: LibraryItemKey) throws {
        var envelope = try load()
        mutateItem(key, in: &envelope) { $0.isFavorite = isFavorite }
        pruneEmptyItems(in: &envelope)
        try persist(envelope)
    }

    func assignTag(id: UUID, to key: LibraryItemKey) throws {
        var envelope = try load()
        guard envelope.tags.contains(where: { $0.id == id }) else {
            throw LibraryMetadataRepositoryError.tagNotFound(id)
        }
        mutateItem(key, in: &envelope) { $0.tagIDs.insert(id) }
        try persist(envelope)
    }

    func removeTag(id: UUID, from key: LibraryItemKey) throws {
        var envelope = try load()
        mutateItem(key, in: &envelope) { $0.tagIDs.remove(id) }
        pruneEmptyItems(in: &envelope)
        try persist(envelope)
    }

    /// Always strips assignments to nonexistent tags. Item rows are only pruned
    /// against artifacts when the caller supplies a complete, authoritative key set.
    func reconcile(
        existingItemKeys: Set<LibraryItemKey>? = nil,
        logicalGroupByItemKey: [LibraryItemKey: UUID] = [:]
    ) throws {
        var envelope = try load()
        let knownTagIDs = Set(envelope.tags.map(\.id))
        for index in envelope.items.indices {
            envelope.items[index].tagIDs.formIntersection(knownTagIDs)
        }
        // Backward-compatible migration: earlier 1.4.4 previews attached metadata
        // to an arbitrary member/artifact of a group. Copy its union to the stable
        // group key before pruning so later member deletion cannot lose it.
        let legacyGroupedItems = envelope.items.compactMap { item -> (UUID, LibraryItemMetadata)? in
            logicalGroupByItemKey[item.key].map { ($0, item) }
        }
        for (groupID, item) in legacyGroupedItems {
            mutateItem(LibraryItemKey(kind: .group, id: groupID), in: &envelope) {
                $0.isFavorite = $0.isFavorite || item.isFavorite
                $0.tagIDs.formUnion(item.tagIDs)
            }
        }
        if !logicalGroupByItemKey.isEmpty {
            envelope.items.removeAll { item in
                guard let groupID = logicalGroupByItemKey[item.key] else { return false }
                return item.key != LibraryItemKey(kind: .group, id: groupID)
            }
        }
        if let existingItemKeys {
            envelope.items.removeAll(where: { !existingItemKeys.contains($0.key) })
        }
        try persist(envelope)
    }

    static func normalizedTagName(_ name: String) -> String {
        cleanedTagName(name)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func cleanedTagName(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func load() throws -> LibraryMetadataEnvelope {
        guard fileAccess.fileExists(at: fileURL) else { return LibraryMetadataEnvelope() }
        do {
            let envelope = try decoder.decode(LibraryMetadataEnvelope.self, from: fileAccess.read(from: fileURL))
            guard envelope.version <= LibraryMetadataEnvelope.currentVersion else {
                throw LibraryMetadataRepositoryError.unsupportedVersion(envelope.version)
            }
            return envelope
        } catch let error as LibraryMetadataRepositoryError {
            throw error
        } catch {
            throw LibraryMetadataRepositoryError.corruptFile(fileURL, error)
        }
    }

    private func persist(_ envelope: LibraryMetadataEnvelope) throws {
        do {
            try fileAccess.writeAtomically(encoder.encode(envelope), to: fileURL)
        } catch {
            throw LibraryMetadataRepositoryError.writeFailed(fileURL, error)
        }
    }

    private func ensureUnique(_ name: String, in tags: [LibraryTag], excluding id: UUID?) throws {
        let normalized = Self.normalizedTagName(name)
        if tags.contains(where: { $0.id != id && Self.normalizedTagName($0.name) == normalized }) {
            throw LibraryMetadataRepositoryError.duplicateTagName(name)
        }
    }

    private func mutateItem(
        _ key: LibraryItemKey,
        in envelope: inout LibraryMetadataEnvelope,
        mutation: (inout LibraryItemMetadata) -> Void
    ) {
        if let index = envelope.items.firstIndex(where: { $0.key == key }) {
            mutation(&envelope.items[index])
        } else {
            var item = LibraryItemMetadata(key: key)
            mutation(&item)
            envelope.items.append(item)
        }
    }

    private func pruneEmptyItems(in envelope: inout LibraryMetadataEnvelope) {
        envelope.items.removeAll(where: { !$0.isFavorite && $0.tagIDs.isEmpty })
    }
}
