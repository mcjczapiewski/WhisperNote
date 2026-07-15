import Foundation

class DirectoryManager {
    static let shared = DirectoryManager()

    // Base directory for all files
    private let baseDirectoryName = "WhisperNote/Files"

    // Subdirectories
    private let recordingsDirectoryName = "Recordings"
    private let transcriptsDirectoryName = "Transcripts"
    private let summariesDirectoryName = "Summaries"
    private let templatesDirectoryName = "Templates"
    private let libraryMetadataFilename = "library-metadata.json"
    private let summaryTemplatesFilename = "summary-templates.json"

    private init() {
        // Create base directories on initialization
        createBaseDirectories()
    }

    private func createBaseDirectories() {
        let baseDir = getBaseDirectory()
        ensureDirectoryExists(at: baseDir)

        let recordingsDir = baseDir.appendingPathComponent(recordingsDirectoryName)
        ensureDirectoryExists(at: recordingsDir)

        let transcriptsDir = baseDir.appendingPathComponent(transcriptsDirectoryName)
        ensureDirectoryExists(at: transcriptsDir)

        let summariesDir = baseDir.appendingPathComponent(summariesDirectoryName)
        ensureDirectoryExists(at: summariesDir)

        let templatesDir = baseDir.appendingPathComponent(templatesDirectoryName)
        ensureDirectoryExists(at: templatesDir)
    }

    /// Get the base directory for all WhisperNote files
    func getBaseDirectory() -> URL {
        // Check if user has selected a custom directory
        if let customDirectory = resolveBookmarkedDirectory() {
            // Use the custom directory as the base
            let baseDir = customDirectory.appendingPathComponent(baseDirectoryName, isDirectory: true)
            ensureDirectoryExists(at: baseDir)
            return baseDir
        }

        // Fall back to the default Documents directory
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDir = documentsDirectory.appendingPathComponent(baseDirectoryName, isDirectory: true)
        ensureDirectoryExists(at: baseDir)
        return baseDir
    }

    /// Get the directory URL for saving recordings
    func getRecordingsDirectory() -> URL {
        let baseDir = getBaseDirectory()
        let recordingsDir = baseDir.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
        ensureDirectoryExists(at: recordingsDir)
        return recordingsDir
    }

    /// Get the directory URL for saving transcripts
    func getTranscriptsDirectory() -> URL {
        let baseDir = getBaseDirectory()
        let transcriptsDir = baseDir.appendingPathComponent(transcriptsDirectoryName, isDirectory: true)
        ensureDirectoryExists(at: transcriptsDir)
        return transcriptsDir
    }

    /// Get the directory URL for saving summaries
    func getSummariesDirectory() -> URL {
        let baseDir = getBaseDirectory()
        let summariesDir = baseDir.appendingPathComponent(summariesDirectoryName, isDirectory: true)
        ensureDirectoryExists(at: summariesDir)
        return summariesDir
    }

    /// Get the directory URL for reusable local templates.
    func getTemplatesDirectory() -> URL {
        let templatesDir = getBaseDirectory().appendingPathComponent(templatesDirectoryName, isDirectory: true)
        ensureDirectoryExists(at: templatesDir)
        return templatesDir
    }

    /// Canonical versioned store for reusable summary templates.
    func getSummaryTemplatesURL() -> URL {
        getTemplatesDirectory().appendingPathComponent(summaryTemplatesFilename, isDirectory: false)
    }

    /// Pure path construction used by library preflight and tests.
    static func summaryTemplatesURL(baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent("summary-templates.json", isDirectory: false)
    }

    /// Canonical sidecar for user-managed library metadata such as tags and favorites.
    func getLibraryMetadataURL() -> URL {
        getBaseDirectory().appendingPathComponent(libraryMetadataFilename, isDirectory: false)
    }

    /// Pure candidate resolution for a library switch. It neither consults nor mutates
    /// UserDefaults and deliberately creates no directories during preflight.
    func candidateBaseDirectory(selectedRootPath: String?) -> URL {
        if let selectedRootPath, !selectedRootPath.isEmpty {
            return URL(fileURLWithPath: selectedRootPath, isDirectory: true)
                .appendingPathComponent(baseDirectoryName, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(baseDirectoryName, isDirectory: true)
    }

    /// Ensure that a directory exists, creating it if necessary
    private func ensureDirectoryExists(at url: URL) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                print("Created directory at: \(url.path)")
            } catch {
                print("Error creating directory: \(error.localizedDescription)")
            }
        } else if !isDirectory.boolValue {
            print("Warning: Path exists but is not a directory: \(url.path)")
        }
    }

    /// Resolve a bookmarked directory URL from UserDefaults
    private func resolveBookmarkedDirectory() -> URL? {
        // Check if we have a saved path
        guard let path = UserDefaults.standard.string(forKey: "recordingsDirectory"),
              !path.isEmpty else {
            return nil
        }

        // First try to create a URL from the path directly
        let directURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            return directURL
        }

        // If that fails, try to resolve from bookmark data
        guard let bookmarkData = UserDefaults.standard.data(forKey: "recordingsDirectoryBookmark") else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)

            if isStale {
                // If the bookmark is stale, we should update it
                print("Bookmark is stale, needs to be refreshed")
                return nil
            }

            // Start accessing the security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                return url
            } else {
                return nil
            }
        } catch {
            print("Error resolving bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Create a unique filename for a recording
    func createUniqueFilename(name: String, format: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = dateFormatter.string(from: Date())

        // Sanitize the name to remove characters that might cause issues in filenames
        let sanitizedName = name.replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)

        return "\(sanitizedName)_\(dateString).\(format)"
    }

    /// Get a URL for a new recording file
    func getURLForNewRecording(name: String, format: String) -> URL {
        let directory = getRecordingsDirectory()
        let filename = createUniqueFilename(name: name, format: format)
        let fileURL = directory.appendingPathComponent(filename)

        // Print the full path for debugging
        print("Creating new recording at: \(fileURL.path)")

        return fileURL
    }

    /// Release access to security-scoped resources when done
    func releaseSecurityScopedAccess(for url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
