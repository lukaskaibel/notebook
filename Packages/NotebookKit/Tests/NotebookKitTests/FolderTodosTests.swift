import XCTest
@testable import NotebookKit

/// To-dos limited to a folder and the folders in it: what it lists, how it is reached and left, what happens to it when
/// the folder changes, and where a to-do added there goes.
@MainActor
final class FolderTodosTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    private var year: URL { library.appendingPathComponent("2027") }
    private var roth: URL { year.appendingPathComponent("Challenge Roth 2027") }
    private var logistics: URL { roth.appendingPathComponent("Logistics.md") }
    private var plan: URL { year.appendingPathComponent("Season plan.md") }
    private var older: URL { library.appendingPathComponent("2027 old/Leftovers.md") }
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }
    private var yearNote: URL { year.appendingPathComponent("To-dos.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-folder-todos-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: roth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: older.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] Book the hotel\n".write(to: logistics, atomically: true, encoding: .utf8)
        try "# Season\n\n- [ ] Plan the build-up\n- [x] Pick the races\n\nAfter the list.\n".write(to: plan, atomically: true, encoding: .utf8)
        try "- [ ] Sell the old wheels\n".write(to: older, atomically: true, encoding: .utf8)
        try "- [ ] Bread\n".write(to: groceries, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func makeWorkspace() async throws -> Workspace {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        let url = await workspace.looseTodos.fileURL()
        try "- [ ] Call the plumber\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.start()
        try await until { !workspace.index.isBuilding && workspace.todos.isReady && workspace.todos.items.count == 5 }
        return workspace
    }

    private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition(), Date() < end {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func listed(_ workspace: Workspace) -> [String] {
        TodoGroups.sections(todos: workspace.todos.items, notes: [], in: workspace.todosFolder)
            .flatMap(\.rows).compactMap { row in
                if case .todo(let item) = row { item.todo.text } else { nil }
            }.sorted()
    }

    private func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    // MARK: - What it lists

    func testItListsTheFolderAndTheFoldersInItOnly() async throws {
        let workspace = try await makeWorkspace()
        XCTAssertEqual(listed(workspace), ["Book the hotel", "Bread", "Call the plumber", "Plan the build-up", "Sell the old wheels"])
        workspace.showTodos(in: year)
        // Not "2027 old", whose name starts the same; not those in no note, which are in no folder.
        XCTAssertEqual(listed(workspace), ["Book the hotel", "Plan the build-up"])
        workspace.showTodos(in: roth)
        XCTAssertEqual(listed(workspace), ["Book the hotel"])
    }

    func testNotesWithARemindersAreInTheirFolder() {
        let reminder = Reminder(id: UUID(), note: "Logistics", date: .now)
        let inside = NoteReminderRow(reminder: reminder, url: logistics, name: "Logistics")
        let outside = NoteReminderRow(reminder: reminder, url: groceries, name: "Groceries")
        let nowhere = NoteReminderRow(reminder: reminder, url: nil, name: "Gone")
        XCTAssertTrue(TodoRow.note(inside).isInside(year))
        XCTAssertFalse(TodoRow.note(outside).isInside(year))
        XCTAssertFalse(TodoRow.note(nowhere).isInside(year))
    }

    func testARowSaysWhereItIsUnderTheFolder() throws {
        let todo = try XCTUnwrap(TodoList.todo(["- [ ] Book the hotel"], line: 0))
        let item = TodoList.Item(url: logistics, note: "Logistics", modified: nil, todo: todo)
        XCTAssertEqual(item.place(under: year), "Challenge Roth 2027 › Logistics")
        XCTAssertEqual(item.place(under: library), "2027 › Challenge Roth 2027 › Logistics")
        XCTAssertEqual(item.place(under: roth), "Logistics", "right in the folder: only its note")
    }

    // MARK: - Getting there and back

    func testAPlaceInTheHistoryKeepsAnyFolderName() {
        for name in ["2027", "Café & Co", "50% done?", "a+b #1", "Ünï/Söme"] {
            let folder = library.appendingPathComponent(name, isDirectory: true)
            let list = Workspace.todosURL(in: folder)
            XCTAssertTrue(Workspace.isTodos(list), name)
            XCTAssertTrue(Workspace.isList(list), name)
            XCTAssertEqual(Workspace.todosFolder(of: list)?.path, folder.path, name)
        }
        XCTAssertEqual(Workspace.todosURL(in: nil), Workspace.todosURL)
        XCTAssertNil(Workspace.todosFolder(of: Workspace.todosURL))
        XCTAssertNil(Workspace.todosFolder(of: groceries))
        XCTAssertFalse(Workspace.isTodos(Workspace.favoritesURL))
    }

    func testTheTileShowsEveryTodoAndTheCrossTakesNoStep() async throws {
        let workspace = try await makeWorkspace()
        workspace.open(groceries)
        workspace.showTodos(in: year)
        XCTAssertTrue(workspace.showsTodos)
        XCTAssertEqual(workspace.currentTitle, "To-dos in 2027")
        // × : every to-do, and Back goes where it would have gone.
        workspace.stopLimitingTodos()
        XCTAssertNil(workspace.todosFolder)
        XCTAssertEqual(workspace.currentTitle, "To-dos")
        XCTAssertEqual(workspace.history.last, Workspace.todosURL)
        workspace.goBack()
        XCTAssertEqual(workspace.currentURL, groceries)
        // The tile, ⇧⌘R, ⌘K: every to-do, also from a folder's list.
        workspace.showTodos(in: year)
        workspace.showTodos()
        XCTAssertTrue(workspace.showsTodos)
        XCTAssertNil(workspace.todosFolder)
    }

    func testBackFromANoteComesBackToTheFoldersList() async throws {
        let workspace = try await makeWorkspace()
        workspace.showTodos(in: year)
        workspace.open(logistics)
        XCTAssertFalse(workspace.showsTodos)
        workspace.goBack()
        XCTAssertTrue(workspace.showsTodos)
        XCTAssertEqual(workspace.todosFolder?.path, year.path)
        workspace.showTodos(in: roth)
        workspace.goBack()
        XCTAssertEqual(workspace.todosFolder?.path, year.path, "another folder's list is a step of its own")
        workspace.goForward()
        XCTAssertEqual(workspace.todosFolder?.path, roth.path)
    }

    func testNothingShowsWithToDosTurnedOff() async throws {
        let workspace = try await makeWorkspace()
        NotebookSettings.shared.showsTodos = false
        defer { NotebookSettings.shared.showsTodos = true }
        workspace.showTodos(in: year)
        XCTAssertFalse(workspace.showsTodos)
        XCTAssertNil(workspace.todosFolder)
    }

    // MARK: - When the folder changes

    func testItFollowsTheFolderRenamed() async throws {
        let workspace = try await makeWorkspace()
        workspace.showTodos(in: roth)
        workspace.open(groceries)
        workspace.goBack()
        let renamed = year.appendingPathComponent("Roth")
        workspace.replacePath(roth, with: renamed)
        XCTAssertEqual(workspace.todosFolder?.path, renamed.path)
        XCTAssertEqual(workspace.history[workspace.historyIndex], Workspace.todosURL(in: renamed))
        // And a folder it is in.
        let moved = library.appendingPathComponent("Next year")
        workspace.replacePath(year, with: moved)
        XCTAssertEqual(workspace.todosFolder?.path, moved.appendingPathComponent("Roth").path)
    }

    func testItListsEveryTodoOnceTheFolderIsGone() async throws {
        let workspace = try await makeWorkspace()
        workspace.showTodos(in: roth)
        try FileManager.default.removeItem(at: roth)
        workspace.checkTodosFolder()
        try await until { workspace.todosFolder == nil }
        XCTAssertTrue(workspace.showsTodos)
        XCTAssertEqual(workspace.history[workspace.historyIndex], Workspace.todosURL)
    }

    func testItListsEveryTodoOnceTheFolderIsHidden() async throws {
        let workspace = try await makeWorkspace()
        workspace.showTodos(in: year)
        workspace.index.hiddenPaths = [year.path]
        workspace.checkTodosFolder()
        XCTAssertNil(workspace.todosFolder)
        try await until { !workspace.todos.items.contains { $0.todo.text == "Book the hotel" } }
    }

    // MARK: - Adding

    func testANewTodoGoesIntoANoteMadeInTheFolder() async throws {
        let workspace = try await makeWorkspace()
        workspace.showTodos(in: year)
        let added = try XCTUnwrap(workspace.addTodo(due: today, in: year))
        XCTAssertTrue(FileNode.samePath(added.url, yearNote))
        XCTAssertEqual(added.note, "To-dos")
        XCTAssertTrue(TodoRow.todo(added).isInside(year))
        XCTAssertTrue(workspace.todos.items.contains { $0.id == added.id }, "it shows at once")
        await workspace.todosWritten()
        XCTAssertEqual(text(yearNote), added.todo.source + "\n")

        // Typed in, it says so in the note, and the next goes under it.
        let typed = added.todo.source.replacingOccurrences(of: "- [ ]", with: "- [ ] Renew the licence")
        workspace.changeTodoLines(added.reference, from: [added.todo.source], to: [typed], actionName: "Edit To-do", undoable: false)
        await workspace.todosWritten()
        let next = try XCTUnwrap(workspace.addTodo(due: nil, in: year))
        XCTAssertEqual(next.todo.line, 1)
        await workspace.todosWritten()
        XCTAssertEqual(text(yearNote), typed + "\n- [ ]\n")
        try await until { workspace.index.entry(for: yearNote) != nil && workspace.todos.items.contains { $0.todo.text == "Renew the licence" && !$0.isLoose } }
        XCTAssertTrue(listed(workspace).contains("Renew the licence"))
    }

    func testANewTodoGoesAfterTheChecklistOfTheNoteThere() async throws {
        let workspace = try await makeWorkspace()
        try "Kit for the year.\n\n* [ ] Service the bike\n\nLast words.\n".write(to: yearNote, atomically: true, encoding: .utf8)
        workspace.index.refresh(folders: [year], locations: workspace.locations)
        try await until { workspace.todos.items.contains { $0.todo.text == "Service the bike" } }
        let added = try XCTUnwrap(workspace.addTodo(due: nil, in: year))
        XCTAssertEqual(added.todo.source, "* [ ]", "the checklist's bullet")
        XCTAssertEqual(added.todo.line, 3)
        await workspace.todosWritten()
        XCTAssertEqual(text(yearNote), "Kit for the year.\n\n* [ ] Service the bike\n* [ ]\n\nLast words.\n")
    }

    func testANewTodoLeftWithoutWordsTakesTheNoteMadeForItAlong() async throws {
        let workspace = try await makeWorkspace()
        let added = try XCTUnwrap(workspace.addTodo(due: today, in: year))
        await workspace.todosWritten()
        XCTAssertTrue(FileManager.default.fileExists(atPath: yearNote.path))
        workspace.dropNewTodo(added.reference)
        await workspace.todosWritten()
        XCTAssertFalse(FileManager.default.fileExists(atPath: yearNote.path))
        XCTAssertFalse(workspace.todos.items.contains { FileNode.samePath($0.url, yearNote) })
    }

    func testANewTodoLeftWithoutWordsLeavesANoteWithSomethingInIt() async throws {
        let workspace = try await makeWorkspace()
        try "- [ ] Service the bike\n".write(to: yearNote, atomically: true, encoding: .utf8)
        workspace.index.refresh(folders: [year], locations: workspace.locations)
        try await until { workspace.todos.items.contains { $0.todo.text == "Service the bike" } }
        let added = try XCTUnwrap(workspace.addTodo(due: nil, in: year))
        await workspace.todosWritten()
        workspace.dropNewTodo(added.reference)
        await workspace.todosWritten()
        XCTAssertEqual(text(yearNote), "- [ ] Service the bike\n")
    }

    #if os(macOS)
    func testANewTodoGoesIntoTheNoteOpenInItsOwnWindow() async throws {
        let workspace = try await makeWorkspace()
        try "- [ ] Service the bike\n".write(to: yearNote, atomically: true, encoding: .utf8)
        workspace.index.refresh(folders: [year], locations: workspace.locations)
        try await until { workspace.todos.items.contains { $0.todo.text == "Service the bike" } }
        workspace.showTodos(in: year)
        FileWindows.shared.open(yearNote)
        let controller = try XCTUnwrap(FileWindows.shared.windows.compactMap { $0.windowController as? FileWindowController }.first { FileNode.samePath($0.url, yearNote) })
        defer { controller.window?.close() }
        try await until { controller.isLoaded }
        let added = try XCTUnwrap(workspace.addTodo(due: nil, in: year))
        XCTAssertEqual(controller.editor.text, "- [ ] Service the bike\n- [ ]\n", "there at once, for what is typed next")
        XCTAssertEqual(added.todo.line, 1)
        workspace.dropNewTodo(added.reference)
        XCTAssertEqual(controller.editor.text, "- [ ] Service the bike\n")
        await workspace.todosWritten()
        XCTAssertTrue(FileManager.default.fileExists(atPath: yearNote.path))
    }
    #endif

    func testANewTodoBeingAddedHasNoNotificationYet() async throws {
        let workspace = try await makeWorkspace()
        let added = try XCTUnwrap(workspace.addTodo(due: today, in: year))
        let editing = TodoEditing(workspace: workspace, item: added)
        editing.added = .today
        workspace.todoEditing = editing
        XCTAssertTrue(workspace.isBeingAdded(added))
        XCTAssertFalse(workspace.todoJobs().contains { FileNode.samePath(URL(fileURLWithPath: $0.path), yearNote) })
        XCTAssertFalse(workspace.widgetTodoRows().contains { FileNode.samePath(URL(fileURLWithPath: $0.path), yearNote) })
        workspace.todoEditing = nil
        XCTAssertFalse(workspace.isBeingAdded(added))
        withExtendedLifetime(editing) {}
        await workspace.todosWritten()
    }
}
