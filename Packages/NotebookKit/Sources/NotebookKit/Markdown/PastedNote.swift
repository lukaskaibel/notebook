import Foundation

/// Markdown pasted as a note of its own, such as a Markdown file's contents. A note's title is its file's name, shown
/// above its text, so the `# Heading` such a file starts with is the note's title rather than a line of its text.
struct PastedNote: Equatable {
    /// The title, as it reads: without a heading's #s.
    var title: String
    /// What goes under it: the rest, from its first line that isn't empty. Front matter stays at the top.
    var text: String

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    /// A document that starts with a `# Heading`, after any front matter, and has text after it. Nil for anything
    /// else: a heading of a section (`## Day one`) or further down is part of the text, and so is a heading by itself.
    init?(document markdown: String) {
        let split = Self.split(markdown) { kind in
            if case .heading(1, _) = kind { true } else { false }
        }
        guard let split, !split.title.isEmpty, !split.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self = split
    }

    /// Text pasted in a title, which holds one line: its first, as it reads without a heading's #s or a list item's
    /// bullet, and what comes after it for the text.
    init(forTitle markdown: String) {
        if let document = PastedNote(document: markdown) {
            self = document
        } else if let split = Self.split(markdown, isTitle: { _ in true }) {
            self = split
        } else {
            self.init(title: "", text: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The first line that isn't empty or front matter as the title, when `isTitle` takes it, and the rest.
    private static func split(_ markdown: String, isTitle: (LineKind) -> Bool) -> PastedNote? {
        let string = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
        let skipped: [LineKind] = [.blank, .frontmatter, .frontmatterDelimiter]
        guard let line = MarkdownParser.parse(string).lines.first(where: { !skipped.contains($0.kind) }), isTitle(line.kind) else { return nil }
        var title = string.substring(with: line.content)
        // A heading may close with #s of its own: `# Kyoto #`.
        if case .heading = line.kind {
            title = title.replacingOccurrences(of: "[ \t]+#+[ \t]*$", with: "", options: .regularExpression)
        }
        title = title.trimmingCharacters(in: .whitespaces)
        let above = string.substring(to: line.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        // The blank lines between the title and the text go with the title.
        let below = string.substring(from: line.fullRange.upperBound).replacingOccurrences(of: "^([ \t]*\n)+", with: "", options: .regularExpression)
        return PastedNote(title: title, text: [above, below].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
