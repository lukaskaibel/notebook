import Foundation

/// What typing does to Markdown besides putting characters in, as in Notion or Bear. Bold and the other styles turn
/// on and off; a style's marks are kept or removed as a pair; Return leaves a style and continues a list; "-" starts
/// one. Each rule takes the text and the selection and gives back new ones, so the Mac, the iPhone and the iPad type
/// the same and every rule can be tested. `nil` means the keystroke does what it always does. The rules are Issues',
/// with highlights added, so a note and an issue type alike.
enum MarkdownEditing {
    typealias Style = MarkdownSyntax.Style
    typealias Span = MarkdownSyntax.Span
    typealias Line = MarkdownSyntax.Line

    struct State: Equatable {
        var text: String
        /// UTF-16, as the text views count.
        var selection: NSRange

        init(_ text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }

        init(_ text: String, caret: Int) {
            self.init(text, selection: NSRange(location: caret, length: 0))
        }

        func moving(to caret: Int) -> State {
            State(text, caret: caret)
        }
    }

    /// The kinds of list the bar above the keyboard starts.
    enum Block {
        case bullet, checklist, ordered
    }

    /// What is on where the caret is, for the bar above the keyboard to offer.
    struct Context: Equatable {
        var styles: Set<Style> = []
        var line: Line.Kind = .plain
        var isChecklist = false
        var isChecked = false
        var canIndent = false
        var canOutdent = false
        var link: URL?

        var isList: Bool {
            switch line {
            case .bullet, .ordered: true
            default: false
            }
        }
    }

    // MARK: - Styles

    /// Bold, italics, strikethrough or code, on or off. With a selection it wraps or unwraps the selected text. At a
    /// caret it unwraps the style the caret is in, leaves it from the end of its text (where typing on would still
    /// be in it), goes back into it from just behind it, styles the word the caret is in, or else leaves an empty
    /// pair of marks to type into. `restoring` is the text a previous press unwrapped, which a second press styles
    /// again; the result says what this press unwrapped.
    static func toggle(_ style: Style, in state: State, restoring: NSRange? = nil) -> (state: State, unwrapped: NSRange?) {
        let document = Document(state.text)
        if state.selection.length == 0 {
            return toggle(style, at: state.selection.location, in: document, restoring: restoring)
        }
        return (toggle(style, selection: state.selection, in: document), nil)
    }

    private static func toggle(_ style: Style, at caret: Int, in document: Document, restoring: NSRange?) -> (state: State, unwrapped: NSRange?) {
        let text = document.text
        let line = document.line(at: caret)
        let spans = document.spans(on: line.range)
        if let pair = document.emptyPair(around: caret, spans: spans), pair.style == style {
            return (document.replacing(pair.range, with: "", caret: pair.range.location), nil)
        }
        let mine = spans.filter { $0.style == style }
        if let span = mine.last(where: { $0.range.location < caret && caret < NSMaxRange($0.range) }) {
            let inner = spans.filter { $0 != span && MarkdownSyntax.contains(span.content, $0.range) }
            if span.content.length > 0, skippingClosings(from: min(caret, NSMaxRange(span.content)), spans: inner) == NSMaxRange(span.content) {
                return (leaving(span, in: document), nil)
            }
            let unwrapped = NSRange(location: span.range.location, length: span.content.length)
            return (unwrap(span, in: document, caret: caret), unwrapped)
        }
        if let span = mine.last(where: { NSMaxRange($0.range) == caret && $0.content.length > 0 }) {
            return (State(text as String, caret: NSMaxRange(span.content)), nil)
        }
        if let restoring, NSMaxRange(restoring) <= text.length, restoring.location <= caret, caret <= NSMaxRange(restoring) {
            return (wrap(restoring, in: style, document: document, caret: caret), nil)
        }
        if let word = document.word(around: caret) {
            return (wrap(word, in: style, document: document, caret: caret), nil)
        }
        let mark = self.mark(for: style, before: document.character(caret - 1), after: document.character(caret))
        return (document.replacing(NSRange(location: caret, length: 0), with: mark + mark, caret: caret + mark.utf16.count), nil)
    }

