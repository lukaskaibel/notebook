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
    /// at its end (`Todos.inserting`). The note's file is written, which a note open in an editor takes in as it takes
    /// a change from another app, so the move has one Undo, To-dos'. It goes into the note first and only then out of
    /// those in no note: stopped halfway (the app quits, the note can't be written) it is in one or both, never neither.
    /// To-dos shows it under the note's name at once.
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

        let move = TodoMove(from: todo)
        let undo = keepTodoChangeForUndo("Move to Note") { [weak self] in self?.moveBack(move, from: note) }
        func failed() {
            undo.forget()
            todos.unpatch(todo)
            todos.unpatch(moved.reference)
            beep()
        }
        return chainTodoWrite { [weak self] in
            guard let self else { return }
            // Its lines as they are in the file now.
            guard let lines = await Task.detached(priority: .userInitiated, operation: { Self.lines(of: todo) }).value else {
                looseTodos.read()
                return failed()
            }
            let inserted = await Task.detached(priority: .userInitiated) {
                Self.write(note) { text, document in
                    let inserting = Todos.inserting(lines, in: text, document: document)
                    move.placed(line: inserting.line, lines: [inserting.source] + lines.dropFirst())
                    return (inserting.range, inserting.replacement)
                }
            }.value
            index.refresh(folders: [note.deletingLastPathComponent()], locations: locations)
            // The note is gone, or can't be written: the to-do stays where it was.
            guard inserted == .written else { return failed() }
            #if DEBUG
            await betweenMoveSteps?()
            #endif
            let removed = await Task.detached(priority: .userInitiated) {
                Self.write(todo) { text, document, index in
                    // Changed meanwhile, on another device say: it stays as it is now, in both, rather than lose that.
                    guard Self.lines(at: index, in: document, string: text) == lines,
                          let deleting = Todos.deleting(in: text, document: document, line: index) else { return nil }
                    move.removed(deleting.removal)
                    return (deleting.range, "")
                }.outcome
            }.value
            looseTodos.read()
            // Not written, or changed or gone meanwhile: it is in the note, and still among those in no note.
            if removed != .written {
                move.removed(nil)
                todos.unpatch(todo)
            }
        }
    }

    /// The to-do in no note To-dos lists for a reference: the nearest one with its words.
    private func looseItem(_ todo: TodoReference) -> TodoList.Item? {
        todos.items.filter { $0.isLoose && $0.todo.source == todo.source }.min { abs($0.todo.line - todo.line) < abs($1.todo.line - todo.line) }
    }

    /// A to-do's line and the lines under it as its file has them now, found by what it said; nil when it is gone.
    nonisolated private static func lines(of todo: TodoReference) -> [String]? {
        var lines: [String]?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: todo.url, options: [], error: &error) { url in
            guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return }
            let string = text as NSString
            let document = MarkdownParser.parse(string)
            guard let index = Todos.find(todo.source, near: todo.line, in: document, string: string) else { return }
            lines = Self.lines(at: index, in: document, string: string)
        }
        return lines
    }

    /// The lines of the to-do on line `index`: its own and those under it.
    nonisolated private static func lines(at index: Int, in document: MarkdownDocument, string: NSString) -> [String] {
        let under = Todos.noteLines(under: index, in: document, string: string)
        return ([index] + Array(under)).map { string.substring(with: document.lines[$0].range) }
    }

    /// The lines deleting a to-do took out, without the line endings and blank lines around them.
    nonisolated private static func lines(of removal: TodoRemoval) -> [String] {
        var lines = removal.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Undo of moving a to-do into a note, once the move is written, which this waits for: it goes back among those in
    /// no note where it was, and then out of the note, with the lines under it. Redo moves it again.
    private func moveBack(_ move: TodoMove, from note: URL) {
        let loose = move.todo.url
        // Registered now, as Undo runs: what it moves is known by the time Redo can be chosen.
        let redo = keepTodoChangeForUndo("Move to Note") { [weak self] in
            let back = move.removal.map { TodoReference(url: loose, line: $0.line, source: Self.lines(of: $0).first ?? "") } ?? move.todo
            self?.moveTodo(back, toNote: note)
        }
        chainTodoWrite { [weak self] in
            guard let self else { return }
            guard let place = move.placement else {
                redo.forget()
                return beep()
            }
            let inNote = TodoReference(url: note, line: place.line, source: place.lines.first ?? "")
            if let removal = move.removal {
                let lines = Self.lines(of: removal)
                if let todo = TodoList.todo(lines, line: removal.line) {
                    todos.add(TodoList.Item(url: loose, note: "", modified: nil, todo: todo, isLoose: true))
                }
                todos.patch(inNote, to: nil, under: nil)
                let restored = await Task.detached(priority: .userInitiated) {
                    Self.write(loose) { text, document in Todos.restoring(removal, in: text, document: document) }
                }.value
                looseTodos.read()
                // It can't go back now: it stays in the note.
                guard restored == .written else {
                    redo.forget()
                    todos.unpatch(inNote)
                    return beep()
                }
            } else {
                // It never left those in no note: only the note has it twice.
                todos.patch(inNote, to: nil, under: nil)
            }
            let taken = await Task.detached(priority: .userInitiated) {
                Self.write(inNote) { text, document, index in
                    // Only as it went in: with lines typed under it since, it stays, and so do they.
                    guard Self.lines(at: index, in: document, string: text) == place.lines else { return nil }
                    return Todos.deleting(in: text, document: document, line: index).map { ($0.range, "") }
                }.outcome
            }.value
            index.refresh(folders: [note.deletingLastPathComponent()], locations: locations)
            // Changed in the note meanwhile: it stays there as it is now, and is among those in no note again too.
            if taken != .written { todos.unpatch(inNote) }
        }
    }
}

/// A to-do being moved into a note: where it was among those in no note, and once written, where it went in the note
/// and what taking it out of those in no note took. Written off the main thread.
final class TodoMove: @unchecked Sendable {
    let todo: TodoReference
    private let lock = NSLock()
    private var place: (line: Int, lines: [String])?
    private var taken: TodoRemoval?

    init(from todo: TodoReference) {
        self.todo = todo
    }

    /// Where it went in the note, and the lines it went in as.
    var placement: (line: Int, lines: [String])? { lock.withLock { place } }
    var removal: TodoRemoval? { lock.withLock { taken } }
    func placed(line: Int, lines: [String]) { lock.withLock { place = (line, lines) } }
    func removed(_ removal: TodoRemoval?) { lock.withLock { taken = removal } }
}
