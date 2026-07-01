import AppKit
import Foundation

enum FinderHelper {
    static func showInFinder(_ url: URL) {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let containingDirectory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: containingDirectory.path) {
            NSWorkspace.shared.open(containingDirectory)
            return
        }

        NSWorkspace.shared.open(DirectoryManager.shared.getBaseDirectory())
    }
}
