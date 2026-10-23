#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Something drawn in place of Markdown: a checkbox, a picture, a rendered table. It sits on the first character of
/// the Markdown it stands for; that character is laid out as an empty box the object's size and the rest of the
/// Markdown is hidden, so the source stays in the text exactly as it is in the file.
final class EditorObject: NSObject {
    enum Kind {
        case bullet(level: Int)
        case checkbox(TaskMark)
        case quoteBar
        /// The front of a link to a note: its icon.
        case chipLead(icon: ChipIcon)
        /// The end of a link to a note: a little room after the name.
        case chipTrail
        case image(url: URL?, source: String, inline: Bool)
        /// A picture with its strokes next to it (`DrawingFile`): drawn from them, and drawn in.
        case drawing(url: URL)
        case fileCard(url: URL?, name: String)
        case noteEmbed(target: String, url: URL?)
        case horizontalRule
        case table(TableModel)
        case mermaid(source: String)
        case mathBlock(tex: String)
        case mathInline(tex: String)
        case callout(type: String, label: String?)
        case frontmatter(count: Int)
        /// After a link's text: a pencil that edits where it goes.
        case linkEdit
        /// A to-do's date or place, after its words.
        case todoPill(TodoPill)
    }

    enum ChipIcon {
        case note, file, missing, embed
    }

    let kind: Kind
    /// How far before the object's character the Markdown it stands for starts, and how long it is. Relative, so
    /// the object stays right when text before it moves it along.
    let offset: Int
    let length: Int
    /// Shown as its Markdown when the caret is next to it (math, a rule, a callout's type).
    let revealable: Bool

    /// `range` is where the Markdown is now; `at` is the character the object goes on.
    init(_ kind: Kind, range: NSRange, at index: Int? = nil, revealable: Bool = false) {
        self.kind = kind
        self.offset = (index ?? range.location) - range.location
        self.length = range.length
        self.revealable = revealable
    }

    /// The Markdown the object stands for, given the character it is on.
    func range(at index: Int) -> NSRange {
        NSRange(location: index - offset, length: length)
    }

    /// Takes a line of its own and the whole width of the text.
    var isBlock: Bool {
        switch kind {
        case .image(_, _, let inline): !inline
        case .drawing, .fileCard, .noteEmbed, .horizontalRule, .table, .mermaid, .mathBlock, .frontmatter: true
        default: false
        }
    }

    /// The caret goes around it and a selection takes all of it or none: the parts of a list item's prefix,
    /// pictures, links to notes.
    var isAtomic: Bool {
        switch kind {
        case .mathInline, .horizontalRule, .callout: false
        default: true
        }
    }

    var signature: String {
        switch kind {
        case .bullet(let level): "bullet\(level)"
        case .checkbox(let mark): "check\(mark.character)"
        case .quoteBar: "quote"
        case .chipLead(let icon): "lead\(icon)"
        case .chipTrail: "trail"
        case .image(let url, let source, let inline): "image\(url?.path ?? source)\(inline)"
        case .drawing(let url): "drawing\(url.path)"
        case .fileCard(let url, let name): "file\(url?.path ?? name)"
        case .noteEmbed(let target, _): "embed\(target)"
        case .horizontalRule: "hr"
        case .table(let model): "table\(model.signature)"
        case .mermaid(let source): "mermaid\(source)"
        case .mathBlock(let tex): "math\(tex)"
        case .mathInline(let tex): "imath\(tex)"
        case .callout(let type, let label): "callout\(type)\(label ?? "")"
        case .frontmatter(let count): "front\(count)"
        case .linkEdit: "linkEdit"
        case .todoPill(let pill): "pill\(pill.symbol)\(pill.label)\(pill.tone)"
        }
    }
}

/// A to-do's date or place as it shows after its words: a symbol and a few words in a tinted capsule, like a link to a
/// note, red once its time has passed and grey once the to-do is done.
struct TodoPill: Equatable {
    enum Tone: Equatable {
        /// `quiet`: another of the Tasks plugin's fields, which only shows.
        case normal, overdue, done, quiet
    }

