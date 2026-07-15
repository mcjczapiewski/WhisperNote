import Foundation

protocol SummaryTemplateFileAccess: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct LocalSummaryTemplateFileAccess: SummaryTemplateFileAccess {
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

enum SummaryTemplateRepositoryError: LocalizedError {
    case corruptFile(URL, Error)
    case unsupportedSchemaVersion(Int)
    case writeFailed(URL, Error)
    case templateNotFound(UUID)
    case builtInIsImmutable
    case invalidName
    case nameTooLong
    case duplicateName(String)
    case invalidPrompt
    case promptTooLong
    case invalidStore(String)
    case invalidReorder
    case presetIdentityMismatch(presetID: String, expected: UUID, actual: UUID)
    case candidateChanged(URL)

    var errorDescription: String? {
        switch self {
        case .corruptFile(let url, let error):
            return "Summary templates at \(url.path) are unreadable and were left unchanged: \(error.localizedDescription)"
        case .unsupportedSchemaVersion(let version):
            return "Summary template schema version \(version) is newer than this version of WhisperNote supports."
        case .writeFailed(let url, let error):
            return "Summary templates could not be saved to \(url.path): \(error.localizedDescription)"
        case .templateNotFound:
            return "The selected summary template no longer exists."
        case .builtInIsImmutable:
            return "Built-in summary templates cannot be edited, reordered, or deleted. Duplicate the template first."
        case .invalidName:
            return "Template names cannot be empty."
        case .nameTooLong:
            return "Template names cannot exceed 80 characters."
        case .duplicateName(let name):
            return "A summary template named “\(name)” already exists."
        case .invalidPrompt:
            return "Template prompts cannot be empty."
        case .promptTooLong:
            return "Template prompts cannot exceed 20,000 characters."
        case .invalidStore(let reason):
            return "The summary template library is invalid and was left unchanged: \(reason)"
        case .invalidReorder:
            return "The custom template order must include every custom template exactly once."
        case .presetIdentityMismatch(let presetID, let expected, let actual):
            return "Preset \(presetID) has UUID \(actual.uuidString), but \(expected.uuidString) is required. The file was left unchanged."
        case .candidateChanged(let url):
            return "Summary templates at \(url.path) changed during library validation. The previous library remains active."
        }
    }
}

struct SummaryTemplateLibraryCandidate: Sendable {
    fileprivate enum SourceToken: Sendable, Equatable {
        case missing
        case data(Data)
    }