    private static func toggle(_ style: Style, selection: NSRange, in document: Document) -> State {
        let text = document.text
        // Each line's part of the selection, after its list marker, without the spaces around it.
        var parts: [(part: NSRange, spans: [Span])] = []
        var location = selection.location
        while location <= NSMaxRange(selection), location <= text.length {
            let line = document.line(at: location)
            let start = max(selection.location, line.contentStart)
            let end = min(NSMaxRange(selection), NSMaxRange(line.range))
            if end > start, let part = document.trimmed(NSRange(location: start, length: end - start)) {
                parts.append((part, document.spans(on: line.range).filter { $0.style == style }))
            }
            location = NSMaxRange(line.range) + 1
        }
        guard !parts.isEmpty else {
            return toggle(style, at: selection.location, in: document, restoring: nil).state
        }
        let isOn = parts.allSatisfy { part in
            part.spans.contains { MarkdownSyntax.contains($0.range, part.part) }
        }
        let result = NSMutableString(string: text)
        // From the last line up, so the places above stay right; the selections found so far move with each edit.
        var selections: [NSRange] = []
        for part in parts.reversed() {
            let edit = isOn ? removing(style, from: part.part, spans: part.spans, in: document)
                : adding(style, to: part.part, spans: part.spans, in: document)
            result.replaceCharacters(in: edit.range, with: edit.text)
            let delta = edit.text.utf16.count - edit.range.length
            selections = selections.map { NSRange(location: $0.location + delta, length: $0.length) }
            selections.insert(NSRange(location: edit.range.location + edit.selected.location, length: edit.selected.length), at: 0)
        }
        let start = selections.first!.location
        return State(result as String, selection: NSRange(location: start, length: NSMaxRange(selections.last!) - start))
    }

    /// The edit that takes a style off a selected part of a line, splitting the span if the part is inside it.
    private static func removing(_ style: Style, from part: NSRange, spans: [Span], in document: Document) -> (range: NSRange, text: String, selected: NSRange) {
        guard let span = spans.last(where: { MarkdownSyntax.contains($0.range, part) }) else {
            return (part, document.string(part), NSRange(location: 0, length: part.length))
        }
        let opening = document.string(span.opening)
        let closing = document.string(span.closing)
        // A selection that takes in some of the marks counts as the text between them.
        let part = NSIntersectionRange(part, span.content)
        if part.length == 0 || part == span.content {
            return (span.range, document.string(span.content), NSRange(location: 0, length: span.content.length))
        }
        var text = ""
        let left = document.string(NSRange(location: span.content.location, length: part.location - span.content.location))
        if !left.isEmpty {
            // Spaces stay outside the marks, where Markdown needs them.
            let core = left.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            text += core.isEmpty ? left : opening + core + closing + left.dropFirst(core.count)
        }
        let selected = NSRange(location: text.utf16.count, length: part.length)
        text += document.string(part)
        let right = document.string(NSRange(location: NSMaxRange(part), length: NSMaxRange(span.content) - NSMaxRange(part)))
        if !right.isEmpty {
            let core = right.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
            text += core.isEmpty ? right : right.dropLast(core.count) + opening + core + closing
        }
        return (span.range, text, selected)
    }

    /// The edit that styles a selected part of a line, taking in the spans of the same style it touches.
    private static func adding(_ style: Style, to part: NSRange, spans: [Span], in document: Document) -> (range: NSRange, text: String, selected: NSRange) {
        var union = part
        let touched = spans.filter { NSIntersectionRange($0.range, part).length > 0 }
        for span in touched { union = NSUnionRange(union, span.range) }
        // The marks of the spans taken in go; their text is styled as a whole.
        let marks = touched.flatMap { [$0.opening, $0.closing] }.sorted { $0.location > $1.location }
        let inner = NSMutableString(string: document.string(union))
        for mark in marks {
            inner.deleteCharacters(in: NSRange(location: mark.location - union.location, length: mark.length))
        }
        let mark = self.mark(for: style, before: document.character(union.location - 1), after: document.character(NSMaxRange(union)))
        return (union, mark + (inner as String) + mark, NSRange(location: mark.utf16.count, length: inner.length))
    }

    /// The marks a new span of a style gets. Italics take `_`, or `*` next to a letter, where `_` wouldn't work.
    private static func mark(for style: Style, before: unichar?, after: unichar?) -> String {
        switch style {
        case .bold: "**"
        case .italic: isWordCharacter(before) || isWordCharacter(after) ? "*" : "_"
        case .strikethrough: "~~"
        case .highlight: "=="
        case .code: "`"
        }
    }

