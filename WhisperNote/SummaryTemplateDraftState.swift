import Foundation

struct SummaryTemplateDraftState: Equatable, Sendable {
    struct RequestContext: Equatable, Sendable {
        let revision: UInt64
        let prompt: String
        let model: String
        let sourceTemplateID: String?
        let sourceTemplateName: String?
        let sourcePrompt: String?
        let sourceIsBuiltIn: Bool
        let isCustom: Bool
        let isDirty: Bool
        let isGuided: Bool
        let didExplicitlyChoose: Bool
        let isInitialized: Bool
    }

    private(set) var revision: UInt64 = 0
    private(set) var prompt = ""
    private(set) var model = defaultLLMModelId
    private(set) var sourceTemplateID: String?
    private(set) var sourceTemplateName: String?
    private(set) var sourcePrompt: String?
    private(set) var sourceIsBuiltIn = false
    private(set) var isCustom = true
    private(set) var isDirty = false
    private(set) var isGuided = false
    private(set) var didExplicitlyChoose = false
    private(set) var isInitialized = false

    var canSaveAsTemplate: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= SummaryTemplateRepository.maximumPromptLength
    }

    var canUpdateSourceTemplate: Bool {
        sourceTemplateID != nil && !sourceIsBuiltIn && prompt != sourcePrompt && canSaveAsTemplate
    }

    var displayName: String { isCustom ? "Custom" : (sourceTemplateName ?? "Custom") }

    mutating func initializeDefaultIfPristine(_ template: SummaryTemplate, model: String) {
        guard !isInitialized, !didExplicitlyChoose, !isDirty else { return }
        apply(template: template, model: model, explicit: false)
        isInitialized = true
        advanceRevision()
    }

    mutating func initializeHistorical(_ summary: Summary, fallbackModel: String) {
        guard !isInitialized, !didExplicitlyChoose, !isDirty else { return }
        prompt = summary.prompt
        model = summary.model.isEmpty ? fallbackModel : summary.model
        sourceTemplateID = summary.templateID
        sourceTemplateName = summary.templateName
        sourcePrompt = summary.prompt
        sourceIsBuiltIn = summary.templateID.flatMap(SummaryTemplatePresetCatalog.preset(id:)) != nil
        isCustom = false
        isDirty = false
        isGuided = false
        isInitialized = true
        advanceRevision()
    }

    mutating func selectTemplate(_ template: SummaryTemplate, model: String) {
        apply(template: template, model: model, explicit: true)
        isInitialized = true
        advanceRevision()
    }

    mutating func chooseGuided(prompt: String, model: String) {
        self.prompt = prompt
        self.model = model
        sourceTemplateID = nil
        sourceTemplateName = nil
        sourcePrompt = nil
        sourceIsBuiltIn = false
        isCustom = true
        isDirty = false
        isGuided = true
        didExplicitlyChoose = true
        isInitialized = true
        advanceRevision()
    }

    mutating func refreshGuidedPrompt(_ prompt: String) {
        guard isGuided, !isDirty else { return }
        guard self.prompt != prompt else { return }
        self.prompt = prompt
        advanceRevision()
    }

    mutating func editPrompt(_ prompt: String) {
        self.prompt = prompt
        isCustom = true
        isDirty = true
        isGuided = false
        didExplicitlyChoose = true
        isInitialized = true
        advanceRevision()
    }

    @discardableResult
    mutating func applyEnhancedPrompt(_ prompt: String, ifUnchanged context: RequestContext) -> Bool {
        guard isCurrent(context) else { return false }
        editPrompt(prompt)
        return true
    }

    mutating func setModel(_ model: String) {
        guard self.model != model else { return }
        self.model = model
        advanceRevision()
    }

    @discardableResult
    mutating func acceptSavedTemplate(_ template: SummaryTemplate, ifUnchanged context: RequestContext) -> Bool {
        guard isCurrent(context) else { return false }
        sourceTemplateID = template.stableSelectionID
        sourceTemplateName = template.name
        sourcePrompt = template.prompt
        sourceIsBuiltIn = template.isBuiltIn
        prompt = template.prompt
        isCustom = false
        isDirty = false
        isGuided = false
        didExplicitlyChoose = true
        isInitialized = true
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func acceptUpdatedSource(_ template: SummaryTemplate, ifUnchanged context: RequestContext) -> Bool {
        acceptSavedTemplate(template, ifUnchanged: context)
    }

    func requestContext() -> RequestContext {
        RequestContext(
            revision: revision,
            prompt: prompt,
            model: model,
            sourceTemplateID: sourceTemplateID,
            sourceTemplateName: sourceTemplateName,
            sourcePrompt: sourcePrompt,
            sourceIsBuiltIn: sourceIsBuiltIn,
            isCustom: isCustom,
            isDirty: isDirty,
            isGuided: isGuided,
            didExplicitlyChoose: didExplicitlyChoose,
            isInitialized: isInitialized
        )
    }

    func isCurrent(_ context: RequestContext) -> Bool { requestContext() == context }

    mutating func invalidateRequests() { advanceRevision() }

    func snapshot() -> SummaryGenerationSnapshot {
        SummaryGenerationSnapshot(
            templateID: sourceTemplateID,
            templateName: sourceTemplateName,
            prompt: prompt,
            model: model
        )
    }

    private mutating func apply(template: SummaryTemplate, model: String, explicit: Bool) {
        prompt = template.prompt
        self.model = model
        sourceTemplateID = template.stableSelectionID
        sourceTemplateName = template.name
        sourcePrompt = template.prompt
        sourceIsBuiltIn = template.isBuiltIn
        isCustom = false
        isDirty = false
        isGuided = false
        didExplicitlyChoose = explicit
    }

    private mutating func advanceRevision() { revision &+= 1 }
}
