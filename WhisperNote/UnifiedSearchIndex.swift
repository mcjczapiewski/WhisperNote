import Foundation

enum UnifiedSearchResultKey: Hashable, Sendable {
    case recording(UUID)
    case group(UUID)
    case orphanSummary(UUID)
}

enum UnifiedSearchDestination: Hashable, Sendable {
    case recording(UUID)
    case group(UUID)
    case transcript(UUID)
    case summary(UUID)
}

enum UnifiedSearchStatus: String, CaseIterable, Sendable {
    case unprocessed
    case processing
    case needsAttention
    case completed
}

enum UnifiedSearchStatusFilter: Sendable {
    case all
    case unprocessed
    case processing
    case needsAttention
    case completed
}

enum UnifiedSearchDateFilter: Sendable {
    case any
    case today
    case last7Days
    case last30Days
    case custom(Date, Date)
}

struct UnifiedSearchQuery: Sendable {
    var text: String
    var favoritesOnly: Bool
    var status: UnifiedSearchStatusFilter
    var date: UnifiedSearchDateFilter
    var tagIDs: Set<UUID>

    init(
        text: String = "",
        favoritesOnly: Bool = false,
        status: UnifiedSearchStatusFilter = .all,
        date: UnifiedSearchDateFilter = .any,
        tagIDs: Set<UUID> = []
    ) {
        self.text = text
        self.favoritesOnly = favoritesOnly
        self.status = status
        self.date = date
        self.tagIDs = tagIDs
    }
}

struct UnifiedSearchResult: Equatable, Sendable {
    let key: UnifiedSearchResultKey
    let title: String
    let date: Date
    let status: UnifiedSearchStatus
    let isFavorite: Bool
    let tags: [LibraryTag]
    let destination: UnifiedSearchDestination
    let isStale: Bool
    let isOrphan: Bool
    let previews: [UnifiedSearchPreview]
}

struct UnifiedSearchPreview: Equatable, Sendable {
    let destination: UnifiedSearchDestination
    let match: String
    let matchIndex: Int
}

/// An immutable, pre-normalized projection of the library. Rebuild it whenever an
/// artifact or its metadata changes, then query it cheaply from any concurrency domain.
struct UnifiedSearchIndex: Sendable {
    private let entries: [Entry]