    private static func wrap(_ range: NSRange, in style: Style, document: Document, caret: Int) -> State {
        let mark = self.mark(for: style, before: document.character(range.location - 1), after: document.character(NSMaxRange(range)))
        let length = mark.utf16.count
        let result = NSMutableString(string: document.text)
        result.insert(mark, at: NSMaxRange(range))
        result.insert(mark, at: range.location)
        let moved = caret < range.location ? caret : caret <= NSMaxRange(range) ? caret + length : caret + 2 * length
        return State(result as String, caret: moved)
    }

    /// The span without its marks, the caret staying with the character it was next to.
    private static func unwrap(_ span: Span, in document: Document, caret: Int) -> State {
        let result = NSMutableString(string: document.text)
        result.deleteCharacters(in: span.closing)
        result.deleteCharacters(in: span.opening)
        let moved: Int
        if caret <= span.range.location {
            moved = caret
        } else if caret <= NSMaxRange(span.opening) {
            moved = span.range.location
        } else if caret <= NSMaxRange(span.content) {
            moved = caret - span.opening.length
        } else if caret <= NSMaxRange(span.range) {
            moved = NSMaxRange(span.content) - span.opening.length
        } else {
            moved = caret - span.opening.length - span.closing.length
        }
        return State(result as String, caret: moved)
    }

    /// Out of a style from the end of its text, where typing on would still be in it. Spaces typed last go out with
    /// the caret: Markdown doesn't end a style after a space, so `**bold **` wouldn't be bold in other apps.
    private static func leaving(_ span: Span, in document: Document) -> State {
        let content = document.string(span.content)
        let core = content.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let spaces = content.utf16.count - core.utf16.count
        guard spaces > 0, !core.isEmpty else { return State(document.text as String, caret: NSMaxRange(span.range)) }
        let trailing = NSRange(location: NSMaxRange(span.content) - spaces, length: spaces)
        let result = NSMutableString(string: document.text)
        result.insert(document.string(trailing), at: NSMaxRange(span.range))
        result.deleteCharacters(in: trailing)
        return State(result as String, caret: NSMaxRange(span.range))
    }

    /// Past the closing marks that start at `position`, innermost first: from `**_bold|_**` to the end.
    private static func skippingClosings(from position: Int, spans: [Span]) -> Int {
        var position = position
        while let span = spans.last(where: { $0.closing.location == position && $0.closing.length > 0 }) {
            position = NSMaxRange(span.range)
        }
        return position
    }

    // MARK: - Lists

    /// Bullets, a checklist or numbers for the lines of the selection, or off again where they all have them.
    static func toggle(_ block: Block, in state: State) -> State {
        let document = Document(state.text)
        var lines = document.lines(in: state.selection)
        if lines.count > 1 { lines = lines.filter { $0.range.length > 0 } }
        guard !lines.isEmpty else { return state }
        func has(_ line: Line) -> Bool {
            switch block {
            case .bullet: line.kind == .bullet && line.checkbox == nil
            case .checklist: line.checkbox != nil
            case .ordered: if case .ordered = line.kind { line.checkbox == nil } else { false }
            }
        }
        let removing = lines.allSatisfy(has)
        var number = 1
        if case .ordered(let previous) = document.line(before: lines[0])?.kind { number = previous + 1 }
        var edits: [(range: NSRange, text: String)] = []
        for line in lines where removing || !has(line) {
            let prefix = NSRange(location: line.marker.location, length: line.contentStart - line.marker.location)
            guard !removing else {
                edits.append((prefix, ""))
                continue
            }
            let bullet = line.kind == .bullet ? document.string(NSRange(location: line.marker.location, length: 1)) : "-"
            let marker: String
            switch block {
            case .bullet:
                marker = bullet + " "
            case .checklist:
                marker = (line.isList ? document.string(line.marker).trimmingCharacters(in: .whitespaces) : bullet) + " [ ] "
            case .ordered:
                marker = "\(number). "
                number += 1
            }
            edits.append((prefix, marker))
        }
        return document.applying(edits, to: state.selection)
    }

