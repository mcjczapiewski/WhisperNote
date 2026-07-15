import Foundation
import SwiftUI

/// Main-actor presentation and resolution layer over the actor-backed template store.
/// A read failure exposes the canonical Meeting Minutes preset in memory while leaving
/// the unreadable file untouched for explicit user recovery.
@MainActor
final class SummaryTemplateController: ObservableObject {
    @Published private(set) var templates: [SummaryTemplate] = []
    @Published var selectedTemplateID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: SummaryTemplateRepositoryNotice?
    @Published private(set) var isLibraryRebinding = false

    private let repository: SummaryTemplateRepository
    private var hasLoaded = false
    private var libraryGeneration = 0
    private var operationsInFlight = 0
    private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(repository: SummaryTemplateRepository = SummaryTemplateRepository()) {
        self.repository = repository
    }

    @discardableResult
    func load() async -> Bool {
        guard !isLibraryRebinding else { return false }
        let generation = libraryGeneration
        beginOperation()
        defer { finishOperation() }
        do {
            let loaded = try await repository.templates()
            guard generation == libraryGeneration else { return false }
            publish(loaded, notice: await repository.consumeNotice())
        } catch {
            guard generation == libraryGeneration else { return false }
            publishFallback(error)
        }
        hasLoaded = true
        return true
    }

    func rebind(to fileURL: URL) async {
        do {
            let loaded = try await repository.rebind(to: fileURL)
            libraryGeneration += 1
            publish(loaded, notice: await repository.consumeNotice())
            hasLoaded = true
        } catch {
            // The repository keeps its prior binding on failure; mirror that
            // transactionality by preserving all previously published UI state.
            errorMessage = error.localizedDescription
        }
    }

    func preflight(fileURL: URL) async throws -> SummaryTemplateLibraryCandidate {
        try await repository.preflight(fileURL: fileURL)
    }

    func accept(_ candidate: SummaryTemplateLibraryCandidate) async throws {
        let loaded = try await repository.accept(candidate)
        libraryGeneration += 1
        publish(loaded, notice: await repository.consumeNotice())
        hasLoaded = true
    }

    func beginLibraryRebind() async -> Bool {
        guard !isLibraryRebinding else { return false }
        isLibraryRebinding = true
        if operationsInFlight > 0 {
            await withCheckedContinuation { operationDrainWaiters.append($0) }
        }
        return true
    }

    func finishLibraryRebind() { isLibraryRebinding = false }

    func resumeAfterLibraryRebindCancellation() { isLibraryRebinding = false }

    func select(_ selectionID: String?) {
        guard let selectionID,
              templates.contains(where: { $0.matchesSelectionID(selectionID) }) else {
            selectedTemplateID = defaultTemplate.stableSelectionID
            return
        }
        selectedTemplateID = selectionID
    }

    func template(matching selectionID: String?) -> SummaryTemplate? {
        guard let selectionID else { return nil }
        return templates.first(where: { $0.matchesSelectionID(selectionID) })
    }

    var selectedTemplate: SummaryTemplate? {
        template(matching: selectedTemplateID)
    }

    var defaultTemplateValue: SummaryTemplate { defaultTemplate }

    @discardableResult
    func create(name: String, prompt: String) async -> SummaryTemplate? {
        await mutate { try await self.repository.create(name: name, prompt: prompt) }
    }

    @discardableResult
    func update(id: UUID, name: String, prompt: String) async -> SummaryTemplate? {
        await mutate { try await self.repository.update(id: id, name: name, prompt: prompt) }
    }

    @discardableResult
    func duplicate(id: UUID) async -> SummaryTemplate? {
        await mutate { try await self.repository.duplicate(id: id) }
    }

    func delete(id: UUID) async {
        _ = await mutate { try await self.repository.delete(id: id) }
    }

    func setDefault(id: UUID) async {
        _ = await mutate { try await self.repository.setDefault(id: id) }
    }

    func reorderCustomTemplates(ids: [UUID]) async {
        _ = await mutate { try await self.repository.reorderCustomTemplates(ids: ids) }
    }

    @discardableResult
    func reload() async -> Bool { await load() }

    func clearError() { errorMessage = nil }

    func currentSelectionSnapshot(model: String) -> SummaryGenerationSnapshot {
        let selected = selectedTemplateID.flatMap(template(matching:)) ?? defaultTemplate
        return snapshot(for: selected, model: model)
    }

    /// Preserves the selected template as provenance while freezing the exact
    /// visible working draft, including manual edits or prompt enhancement.
    func currentSelectionSnapshot(prompt: String, model: String) -> SummaryGenerationSnapshot {
        let selected = selectedTemplateID.flatMap(template(matching:)) ?? defaultTemplate
        return SummaryGenerationSnapshot(
            templateID: selected.stableSelectionID,
            templateName: selected.name,
            prompt: prompt,
            model: model
        )
    }

    func snapshot(selectionID: String?, prompt: String, model: String) -> SummaryGenerationSnapshot {
        guard let selected = template(matching: selectionID) else {
            return SummaryGenerationSnapshot(prompt: prompt, model: model)
        }
        return SummaryGenerationSnapshot(
            templateID: selected.stableSelectionID,
            templateName: selected.name,
            prompt: prompt,
            model: model
        )
    }

    /// Async by contract so workflow handoff can resolve and freeze the per-library
    /// default before creating a durable job.
    func defaultSelectionSnapshot(model: String) async -> SummaryGenerationSnapshot {
        if !hasLoaded { await load() }
        return snapshot(for: defaultTemplate, model: model)
    }

    func clearNotice() {
        notice = nil
    }

    private var defaultTemplate: SummaryTemplate {
        templates.first(where: \.isDefault) ?? canonicalFallback
    }

    private var canonicalFallback: SummaryTemplate {
        SummaryTemplatePresetCatalog.preset(id: SummaryTemplatePresetCatalog.meetingMinutesID)!
    }

    private func snapshot(for template: SummaryTemplate, model: String) -> SummaryGenerationSnapshot {
        SummaryGenerationSnapshot(
            templateID: template.stableSelectionID,
            templateName: template.name,
            prompt: template.prompt,
            model: model
        )
    }

    private func publish(_ loaded: [SummaryTemplate], notice: SummaryTemplateRepositoryNotice?) {
        templates = loaded
        errorMessage = nil
        self.notice = notice
        if let selectedTemplateID,
           loaded.contains(where: { $0.matchesSelectionID(selectedTemplateID) }) {
            return
        }
        selectedTemplateID = defaultTemplate.stableSelectionID
    }

    private func publishFallback(_ error: Error) {
        templates = [canonicalFallback]
        selectedTemplateID = canonicalFallback.stableSelectionID
        errorMessage = error.localizedDescription
        notice = nil
    }

    private func mutate<T>(_ operation: @escaping () async throws -> T) async -> T? {
        guard !isLibraryRebinding else {
            errorMessage = "Summary templates are unavailable while the library is changing."
            return nil
        }
        beginOperation()
        defer { finishOperation() }
        do {
            let result = try await operation()
            let loaded = try await repository.templates()
            publish(loaded, notice: await repository.consumeNotice())
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func beginOperation() { operationsInFlight += 1 }

    private func finishOperation() {
        operationsInFlight -= 1
        if operationsInFlight == 0 {
            let waiters = operationDrainWaiters
            operationDrainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
