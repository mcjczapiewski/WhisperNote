import Foundation
import SwiftUI

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var transcripts: [Transcript] = []

    private let directoryManager = DirectoryManager.shared
    private var boundTranscriptsDirectory = DirectoryManager.shared.getTranscriptsDirectory()
    private var libraryGeneration = 0
    private(set) var isLibraryRebinding = false
    private let debugLogger = DebugLogger.shared
    private var apiKey: String { UserDefaults.standard.string(forKey: "elevenlabsApiKey") ?? "" }
    var testTranscriptionOperation: ((Recording, String) async throws -> (content: String, formatted: String, jsonPath: URL?))?

    init() {
        loadTranscripts()
        migrateLegacyJSONArchives()
    }

    func transcript(id: UUID) -> Transcript? {
        transcripts.first(where: { $0.id == id })
    }

    /// Workflow-specific stable-ID upsert. Persisting each artifact transition is
    /// part of the operation: a disk failure is surfaced to the coordinator rather
    /// than allowing its job to advance past an artifact that only exists in memory.
    func transcribeForWorkflow(
        _ recording: Recording,
        transcriptID: UUID,
        language: String
    ) async throws -> Transcript {
        guard !isLibraryRebinding else { throw TranscriptionError.staleLibrary }
        let generation = libraryGeneration
        if let existing = transcript(id: transcriptID), existing.status == .completed {
            return existing
        }
        guard !apiKey.isEmpty else { throw TranscriptionError.missingApiKey }
        guard FileManager.default.fileExists(atPath: recording.filePath.path) else {
            throw TranscriptionError.fileReadError
        }

        var artifact = transcript(id: transcriptID) ?? Transcript(
            id: transcriptID,
            name: recording.name,
            date: Date(),
            content: "",
            recordingId: recording.id,
            status: .pending
        )
        artifact.status = .inProgress
        try upsertAndPersist(artifact)

        let result: (content: String, formatted: String, jsonPath: URL?)
        do {
            result = try await performTranscription(
                recording,
                language: language,
                expectedGeneration: generation,
                transcriptsDirectory: boundTranscriptsDirectory
            )
        } catch {
            guard generation == libraryGeneration else { throw TranscriptionError.staleLibrary }
            artifact.status = .failed
            try upsertAndPersist(artifact)
            if let typed = error as? TranscriptionError { throw typed }
            throw TranscriptionError.unknown(error)
        }
        guard generation == libraryGeneration else {
            if let jsonPath = result.jsonPath { try? FileManager.default.removeItem(at: jsonPath) }
            throw TranscriptionError.staleLibrary
        }
        artifact.content = result.content
        artifact.formattedContent = result.formatted
        artifact.jsonFilePath = result.jsonPath
        artifact.status = .completed
        try upsertAndPersist(artifact)
        return artifact
    }

    func transcribeRecording(_ recording: Recording, language: String = "eng") async throws -> Transcript {
        guard !isLibraryRebinding else { throw TranscriptionError.staleLibrary }
        let generation = libraryGeneration
        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingApiKey
        }

        // Verify the file exists before proceeding
        guard FileManager.default.fileExists(atPath: recording.filePath.path) else {
            print("Audio file not found at path: \(recording.filePath.path)")
            throw TranscriptionError.fileReadError
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
        transcripts.append(pendingTranscript)
        saveTranscripts()

        // Update status to in progress
        var inProgressTranscript = pendingTranscript
        inProgressTranscript.status = .inProgress

        if let index = transcripts.firstIndex(where: { $0.id == pendingTranscript.id }) {
            transcripts[index] = inProgressTranscript
            saveTranscripts()
        }

        do {
            let result = try await performTranscription(
                recording,
                language: language,
                expectedGeneration: generation,
                transcriptsDirectory: boundTranscriptsDirectory
            )
            guard generation == libraryGeneration else {
                if let jsonPath = result.jsonPath { try? FileManager.default.removeItem(at: jsonPath) }
                throw TranscriptionError.staleLibrary
            }

            var completedTranscript = inProgressTranscript
            completedTranscript.content = result.content
            completedTranscript.formattedContent = result.formatted
            completedTranscript.jsonFilePath = result.jsonPath
            completedTranscript.status = .completed

            if let index = transcripts.firstIndex(where: { $0.id == inProgressTranscript.id }) {
                transcripts[index] = completedTranscript
                saveTranscripts()
            }
            return completedTranscript
        } catch {
            guard generation == libraryGeneration else { throw TranscriptionError.staleLibrary }
            var failedTranscript = inProgressTranscript
            failedTranscript.status = .failed

            if let index = transcripts.firstIndex(where: { $0.id == inProgressTranscript.id }) {
                transcripts[index] = failedTranscript
                saveTranscripts()
            }

            if let transcriptionError = error as? TranscriptionError {
                throw transcriptionError
            } else {
                throw TranscriptionError.unknown(error)
            }
        }
    }

    /// Transcribe a batch of recordings into a SINGLE combined transcript.
    /// Each file is sent to ElevenLabs individually; results are joined once all return.
    /// The combined transcript uses `groupId` as its `recordingId`.
    func transcribeGroup(_ recordings: [Recording], groupId: UUID, groupName: String, language: String = "eng") async throws -> Transcript {
        guard !isLibraryRebinding else { throw TranscriptionError.staleLibrary }
        let generation = libraryGeneration
        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingApiKey
        }

        var groupTranscript = Transcript(
            name: groupName,
            date: Date(),
            content: "",
            recordingId: groupId,
            status: .inProgress
        )

        transcripts.append(groupTranscript)
        saveTranscripts()

        do {
            // ponytail: sequential to respect ElevenLabs rate limits; switch to a TaskGroup if batch latency matters
            var plainSections: [String] = []
            var formattedSections: [String] = []
            for recording in recordings {
                let result = try await performTranscription(
                    recording,
                    language: language,
                    expectedGeneration: generation,
                    transcriptsDirectory: boundTranscriptsDirectory
                )
                guard generation == libraryGeneration else {
                    if let jsonPath = result.jsonPath { try? FileManager.default.removeItem(at: jsonPath) }
                    throw TranscriptionError.staleLibrary
                }
                plainSections.append("─── \(recording.name) ───\n\(result.content)")
                formattedSections.append("─── \(recording.name) ───\n\(result.formatted)")
            }

            let names = recordings.map { $0.name }.joined(separator: ", ")
            let header = "Combined transcript from \(recordings.count) audio files: \(names)"
            let combinedContent = header + "\n\n" + plainSections.joined(separator: "\n\n")
            let combinedFormatted = header + "\n\n" + formattedSections.joined(separator: "\n\n")

            groupTranscript.content = combinedContent
            groupTranscript.formattedContent = combinedFormatted
            groupTranscript.status = .completed

            let finished = groupTranscript
            if let index = transcripts.firstIndex(where: { $0.id == finished.id }) {
                transcripts[index] = finished
                saveTranscripts()
            }
            return finished
        } catch {
            guard generation == libraryGeneration else { throw TranscriptionError.staleLibrary }
            groupTranscript.status = .failed
            let failed = groupTranscript
            if let index = transcripts.firstIndex(where: { $0.id == failed.id }) {
                transcripts[index] = failed
                saveTranscripts()
            }
            if let transcriptionError = error as? TranscriptionError {
                throw transcriptionError
            } else {
                throw TranscriptionError.unknown(error)
            }
        }
    }

    /// Pure "audio in, text out": uploads a single recording to ElevenLabs and returns
    /// the parsed result. Does NOT touch the `transcripts` array.
    private func performTranscription(
        _ recording: Recording,
        language: String,
        expectedGeneration: Int,
        transcriptsDirectory: URL
    ) async throws -> (content: String, formatted: String, jsonPath: URL?) {
        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingApiKey
        }
        guard FileManager.default.fileExists(atPath: recording.filePath.path) else {
            print("Audio file not found at path: \(recording.filePath.path)")
            throw TranscriptionError.fileReadError
        }
        if let testTranscriptionOperation {
            let result = try await testTranscriptionOperation(recording, language)
            guard expectedGeneration == libraryGeneration,
                  transcriptsDirectory == boundTranscriptsDirectory else {
                if let jsonPath = result.jsonPath { try? FileManager.default.removeItem(at: jsonPath) }
                throw TranscriptionError.staleLibrary
            }
            return result
        }

        print("Transcribing with language: \(language)")
        debugLogger.log("Transcription started. recording=\(recording.name) language=\(language)", area: .transcripts, contextURL: recording.filePath)

        // Prepare the request
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // Create URLSession with a longer timeout. Large files can spend a long
        // time uploading before ElevenLabs starts processing the transcription.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: config)

        // Create multipart form data
        let boundary = "---011000010111000001101001" // Use a fixed boundary as in the example
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

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

        let audioFileSize = (try? FileManager.default.attributesOfItem(atPath: recording.filePath.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("Audio file size: \(ByteCountFormatter.string(fromByteCount: audioFileSize, countStyle: .file))")

        let uploadFileURL: URL
        do {
            uploadFileURL = try await Task.detached(priority: .userInitiated) {
                try Self.createMultipartUploadFile(recording: recording, language: language, boundary: boundary, contentType: contentType)
            }.value
        } catch {
            print("Error preparing upload body: \(error.localizedDescription)")
            debugLogger.log("Transcription upload body preparation failed. error=\(error.localizedDescription)", area: .transcripts, contextURL: recording.filePath)
            throw TranscriptionError.fileReadError
        }
        defer { try? FileManager.default.removeItem(at: uploadFileURL) }

        let uploadFileSize = (try? FileManager.default.attributesOfItem(atPath: uploadFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        request.setValue("\(uploadFileSize)", forHTTPHeaderField: "Content-Length")
        debugLogger.log("ElevenLabs request prepared. audioBytes=\(audioFileSize) uploadBytes=\(uploadFileSize) contentType=\(contentType) timeoutRequest=\(config.timeoutIntervalForRequest) timeoutResource=\(config.timeoutIntervalForResource)", area: .transcripts, contextURL: recording.filePath)

        do {
            let startedAt = Date()
            let (responseData, response) = try await session.upload(for: request, fromFile: uploadFileURL)
            let elapsed = Date().timeIntervalSince(startedAt)

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLogger.log("ElevenLabs response invalid. elapsed=\(elapsed)", area: .transcripts, contextURL: recording.filePath)
                throw TranscriptionError.invalidResponse
            }

            debugLogger.log("ElevenLabs response received. status=\(httpResponse.statusCode) elapsed=\(String(format: "%.2f", elapsed))s responseBytes=\(responseData.count)", area: .transcripts, contextURL: recording.filePath)

            guard httpResponse.statusCode == 200 else {
                debugLogger.log("ElevenLabs API error. status=\(httpResponse.statusCode) responseBytes=\(responseData.count)", area: .transcripts, contextURL: recording.filePath)

                // Try to extract error message from the response
                let errorMessage = Self.extractAPIErrorMessage(from: responseData)

                throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }

            // Parse the response
            let decoder = JSONDecoder()

            // Try to decode with our expected format
            let transcriptionResponse: ElevenLabsTranscriptionResponse
            do {
                transcriptionResponse = try decoder.decode(ElevenLabsTranscriptionResponse.self, from: responseData)
            } catch {
                print("Error decoding response: \(error)")
                debugLogger.log("ElevenLabs response decode failed. error=\(error.localizedDescription) responseBytes=\(responseData.count)", area: .transcripts, contextURL: recording.filePath)

                // Try alternative format (simple string)
                if let simpleResponse = try? decoder.decode([String: String].self, from: responseData),
                   let text = simpleResponse["text"] {
                    transcriptionResponse = ElevenLabsTranscriptionResponse(
                        text: text,
                        language_code: nil,
                        language_probability: nil,
                        words: nil,
                        transcription_id: nil,
                        audio_duration_secs: nil
                    )
                } else {
                    throw error
                }
            }

            let speakerSegments = compactSpeakerSegments(from: transcriptionResponse)
            guard expectedGeneration == libraryGeneration,
                  transcriptsDirectory == boundTranscriptsDirectory else {
                throw TranscriptionError.staleLibrary
            }

            // Save a compact archive instead of the full per-word response.
            let jsonFilePath = try self.saveCompactJSONResponse(
                transcriptionResponse,
                speakerSegments: speakerSegments,
                rawResponseByteCount: responseData.count,
                recording: recording,
                transcriptsDirectory: transcriptsDirectory
            )
            debugLogger.log("Transcription completed. textChars=\(transcriptionResponse.text.count) speakerSegments=\(speakerSegments.count)", area: .transcripts, contextURL: recording.filePath)

            let formattedContent = formatTranscriptContent(response: transcriptionResponse, speakerSegments: speakerSegments)

            return (content: transcriptionResponse.text, formatted: formattedContent, jsonPath: jsonFilePath)
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                debugLogger.log("Transcription failed. error=\(transcriptionError.localizedDescription)", area: .transcripts, contextURL: recording.filePath)
                throw transcriptionError
            } else {
                let nsError = error as NSError
                debugLogger.log("Transcription failed. domain=\(nsError.domain) code=\(nsError.code) error=\(nsError.localizedDescription)", area: .transcripts, contextURL: recording.filePath)
                throw TranscriptionError.unknown(error)
            }
        }
    }

    nonisolated private static func createMultipartUploadFile(recording: Recording, language: String, boundary: String, contentType: String) throws -> URL {
        let uploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("elevenlabs_\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: uploadURL.path, contents: nil)

        let uploadHandle = try FileHandle(forWritingTo: uploadURL)
        defer { try? uploadHandle.close() }

        func write(_ string: String) throws {
            if let data = string.data(using: .utf8) {
                try uploadHandle.write(contentsOf: data)
            }
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        try write("scribe_v2\r\n")

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(recording.filePath.lastPathComponent)\"\r\n")
        try write("Content-Type: \(contentType)\r\n\r\n")

        let audioHandle = try FileHandle(forReadingFrom: recording.filePath)
        defer { try? audioHandle.close() }
        while let chunk = try audioHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try uploadHandle.write(contentsOf: chunk)
        }

        try write("\r\n")
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"language_code\"\r\n\r\n")
        try write("\(language)\r\n")

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"timestamps_granularity\"\r\n\r\n")
        try write("word\r\n")

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"tag_audio_events\"\r\n\r\n")
        try write("false\r\n")

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n")
        try write("true\r\n")

        try write("--\(boundary)--\r\n")
        return uploadURL
    }

    nonisolated private static func extractAPIErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let detail = json["detail"] as? [String: Any] {
            return detail["message"] as? String
        }

        if let detail = json["detail"] as? String {
            return detail
        }

        if let message = json["message"] as? String {
            return message
        }

        return nil
    }

    nonisolated private static func truncateForLog(_ value: String, limit: Int = 4_000) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "... [truncated]"
    }

    // MARK: - Persistence

    private func saveTranscripts() {
        do {
            let data = try JSONEncoder().encode(transcripts)
            let directory = boundTranscriptsDirectory
            let url = directory.appendingPathComponent("transcripts.json")
            try data.write(to: url)
        } catch {
            print("Failed to save transcripts: \(error)")
        }
    }

    private func upsertAndPersist(_ transcript: Transcript) throws {
        do {
            try ArtifactUpsertTransaction.commit(
                current: transcripts,
                artifact: transcript,
                persist: { candidate in
                    let data = try JSONEncoder().encode(candidate)
                    let url = self.boundTranscriptsDirectory.appendingPathComponent("transcripts.json")
                    try data.write(to: url, options: .atomic)
                },
                publish: { self.transcripts = $0 }
            )
        } catch {
            throw ArtifactPersistenceError.transcript(error)
        }
    }

    // Delete a transcript by ID
    func deleteTranscript(id: UUID) {
        guard !isLibraryRebinding else { return }
        if let index = transcripts.firstIndex(where: { $0.id == id }) {
            transcripts.remove(at: index)
            saveTranscripts()
        }
    }

    // Update transcript content
    func updateTranscriptContent(id: UUID, newContent: String) {
        guard !isLibraryRebinding else { return }
        if let index = transcripts.firstIndex(where: { $0.id == id }) {
            var updatedTranscript = transcripts[index]
            updatedTranscript.formattedContent = newContent
            transcripts[index] = updatedTranscript
            saveTranscripts()
        }
    }

    // Public method to reload transcripts from disk
    func reloadTranscripts() {
        loadTranscripts()
    }

    func reloadTranscriptsForCurrentLibrary() throws {
        let url = boundTranscriptsDirectory.appendingPathComponent("transcripts.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            transcripts = []
            return
        }
        transcripts = try JSONDecoder().decode([Transcript].self, from: Data(contentsOf: url))
    }

    func clearTranscriptsForLibraryRebindFailure() { transcripts = [] }

    func acceptLibrary(transcripts: [Transcript], transcriptsDirectory: URL) {
        libraryGeneration += 1
        boundTranscriptsDirectory = transcriptsDirectory
        self.transcripts = transcripts
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

    private func loadTranscripts() {
        // Try to load from the new directory structure
        let transcriptsDirectory = boundTranscriptsDirectory
        let transcriptsUrl = transcriptsDirectory.appendingPathComponent("transcripts.json")

        if FileManager.default.fileExists(atPath: transcriptsUrl.path) {
            do {
                let data = try Data(contentsOf: transcriptsUrl)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)
                return
            } catch {
                print("Failed to load transcripts from transcripts directory: \(error)")
            }
        }

        // Try to load from old custom directory (for backward compatibility)
        let oldCustomDirectory = directoryManager.getRecordingsDirectory()
        let oldCustomUrl = oldCustomDirectory.appendingPathComponent("transcripts.json")

        if FileManager.default.fileExists(atPath: oldCustomUrl.path) {
            do {
                let data = try Data(contentsOf: oldCustomUrl)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)

                // Save to the new location for future use
                saveTranscripts()

                // Optionally, remove the old file
                try? FileManager.default.removeItem(at: oldCustomUrl)

                return
            } catch {
                print("Failed to load transcripts from old custom directory: \(error)")
            }
        }

        // Fall back to old default directory if needed (for backward compatibility)
        let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultUrl = defaultDirectory.appendingPathComponent("transcripts.json")
        if FileManager.default.fileExists(atPath: defaultUrl.path) {
            do {
                let data = try Data(contentsOf: defaultUrl)
                transcripts = try JSONDecoder().decode([Transcript].self, from: data)

                // Save to the new location for future use
                saveTranscripts()

                // Optionally, remove the old file
                try? FileManager.default.removeItem(at: defaultUrl)
            } catch {
                print("Failed to load transcripts from old default directory: \(error)")
            }
        }
    }

    private func migrateLegacyJSONArchives() {
        for transcript in transcripts {
            guard let jsonFilePath = transcript.jsonFilePath else { continue }
            guard FileManager.default.fileExists(atPath: jsonFilePath.path) else { continue }

            do {
                let data = try Data(contentsOf: jsonFilePath)
                let response = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
                guard response.words != nil else { continue }

                let compactArchive = CompactTranscriptionArchive(
                    language_code: response.language_code,
                    language_probability: response.language_probability,
                    text: response.text,
                    transcription_id: response.transcription_id,
                    audio_duration_secs: response.audio_duration_secs,
                    speaker_segments: compactSpeakerSegments(from: response)
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let compactData = try encoder.encode(compactArchive)
                try compactData.write(to: jsonFilePath, options: .atomic)

                debugLogger.log(
                    "Migrated transcript JSON archive to compact format. transcript=\(transcript.name) oldBytes=\(data.count) compactBytes=\(compactData.count)",
                    area: .transcripts
                )
            } catch {
                debugLogger.log(
                    "Failed to migrate transcript JSON archive. transcript=\(transcript.name) error=\(error.localizedDescription)",
                    area: .transcripts
                )
            }
        }
    }

    // MARK: - JSON Response Handling

    /// Save a compact JSON transcript archive. The raw ElevenLabs response can
    /// include one object per word and one object per space; for long meetings
    /// that is large and slow to inspect, while speaker turns preserve the app's
    /// useful diarization data.
    private func saveCompactJSONResponse(_ response: ElevenLabsTranscriptionResponse, speakerSegments: [SpeakerSegment], rawResponseByteCount: Int, recording: Recording, transcriptsDirectory: URL) throws -> URL {
        // Create a unique filename with recording name and timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = dateFormatter.string(from: Date())

        // Sanitize the recording name
        let sanitizedName = recording.name.replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)
        let filename = "\(sanitizedName)_\(dateString)_\(UUID().uuidString)_json.json"

        let fileURL = transcriptsDirectory.appendingPathComponent(filename)

        do {
            let compactResponse = CompactTranscriptionArchive(
                language_code: response.language_code,
                language_probability: response.language_probability,
                text: response.text,
                transcription_id: response.transcription_id,
                audio_duration_secs: response.audio_duration_secs,
                speaker_segments: speakerSegments
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let compactData = try encoder.encode(compactResponse)
            try compactData.write(to: fileURL)
            let wordsCount = response.words?.count ?? 0
            let ratio = rawResponseByteCount == 0 ? 0 : Double(compactData.count) / Double(rawResponseByteCount)
            debugLogger.log(
                "Saved compact transcription JSON. rawBytes=\(rawResponseByteCount) compactBytes=\(compactData.count) words=\(wordsCount) speakerSegments=\(speakerSegments.count) compactRatio=\(String(format: "%.2f", ratio * 100))%",
                area: .transcripts,
                contextURL: recording.filePath
            )
            return fileURL
        } catch {
            print("Error saving JSON response: \(error.localizedDescription)")
            throw error
        }
    }

    private func compactSpeakerSegments(from response: ElevenLabsTranscriptionResponse) -> [SpeakerSegment] {
        guard let words = response.words, !words.isEmpty else { return [] }

        var segments: [SpeakerSegment] = []
        var currentSpeaker = words.first?.speaker_id ?? "speaker_unknown"
        var currentStart = words.first?.start ?? 0
        var currentEnd = words.first?.end ?? currentStart
        var currentText = ""

        func flushSegment() {
            let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            segments.append(SpeakerSegment(
                speaker_id: currentSpeaker,
                start: currentStart,
                end: currentEnd,
                text: trimmedText
            ))
        }

        for word in words {
            let speaker = word.speaker_id ?? currentSpeaker
            if speaker != currentSpeaker {
                flushSegment()
                currentSpeaker = speaker
                currentStart = word.start
                currentEnd = word.end
                currentText = word.text
            } else {
                currentEnd = word.end
                currentText += word.text
            }
        }

        flushSegment()
        return segments
    }

    /// Format transcript content based on compact speaker turns.
    private func formatTranscriptContent(response: ElevenLabsTranscriptionResponse, speakerSegments: [SpeakerSegment]) -> String {
        guard !speakerSegments.isEmpty else {
            return response.text
        }

        var formattedContent = ""
        for segment in speakerSegments {
            if !formattedContent.isEmpty {
                formattedContent += "\n\n"
            }
            formattedContent += "[\(segment.speaker_id)]\n\(segment.text)"
        }

        return formattedContent
    }
}