    var symbol: String
    var label: String
    var tone: Tone
    /// Another of the Tasks plugin's fields, which only shows: a click on it is a click in the text.
    var isField = false

    init(_ mark: TodoMark.Kind, done: Bool, now: Date = .now) {
        switch mark {
        case .field(let field):
            symbol = field.symbol
            label = field.label(now: now)
            tone = done ? .done : .quiet
            isField = true
        case .due(let due):
            symbol = due.hasTime ? "bell.fill" : "calendar"
            label = ReminderText.text(due.date(), time: due.hasTime, now: now)
            tone = done ? .done : due.isOverdue(at: now) ? .overdue : .normal
        case .place(let place):
            symbol = "location.fill"
            // A long name would take a line of its own.
            let name = place.name.count > 26 ? place.name.prefix(24).trimmingCharacters(in: .whitespaces) + "…" : place.name
            label = place.leaving ? "Leaving " + name : name
            tone = done ? .done : .normal
        }
    }

    /// Its words, a little smaller than the text they follow.
    static func font(for body: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: max(11, (body.pointSize * 0.8).rounded()), weight: .medium)
    }

    /// Room before the capsule, and inside it around the symbol and the words.
    static let gap: CGFloat = 6
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 3

    func labelWidth(_ font: NSFont) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    func symbolSize(_ font: NSFont) -> CGFloat { (font.pointSize * 0.85).rounded() }

    /// The whole room it takes after the words: the gap and the capsule.
    func width(after body: NSFont) -> CGFloat {
        let font = Self.font(for: body)
        return Self.gap + Self.padding + symbolSize(font) + 2 + Self.spacing + labelWidth(font) + Self.padding + 1
    }
}

/// A box drawn behind text. One instance covers all the text it goes around, so where it starts and ends is the
/// run of characters that carry this very instance; that moves along with the text when text before it changes.
final class Decoration: NSObject {
    enum Kind: Equatable {
        case codeBlock(language: String, active: Bool, preview: Preview? = nil)
        case callout(type: String)
        case inlineCode
        case chip(resolved: Bool)
        case highlight
    }

    /// What a diagram or formula being edited looks like, drawn under the box with its source.
    enum Preview: Equatable {
        case diagram(source: String)
        case math(tex: String)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// Where a click on a link goes. Like a decoration, one instance covers the whole link.
public final class LinkTarget: NSObject {
    public enum Kind: Equatable {
        case url(String)
        case note(String)
        case file(URL)
    }

    public let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

extension NSAttributedString {
    /// The run of characters around `index` that carry this very object for `key`.
    func extent(of key: NSAttributedString.Key, at index: Int) -> (value: AnyObject, range: NSRange)? {
        guard index >= 0, index < length else { return nil }
        var range = NSRange()
        guard let value = attribute(key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: length)) as AnyObject? else { return nil }
        return (value, range)
    }
}

/// Callout types, as GitHub and Obsidian name them.
enum CalloutStyle {
    static func color(_ type: String) -> NSColor {
        switch type {
        case "tip", "hint", "success", "check", "done": Theme.positive
        case "important", "abstract", "summary", "tldr", "example": Theme.purple
        case "warning", "caution", "attention", "question", "help", "faq": Theme.warning
        case "danger", "error", "failure", "fail", "missing", "bug": Theme.red
        default: Theme.accent
        }
    }

    static func symbol(_ type: String) -> String {
        switch type {
        case "tip", "hint": "lightbulb"
        case "success", "check", "done": "checkmark.circle"
        case "important": "exclamationmark.bubble"
        case "abstract", "summary", "tldr": "list.bullet.rectangle"
        case "example": "list.bullet"
        case "warning", "attention": "exclamationmark.triangle"
        case "caution", "danger", "error": "exclamationmark.octagon"
        case "failure", "fail", "missing": "xmark.circle"
        case "bug": "ladybug"
        case "question", "help", "faq": "questionmark.circle"
        case "quote", "cite": "quote.opening"
        default: "info.circle"
        }
    }

    static func title(_ type: String) -> String {
        type.prefix(1).uppercased() + type.dropFirst()
    }
}
