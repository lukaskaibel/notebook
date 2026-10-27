import SwiftUI

/// Where the keyboard is in a to-do being edited: its words, or one of the lines under it.
enum TodoFocus: Hashable {
    case title
    case line(UUID)
}

/// A to-do being edited in To-dos, as Reminders edits a reminder in place: its words, and the lines indented under it,
/// which are its sub-to-dos, points and notes, with a line for notes waiting under its words when it has none. What you
/// type is written to the note a moment after you stop, when you leave the to-do, and before its date or place changes;
/// it is the note's Markdown, so the note says the same.
@MainActor
@Observable
final class TodoEditing {
    /// A line under the to-do, as it is being edited.
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var kind: TodoLine.Kind
        /// The spaces or tabs it starts with.
        var indent: String
        /// What comes after the indent and before the words: `- [ ] `, `- `, `1. `, `> `, or nothing.
        var marker: String
        var words: String
        /// How deep it is under the to-do, from 1.
        var depth: Int
        var selection: TextSelection?
        /// Empty in the note when editing began: kept so. Any other line left empty goes when editing ends.
        var wasEmpty = false

        /// Made while editing and still without words: written once it has some, and gone if it never gets any.
        var isNewAndEmpty: Bool { kind == .text && !wasEmpty && words.trimmingCharacters(in: .whitespaces).isEmpty }

        static func == (a: Line, b: Line) -> Bool {
            a.id == b.id && a.kind == b.kind && a.indent == b.indent && a.marker == b.marker && a.words == b.words && a.depth == b.depth
        }

        /// As it is written in the note: a line not changed character for character, as its parts are cut from it.
        var markdown: String { indent + marker + words }

