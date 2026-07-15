import SwiftUI

struct UnifiedSearchView: View {
    @EnvironmentObject private var librarySearch: LibrarySearchController
    @EnvironmentObject private var navigationRouter: AppNavigationRouter
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var status = "all"
    @State private var date = "any"
    @State private var selectedTags: Set<UUID> = []

    private var query: UnifiedSearchQuery {
        UnifiedSearchQuery(
            text: searchText,
            favoritesOnly: favoritesOnly,
            status: statusFilter,
            date: dateFilter,
            tagIDs: selectedTags
        )
    }

    private var results: [UnifiedSearchResult] { librarySearch.results(for: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Search").font(.largeTitle).fontWeight(.bold)
                Spacer()
                if librarySearch.isRebuilding { ProgressView().controlSize(.small) }
            }
            TextField("Search recordings, transcripts, summaries, and tags", text: $searchText)
                .textFieldStyle(.roundedBorder)
            filters
            if let error = librarySearch.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Spacer()
                    Button("Dismiss") { librarySearch.clearError() }
                }
                .font(.caption)
            }
            if results.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Matching Library Items" : "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try changing the search text or filters.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, id: \.key) { result in
                    Button { open(result.destination) } label: {
                        SearchResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Toggle("Favorites", isOn: $favoritesOnly).toggleStyle(.checkbox)
            Picker("Status", selection: $status) {
                Text("Any status").tag("all")
                Text("Unprocessed").tag("unprocessed")
                Text("Processing").tag("processing")
                Text("Needs attention").tag("attention")
                Text("Completed").tag("completed")
            }
            .frame(width: 180)
            Picker("Date", selection: $date) {
                Text("Any date").tag("any")
                Text("Today").tag("today")
                Text("Last 7 days").tag("7")
                Text("Last 30 days").tag("30")
            }
            .frame(width: 150)
            Menu {
                if librarySearch.metadata.tags.isEmpty { Text("No tags yet") }
                ForEach(librarySearch.metadata.tags) { tag in
                    Button {
                        if selectedTags.contains(tag.id) { selectedTags.remove(tag.id) }
                        else { selectedTags.insert(tag.id) }
                    } label: {
                        Label(tag.name, systemImage: selectedTags.contains(tag.id) ? "checkmark" : "tag")
                    }
                }
                if !selectedTags.isEmpty {
                    Divider()
                    Button("Clear tag filter") { selectedTags.removeAll() }
                }
            } label: {
                Label(selectedTags.isEmpty ? "Tags" : "Tags (\(selectedTags.count))", systemImage: "tag")
            }
            Spacer()
        }
    }

    private var statusFilter: UnifiedSearchStatusFilter {
        switch status {
        case "unprocessed": return .unprocessed
        case "processing": return .processing
        case "attention": return .needsAttention
        case "completed": return .completed
        default: return .all
        }
    }

    private var dateFilter: UnifiedSearchDateFilter {
        switch date {
        case "today": return .today
        case "7": return .last7Days
        case "30": return .last30Days
        default: return .any
        }
    }

    private func open(_ destination: UnifiedSearchDestination) {
        switch destination {
        case .recording(let id): navigationRouter.openRecording(id)
        case .group(let id): navigationRouter.openRecordingGroup(id)
        case .transcript(let id): navigationRouter.openTranscript(id)
        case .summary(let id): navigationRouter.openSummary(id)
        }
    }
}

private struct SearchResultRow: View {
    let result: UnifiedSearchResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resultIcon).font(.title2).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(result.title).font(.headline)
                    Text(artifactLabel)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
                    if result.isFavorite { Image(systemName: "star.fill").foregroundColor(.yellow) }
                    statusBadge
                }
                HStack(spacing: 6) {
                    Text(result.date, style: .date)
                    ForEach(result.tags) { tag in
                        Text(tag.name).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                    }
                    if result.isStale { Label("Stale", systemImage: "clock.badge.exclamationmark") }
                    if result.isOrphan { Label("Missing parent", systemImage: "link.badge.plus") }
                }
                .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
    }

    private var resultIcon: String {
        switch result.destination {
        case .recording: return "waveform"
        case .group: return "folder"
        case .transcript: return "doc.text"
        case .summary: return "list.bullet.clipboard"
        }
    }

    private var artifactLabel: String {
        switch result.destination {
        case .recording: return "Recording"
        case .group: return "Group"
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        }
    }

    private var statusBadge: some View {
        Text(statusText).font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundColor(statusColor).background(statusColor.opacity(0.12)).clipShape(Capsule())
    }

    private var statusText: String {
        switch result.status {
        case .unprocessed: return "Unprocessed"
        case .processing: return "Processing"
        case .needsAttention: return "Needs attention"
        case .completed: return "Completed"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .unprocessed: return .secondary
        case .processing: return .blue
        case .needsAttention: return .orange
        case .completed: return .green
        }
    }
}
