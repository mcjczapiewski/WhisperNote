import Foundation

enum LibraryItemKind: String, Codable, CaseIterable, Sendable {
    case recording
    case group
    case transcript
    case summary
}

/// A library identity includes its artifact kind so equal UUIDs in different stores
/// can never share favorites or tag assignments accidentally.
struct LibraryItemKey: Codable, Hashable, Sendable {
    let kind: LibraryItemKind
    let id: UUID

    init(kind: LibraryItemKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

struct LibraryTag: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct LibraryItemMetadata: Codable, Equatable, Sendable {
    let key: LibraryItemKey
    var isFavorite: Bool
    var tagIDs: Set<UUID>

    init(key: LibraryItemKey, isFavorite: Bool = false, tagIDs: Set<UUID> = []) {
        self.key = key
        self.isFavorite = isFavorite
        self.tagIDs = tagIDs
    }

    private enum CodingKeys: String, CodingKey {
        case key, isFavorite, tagIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(LibraryItemKey.self, forKey: .key)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tagIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .tagIDs) ?? []
    }
}

struct LibraryMetadataEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var tags: [LibraryTag]
    var items: [LibraryItemMetadata]

    init(
        version: Int = LibraryMetadataEnvelope.currentVersion,
        tags: [LibraryTag] = [],
        items: [LibraryItemMetadata] = []
    ) {
        self.version = version
        self.tags = tags
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case version, tags, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        tags = try container.decodeIfPresent([LibraryTag].self, forKey: .tags) ?? []
        items = try container.decodeIfPresent([LibraryItemMetadata].self, forKey: .items) ?? []
    }
}
