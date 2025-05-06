import Foundation
import SwiftUI

@MainActor
class SummaryManager: ObservableObject {
    @Published var summaries: [Summary] = []
    @AppStorage("openrouterApiKey") private var apiKey = ""
    @AppStorage("defaultLLMModel") private var defaultModel = "gpt-4"

    private let directoryManager = DirectoryManager.shared

    init() {
        loadSummaries()
    }

    func generateSummary(for transcript: Transcript, with customPrompt: String? = nil) async throws -> Summary {
        guard !apiKey.isEmpty else {
            throw SummaryError.missingApiKey
        }

        let prompt = customPrompt ?? getDefaultPrompt()

        // Create a pending summary
        let pendingSummary = Summary(
            name: transcript.name,
            date: Date(),
            content: "",
            transcriptId: transcript.id,
            model: defaultModel,
            prompt: prompt,
            status: .pending
        )

        // Add to summaries and save
        DispatchQueue.main.async {
            self.summaries.append(pendingSummary)
            self.saveSummaries()
        }

        // Update status to in progress
        var inProgressSummary = pendingSummary
        inProgressSummary.status = .inProgress

        DispatchQueue.main.async {
            if let index = self.summaries.firstIndex(where: { $0.id == pendingSummary.id }) {
                self.summaries[index] = inProgressSummary
                self.saveSummaries()
            }
        }

        // Prepare the request
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("WhisperNote/1.0.0", forHTTPHeaderField: "HTTP-Referer")

        // Create the request body
        let fullPrompt = "\(prompt)\n\nTranscript:\n\(transcript.content)"

        let requestBody: [String: Any] = [
            "model": defaultModel,
            "messages": [
                ["role": "user", "content": fullPrompt]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = jsonData

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummaryError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw SummaryError.apiError(statusCode: httpResponse.statusCode)
            }

            // Parse the response
            let decoder = JSONDecoder()
            let summaryResponse = try decoder.decode(OpenRouterResponse.self, from: responseData)

            guard let summaryContent = summaryResponse.choices.first?.message.content else {
                throw SummaryError.emptyResponse
            }

            // Create completed summary
            var completedSummary = inProgressSummary
            completedSummary.content = summaryContent
            completedSummary.status = .completed

            DispatchQueue.main.async {
                if let index = self.summaries.firstIndex(where: { $0.id == inProgressSummary.id }) {
                    self.summaries[index] = completedSummary
                    self.saveSummaries()
                }
            }

            return completedSummary
        } catch {
            // Update summary status to failed
            var failedSummary = inProgressSummary
            failedSummary.status = .failed

            DispatchQueue.main.async {
                if let index = self.summaries.firstIndex(where: { $0.id == inProgressSummary.id }) {
                    self.summaries[index] = failedSummary
                    self.saveSummaries()
                }
            }

            if let summaryError = error as? SummaryError {
                throw summaryError
            } else {
                throw SummaryError.unknown(error)
            }
        }
    }

    func getDefaultPrompt() -> String {
        return """
        Please provide a comprehensive summary of the following meeting transcript. Include:

        1. Key discussion points
        2. Decisions made
        3. Action items with assigned owners (if mentioned)
        4. Follow-up tasks and deadlines

        Format the summary in a clear, organized manner with appropriate headings.
        """
    }

    // MARK: - Persistence

    private func saveSummaries() {
        do {
            let data = try JSONEncoder().encode(summaries)
            let directory = directoryManager.getSummariesDirectory()
            let url = directory.appendingPathComponent("summaries.json")
            try data.write(to: url)
        } catch {
            print("Failed to save summaries: \(error)")
        }
    }

    // Delete a summary by ID
    func deleteSummary(id: UUID) {
        if let index = summaries.firstIndex(where: { $0.id == id }) {
            summaries.remove(at: index)
            saveSummaries()
        }
    }

    private func loadSummaries() {
        // Try to load from the new directory structure
        let summariesDirectory = directoryManager.getSummariesDirectory()
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
    case invalidResponse
    case apiError(statusCode: Int)
    case emptyResponse
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "OpenRouter API key is missing. Please add it in Settings."
        case .invalidResponse:
            return "Received invalid response from OpenRouter API."
        case .apiError(let statusCode):
            return "OpenRouter API error (Status \(statusCode)). Please check your API key and try again."
        case .emptyResponse:
            return "Received empty response from the language model."
        case .unknown(let error):
            return "Summary generation failed: \(error.localizedDescription)"
        }
    }
}
