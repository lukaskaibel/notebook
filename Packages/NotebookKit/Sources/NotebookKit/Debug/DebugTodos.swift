#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// The debug remote's commands for to-dos, the same on the Mac and on iPhone and iPad. A to-do is named by some of
/// its words.
///
///     todos                                      the To-dos list as it shows: each group, its rows, and the count
///     showtodos                                  To-dos, as the row at the top of the sidebar opens it
///     ticktodo <words>                           ticks it in its note, as its circle in To-dos does
///     datetodo <yyyy-MM-dd[THH:mm] | none> <words>  gives it a day (and a time), or takes it away
///     placetodo <name> <latitude> <longitude> <words>  gives it a place to arrive at
///     movetodo <today|tomorrow|week|later|none> <words>  as dragging it into that group
///     opentodo <words>                           opens its note at it
///     remindtodo [date|place] <words>            Remind Me for it (the popover or the sheet), or on the Mac the
///                                                dropdown for its date or place, as its pills open them
///     firetodo <words>                           its notification in a second, as at its time
///     todojobs                                   what the to-dos' notifications are made from
///     edittodo <offset|end> <words>              edits it in To-dos, as a click on its words that many letters in
///     todoediting                                the to-do being edited: its words, its lines and where the keyboard is
///     todolines <words>                          the lines under it, as To-dos reads them
///     showstodos 0|1                             To-dos on or off, as in Settings
///     todopick date|time|place|none              opens the to-do being edited's dropdown for that, or closes it
///     todopicktype <text>                        types in the open dropdown's field
///     todopickkey down|up|return|escape|focus    a key in the open dropdown, or the keyboard into its field
///     todopicker                                 what the open dropdown shows
@MainActor
enum DebugTodos {
    /// Asks To-dos to edit a to-do: `item` and `offset` in its user info.
    static let edit = Notification.Name("DebugTodosEdit")
    /// Asks the to-do being edited to open a dropdown: "date", "time", "place" or "none" as the object.
    static let pick = Notification.Name("DebugTodosPick")
    /// Types in the open dropdown: the text as the object.
    static let pickerType = Notification.Name("DebugTodosPickerType")
    /// A key in the open dropdown: "down", "up", "return" or "escape" as the object.
    static let pickerKey = Notification.Name("DebugTodosPickerKey")
    /// The to-do To-dos is editing, and where its keyboard is.
    static weak var session: TodoEditing?
    static var focus: TodoFocus?

