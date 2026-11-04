import Foundation

/// What a note is written in: Markdown (`.md`) or AsciiDoc (`.adoc`). The editor reads, draws and types both alike;
/// only the punctuation differs, and each note keeps its own.
public enum NoteSyntax: String, Sendable, Hashable, CaseIterable {
    case markdown, asciidoc

    /// The extensions of notes, lowercased.
    public static let markdownExtensions: Set<String> = ["md", "markdown"]
    public static let asciidocExtensions: Set<String> = ["adoc", "asciidoc"]
    public static let noteExtensions = markdownExtensions.union(asciidocExtensions)

    /// What a file with this extension is written in, if it is a note.
    public init?(pathExtension: String) {
        let lowered = pathExtension.lowercased()
        if Self.markdownExtensions.contains(lowered) {
            self = .markdown
        } else if Self.asciidocExtensions.contains(lowered) {
            self = .asciidoc
        } else {
            return nil
        }
    }

    /// What a note's file is written in: AsciiDoc for `.adoc` and `.asciidoc`, Markdown for anything else.
    public init(url: URL?) {
        self = url.flatMap { NoteSyntax(pathExtension: $0.pathExtension) } ?? .markdown
    }

    /// Whether a file's extension makes it a note.
    public static func isNote(pathExtension: String) -> Bool {
        noteExtensions.contains(pathExtension.lowercased())
    }

    /// The extension a new note of this kind gets.
    public var pathExtension: String {
        switch self {
        case .markdown: "md"
        case .asciidoc: "adoc"
        }
    }
}

/// How a note writes what Notebook puts into it (a picture pasted, a drawing, a link, a file dropped in): as Markdown,
/// or as AsciiDoc in an `.adoc` note. Paths are written as they are given.
public enum NoteMarkup {
    /// A picture on a line of its own.
    public static func picture(_ path: String, alt: String = "", syntax: NoteSyntax) -> String {
        switch syntax {
        case .markdown: "![\(alt)](\(path))"
        case .asciidoc: "image::\(path)[\(alt)]"
        }
    }

    /// A file that is no picture, on a line of its own: a card in Markdown, a link in AsciiDoc.
    public static func file(_ path: String, name: String, syntax: NoteSyntax) -> String {
        switch syntax {
        case .markdown: "![\(name)](\(path))"
        case .asciidoc: "link:\(path)[\(name)]"
        }
    }

    /// A picture or another file, whichever the path is.
    public static func attachment(_ path: String, name: String, syntax: NoteSyntax) -> String {
        MarkdownStyler.imageExtensions.contains(((path.removingPercentEncoding ?? path) as NSString).pathExtension.lowercased()) ? picture(path, syntax: syntax) : file(path, name: name, syntax: syntax)
    }

    /// A link with words of its own.
    public static func link(_ address: String, text: String, syntax: NoteSyntax) -> String {
        switch syntax {
        case .markdown:
            return "[\(text)](\(address))"
        case .asciidoc:
            let hasScheme = URL(string: address)?.scheme.map { $0.count > 1 } ?? false
            return hasScheme ? "\(address)[\(text)]" : "link:\(address)[\(text)]"
        }
    }

    /// A link to another note: `[[Name]]` in Markdown, which finds it by name, `xref:` with the way to it from the
    /// note's folder in AsciiDoc.
    public static func noteLink(name: String, path: String, syntax: NoteSyntax) -> String {
        switch syntax {
        case .markdown: "[[\(name)]]"
        case .asciidoc: "xref:\(path)[\(name)]"
        }
    }

    /// Whether text points into a folder's `.assets`, as pictures pasted into a note do.
    public static func pointsIntoAssets(_ text: String) -> Bool {
        text.contains("](.assets/") || text.contains("image::.assets/") || text.contains("image:.assets/") || text.contains("link:.assets/")
    }
}
