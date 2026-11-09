#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline Markdown turned into the text you read, without its punctuation: for table cells, embedded notes and
/// excerpts, where nothing is edited.
@MainActor
enum InlineRenderer {
    static func render(_ text: String, font: NSFont, color: NSColor, syntax: NoteSyntax = .markdown) -> NSAttributedString {
        let units = Array(text.utf16)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let range = NSRange(location: 0, length: units.count)
        let spans = syntax == .asciidoc ? AsciiDocInlineParser.spans(in: units, range: range) : InlineParser.spans(in: units, range: range)
        var markers: [NSRange] = []
        var signs: [(NSRange, String)] = []
        for span in spans {
            if case .replacement(let shown) = span.kind {
                signs.append((span.range, shown))
                continue
            }
            markers.append(contentsOf: span.markers)
            switch span.kind {
            case .strong:
                restyleFont(result, span.content) { EditorStyle.font($0, bold: true) }
            case .emphasis:
                restyleFont(result, span.content) { EditorStyle.font($0, italic: true) }
            case .strikethrough:
                result.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.textTertiary], range: span.content)
            case .highlight:
                result.addAttribute(.backgroundColor, value: Theme.highlight, range: span.content)
            case .code:
                result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular), .backgroundColor: Theme.inlineCode], range: span.content)
            case .link, .autolink, .wikiLink, .embed:
                result.addAttribute(.foregroundColor, value: Theme.accent, range: span.content)
            case .image:
                result.addAttributes([.foregroundColor: Theme.accent], range: span.content)
            case .math(let tex):
                result.replaceCharacters(in: span.content, with: tex)
            case .footnoteReference:
                result.addAttributes([.foregroundColor: Theme.accent, .baselineOffset: 4, .font: NSFont.systemFont(ofSize: font.pointSize * 0.75)], range: span.content)
            case .replacement:
                break
            case .superscript, .subscript:
                result.addAttributes([.baselineOffset: span.kind == .superscript ? 4 : -2, .font: font.resized(font.pointSize * 0.75)], range: span.content)
            case .escape, .todoMark:
                break
            }
        }
        let edits = markers.map { ($0, "") } + signs
        for (range, text) in edits.sorted(by: { $0.0.location > $1.0.location }) where range.upperBound <= result.length {
            result.replaceCharacters(in: range, with: text)
        }
        return result
    }

    /// A table cell's text as you type in it: as `render` shows it, and for each place in its Markdown (0 to its
    /// length), the place in what shows. The marks of the spans in `revealing` show, faint, as next to the caret in the
    /// rest of a note; the backslash that keeps a `|` in its cell never shows.
    static func renderMapped(_ text: String, font: NSFont, color: NSColor, revealing: [NSRange] = []) -> (shown: NSAttributedString, map: [Int]) {
        let units = Array(text.utf16)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let range = NSRange(location: 0, length: units.count)
        var hidden = IndexSet()
        for span in InlineParser.spans(in: units, range: range) {
            let isPipe = span.kind == .escape && span.content.length == 1 && units[span.content.location] == 124
            let shows = !isPipe && revealing.contains(span.range)
            for marker in span.markers where marker.upperBound <= units.count {
                if shows {
                    result.addAttribute(.foregroundColor, value: Theme.faint, range: marker)
                } else {
                    hidden.insert(integersIn: marker.location..<marker.upperBound)
                }
            }
            switch span.kind {
            case .strong:
                restyleFont(result, span.content) { EditorStyle.font($0, bold: true) }
            case .emphasis:
                restyleFont(result, span.content) { EditorStyle.font($0, italic: true) }
            case .strikethrough:
                result.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.textTertiary], range: span.content)
            case .highlight:
                result.addAttribute(.backgroundColor, value: Theme.highlight, range: span.content)
            case .code:
                result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular), .backgroundColor: Theme.inlineCode], range: span.content)
            case .link, .autolink, .wikiLink, .embed, .image:
                result.addAttribute(.foregroundColor, value: Theme.accent, range: span.content)
            case .footnoteReference:
                result.addAttributes([.foregroundColor: Theme.accent, .baselineOffset: 4, .font: NSFont.systemFont(ofSize: font.pointSize * 0.75)], range: span.content)
            case .superscript, .subscript:
                result.addAttributes([.baselineOffset: span.kind == .superscript ? 4 : -2, .font: font.resized(font.pointSize * 0.75)], range: span.content)
            case .math, .replacement, .escape, .todoMark:
                break
            }
        }
        // A `\|` the parser didn't take as an escape (in code, say) still keeps its pipe in the cell.
        for index in 0..<max(0, units.count - 1) where units[index] == 92 && units[index + 1] == 124 && !hidden.contains(index) {
            if index == 0 || units[index - 1] != 92 { hidden.insert(index) }
        }
        var map = [Int](repeating: 0, count: units.count + 1)
        var shown = 0
        for index in 0...units.count {
            map[index] = shown
            if index < units.count, !hidden.contains(index) { shown += 1 }
        }
        for run in hidden.rangeView.reversed() {
            result.deleteCharacters(in: NSRange(location: run.lowerBound, length: run.count))
        }
        return (result, map)
    }

    private static func restyleFont(_ string: NSMutableAttributedString, _ range: NSRange, _ change: (NSFont) -> NSFont) {
        string.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { string.addAttribute(.font, value: change(font), range: run) }
        }
    }
}