    init(
        recordings: [Recording],
        transcripts: [Transcript],
        summaries: [Summary],
        jobs: [ProcessingJob],
        metadata: LibraryMetadataEnvelope
    ) {
        let recordingRoots = Self.firstValueDictionary(recordings.map {
            ($0.id, $0.groupId.map(UnifiedSearchResultKey.group) ?? .recording($0.id))
        })
        let groupRoots = Self.firstValueDictionary(recordings.compactMap { recording in
            recording.groupId.map { ($0, UnifiedSearchResultKey.group($0)) }
        })
        let transcriptsByID = Self.firstValueDictionary(transcripts.map { ($0.id, $0) })
        var builders: [UnifiedSearchResultKey: Builder] = [:]

        for recording in recordings {
            let key = recordingRoots[recording.id]!
            var builder = builders[key] ?? Builder(key: key)
            builder.recordingIDs.insert(recording.id)
            builder.add(
                artifact: .recording(recording.id),
                title: recording.name,
                content: "",
                date: recording.date,
                status: nil
            )
            if let groupName = recording.groupName, !groupName.isEmpty {
                builder.titles.append(Self.normalize(groupName))
                if recording.groupId != nil { builder.groupDisplayTitle = groupName }
            }
            builders[key] = builder
        }

        var transcriptRoots: [UUID: UnifiedSearchResultKey] = [:]
        for transcript in transcripts {
            // The persisted recording relationship remains the logical root even if
            // that parent is currently missing. This also collapses multiple stale
            // transcripts and a processing job that reference the same recording ID.
            let key = recordingRoots[transcript.recordingId]
                ?? groupRoots[transcript.recordingId]
                ?? .recording(transcript.recordingId)
            if transcriptRoots[transcript.id] == nil { transcriptRoots[transcript.id] = key }
            var builder = builders[key] ?? Builder(key: key)
            builder.isOrphan = recordingRoots[transcript.recordingId] == nil
                && groupRoots[transcript.recordingId] == nil
            builder.isStale = builder.isStale || builder.isOrphan
            builder.add(
                artifact: .transcript(transcript.id),
                title: transcript.name,
                content: [transcript.content, transcript.formattedContent ?? ""].joined(separator: " "),
                date: transcript.date,
                status: transcript.status
            )
            builders[key] = builder
        }

        for summary in summaries {
            let key: UnifiedSearchResultKey
            if let transcript = transcriptsByID[summary.transcriptId] {
                key = transcriptRoots[transcript.id] ?? .recording(transcript.recordingId)
            } else {
                key = .orphanSummary(summary.id)
            }
            var builder = builders[key] ?? Builder(key: key)
            if transcriptsByID[summary.transcriptId] == nil {
                builder.isOrphan = true
                builder.isStale = true
            }
            builder.add(
                artifact: .summary(summary.id),
                title: summary.name,
                content: MarkdownTextRenderer.plainText(from: summary.content),
                date: summary.date,
                status: summary.status
            )
            builders[key] = builder
        }

        for job in jobs {
            let key = recordingRoots[job.recordingID]
                ?? groupRoots[job.recordingID]
                ?? .recording(job.recordingID)
            var builder = builders[key] ?? Builder(key: key)
            if recordingRoots[job.recordingID] == nil && groupRoots[job.recordingID] == nil {
                builder.isStale = true
            }
            builder.addJob(job)
            builders[key] = builder
        }

        let tagsByID = Self.firstValueDictionary(metadata.tags.map { ($0.id, $0) })
        let artifactRoots = Self.artifactRootMap(builders: builders)
        for item in metadata.items {
            guard let key = artifactRoots[item.key] else { continue }
            var builder = builders[key]!
            builder.isFavorite = builder.isFavorite || item.isFavorite
            builder.tagIDs.formUnion(item.tagIDs.filter { tagsByID[$0] != nil })
            builders[key] = builder
        }

        entries = builders.values.map { $0.finish(tagsByID: tagsByID) }
    }

    func search(
        _ query: UnifiedSearchQuery,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UnifiedSearchResult] {
        let normalizedQuery = Self.normalize(query.text)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        let range = Self.dateRange(query.date, now: now, calendar: calendar)

        return entries.compactMap { entry -> Ranked? in
            guard !query.favoritesOnly || entry.isFavorite,
                  Self.matches(query.status, entry.status),
                  query.tagIDs.isSubset(of: entry.tagIDs),
                  range.map({ $0.contains(entry.date) }) ?? true,
                  terms.allSatisfy({ entry.searchText.contains($0) }) else { return nil }

            let rank = entry.rank(query: normalizedQuery, terms: terms)
            return Ranked(entry: entry, rank: rank, destination: entry.destination(query: normalizedQuery, terms: terms))
        }
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.entry.date != $1.entry.date { return $0.entry.date > $1.entry.date }
            return $0.entry.stableKey < $1.entry.stableKey
        }
        .map { ranked in
            let entry = ranked.entry
            return UnifiedSearchResult(
                key: entry.key,
                title: entry.title,
                date: entry.date,
                status: entry.status,
                isFavorite: entry.isFavorite,
                tags: entry.tags,
                destination: ranked.destination,
                isStale: entry.isStale,
                isOrphan: entry.isOrphan,
                previews: entry.previews(matching: terms)
            )
        }
    }

    private static func artifactRootMap(builders: [UnifiedSearchResultKey: Builder]) -> [LibraryItemKey: UnifiedSearchResultKey] {
        var result: [LibraryItemKey: UnifiedSearchResultKey] = [:]
        for (root, builder) in builders {
            if case .group(let id) = root {
                result[LibraryItemKey(kind: .group, id: id)] = root
            }
            for artifact in builder.artifacts {
                switch artifact.destination {
                case .recording(let id): result[LibraryItemKey(kind: .recording, id: id)] = root
                case .transcript(let id): result[LibraryItemKey(kind: .transcript, id: id)] = root
                case .summary(let id): result[LibraryItemKey(kind: .summary, id: id)] = root
                case .group: break
                }
            }
        }
        return result
    }

    /// Persisted JSON is user-owned and may contain duplicated identifiers after an
    /// interrupted migration or manual repair. Keep the first value deterministically
    /// instead of using Dictionary(uniqueKeysWithValues:), which traps the process.
    private static func firstValueDictionary<Key: Hashable, Value>(
        _ pairs: [(Key, Value)]
    ) -> [Key: Value] {
        pairs.reduce(into: [:]) { result, pair in
            if result[pair.0] == nil { result[pair.0] = pair.1 }
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func matches(_ filter: UnifiedSearchStatusFilter, _ status: UnifiedSearchStatus) -> Bool {
        switch filter {
        case .all: return true
        case .unprocessed: return status == .unprocessed
        case .processing: return status == .processing
        case .needsAttention: return status == .needsAttention
        case .completed: return status == .completed
        }
    }

    private static func dateRange(_ filter: UnifiedSearchDateFilter, now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let end = now
        switch filter {
        case .any: return nil
        case .today:
            return calendar.startOfDay(for: now)...end
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: end) ?? .distantPast)...end
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: end) ?? .distantPast)...end
        case .custom(let first, let second):
            return min(first, second)...max(first, second)
        }
    }
}