    static func run(_ command: String, _ argument: String, workspace: Workspace, log: @escaping (String) -> Void) -> Bool {
        func find(_ words: String) -> TodoList.Item? {
            let folded = words.lowercased()
            return workspace.todos.items.first { $0.todo.text.lowercased().contains(folded) }
        }
        let split = argument.split(separator: " ", maxSplits: 1).map(String.init)
        switch command {
        case "todos":
            let notes = workspace.reminders.all.map { NoteReminderRow(reminder: $0, url: workspace.url(for: $0, searching: false), name: $0.name) }
            let sections = TodoGroups.sections(todos: workspace.todos.items, notes: notes)
            let lines = sections.flatMap { section in
                [section.title + ":"] + section.rows.map { row in
                    switch row {
                    case .todo(let item):
                        let when = item.todo.due.map { " | " + ReminderText.text($0.date(), time: $0.hasTime) } ?? ""
                        let place = item.todo.place.map { " | " + $0.phrase } ?? ""
                        let notes = item.todo.notes.isEmpty ? "" : " | notes: " + item.todo.notes.joined(separator: " / ")
                        return "  ○ \(item.todo.text)\(when)\(place) | in \(item.note)\(notes)"
                    case .note(let note):
                        return "  ◻︎ \(note.name) | \(note.reminder.text) | note"
                    }
                }
            }
            log("todos (ready \(workspace.todos.isReady), \(workspace.todos.items.count) open, \(workspace.dueTodoCount) due, showing \(workspace.showsTodos)):\n" + lines.joined(separator: "\n"))
        case "showtodos":
            workspace.showTodos()
            log("showtodos: \(workspace.showsTodos)")
        case "ticktodo":
            guard let item = find(argument) else { log("ticktodo: no to-do “\(argument)”"); break }
            workspace.setTodoDone(item.reference, true)
            log("ticktodo \(item.todo.text) in \(item.note)")
        case "datetodo":
            guard split.count == 2, let item = find(split[1]) else { log("datetodo: <date|none> <words>"); break }
            var due: TodoDue?
            if split[0] != "none" {
                let formatter = DateFormatter()
                formatter.dateFormat = split[0].contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
                guard let date = formatter.date(from: split[0]) else { log("datetodo: no date \(split[0])"); break }
                due = TodoDue(date, time: split[0].contains("T"))
            }
            workspace.setTodo(item.reference, due: due, place: item.todo.place)
            log("datetodo \(item.todo.text): \(due?.markdown ?? "none")")
        case "placetodo":
            let parts = argument.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, let latitude = Double(parts[1]), let longitude = Double(parts[2]), let item = find(parts[3]) else {
                log("placetodo: <name> <latitude> <longitude> <words>"); break
            }
            workspace.setTodo(item.reference, due: item.todo.due, place: TodoPlace(name: parts[0].replacingOccurrences(of: "_", with: " "), latitude: latitude, longitude: longitude))
            log("placetodo \(item.todo.text): \(parts[0])")
        case "movetodo":
            guard split.count == 2, let item = find(split[1]) else { log("movetodo: <group> <words>"); break }
            let kinds: [String: TodoSection.Kind] = ["today": .today, "tomorrow": .tomorrow, "week": .week, "later": .later, "none": .someday]
            guard let kind = kinds[split[0]], let day = TodoSection.day(for: kind) else { log("movetodo: no group \(split[0])"); break }
            workspace.move(.todo(item), to: day)
            log("movetodo \(item.todo.text) to \(split[0])")
        case "opentodo":
            guard let item = find(argument) else { log("opentodo: no to-do “\(argument)”"); break }
            workspace.openTodo(item.reference)
            log("opentodo \(item.todo.text): open \(workspace.currentURL?.lastPathComponent ?? "nothing")")
        case "remindtodo":
            // remindtodo [date|place] <words>: Remind Me, or the dropdown for its date or place, as its pills open them.
            let part: TodoPart = split.first == "date" ? .date : split.first == "place" ? .place : .reminder
            let words = part == .reminder ? argument : split.count > 1 ? split[1] : ""
            guard let item = find(words) else { log("remindtodo: no to-do “\(words)”"); break }
            if let editor = workspace.editorShowing(item.url), let line = editor.todoLine(item.todo.source, near: item.todo.line) {
                workspace.askForTodoReminder(in: editor, url: item.url, line: line, part: part)
            } else {
                #if os(iOS)
                workspace.askForTodoReminder(item.reference)
                #else
                log("remindtodo: open its note first")
                #endif
            }
            log("remindtodo \(item.todo.text)")
        case "firetodo":
            guard let item = find(argument), let job = workspace.todoJobs().first(where: { $0.source == item.todo.source && $0.path == item.url.path }) else {
                log("firetodo: no to-do with a reminder “\(argument)”"); break
            }
            ReminderNotifications.shared.fireSoon(job)
            log("firetodo \(job.identifier): \(job.title) | \(job.subtitle(forPlace: job.date == nil)) | \(job.body.replacingOccurrences(of: "\n", with: " / "))")
        case "edittodo":
            guard split.count == 2, let item = find(split[1]) else { log("edittodo: <offset|end> <words>"); break }
            NotificationCenter.default.post(name: edit, object: nil, userInfo: ["item": item, "offset": Int(split[0]) as Any])
            log("edittodo \(item.todo.text) at \(split[0])")
        case "todoediting":
            guard let session, !session.isEnded else { log("todoediting: none"); break }
            let focus = switch self.focus {
            case .title: "title"
            case .line(let id): "line \(session.lines.firstIndex { $0.id == id } ?? -1)"
            case nil: "none"
            }
            func caret(_ words: String, _ selection: TextSelection?) -> String {
                guard selection != nil else { return "-" }
                return "\(words.utf16.distance(from: words.startIndex, to: TodoEditing.caret(in: words, selection)))"
            }
            let lines = session.lines.enumerated().map { "  \($0.offset): [\($0.element.depth)] \($0.element.markdown.debugDescription) caret \(caret($0.element.words, $0.element.selection))" }
            log("todoediting \(session.title.debugDescription) caret \(caret(session.title, session.titleSelection)) (focus \(focus), source \(session.current.source.debugDescription)):\n" + lines.joined(separator: "\n"))
        case "todolines":
            guard let item = find(argument) else { log("todolines: no to-do “\(argument)”"); break }
            log("todolines \(item.todo.text) [\(item.todo.mark.character)] fields \(item.todo.fields.map { $0.label() }):\n"
                + item.todo.lines.map { "  [\($0.depth)] \($0.kind) \($0.text.debugDescription) | \($0.source.debugDescription)" }.joined(separator: "\n"))
        case "todopick":
            NotificationCenter.default.post(name: pick, object: argument)
            log("todopick \(argument)")
        case "todopicktype":
            NotificationCenter.default.post(name: pickerType, object: argument)
            log("todopicktype \(argument)")
        case "todopickkey":
            NotificationCenter.default.post(name: pickerKey, object: argument)
            log("todopickkey \(argument)")
        #if os(macOS)
        case "todopicker":
            guard let panel = Dropdown.debugPanel else { log("todopicker: none open"); break }
            log("todopicker at \(panel.frame.integral) under \(panel.anchor.integral), key \(panel.isKeyWindow), first responder \(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        #endif
        case "showstodos":
            NotebookSettings.shared.showsTodos = argument == "1"
            log("showstodos \(NotebookSettings.shared.showsTodos), showing \(workspace.showsTodos)")
        case "todojobs":
            let jobs = workspace.todoJobs()
            log("todojobs (\(jobs.count)):\n" + jobs.map { "  \($0.identifier) \($0.date?.formatted(date: .abbreviated, time: .shortened) ?? "-") \($0.place?.phrase ?? "") | \($0.title) | \($0.subtitle(forPlace: false))" }.joined(separator: "\n"))
        default:
            return false
        }
        return true
    }
}
#endif
