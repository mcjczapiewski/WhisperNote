import Foundation
import SwiftUI

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var transcripts: [Transcript] = []
    @AppStorage("elevenlabsApiKey") private var apiKey = ""

    private let directoryManager = DirectoryManager.shared

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
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // Print the API key for debugging (remove in production)
        print("Using API key: \(apiKey)")

        // Create form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()

        // Add audio file to form data
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(recording.filePath.lastPathComponent)\"\r\n".data(using: .utf8)!)

        // Set the correct content type based on the file extension
        let fileExtension = recording.filePath.pathExtension.lowercased()
        let contentType: String
        if fileExtension == "wav" {
            contentType = "audio/wav"
        } else if fileExtension == "mp3" {
            contentType = "audio/mpeg"
        } else if fileExtension == "m4a" {
            contentType = "audio/m4a"
        } else {
            contentType = "application/octet-stream"
        }

        data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)

        do {
            let audioData = try Data(contentsOf: recording.filePath)
            data.append(audioData)
            data.append("\r\n".data(using: .utf8)!)
        } catch {
            throw TranscriptionError.fileReadError
        }

        // Add model parameter (optional)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        data.append("whisper-1\r\n".data(using: .utf8)!)

        // Add language parameter (optional)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"language_code\"\r\n\r\n".data(using: .utf8)!)
        data.append("en\r\n".data(using: .utf8)!)

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                // Print response body for debugging
                let responseString = String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
                print("API Error Response: \(responseString)")
                throw TranscriptionError.apiError(statusCode: httpResponse.statusCode)
            }

            // Print the response for debugging
            let responseString = String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
            print("API Success Response: \(responseString)")

            // Parse the response
            let decoder = JSONDecoder()

            // Try to decode with our expected format
            let transcriptionResponse: ElevenLabsTranscriptionResponse
            do {
                transcriptionResponse = try decoder.decode(ElevenLabsTranscriptionResponse.self, from: responseData)
            } catch {
                print("Error decoding response: \(error)")

                // Try alternative format (simple string)
                if let simpleResponse = try? decoder.decode([String: String].self, from: responseData),
                   let text = simpleResponse["text"] {
                    transcriptionResponse = ElevenLabsTranscriptionResponse(
                        text: text,
                        language: nil,
                        confidence: nil,
                        words: nil
                    )
                } else {
                    throw error
                }
            }

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
            let directory = directoryManager.getRecordingsDirectory()
            let url = directory.appendingPathComponent("transcripts.json")
            try data.write(to: url)
        } catch {
            print("Failed to save transcripts: \(error)")
        }
    }

    private func loadTranscripts() {
        // Try to load from custom directory first
        let customDirectory = directoryManager.getRecordingsDirectory()
        let customUrl = customDirectory.appendingPathComponent("transcripts.json")

        if FileManager.default.fileExists(atPath: customUrl.path) {
            do {
                let data = try Data(contentsOf: customUrl)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)
                return
            } catch {
                print("Failed to load transcripts from custom directory: \(error)")
            }
        }

        // Fall back to default directory if needed
        let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultUrl = defaultDirectory.appendingPathComponent("transcripts.json")
        if FileManager.default.fileExists(atPath: defaultUrl.path) {
            do {
                let data = try Data(contentsOf: defaultUrl)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)
            } catch {
                print("Failed to load transcripts from default directory: \(error)")
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