    fileprivate let fileURL: URL
    fileprivate let envelope: SummaryTemplateEnvelope
    fileprivate let requiresPersistence: Bool
    fileprivate let usedDefaultFallback: Bool
    fileprivate let sourceToken: SourceToken
}

actor SummaryTemplateRepository {
    static let maximumNameLength = 80
    static let maximumPromptLength = 20_000

    private var fileURL: URL
    private let fileAccess: any SummaryTemplateFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedEnvelope: SummaryTemplateEnvelope?
    private var pendingNotice: SummaryTemplateRepositoryNotice?

    init(
        fileURL: URL = DirectoryManager.shared.getSummaryTemplatesURL(),
        fileAccess: any SummaryTemplateFileAccess = LocalSummaryTemplateFileAccess()
    ) {
        self.fileURL = fileURL
        self.fileAccess = fileAccess
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func templates() throws -> [SummaryTemplate] {
        try currentEnvelope().templates
    }

    func defaultTemplate() throws -> SummaryTemplate {
        guard let template = try currentEnvelope().templates.first(where: \.isDefault) else {
            throw SummaryTemplateRepositoryError.invalidStore("No default template is available.")
        }
        return template
    }

    func consumeNotice() -> SummaryTemplateRepositoryNotice? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    /// Validates and prepares another library without writing, seeding, repairing,
    /// rebinding, or changing the currently published cache.
    func preflight(fileURL: URL) throws -> SummaryTemplateLibraryCandidate {
        let sourceToken = try readSourceToken(from: fileURL)
        let prepared = try prepare(from: sourceToken, at: fileURL)
        return SummaryTemplateLibraryCandidate(
            fileURL: fileURL,
            envelope: prepared.envelope,
            requiresPersistence: prepared.requiresPersistence,
            usedDefaultFallback: prepared.usedDefaultFallback,
            sourceToken: sourceToken
        )
    }

    /// Accepts a previously validated candidate. Any required seed or repair is
    /// durably written before the repository swaps its live library binding.
    @discardableResult
    func accept(_ candidate: SummaryTemplateLibraryCandidate) throws -> [SummaryTemplate] {
        let currentToken = try readSourceToken(from: candidate.fileURL)
        guard currentToken == candidate.sourceToken else {
            throw SummaryTemplateRepositoryError.candidateChanged(candidate.fileURL)
        }
        if candidate.requiresPersistence {
            try persist(candidate.envelope, to: candidate.fileURL)
        }
        fileURL = candidate.fileURL
        cachedEnvelope = candidate.envelope
        pendingNotice = candidate.usedDefaultFallback ? .defaultChangedToMeetingMinutes : nil
        return candidate.envelope.templates
    }

    @discardableResult
    func create(
        name: String,
        prompt: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> SummaryTemplate {
        var envelope = try currentEnvelope()
        let template = SummaryTemplate(
            id: id,
            name: try validatedName(name),
            prompt: try validatedPrompt(prompt),
            createdAt: now,
            updatedAt: now,
            sortOrder: envelope.templates.count
        )
        envelope.templates.append(template)
        try commit(&envelope)
        return envelope.templates.first(where: { $0.id == id })!
    }

    @discardableResult
    func update(id: UUID, name: String, prompt: String, now: Date = Date()) throws -> SummaryTemplate {
        var envelope = try currentEnvelope()
        guard let index = envelope.templates.firstIndex(where: { $0.id == id }) else {
            throw SummaryTemplateRepositoryError.templateNotFound(id)
        }
        guard !envelope.templates[index].isBuiltIn else {
            throw SummaryTemplateRepositoryError.builtInIsImmutable
        }
        envelope.templates[index].name = try validatedName(name)
        envelope.templates[index].prompt = try validatedPrompt(prompt)
        envelope.templates[index].updatedAt = now
        try commit(&envelope)
        return envelope.templates.first(where: { $0.id == id })!
    }

    @discardableResult
    func duplicate(id: UUID, newID: UUID = UUID(), now: Date = Date()) throws -> SummaryTemplate {
        var envelope = try currentEnvelope()
        guard let source = envelope.templates.first(where: { $0.id == id }) else {
            throw SummaryTemplateRepositoryError.templateNotFound(id)
        }
        let copy = SummaryTemplate(
            id: newID,
            name: uniqueCopyName(for: source.name, in: envelope.templates),
            prompt: source.prompt,
            createdAt: now,
            updatedAt: now,
            sortOrder: envelope.templates.count
        )
        envelope.templates.append(copy)
        try commit(&envelope)
        return envelope.templates.first(where: { $0.id == newID })!
    }

    func reorderCustomTemplates(ids: [UUID]) throws {
        var envelope = try currentEnvelope()
        let customs = envelope.templates.filter { !$0.isBuiltIn }
        guard ids.count == customs.count,
              Set(ids).count == ids.count,
              Set(ids) == Set(customs.map(\.id)) else {
            throw SummaryTemplateRepositoryError.invalidReorder
        }
        let byID = Dictionary(uniqueKeysWithValues: customs.map { ($0.id, $0) })
        envelope.templates = envelope.templates.filter(\.isBuiltIn) + ids.compactMap { byID[$0] }
        for index in envelope.templates.indices {
            envelope.templates[index].sortOrder = index
        }
        try commit(&envelope)
    }

    func setDefault(id: UUID) throws {
        var envelope = try currentEnvelope()
        guard envelope.templates.contains(where: { $0.id == id }) else {
            throw SummaryTemplateRepositoryError.templateNotFound(id)
        }
        for index in envelope.templates.indices {
            envelope.templates[index].isDefault = envelope.templates[index].id == id
        }
        try commit(&envelope)
    }

    func delete(id: UUID) throws {
        var envelope = try currentEnvelope()
        guard let template = envelope.templates.first(where: { $0.id == id }) else {
            throw SummaryTemplateRepositoryError.templateNotFound(id)
        }
        guard !template.isBuiltIn else { throw SummaryTemplateRepositoryError.builtInIsImmutable }
        envelope.templates.removeAll(where: { $0.id == id })
        if template.isDefault {
            setMeetingMinutesDefault(in: &envelope.templates)
        }
        try commit(&envelope)
        if template.isDefault { pendingNotice = .defaultChangedToMeetingMinutes }
    }

    /// Loads an independent library. Candidate state is fully decoded, repaired,
    /// validated, and durably seeded before the repository swaps its live binding.
    @discardableResult
    func rebind(to fileURL: URL) throws -> [SummaryTemplate] {
        try accept(preflight(fileURL: fileURL))
    }

    static func normalizedName(_ name: String) -> String {
        cleanedName(name)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func currentEnvelope() throws -> SummaryTemplateEnvelope {
        if let cachedEnvelope { return cachedEnvelope }
        let sourceToken = try readSourceToken(from: fileURL)
        let prepared = try prepare(from: sourceToken, at: fileURL)
        if prepared.requiresPersistence { try persist(prepared.envelope, to: fileURL) }
        cachedEnvelope = prepared.envelope
        if prepared.usedDefaultFallback { pendingNotice = .defaultChangedToMeetingMinutes }
        return prepared.envelope
    }

    private func readSourceToken(from url: URL) throws -> SummaryTemplateLibraryCandidate.SourceToken {
        guard fileAccess.fileExists(at: url) else { return .missing }
        return .data(try fileAccess.read(from: url))
    }

    private func prepare(
        from sourceToken: SummaryTemplateLibraryCandidate.SourceToken,
        at url: URL
    ) throws -> (envelope: SummaryTemplateEnvelope, usedDefaultFallback: Bool, requiresPersistence: Bool) {
        guard case .data(let sourceData) = sourceToken else {
            let envelope = SummaryTemplateEnvelope(templates: normalized(SummaryTemplatePresetCatalog.presets))
            return (envelope, false, true)
        }

        let original: SummaryTemplateEnvelope
        do {
            original = try decoder.decode(SummaryTemplateEnvelope.self, from: sourceData)
        } catch {
            throw SummaryTemplateRepositoryError.corruptFile(url, error)
        }
        guard original.schemaVersion <= SummaryTemplateEnvelope.currentSchemaVersion else {
            throw SummaryTemplateRepositoryError.unsupportedSchemaVersion(original.schemaVersion)
        }
        guard original.schemaVersion == SummaryTemplateEnvelope.currentSchemaVersion else {
            throw SummaryTemplateRepositoryError.invalidStore("Unsupported legacy schema version \(original.schemaVersion).")
        }

        try validateStoredIdentities(original.templates)
        var templates = original.templates
        upsertPresets(into: &templates)
        for index in templates.indices where templates[index].presetID == nil {
            templates[index].name = Self.cleanedName(templates[index].name)
            templates[index].prompt = templates[index].prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let defaultCount = templates.filter(\.isDefault).count
        let usedFallback = defaultCount != 1
        if usedFallback { setMeetingMinutesDefault(in: &templates) }
        templates = normalized(templates)
        try validate(templates)
        let prepared = SummaryTemplateEnvelope(templates: templates)
        let requiresPersistence = prepared != original
        return (prepared, usedFallback, requiresPersistence)
    }

    private func commit(_ envelope: inout SummaryTemplateEnvelope) throws {
        envelope.schemaVersion = SummaryTemplateEnvelope.currentSchemaVersion
        envelope.templates = normalized(envelope.templates)
        try validate(envelope.templates)
        try persist(envelope, to: fileURL)
        cachedEnvelope = envelope
    }

    private func persist(_ envelope: SummaryTemplateEnvelope, to url: URL) throws {
        do {
            try fileAccess.writeAtomically(encoder.encode(envelope), to: url)
        } catch {
            throw SummaryTemplateRepositoryError.writeFailed(url, error)
        }
    }

    private func upsertPresets(into templates: inout [SummaryTemplate]) {
        for preset in SummaryTemplatePresetCatalog.presets {
            if let index = templates.firstIndex(where: { $0.presetID == preset.presetID }) {
                templates[index].name = preset.name
                templates[index].prompt = preset.prompt
                templates[index].updatedAt = preset.updatedAt
            } else {
                var inserted = preset
                inserted.isDefault = false
                templates.append(inserted)
            }
        }
    }

    private func normalized(_ templates: [SummaryTemplate]) -> [SummaryTemplate] {
        let presetOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: SummaryTemplatePresetCatalog.presets.enumerated().compactMap {
            guard let presetID = $0.element.presetID else { return nil }
            return (presetID, $0.offset)
            }
        )
        let sorted = templates.sorted { lhs, rhs in
            let leftPreset = lhs.presetID.flatMap { presetOrder[$0] }
            let rightPreset = rhs.presetID.flatMap { presetOrder[$0] }
            let leftSection = leftPreset != nil ? 0 : (lhs.presetID != nil ? 1 : 2)
            let rightSection = rightPreset != nil ? 0 : (rhs.presetID != nil ? 1 : 2)
            if leftSection != rightSection { return leftSection < rightSection }
            switch (leftPreset, rightPreset) {
            case let (left?, right?): return left < right
            default:
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        return sorted.enumerated().map { offset, template in
            var template = template
            template.sortOrder = offset
            return template
        }
    }

    private func validateStoredIdentities(_ templates: [SummaryTemplate]) throws {
        guard Set(templates.map(\.id)).count == templates.count else {
            throw SummaryTemplateRepositoryError.invalidStore("Template UUIDs must be unique.")
        }
        let presetIDs = templates.compactMap(\.presetID)
        guard Set(presetIDs).count == presetIDs.count else {
            throw SummaryTemplateRepositoryError.invalidStore("Preset identities must be unique.")
        }
        for template in templates {
            guard let presetID = template.presetID,
                  let canonical = SummaryTemplatePresetCatalog.preset(id: presetID) else { continue }
            guard template.id == canonical.id else {
                throw SummaryTemplateRepositoryError.presetIdentityMismatch(
                    presetID: presetID,
                    expected: canonical.id,
                    actual: template.id
                )
            }
        }
    }

    private func validate(_ templates: [SummaryTemplate]) throws {
        try validateStoredIdentities(templates)
        guard templates.filter(\.isDefault).count == 1 else {
            throw SummaryTemplateRepositoryError.invalidStore("Exactly one default template is required.")
        }
        guard templates.map(\.sortOrder) == Array(templates.indices) else {
            throw SummaryTemplateRepositoryError.invalidStore("Template ordering is not contiguous.")
        }
        var normalizedNames = Set<String>()
        for template in templates {
            let name = try validatedName(template.name)
            _ = try validatedPrompt(template.prompt)
            guard name == template.name else {
                throw SummaryTemplateRepositoryError.invalidStore("Template names must be stored in normalized display form.")
            }
            guard normalizedNames.insert(Self.normalizedName(name)).inserted else {
                throw SummaryTemplateRepositoryError.duplicateName(name)
            }
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let cleaned = Self.cleanedName(name)
        guard !cleaned.isEmpty else { throw SummaryTemplateRepositoryError.invalidName }
        guard cleaned.count <= Self.maximumNameLength else { throw SummaryTemplateRepositoryError.nameTooLong }
        return cleaned
    }

    private func validatedPrompt(_ prompt: String) throws -> String {
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw SummaryTemplateRepositoryError.invalidPrompt }
        guard cleaned.count <= Self.maximumPromptLength else { throw SummaryTemplateRepositoryError.promptTooLong }
        return cleaned
    }

    private func uniqueCopyName(for sourceName: String, in templates: [SummaryTemplate]) -> String {
        let base = String(sourceName.prefix(Self.maximumNameLength - 5))
        var candidate = "\(base) Copy"
        var suffix = 2
        let existing = Set(templates.map { Self.normalizedName($0.name) })
        while existing.contains(Self.normalizedName(candidate)) {
            let suffixText = " Copy \(suffix)"
            candidate = "\(sourceName.prefix(Self.maximumNameLength - suffixText.count))\(suffixText)"
            suffix += 1
        }
        return candidate
    }

    private func setMeetingMinutesDefault(in templates: inout [SummaryTemplate]) {
        for index in templates.indices {
            templates[index].isDefault = templates[index].presetID == SummaryTemplatePresetCatalog.meetingMinutesID
        }
    }

    private static func cleanedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
