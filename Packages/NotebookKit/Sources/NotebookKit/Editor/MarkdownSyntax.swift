import Foundation

/// The Markdown of a note as the typing rules in `MarkdownEditing` see it, line by line: the styles, the marks around
/// them, and what a line starts with. It is the same as Issues', so the two apps type alike; Notebook adds highlights
/// and `~~~` fences. An AsciiDoc note is seen the same way with its own marks: `*bold*`, `_italics_`, `#highlights#`,
/// `[.line-through]#struck#`, `* item` nested as `** item`, `== Heading`. Positions are UTF-16 offsets, as the text
/// views count them.
enum MarkdownSyntax {
    enum Style: CaseIterable, Hashable {
        case bold, italic, strikethrough, highlight, code
    }

    /// A styled run such as `**bold**`: where it is, and where its content is between the marks.
    struct Span: Equatable {
        var style: Style
        var range: NSRange
        var content: NSRange

        var opening: NSRange { NSRange(location: range.location, length: content.location - range.location) }
        var closing: NSRange { NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)) }
    }

    /// What a line starts with.
    struct Line: Equatable {
        enum Kind: Equatable {
            case plain
            case bullet
            case ordered(Int)
            case quote
            case heading(Int)
        }

        /// The line without its line break.
        var range: NSRange
        var kind: Kind = .plain
        /// The spaces or tabs it starts with, before a list marker.
        var indent = 0
        /// The marker with the space after it: `- `, `12. `, `> `, `## `. Empty on a plain line.
        var marker: NSRange
        /// A checklist's box with the space after it, `[ ] `.
        var checkbox: NSRange?
        var isChecked = false
        /// AsciiDoc: how deep the item is nested, by its marker (`**` is 1).
        var depth = 0

        var isList: Bool {
            switch kind {
            case .bullet, .ordered: true
            default: false
            }
        }

        /// Where the text of the line starts, after everything Markdown put in front of it.
        var contentStart: Int { checkbox.map(NSMaxRange) ?? NSMaxRange(marker) }
        /// The column a nested item has to start at to belong to this one.
        var childIndent: Int { NSMaxRange(marker) - range.location }
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and tested, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#)
    static let quote = regex(#"^(>[ \t]?)(.*)$"#)
    static let listMarker = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[(?: |[^\s0-9\[\]\\`\x{10000}-\x{10FFFF}])\][ \t]+)?"#)
    static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    // A space before the closing marks still counts, unlike in CommonMark: it is there for a moment whenever a space
    // is typed in bold text, and the bold would flicker off and on with every word.
    static let bold = regex(#"(\*\*|__)(?=\S)(.+?)\1"#)
    /// `*` works inside a word as in CommonMark, `_` only around one; either may sit inside bold, as in `**_both_**`.
    static let italic = regex(#"(?<!\*)\*(?=[^\s*])(.+?)(?<!\*)\*(?!\*)|(?<![_\w])_(?=[^\s_])(.+?)(?<!_)_(?![_\w])"#)
    static let strikethrough = regex(#"~~(?=\S)(.+?)~~"#)
    static let highlight = regex(#"==(?=\S)(.+?)=="#)
    static let link = regex(#"(!?)\[([^\]\n]+)\]\(([^)\s]+)[^)\n]*\)"#)
    static let url = regex(#"(?<![(<\w])https?://[^\s<>()\]]+"#)
    static let html = regex(#"</?[a-zA-Z][^>\n]*>"#)
    static let inlineCode = regex(#"`[^`\n]+`"#)
    static let fence = regex(#"^(```|~~~)[^\n]*\n[\s\S]*?(?:^\1[ \t]*$|\z)"#)

    // AsciiDoc's marks: doubled anywhere, single at a word's edges, as Asciidoctor reads them.
    static let asciidocStrongUnconstrained = regex(#"\*\*(?=\S)(.+?)\*\*"#)
    static let asciidocStrong = regex(#"(?<![\p{L}\p{N}_*;:}\\])\*(?=[^\s*])(.+?)\*(?![\p{L}\p{N}_*])"#)
    static let asciidocEmphasisUnconstrained = regex(#"__(?=\S)(.+?)__"#)
    static let asciidocEmphasis = regex(#"(?<![\p{L}\p{N}_;:}\\])_(?=[^\s_])(.+?)_(?![\p{L}\p{N}_])"#)
    static let asciidocMarkUnconstrained = regex(#"(?<!\])##(?=\S)(.+?)##"#)
    static let asciidocMark = regex(#"(?<![\p{L}\p{N}_#;:}\]\\])#(?=[^\s#])(.+?)#(?![\p{L}\p{N}_#])"#)
    static let asciidocStrike = regex(#"\[\.line-through\]#(?=\S)(.+?)#(?![\p{L}\p{N}_#])"#)
    /// Listing, literal, passthrough and comment blocks, and fenced code, where nothing is AsciiDoc.
    static let asciidocFence = regex(#"^(-{4,}|\.{4,}|\+{4,}|/{4,}|```)[^\n]*\n[\s\S]*?(?:^\1[ \t]*$|\z)"#)
    static let asciidocURL = regex(#"(?<![\w])(?:https?|mailto|ftp):(?://)?[^\s<>\[\]]+"#)
    static let asciidocRule = regex(#"^[ \t]*(?:'''|<<<|---|\*\*\*|- - -|\* \* \*)[ \t]*$"#)
    private static let asciidocListPrefix = regex(#"^([ \t]*)(\*{1,5}|-|\.{1,5}|(\d{1,9})\.)([ \t]+)(?:\[([ xX*])\](?:[ \t]+|$))?"#)
    private static let asciidocHeadingPrefix = regex(#"^(={1,6}|#{1,6})[ \t]+"#)

    /// A checkbox holds a space, an x or another of the marks `TaskMark` reads.
    private static let listPrefix = regex(#"^([ \t]*)([-*+]|(\d{1,9})[.)])([ \t]+)(?:\[( |[^\s0-9\[\]\\`\x{10000}-\x{10FFFF}])\](?:[ \t]+|$))?"#)
    private static let headingPrefix = regex(#"^(#{1,6})[ \t]+"#)
    /// Nested quotes as one marker, `> > `, which Return carries on whole.
    private static let quotePrefix = regex(#"^(?:>[ \t]?)+"#)

    /// The length of a style's marks on each side.
    static func markLength(_ style: Style) -> Int {
        switch style {
        case .bold, .strikethrough, .highlight: 2
        case .italic, .code: 1
        }
    }

    /// The fenced code blocks, where nothing is Markdown.
    static func fences(in text: NSString, syntax: NoteSyntax = .markdown) -> [NSRange] {
        (syntax == .asciidoc ? asciidocFence : fence).matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
    }

    /// The styled runs in part of the text (usually a line), outermost first. Nothing inside code counts, and
    /// nothing in a fenced code block.
    static func spans(in text: NSString, _ range: NSRange, fences: [NSRange] = [], syntax: NoteSyntax = .markdown) -> [Span] {
        if syntax == .asciidoc { return asciidocSpans(in: text, range, fences: fences) }
        let string = text as String
        func find(_ expression: NSRegularExpression, _ style: Style) -> [Span] {
            let mark = markLength(style)
            return expression.matches(in: string, range: range).map { match in
                Span(style: style, range: match.range, content: NSRange(location: match.range.location + mark, length: match.range.length - 2 * mark))
            }
        }
        let code = find(inlineCode, .code)
        let others = [find(bold, .bold), find(italic, .italic), find(strikethrough, .strikethrough), find(highlight, .highlight)].joined().filter { span in
            // A span may hold code, but not start or end inside it.
            !code.contains { NSIntersectionRange($0.range, span.range).length > 0 && !contains(span.content, $0.range) }
        }
        return (code + others)
            .filter { span in !fences.contains { NSIntersectionRange($0, span.range).length > 0 } }
            .sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }

    /// AsciiDoc's styled runs, as `spans` finds Markdown's.
    private static func asciidocSpans(in text: NSString, _ range: NSRange, fences: [NSRange]) -> [Span] {
        let string = text as String
        func find(_ expression: NSRegularExpression, _ style: Style) -> [Span] {
            expression.matches(in: string, range: range).map { Span(style: style, range: $0.range, content: $0.range(at: 1)) }
        }
        let code = find(inlineCode, .code)
        let found = [
            find(asciidocStrongUnconstrained, .bold), find(asciidocStrong, .bold),
            find(asciidocEmphasisUnconstrained, .italic), find(asciidocEmphasis, .italic),
            find(asciidocMarkUnconstrained, .highlight), find(asciidocMark, .highlight), find(asciidocStrike, .strikethrough),
        ].joined()
        // A span may hold code, but not start or end inside it; and a doubled pair is one span, not a single pair in it.
        let others = found.filter { span in
            !code.contains { NSIntersectionRange($0.range, span.range).length > 0 && !contains(span.content, $0.range) }
                && !found.contains { $0 != span && $0.style == span.style && $0.range.location == span.range.location - 1 && contains($0.range, span.range) }
        }
        return (code + others)
            .filter { span in !fences.contains { NSIntersectionRange($0, span.range).length > 0 } }
            .sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }


    /// The line around a place in the text, and what it starts with.
    static func line(at location: Int, in text: NSString, syntax: NoteSyntax = .markdown) -> Line {
        if syntax == .asciidoc { return asciidocLine(at: location, in: text) }
        let range = lineRange(at: location, in: text)
        var line = Line(range: range, marker: NSRange(location: range.location, length: 0))
        let string = text as String
        if rule.firstMatch(in: string, range: range) != nil { return line }
        if let match = listPrefix.firstMatch(in: string, range: range) {
            line.indent = match.range(at: 1).length
            let number = match.range(at: 3)
            line.kind = number.location == NSNotFound ? .bullet : .ordered(Int(text.substring(with: number)) ?? 1)
            line.marker = NSRange(location: match.range(at: 2).location, length: NSMaxRange(match.range(at: 4)) - match.range(at: 2).location)
            let mark = match.range(at: 5)
            if mark.location != NSNotFound {
                line.checkbox = NSRange(location: NSMaxRange(line.marker), length: NSMaxRange(match.range) - NSMaxRange(line.marker))
                line.isChecked = TaskMark(text.character(at: mark.location))?.isClosed ?? false
            }
        } else if let match = headingPrefix.firstMatch(in: string, range: range) {
            line.kind = .heading(match.range(at: 1).length)
            line.marker = match.range
        } else if let match = quotePrefix.firstMatch(in: string, range: range) {
            line.kind = .quote
            line.marker = match.range
        } else {
            // A list marker would go after the spaces a plain line starts with.
            while line.indent < range.length, [32, 9].contains(text.character(at: range.location + line.indent)) { line.indent += 1 }
            line.marker.location += line.indent
        }
        return line
    }

    /// An AsciiDoc line and what it starts with: `* `, `** [ ] `, `. `, `1. `, `== `.
    private static func asciidocLine(at location: Int, in text: NSString) -> Line {
        let range = lineRange(at: location, in: text)
        var line = Line(range: range, marker: NSRange(location: range.location, length: 0))
        let string = text as String
        if asciidocRule.firstMatch(in: string, range: range) != nil { return line }
        if let match = asciidocListPrefix.firstMatch(in: string, range: range) {
            line.indent = match.range(at: 1).length
            let marker = text.substring(with: match.range(at: 2))
            let number = match.range(at: 3)
            if number.location != NSNotFound {
                line.kind = .ordered(Int(text.substring(with: number)) ?? 1)
            } else {
                line.kind = marker.hasPrefix(".") ? .ordered(1) : .bullet
                line.depth = marker.hasPrefix("-") ? 0 : marker.count - 1
            }
            line.marker = NSRange(location: match.range(at: 2).location, length: NSMaxRange(match.range(at: 4)) - match.range(at: 2).location)
            let mark = match.range(at: 5)
            if mark.location != NSNotFound {
                line.checkbox = NSRange(location: NSMaxRange(line.marker), length: NSMaxRange(match.range) - NSMaxRange(line.marker))
                line.isChecked = text.character(at: mark.location) != 32
            }
        } else if let match = asciidocHeadingPrefix.firstMatch(in: string, range: range) {
            line.kind = .heading(match.range(at: 1).length)
            line.marker = match.range
        } else if let match = quotePrefix.firstMatch(in: string, range: range) {
            line.kind = .quote
            line.marker = match.range
        } else {
            while line.indent < range.length, [32, 9].contains(text.character(at: range.location + line.indent)) { line.indent += 1 }
            line.marker.location += line.indent
        }
        return line
    }


    /// The line around a place in the text, without its line break.
    static func lineRange(at location: Int, in text: NSString) -> NSRange {
        var range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return range
    }

    static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}