private extension UnifiedSearchIndex {
    struct Artifact: Sendable {
        let destination: UnifiedSearchDestination
        let title: String
        let content: String
        let sentences: [SearchSentence]
        let date: Date
        let status: ProcessingStatus?

        func matchCount(_ terms: [String]) -> Int {
            terms.reduce(into: 0) { if title.contains($1) || content.contains($1) { $0 += 1 } }
        }
    }

    struct SearchSentence: Sendable {
        let text: String
        let normalized: String
    }

    struct Builder {
        let key: UnifiedSearchResultKey
        var artifacts: [Artifact] = []
        var recordingIDs: Set<UUID> = []
        var titles: [String] = []
        var displayTitle: String?
        var groupDisplayTitle: String?
        var isFavorite = false
        var tagIDs: Set<UUID> = []
        var jobStates: [ProcessingJobState] = []
        var isStale = false
        var isOrphan = false

        mutating func add(artifact: UnifiedSearchDestination, title: String, content: String, date: Date, status: ProcessingStatus?) {
            let normalizedTitle = UnifiedSearchIndex.normalize(title)
            artifacts.append(Artifact(
                destination: artifact,
                title: normalizedTitle,
                content: UnifiedSearchIndex.normalize(content),
                sentences: content.sentences.map { SearchSentence(text: $0, normalized: UnifiedSearchIndex.normalize($0)) },
                date: date,
                status: status
            ))
            titles.append(normalizedTitle)
            if displayTitle == nil || date >= (artifacts.dropLast().map(\.date).max() ?? .distantPast) { displayTitle = title }
        }

        mutating func addJob(_ job: ProcessingJob) {
            jobStates.append(job.state)
            let title = UnifiedSearchIndex.normalize(job.recordingName)
            titles.append(title)
            if displayTitle == nil { displayTitle = job.recordingName }
        }

        func finish(tagsByID: [UUID: LibraryTag]) -> Entry {
            let tags = tagIDs.compactMap { tagsByID[$0] }.sorted {
                UnifiedSearchIndex.normalize($0.name) < UnifiedSearchIndex.normalize($1.name)
            }
            let normalizedTags = tags.map { UnifiedSearchIndex.normalize($0.name) }
            let date = artifacts.map(\.date).max() ?? .distantPast
            let status = resolvedStatus
            let fallback = fallbackDestination
            let searchText = (titles + normalizedTags + artifacts.map(\.content)).joined(separator: " ")
            return Entry(
                key: key,
                title: groupDisplayTitle ?? displayTitle ?? "Missing Library Item",
                date: date,
                status: status,
                isFavorite: isFavorite,
                tags: tags,
                tagIDs: tagIDs,
                normalizedTags: normalizedTags,
                titles: titles,
                searchText: searchText,
                artifacts: artifacts,
                fallback: fallback,
                isStale: isStale,
                isOrphan: isOrphan
            )
        }

