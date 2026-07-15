import Foundation
import SwiftUI

@MainActor
class SummaryManager: ObservableObject {
    @Published var summaries: [Summary] = []
    @AppStorage("defaultLLMModel") var defaultModel = defaultLLMModelId

    private var boundSummariesDirectory: URL
    private let allowsLegacyMigration: Bool
    private let apiKeyProvider: () -> String
    private var libraryGeneration = 0
    private(set) var isLibraryRebinding = false
    private let debugLogger = DebugLogger.shared
    private var apiKey: String { apiKeyProvider() }
    var testSummaryOperation: ((String, String, Transcript) async throws -> String)?
    var testSummaryPersistenceOperation: (([Summary], URL) throws -> Void)?

    init(
        initialSummariesDirectory: URL? = nil,
        apiKeyProvider: (() -> String)? = nil
    ) {
        let processInfo = ProcessInfo.processInfo
        let isRunningTests = processInfo.processName.contains("xctest")
            || processInfo.environment["XCTestConfigurationFilePath"] != nil
        if let initialSummariesDirectory {
            boundSummariesDirectory = initialSummariesDirectory
        } else if isRunningTests {
            boundSummariesDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("WhisperNote-SummaryManagerTests-\(UUID().uuidString)")
        } else {
            boundSummariesDirectory = DirectoryManager.shared.getSummariesDirectory()
        }
        allowsLegacyMigration = initialSummariesDirectory == nil && !isRunningTests
        self.apiKeyProvider = apiKeyProvider ?? {
            UserDefaults.standard.string(forKey: "openrouterApiKey") ?? ""
        }
        try? FileManager.default.createDirectory(
            at: boundSummariesDirectory,
            withIntermediateDirectories: true
        )
        loadSummaries()
        cleanupLegacySummaryFiles()
        saveSummaries()
    }

    func summary(id: UUID) -> Summary? {
        summaries.first(where: { $0.id == id })
    }

    func summarizeForWorkflow(
        _ transcript: Transcript,
        summaryID: UUID,
        prompt: String,
        model: String
    ) async throws -> Summary {
        try await summarizeForWorkflow(
            transcript,
            summaryID: summaryID,
            snapshot: SummaryGenerationSnapshot(prompt: prompt, model: model)
        )
    }

    func summarizeForWorkflow(
        _ transcript: Transcript,
        summaryID: UUID,
        snapshot: SummaryGenerationSnapshot
    ) async throws -> Summary {
        guard !isLibraryRebinding else { throw SummaryError.staleLibrary }
        let generation = libraryGeneration
        if let existing = summary(id: summaryID), existing.status == .completed {
            return existing
        }
        guard !apiKey.isEmpty else { throw SummaryError.missingApiKey }
        let frozen = snapshot

        var artifact = summary(id: summaryID) ?? Summary(
            id: summaryID,
            name: transcript.name,
            date: Date(),
            content: "",
            transcriptId: transcript.id,
            model: frozen.model,
            prompt: frozen.prompt,
            templateID: frozen.templateID,
            templateName: frozen.templateName,
            status: .pending
        )
        artifact.model = frozen.model
        artifact.prompt = frozen.prompt
        artifact.templateID = frozen.templateID
        artifact.templateName = frozen.templateName
        artifact.status = .inProgress
        try upsertAndPersist(artifact)

        let content: String
        do {
            content = try await callOpenRouterAPI(prompt: frozen.prompt, model: frozen.model, transcript: transcript)
        } catch {
            guard generation == libraryGeneration else { throw SummaryError.staleLibrary }
            artifact.status = .failed
            try upsertAndPersist(artifact)
            if let typed = error as? SummaryError { throw typed }
            throw SummaryError.unknown(error)
        }
        guard generation == libraryGeneration else { throw SummaryError.staleLibrary }
        artifact.content = content
        artifact.status = .completed
        try upsertAndPersist(artifact)
        return artifact
    }

    func generateSummary(for transcript: Transcript, with customPrompt: String? = nil, model: String? = nil) async throws -> Summary {
        let snapshot = SummaryGenerationSnapshot(
            prompt: customPrompt ?? getDefaultPrompt(),
            model: model ?? defaultModel
        )
        return try await generateSummary(for: transcript, snapshot: snapshot)
    }

