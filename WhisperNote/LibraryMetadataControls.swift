import SwiftUI

extension View {
    func libraryActionButton() -> some View {
        buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.callout.weight(.medium))
    }
}

struct LibraryMetadataControls: View {
    @EnvironmentObject private var librarySearch: LibrarySearchController
    let itemKey: LibraryItemKey
    @State private var showingTagManager = false

    private var item: LibraryItemMetadata { librarySearch.metadata(for: itemKey) }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task { await librarySearch.setFavorite(!item.isFavorite, for: itemKey) }
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundColor(item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Menu {
                if librarySearch.metadata.tags.isEmpty {
                    Text("No tags yet")
                }
                ForEach(librarySearch.metadata.tags) { tag in
                    Button {
                        Task {
                            if item.tagIDs.contains(tag.id) {
                                await librarySearch.removeTag(tag.id, from: itemKey)
                            } else {
                                await librarySearch.assignTag(tag.id, to: itemKey)
                            }
                        }
                    } label: {
                        Label(tag.name, systemImage: item.tagIDs.contains(tag.id) ? "checkmark" : "tag")
                    }
                }
                Divider()
                Button("Manage Tags…") { showingTagManager = true }
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .help("Assign or manage tags")
        }
        .sheet(isPresented: $showingTagManager) {
            LibraryTagManager(assigningTo: itemKey)
                .environmentObject(librarySearch)
        }
    }
}

private struct LibraryTagManager: View {
    @EnvironmentObject private var librarySearch: LibrarySearchController
    @Environment(\.dismiss) private var dismiss
    let assigningTo: LibraryItemKey
    @State private var newTagName = ""
    @State private var renameValues: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Tags").font(.title2).fontWeight(.semibold)
            HStack {
                TextField("New tag", text: $newTagName)
                Button("Create & Assign") {
                    let name = newTagName
                    newTagName = ""
                    Task { await librarySearch.createTag(named: name, assigningTo: assigningTo) }
                }
                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(librarySearch.metadata.tags) { tag in
                    HStack {
                        Toggle(tag.name, isOn: assignmentBinding(tag.id))
                            .toggleStyle(.checkbox)
                        Spacer()
                        TextField("Tag name", text: renameBinding(tag))
                            .frame(width: 180)
                        Button("Rename") {
                            Task { await librarySearch.renameTag(tag.id, to: renameValues[tag.id] ?? tag.name) }
                        }
                        Button(role: .destructive) {
                            Task { await librarySearch.deleteTag(tag.id) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            HStack {
                if let error = librarySearch.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
    }

    private func assignmentBinding(_ tagID: UUID) -> Binding<Bool> {
        Binding(
            get: { librarySearch.metadata(for: assigningTo).tagIDs.contains(tagID) },
            set: { value in
                Task {
                    if value { await librarySearch.assignTag(tagID, to: assigningTo) }
                    else { await librarySearch.removeTag(tagID, from: assigningTo) }
                }
            }
        )
    }

    private func renameBinding(_ tag: LibraryTag) -> Binding<String> {
        Binding(
            get: { renameValues[tag.id] ?? tag.name },
            set: { renameValues[tag.id] = $0 }
        )
    }
}
