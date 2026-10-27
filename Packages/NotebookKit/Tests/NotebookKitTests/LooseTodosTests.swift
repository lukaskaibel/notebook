import XCTest
@testable import NotebookKit

/// To-dos in no note: added in To-dos, kept in a checklist of Notebook's own, listed and changed like any other, and
/// moved into a note from there.
@MainActor
final class LooseTodosTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }
    private var trip: URL { library.appendingPathComponent("Kyoto trip.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-loose-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "# Groceries\n\n- [ ] Bread\n    - wholemeal\n- [x] Eggs\n\nFrom the market on Saturday.\n".write(to: groceries, atomically: true, encoding: .utf8)
        try "- [ ] Pack the adapter\n".write(to: trip, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func makeWorkspace(loose text: String? = nil) async throws -> Workspace {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        if let text {
            let url = await workspace.looseTodos.fileURL()
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
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

    private func loose(_ workspace: Workspace) -> String? {
        workspace.looseTodos.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func testTodosInNoNoteAreListedAfterTheNotesOnes() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber\n- [x] Water the plants\n- [ ] Ask Mia about the bike\n")
        let texts = workspace.todos.items.map(\.todo.text)
        XCTAssertEqual(Array(texts.suffix(2)), ["Call the plumber", "Ask Mia about the bike"])
        let plumber = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Call the plumber" })
        XCTAssertTrue(plumber.isLoose)
        XCTAssertEqual(plumber.note, "")
        XCTAssertFalse(workspace.todos.items.first { $0.todo.text == "Bread" }?.isLoose ?? true)
        // Never a note: not in search, so not in the sidebar.
        XCTAssertNil(workspace.index.entry(for: plumber.url))

        // Ticked, it is done in its file, as in a note.
        await workspace.setTodoDone(plumber.reference, true)?.value
        XCTAssertEqual(loose(workspace)?.components(separatedBy: "\n").first, "- [x] Call the plumber")
        try await until { !workspace.todos.items.contains { $0.todo.text == "Call the plumber" } }

        // Changed somewhere else, by iCloud say, it is read again.
        let url = try XCTUnwrap(workspace.looseTodos.url)
        try "- [ ] Book a table\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.looseTodos.read()
        try await until { workspace.todos.items.contains { $0.todo.text == "Book a table" } }
        XCTAssertFalse(workspace.todos.items.contains { $0.todo.text == "Ask Mia about the bike" })
    }

    func testAddingATodoInNoNote() async throws {
        let workspace = try await makeWorkspace()
        XCTAssertNil(loose(workspace), "no file until there is a to-do in it")
        let today = Calendar.current.startOfDay(for: .now)
        let added = try XCTUnwrap(workspace.addTodo(due: today))
        // To-dos shows it at once, without words yet, due today.
        XCTAssertTrue(workspace.todos.items.contains { $0.id == added.id && $0.isLoose })
        XCTAssertEqual(added.todo.due, TodoDue(today, time: false))
        XCTAssertEqual(added.todo.text, "")
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(loose(workspace), "- [ ] \(TodoDue(today, time: false).markdown)\n")

        // What is typed in it goes into its line; one Undo takes it all away.
        let editing = TodoEditing(workspace: workspace, item: added)
        editing.added = .today
        editing.title = "Call the plumber"
        editing.commit()
        editing.title = "Call the plumber at 9"
        editing.commit()
        editing.title = "Call the plumber"
        editing.end()
        workspace.keepNewTodo(editing.current)
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber \(TodoDue(today, time: false).markdown)\n")
        let manager = workspace.fileUndoManager
        XCTAssertEqual(manager.undoActionName, "New To-do")
        manager.undo()
        try await until { loose(workspace) == "" }
        try await until { !workspace.todos.items.contains(where: \.isLoose) }
        // Redo brings it back as it was.
        manager.redo()
        try await until { loose(workspace) == "- [ ] Call the plumber \(TodoDue(today, time: false).markdown)\n" }
        try await until { workspace.todos.items.contains { $0.todo.text == "Call the plumber" } }

        // Another, without a date, goes after it; one after that, before either is read, has a line of its own.
        let second = try XCTUnwrap(workspace.addTodo(due: nil))
        let third = try XCTUnwrap(workspace.addTodo(due: nil))
        XCTAssertNotEqual(second.id, third.id)
        XCTAssertEqual(workspace.todos.items.filter(\.isLoose).count, 3)
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber \(TodoDue(today, time: false).markdown)\n- [ ]\n- [ ]\n")
    }

    func testNewTodosOneAfterAnother() async throws {
        let workspace = try await makeWorkspace()
        let today = Calendar.current.startOfDay(for: .now)
        let date = TodoDue(today, time: false).markdown
        // Return in the first starts the second, which says what the first said before it was typed in.
        let first = try XCTUnwrap(workspace.addTodo(due: today))
        let editing = TodoEditing(workspace: workspace, item: first)
        editing.added = .today
        editing.title = "Call the plumber"
        editing.end()
        workspace.keepNewTodo(editing.current)
        // Return is an event of its own: Undo takes back one at a time.
        try await Task.sleep(for: .milliseconds(50))
        let second = try XCTUnwrap(workspace.addTodo(due: today))
        XCTAssertEqual(workspace.current(second.reference).source, "- [ ] \(date)", "the second is not the first")
        let next = TodoEditing(workspace: workspace, item: second)
        next.added = .today
        next.title = "Buy milk"
        next.end()
        workspace.keepNewTodo(next.current)
        // Both show, each as typed, before the file is read again.
        XCTAssertEqual(Set(workspace.todos.items.filter(\.isLoose).map(\.todo.text)), ["Call the plumber", "Buy milk"])
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber \(date)\n- [ ] Buy milk \(date)\n")
        try await until { Set(workspace.todos.items.filter(\.isLoose).map(\.todo.text)) == ["Call the plumber", "Buy milk"] }
        // Undo takes away the last first.
        workspace.fileUndoManager.undo()
        try await until { self.loose(workspace) == "- [ ] Call the plumber \(date)\n" }
    }

    func testANewTodoStaysThroughAReadingBeforeItsLineWasWritten() async throws {
        let list = TodoList()
        let url = base.appendingPathComponent("To-dos.md")
        func read(_ text: String, at seconds: Int) async throws {
            list.update(loose: LooseTodos.Snapshot(url: url, text: text, modified: Date(timeIntervalSinceReferenceDate: Double(seconds))))
            try await until { list.items.contains { $0.todo.text == "Read \(seconds)" } || !text.contains("Read") }
        }
        list.update(entries: [:], hidden: [], built: true)
        try await read("- [ ] Call the plumber\n- [ ] Read 1\n", at: 1)
        let todo = try XCTUnwrap(TodoList.todo(["- [ ]"], line: 2))
        list.add(TodoList.Item(url: url, note: "", modified: nil, todo: todo, isLoose: true))
        XCTAssertEqual(list.items.count, 3)
        // A reading begun before its line was written, finished after: the file changed meanwhile, but not by it yet.
        try await read("- [ ] Call the plumber\n- [ ] Read 2\n", at: 2)
        XCTAssertEqual(list.items.map(\.todo.text), ["Call the plumber", "Read 2", ""], "still there")
        // The reading that has it takes over, without the row twice.
        try await read("- [ ] Call the plumber\n- [ ] Read 3\n- [ ]\n", at: 3)
        XCTAssertEqual(list.items.map(\.todo.text), ["Call the plumber", "Read 3", ""])
    }

    func testANewTodoLeftWithoutWordsGoes() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber\n")
        let manager = workspace.fileUndoManager
        let added = try XCTUnwrap(workspace.addTodo(due: nil))
        workspace.dropNewTodo(added.reference)
        XCTAssertFalse(workspace.todos.items.contains { $0.id == added.id })
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber\n")
        XCTAssertFalse(manager.canUndo, "nothing to undo")
    }

    func testMovingATodoIntoANote() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber\n- [ ] Butter\n    - the salted one\n")
        let butter = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Butter" })
        let task = workspace.moveTodo(butter.reference, toNote: groceries)
        // To-dos shows it under the note's name at once.
        let moved = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Butter" })
        XCTAssertFalse(moved.isLoose)
        XCTAssertEqual(moved.note, "Groceries")
        XCTAssertEqual(moved.todo.notes, ["• the salted one"])
        await task?.value
        // After the note's last to-do, with the lines under it, and gone from those in no note.
        XCTAssertEqual(try String(contentsOf: groceries, encoding: .utf8),
                       "# Groceries\n\n- [ ] Bread\n    - wholemeal\n- [x] Eggs\n- [ ] Butter\n    - the salted one\n\nFrom the market on Saturday.\n")
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber\n")
        try await until { workspace.todos.items.contains { $0.todo.text == "Butter" && $0.url == groceries.standardizedFileURL } }
        XCTAssertEqual(workspace.todos.items.filter { $0.todo.text == "Butter" }.count, 1)

        // One Undo puts it back where it was; Redo moves it again.
        let manager = workspace.fileUndoManager
        XCTAssertEqual(manager.undoActionName, "Move to Note")
        manager.undo()
        try await until { self.loose(workspace) == "- [ ] Call the plumber\n- [ ] Butter\n    - the salted one\n" }
        await workspace.lastTodoWrite?.value
        XCTAssertEqual(try String(contentsOf: groceries, encoding: .utf8), "# Groceries\n\n- [ ] Bread\n    - wholemeal\n- [x] Eggs\n\nFrom the market on Saturday.\n")
        try await until { workspace.todos.items.contains { $0.todo.text == "Butter" && $0.isLoose } }
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        try await until { self.loose(workspace) == "- [ ] Call the plumber\n" }
        await workspace.lastTodoWrite?.value
        XCTAssertTrue(try String(contentsOf: groceries, encoding: .utf8).contains("- [ ] Butter\n    - the salted one\n"))
    }

    func testMovingATodoIntoANoteOpenInTheEditor() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Rice\n")
        workspace.open(trip)
        try await until { workspace.note?.isLoaded == true }
        let rice = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Rice" })
        await workspace.moveTodo(rice.reference, toNote: trip)?.value
        // Written into its file, which the note open takes in as a change from elsewhere.
        try await until { workspace.editor.text == "- [ ] Pack the adapter\n- [ ] Rice\n" }
        XCTAssertEqual(loose(workspace), "")
    }

    func testUndoStraightAfterMovingATodo() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber\n- [ ] Butter\n")
        let butter = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Butter" })
        let original = try String(contentsOf: groceries, encoding: .utf8)
        workspace.moveTodo(butter.reference, toNote: groceries)
        // Undo before the move is written waits for it.
        try await Task.sleep(for: .milliseconds(30))
        let manager = workspace.fileUndoManager
        XCTAssertEqual(manager.undoActionName, "Move to Note")
        manager.undo()
        await workspace.todosWritten()
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber\n- [ ] Butter\n")
        XCTAssertEqual(try String(contentsOf: groceries, encoding: .utf8), original)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        await workspace.todosWritten()
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber\n")
        XCTAssertTrue(try String(contentsOf: groceries, encoding: .utf8).contains("- [ ] Butter\n"))
    }

    func testAMoveStoppedHalfwayLeavesTheTodoInBoth() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Butter\n")
        let butter = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Butter" })
        // Those in no note can't be written: it goes into the note first, and stays where it was too.
        let folder = try XCTUnwrap(workspace.looseTodos.url).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await workspace.moveTodo(butter.reference, toNote: groceries)?.value
        XCTAssertTrue(try String(contentsOf: groceries, encoding: .utf8).contains("- [ ] Butter\n"))
        XCTAssertEqual(loose(workspace), "- [ ] Butter\n")
        // Undo takes it out of the note again, where it is twice.
        workspace.fileUndoManager.undo()
        await workspace.todosWritten()
        XCTAssertFalse(try String(contentsOf: groceries, encoding: .utf8).contains("Butter"))
        XCTAssertEqual(loose(workspace), "- [ ] Butter\n")
    }

    #if os(macOS)
    /// A note open in a window of its own takes the move in from its file: Undo is To-dos', and the note's window has
    /// none that would take only half of it back.
    func testMovingATodoIntoANoteOpenInItsOwnWindow() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Rice\n")
        workspace.showTodos()
        FileWindows.shared.open(trip)
        let controller = try XCTUnwrap(FileWindows.shared.windows.compactMap { $0.windowController as? FileWindowController }.first { FileNode.samePath($0.url, trip) })
        defer { controller.window?.close() }
        try await until { controller.isLoaded }
        let rice = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Rice" })
        await workspace.moveTodo(rice.reference, toNote: trip)?.value
        try await until { controller.editor.text == "- [ ] Pack the adapter\n- [ ] Rice\n" }
        XCTAssertNotEqual(controller.window?.undoManager?.undoActionName, "Move to Note")
        try await Task.sleep(for: .milliseconds(30))
        workspace.fileUndoManager.undo()
        await workspace.todosWritten()
        try await until { controller.editor.text == "- [ ] Pack the adapter\n" }
        XCTAssertEqual(loose(workspace), "- [ ] Rice\n")
    }
    #endif

    func testAnUnreadableFileOfTodosDoesntHoldUpTheOthers() async throws {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        let url = await workspace.looseTodos.fileURL()
        try "- [ ] Call the plumber ⏰ 2099-01-02 09:30\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        workspace.start()
        // Ready without it: the notes' to-dos remind, and its own notifications are left as they are.
        try await until { !workspace.index.isBuilding && workspace.todos.isReady }
        XCTAssertTrue(workspace.todos.isLooseUnread)
        XCTAssertTrue(workspace.todos.items.contains { $0.todo.text == "Bread" })
        // Read once it can be.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        workspace.looseTodos.read()
        try await until { workspace.todos.items.contains { $0.todo.text == "Call the plumber" } }
        XCTAssertFalse(workspace.todos.isLooseUnread)
    }

    func testANewTodoWithoutWordsHasNoNotificationAndGoesAsTheAppQuits() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber\n")
        let added = try XCTUnwrap(workspace.addTodo(due: Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)))
        XCTAssertTrue(workspace.todos.items.contains { $0.id == added.id })
        XCTAssertFalse(workspace.todoJobs().contains { $0.path == added.url.path }, "no notification for it")
        let editing = TodoEditing(workspace: workspace, item: added)
        editing.added = .tomorrow
        workspace.todoEditing = editing
        workspace.saveAll(quitting: true)
        XCTAssertTrue(workspace.isWritingTodos, "quitting waits for it")
        await workspace.todosWritten()
        XCTAssertEqual(loose(workspace), "- [ ] Call the plumber\n")
    }

    func testTheOpenTodosOnlyAConflictingVersionHas() {
        let here = "- [ ] Call the plumber\n- [x] Buy milk ✅ 2026-10-27\n"
        let there = "- [ ] Call the plumber\n- [ ] Buy milk\n- [ ] Book a table\n    - for four\n- [x] Done there\n"
        // Book a table is only there; Buy milk was ticked here, and done ones stay done.
        XCTAssertEqual(LooseTodos.missingTodos(in: here, from: [there]), ["- [ ] Book a table", "    - for four"])
        XCTAssertEqual(LooseTodos.missingTodos(in: here, from: [there, "- [ ] Book a table\n- [ ] Third\n"]),
                       ["- [ ] Book a table", "    - for four", "- [ ] Third"])
        XCTAssertEqual(LooseTodos.missingTodos(in: there, from: [here]), [])
    }

    func testANoteThatIsGoneKeepsTheTodo() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Rice\n")
        let rice = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Rice" })
        try FileManager.default.removeItem(at: groceries)
        await workspace.moveTodo(rice.reference, toNote: groceries)?.value
        XCTAssertEqual(loose(workspace), "- [ ] Rice\n")
        try await until { workspace.todos.items.contains { $0.todo.text == "Rice" && $0.isLoose } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: groceries.path))
    }

    func testNotificationsOfTodosInNoNote() async throws {
        let workspace = try await makeWorkspace(loose: "- [ ] Call the plumber ⏰ 2099-01-02 09:30\n")
        let job = try XCTUnwrap(workspace.todoJobs().first { $0.source.contains("plumber") })
        XCTAssertEqual(job.title, "Call the plumber")
        XCTAssertEqual(job.noteName, "")
        // No note to name after the time.
        XCTAssertEqual(job.subtitle(forPlace: false), try XCTUnwrap(job.date).formatted(date: .omitted, time: .shortened))
    }
}