    func generateSummary(
        for transcript: Transcript,
        snapshot: SummaryGenerationSnapshot
    ) async throws -> Summary {
        guard !isLibraryRebinding else { throw SummaryError.staleLibrary }
        let generation = libraryGeneration
        guard !apiKey.isEmpty else {
            throw SummaryError.missingApiKey
        }

        let frozen = snapshot

        // Create a pending summary
        let pendingSummary = Summary(
            name: transcript.name,
            date: Date(),
            content: "",
            transcriptId: transcript.id,
            model: frozen.model,
            prompt: frozen.prompt,
            templateID: frozen.templateID,
            templateName: frozen.templateName,
            status: .pending
        )

        // Every visible state is durably committed before it is published.
        try upsertAndPersist(pendingSummary)

        // Update status to in progress
        var inProgressSummary = pendingSummary
        inProgressSummary.status = .inProgress

        try upsertAndPersist(inProgressSummary)

        let summaryContent: String
        do {
            summaryContent = try await callOpenRouterAPI(
                prompt: frozen.prompt,
                model: frozen.model,
                transcript: transcript
            )
        } catch {
            guard generation == libraryGeneration else { throw SummaryError.staleLibrary }
            var failedSummary = inProgressSummary
            failedSummary.status = .failed

            try upsertAndPersist(failedSummary)

            if let summaryError = error as? SummaryError {
                throw summaryError
            } else {
                throw SummaryError.unknown(error)
            }
        }
        guard generation == libraryGeneration else { throw SummaryError.staleLibrary }

        var completedSummary = inProgressSummary
        completedSummary.content = summaryContent
        completedSummary.status = .completed
        try upsertAndPersist(completedSummary)
        return completedSummary
    }

