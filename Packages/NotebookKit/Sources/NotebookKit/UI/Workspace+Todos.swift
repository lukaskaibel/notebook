#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// A to-do whose date or place to change, from its pill.
struct TodoPickRequest: Identifiable {
    let todo: TodoReference
    let isPlace: Bool
    var id: String { todo.id + (isPlace ? "\u{0}place" : "") }
}

/// To-dos: every open checkbox in the notes, in the To-dos list, with a date, a time and a place written after its words
/// for those that should remind you. A to-do is changed in the editor that shows its note, where Undo takes it back, or
/// else in its file, off the main thread, merged with what is there.
extension Workspace {
    // MARK: - Keeping up

    /// What search knows changed: the to-dos are read again, in the background.
    func indexChanged() {
        // Ready only once every file has been read, not with the index kept from the last run: until then a to-do left
        // out would take its notification with it.
        todos.update(entries: index.byPathSnapshot, hidden: index.hiddenPaths, built: index.hasBuilt && !index.isBuilding)
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

    /// The pill or the bell of a to-do in an editor was clicked, or Remind Me… chosen: on the Mac the dropdown for its
    /// date or its place, as To-dos has them, or Remind Me for both, from there.
    func askForTodoReminder(in editor: EditorController, url: URL, line: Int, part: TodoPart = .reminder) {
        guard let current = editor.todo(onLine: line) else { return }
        let todo = TodoReference(url: url.standardizedFileURL, line: line, source: current.source)
        #if os(macOS)
        let rect = editor.todoAnchor(line: line, part: part) ?? .zero
        switch part {
        case .reminder: askForTodoReminder(todo, from: editor.textView, rect: rect)
        case .date, .place: showTodoDropdown(todo, part: part, from: editor.textView, rect: rect)
        }
        #else
        switch part {
        case .reminder: todoReminderRequest = todo
        case .date, .place: todoPickRequest = TodoPickRequest(todo: todo, isPlace: part == .place)
        }
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

    /// A to-do's date or place in a dropdown under `rect` of `view`: typed or clicked, as To-dos' buttons have them.
    func showTodoDropdown(_ todo: TodoReference, part: TodoPart, from view: NSView, rect: NSRect) {
        guard view.window != nil else { return beep() }
        reminderPopover?.close()
        let schedule = schedule(of: todo)
        Dropdown.show(below: rect.insetBy(dx: -2, dy: -2), in: view) { close in
            if part == .place {
                TodoPlaceDropdown(place: schedule.place, pick: { [weak self] place in self?.setTodo(todo, due: schedule.due, place: place) }, close: close)
            } else {
                TodoDatePicker(due: schedule.due, pick: { [weak self] due in self?.setTodo(todo, due: due, place: schedule.place) }, close: close)
            }
        }
    }
    #else
    func askForTodoReminder(_ todo: TodoReference) {
        todoReminderRequest = todo
    }
    #endif

    /// A to-do's date or place, picked in a sheet: typed or tapped, as To-dos has them.
    @ViewBuilder
    func todoPicker(for request: TodoPickRequest, close: @escaping () -> Void) -> some View {
        let schedule = schedule(of: request.todo)
        ScrollView {
            if request.isPlace {
                TodoPlaceDropdown(place: schedule.place, pick: { [weak self] place in self?.setTodo(request.todo, due: schedule.due, place: place) }, close: close)
            } else {
                TodoDatePicker(due: schedule.due, pick: { [weak self] due in self?.setTodo(request.todo, due: due, place: schedule.place) }, close: close)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Changing a to-do

    /// Sets a to-do's date and place, or takes them away. The first asks whether Notebook may send notifications.
    @discardableResult
    func setTodo(_ todo: TodoReference, due: TodoDue?, place: TodoPlace?) -> Task<Void, Never>? {
        let todo = current(todo)
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

    /// Ticks a to-do, or unticks it. Undo gives it back the mark it had, `[/]` say.
    @discardableResult
    func setTodoDone(_ todo: TodoReference, _ done: Bool) -> Task<Void, Never>? {
        let todo = current(todo)
        guard let mark = Todos.mark(of: todo.source), mark.isClosed != done else { return nil }
        return setTodoMark(todo, done ? .done : .open)
    }

    /// Puts another mark in a to-do's brackets: done, in progress, cancelled, or back to do.
    @discardableResult
    func setTodoMark(_ todo: TodoReference, _ mark: TaskMark) -> Task<Void, Never>? {
        let todo = current(todo)
        let before = Todos.mark(of: todo.source) ?? .open
        let name = switch mark {
        case .done: "Check"
        case .open: "Uncheck"
        case .cancelled: "Cancel To-do"
        default: "Mark To-do"
        }
        return changeTodo(todo, actionName: name, edit: { _, line in
            guard case .listItem(let item) = line.kind, let box = item.checkbox, item.mark != mark else { return nil }
            return (box, "[" + String(mark.character) + "]")
        }, undo: { [weak self] changed in
            self?.setTodoMark(changed, before)
        })
    }

    /// Moves a to-do to another day, keeping its time and place: dragged into another group of To-dos, or chosen in
    /// its menu.
    @discardableResult
    func moveTodo(_ todo: TodoReference, to day: Date?) -> Task<Void, Never>? {
        let todo = self.current(todo)
        let current = schedule(of: todo)
        guard let day else { return setTodo(todo, due: nil, place: current.place) }
        var due = TodoDue(day, time: false)
        if let old = current.due, old.hasTime { due = due.at(hour: old.hour, minute: old.minute) }
        guard due != current.due else { return nil }
        return setTodo(todo, due: due, place: current.place)
    }

    /// Remind Me in 1 Hour, from a to-do's notification: its time becomes that time. With the name its notification will
    /// have then, for one to go in right away (`notes`: the to-do's notes, as the notification has them).
    func remindOfTodoAgain(_ todo: TodoReference, at date: Date, notes: String) -> (task: Task<Void, Never>?, todo: TodoReference, identifier: String) {
        let todo = current(todo)
        let due = TodoDue(date, time: true), place = schedule(of: todo).place
        let task = setTodo(todo, due: due, place: place)
        let changed = current(todo)
        return (task, changed, Self.todoIdentifier(path: todo.url.path, source: changed.source, notes: notes))
    }

    /// A to-do as Notebook last changed it. The list catches up with a change a moment after it is written, so a row
    /// still showing the line from before (ticked and unticked again at once, or moved twice) finds it as it is now.
    func current(_ todo: TodoReference) -> TodoReference {
        var todo = todo
        var seen: Set<String> = [todo.source]
        while let newer = todoRewrites[Self.rewriteKey(todo)], seen.insert(newer.source).inserted { todo = newer }
        return todo
    }

    private static func rewriteKey(_ todo: TodoReference) -> String {
        HiddenFolders.withoutPrivate(todo.url.standardizedFileURL.path) + "\n" + todo.source
    }

    /// Remembers what a to-do's line became.
    private func rewrote(_ todo: TodoReference, to changed: TodoReference) {
        guard changed.source != todo.source else { return }
        if todoRewrites.count > 200 { todoRewrites.removeAll() }
        // Back to what it was (Undo): no way round in a circle.
        todoRewrites[Self.rewriteKey(changed)] = nil
        todoRewrites[Self.rewriteKey(todo)] = changed
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
    /// A change to a to-do and the lines under it, given the note's text, its lines and the to-do's line.
    typealias TodoLinesEdit = @Sendable (NSString, MarkdownDocument, Int) -> (range: NSRange, replacement: String)?

    /// Changes a to-do's line. See `changeTodo(_:to:actionName:edit:under:undo:)`.
    private func changeTodo(_ todo: TodoReference, actionName: String, edit: @escaping TodoEdit, undo: @escaping (TodoReference) -> Void) -> Task<Void, Never>? {
        let todo = current(todo)
        // Nothing to change: already ticked, or already on that day.
        guard let source = Todos.line(todo.source, after: edit) else { return nil }
        return changeTodo(todo, to: source, actionName: actionName, edit: { text, document, index in
            guard let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask else { return nil }
            return edit(text, line)
        }, under: nil, undo: undo)
    }

    /// Changes a to-do and the lines under it, edited in To-dos: `before` and `after` start with the to-do's line.
    /// Nothing changes when the lines no longer say what they said, here or in the file.
    @discardableResult
    func changeTodoLines(_ todo: TodoReference, from before: [String], to after: [String], actionName: String, now: Bool = false) -> Task<Void, Never>? {
        guard let first = after.first, before.first != nil, before != after else { return nil }
        var todo = current(todo)
        todo.source = before[0]
        return changeTodo(todo, to: first, actionName: actionName, edit: { text, document, index in
            guard index + before.count <= document.lines.count else { return nil }
            for (offset, line) in before.enumerated() where text.substring(with: document.lines[index + offset].range) != line { return nil }
            let start = document.lines[index].range.location
            return (NSRange(location: start, length: document.lines[index + before.count - 1].range.upperBound - start), after.joined(separator: "\n"))
        }, under: Array(after.dropFirst()), now: now, undo: { [weak self] changed in
            self?.changeTodoLines(changed, from: after, to: before, actionName: actionName)
        })
    }

    /// Changes a to-do: in the editor that shows its note, as an edit of the text, saved at once, or else in its file,
    /// which is read and written in one go off the main thread, so nothing written there meanwhile is lost, one change
    /// after another. A change to the file is kept for Undo as it is asked for, so Undo pressed at once waits for it and
    /// Redo comes back; `undo` makes it with the line as it is after the change. `source` is what the to-do's line says
    /// after it, and `under` the lines under it when they change too. To-dos shows the change at once. With `now`, as the
    /// app quits, the file is written before this returns.
    private func changeTodo(_ todo: TodoReference, to source: String, actionName: String, edit: @escaping TodoLinesEdit, under: [String]?,
                            now: Bool = false, undo: @escaping (TodoReference) -> Void) -> Task<Void, Never>? {
        let changed = TodoReference(url: todo.url, line: todo.line, source: source)
        if let editor = editorShowing(todo.url) {
            guard let line = editor.todoLine(todo.source, near: todo.line) else {
                beep()
                return nil
            }
            guard editor.editTodoLines(line: line, actionName: actionName, edit: edit) else {
                // The lines under it changed meanwhile.
                if under != nil { beep() }
                return nil
            }
            rewrote(todo, to: changed)
            todos.patch(todo, to: source, under: under)
            // From a notification the app may only have a moment: the note is written now, not after a pause.
            saveNote(showing: todo.url)
            return nil
        }
        rewrote(todo, to: changed)
        todos.patch(todo, to: source, under: under)
        let manager = fileUndoManager
        let target = TodoUndoTarget()
        // The undo manager closes the group of an event once the event is handled; outside one (a notification's action)
        // the change gets a group of its own.
        let opens = manager.groupingLevel == 0
        if opens { manager.beginUndoGrouping() }
        // The undo manager doesn't keep its targets: the action does.
        manager.registerUndo(withTarget: target) { [target] _ in
            withExtendedLifetime(target) { undo(changed) }
        }
        manager.setActionName(actionName)
        if opens { manager.endUndoGrouping() }
        guard !now else {
            if Self.write(todo, edit: edit) == nil { todos.unpatch(todo) }
            return nil
        }
        let url = todo.url
        let previous = lastTodoWrite
        let task = Task { [weak self] in
            await previous?.value
            let written = await Task.detached(priority: .userInitiated) { Self.write(todo, edit: edit) }.value
            guard let self else { return }
            index.refresh(folders: [url.deletingLastPathComponent()], locations: locations)
            // Changed or gone meanwhile, here or on another device: the list shows it as it is now, and there is nothing
            // to undo.
            guard written != nil else {
                manager.removeAllActions(withTarget: target)
                if todoRewrites[Self.rewriteKey(todo)] == changed { todoRewrites[Self.rewriteKey(todo)] = nil }
                todos.unpatch(todo)
                return beep()
            }
        }
        lastTodoWrite = task
        return task
    }

    /// Writes the note an editor shows, now.
    func saveNote(showing url: URL) {
        if let note, note.isLoaded, FileNode.samePath(note.url, url) {
            note.update(text: editor.text)
            note.saveNow()
            return
        }
        #if os(macOS)
        FileWindows.shared.save(showing: url)
        #endif
    }

    /// Waits until the locations have been looked up, and so can be read and written: a notification's action can be
    /// what started the app.
    func surveyed() async {
        await withCheckedContinuation { continuation in whenSurveyed { continuation.resume() } }
    }

    /// Changes a to-do in its file: the line it is on now, found by what it said. The line and what it says after the
    /// change, or nil when the to-do isn't there or the file couldn't be written.
    nonisolated private static func write(_ todo: TodoReference, edit: TodoLinesEdit) -> (line: Int, source: String)? {
        var result: (line: Int, source: String)?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: todo.url, options: .forMerging, error: &error) { url in
            guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return }
            let string = text as NSString
            let document = MarkdownParser.parse(string)
            guard let index = Todos.find(todo.source, near: todo.line, in: document, string: string),
                  let change = edit(string, document, index) else { return }
            let changed = string.replacingCharacters(in: change.range, with: change.replacement)
            guard FileOperations.write(Data(changed.utf8), to: url) else { return }
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
        guard ReminderNotifications.shared.isActive, isStarted else { return nil }
        // To-dos turned off: none of them reminds.
        guard NotebookSettings.shared.showsTodos else { return ReminderNotifications.shared.scheduleTodos([], open: []) }
        guard todos.isReady else { return nil }
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

/// What Undo keeps a change to a to-do's file under, to take it out again if the change couldn't be written.
private final class TodoUndoTarget {}
