import Foundation

/// To-dos in no note (`LooseTodos`): added in To-dos, changed there as any other, and moved into a note from there.
extension Workspace {
    /// Whether a file is the one with the to-dos in no note.
    func isLoose(_ url: URL) -> Bool {
        looseTodos.url.map { FileNode.samePath($0, url) } ?? false
    }

    // MARK: - Adding

    /// Adds a to-do in no note after the others, due on `day` (nil: without a date), and shows it in To-dos at once,
    /// without words yet, to type them in. Undo comes once it has them (`keepNewTodo`). Nil while the to-dos in no note
    /// are still being looked up.
    func addTodo(due day: Date?) -> TodoList.Item? {
        guard let url = looseTodos.url else {
            beep()
            return nil
        }
        let source = "- [ ]" + (day.map { " " + TodoDue($0, time: false).markdown } ?? "")
        let snapshot = looseTodos.snapshot
        // Where it will be, as far as is known here: the file may have changed since it was read, and others just added
        // may not have been read yet.
        let after = todos.items.filter(\.isLoose).map { $0.todo.line + $0.todo.lines.count + 1 }.max() ?? 0
        let line = max(LooseTodos.adding([source], to: snapshot?.text ?? "").line, after)
        guard let todo = TodoList.todo([source], line: line) else { return nil }
        let item = TodoList.Item(url: url, note: "", modified: snapshot?.modified, todo: todo, isLoose: true)
        todos.add(item)
        let reference = item.reference
        // One added before it said the same before it was typed in: what that one's line became isn't this one's.
        todoRewrites[Self.rewriteKey(reference)] = nil
        writeTodoChange(in: url, { LooseTodos.append([source], to: url) == nil ? .failed : .written }, failed: { [weak self] in
            self?.todos.unpatch(reference)
        }, whenWritten: nil)
        return item
    }

    /// A to-do just added was given words: Undo takes it away as it is now, with what was typed in it.
    func keepNewTodo(_ todo: TodoReference) {
        keepTodoChangeForUndo("New To-do") { [weak self] in self?.deleteTodo(todo) }
    }

    /// A to-do just added that was left without words goes again, as if it had never been added.
    func dropNewTodo(_ todo: TodoReference) {
        deleteTodo(todo, undoable: false)
    }

    // MARK: - Moving into a note

    /// Moves a to-do in no note, with the lines under it, into a note: after the last to-do of its last checklist, or
    /// at its end (`Todos.inserting`), in the editor that shows the note or else in its file. To-dos shows it under
    /// the note's name at once, and one Undo puts it back among those in no note.
    @discardableResult
    func moveTodo(_ todo: TodoReference, toNote note: URL) -> Task<Void, Never>? {
        let todo = current(todo)
        guard isLoose(todo.url), !isLoose(note), let item = looseItem(todo) else {
            beep()
            return nil
        }
        let note = note.standardizedFileURL
        let lines = [item.todo.source] + item.todo.lines.map(\.source)
        // Where it goes, as far as is known here, to show it there at once.
        let known = editorShowing(note)?.text ?? index.entry(for: note)?.text ?? ""
        let estimate = Todos.inserting(lines, in: known as NSString, document: MarkdownParser.parse(known as NSString))
        var moved = item
        moved.url = note
        moved.note = SearchSection.displayName(note)
        moved.modified = index.entry(for: note)?.modified
        moved.isLoose = false
        moved.todo = TodoList.todo([estimate.source] + lines.dropFirst(), line: estimate.line) ?? item.todo
        todos.patch(todo, to: nil, under: nil)
        todos.add(moved)

        let removed = TodoRemoval.Kept()
        let placed = TodoPlacement()
        let undo = keepTodoChangeForUndo("Move to Note") { [weak self] in
            self?.moveBack(from: note, placed: placed, removed: removed, to: todo.url)
        }
        func failed() {
            undo.forget()
            todos.unpatch(todo)
            todos.unpatch(moved.reference)
        }
        return writeTodoChange(in: todo.url, {
            Self.write(todo) { text, document, index in
                guard let deleting = Todos.deleting(in: text, document: document, line: index) else { return nil }
                removed.set(deleting.removal)
                return (deleting.range, "")
            }.outcome
        }, failed: failed, whenWritten: { [weak self] in
            guard let self, let removal = removed.value else { return }
            guard await insert(Self.lines(of: removal), into: note, placed: placed) else {
                // The note is gone, or can't be written: the to-do goes back among those in no note.
                failed()
                await Task.detached(priority: .userInitiated) {
                    _ = Self.write(todo.url) { text, document in Todos.restoring(removal, in: text, document: document) }
                }.value
                looseTodos.read()
                beep()
                return
            }
        })
    }

