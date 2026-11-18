import Foundation

/// To-dos limited to a folder and the folders in it (`todosFolder`), from Show To-dos in a folder's menu. It is the same
/// list with fewer rows: the count on its tile, the notifications and the widgets go on being about every to-do. A to-do
/// added there goes into a note called To-dos in the folder, made the first time, so that it is in the list it was added
/// to; in no note, as To-dos adds them otherwise, it would be in no folder.
extension Workspace {
    /// What To-dos is called where the title of its page doesn't show: the toolbar once that has scrolled away, the window.
    var todosTitle: String {
        todosFolder.map { "To-dos in \(folderName($0))" } ?? "To-dos"
    }

    /// The folder To-dos is limited to was deleted, moved somewhere else or hidden: it lists every to-do again. Search
    /// says when something changed; whether the folder is still there is asked off the main thread.
    func checkTodosFolder() {
        guard showsTodos, let folder = todosFolder else { return }
        guard location(containing: folder) != nil, !SearchIndex.isHidden(folder.path, in: index.hiddenPaths) else { return stopLimitingTodos() }
        Task { [weak self] in
            let isThere = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: folder.path) }.value
            if !isThere, let self, showsTodos, todosFolder == folder { stopLimitingTodos() }
        }
    }

    // MARK: - Adding

    /// The note the to-dos added to a folder's list go in.
    func folderTodosNote(in folder: URL) -> URL {
        folder.appendingPathComponent(LooseTodos.fileName, isDirectory: false).standardizedFileURL
    }

    /// Adds a to-do to a folder's note, after its last checklist's to-dos, due on `day` (nil: without a date), and shows
    /// it in To-dos at once, without words yet, to type them in. The note is made if it isn't there; its file is written
    /// off the main thread, or the change is made in the window it is open in.
    func addTodo(due day: Date?, in folder: URL) -> TodoList.Item? {
        let note = folderTodosNote(in: folder)
        let source = "- [ ]" + (day.map { " " + TodoDue($0, time: false).markdown } ?? "")
        let editor = editorShowing(note)
        let entry = index.entry(for: note)
        // Where it will be, as far as is known here: others just added may not have been read yet.
        let known = (editor?.text ?? entry?.text ?? "") as NSString
        let place = Todos.inserting([source], in: known, document: MarkdownParser.parse(known))
        let after = todos.items.filter { FileNode.samePath($0.url, note) }.map { $0.todo.line + $0.todo.lines.count + 1 }.max() ?? 0
        guard let todo = TodoList.todo([place.source], line: max(place.line, after)) else { return nil }
        let item = TodoList.Item(url: note, note: SearchSection.displayName(note), modified: entry?.modified, todo: todo)
        if let editor {
            guard editor.editTodoLines(line: 0, actionName: "New To-do", edit: { text, document, _ in
                let inserting = Todos.inserting([source], in: text, document: document)
                return (inserting.range, inserting.replacement)
            }) else {
                beep()
                return nil
            }
            saveNote(showing: note)
        }
        todos.add(item)
        // One added before it said the same before it was typed in: what that one's line became isn't this one's.
        todoRewrites[Self.rewriteKey(item.reference)] = nil
        guard editor == nil else { return item }
        let reference = item.reference
        writeTodoChange(in: note, { Self.addTodoLine(source, toNote: note) }, failed: { [weak self] in
            self?.todos.unpatch(reference)
        }, whenWritten: { [weak self] in
            // The note may be new: it shows in its folder at once.
            let listing = await Task.detached(priority: .userInitiated) { FileNode.listing(of: note) }.value
            self?.showChanges(in: [note.deletingLastPathComponent()], adding: listing.map { [$0] } ?? [])
        })
        return item
    }

    /// Writes a to-do's line into a note, making the note when there is none.
    nonisolated private static func addTodoLine(_ source: String, toNote note: URL) -> TodoChangeOutcome {
        var outcome = TodoChangeOutcome.failed
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: note, options: .forMerging, error: &error) { url in
            var text = ""
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url), let read = NoteDocument.decode(data) else { return }
                text = read
            }
            let string = text as NSString
            let inserting = Todos.inserting([source], in: string, document: MarkdownParser.parse(string, syntax: NoteSyntax(url: url)))
            let changed = string.replacingCharacters(in: inserting.range, with: inserting.replacement)
            if FileOperations.write(Data(changed.utf8), to: url) { outcome = .written }
        }
        return outcome
    }

    /// Whether a to-do is the one just added to a note and still has no words: it reminds of nothing yet, and no widget
    /// shows it, as with one just added in no note.
    func isBeingAdded(_ item: TodoList.Item) -> Bool {
        guard item.todo.text.isEmpty, item.todo.lines.isEmpty, let editing = todoEditing, editing.added != nil else { return false }
        return editing.shows(item)
    }

    /// A to-do just added to a folder's note went again without having been given words: the note goes too when that
    /// leaves nothing in it, as it was made for the to-do. Once what is being written has been.
    func removeFolderTodosNoteIfEmpty(_ note: URL) {
        guard !isLoose(note), note.lastPathComponent == LooseTodos.fileName, editorShowing(note) == nil else { return }
        chainTodoWrite { [weak self] in
            let removed = await Task.detached(priority: .userInitiated) { FileOperations.removeEmptyNote(note) }.value
            if removed { self?.showChanges(in: [note.deletingLastPathComponent()], removing: [note]) }
        }
    }
}