    /// Ticks or unticks the checkbox of the caret's line.
    static func toggleCheckbox(in state: State) -> State? {
        let document = Document(state.text)
        let line = document.line(at: state.selection.location)
        guard let box = line.checkbox else { return nil }
        return document.applying([(NSRange(location: box.location + 1, length: 1), line.isChecked ? " " : "x")], to: state.selection)
    }

    /// The list items of the selection one level in, under the item above.
    static func indent(in state: State) -> State? {
        shift(in: state, inwards: true)
    }

    /// The list items of the selection one level out.
    static func outdent(in state: State) -> State? {
        shift(in: state, inwards: false)
    }

    private static func shift(in state: State, inwards: Bool) -> State? {
        let document = Document(state.text)
        let lines = document.lines(in: state.selection)
        guard let first = lines.first(where: \.isList) else { return nil }
        let amount: Int
        if inwards {
            // To where the text of the item above starts, which makes it that item's child.
            let above = document.listItem(before: first) { $0.indent <= first.indent }
            amount = above.map { $0.childIndent > first.indent ? $0.childIndent - first.indent : 2 } ?? 2
        } else {
            guard first.indent > 0 else { return nil }
            let parent = document.listItem(before: first) { $0.indent < first.indent }
            amount = first.indent - (parent?.indent ?? 0)
        }
        var edits: [(range: NSRange, text: String)] = []
        for line in lines where line.range.length > 0 {
            if inwards {
                edits.append((NSRange(location: line.range.location, length: 0), String(repeating: " ", count: amount)))
            } else {
                let whitespace = document.leadingWhitespace(of: line.range)
                edits.append((NSRange(location: line.range.location, length: min(amount, whitespace)), ""))
            }
        }
        return document.applying(edits, to: state.selection)
    }

    // MARK: - Typing

    /// Return: leaves the styles the caret is at the end of, splits those it is in the middle of, continues a list
    /// or a quote with the next marker, and ends one on an empty item.
    static func insertNewline(in state: State) -> State? {
        guard state.selection.length == 0, !Document(state.text).isInFence(state.selection.location) else { return nil }
        var text = state.text
        var caret = state.selection.location
        var changed = false
        // A pair of marks with nothing in it goes, as if the style had never been turned on.
        while true {
            let document = Document(text)
            guard let pair = document.emptyPair(around: caret, spans: document.spans(on: document.line(at: caret).range)) else { break }
            text = document.replacing(pair.range, with: "", caret: pair.range.location).text
            caret = pair.range.location
            changed = true
        }
        let document = Document(text)
        let line = document.line(at: caret)
        let spans = document.spans(on: line.range)

        // The line breaks after the styles that end at the caret, or before those that start there.
        var split = skippingClosings(from: caret, spans: spans.filter { $0.content.length > 0 })
        var entered: [Span] = []
        if split == caret {
            while let span = spans.first(where: { NSMaxRange($0.opening) == split && $0.content.length > 0 }) {
                entered.append(span)
                split = span.range.location
            }
        }
        // Styles that go on after the break are closed before it and opened again after it.
        let open = spans.filter { $0.content.location < split && split < NSMaxRange($0.content) }
        var left = document.string(NSRange(location: line.range.location, length: split - line.range.location))
        if split > caret {
            // Leaving styles at the end of the line: spaces typed last before their marks would undo them in Markdown.
            left = left.replacingOccurrences(of: #"[ \t]+((?:\*\*|__|~~|==|[*_~`])+)$"#, with: "$1", options: .regularExpression)
        }
        var right = document.string(NSRange(location: split, length: NSMaxRange(line.range) - split))
        var reopened = ""
        if !open.isEmpty {
            let core = left.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            left = core + open.reversed().map { document.string($0.closing) }.joined() + left.dropFirst(core.count)
            right = right.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
            reopened = open.map { document.string($0.opening) }.joined()
        }

        // Lists and quotes go on; an empty item ends them, or takes the item one level out.
        var continuation = ""
        if line.isList || line.kind == .quote, split >= line.contentStart {
            let content = document.string(NSRange(location: line.contentStart, length: NSMaxRange(line.range) - line.contentStart))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.isList, line.indent > 0, let out = outdent(in: State(text, caret: caret)) { return out }
                let prefix = NSRange(location: line.marker.location, length: line.contentStart - line.marker.location)
                return document.applying([(prefix, "")], to: NSRange(location: caret, length: 0))
            }
            continuation = document.string(NSRange(location: line.range.location, length: line.indent)) + nextMarker(after: line, in: document)
        }
        guard changed || !open.isEmpty || split != caret || !continuation.isEmpty else { return nil }
        let replaced = NSRange(location: line.range.location, length: line.range.length)
        let newLine = left + "\n" + continuation + reopened + right
        let enteredMarks = entered.reduce(0) { $0 + $1.opening.length }
        let newCaret = line.range.location + left.utf16.count + 1 + continuation.utf16.count + reopened.utf16.count + enteredMarks
        return document.replacing(replaced, with: newLine, caret: newCaret)
    }

