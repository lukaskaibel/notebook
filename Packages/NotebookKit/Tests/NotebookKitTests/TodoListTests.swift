import SwiftUI
import XCTest
@testable import NotebookKit

/// To-dos in the app: every open checkbox of every note, read from what search knows, grouped by when it's due, and
/// changed in the note's editor or in its file.
@MainActor
final class TodoListTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    private var doctor: URL { library.appendingPathComponent("Personal/Doctor.md") }
    private var trip: URL { library.appendingPathComponent("Kyoto trip.md") }
    private var hidden: URL { library.appendingPathComponent("Archive/Old.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-todos-\(UUID().uuidString)").standardizedFileURL
        for folder in ["Personal", "Archive"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "# Doctor\n\n- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00\n    - ask about the results\n- [x] Book the taxi\n".write(to: doctor, atomically: true, encoding: .utf8)
        try "- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n".write(to: trip, atomically: true, encoding: .utf8)
        try "- [ ] Something old\n".write(to: hidden, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func makeWorkspace() async throws -> Workspace {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        try await until { !workspace.index.isBuilding && workspace.todos.isReady }
        return workspace
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    func testEveryOpenTodoIsListed() async throws {
        let workspace = try await makeWorkspace()
        XCTAssertEqual(Set(workspace.todos.items.map(\.todo.text)), ["Call Dr. Weber", "Pack the adapter", "Print the tickets", "Something old"])
        let call = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call Dr. Weber" })
        XCTAssertEqual(call.note, "Doctor")
        XCTAssertEqual(call.todo.notes, ["• ask about the results"])

        // A hidden folder's to-dos go, as its notes go from search.
        workspace.setHidden(library.appendingPathComponent("Archive"), true)
        try await until { !workspace.todos.items.contains { $0.todo.text == "Something old" } }

        // A note changed elsewhere is read again.
        try "- [ ] Pack the adapter\n- [ ] Buy yen\n".write(to: trip, atomically: true, encoding: .utf8)
        workspace.readAgain([library])
        try await until { workspace.todos.items.contains { $0.todo.text == "Buy yen" } }
        XCTAssertFalse(workspace.todos.items.contains { $0.todo.text == "Print the tickets" })
    }

    func testTickingAndDatingATodoInItsFile() async throws {
        let workspace = try await makeWorkspace()
        let pack = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Pack the adapter" })
        let due = TodoDue(year: 2099, month: 3, day: 4)
        await workspace.setTodo(pack.reference, due: due, place: nil)?.value
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), "- [ ] Pack the adapter 📅 2099-03-04\n- [ ] Print the tickets 📅 2099-01-02\n")

        // Undo takes it back, in the file, and Redo brings it again.
        let manager = workspace.fileUndoManager
        XCTAssertEqual(manager.undoActionName, "Set Reminder")
        manager.undo()
        try await until { (try? String(contentsOf: trip, encoding: .utf8)) == "- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n" }
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        try await until { (try? String(contentsOf: trip, encoding: .utf8)) == "- [ ] Pack the adapter 📅 2099-03-04\n- [ ] Print the tickets 📅 2099-01-02\n" }
        manager.undo()
        try await until { (try? String(contentsOf: trip, encoding: .utf8)) == "- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n" }
        // Two changes at once, before the list has caught up: the second finds the line the first made.
        let tickets = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Print the tickets" })
        workspace.setTodo(tickets.reference, due: TodoDue(year: 2099, month: 1, day: 3), place: nil)
        await workspace.setTodo(tickets.reference, due: TodoDue(year: 2099, month: 1, day: 4), place: nil)?.value
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), "- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-04\n")
        try "- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n".write(to: trip, atomically: true, encoding: .utf8)
        workspace.readAgain([library])
        try await until { workspace.todos.items.contains { $0.todo.due?.day == 2 } }

        // The note changed in between: the to-do is found by what it says.
        try "Intro\n\n- [ ] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n".write(to: trip, atomically: true, encoding: .utf8)
        await workspace.setTodoDone(pack.reference, true)?.value
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), "Intro\n\n- [x] Pack the adapter\n- [ ] Print the tickets 📅 2099-01-02\n")
        try await until { !workspace.todos.items.contains { $0.todo.text == "Pack the adapter" } }

        // A to-do that isn't there any more changes nothing.
        let before = try String(contentsOf: trip, encoding: .utf8)
        await workspace.setTodoDone(pack.reference, true)?.value
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), before)
    }

    func testATodoInTheOpenNoteChangesInItsEditor() async throws {
        let workspace = try await makeWorkspace()
        workspace.open(doctor)
        try await until { workspace.note?.isLoaded == true }
        let call = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call Dr. Weber" })
        workspace.moveTodo(call.reference, to: Calendar.current.date(from: DateComponents(year: 2099, month: 5, day: 6)))
        XCTAssertEqual(workspace.editor.text, "# Doctor\n\n- [ ] Call Dr. Weber ⏰ 2099-05-06 14:00\n    - ask about the results\n- [x] Book the taxi\n", "the time stays")
        // The list's row still has the line from before it moved: it finds the line as it is now.
        workspace.setTodoDone(call.reference, true)
        XCTAssertTrue(workspace.editor.text.contains("- [x] Call Dr. Weber ⏰ 2099-05-06 14:00"))
        // A to-do that isn't there at all changes nothing.
        workspace.setTodoDone(TodoReference(url: doctor, line: 2, source: "- [ ] Something else"), true)
        XCTAssertTrue(workspace.editor.text.contains("- [x] Call Dr. Weber ⏰ 2099-05-06 14:00\n    - ask about the results\n- [x] Book the taxi"))
    }

    // MARK: - Editing in To-dos

    func testEditingATodoAndItsLinesInItsFile() async throws {
        let workspace = try await makeWorkspace()
        let call = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call Dr. Weber" })
        let editing = TodoEditing(workspace: workspace, item: call)
        XCTAssertEqual(editing.title, "Call Dr. Weber", "the words without the time")
        XCTAssertEqual(editing.lines.map(\.words), ["ask about the results"])

        // New words, a sub-to-do under them, and the point turned into one with "[ ] ".
        editing.title = "Call Dr. Weber's office"
        editing.addTodo()
        let added = try XCTUnwrap(editing.lines.last)
        editing.lines[editing.lines.count - 1].words = "bring the letter"
        editing.typed(added.id)
        editing.lines[0].words = "[ ] ask about the results"
        editing.typed(editing.lines[0].id)
        editing.commit()
        // The list shows it at once, before the note is read again.
        XCTAssertEqual(workspace.todos.items.first { $0.url == call.url }?.todo.notes, ["○ ask about the results", "○ bring the letter"])
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(try String(contentsOf: doctor, encoding: .utf8),
                       "# Doctor\n\n- [ ] Call Dr. Weber's office ⏰ 2026-10-24 14:00\n    - [ ] ask about the results\n    - [ ] bring the letter\n- [x] Book the taxi\n")

        // Return after a sub-to-do makes the next; Tab takes it in under the one above; an empty one goes again.
        editing.lines[1].selection = TextSelection(insertionPoint: editing.lines[1].words.endIndex)
        XCTAssertTrue(editing.split(editing.lines[1].id))
        editing.lines[2].words = "the blue one"
        editing.indent(editing.lines[2].id)
        XCTAssertEqual(editing.lines[2].depth, 2)
        editing.commit()
        await workspace.lastTodoWrite?.value
        XCTAssertTrue(try String(contentsOf: doctor, encoding: .utf8).contains("    - [ ] bring the letter\n      - [ ] the blue one\n- [x] Book the taxi"))

        // Ticking a sub-to-do in the list; Undo takes it back.
        try await until { workspace.todos.items.first { $0.url == call.url }?.todo.lines.count == 3 }
        let edited = try XCTUnwrap(workspace.todos.items.first { $0.url == call.url })
        workspace.toggle(0, under: edited)
        await workspace.lastTodoWrite?.value
        XCTAssertTrue(try String(contentsOf: doctor, encoding: .utf8).contains("    - [x] ask about the results"))
        workspace.fileUndoManager.undo()
        try await until { (try? String(contentsOf: doctor, encoding: .utf8))?.contains("    - [ ] ask about the results") == true }

        // Lines that changed in the note meanwhile are left alone.
        try "# Doctor\n\n- [ ] Call Dr. Weber's office ⏰ 2026-10-24 14:00\n    - [ ] something else\n".write(to: doctor, atomically: true, encoding: .utf8)
        editing.title = "Call the office"
        editing.commit()
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(try String(contentsOf: doctor, encoding: .utf8), "# Doctor\n\n- [ ] Call Dr. Weber's office ⏰ 2026-10-24 14:00\n    - [ ] something else\n")
    }

    func testWhatIsTypedInATodoIsWrittenAsTheAppQuits() async throws {
        let workspace = try await makeWorkspace()
        let pack = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Pack the adapter" })
        let editing = TodoEditing(workspace: workspace, item: pack)
        workspace.todoEditing = editing
        editing.title = "Pack the adapter and its cable"
        workspace.saveAll(quitting: true)
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), "- [ ] Pack the adapter and its cable\n- [ ] Print the tickets 📅 2099-01-02\n")
    }

    func testEditingATodoInTheOpenNoteChangesItsEditor() async throws {
        let workspace = try await makeWorkspace()
        workspace.open(doctor)
        try await until { workspace.note?.isLoaded == true }
        let call = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call Dr. Weber" })
        let editing = TodoEditing(workspace: workspace, item: call)
        editing.addLineUnderTitle()
        editing.lines[0].words = "the letter"
        // Shift-Return on the words starts a line of the kind under them, a point here, before the others.
        editing.commit()
        XCTAssertEqual(workspace.editor.text, "# Doctor\n\n- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00\n    - the letter\n    - ask about the results\n- [x] Book the taxi\n")
        // A date set from its buttons in between keeps what is typed after it.
        workspace.moveTodo(editing.beforeChanging(), to: Calendar.current.date(from: DateComponents(year: 2099, month: 5, day: 6)))
        editing.title = "Call Dr. Weber again"
        editing.end()
        XCTAssertTrue(workspace.editor.text.hasPrefix("# Doctor\n\n- [ ] Call Dr. Weber again ⏰ 2099-05-06 14:00\n    - the letter\n"))
    }

    func testTodosAndNotesAreGroupedByWhenTheyAreDue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12)))
        func item(_ text: String, _ due: TodoDue?, place: TodoPlace? = nil) -> TodoList.Item {
            TodoList.Item(url: URL(fileURLWithPath: "/n/\(text).md"), note: text, modified: nil,
                          todo: Todo(line: 0, source: "- [ ] " + text, text: text, due: due, place: place))
        }
        let items = [
            item("late", TodoDue(year: 2026, month: 10, day: 23, hour: 9, minute: 0)),
            item("today", TodoDue(year: 2026, month: 10, day: 23)),
            item("tonight", TodoDue(year: 2026, month: 10, day: 23, hour: 20, minute: 0)),
            item("yesterday", TodoDue(year: 2026, month: 10, day: 22)),
            item("tomorrow", TodoDue(year: 2026, month: 10, day: 24, hour: 8, minute: 0)),
            item("week", TodoDue(year: 2026, month: 10, day: 30)),
            item("later", TodoDue(year: 2026, month: 10, day: 31)),
            item("someday", nil),
            item("pharmacy", nil, place: TodoPlace(name: "Pharmacy", latitude: 1, longitude: 2)),
        ]
        let note = NoteReminderRow(reminder: Reminder(id: UUID(), note: "n/Doctor.md", date: calendar.date(byAdding: .hour, value: 3, to: now)), url: nil, name: "Doctor")
        let sections = TodoGroups.sections(todos: items, notes: [note], now: now, calendar: calendar)
        func names(_ kind: TodoSection.Kind) -> [String] {
            sections.first { $0.kind == kind }?.rows.map { row in
                switch row {
                case .todo(let item): item.todo.text
                case .note(let note): note.name
                }
            } ?? []
        }
        XCTAssertEqual(sections.map(\.kind), [.overdue, .today, .tomorrow, .week, .later, .someday])
        XCTAssertEqual(names(.overdue), ["yesterday", "late"])
        XCTAssertEqual(names(.today), ["today", "Doctor", "tonight"], "a day without a time first, then by time")
        XCTAssertEqual(names(.tomorrow), ["tomorrow"])
        XCTAssertEqual(names(.week), ["week"])
        XCTAssertEqual(names(.later), ["later"])
        XCTAssertEqual(names(.someday), ["someday", "pharmacy"])
        XCTAssertNil(TodoSection.day(for: .overdue, now: now, calendar: calendar), "nothing can be dragged into Overdue")
        XCTAssertEqual(TodoSection.day(for: .tomorrow, now: now, calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))
        XCTAssertEqual(TodoSection.day(for: .someday, now: now, calendar: calendar), .some(nil))
    }

    func testNotificationsOfTodosWithAReminder() async throws {
        let workspace = try await makeWorkspace()
        let jobs = workspace.todoJobs()
        XCTAssertEqual(jobs.map(\.title).sorted(), ["Call Dr. Weber", "Print the tickets"])
        let call = try XCTUnwrap(jobs.first { $0.title == "Call Dr. Weber" })
        XCTAssertEqual(call.body, "• ask about the results")
        XCTAssertEqual(call.noteName, "Doctor")
        XCTAssertTrue(call.identifier.hasPrefix(ReminderNotifications.todoPrefix))
        XCTAssertEqual(call.subtitle(forPlace: false), TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0).date().formatted(date: .omitted, time: .shortened) + " · Doctor")
        let tickets = try XCTUnwrap(jobs.first { $0.title == "Print the tickets" })
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(tickets.date)), TodoDue.dayAlertHour, "a day without a time reminds in the morning")
        XCTAssertEqual(workspace.todoJobs().map(\.identifier), jobs.map(\.identifier), "the same each time")
    }

    /// Remind Me in 1 Hour puts a notification in at once, named as the to-do's own will be, so the two are one.
    func testRemindingAgainNamesTheNotificationAsTheTodoWillBe() async throws {
        let workspace = try await makeWorkspace()
        let call = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call Dr. Weber" })
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2099, month: 1, day: 2, hour: 15, minute: 30)))
        let later = workspace.remindOfTodoAgain(call.reference, at: date, notes: call.todo.notes.joined(separator: "\n"))
        await later.task?.value
        XCTAssertTrue(try String(contentsOf: doctor, encoding: .utf8).contains("- [ ] Call Dr. Weber ⏰ 2099-01-02 15:30"))
        try await until { workspace.todos.items.contains { $0.todo.text == "Call Dr. Weber" && $0.todo.due?.year == 2099 } }
        XCTAssertTrue(workspace.todoJobs().contains { $0.identifier == later.identifier })
    }

    /// A place reminds you once: what was waiting and isn't any more has come, and isn't scheduled again.
    func testAPlaceRemindsOnce() {
        let defaults = UserDefaults.standard
        defer { ["armedPlaces", "firedPlaces"].forEach(defaults.removeObject(forKey:)) }
        defaults.set(["todo.a.place", "todo.b.place", "reminder.X.place"], forKey: "armedPlaces")
        defaults.set([String](), forKey: "firedPlaces")
        // a came (it isn't waiting any more); b still waits; the note's place belongs to the other scheduling.
        XCTAssertEqual(ReminderNotifications.firedPlaces(prefix: "todo.", pending: ["todo.b.place"]), ["todo.a.place"])
        XCTAssertEqual(ReminderNotifications.firedPlaces(prefix: "reminder.", pending: ["reminder.X.place"]), [])
        XCTAssertEqual(ReminderNotifications.firedPlaces(prefix: "todo.", pending: []), ["todo.a.place", "todo.b.place"], "b has come since")
    }

    func testANoteReminderAtAPlace() async throws {
        let workspace = try await makeWorkspace()
        let pharmacy = TodoPlace(name: "Pharmacy", latitude: 52.52, longitude: 13.4, leaving: true)
        workspace.setReminder(for: doctor, at: nil, place: pharmacy)
        let reminder = try XCTUnwrap(workspace.reminder(for: doctor))
        XCTAssertNil(reminder.date)
        XCTAssertEqual(reminder.place, pharmacy)
        XCTAssertEqual(reminder.text, "Leaving Pharmacy")
        XCTAssertFalse(reminder.isOverdue)
        workspace.setReminder(for: doctor, at: nil, place: nil)
        XCTAssertNil(workspace.reminder(for: doctor), "neither a time nor a place: no reminder")
    }
}
