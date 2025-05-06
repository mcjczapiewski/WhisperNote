import SwiftUI
import UniformTypeIdentifiers

// Extension to UTType for markdown
extension UTType {
    static var markdown: UTType {
        UTType(exportedAs: "public.markdown")
    }
}

// Document class for exporting text files
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .markdown] }

    var text: String
    var contentType: UTType

    init(initialText: String = "", contentType: UTType = .plainText) {
        self.text = initialText
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(data: data, encoding: .utf8) ?? ""
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
}