    /// The marker the item after a list item or quote line starts with.
    private static func nextMarker(after line: Line, in document: Document) -> String {
        let marker = document.string(line.marker)
        var next: String
        switch line.kind {
        case .ordered(let number):
            let digits = marker.prefix { $0.isNumber }
            next = "\(number + 1)" + marker.dropFirst(digits.count)
        case .quote:
            next = marker.hasSuffix(" ") ? marker : marker + " "
        default:
            next = marker
        }
        if line.checkbox != nil { next += "[ ] " }
        return next
    }

    /// What Delete did: the new text, and the text of a style whose last marks it took off, which a mark typed right
    /// next to it styles again (see `insert`).
    struct Deletion: Equatable {
        var state: State
        var unmarked: NSRange?
    }

    /// Delete. A pair of empty marks goes as a whole. Deleting one of a style's marks takes one of the other side with
    /// it: `**bold**` becomes `*bold*`, italics, and then `bold`; the other styles lose both their marks at once.
    /// Deleting into a list marker, a checkbox, a quote or a heading's marks takes the marker off.
    static func deleteBackward(in state: State) -> State? {
        deleting(state, forward: false)?.state
    }

    /// Forward delete, the mirror image of `deleteBackward`.
    static func deleteForward(in state: State) -> State? {
        deleting(state, forward: true)?.state
    }

    static func deleting(_ state: State, forward: Bool) -> Deletion? {
        let document = Document(state.text)
        if state.selection.length > 0 { return deleteSelection(in: state, document: document).map { Deletion(state: $0) } }
        let caret = state.selection.location
        guard forward ? caret < document.text.length : caret > 0, !document.isInFence(caret) else { return nil }
        let line = document.line(at: caret)
        guard forward ? caret < NSMaxRange(line.range) : caret > line.range.location else { return nil }
        let spans = document.spans(on: line.range)
        if let pair = document.emptyPair(around: caret, spans: spans) {
            return Deletion(state: document.replacing(pair.range, with: "", caret: pair.range.location))
        }
        let index = forward ? caret : caret - 1
        // The innermost style whose marks hold the character.
        if let span = spans.last(where: { touches(index, $0) }) {
            return unmarking(span, at: index, caret: caret, in: document)
        }
        return deletingMarker(of: line, at: index, in: document).map { Deletion(state: $0) }
    }

    /// Whether the character at `index` is one of a span's marks.
    private static func touches(_ index: Int, _ span: Span) -> Bool {
        NSLocationInRange(index, span.opening) || NSLocationInRange(index, span.closing)
    }

    /// One mark of a span deleted, and one of the other side with it: bold's `**` become italics' `*`. A style with a
    /// single mark, or marks that can't be halved (`~~`, `==`), loses them both at once, and its text is what a mark
    /// typed next to it styles again.
    private static func unmarking(_ span: Span, at index: Int, caret: Int, in document: Document) -> Deletion {
        let halves = span.style == .bold
        // The mark deleted, and the outer one of the other side.
        let opening = !halves ? span.opening : NSRange(location: NSLocationInRange(index, span.opening) ? index : span.opening.location, length: 1)
        let closing = !halves ? span.closing : NSRange(location: NSLocationInRange(index, span.closing) ? index : NSMaxRange(span.closing) - 1, length: 1)
        let result = NSMutableString(string: document.text)
        result.deleteCharacters(in: closing)
        result.deleteCharacters(in: opening)
        // The caret moves back by what went in front of it.
        let moved = caret - [opening, closing].reduce(0) { $0 + max(0, min(NSMaxRange($1), caret) - $1.location) }
        let unmarked = halves ? nil : NSRange(location: span.range.location, length: span.content.length)
        return Deletion(state: State(result as String, caret: moved), unmarked: unmarked)
    }

