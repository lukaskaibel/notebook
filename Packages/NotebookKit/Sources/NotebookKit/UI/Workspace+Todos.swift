#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// To-dos: every open checkbox in the notes, in the To-dos list, with a date, a time and a place written after its words
/// for those that should remind you. A to-do is changed in the editor that shows its note, where Undo takes it back, or
/// else in its file, off the main thread, merged with what is there.
extension Workspace {
    // MARK: - Keeping up

    /// What search knows changed: the to-dos are read again, in the background.
    func indexChanged() {
        todos.update(entries: index.byPathSnapshot, hidden: index.hiddenPaths, built: !index.isBuilding)
    }

    /// The to-dos changed: their notifications follow a moment later, so a pause in typing doesn't schedule them
    /// again each time.
    func todosChanged() {
        watchForDueReminders()
        #if os(macOS)
        sidebar?.refreshTodosRow()
        #endif
        todoScheduling?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleTodoNotifications() }
        todoScheduling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// How many to-dos and notes are due today or overdue, for the count next to To-dos in the sidebar.
    var dueTodoCount: Int {
        _ = remindersDue
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        let todos = todos.items.filter { ($0.todo.due?.date(in: calendar) ?? .distantFuture) < endOfToday }.count
        let notes = reminders.all.filter { ($0.date ?? .distantFuture) < endOfToday }.count
        return todos + notes
    }

    /// The pills of to-dos in every editor: a time that passed turns red, Tomorrow becomes Today.
    func refreshTodoPills() {
        editor.refreshTodoPills()
        #if os(macOS)
        FileWindows.shared.refreshTodoPills()
        #endif
    }

    func sidebarSelectTodos() {
        #if os(macOS)
        sidebar?.selectTodos()
        #endif
    }

    // MARK: - A to-do's reminder

    /// A to-do's words, date and place, as its line says now.
    func schedule(of todo: TodoReference) -> (text: String, due: TodoDue?, place: TodoPlace?) {
        if let editor = editorShowing(todo.url), let line = editor.todoLine(todo.source, near: todo.line), let current = editor.todo(onLine: line),
           let parsed = Todos.line(current.source) {
            return (parsed.text, parsed.due, parsed.place)
        }
        let parsed = Todos.line(todo.source)
        return (parsed?.text ?? "", parsed?.due, parsed?.place)
    }

    /// The pill or the bell of a to-do in an editor was clicked: Remind Me for it, from there.
    func askForTodoReminder(in editor: EditorController, url: URL, line: Int) {
        guard let current = editor.todo(onLine: line) else { return }
        let todo = TodoReference(url: url.standardizedFileURL, line: line, source: current.source)
        #if os(macOS)
        let rect = editor.todoAnchor(line: line) ?? .zero
        askForTodoReminder(todo, from: editor.textView, rect: rect)
        #else
        todoReminderRequest = todo
        #endif
    }

    #if os(macOS)
    /// Remind Me for a to-do, in a popover pointing at `rect` of `view`.
    func askForTodoReminder(_ todo: TodoReference, from view: NSView, rect: NSRect) {
        guard view.window != nil else { return beep() }
        reminderPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: TodoReminderPicker(workspace: self, todo: todo) { [weak popover] in popover?.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: view, preferredEdge: .maxY)
        reminderPopover = popover
    }
    #else
    func askForTodoReminder(_ todo: TodoReference) {
        todoReminderRequest = todo
    }
    #endif

    // MARK: - Changing a to-do

    /// Sets a to-do's date and place, or takes them away. The first asks whether Notebook may send notifications.
    @discardableResult
    func setTodo(_ todo: TodoReference, due: TodoDue?, place: TodoPlace?) -> Task<Void, Never>? {
        let before = schedule(of: todo)
        if let place { PlaceHistory.add(place) }
        if due != nil || place != nil {
            Task {
                if !(await askForReminderPermissions(place: place != nil)) { reportNotificationsOff() }
            }
        }
        let name = due == nil && place == nil ? "Remove Reminder" : "Set Reminder"
        return changeTodo(todo, actionName: name, edit: { text, line in
            TodoMarks.change(in: text, content: line.content, due: due, place: place)
        }, undo: { [weak self] changed in
            self?.setTodo(changed, due: before.due, place: before.place)
        })
    }

    /// Ticks a to-do, or unticks it.
    @discardableResult
    func setTodoDone(_ todo: TodoReference, _ done: Bool) -> Task<Void, Never>? {
        changeTodo(todo, actionName: done ? "Check" : "Uncheck", edit: { _, line in
            guard case .listItem(let item) = line.kind, let box = item.checkbox, item.checked != done else { return nil }
            return (box, done ? "[x]" : "[ ]")
        }, undo: { [weak self] changed in
            self?.setTodoDone(changed, !done)
        })
    }

    /// Moves a to-do to another day, keeping its time and place: dragged into another group of To-dos, or chosen in
    /// its menu.
    @discardableResult
    func moveTodo(_ todo: TodoReference, to day: Date?) -> Task<Void, Never>? {
        let current = schedule(of: todo)
        guard let day else { return setTodo(todo, due: nil, place: current.place) }
        var due = TodoDue(day, time: false)
        if let old = current.due, old.hasTime { due = due.at(hour: old.hour, minute: old.minute) }
        guard due != current.due else { return nil }
        return setTodo(todo, due: due, place: current.place)
    }