    /// The to-do in no note To-dos lists for a reference: the nearest one with its words.
    private func looseItem(_ todo: TodoReference) -> TodoList.Item? {
        todos.items.filter { $0.isLoose && $0.todo.source == todo.source }.min { abs($0.todo.line - todo.line) < abs($1.todo.line - todo.line) }
    }

    /// The lines deleting a to-do took out, without the line endings and blank lines around them.
    nonisolated private static func lines(of removal: TodoRemoval) -> [String] {
        var lines = removal.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Puts a to-do's lines into a note's checklist, in the editor that shows it or else in its file, and says where it
    /// went. False when the note is gone or couldn't be written. Inside a change to a to-do's file being written.
    private func insert(_ lines: [String], into note: URL, placed: TodoPlacement) async -> Bool {
        if let editor = editorShowing(note) {
            guard !editor.isWaitingForText else { return false }
            let done = editor.editTodoLines(line: 0, actionName: "Move to Note") { text, document, _ in
                let inserting = Todos.inserting(lines, in: text, document: document)
                placed.set(line: inserting.line, source: inserting.source)
                return (inserting.range, inserting.replacement)
            }
            if done { saveNote(showing: note) }
            return done
        }
        let written = await Task.detached(priority: .userInitiated) {
            Self.write(note) { text, document in
                let inserting = Todos.inserting(lines, in: text, document: document)
                placed.set(line: inserting.line, source: inserting.source)
                return (inserting.range, inserting.replacement)
            }
        }.value
        index.refresh(folders: [note.deletingLastPathComponent()], locations: locations)
        return written == .written
    }

    /// Undo of moving a to-do into a note: it goes from the note, with the lines under it, and back among those in no
    /// note where it was. Redo moves it again.
    private func moveBack(from note: URL, placed: TodoPlacement, removed: TodoRemoval.Kept, to loose: URL) {
        // Known once the move was written, which Undo waits for.
        guard let removal = removed.value, let place = placed.value else { return beep() }
        let inNote = TodoReference(url: note, line: place.line, source: place.source)
        deleteTodo(inNote, undoable: false)
        let lines = Self.lines(of: removal)
        let back = TodoReference(url: loose, line: removal.line, source: lines.first ?? "")
        if let todo = TodoList.todo(lines, line: removal.line) {
            todos.add(TodoList.Item(url: loose, note: "", modified: looseTodos.snapshot?.modified, todo: todo, isLoose: true))
        }
        let redo = keepTodoChangeForUndo("Move to Note") { [weak self] in self?.moveTodo(back, toNote: note) }
        writeTodoChange(in: loose, {
            Self.write(loose) { text, document in Todos.restoring(removal, in: text, document: document) }
        }, failed: { [weak self] in
            redo.forget()
            self?.todos.unpatch(back)
        }, whenWritten: nil)
    }
}

/// Where a to-do moved into a note went, known once that is written: in a file off the main thread.
final class TodoPlacement: @unchecked Sendable {
    private let lock = NSLock()
    private var placed: (line: Int, source: String)?

    var value: (line: Int, source: String)? { lock.withLock { placed } }
    func set(line: Int, source: String) { lock.withLock { placed = (line, source) } }
}
