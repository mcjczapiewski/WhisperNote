import Foundation
import SwiftUI

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var transcripts: [Transcript] = []
    @AppStorage("elevenlabsApiKey") private var apiKey = ""

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        loadTranscripts()
    }

    func transcribeRecording(_ recording: Recording) async throws -> Transcript {
        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingApiKey
        }

        // Create a pending transcript
        let pendingTranscript = Transcript(
            name: recording.name,
            date: Date(),
            content: "",
            recordingId: recording.id,
            status: .pending
        )

        // Add to transcripts and save
        DispatchQueue.main.async {
            self.transcripts.append(pendingTranscript)
            self.saveTranscripts()
        }

        // Update status to in progress
        var inProgressTranscript = pendingTranscript
        inProgressTranscript.status = .inProgress

        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.id == pendingTranscript.id }) {
                self.transcripts[index] = inProgressTranscript
                self.saveTranscripts()
            }
        }

        // Prepare the request
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text/convert")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // Create form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()

        // Add audio file to form data
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(recording.filePath.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)

        do {
            let audioData = try Data(contentsOf: recording.filePath)
            data.append(audioData)
            data.append("\r\n".data(using: .utf8)!)
        } catch {
            throw TranscriptionError.fileReadError
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw TranscriptionError.apiError(statusCode: httpResponse.statusCode)
            }

            // Parse the response
            let decoder = JSONDecoder()
            let transcriptionResponse = try decoder.decode(ElevenLabsTranscriptionResponse.self, from: responseData)

            // Create completed transcript
            var completedTranscript = inProgressTranscript
            completedTranscript.content = transcriptionResponse.text
            completedTranscript.status = .completed

            DispatchQueue.main.async {
                if let index = self.transcripts.firstIndex(where: { $0.id == inProgressTranscript.id }) {
                    self.transcripts[index] = completedTranscript
                    self.saveTranscripts()
                }
            }

            return completedTranscript
        } catch {
            // Update transcript status to failed
            var failedTranscript = inProgressTranscript
            failedTranscript.status = .failed

            DispatchQueue.main.async {
                if let index = self.transcripts.firstIndex(where: { $0.id == inProgressTranscript.id }) {
                    self.transcripts[index] = failedTranscript
                    self.saveTranscripts()
                }
            }

            if let transcriptionError = error as? TranscriptionError {
                throw transcriptionError
            } else {
                throw TranscriptionError.unknown(error)
            }
        }
    }

    // MARK: - Persistence

    private func saveTranscripts() {
        do {
            let data = try JSONEncoder().encode(transcripts)
            let url = documentsDirectory.appendingPathComponent("transcripts.json")
            try data.write(to: url)
        } catch {
            print("Failed to save transcripts: \(error)")
        }
    }

    private func loadTranscripts() {
        let url = documentsDirectory.appendingPathComponent("transcripts.json")

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)
            } catch {
                print("Failed to load transcripts: \(error)")
            }
        }
    }
}

// MARK: - ElevenLabs API Response

struct ElevenLabsTranscriptionResponse: Codable {
    let text: String
    let language: String?
    let confidence: Double?
    let words: [ElevenLabsWord]?

    struct ElevenLabsWord: Codable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Double
    }
}

// MARK: - Errors

enum TranscriptionError: Error, LocalizedError {
    case missingApiKey
    case fileReadError
    case invalidResponse
    case apiError(statusCode: Int)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "ElevenLabs API key is missing. Please add it in Settings."
        case .fileReadError:
            return "Failed to read audio file."
        case .invalidResponse:
            return "Received invalid response from ElevenLabs API."
        case .apiError(let statusCode):
            return "ElevenLabs API error (Status \(statusCode)). Please check your API key and try again."
        case .unknown(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}
