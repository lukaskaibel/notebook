import Foundation
import Observation

/// What the caret is in, as the bar above the keyboard shows it on its left: the styles it is in, the checkbox of its
/// line, whether its list item can move in or out, and the link it is on.
@MainActor
@Observable
final class CaretContext {
    var context = MarkdownEditing.Context()
    /// Where the link the caret is on goes: an address, a note or a file.
    var link: LinkTarget.Kind?
}

/// What the last press of Bold (or another style) took off, for the next press to put back.
struct MarkdownUnwrapped {
    var style: MarkdownSyntax.Style
    var range: NSRange
    var text: String
}

/// The text whose marks Delete just took off, for a mark typed next to it to style again, while nothing else changed.
struct MarkdownUnmarked {
    var range: NSRange
    var text: String
}

/// The typing rules of `MarkdownEditing` applied to the note: each takes the text and the selection and gives back new
/// ones, which go in as one undoable edit, with the characters that stay easing from their old look.
extension EditorController {
    var markdownState: MarkdownEditing.State {
        MarkdownEditing.State(text, selection: selection)
    }

    /// Puts the new text in as one undoable edit and selects what the rule selected.
    func apply(_ state: MarkdownEditing.State, actionName: String? = nil) {
        let (range, replacement) = MarkdownEditing.difference(from: text, to: state.text)
        // The rule's caret exactly; a selection takes the Markdown it covers whole, as everywhere in the note.
        selectsExactly = true
        defer { selectsExactly = false }
        if range.length > 0 || !replacement.isEmpty {
            styleAnimator.keep(storage, replacing: range, with: replacement)
            replace(range, with: replacement, select: state.selection, actionName: actionName)
        }
        let selection = state.selection.length > 0 ? expandSelection(state.selection) : state.selection
        if selection != self.selection { setSelection(selection) }
    }

    /// Runs a rule; false when it leaves the keystroke to the text view. Nothing applies inside code or maths, where
    /// nothing is Markdown, or in front matter.
    @discardableResult
    func perform(_ rule: (MarkdownEditing.State) -> MarkdownEditing.State?, actionName: String? = nil) -> Bool {
        guard !isWaitingForText, isInProse else { return false }
        let state = markdownState
        guard let result = rule(state) else { return false }
        if result != state { apply(result, actionName: actionName) }
        return true
    }

    /// Delete (or forward delete) by the rules of `MarkdownEditing`: a style's marks go a pair at a time, and the text
    /// whose last marks went is remembered, so typing a mark next to it brings them back.
    func deleteByRules(forward: Bool) -> Bool {
        guard !isWaitingForText, isInProse, let deletion = MarkdownEditing.deleting(markdownState, forward: forward) else { return false }
        apply(deletion.state, actionName: "Delete")
        unmarked = deletion.unmarked.map { MarkdownUnmarked(range: $0, text: text) }
        return true
    }

    /// A character typed, by the rules of `MarkdownEditing`; false when it goes in as it is.
    func insertByRules(_ typed: String) -> Bool {
        let memory = unmarked.flatMap { $0.text == text ? $0.range : nil }
        return perform { MarkdownEditing.insert(typed, in: $0, unmarked: memory) }
    }

    /// Bold, italics, strikethrough, highlight or code on or off, by the rules of `MarkdownEditing`: at the end of a
    /// style it leaves it, just behind it goes back in, a second press puts back what the first took off.
    func toggle(_ style: MarkdownSyntax.Style) {
        guard !isWaitingForText else { return }
        guard isInProse else { return toggleWords(style) }
        let state = markdownState
        let restoring = unwrapped.flatMap { $0.style == style && $0.text == state.text ? $0.range : nil }
        let result = MarkdownEditing.toggle(style, in: state, restoring: restoring)
        apply(result.state, actionName: "Format")
        unwrapped = result.unwrapped.map { MarkdownUnwrapped(style: style, range: $0, text: result.state.text) }
    }

    /// Whether the caret (or the start of the selection) is in text that is Markdown: not in code, maths, a table or
    /// front matter, whose lines have rules of their own.
    var isInProse: Bool {
        guard !document.lines.isEmpty else { return true }
        let start = document.lineIndex(containing: selection.location)
        let end = document.lineIndex(containing: max(selection.location, selection.upperBound - (selection.length > 0 ? 1 : 0)))
        return document.lines[start...end].allSatisfy { line in
            switch line.kind {
            case .fence, .code, .mathDelimiter, .math, .tableHeader, .tableDelimiter, .tableRow, .frontmatterDelimiter, .frontmatter: false
            default: true
            }
        }
    }

    /// While a word is still being composed (Japanese, Chinese), keys belong to the input method.
    var hasMarkedText: Bool {
        #if os(macOS)
        textView.hasMarkedText()
        #else
        textView.markedTextRange != nil
        #endif
    }

    /// Brings the bar's buttons for where the caret is up to date.
    func updateCaretContext() {
        #if os(iOS)
        let editing = isFocused && !isWaitingForText && !isDrawing
        let context = editing && isInProse ? MarkdownEditing.context(in: markdownState) : MarkdownEditing.Context()
        if caretContext.context != context { caretContext.context = context }
        let link = editing ? linkTarget(at: selection) : nil
        if caretContext.link != link { caretContext.link = link }
        #endif
    }

    /// The link a caret rests in or right behind.
    private func linkTarget(at selection: NSRange) -> LinkTarget.Kind? {
        guard selection.length == 0, storage.length > 0 else { return nil }
        for index in [selection.location, selection.location - 1] where index >= 0 && index < storage.length {
            if let link = storage.attribute(.notebookLink, at: index, effectiveRange: nil) as? LinkTarget { return link.kind }
        }
        return nil
    }
}
