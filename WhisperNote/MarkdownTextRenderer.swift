import AppKit
import Foundation

enum MarkdownTextRenderer {
    static func plainText(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let renderedLines = lines.map { line in
            let style = lineStyle(for: line)
            guard !style.isRule else { return "----------" }
            return normalizeInlinePlainText(style.prefix + inlinePlainText(from: style.content))
        }

        return renderedLines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributedText(from markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let style = lineStyle(for: rawLine)
            let attributedLine: NSMutableAttributedString

            if style.isRule {
                attributedLine = NSMutableAttributedString(string: "────────────", attributes: [
                    .font: style.font,
                    .foregroundColor: style.color
                ])
            } else {
                attributedLine = NSMutableAttributedString(string: style.prefix, attributes: [
                    .font: style.font,
                    .foregroundColor: style.color
                ])
                attributedLine.append(inlineAttributedText(from: style.content, baseFont: style.font, color: style.color))
            }

            let fullRange = NSRange(location: 0, length: attributedLine.length)
            if attributedLine.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = 3
                paragraphStyle.paragraphSpacing = style.paragraphSpacing
                paragraphStyle.firstLineHeadIndent = style.firstLineIndent
                paragraphStyle.headIndent = style.headIndent
                attributedLine.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
            }

            output.append(attributedLine)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        return output
    }

    private static func lineStyle(for rawLine: String) -> LineStyle {
        let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let baseIndent = CGFloat(leadingSpaces / 2) * 18
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        let leadingTrimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if isHorizontalRule(trimmed) {
            return LineStyle(content: "", prefix: "", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, paragraphSpacing: 8, firstLineIndent: baseIndent, headIndent: baseIndent, isRule: true)
        }

        if let heading = parseHeading(leadingTrimmed) {
            let size: CGFloat
            let spacing: CGFloat
            switch heading.level {
            case 1:
                size = 22
                spacing = 12
            case 2:
                size = 18
                spacing = 10
            case 3:
                size = 16
                spacing = 8
            default:
                size = 14
                spacing = 6
            }
            return LineStyle(content: heading.content, prefix: "", font: .boldSystemFont(ofSize: size), color: .labelColor, paragraphSpacing: spacing, firstLineIndent: baseIndent, headIndent: baseIndent, isRule: false)
        }

        if let ordered = parseOrderedList(leadingTrimmed) {
            let prefix = "\(ordered.number).  "
            return LineStyle(content: ordered.content, prefix: prefix, font: .systemFont(ofSize: 12), color: .labelColor, paragraphSpacing: 4, firstLineIndent: baseIndent + 18, headIndent: baseIndent + 46, isRule: false)
        }

        if let unordered = parseUnorderedList(leadingTrimmed) {
            return LineStyle(content: unordered, prefix: "•  ", font: .systemFont(ofSize: 12), color: .labelColor, paragraphSpacing: 4, firstLineIndent: baseIndent + 18, headIndent: baseIndent + 38, isRule: false)
        }

        if let quote = parseBlockquote(leadingTrimmed) {
            return LineStyle(content: quote, prefix: "", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, paragraphSpacing: 5, firstLineIndent: baseIndent + 18, headIndent: baseIndent + 18, isRule: false)
        }

        return LineStyle(content: rawLine.trimmingCharacters(in: .whitespaces), prefix: "", font: .systemFont(ofSize: 12), color: .labelColor, paragraphSpacing: trimmed.isEmpty ? 8 : 4, firstLineIndent: baseIndent, headIndent: baseIndent, isRule: false)
    }

    private static func inlineAttributedText(from markdown: String, baseFont: NSFont, color: NSColor) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        var index = markdown.startIndex

        while index < markdown.endIndex {
            if let link = parseLink(in: markdown, at: index) {
                output.append(NSAttributedString(string: link.label, attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
                output.append(NSAttributedString(string: " (\(link.url))", attributes: [
                    .font: baseFont,
                    .foregroundColor: color
                ]))
                index = link.endIndex
                continue
            }

            if let code = parseDelimited(in: markdown, at: index, delimiter: "`") {
                output.append(NSAttributedString(string: code.content, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: NSColor.textBackgroundColor
                ]))
                index = code.endIndex
                continue
            }

            if let boldItalic = parseDelimited(in: markdown, at: index, delimiter: "***") ?? parseDelimited(in: markdown, at: index, delimiter: "___") {
                output.append(inlineAttributedText(from: boldItalic.content, baseFont: boldItalicFont(baseFont), color: color))
                index = boldItalic.endIndex
                continue
            }

            if let bold = parseDelimited(in: markdown, at: index, delimiter: "**") ?? parseDelimited(in: markdown, at: index, delimiter: "__") {
                output.append(inlineAttributedText(from: bold.content, baseFont: boldFont(baseFont), color: color))
                index = bold.endIndex
                continue
            }

            if let strike = parseDelimited(in: markdown, at: index, delimiter: "~~") {
                let text = inlineAttributedText(from: strike.content, baseFont: baseFont, color: color)
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.length))
                output.append(text)
                index = strike.endIndex
                continue
            }