    /// Remind Me in 1 Hour, from a to-do's notification: its time becomes that time. With the name its notification will
    /// have then, for one to go in right away (`notes`: the to-do's notes, as the notification has them).
    func remindOfTodoAgain(_ todo: TodoReference, at date: Date, notes: String) -> (task: Task<Void, Never>?, identifier: String) {
        let due = TodoDue(date, time: true), place = schedule(of: todo).place
        let changed = Todos.line(todo.source) { text, line in TodoMarks.change(in: text, content: line.content, due: due, place: place) } ?? todo.source
        return (setTodo(todo, due: due, place: place), Self.todoIdentifier(path: todo.url.path, source: changed, notes: notes))
    }

    /// The editor that shows a note with its text in: this window's, or on the Mac a window of its own.
    func editorShowing(_ url: URL) -> EditorController? {
        let target = url.standardizedFileURL
        if let note, note.isLoaded, FileNode.samePath(note.url, target) { return editor }
        #if os(macOS)
        return FileWindows.shared.editor(showing: target)
        #else
        return nil
        #endif
    }

    typealias TodoEdit = @Sendable (NSString, MarkdownLine) -> (range: NSRange, replacement: String)?

    /// Changes a to-do's line: in the editor that shows its note, as an edit of the text, or else in its file, which is
    /// read and written in one go off the main thread, so nothing written there meanwhile is lost. A change to the file
    /// is kept for Undo, which `undo` makes with the line as it is after the change.
    private func changeTodo(_ todo: TodoReference, actionName: String, edit: @escaping TodoEdit, undo: @escaping (TodoReference) -> Void) -> Task<Void, Never>? {
        if let editor = editorShowing(todo.url) {
            guard let line = editor.todoLine(todo.source, near: todo.line) else {
                beep()
                return nil
            }
            editor.editTodo(line: line, actionName: actionName, edit: edit)
            return nil
        }
        let url = todo.url
        return Task { [weak self] in
            let written = await Task.detached(priority: .userInitiated) { Self.write(todo, edit: edit) }.value
            guard let self else { return }
            // Changed or gone meanwhile, here or on another device: the list shows it as it is now.
            guard let written else {
                index.refresh(folders: [url.deletingLastPathComponent()], locations: locations)
                return beep()
            }
            index.refresh(folders: [url.deletingLastPathComponent()], locations: locations)
            let changed = TodoReference(url: url, line: written.line, source: written.source)
            let manager = fileUndoManager
            manager.registerUndo(withTarget: self) { _ in undo(changed) }
            manager.setActionName(actionName)
        }
    }

    /// Changes a to-do in its file: the line it is on now, found by what it said. The line and what it says after the
    /// change, or nil when the to-do isn't there or the file couldn't be written.
    nonisolated private static func write(_ todo: TodoReference, edit: TodoEdit) -> (line: Int, source: String)? {
        var result: (line: Int, source: String)?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: todo.url, options: .forMerging, error: &error) { url in
            guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return }
            let string = text as NSString
            let document = MarkdownParser.parse(string)
            guard let index = Todos.find(todo.source, near: todo.line, in: document, string: string),
                  let change = edit(string, document.lines[index]) else { return }
            let changed = string.replacingCharacters(in: change.range, with: change.replacement)
            guard (try? Data(changed.utf8).write(to: url, options: .atomic)) != nil else { return }
            let line = MarkdownParser.parse(changed).lines[index].range
            result = (index, (changed as NSString).substring(with: line))
        }
        return result
    }

    // MARK: - Going to a to-do

    /// Opens a to-do's note with the caret at the end of its words; from a notification once the locations are known.
    func openTodo(_ todo: TodoReference, fromNotification: Bool = false) {
        guard fromNotification else { return open(todo.url, at: .todo(line: todo.line, source: todo.source)) }
        start()
        whenSurveyed { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: todo.url.path) else { return beep() }
            showWindow?()
            #if os(macOS)
            NSApp.activate()
            #endif
            open(todo.url, at: .todo(line: todo.line, source: todo.source))
        }
    }

    // MARK: - Notifications

    /// Schedules the notifications of every to-do with a reminder, once all notes have been read.
    @discardableResult
    func scheduleTodoNotifications() -> Task<Void, Never>? {
        guard ReminderNotifications.shared.isActive, isStarted, todos.isReady else { return nil }
        #if DEBUG
        // A run on the sample notes leaves no notification behind.
        if temporaryLocations, UserDefaults.standard.bool(forKey: "NotebookDemo") { return nil }
        #endif
        let jobs = todoJobs()
        return ReminderNotifications.shared.scheduleTodos(jobs, open: Set(jobs.map(\.identifier)))
    }

    /// What the notifications of the to-dos with a reminder are made from.
    func todoJobs() -> [ReminderNotifications.TodoJob] {
        var seen: [String: Int] = [:]
        return todos.items.filter(\.todo.hasReminder).map { item in
            let todo = item.todo
            let notes = todo.notes.joined(separator: "\n")
            // The same words twice in a note are two to-dos.
            let key = item.url.path + "\n" + todo.source + "\n" + notes
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            return ReminderNotifications.TodoJob(identifier: Self.todoIdentifier(path: item.url.path, source: todo.source, notes: notes, occurrence: occurrence),
                                                 date: todo.due?.alertDate(), place: todo.place, title: todo.text.isEmpty ? item.note : todo.text,
                                                 noteName: item.note, body: todo.notes.joined(separator: "\n"), path: item.url.path, line: todo.line, source: todo.source)
        }
    }

    /// A to-do's notification's name: from its note, its line and its notes, so a to-do changed is a new notification.
    nonisolated static func todoIdentifier(path: String, source: String, notes: String, occurrence: Int = 0) -> String {
        // File events can name a note "/private/var/…" that was "/var/…".
        ReminderNotifications.todoPrefix + hash(HiddenFolders.withoutPrivate(path) + "\n" + source + "\n" + notes + "\n\(occurrence)")
    }

    /// The same on every launch, unlike `hashValue`.
    nonisolated static func hash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