    func retryGenerateSummary(id: UUID, transcript: Transcript) async throws -> Summary {
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw SummaryError.invalidResponse
        }
        return try await regenerateSummary(
            id: id,
            transcript: transcript,
            snapshot: SummaryGenerationSnapshot(
                templateID: summary.templateID,
                templateName: summary.templateName,
                prompt: summary.prompt,
                model: summary.model
            )
        )
    }

    /// Replaces an existing summary only after both generation and durable save
    /// succeed. A failed API call or write leaves the old content and metadata intact.
    func regenerateSummary(
        id: UUID,
        transcript: Transcript,
        snapshot: SummaryGenerationSnapshot
    ) async throws -> Summary {
        guard !isLibraryRebinding else { throw SummaryError.staleLibrary }
        let generation = libraryGeneration
        guard let original = summaries.first(where: { $0.id == id }) else {
            throw SummaryError.invalidResponse
        }
        guard !apiKey.isEmpty else { throw SummaryError.missingApiKey }
        let frozen = snapshot

        let content: String
        do {
            content = try await callOpenRouterAPI(
                prompt: frozen.prompt,
                model: frozen.model,
                transcript: transcript
            )
        } catch {
            guard generation == libraryGeneration else { throw SummaryError.staleLibrary }
            if let e = error as? SummaryError { throw e }
            throw SummaryError.unknown(error)
        }
        guard generation == libraryGeneration else { throw SummaryError.staleLibrary }

        var replacement = original
        replacement.content = content
        replacement.model = frozen.model
        replacement.prompt = frozen.prompt
        replacement.templateID = frozen.templateID
        replacement.templateName = frozen.templateName
        replacement.status = .completed
        try upsertAndPersist(replacement)
        return replacement
    }

    func enhancePrompt(_ prompt: String, model: String? = nil) async throws -> String {
        guard !isLibraryRebinding else { throw SummaryError.staleLibrary }
        guard !apiKey.isEmpty else {
            throw SummaryError.missingApiKey
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw SummaryError.emptyPrompt
        }

        let modelToUse = model ?? defaultModel
        let enhancerInstructions = """
        You are improving a prompt that will be used to generate an output from a transcript.

        Rewrite the user's prompt so it is clearer, more specific, and more actionable. Preserve the user's intent, requested output type, target audience, formatting requirements, language requirements, and constraints.

        Do not assume the transcript is a meeting. It may be a meeting, workshop, lecture, interview, training session, podcast, call, presentation, or another spoken recording.

        Do not summarize any transcript. Do not invent details. Do not add domain-specific assumptions that are not present in the original prompt.

        Make the improved prompt suitable for producing a high-quality, well-structured output from the transcript.

        Return only the improved prompt text.
        """

        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("WhisperNote/1.0.0", forHTTPHeaderField: "HTTP-Referer")

        let requestBody: [String: Any] = [
            "model": modelToUse,
            "messages": [
                ["role": "system", "content": enhancerInstructions],
                ["role": "user", "content": trimmedPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        debugLogger.log("OpenRouter prompt enhancement started. model=\(modelToUse) promptChars=\(trimmedPrompt.count)", area: .summaries)

        let startedAt = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let httpResponse = response as? HTTPURLResponse else {
            debugLogger.log("OpenRouter prompt enhancement response invalid. elapsed=\(String(format: "%.2f", elapsed))s", area: .summaries)
            throw SummaryError.invalidResponse
        }
        debugLogger.log("OpenRouter prompt enhancement response received. status=\(httpResponse.statusCode) elapsed=\(String(format: "%.2f", elapsed))s responseBytes=\(responseData.count)", area: .summaries)
        guard httpResponse.statusCode == 200 else {
            debugLogger.log("OpenRouter prompt enhancement API error. status=\(httpResponse.statusCode) responseBytes=\(responseData.count)", area: .summaries)
            throw SummaryError.apiError(statusCode: httpResponse.statusCode)
        }
        let summaryResponse = try JSONDecoder().decode(OpenRouterResponse.self, from: responseData)
        guard let content = summaryResponse.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            debugLogger.log("OpenRouter prompt enhancement response contained no choices.", area: .summaries)
            throw SummaryError.emptyResponse
        }
        debugLogger.log("OpenRouter prompt enhancement completed. outputChars=\(content.count)", area: .summaries)
        return content
    }

    private func callOpenRouterAPI(prompt: String, model: String, transcript: Transcript) async throws -> String {
        if let testSummaryOperation {
            return try await testSummaryOperation(prompt, model, transcript)
        }
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("WhisperNote/1.0.0", forHTTPHeaderField: "HTTP-Referer")

        let fullPrompt = "\(prompt)\n\nTRANSCRIPT=\n\(transcript.content)"
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": fullPrompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        debugLogger.log("OpenRouter request started. model=\(model) transcript=\(transcript.name) promptChars=\(prompt.count) transcriptChars=\(transcript.content.count)", area: .summaries)

        let startedAt = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let httpResponse = response as? HTTPURLResponse else {
            debugLogger.log("OpenRouter response invalid. elapsed=\(String(format: "%.2f", elapsed))s", area: .summaries)
            throw SummaryError.invalidResponse
        }
        debugLogger.log("OpenRouter response received. status=\(httpResponse.statusCode) elapsed=\(String(format: "%.2f", elapsed))s responseBytes=\(responseData.count)", area: .summaries)
        guard httpResponse.statusCode == 200 else {
            debugLogger.log("OpenRouter API error. status=\(httpResponse.statusCode) responseBytes=\(responseData.count)", area: .summaries)
            throw SummaryError.apiError(statusCode: httpResponse.statusCode)
        }
        let summaryResponse = try JSONDecoder().decode(OpenRouterResponse.self, from: responseData)
        guard let content = summaryResponse.choices.first?.message.content else {
            debugLogger.log("OpenRouter response contained no choices.", area: .summaries)
            throw SummaryError.emptyResponse
        }
        debugLogger.log("OpenRouter summary completed. outputChars=\(content.count)", area: .summaries)
        return content
    }

    func getDefaultPrompt(meetingType: String = "meeting", audience: String = "all participants") -> String {
        // Parameters are kept for backward compatibility but no longer used in the prompt
        return """
        Identify key points, action items, decisions made, and any important discussions from TRANSCRIPT.
        Organize the information in a clear and concise manner, ensure accuracy, and capture the essence of the meeting.
        Include relevant details such as attendee names, time stamps, and any follow-up actions required.
        The meeting minutes should serve as a comprehensive record of the meeting for future reference and accountability.

        Format the summary using Markdown syntax with:
        - # for main headings
        - ## for subheadings
        - **bold** for important points
        - - or * for bullet points
        - 1. 2. 3. for numbered lists
        - [text](link) for any links

        Make sure to use proper Markdown formatting to create a well-structured, readable summary.
        The summary should be in the same language as the TRANSCRIPT.
        """
    }

    // MARK: - Persistence

    private func saveSummaries() {
        do {
            let data = try JSONEncoder().encode(summaries)
            let directory = boundSummariesDirectory
            let url = directory.appendingPathComponent("summaries.json")
            try data.write(to: url)
        } catch {
            print("Failed to save summaries: \(error)")
        }
    }

    private func upsertAndPersist(_ summary: Summary) throws {
        do {
            try ArtifactUpsertTransaction.commit(
                current: summaries,
                artifact: summary,
                persist: { candidate in
                    let url = self.boundSummariesDirectory.appendingPathComponent("summaries.json")
                    if let testSummaryPersistenceOperation = self.testSummaryPersistenceOperation {
                        try testSummaryPersistenceOperation(candidate, url)
                    } else {
                        let data = try JSONEncoder().encode(candidate)
                        try data.write(to: url, options: .atomic)
                    }
                },
                publish: { self.summaries = $0 }
            )
        } catch {
            throw ArtifactPersistenceError.summary(error)
        }
    }

    // Delete a summary by ID
    func deleteSummary(id: UUID) {
        guard !isLibraryRebinding else { return }
        if let index = summaries.firstIndex(where: { $0.id == id }) {
            summaries.remove(at: index)
            saveSummaries()
        }
    }

    // Update summary content
    func updateSummaryContent(id: UUID, newContent: String) {
        guard !isLibraryRebinding else { return }
        if let index = summaries.firstIndex(where: { $0.id == id }) {
            summaries[index].content = newContent
            saveSummaries()
        }
    }

    // Public method to reload summaries from disk
    func reloadSummaries() {
        loadSummaries()
    }

    func reloadSummariesForCurrentLibrary() throws {
        let url = boundSummariesDirectory.appendingPathComponent("summaries.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            summaries = []
            return
        }
        summaries = try JSONDecoder().decode([Summary].self, from: Data(contentsOf: url))
    }

    func clearSummariesForLibraryRebindFailure() { summaries = [] }

    func acceptLibrary(summaries: [Summary], summariesDirectory: URL) {
        libraryGeneration += 1
        boundSummariesDirectory = summariesDirectory
        self.summaries = summaries
    }

    func beginLibraryRebind() -> Bool {
        guard !isLibraryRebinding else { return false }
        isLibraryRebinding = true
        libraryGeneration += 1
        return true
    }

    func finishLibraryRebind() {
        isLibraryRebinding = false
    }

    private func loadSummaries() {
        // Try to load from the new directory structure
        let summariesDirectory = boundSummariesDirectory
        let summariesUrl = summariesDirectory.appendingPathComponent("summaries.json")

        if FileManager.default.fileExists(atPath: summariesUrl.path) {
            do {
                let data = try Data(contentsOf: summariesUrl)
                summaries = try JSONDecoder().decode([Summary].self, from: data)
                return
            } catch {
                print("Failed to load summaries from summaries directory: \(error)")
            }
        }

        // Fall back to old directory if needed (for backward compatibility)
        guard allowsLegacyMigration else { return }
        let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultUrl = defaultDirectory.appendingPathComponent("summaries.json")
        if FileManager.default.fileExists(atPath: defaultUrl.path) {
            do {
                let data = try Data(contentsOf: defaultUrl)
                summaries = try JSONDecoder().decode([Summary].self, from: data)

                // Save to the new location for future use
                saveSummaries()

                // Optionally, remove the old file
                try? FileManager.default.removeItem(at: defaultUrl)
            } catch {
                print("Failed to load summaries from old directory: \(error)")
            }
        }
    }

    private func cleanupLegacySummaryFiles() {
        let summariesDirectory = boundSummariesDirectory
        let summariesURL = summariesDirectory.appendingPathComponent("summaries.json")
        var urlsToRemove = Set<URL>()

        if let data = try? Data(contentsOf: summariesURL),
           let rawSummaries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for rawSummary in rawSummaries {
                if let path = rawSummary["filePath"] as? String {
                    urlsToRemove.insert(URL(fileURLWithPath: path))
                }
            }
        }

        if let generatedFiles = try? FileManager.default.contentsOfDirectory(at: summariesDirectory, includingPropertiesForKeys: nil) {
            for fileURL in generatedFiles where isGeneratedSummaryFile(fileURL) {
                urlsToRemove.insert(fileURL)
            }
        }

        for fileURL in urlsToRemove {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func isGeneratedSummaryFile(_ url: URL) -> Bool {
        let filename = url.lastPathComponent
        let pattern = #"_summary_[0-9]{8}_[0-9]{6}_[A-Fa-f0-9]{8}\.(txt|md)$"#
        return filename.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - OpenRouter API Response

struct OpenRouterResponse: Codable {
    let id: String
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
        let index: Int
    }

    struct Message: Codable {
        let role: String
        let content: String
    }
}

// MARK: - Errors

enum SummaryError: Error, LocalizedError {
    case missingApiKey
    case emptyPrompt
    case invalidResponse
    case apiError(statusCode: Int)
    case emptyResponse
    case staleLibrary
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "OpenRouter API key is missing. Please add it in Settings."
        case .emptyPrompt:
            return "Prompt is empty. Please preview or enter a prompt first."
        case .invalidResponse:
            return "Received invalid response from OpenRouter API."
        case .apiError(let statusCode):
            return "OpenRouter API error (Status \(statusCode)). Please check your API key and try again."
        case .emptyResponse:
            return "Received empty response from the language model."
        case .staleLibrary:
            return "Summary generation was cancelled because the active library changed."
        case .unknown(let error):
            return "Summary generation failed: \(error.localizedDescription)"
        }
    }
}
