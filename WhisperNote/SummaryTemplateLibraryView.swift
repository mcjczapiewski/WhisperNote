import SwiftUI

struct SummaryTemplatePicker: View {
    @ObservedObject var controller: SummaryTemplateController
    let selectedTemplateID: String?
    var allowsCustom = false
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            if allowsCustom {
                Button("Custom") { onSelect(nil) }
                Divider()
            }
            ForEach(controller.templates) { template in
                Button {
                    onSelect(template.stableSelectionID)
                } label: {
                    if template.matchesSelectionID(selectedTemplateID ?? "") {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(controller.template(matching: selectedTemplateID)?.name ?? "Custom")
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
        .accessibilityLabel("Summary template")
    }
}

struct SummaryTemplateLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: SummaryTemplateController
    @EnvironmentObject private var librarySearch: LibrarySearchController
    @State private var editor: TemplateEditorState?
    @State private var templateToDelete: SummaryTemplate?

    private var mutationsDisabled: Bool {
        librarySearch.isRebinding || controller.isLibraryRebinding
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Summary Templates").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            if let notice = controller.notice {
                Label(noticeText(notice), systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .overlay(alignment: .trailing) {
                        Button("Dismiss") { controller.clearNotice() }
                            .buttonStyle(.link).padding(.trailing)
                    }
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityLabel("Template error: \(error)")
            }

            List {
                Section("Built-in") {
                    ForEach(controller.templates.filter(\.isBuiltIn)) { template in
                        templateRow(template)
                    }
                }
                Section("Custom") {
                    ForEach(controller.templates.filter { !$0.isBuiltIn }) { template in
                        templateRow(template)
                    }
                    .onMove(perform: moveCustom)
                }
            }

            HStack {
                Button {
                    editor = TemplateEditorState(template: nil)
                } label: {
                    Label("New Template", systemImage: "plus")
                }
                .disabled(mutationsDisabled)
                Spacer()
                if mutationsDisabled {
                    ProgressView().controlSize(.small)
                    Text("Changing library…").foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 540)
        .task { if controller.templates.isEmpty { await controller.load() } }
        .sheet(item: $editor) { state in
            SummaryTemplateEditorSheet(state: state) { name, prompt in
                if let template = state.template {
                    return await controller.update(id: template.id, name: name, prompt: prompt) != nil
                }
                return await controller.create(name: name, prompt: prompt) != nil
            }
        }
        .alert("Delete Template", isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { templateToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = templateToDelete?.id { Task { await controller.delete(id: id) } }
                templateToDelete = nil
            }
        } message: {
            Text("Delete “\(templateToDelete?.name ?? "this template")”? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func templateRow(_ template: SummaryTemplate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(template.name).fontWeight(.medium)
                    if template.isDefault {
                        Text("Default").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
                    }
                    if template.isBuiltIn { Text("Built-in").font(.caption).foregroundColor(.secondary) }
                }
                Text(template.prompt).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            if !template.isDefault {
                Button("Set Default") { Task { await controller.setDefault(id: template.id) } }
                    .disabled(mutationsDisabled)
            }
            Button("Duplicate") { Task { _ = await controller.duplicate(id: template.id) } }
                .disabled(mutationsDisabled)
            if !template.isBuiltIn {
                Button("Edit") { editor = TemplateEditorState(template: template) }
                    .disabled(mutationsDisabled)
                Button(role: .destructive) { templateToDelete = template } label: {
                    Image(systemName: "trash")
                }
                .help("Delete template")
                .disabled(mutationsDisabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func moveCustom(from offsets: IndexSet, to destination: Int) {
        guard !mutationsDisabled else { return }
        var customs = controller.templates.filter { !$0.isBuiltIn }
        customs.move(fromOffsets: offsets, toOffset: destination)
        Task { await controller.reorderCustomTemplates(ids: customs.map(\.id)) }
    }

    private func noticeText(_ notice: SummaryTemplateRepositoryNotice) -> String {
        switch notice {
        case .defaultChangedToMeetingMinutes:
            return "The previous default is unavailable. Meeting Minutes is now the default."
        }
    }
}

private struct TemplateEditorState: Identifiable {
    let id = UUID()
    let template: SummaryTemplate?
}

private struct SummaryTemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: SummaryTemplateController
    let state: TemplateEditorState
    let onSave: (String, String) async -> Bool
    @State private var name: String
    @State private var prompt: String
    @State private var isSaving = false

    init(state: TemplateEditorState, onSave: @escaping (String, String) async -> Bool) {
        self.state = state
        self.onSave = onSave
        _name = State(initialValue: state.template?.name ?? "")
        _prompt = State(initialValue: state.template?.prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.template == nil ? "New Summary Template" : "Edit Summary Template").font(.headline)
            TextField("Template name", text: $name)
                .accessibilityLabel("Template name")
                .onChange(of: name) { _ in controller.clearError() }
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 280)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Template prompt")
                .onChange(of: prompt) { _ in controller.clearError() }
            if let message = validationMessage ?? controller.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("Template validation error: \(message)")
            }
            HStack {
                Text("\(prompt.count)/\(SummaryTemplateRepository.maximumPromptLength)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    guard !isSaving, validationMessage == nil else { return }
                    isSaving = true
                    controller.clearError()
                    Task {
                        let succeeded = await onSave(name, prompt)
                        isSaving = false
                        if succeeded { dismiss() }
                    }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || validationMessage != nil)
            }
        }
        .padding()
        .frame(width: 620, height: 460)
    }

    private var validationMessage: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Template name is required." }
        if trimmedName.count > SummaryTemplateRepository.maximumNameLength {
            return "Template names cannot exceed \(SummaryTemplateRepository.maximumNameLength) characters."
        }
        if trimmedPrompt.isEmpty { return "Template prompt is required." }
        if trimmedPrompt.count > SummaryTemplateRepository.maximumPromptLength {
            return "Template prompts cannot exceed \(SummaryTemplateRepository.maximumPromptLength) characters."
        }
        return nil
    }
}