        private var resolvedStatus: UnifiedSearchStatus {
            if isStale || artifacts.contains(where: { $0.status == .failed }) || jobStates.contains(where: {
                [.transcriptionFailed, .summaryFailed, .waitingForRecording, .waitingForTranscriptionKey, .waitingForSummaryKey].contains($0)
            }) { return .needsAttention }
            if artifacts.contains(where: { $0.status == .pending || $0.status == .inProgress }) || jobStates.contains(where: {
                [.queued, .transcribing, .summarizing].contains($0)
            }) { return .processing }
            if artifacts.contains(where: { $0.status == .completed }) || jobStates.contains(.completed) { return .completed }
            return .unprocessed
        }

        private var fallbackDestination: UnifiedSearchDestination {
            if let summary = artifacts.filter({
                if case .summary = $0.destination { return $0.status == .completed }
                return false
            }).max(by: { $0.date < $1.date }) { return summary.destination }
            if let transcript = artifacts.filter({
                if case .transcript = $0.destination { return true }
                return false
            }).max(by: { $0.date < $1.date }) { return transcript.destination }
            switch key {
            case .group(let id): return .group(id)
            case .recording(let id): return .recording(id)
            case .orphanSummary(let id): return .summary(id)
            }
        }
    }

    struct Entry: Sendable {
        let key: UnifiedSearchResultKey
        let title: String
        let date: Date
        let status: UnifiedSearchStatus
        let isFavorite: Bool
        let tags: [LibraryTag]
        let tagIDs: Set<UUID>
        let normalizedTags: [String]
        let titles: [String]
        let searchText: String
        let artifacts: [Artifact]
        let fallback: UnifiedSearchDestination
        let isStale: Bool
        let isOrphan: Bool

        var stableKey: String {
            switch key {
            case .recording(let id): return "0-\(id.uuidString)"
            case .group(let id): return "1-\(id.uuidString)"
            case .orphanSummary(let id): return "2-\(id.uuidString)"
            }
        }

        func rank(query: String, terms: [String]) -> Int {
            guard !terms.isEmpty else { return 5 }
            if titles.contains(query) { return 0 }
            if titles.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if titles.contains(where: { $0.contains(query) }) { return 2 }
            if terms.allSatisfy({ term in normalizedTags.contains(where: { $0.contains(term) }) }) { return 3 }
            return 4
        }

        func destination(query: String, terms: [String]) -> UnifiedSearchDestination {
            guard !terms.isEmpty else { return fallback }
            let matches = artifacts.map { artifact in
                (artifact, artifact.matchCount(terms), artifact.title == query ? 0 : artifact.title.hasPrefix(query) ? 1 : artifact.title.contains(query) ? 2 : 4)
            }.filter { $0.1 > 0 }
            return matches.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                if $0.0.date != $1.0.date { return $0.0.date > $1.0.date }
                return String(describing: $0.0.destination) < String(describing: $1.0.destination)
            }.first?.0.destination ?? fallback
        }

        func previews(matching terms: [String]) -> [UnifiedSearchPreview] {
            guard !terms.isEmpty else { return [] }
            return artifacts.flatMap { artifact in
                artifact.sentences.enumerated().compactMap { index, sentence -> UnifiedSearchPreview? in
                    guard terms.allSatisfy({ sentence.normalized.contains($0) }) else { return nil }
                    return UnifiedSearchPreview(
                        destination: artifact.destination,
                        match: sentence.text,
                        matchIndex: index
                    )
                }
            }
        }
    }

    struct Ranked {
        let entry: Entry
        let rank: Int
        let destination: UnifiedSearchDestination
    }
}

private extension String {
    var sentences: [String] {
        var result: [String] = []
        enumerateSubstrings(in: startIndex..<endIndex, options: .bySentences) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            result.append(sentence)
        }
        return result
    }
}
