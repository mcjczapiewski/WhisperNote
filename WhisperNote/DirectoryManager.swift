import Foundation

class DirectoryManager {
    static let shared = DirectoryManager()
    
    private init() {}
    
    /// Get the directory URL for saving recordings
    func getRecordingsDirectory() -> URL {
        // Check if user has selected a custom directory
        if let customDirectory = resolveBookmarkedDirectory() {
            return customDirectory
        }
        
        // Fall back to the default Documents directory
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        return directory.appendingPathComponent(filename)
    }
    
    /// Release access to security-scoped resources when done
    func releaseSecurityScopedAccess(for url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