    /// Deleting the character at `index`, inside a line's marker: the marker goes as a whole. One `#` of several
    /// is just deleted, which makes the heading one level bigger or smaller.
    private static func deletingMarker(of line: Line, at index: Int, in document: Document) -> State? {
        guard line.kind != .plain, index >= line.marker.location, index < line.contentStart else { return nil }
        if case .heading(let level) = line.kind, level > 1, document.character(index) == UInt16(UInt8(ascii: "#")) { return nil }
        let removed: NSRange
        if let box = line.checkbox, index >= box.location {
            removed = box
        } else {
            removed = NSRange(location: line.marker.location, length: line.contentStart - line.marker.location)
        }
        return document.replacing(removed, with: "", caret: removed.location)
    }

    /// Deleting a selection that holds one of a span's marks but not the whole span takes the other mark too.
    private static func deleteSelection(in state: State, document: Document) -> State? {
        let selection = state.selection
        var ranges = [selection]
        for line in document.lines(in: selection) {
            for span in document.spans(on: line.range) where !MarkdownSyntax.contains(selection, span.range) {
                let opening = NSIntersectionRange(selection, span.opening).length > 0
                let closing = NSIntersectionRange(selection, span.closing).length > 0
                if opening || closing { ranges += [span.opening, span.closing] }
            }
        }
        guard ranges.count > 1 else { return nil }
        // Merged, then deleted from the end.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        let result = NSMutableString(string: document.text)
        var caret = selection.location
        for range in merged.reversed() {
            result.deleteCharacters(in: range)
            caret -= max(0, min(NSMaxRange(range), selection.location) - range.location)
        }
        return State(result as String, caret: caret)
    }