// MARK: - Extensions

extension Character {
    var isEndOfSentence: Bool {
        return self == "." || self == "?" || self == "!"
    }
}

// MARK: - ElevenLabs API Response

struct CompactTranscriptionArchive: Codable {
    let language_code: String?
    let language_probability: Double?
    let text: String
    let transcription_id: String?
    let audio_duration_secs: Double?
    let speaker_segments: [SpeakerSegment]
}

struct SpeakerSegment: Codable {
    let speaker_id: String
    let start: Double
    let end: Double
    let text: String
}

struct ElevenLabsTranscriptionResponse: Codable {
    let text: String
    let language_code: String?
    let language_probability: Double?
    let words: [ElevenLabsWord]?
    let transcription_id: String?
    let audio_duration_secs: Double?

    struct ElevenLabsWord: Codable {
        let text: String
        let start: Double
        let end: Double
        let type: String?
        let speaker_id: String?
    }
}

// MARK: - Errors

enum TranscriptionError: Error, LocalizedError {
    case missingApiKey
    case fileReadError
    case invalidResponse
    case apiError(statusCode: Int, message: String?)
    case staleLibrary
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "ElevenLabs API key is missing. Please add it in Settings."
        case .fileReadError:
            return "Failed to read audio file."
        case .invalidResponse:
            return "Received invalid response from ElevenLabs API."
        case .apiError(let statusCode, let message):
            if let message = message {
                return "ElevenLabs API error (Status \(statusCode)): \(message)"
            } else {
                return "ElevenLabs API error (Status \(statusCode)). Please check your API key and try again."
            }
        case .staleLibrary:
            return "Transcription was cancelled because the active library changed."
        case .unknown(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}