            if let italic = parseDelimited(in: markdown, at: index, delimiter: "*") ?? parseDelimited(in: markdown, at: index, delimiter: "_") {
                output.append(inlineAttributedText(from: italic.content, baseFont: italicFont(baseFont), color: color))
                index = italic.endIndex
                continue
            }

            output.append(NSAttributedString(string: String(markdown[index]), attributes: [
                .font: baseFont,
                .foregroundColor: color
            ]))
            index = markdown.index(after: index)
        }

        return output
    }

    private static func inlinePlainText(from markdown: String) -> String {
        var output = ""
        var index = markdown.startIndex

        while index < markdown.endIndex {
            if let link = parseLink(in: markdown, at: index) {
                output += "\(inlinePlainText(from: link.label)) (\(link.url))"
                index = link.endIndex
                continue
            }

            if let code = parseDelimited(in: markdown, at: index, delimiter: "`") {
                output += code.content
                index = code.endIndex
                continue
            }

            if let boldItalic = parseDelimited(in: markdown, at: index, delimiter: "***") ?? parseDelimited(in: markdown, at: index, delimiter: "___") {
                output += inlinePlainText(from: boldItalic.content)
                index = boldItalic.endIndex
                continue
            }

            if let bold = parseDelimited(in: markdown, at: index, delimiter: "**") ?? parseDelimited(in: markdown, at: index, delimiter: "__") {
                output += inlinePlainText(from: bold.content)
                index = bold.endIndex
                continue
            }

            if let strike = parseDelimited(in: markdown, at: index, delimiter: "~~") {
                output += inlinePlainText(from: strike.content)
                index = strike.endIndex
                continue
            }

            if let italic = parseDelimited(in: markdown, at: index, delimiter: "*") ?? parseDelimited(in: markdown, at: index, delimiter: "_") {
                output += inlinePlainText(from: italic.content)
                index = italic.endIndex
                continue
            }

            output.append(markdown[index])
            index = markdown.index(after: index)
        }

        return output
    }

    private static func parseDelimited(in text: String, at index: String.Index, delimiter: String) -> DelimitedMatch? {
        guard text[index...].hasPrefix(delimiter) else { return nil }
        let contentStart = text.index(index, offsetBy: delimiter.count)
        guard contentStart < text.endIndex,
              let contentEnd = text[contentStart...].range(of: delimiter)?.lowerBound else {
            return nil
        }

        let content = String(text[contentStart..<contentEnd])
        guard !content.isEmpty else { return nil }
        let endIndex = text.index(contentEnd, offsetBy: delimiter.count)
        return DelimitedMatch(content: content, endIndex: endIndex)
    }

    private static func parseLink(in text: String, at index: String.Index) -> LinkMatch? {
        guard text[index] == "[",
              let labelEnd = text[index...].firstIndex(of: "]") else {
            return nil
        }

        let parenStart = text.index(after: labelEnd)
        guard parenStart < text.endIndex,
              text[parenStart] == "(",
              let urlEnd = text[parenStart...].firstIndex(of: ")") else {
            return nil
        }

        let labelStart = text.index(after: index)
        let urlStart = text.index(after: parenStart)
        let label = String(text[labelStart..<labelEnd])
        let url = String(text[urlStart..<urlEnd])
        guard !label.isEmpty, !url.isEmpty else { return nil }

        return LinkMatch(label: label, url: url, endIndex: text.index(after: urlEnd))
    }

    private static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        var index = line.startIndex

        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0,
              index < line.endIndex,
              line[index] == " " else {
            return nil
        }

        let contentStart = line.index(after: index)
        return (level, String(line[contentStart...]))
    }

    private static func parseOrderedList(_ line: String) -> (number: String, content: String)? {
        let pattern = #"^([0-9]+)[\.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              let numberRange = Range(match.range(at: 1), in: line),
              let contentRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        return (String(line[numberRange]), String(line[contentRange]))
    }

    private static func parseUnorderedList(_ line: String) -> String? {
        guard line.count > 2 else { return nil }

        let marker = line[line.startIndex]
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }

        let contentStart = line.index(after: line.startIndex)
        guard contentStart < line.endIndex,
              line[contentStart].isWhitespace else {
            return nil
        }

        return String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseBlockquote(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" }
    }

    private static func normalizeInlinePlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    private static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italicFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func boldItalicFont(_ font: NSFont) -> NSFont {
        italicFont(boldFont(font))
    }

    private struct LineStyle {
        let content: String
        let prefix: String
        let font: NSFont
        let color: NSColor
        let paragraphSpacing: CGFloat
        let firstLineIndent: CGFloat
        let headIndent: CGFloat
        let isRule: Bool
    }

    private struct DelimitedMatch {
        let content: String
        let endIndex: String.Index
    }

    private struct LinkMatch {
        let label: String
        let url: String
        let endIndex: String.Index
    }
}
