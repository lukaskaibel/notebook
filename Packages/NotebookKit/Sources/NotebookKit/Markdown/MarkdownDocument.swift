import Foundation

/// A Markdown file read line by line, the way the editor needs it: every line knows what it is, which characters
/// are Markdown punctuation and which are the text you read. Ranges count UTF-16 code units, as `NSString` does.
public struct MarkdownDocument {
    public var lines: [MarkdownLine]
    public var blocks: [MarkdownBlock]
    public var length: Int

    /// The line that holds a character (or the caret at that index).
    public func lineIndex(containing location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].range.location <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func line(containing location: Int) -> MarkdownLine? {
        lines.isEmpty ? nil : lines[lineIndex(containing: location)]
    }

    public func block(containing location: Int) -> MarkdownBlock? {
        guard let index = line(containing: location)?.block else { return nil }
        return blocks[index]
    }
}

public struct MarkdownLine: Equatable {
    /// The line without its line break.
    public var range: NSRange
    /// The line break after it: 0 on the last line, 1 for `\n`, 2 for `\r\n`.
    public var breakLength: Int
    public var kind: LineKind
    /// The block it belongs to, for lines that only make sense together (code, tables, math, quotes).
    public var block: Int?
    /// The text after the line's own punctuation (`- `, `> `, `## `), where inline Markdown is read.
    public var content: NSRange
    public var spans: [InlineSpan]
    /// A hash of the line's characters, line break included, to tell cheaply whether it changed.
    public var textHash: Int = 0

    public var fullRange: NSRange { NSRange(location: range.location, length: range.length + breakLength) }
}

public enum LineKind: Hashable {
    case blank
    case paragraph
    case heading(level: Int, marker: NSRange)
    case listItem(ListItem)
    case quote(depth: Int, prefix: NSRange)
    case thematicBreak
    case fence
    case code
    case mathDelimiter
    case math
    case tableHeader
    case tableDelimiter
    case tableRow
    case frontmatterDelimiter
    case frontmatter
    case footnoteDefinition(label: NSRange)

    public var isListItem: Bool { if case .listItem = self { true } else { false } }
}

public struct ListItem: Hashable {
    public enum Marker: Hashable {
        case bullet(Character)
        case ordered(Int, Character)
    }

    /// Spaces before the marker; a tab counts as four.
    public var indent: Int
    /// How deep the item sits in its list, from 0.
    public var level: Int
    public var indentRange: NSRange
    public var marker: Marker
    public var markerRange: NSRange
    /// Everything before the item's text: indent, marker, spaces, checkbox.
    public var prefix: NSRange
    /// `[ ]` or `[x]` of a task, or another mark between the brackets.
    public var checkbox: NSRange?
    /// Done or cancelled: no longer to do.
    public var checked: Bool
    /// What a task's brackets hold.
    public var mark: TaskMark = .open

    public var isTask: Bool { checkbox != nil }
    public var isOrdered: Bool { if case .ordered = marker { true } else { false } }
}

/// What a task's brackets hold. Obsidian makes a checkbox of any character there, and its themes and the Tasks plugin
/// give many of them a meaning: `[ ]` to do, `[x]` done, `[/]` in progress, `[-]` cancelled, `[!]` important, `[?]` a
/// question, `[>]` moved on and so on. As in the Tasks plugin, all but done and cancelled are still to do.
public enum TaskMark: Hashable, Sendable {
    case open, done, inProgress, cancelled
    case other(Character)

    /// The mark a character between brackets makes, if it makes one: any character but a digit (`[1]` starts a
    /// reference), a bracket, a backslash or a backtick, and no space but the space.
    public init?(_ unit: UInt16) {
        switch unit {
        case 32: self = .open
        case 120, 88: self = .done
        case 47: self = .inProgress
        case 45: self = .cancelled
        case 48...57, 91, 92, 93, 96, 0..<32, 127, 0xD800...0xDFFF: return nil
        default:
            guard let scalar = UnicodeScalar(unit), !scalar.properties.isWhitespace else { return nil }
            self = .other(Character(scalar))
        }
    }

    /// Done or cancelled.
    public var isClosed: Bool { self == .done || self == .cancelled }

