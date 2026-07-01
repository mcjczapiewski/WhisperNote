import Foundation

enum DebugLogArea {
    case recordings
    case transcripts
    case summaries

    var directory: URL {
        switch self {
        case .recordings:
            return DirectoryManager.shared.getRecordingsDirectory()
        case .transcripts:
            return DirectoryManager.shared.getTranscriptsDirectory()
        case .summaries:
            return DirectoryManager.shared.getSummariesDirectory()
        }
    }
}

final class DebugLogger {
    static let shared = DebugLogger()

    private let lock = NSLock()
    private let fileManager = FileManager.default

    private init() {}

    func log(_ message: String, area: DebugLogArea, contextURL: URL? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        lock.lock()
        defer { lock.unlock() }

        append(line, to: dailyLogURL(for: area))

        if let contextURL {
            let contextDirectory = contextURL.hasDirectoryPath ? contextURL : contextURL.deletingLastPathComponent()
            append(line, to: contextDirectory.appendingPathComponent("debug.log"))
        }
    }

    private func dailyLogURL(for area: DebugLogArea) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return area.directory.appendingPathComponent("debug_\(formatter.string(from: Date())).log")
    }

    private func append(_ line: String, to url: URL) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }

            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("Failed to write debug log: \(error.localizedDescription)")
        }
    }
}