    /// The small things typing does: "-" at the start of a line becomes a bullet with its space, a space typed
    /// after a list marker's own is left out, "- [" and "]" make a checkbox, and a closing mark typed where the same
    /// mark is already steps over it. A `*` or `_` typed at either end of italics goes on the other end too, which
    /// makes them bold, and one typed at either end of `unmarked`, the text whose marks Delete just took off, styles
    /// it again: marks come back as they went, a pair at a time.
    static func insert(_ typed: String, in state: State, unmarked: NSRange? = nil) -> State? {
        guard state.selection.length == 0, typed.utf16.count == 1 else { return nil }
        let document = Document(state.text)
        let caret = state.selection.location
        guard !document.isInFence(caret) else { return nil }
        let line = document.line(at: caret)
        let before = document.string(NSRange(location: line.range.location, length: caret - line.range.location))
        let after = document.string(NSRange(location: caret, length: NSMaxRange(line.range) - caret))
        switch typed {
        case "-":
            if before.allSatisfy({ $0 == " " || $0 == "\t" }), !after.hasPrefix(" "), !after.hasPrefix("-") {
                return document.replacing(NSRange(location: caret, length: 0), with: "- ", caret: caret + 2)
            }
            // Three dashes still make a rule.
            if line.kind == .bullet, after.isEmpty, before.hasSuffix("- "), before.dropLast(2).allSatisfy({ $0 == " " || $0 == "\t" }) {
                return document.replacing(NSRange(location: caret - 1, length: 1), with: "-", caret: caret)
            }
        case " ":
            let isMarked = line.isList || { if case .heading = line.kind { true } else { false } }()
            if isMarked, caret == line.contentStart, before.hasSuffix(" ") {
                return state
            }
        case "]":
            let pattern = #"^([ \t]*(?:[-*+]|\d{1,9}[.)]))[ \t]+\[([ xX]?)$"#
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: before, range: NSRange(location: 0, length: before.utf16.count)) else { break }
            let marker = (before as NSString).substring(with: match.range(at: 1))
            let mark = (before as NSString).substring(with: match.range(at: 2))
            let box = marker + " [" + (mark.isEmpty ? " " : mark) + "] "
            let replaced = NSRange(location: line.range.location, length: before.utf16.count + (after.hasPrefix(" ") ? 1 : 0))
            return document.replacing(replaced, with: box, caret: line.range.location + box.utf16.count)
        case "*", "_", "~", "`", "=":
            let spans = document.spans(on: line.range)
            let closes = spans.contains { $0.content.length > 0 && caret >= NSMaxRange($0.content) && caret < NSMaxRange($0.range) }
            if closes, after.hasPrefix(typed) {
                return State(state.text, caret: caret + 1)
            }
            guard typed == "*" || typed == "_" else { break }
            let italics = spans.filter { $0.style == .italic && document.string($0.opening) == typed }
            if let span = italics.last(where: { NSMaxRange($0.range) == caret }) {
                return document.applying([(NSRange(location: caret, length: 0), typed), (NSRange(location: span.range.location, length: 0), typed)], to: NSRange(location: caret, length: 0))
                    .moving(to: caret + 2)
            }
            if let span = italics.first(where: { $0.range.location == caret || NSMaxRange($0.opening) == caret }) {
                return document.applying([(NSRange(location: NSMaxRange(span.range), length: 0), typed), (NSRange(location: caret, length: 0), typed)], to: NSRange(location: caret, length: 0))
                    .moving(to: caret + 1)
            }
            if let unmarked, NSMaxRange(unmarked) <= document.text.length, caret == NSMaxRange(unmarked) || caret == unmarked.location {
                let wrapped = typed + document.string(unmarked) + typed
                return document.replacing(unmarked, with: wrapped, caret: caret == unmarked.location ? caret + 1 : caret + 2)
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Context

    /// The styles around the caret or selection, and what its line is.
    static func context(in state: State) -> Context {
        let document = Document(state.text)
        let selection = state.selection
        let line = document.line(at: selection.location)
        var context = Context(line: line.kind, isChecklist: line.checkbox != nil, isChecked: line.isChecked, canOutdent: line.isList && line.indent > 0)
        // In only where it would put the item under the one above.
        context.canIndent = line.isList && document.listItem(before: line) { $0.indent <= line.indent && $0.childIndent > line.indent } != nil
        guard !document.isInFence(selection.location) else { return context }
        let spans = document.spans(on: line.range)
        for span in spans where span.content.location <= selection.location && NSMaxRange(selection) <= NSMaxRange(span.content) {
            context.styles.insert(span.style)
        }
        if selection.length == 0, let pair = document.emptyPair(around: selection.location, spans: spans) {
            context.styles.insert(pair.style)
        }
        let string = document.text as String
        for match in MarkdownSyntax.link.matches(in: string, range: line.range) where match.range(at: 1).length == 0 {
            if NSLocationInRange(selection.location, match.range) {
                context.link = URL(string: document.string(match.range(at: 3)))
            }
        }
        if context.link == nil {
            for match in MarkdownSyntax.url.matches(in: string, range: line.range) {
                if match.range.location <= selection.location, selection.location <= NSMaxRange(match.range) {
                    context.link = URL(string: document.string(match.range))
                }
            }
        }
        return context
    }

    // MARK: - Applying

    /// The smallest replacement that turns one text into another, for a text view to make as one undoable edit.
    static func difference(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let a = old as NSString
        let b = new as NSString
        let shorter = min(a.length, b.length)
        var prefix = 0
        while prefix < shorter, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        // Never between the two halves of an emoji.
        if prefix > 0, prefix < a.length, CFStringIsSurrogateLowCharacter(a.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, a.length - suffix > prefix, CFStringIsSurrogateLowCharacter(a.character(at: a.length - suffix)) { suffix -= 1 }
        return (NSRange(location: prefix, length: a.length - prefix - suffix), b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix)))
    }

    private static func isWordCharacter(_ character: unichar?) -> Bool {
        guard let character, let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Document

    /// The text with what the rules need to know about it.
    private struct Document {
        let text: NSString
        let fences: [NSRange]

        init(_ string: String) {
            text = string as NSString
            fences = MarkdownSyntax.fences(in: text)
        }

        func line(at location: Int) -> Line {
            MarkdownSyntax.line(at: location, in: text)
        }

        func spans(on line: NSRange) -> [Span] {
            MarkdownSyntax.spans(in: text, line, fences: fences)
        }

        func string(_ range: NSRange) -> String {
            text.substring(with: range)
        }

        func character(_ index: Int) -> unichar? {
            index >= 0 && index < text.length ? text.character(at: index) : nil
        }

        /// The lines a selection touches; at a caret, its line.
        func lines(in selection: NSRange) -> [Line] {
            var lines = [line(at: selection.location)]
            while NSMaxRange(lines.last!.range) < NSMaxRange(selection) {
                lines.append(line(at: NSMaxRange(lines.last!.range) + 1))
            }
            // A selection of whole lines ends at the start of the next one, which isn't selected.
            if lines.count > 1, lines.last!.range.location == NSMaxRange(selection) { lines.removeLast() }
            return lines
        }

        /// The line before this one.
        func line(before line: Line) -> Line? {
            line.range.location > 0 ? self.line(at: line.range.location - 1) : nil
        }

        /// The nearest list item above a line that passes a test, within the same list.
        func listItem(before line: Line, where test: (Line) -> Bool) -> Line? {
            var current = line
            while let above = self.line(before: current) {
                if above.isList, test(above) { return above }
                // A list ends at a line that is neither an item nor indented under one.
                if !above.isList, above.range.length > 0, leadingWhitespace(of: above.range) == 0 { return nil }
                current = above
            }
            return nil
        }

        func leadingWhitespace(of range: NSRange) -> Int {
            var count = 0
            while count < range.length, let character = character(range.location + count), character == 32 || character == 9 { count += 1 }
            return count
        }

        func isInFence(_ location: Int) -> Bool {
            fences.contains { fence in
                guard location > fence.location else { return false }
                if location < NSMaxRange(fence) { return true }
                // A fence that isn't closed runs to the end of the text.
                guard location == NSMaxRange(fence), location == text.length else { return false }
                let last = MarkdownSyntax.lineRange(at: location, in: text)
                return last.location == fence.location || !(string(last).hasPrefix("```") || string(last).hasPrefix("~~~"))
            }
        }

        /// A range without the white space around it, or nil if there is nothing else.
        func trimmed(_ range: NSRange) -> NSRange? {
            var start = range.location
            var end = NSMaxRange(range)
            func isSpace(_ index: Int) -> Bool {
                guard let character = character(index), let scalar = Unicode.Scalar(character) else { return false }
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            while start < end, isSpace(start) { start += 1 }
            while end > start, isSpace(end - 1) { end -= 1 }
            return end > start ? NSRange(location: start, length: end - start) : nil
        }

        /// The word the caret is inside of, with letters on both sides of it.
        func word(around caret: Int) -> NSRange? {
            guard isWordCharacter(character(caret - 1)), isWordCharacter(character(caret)) else { return nil }
            var start = caret - 1
            var end = caret + 1
            while isWordCharacter(character(start - 1)) { start -= 1 }
            while isWordCharacter(character(end)) { end += 1 }
            return NSRange(location: start, length: end - start)
        }

        /// The marks of a style with nothing in it around the caret, as a press of Bold leaves them: `**|**`.
        func emptyPair(around caret: Int, spans: [Span]) -> (style: Style, range: NSRange)? {
            let candidates: [(Style, String)] = [(.bold, "**"), (.bold, "__"), (.strikethrough, "~~"), (.highlight, "=="), (.italic, "*"), (.italic, "_"), (.code, "`")]
            for (style, mark) in candidates {
                let length = mark.utf16.count
                guard caret >= length, caret + length <= text.length else { continue }
                let range = NSRange(location: caret - length, length: 2 * length)
                guard string(range) == mark + mark else { continue }
                // Not the marks of two spans that meet: `**a**|**b**`.
                guard !spans.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                return (style, range)
            }
            return nil
        }

        func replacing(_ range: NSRange, with replacement: String, caret: Int) -> State {
            State(text.replacingCharacters(in: range, with: replacement), caret: caret)
        }

        /// Several replacements, none overlapping, with the selection moved along.
        func applying(_ edits: [(range: NSRange, text: String)], to selection: NSRange) -> State {
            let result = NSMutableString(string: text)
            var start = selection.location
            var end = NSMaxRange(selection)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                result.replaceCharacters(in: edit.range, with: edit.text)
                let delta = edit.text.utf16.count - edit.range.length
                func move(_ position: Int) -> Int {
                    if position >= NSMaxRange(edit.range), position > edit.range.location || edit.range.length == 0 {
                        return position + delta
                    }
                    // Inside what was replaced: to the end of the new text, where the line's own text starts.
                    if position >= edit.range.location { return edit.range.location + edit.text.utf16.count }
                    return position
                }
                start = move(start)
                end = move(end)
            }
            return State(result as String, selection: NSRange(location: start, length: max(0, end - start)))
        }
    }
}