    /// As it is written between the brackets.
    public var character: Character {
        switch self {
        case .open: " "
        case .done: "x"
        case .inProgress: "/"
        case .cancelled: "-"
        case .other(let character): character
        }
    }

    /// The symbol drawn in the circle of a mark Obsidian's themes draw as one, as the Minimal and Things themes do.
    public var symbol: String? {
        guard case .other(let character) = self else { return nil }
        return switch character {
        case ">": "arrow.right"
        case "<": "calendar"
        case "!": "exclamationmark"
        case "?": "questionmark"
        case "*": "star.fill"
        case "\"", "“": "quote.opening"
        case "l", "L": "location.fill"
        case "b": "bookmark.fill"
        case "i": "info"
        case "I": "lightbulb.fill"
        case "S": "dollarsign"
        case "p": "hand.thumbsup.fill"
        case "c": "hand.thumbsdown.fill"
        case "f": "flame.fill"
        case "k": "key.fill"
        case "w": "trophy.fill"
        case "u": "arrow.up"
        case "d": "arrow.down"
        case "n", "N": "note.text"
        case "+": "plus"
        case "@": "person.fill"
        case "T": "clock"
        default: nil
        }
    }

    /// What it means, in words, for VoiceOver and menus.
    public var name: String {
        switch self {
        case .open: "To Do"
        case .done: "Done"
        case .inProgress: "In Progress"
        case .cancelled: "Cancelled"
        case .other(let character):
            switch character {
            case ">": "Moved On"
            case "<": "Scheduled"
            case "!": "Important"
            case "?": "Question"
            case "*": "Starred"
            default: "To Do"
            }
        }
    }
}

public struct MarkdownBlock: Equatable {
    public enum Kind: Hashable {
        case code(language: String)
        case mermaid
        case table(alignments: [TableAlignment])
        case math
        case frontmatter
        case quote
        case callout(type: String)
    }

    public var kind: Kind
    /// Indices of its first and last line.
    public var lines: ClosedRange<Int>
    /// From the start of its first line to the end of its last, without the last line break.
    public var range: NSRange

    /// Blocks whose look changes as a whole when the caret goes in: they show their Markdown then.
    public var isSwappable: Bool {
        switch kind {
        case .table, .math, .frontmatter, .mermaid: true
        default: false
        }
    }
}

public enum TableAlignment: Hashable, Sendable {
    case leading, center, trailing
}

public struct InlineSpan: Equatable {
    public enum Kind: Equatable {
        case strong
        case emphasis
        case strikethrough
        /// `==marked==` text.
        case highlight
        case code
        case link(destination: String)
        case image(source: String, alt: String)
        case wikiLink(target: String, alias: String?)
        case embed(target: String)
        case math(tex: String)
        case autolink(url: String)
        case footnoteReference(label: String)
        case escape
        /// A to-do's due date or place (`TodoMarks`).
        case todoMark(TodoMark.Kind)

        var isStyle: Bool {
            switch self {
            case .strong, .emphasis, .strikethrough, .highlight, .code: true
            default: false
            }
        }
    }

    public var kind: Kind
    /// All of it, punctuation included.
    public var range: NSRange
    /// The punctuation, hidden unless the caret is in or next to the span.
    public var markers: [NSRange]
    /// What you read.
    public var content: NSRange

    /// Bold, italics, strikethrough, highlights and code: styles that typing and the bar above the keyboard turn on
    /// and off.
    var isStyle: Bool { kind.isStyle }

    /// Spans that are one thing on screen: the caret goes around them and a selection takes all or nothing.
    public var isAtomic: Bool {
        switch kind {
        case .image, .wikiLink, .embed, .todoMark: true
        default: false
        }
    }

    func shifted(by offset: Int) -> InlineSpan {
        InlineSpan(
            kind: kind,
            range: range.shifted(by: offset),
            markers: markers.map { $0.shifted(by: offset) },
            content: content.shifted(by: offset)
        )
    }
}

extension NSRange {
    func shifted(by offset: Int) -> NSRange { NSRange(location: location + offset, length: length) }

    /// Whether a caret at `location` touches the range: inside it or at either end.
    func touches(_ location: Int) -> Bool { location >= self.location && location <= upperBound }

    func strictlyContains(_ location: Int) -> Bool { location > self.location && location < upperBound }
}
