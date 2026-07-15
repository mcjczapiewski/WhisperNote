import AppKit
import SwiftUI

struct ReadOnlyTranscriptTextView: NSViewRepresentable {
    let text: String
    var attributedText: NSAttributedString? = nil
    var searchText = ""
    var selectedMatch = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        applyContent(to: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyContent(to: textView, coordinator: context.coordinator)
    }

    private func applyContent(to textView: NSTextView, coordinator: Coordinator) {
        let base = attributedText ?? NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        let content = base.string
        guard coordinator.content != content || coordinator.query != searchText || coordinator.selectedMatch != selectedMatch else { return }

        let rendered = NSMutableAttributedString(attributedString: base)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [NSRange] = []
        if !query.isEmpty {
            var range = NSRange(location: 0, length: (content as NSString).length)
            while range.length > 0 {
                let match = (content as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                rendered.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: match)
                let next = match.location + match.length
                range = NSRange(location: next, length: max(0, range.location + range.length - next))
            }
        }
        textView.textStorage?.setAttributedString(rendered)
        if !matches.isEmpty {
            let match = matches[selectedMatch.clamped(to: 0...(matches.count - 1))]
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
        }
        coordinator.content = content
        coordinator.query = searchText
        coordinator.selectedMatch = selectedMatch
    }

    final class Coordinator {
        var content = ""
        var query = ""
        var selectedMatch = 0
    }
}

struct ReadOnlyTextSearchField: View {
    @Binding var text: String
    @Binding var selectedMatch: Int
    let content: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search text", text: Binding(
                get: { text },
                set: { text = $0; selectedMatch = 0 }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(selectedMatch.clamped(to: 0...(matchCount - 1)) + 1) of \(matchCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button { selectedMatch = (selectedMatch - 1 + matchCount) % matchCount } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(matchCount == 0)
                Button { selectedMatch = (selectedMatch + 1) % matchCount } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(matchCount == 0)
            }
        }
    }

    private var matchCount: Int {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        var count = 0
        var range = content.startIndex..<content.endIndex
        while let match = content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            count += 1
            range = match.upperBound..<content.endIndex
        }
        return count
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
