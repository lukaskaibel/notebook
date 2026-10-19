import Foundation

/// The formatting a note can be given, as the Format menu, the toolbar's Aa menu and the bar above the keyboard
/// offer it.
enum FormatCommand: CaseIterable, Identifiable {
    case title, heading, subheading, body
    case bold, italic, strikethrough, highlight, code, link
    case checklist, bulletedList, numberedList, quote
    case indent, outdent

    var id: Self { self }

    var name: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Code"
        case .link: "Link"
        case .checklist: "Checklist"
        case .bulletedList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .quote: "Block Quote"
        case .indent: "Indent"
        case .outdent: "Outdent"
        }
    }

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "text.alignleft"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .checklist: "checklist"
        case .bulletedList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        }
    }

    static let styles: [FormatCommand] = [.title, .heading, .subheading, .body]
    static let inline: [FormatCommand] = [.bold, .italic, .strikethrough, .highlight, .code]
    static let lists: [FormatCommand] = [.checklist, .bulletedList, .numberedList, .quote]
}

extension EditorController {
    func perform(_ command: FormatCommand) {
        switch command {
        case .title: setLineFormat(.heading(1))
        case .heading: setLineFormat(.heading(2))
        case .subheading: setLineFormat(.heading(3))
        case .body: setLineFormat(.body)
        case .bold: toggle(.bold)
        case .italic: toggle(.italic)
        case .strikethrough: toggle(.strikethrough)
        case .highlight: toggle(.highlight)
        case .code: toggle(.code)
        case .link: insertLink()
        case .checklist: setLineFormat(.checklist)
        case .bulletedList: setLineFormat(.bullets)
        case .numberedList: setLineFormat(.numbered)
        case .quote: setLineFormat(.quote)
        case .indent: indent(by: 1)
        case .outdent: indent(by: -1)
        }
    }

    /// What the line with the caret is: one of the four text styles, or a kind of list or a quote.
    var currentLineFormat: FormatCommand? {
        guard !document.lines.isEmpty else { return .body }
        switch document.lines[document.lineIndex(containing: selection.location)].kind {
        case .heading(let level, _): return level == 1 ? .title : level == 2 ? .heading : .subheading
        case .listItem(let item): return item.isTask ? .checklist : item.isOrdered ? .numberedList : .bulletedList
        case .quote: return .quote
        default: return .body
        }
    }

    /// Whether the caret or the selection is in text with this formatting.
    func isActive(_ command: FormatCommand) -> Bool {
        guard !document.lines.isEmpty else { return false }
        let selection = self.selection
        let line = document.lines[document.lineIndex(containing: selection.location)]
        let format: InlineFormat
        switch command {
        case .bold: format = .bold
        case .italic: format = .italic
        case .strikethrough: format = .strikethrough
        case .highlight: format = .highlight
        case .code: format = .code
        default: return currentLineFormat == command
        }
        return line.spans.contains { format.matches($0.kind) && $0.range.location <= selection.location && $0.range.upperBound >= selection.upperBound }
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// A shortcut of the iPad's Format menu, after the system's Bold and Italic, which the text view turns into Markdown.
/// The note's text view takes these keys itself (`MarkdownTextView.keyCommands`), listed while ⌘ is held: buttons in
/// the system's Format menu don't get their shortcuts on iPad.
struct FormatShortcut {
    /// What it does; nil for Mark as Checked.
    let command: FormatCommand?
    let key: Character
    let modifiers: EventModifiers

    init(_ command: FormatCommand?, _ key: Character, _ modifiers: EventModifiers = .command) {
        self.command = command
        self.key = key
        self.modifiers = modifiers
    }

    var name: String { command?.name ?? "Mark as Checked" }
    var symbol: String { command?.symbol ?? "checkmark.circle" }

    /// As the menu shows them, between dividers.
    static let groups: [[FormatShortcut]] = [
        [
            FormatShortcut(.strikethrough, "x", [.command, .shift]),
            FormatShortcut(.highlight, "h", [.command, .control]),
            FormatShortcut(.code, "e"),
            FormatShortcut(.link, "l"),
        ],
        [
            FormatShortcut(.title, "t", [.command, .shift]),
            FormatShortcut(.heading, "h", [.command, .shift]),
            FormatShortcut(.subheading, "j", [.command, .shift]),
            FormatShortcut(.body, "b", [.command, .shift]),
        ],
        [
            FormatShortcut(.checklist, "l", [.command, .shift]),
            FormatShortcut(nil, "u", [.command, .shift]),
            FormatShortcut(.bulletedList, "7", [.command, .shift]),
            FormatShortcut(.numberedList, "9", [.command, .shift]),
            FormatShortcut(.quote, "'"),
        ],
        [
            FormatShortcut(.indent, "]", [.command, .option]),
            FormatShortcut(.outdent, "[", [.command, .option]),
        ],
    ]

    static let all = Array(groups.joined())

    /// The shortcut as a key command for the text view, named for the list shown while ⌘ is held. Its property list is
    /// its place in `all`.
    func keyCommand(action: Selector, index: Int) -> UIKeyCommand {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.control) { flags.insert(.control) }
        let command = UIKeyCommand(title: name, image: UIImage(systemName: symbol), action: action, input: String(key), modifierFlags: flags, propertyList: index)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}

extension EditorController {
    func perform(_ shortcut: FormatShortcut) {
        if let command = shortcut.command { perform(command) } else { toggleChecked() }
    }
}
#endif
