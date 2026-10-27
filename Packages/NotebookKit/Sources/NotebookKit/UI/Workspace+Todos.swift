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
        widgets.refresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishWidgetNotes(catalog: false) }
        widgets.refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// The to-dos changed: their notifications follow a moment later, so a pause in typing doesn't schedule them
    /// again each time.
    func todosChanged() {
        watchForDueReminders()
        #if os(macOS)
        sidebar?.refreshTodosRow()
        #endif
        todoScheduling?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleTodoNotifications()
            self?.publishWidgetTodos()
        }
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

    /// Ticks a to-do, or unticks it. Undo gives it back the mark it had, `[/]` say. `fromNotification`: Done in the
    /// to-do's notification; `unless` and `outcome`: see `setTodoMark`.
    @discardableResult
    func setTodoDone(_ todo: TodoReference, _ done: Bool, fromNotification: Bool = false, unless refused: TodoLinesCheck? = nil,
                     outcome: (@MainActor (TodoChangeOutcome) -> Void)? = nil) -> Task<Void, Never>? {
        let todo = current(todo)
        guard let mark = Todos.mark(of: todo.source) else {
            outcome?(.notThere)
            return nil
        }
        guard mark.isClosed != done else {
            outcome?(.unchanged)
            return nil
        }
        return setTodoMark(todo, done ? .done : .open, fromNotification: fromNotification, unless: refused, outcome: outcome)
    }

    /// Puts another mark in a to-do's brackets: done, in progress, cancelled, or back to do. Ticked, a to-do that repeats
    /// gets the day it was done and the next one goes above it, as the Tasks plugin writes them; brought back, a to-do
    /// loses the day it was done. The notifications of one that repeats change once the change is written, and from its
    /// notification (`fromNotification`) the next one's is in before the task ends, even before To-dos lists it.
    /// `unless`: nothing is changed when it holds for the to-do's line in the note as it is then. `outcome`: told what
    /// became of it, once, instead of a beep when it couldn't be done.
    @discardableResult
    func setTodoMark(_ todo: TodoReference, _ mark: TaskMark, fromNotification: Bool = false, unless refused: TodoLinesCheck? = nil,
                     outcome: (@MainActor (TodoChangeOutcome) -> Void)? = nil) -> Task<Void, Never>? {
        let todo = current(todo)
        let before = Todos.mark(of: todo.source) ?? .open
        let name = switch mark {
        case .done: "Check"
        case .open: "Uncheck"
        case .cancelled: "Cancel To-do"
        default: "Mark To-do"
        }
        let today = TodoDay.today
        guard let after = Todos.marking(todo.source, as: mark, today: today) else {
            outcome?(.unchanged)
            return nil
        }
        let edit: TodoLinesEdit = { text, document, index in
            if let refused, refused(text, document, index) { return nil }
            return Todos.marking(in: text, document: document, line: index, as: mark, today: today)
        }
        guard let next = after.next else {
            return changeTodo(todo, to: after.line, actionName: name, edit: edit, under: nil, outcome: outcome, undo: { [weak self] changed in
                self?.setTodoMark(changed, before)
            })
        }
        // To-dos shows the next one in its place at once, unless it lists it already next to it: then it was there
        // before, ticked and unticked, and isn't written again.
        let listed = todos.items.contains { FileNode.samePath($0.url, todo.url) && $0.todo.source == next && abs($0.todo.line - todo.line) == 1 }
        let tick = TodoTick(done: TodoReference(url: todo.url, line: todo.line + 1, source: after.line), original: todo.source, next: next, showsNext: !listed)
        let written = tick.written
        let inEditor = editorShowing(todo.url) != nil
        let notified = todoJobIdentifiers(of: todo)
        let nextTodo = TodoReference(url: todo.url, line: todo.line, source: next)
        // The next one can say what it said (no date, or `when done` on its day): then the line it said that on is the
        // next one's, not the done one's.
        let task = changeTodo(todo, to: after.line, line: tick.done.line, shows: listed ? nil : (todo, next, []), rewrites: next != todo.source,
                              actionName: name, edit: { text, document, index in
            let change = edit(text, document, index)
            if let change { written.set(change.replacement.contains("\n")) }
            return change
        }, under: nil, outcome: outcome, whenWritten: { [weak self] in
            await self?.remindOfNext(nextTodo, withdrawing: notified, asItWillBe: fromNotification)?.value
        }, undo: { [weak self] _ in
            self?.takeBackTick(tick)
        })
        // In the editor the change is made by now, or not at all; in the file it is on its way.
        guard !inEditor || written.value != nil else { return task }
        if todoTicks.count > 200 { todoTicks.removeAll() }
        todoTicks = todoTicks.filter { !(FileNode.samePath($0.value.done.url, todo.url) && $0.value.original == todo.source) }
        todoTicks[Self.rewriteKey(tick.done)] = tick
        return task
    }

    /// A to-do that repeats was ticked, and the change written: the notifications that came or wait for it go at once,
    /// and the next one's go in at once, as the to-dos' own scheduling would make them a moment later, since the app
    /// may have only this moment (Done from the Lock Screen). The next one may have the same name, when it says the
    /// same: what goes goes first, and a place it reminded of reminds again. `asItWillBe`: see `todoJob(for:asItWillBe:)`.
    @discardableResult
    func remindOfNext(_ next: TodoReference, withdrawing identifiers: [String], asItWillBe: Bool = false) -> Task<Void, Never>? {
        #if DEBUG
        remindedOfNext.append((next.source, asItWillBe))
        #endif
        identifiers.forEach(ReminderNotifications.shared.withdrawTodo)
        guard ReminderNotifications.shared.isActive, isStarted, NotebookSettings.shared.showsTodos,
              let job = todoJob(for: next, asItWillBe: asItWillBe) else { return nil }
        #if DEBUG
        if temporaryLocations, UserDefaults.standard.bool(forKey: "NotebookDemo") { return nil }
        #endif
        return Task { await ReminderNotifications.shared.scheduleTodo(job) }
    }

    /// The names of the notifications of a to-do To-dos lists.
    func todoJobIdentifiers(of todo: TodoReference) -> [String] {
        todoJobs().filter { FileNode.samePath(URL(fileURLWithPath: $0.path), todo.url) && $0.source == todo.source }
            .min { abs($0.line - todo.line) < abs($1.line - todo.line) }.map { [$0.identifier] } ?? []
    }

    /// The notification of a to-do with a reminder, as the to-dos' scheduling makes it. With `asItWillBe`, also of one
    /// To-dos doesn't list yet, as its scheduling will make it once it does: the next one of a to-do done from its
    /// notification, before the note is read again. Never for a note To-dos leaves out, hidden or not in a location.
    func todoJob(for todo: TodoReference, asItWillBe: Bool = false) -> ReminderNotifications.TodoJob? {
        if let job = todoJobs().filter({ FileNode.samePath(URL(fileURLWithPath: $0.path), todo.url) && $0.source == todo.source })
            .min(by: { abs($0.line - todo.line) < abs($1.line - todo.line) }) { return job }
        guard asItWillBe, location(containing: todo.url) != nil, !SearchIndex.isHidden(todo.url.path, in: index.hiddenPaths),
              let parsed = Todos.line(todo.source), !parsed.done, parsed.due != nil || parsed.place != nil else { return nil }
        let note = todo.url.deletingPathExtension().lastPathComponent
        return ReminderNotifications.TodoJob(identifier: Self.todoIdentifier(path: todo.url.path, source: todo.source, notes: ""), date: parsed.due?.alertDate(),
                                             place: parsed.place, title: parsed.text.isEmpty ? note : parsed.text, noteName: note, body: "",
                                             path: todo.url.path, line: todo.line, source: todo.source)
    }

    /// A to-do that repeats was ticked in an editor: as when it is ticked in To-dos, its notifications go and the next
    /// one's come.
    func repeatingTodoTicked(in url: URL, line: Int, source: String, next: String) {
        remindOfNext(TodoReference(url: url.standardizedFileURL, line: line, source: next), withdrawing: todoJobIdentifiers(of: TodoReference(url: url.standardizedFileURL, line: line, source: source)))
    }

    /// Unticks a to-do just ticked in To-dos, back to the mark it had. One that repeats is as it was before: the next
    /// one written for it goes again.
    @discardableResult
    func untickTodo(_ todo: TodoReference, to mark: TaskMark) -> Task<Void, Never>? {
        var done = current(todo)
        // By the line it was ticked to, or, when the next one says what it said, by that.
        if let tick = todoTicks[Self.rewriteKey(done)]
            ?? todoTicks.values.first(where: { FileNode.samePath($0.done.url, todo.url) && $0.original == todo.source && $0.next == todo.source }) {
            return takeBackTick(tick)
        }
        // Not ticked here, or long ago: its line as ticking makes it.
        if done.source == todo.source { done.source = Todos.ticked(todo.source) }
        return setTodoMark(done, mark)
    }

    /// Takes back ticking a to-do that repeats, from To-dos or with Undo: its line says what it said before, and the
    /// next one written for it goes, if it is still as it was written.
    @discardableResult
    func takeBackTick(_ tick: TodoTick) -> Task<Void, Never>? {
        todoTicks[Self.rewriteKey(tick.done)] = nil
        let done = current(tick.done)
        let written = tick.written, next = tick.next, original = tick.original
        let above = TodoReference(url: done.url, line: max(0, done.line - 1), source: next)
        return changeTodo(done, to: original, line: tick.showsNext ? above.line : done.line, shows: tick.showsNext ? (above, original, nil) : nil,
                          rewrites: next != original, actionName: "Uncheck", edit: { text, document, index in
            // Known by now: the change it takes back was made first.
            Todos.takingBack(in: text, document: document, line: index, to: original, next: written.value == true ? next : nil)
        }, under: nil, undo: { [weak self] changed in
            self?.setTodoMark(changed, .done)
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
    /// Something about a to-do's line in a note, given the same.
    typealias TodoLinesCheck = @Sendable (NSString, MarkdownDocument, Int) -> Bool

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
            let ending = Todos.lineEnding(in: text, line: document.lines[index])
            return (NSRange(location: start, length: document.lines[index + before.count - 1].range.upperBound - start), after.joined(separator: ending))
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
    /// `line` is where the to-do's line is after the change, when lines go in or out above it, and `shows` what To-dos
    /// shows in place of a to-do it lists, when not the to-do's line after the change. Without `rewrites`, what the
    /// to-do's line said stays the to-do's (`current(_:)`): a line that says the same is there again.
    /// `outcome` is told once what became of the change, and then there is no beep when it couldn't be made.
    private func changeTodo(_ todo: TodoReference, to source: String, line: Int? = nil, shows: (todo: TodoReference, source: String, under: [String]?)? = nil,
                            rewrites: Bool = true, actionName: String, edit: @escaping TodoLinesEdit, under: [String]?,
                            now: Bool = false, outcome: (@MainActor (TodoChangeOutcome) -> Void)? = nil,
                            whenWritten: (@MainActor () async -> Void)? = nil,
                            undo: @escaping (TodoReference) -> Void) -> Task<Void, Never>? {
        let changed = TodoReference(url: todo.url, line: line ?? todo.line, source: source)
        let shown = shows ?? (todo, source, under)
        if let editor = editorShowing(todo.url) {
            // The note isn't in the editor yet: another time.
            if let outcome, editor.isWaitingForText {
                outcome(.failed)
                return nil
            }
            guard let line = editor.todoLine(todo.source, near: todo.line) else {
                if let outcome { outcome(.notThere) } else { beep() }
                return nil
            }
            guard editor.editTodoLines(line: line, actionName: actionName, edit: edit) else {
                // The lines under it changed meanwhile.
                if let outcome { outcome(.notThere) } else if under != nil { beep() }
                return nil
            }
            if rewrites { rewrote(todo, to: changed) }
            todos.patch(shown.todo, to: shown.source, under: shown.under)
            // From a notification the app may only have a moment: the note is written now, not after a pause.
            saveNote(showing: todo.url)
            outcome?(.written)
            return whenWritten.map { then in Task { await then() } }
        }
        if rewrites { rewrote(todo, to: changed) }
        todos.patch(shown.todo, to: shown.source, under: shown.under)
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
            let written = Self.write(todo, edit: edit)
            if written.change == nil { todos.unpatch(shown.todo) }
            outcome?(written.outcome)
            return nil
        }
        let url = todo.url
        let previous = lastTodoWrite
        let task = Task { [weak self] in
            await previous?.value
            let written = await Task.detached(priority: .userInitiated) { Self.write(todo, edit: edit) }.value
            guard let self else {
                outcome?(written.outcome)
                return
            }
            index.refresh(folders: [url.deletingLastPathComponent()], locations: locations)
            // Changed or gone meanwhile, here or on another device: the list shows it as it is now, and there is nothing
            // to undo.
            guard written.change != nil else {
                manager.removeAllActions(withTarget: target)
                if todoRewrites[Self.rewriteKey(todo)] == changed { todoRewrites[Self.rewriteKey(todo)] = nil }
                todos.unpatch(shown.todo)
                if let outcome { return outcome(written.outcome) }
                return beep()
            }
            outcome?(.written)
            await whenWritten?()
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
    /// change, or nil when the to-do or its file isn't there (`notThere`) or the file couldn't be read or written
    /// (`failed`).
    nonisolated private static func write(_ todo: TodoReference, edit: TodoLinesEdit) -> (change: (line: Int, source: String)?, outcome: TodoChangeOutcome) {
        var result: (change: (line: Int, source: String)?, outcome: TodoChangeOutcome) = (nil, .failed)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: todo.url, options: .forMerging, error: &error) { url in
            // Renamed, moved or deleted somewhere else: there is no to-do to change. (One only in iCloud is downloaded
            // for the coordinated write first.)
            guard FileManager.default.fileExists(atPath: url.path) else { return result.outcome = .notThere }
            guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return }
            let string = text as NSString
            let document = MarkdownParser.parse(string)
            guard let index = Todos.find(todo.source, near: todo.line, in: document, string: string),
                  let change = edit(string, document, index) else { return result.outcome = .notThere }
            let changed = string.replacingCharacters(in: change.range, with: change.replacement)
            guard FileOperations.write(Data(changed.utf8), to: url) else { return }
            let line = MarkdownParser.parse(changed).lines[index].range
            result = ((index, (changed as NSString).substring(with: line)), .written)
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
        let jobs = withoutWidgetTicks(todoJobs())
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
        // File events can name a note "/private/var/…" that was "/var/…". A note in the app's own folder is named from
        // there, as an update of the app moves the folder: a place that reminded you doesn't remind you again after one.
        #if os(iOS)
        let path = lastingPath(path, documents: documentsPath)
        #else
        let path = HiddenFolders.withoutPrivate(path)
        #endif
        return ReminderNotifications.todoPrefix + hash(path + "\n" + source + "\n" + notes + "\n\(occurrence)")
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

/// What became of a change to a to-do, for what waits on it (a tick from a widget): written; nothing to change (done
/// already); not there to change (gone, changed since, or its note gone); or not written now, to be tried again.
enum TodoChangeOutcome: Sendable {
    case written, unchanged, notThere, failed
}

/// A to-do that repeats, ticked in To-dos or from its notification: the line it was ticked to, what it said before and
/// the next one written above it, to take it back.
struct TodoTick {
    var done: TodoReference
    var original: String
    var next: String
    /// Whether To-dos showed the next one at once.
    var showsNext: Bool
    let written = Written()

    /// Whether the next one was written, not there already: known once the change is made, in a file off the main
    /// thread.
    final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var wrote: Bool?

        var value: Bool? { lock.withLock { wrote } }
        func set(_ value: Bool) { lock.withLock { wrote = value } }
    }
}
