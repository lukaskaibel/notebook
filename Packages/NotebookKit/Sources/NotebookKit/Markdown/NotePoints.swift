import Foundation

/// A note's first points, as a reminder's notification shows them: what is still to do first, then the rest of the
/// note in its order, as plain text. Bullets become •, checkboxes ○ and numbers stay. Front matter, pictures, code,
/// tables, maths and headings stay out, and so do the things already done.
enum NotePoints {
    /// About what a notification shows, opened.
    static let maximumLines = 10
    static let maximumLength = 600

    static func text(of markdown: String) -> String {
        let document = MarkdownParser.parse(markdown)
        let string = markdown as NSString
        var open: [String] = []
        var rest: [String] = []
        for line in document.lines {
            switch line.kind {
            case .listItem(let item):
                guard !item.checked else { continue }
                let text = plain(line, in: string)
                guard !text.isEmpty else { continue }
                if item.isTask {
                    open.append("○ " + text)
                } else if case .ordered(let number, let delimiter) = item.marker {
                    rest.append("\(number)\(delimiter) " + text)
                } else {
                    rest.append("• " + text)
                }
            case .paragraph, .quote:
                let text = plain(line, in: string)
                if !text.isEmpty { rest.append(text) }
            default:
                continue
            }
        }
        var result = ""
        for line in (open + rest).prefix(maximumLines) {
            let next = result.isEmpty ? line : result + "\n" + line
            guard next.count <= maximumLength else {
                if result.isEmpty { result = String(line.prefix(maximumLength - 1)) + "…" }
                break
            }
            result = next
        }
        return result
    }

    /// The text you read on a line: its Markdown marks, pictures, embeds and a to-do's date and place left out, a
    /// link's words kept.
    static func plain(_ line: MarkdownLine, in string: NSString) -> String {
        var dropped = IndexSet()
        for span in line.spans {
            switch span.kind {
            case .image, .embed, .footnoteReference, .todoMark:
                dropped.insert(integersIn: span.range.location..<span.range.upperBound)
            default:
                for marker in span.markers { dropped.insert(integersIn: marker.location..<marker.upperBound) }
            }
        }
        var kept = IndexSet(integersIn: line.content.location..<line.content.upperBound)
        kept.subtract(dropped)
        var text = kept.rangeView.map { string.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }.joined()
        // A callout's type: "[!tip] Good to know" reads "Good to know".
        if case .quote = line.kind, text.hasPrefix("[!"), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