        /// Words, code and the like are kept as they are; the rest is typed in.
        var isEditable: Bool { kind != .other && kind != .blank }
    }

    let workspace: Workspace
    /// Who it is, while its line changes under it.
    let id = UUID()
    /// The row it was edited from in To-dos: the row keeps being that one while its line changes, and while it closes.
    let rowID: String
    /// Its buttons and the line for notes show: they come in a moment after editing begins, and go before it ends.
    var isExpanded = false
    /// The to-do as it was last written, and its lines as they were then, the to-do's first.
    private(set) var reference: TodoReference
    private var written: [String]
    var title: String
    var titleSelection: TextSelection?
    var lines: [Line]
    /// Where the keyboard should be: put back when the row is made again, after its group changed.
    var focus: TodoFocus? = .title
    /// Remind Me is open from its buttons: leaving the words doesn't end the editing then.
    var isChoosing = false
    /// A to-do just added in To-dos, in no note: the group it was added to, for Return to add the next one there. What
    /// is typed in it is written without Undo of its own: once it is done, Undo takes it away as it is.
    @ObservationIgnored var added: TodoSection.Kind?
    /// It had the keyboard: until then, its row may still be on its way (the next one after Return), and the keyboard
    /// leaving the row before it isn't the end of this one.
    @ObservationIgnored var hasHadKeyboard = false

    /// Without words, notes or lines under it: a to-do just added and left so goes again.
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && lines.allSatisfy { !$0.isEditable || $0.words.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What a popover can change of it: its day, its time, its place.
    enum Pick: Identifiable {
        case day, time, place
        var id: Self { self }
    }

    /// The popover open for its day, time or place (iPhone and iPad; the Mac's dropdowns keep their own).
    var picking: Pick?

    /// Opens the popover for its day, time or place, with what was typed written first.
    func pick(_ kind: Pick) {
        isChoosing = true
        commit()
        picking = kind
    }
    /// Asks To-dos to put the keyboard where `focus` says.
    private(set) var focusRequest = 0
    /// The caret a field gets once it has the keyboard, in UTF-16 units: a field selects all its words as it gets it.
    @ObservationIgnored private var caretRequest: (field: TodoFocus, caret: Int)?
    /// Ended: written, and no longer shown.
    private(set) var isEnded = false
    @ObservationIgnored private var pending: DispatchWorkItem?

    init(workspace: Workspace, item: TodoList.Item) {
        self.workspace = workspace
        rowID = item.id
        reference = item.reference
        written = [item.todo.source] + item.todo.lines.map(\.source)
        title = Todos.parts(of: item.todo.source)?.words ?? item.todo.text
        lines = item.todo.lines.map { line in
            Line(kind: line.kind, indent: line.indent, marker: String(line.prefix.dropFirst(line.indent.count)), words: line.words,
                 depth: line.depth, wasEmpty: line.words.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // Notes, as Reminders has them under a reminder's title: a line to type them in, right under the words.
        if !lines.contains(where: { $0.kind == .text }) {
            lines.insert(Line(kind: .text, indent: childIndent, marker: "", words: "", depth: 1), at: 0)
        }
    }

    // MARK: - Which row

    /// Whether a row of To-dos is the to-do being edited: the same line, or what it became.
    func isEditing(_ item: TodoList.Item) -> Bool {
        !isEnded && shows(item)
    }

    /// Whether a row of To-dos is this to-do, edited or closing: its line as last written here, what Notebook made of
    /// it since (a date set from the buttons), or a row still showing the line from before the words were written.
    func shows(_ item: TodoList.Item) -> Bool {
        guard FileNode.samePath(item.url, reference.url) else { return false }
        return item.todo.source == reference.source || item.todo.source == current.source
            || workspace.current(item.reference).source == reference.source
    }

    /// The to-do's line as Notebook last changed it: a date set from the buttons changes it apart from the words.
    var current: TodoReference { workspace.current(reference) }

    /// Its date and place, as its line says now.
    var schedule: (due: TodoDue?, place: TodoPlace?) {
        guard let parsed = Todos.line(current.source) else { return (nil, nil) }
        return (parsed.due, parsed.place)
    }

    // MARK: - The keyboard

    /// Puts the keyboard in a field, the caret this many UTF-16 units into its words, or at their end.
    func move(to field: TodoFocus, caret: Int? = nil) {
        caretRequest = (field, caret ?? words(of: field).utf16.count)
        focus = field
        focusRequest += 1
    }

    /// The keyboard back where it was, the caret too: after a menu or Remind Me, or with the row made again.
    func refocus() {
        guard let field = focus else { return }
        if caretRequest == nil { caretRequest = (field, caretOffset(in: field)) }
        focusRequest += 1
    }

    /// The keyboard is in a field: the caret goes where it was asked.
    func placeCaret(focused: TodoFocus?) {
        guard let request = caretRequest, request.field == focused else { return }
        caretRequest = nil
        setCaret(request.caret, in: request.field)
    }

    /// The keyboard went to a field: a caret asked for in another goes with it.
    func focusMoved(to field: TodoFocus) {
        if let request = caretRequest, request.field != field { caretRequest = nil }
    }

    /// The caret a field shows: the one asked for, until it is in place.
    func selection(of field: TodoFocus) -> TextSelection? {
        if let request = caretRequest, request.field == field {
            let words = words(of: field)
            return TextSelection(insertionPoint: String.Index(utf16Offset: min(request.caret, words.utf16.count), in: words))
        }
        return switch field {
        case .title: titleSelection
        case .line(let id): lines.first { $0.id == id }?.selection
        }
    }

    /// A field moved its caret. While a caret is asked for, the field's own, all its words selected as it gets the
    /// keyboard, gives way to it.
    func fieldMoved(_ selection: TextSelection?, in field: TodoFocus) {
        // A dropdown has the keyboard: the field letting go of it moves its caret to the start, which isn't where the
        // caret goes back to.
        guard !isChoosing else { return }
        if let request = caretRequest, request.field == field {
            DispatchQueue.main.async { [weak self] in self?.placeCaret(focused: field) }
            return
        }
        switch field {
        case .title: titleSelection = selection
        case .line(let id): if let index = lines.firstIndex(where: { $0.id == id }) { lines[index].selection = selection }
        }
    }

    private func words(of field: TodoFocus) -> String {
        switch field {
        case .title: title
        case .line(let id): lines.first { $0.id == id }?.words ?? ""
        }
    }

    private func caretOffset(in field: TodoFocus) -> Int {
        let words = words(of: field)
        let selection = switch field {
        case .title: titleSelection
        case .line(let id): lines.first { $0.id == id }?.selection
        }
        return words.utf16.distance(from: words.startIndex, to: Self.caret(in: words, selection))
    }

    private func setCaret(_ offset: Int, in field: TodoFocus) {
        let words = words(of: field)
        let caret = TextSelection(insertionPoint: String.Index(utf16Offset: min(offset, words.utf16.count), in: words))
        switch field {
        case .title: titleSelection = caret
        case .line(let id): if let index = lines.firstIndex(where: { $0.id == id }) { lines[index].selection = caret }
        }
    }

    // MARK: - Writing

    /// Something was typed: written once typing stops for a moment.
    func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes what changed, now; with `now`, as the app quits, before it returns.
    func commit(now: Bool = false) {
        pending?.cancel()
        pending = nil
        // Blank lines at the end belong to what comes after the to-do.
        while let last = lines.last, last.kind == .blank { lines.removeLast() }
        let current = current
        var before = written
        before[0] = current.source
        // A line for words that has none yet isn't written: a line of spaces in the note would be nothing to read.
        let after = [Todos.replacingWords(in: current.source, with: title)] + lines.filter { !$0.isNewAndEmpty }.map(\.markdown)
        guard after != before else { return }
        workspace.changeTodoLines(current, from: before, to: after, actionName: "Edit To-do", now: now, undoable: added == nil)
        reference = TodoReference(url: current.url, line: current.line, source: after[0])
        written = after
    }

    /// Done editing: what is left is written, without the lines made or emptied and left so.
    func end() {
        guard !isEnded else { return }
        lines.removeAll { $0.isEditable && !$0.wasEmpty && $0.words.trimmingCharacters(in: .whitespaces).isEmpty }
        commit()
        isEnded = true
        focus = nil
    }

    /// Writes what was typed before something else changes the to-do: a date, a place, a tick.
    func beforeChanging() -> TodoReference {
        commit()
        return current
    }

    // MARK: - Lines

    /// The indent a line one level under the to-do starts with: as the lines under it are indented, or as far as the
    /// to-do's words start.
    private var childIndent: String {
        if let first = lines.first(where: { $0.depth == 1 && $0.isEditable }) { return first.indent }
        let indent = String(reference.source.prefix { $0 == " " || $0 == "\t" })
        return indent + unit(after: reference.source)
    }

    /// How much further a line under another goes in: a tab where the note uses tabs, else as far as the other's
    /// words start after its marker.
    private func unit(after source: String) -> String {
        if (written + lines.map(\.indent)).contains(where: { $0.hasPrefix("\t") || $0.contains("\n\t") }) { return "\t" }
        let line = source.drop { $0 == " " || $0 == "\t" }
        let marker = line.prefix { !$0.isWhitespace }
        return String(repeating: " ", count: max(2, marker.count + 1))
    }

    /// The marker a new to-do under this one starts with: its own bullet, with a box.
    private var todoMarker: String {
        let line = reference.source.drop { $0 == " " || $0 == "\t" }
        let bullet = line.first.map { "-*+".contains($0) ? String($0) : "-" } ?? "-"
        return bullet + " [ ] "
    }

    private func marker(for kind: TodoLine.Kind, like line: Line? = nil) -> String {
        switch kind {
        case .todo:
            if let line, line.isTodo, let box = line.marker.firstIndex(of: "[") { return String(line.marker[..<box]) + "[ ] " }
            return todoMarker
        case .bullet:
            if let line, line.kind == .bullet { return line.marker }
            return String(todoMarker.prefix(2))
        case .ordered(let number):
            // The next number, with the same dot or bracket.
            let digits = number.prefix { $0.isNumber }
            return "\((Int(digits) ?? 0) + 1)\(number.dropFirst(digits.count)) "
        default:
            return ""
        }
    }

    /// A new line under the to-do's words, before the others but after the line for notes waiting there: a sub-to-do,
    /// or the same as the first line under it.
    @discardableResult
    func addLineUnderTitle() -> UUID {
        let waiting = lines.first?.isNewAndEmpty == true ? 1 : 0
        let first = lines.dropFirst(waiting).first { $0.depth == 1 && $0.isEditable }
        let kind: TodoLine.Kind = first?.kind == .bullet ? .bullet : .todo(.open)
        let line = Line(kind: kind, indent: childIndent, marker: marker(for: kind, like: first), words: "", depth: 1)
        lines.insert(line, at: waiting)
        move(to: .line(line.id))
        changed()
        return line.id
    }

    /// A new sub-to-do after the last line.
    func addTodo() {
        let line = Line(kind: .todo(.open), indent: childIndent, marker: todoMarker, words: "", depth: 1)
        lines.append(line)
        move(to: .line(line.id))
        changed()
    }

    /// Return in a line: the words after the caret go to a new line of the same kind after it. On a line without words
    /// it goes, and so does the editing, as when you leave a list in a note.
    /// - Returns: false when the editing ended.
    func split(_ id: UUID) -> Bool {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return true }
        let line = lines[index]
        if line.words.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: index)
            end()
            return false
        }
        let caret = Self.caret(in: line.words, line.selection)
        let nextMarker = marker(for: line.kind, like: line)
        let kind: TodoLine.Kind = switch line.kind {
        case .todo: .todo(.open)
        case .ordered: .ordered(nextMarker.trimmingCharacters(in: .whitespaces))
        default: line.kind
        }
        let next = Line(kind: kind, indent: line.indent, marker: nextMarker, words: String(line.words[caret...]), depth: line.depth)
        lines[index].words = String(line.words[..<caret])
        lines.insert(next, at: index + 1)
        move(to: .line(next.id), caret: 0)
        changed()
        return true
    }

    /// Delete at the start of a line: a sub-to-do or a point becomes words; words join the line above.
    func deleteBackward(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let line = lines[index]
        if line.kind != .text {
            lines[index].kind = .text
            lines[index].marker = ""
            setCaret(0, in: .line(id))
            changed()
            return
        }
        // Into the editable line above, or the to-do's words: the keyboard goes there first.
        if let above = lines[..<index].lastIndex(where: { $0.isEditable }) {
            let joint = lines[above].words.utf16.count
            lines[above].words += line.words
            move(to: .line(lines[above].id), caret: joint)
        } else {
            let joint = title.utf16.count
            title += line.words
            move(to: .title, caret: joint)
        }
        lines.removeAll { $0.id == id }
        changed()
    }

    /// Tab: a line one level further in, under the line above. Not further than one level below that line.
    func indent(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let depth = lines[index].depth
        guard let above = lines[..<index].last(where: { $0.kind != .blank }), above.depth >= depth else { return }
        if above.depth == depth {
            lines[index].indent = above.indent + unit(after: above.markdown)
        } else {
            lines[index].indent = lines[..<index].last { $0.depth == depth + 1 }?.indent ?? above.indent
        }
        lines[index].depth += 1
        changed()
    }

    /// Shift-Tab: a line one level out, but still under the to-do.
    func outdent(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }), lines[index].depth > 1 else { return }
        let depth = lines[index].depth - 1
        lines[index].indent = lines[..<index].last { $0.depth == depth && $0.isEditable }?.indent ?? childIndent
        lines[index].depth = depth
        changed()
    }

    /// Words typed: words that start with `[ ] ` become a sub-to-do and with `- ` a point, as they would in a note,
    /// and a point that starts with `[ ] ` a sub-to-do.
    func typed(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let line = lines[index]
        var starts: [(String, TodoLine.Kind, String)] = []
        switch line.kind {
        case .text:
            starts = [("- [ ] ", .todo(.open), todoMarker), ("* [ ] ", .todo(.open), "* [ ] "), ("[ ] ", .todo(.open), todoMarker),
                      ("[] ", .todo(.open), todoMarker), ("- ", .bullet, "- "), ("* ", .bullet, "* "), ("+ ", .bullet, "+ ")]
        case .bullet:
            starts = [("[ ] ", .todo(.open), line.marker + "[ ] "), ("[] ", .todo(.open), line.marker + "[ ] ")]
        default:
            break
        }
        if let (start, kind, marker) = starts.first(where: { line.words.hasPrefix($0.0) }) {
            lines[index].kind = kind
            lines[index].marker = marker
            lines[index].words = String(line.words.dropFirst(start.count))
            setCaret(0, in: .line(id))
        }
        changed()
    }

    /// Ticks a sub-to-do or unticks it: done is written at once.
    func toggle(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }), case .todo(let mark) = lines[index].kind,
              let box = lines[index].marker.firstIndex(of: "[") else { return }
        let new: TaskMark = mark.isClosed ? .open : .done
        lines[index].kind = .todo(new)
        lines[index].marker = String(lines[index].marker[..<box]) + "[" + String(new.character) + "] "
        commit()
    }

    /// The line before or after one that can take the keyboard: ↑ and ↓ at either end of a line.
    func neighbour(of focus: TodoFocus, by step: Int) -> TodoFocus? {
        let editable = lines.filter(\.isEditable)
        let index: Int
        switch focus {
        case .title: index = -1
        case .line(let id): index = editable.firstIndex { $0.id == id } ?? -1
        }
        let next = index + step
        if next == -1 { return .title }
        return editable.indices.contains(next) ? .line(editable[next].id) : nil
    }

    /// Where the caret is in some words: the start of the selection, or the end. A text field hands its caret over as an
    /// index of its own copy of the words, often in UTF-16 where ours are in UTF-8, so it is read as a count of UTF-16
    /// units; one that may not fall in the words is the end.
    static func caret(in words: String, _ selection: TextSelection?) -> String.Index {
        guard let selection, case .selection(let range) = selection.indices,
              (range.lowerBound as EncodedOffset).encodedOffset <= words.utf16.count else { return words.endIndex }
        return String.Index(utf16Offset: range.lowerBound.utf16Offset(in: words), in: words)
    }
}

/// An index's offset in the encoding of the string it is from: in UTF-8 no smaller than in UTF-16, so one no larger
/// than a string's UTF-16 count falls in it whichever it is.
private protocol EncodedOffset {
    var encodedOffset: Int { get }
}

extension String.Index: EncodedOffset {}

extension TodoEditing.Line {
    var isTodo: Bool { if case .todo = kind { true } else { false } }
}
