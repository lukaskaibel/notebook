import NotebookCapture
import XCTest
@testable import NotebookKit

/// What the app keeps for the widgets: today's and the overdue to-dos, the ticks that come back from the To-dos
/// widget, and notes as the Note widget shows them, following renames and moves.
@MainActor
final class WidgetDataTests: XCTestCase {
    private var library: URL!
    private var errands: URL { library.appendingPathComponent("Errands.md") }
    private var trip: URL { library.appendingPathComponent("Travel/Kyoto trip.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-widgets-\(UUID().uuidString)").standardizedFileURL
        library = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Travel"), withIntermediateDirectories: true)
        let today = TodoDue(.now, time: false).markdown
        let yesterday = TodoDue(Calendar.current.date(byAdding: .day, value: -1, to: .now)!, time: false).markdown
        let nextWeek = TodoDue(Calendar.current.date(byAdding: .day, value: 5, to: .now)!, time: false).markdown
        let later = TodoDue(Calendar.current.date(byAdding: .day, value: 20, to: .now)!, time: false).markdown
        try """
        - [ ] Dry cleaning \(yesterday)
        - [ ] Milk \(today)
        - [ ] Dentist \(nextWeek)
        - [ ] Passport renewal \(later)
        - [ ] Someday
        """.write(to: errands, atomically: true, encoding: .utf8)
        try """
        # Kyoto trip

        Five days in **October**, see [[Budget]].

        ## Packing
        - [x] Passport
        - [ ] Power adapter
          - Type A

        > Bring cash.
        """.write(to: trip, atomically: true, encoding: .utf8)
        WidgetData.folder = root.appendingPathComponent("Widgets")
        // No widgets run here to say which notes they show.
        WidgetKeeping.askWidgets = { $0(nil) }
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders"] { UserDefaults.standard.removeObject(forKey: key) }
        window?.close()
        WidgetData.folder = nil
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    private func makeWorkspace() -> Workspace {
        let workspace = Workspace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = workspace.editor.view
        return workspace
    }

    private func until(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func readTodos(_ workspace: Workspace) async throws {
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
    }

    private func row(_ text: String, in workspace: Workspace) throws -> WidgetData.TodoRow {
        try XCTUnwrap(workspace.widgetTodoRows().first { $0.text == text })
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// The overdue ones and today's, and the coming week's for the widget to move on by itself; none without a date.
    func testTheTodosAreTodaysOverdueAndTheWeeksToCome() async throws {
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        let rows = workspace.widgetTodoRows()
        XCTAssertEqual(rows.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
        XCTAssertTrue(rows[0].isOverdue(at: .now))
        XCTAssertFalse(rows[1].isOverdue(at: .now))
        XCTAssertEqual(rows.filter { $0.isShown(at: .now) }.map(\.text), ["Dry cleaning", "Milk"])
        let inFiveDays = Calendar.current.date(byAdding: .day, value: 5, to: .now)!
        XCTAssertEqual(rows.filter { $0.isShown(at: inFiveDays) }.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
        XCTAssertNotNil(rows[1].modified, "without when the note changed")
        workspace.publishWidgetTodos()
        workspace.widgets.written()
        XCTAssertEqual(WidgetData.todos?.rows.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
    }

    /// Many overdue: the oldest are listed, the others only counted.
    func testOverdueToDosAreCapped() {
        let day: TimeInterval = 86400
        let rows = (0..<70).map { offset in
            WidgetData.TodoRow(kind: .todo, text: "Old \(offset)", path: "/Old.md", note: "Old", line: offset, source: "- [ ] Old \(offset)",
                               due: Date.now.addingTimeInterval(-Double(100 - offset) * day), hasTime: false)
        } + [WidgetData.TodoRow(kind: .todo, text: "Today", path: "/Old.md", note: "Old", line: 99, source: "- [ ] Today",
                                due: Calendar.current.startOfDay(for: .now), hasTime: false)]
        let todos = Workspace.widgetTodos(rows, isComplete: true)
        XCTAssertEqual(todos.rows.count, Workspace.widgetOverdueLimit + 1)
        XCTAssertEqual(todos.rows.first?.text, "Old 0")
        XCTAssertEqual(todos.rows.last?.text, "Today")
        XCTAssertEqual(todos.overdueLeftOut, 70 - Workspace.widgetOverdueLimit)
    }

    /// A tick in the widget goes into the note as To-dos would write it, and leaves the widget's queue.
    func testATickFromTheWidgetIsWrittenIntoTheNote() async throws {
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        let milk = try row("Milk", in: workspace)
        XCTAssertTrue(WidgetData.toggleTick(milk).ticked)
        XCTAssertEqual(WidgetData.ticks.map(\.row.id), [milk.id])
        await workspace.takeWidgetTicks()
        let text = try read(errands)
        XCTAssertTrue(text.contains("- [x] Milk"), text)
        XCTAssertTrue(text.contains("- [ ] Dry cleaning"), "another to-do was ticked")
        XCTAssertTrue(WidgetData.ticks.isEmpty)
    }

    /// A mis-tap is taken back with another, as long as Notebook hasn't written it: nothing is written.
    func testATickIsTakenBackBeforeItIsWritten() async throws {
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        let milk = try row("Milk", in: workspace)
        let before = try read(errands)
        WidgetData.toggleTick(milk)
        XCTAssertFalse(WidgetData.toggleTick(milk).ticked)
        XCTAssertTrue(WidgetData.ticks.isEmpty)
        await workspace.takeWidgetTicks()
        XCTAssertEqual(try read(errands), before)
    }

    /// A tick that can't be written now waits, its notification kept away meanwhile, and is written the next time.
    func testATickThatCantBeWrittenWaits() async throws {
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        let milk = try row("Milk", in: workspace)
        let jobs = workspace.todoJobs()
        XCTAssertTrue(jobs.contains { $0.source == milk.source })
        WidgetData.toggleTick(milk)
        XCTAssertEqual(chmod(errands.path, 0o000), 0)
        await workspace.takeWidgetTicks()
        XCTAssertEqual(chmod(errands.path, 0o644), 0)
        XCTAssertEqual(WidgetData.ticks.map(\.row.id), [milk.id], "the tick was lost")
        XCTAssertFalse(try read(errands).contains("- [x] Milk"))
        XCTAssertFalse(workspace.withoutWidgetTicks(jobs).contains { $0.source == milk.source }, "its notification came back")
        await workspace.takeWidgetTicks()
        XCTAssertTrue(try read(errands).contains("- [x] Milk"))
        XCTAssertTrue(WidgetData.ticks.isEmpty)
    }

    /// A to-do changed since it was ticked in the widget is left as it is, nothing written over it, and you're told.
    func testATickOfATodoThatChangedSinceIsDropped() async throws {
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        let milk = try row("Milk", in: workspace)
        WidgetData.toggleTick(milk)
        let changed = try read(errands).replacingOccurrences(of: "Milk", with: "Oat milk")
        try changed.write(to: errands, atomically: true, encoding: .utf8)
        await workspace.takeWidgetTicks()
        XCTAssertEqual(try read(errands), changed)
        XCTAssertTrue(WidgetData.ticks.isEmpty)
        try await until("the alert") { window?.attachedSheet != nil }
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
    }

    /// A to-do that repeats, ticked on another device before Notebook ran here: when its next one says what it said, it
    /// isn't ticked as well, and as it was done, there is nothing to tell.
    func testATickOfARepeatingTodoDoneElsewhereIsntDoubled() async throws {
        let tomorrow = TodoDue(Calendar.current.date(byAdding: .day, value: 1, to: .now)!, time: false).markdown
        let water = "- [ ] Water the plants 🔁 every day when done \(tomorrow)"
        try (try read(errands) + "\n" + water + "\n").write(to: errands, atomically: true, encoding: .utf8)
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        try await until("the plants were read") { workspace.todos.items.contains { $0.todo.text == "Water the plants" } }
        let plants = try row("Water the plants", in: workspace)
        WidgetData.toggleTick(plants)
        // Ticked on the Mac: the next one, due the same day, in its place, the one done under it.
        let ticked = try XCTUnwrap(Todos.marking(water, as: .done, today: .today))
        XCTAssertEqual(ticked.next, water)
        let elsewhere = try read(errands).replacingOccurrences(of: water, with: water + "\n" + ticked.line)
        try await Task.sleep(for: .milliseconds(20))
        try elsewhere.write(to: errands, atomically: true, encoding: .utf8)
        await workspace.takeWidgetTicks()
        XCTAssertEqual(try read(errands), elsewhere, "ticked twice")
        XCTAssertTrue(WidgetData.ticks.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(window?.attachedSheet, "told about a to-do that was done")
    }

    /// Ticked in the widget and written, a to-do that repeats gets its next one, as in To-dos.
    func testATickOfARepeatingTodoMakesTheNextOne() async throws {
        let tomorrow = TodoDue(Calendar.current.date(byAdding: .day, value: 1, to: .now)!, time: false).markdown
        let water = "- [ ] Water the plants 🔁 every day when done \(tomorrow)"
        try (try read(errands) + "\n" + water + "\n").write(to: errands, atomically: true, encoding: .utf8)
        let workspace = makeWorkspace()
        try await readTodos(workspace)
        try await until("the plants were read") { workspace.todos.items.contains { $0.todo.text == "Water the plants" } }
        WidgetData.toggleTick(try row("Water the plants", in: workspace))
        await workspace.takeWidgetTicks()
        let lines = try read(errands).components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex(of: water), "no next one")
        XCTAssertTrue(lines[index + 1].hasPrefix("- [x] Water the plants"), lines.joined(separator: "\n"))
    }

    /// The note's lines with their styles: the heading with its name left out, a link's words, done and open to-dos,
    /// a point under one, a quote.
    func testANoteAsTheWidgetShowsIt() throws {
        let note = Workspace.widgetNote(try String(contentsOf: trip, encoding: .utf8), url: trip, place: "Notes › Travel")
        XCTAssertEqual(note.title, "Kyoto trip")
        XCTAssertEqual(note.blocks.map(\.kind), [.text, .heading(2), .todo(done: true), .todo(done: false), .bullet, .quote])
        XCTAssertEqual(note.blocks[0].runs, [WidgetData.Run("Five days in "), WidgetData.Run("October", bold: true),
                                             WidgetData.Run(", see "), WidgetData.Run("Budget", link: true), WidgetData.Run(".")])
        XCTAssertEqual(note.blocks[4].depth, 1)
        XCTAssertEqual(note.blocks[5].runs.map(\.text).joined(), "Bring cash.")
        XCTAssertFalse(note.isCut)
    }

    func testALongNoteIsCut() {
        let long = (1...100).map { "Line \($0)" }.joined(separator: "\n\n")
        let note = Workspace.widgetNote(long, url: trip, place: "")
        XCTAssertEqual(note.blocks.count, Workspace.widgetNoteLines)
        XCTAssertTrue(note.isCut)
    }

    /// Renamed or moved in Notebook, a note chosen in a widget is still the one it shows.
    func testAChosenNoteFollowsARenameAndAMove() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        let id = WidgetData.noteID(path: trip.path, created: .now)
        workspace.widgetNotes = [id: Workspace.widgetNote("Text", url: trip, place: "")]
        let renamed = library.appendingPathComponent("Travel/Japan.md")
        workspace.widgetNoteMoved(from: trip, to: renamed)
        workspace.widgets.written()
        XCTAssertEqual(WidgetData.notes[id]?.path, renamed.path)
        XCTAssertEqual(WidgetData.notes[id]?.title, "Japan")
        let moved = library.appendingPathComponent("Archive/Travel")
        workspace.widgetNoteMoved(from: library.appendingPathComponent("Travel"), to: moved)
        workspace.widgets.written()
        XCTAssertEqual(WidgetData.notes[id]?.path, moved.appendingPathComponent("Japan.md").path)
    }

    /// A rename while the note is being read for the widget isn't lost: it is read again where it is now. When the
    /// widgets can't say which notes they show, none goes; when they can, the others do.
    func testARenameWhileReadingIsKept() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        let id = WidgetData.noteID(path: trip.path, created: .now), other = WidgetData.noteID(path: errands.path, created: .now)
        workspace.widgetNotes = [id: Workspace.widgetNote("Text", url: trip, place: ""), other: Workspace.widgetNote("Milk", url: errands, place: "")]
        let holding = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
        let trip = trip
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(writingItemAt: trip, options: [], error: nil) { _ in
                held.signal()
                holding.wait()
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { held.wait(); continuation.resume() } }
        workspace.renderWidgetNotes(nil)
        try await Task.sleep(for: .milliseconds(100))
        let renamed = library.appendingPathComponent("Travel/Japan.md")
        try FileManager.default.moveItem(at: trip, to: renamed)
        workspace.widgetNoteMoved(from: trip, to: renamed)
        holding.signal()
        try await until("read again where it is") { workspace.widgetNotes[id]?.blocks.contains { $0.runs.first?.text == "Five days in " } == true }
        XCTAssertEqual(workspace.widgetNotes[id]?.path, renamed.path)
        XCTAssertNotNil(workspace.widgetNotes[other], "went though the widgets couldn't say")
        workspace.renderWidgetNotes([id])
        try await until("the other went") { workspace.widgetNotes[other] == nil }
        XCTAssertEqual(workspace.widgetNotes[id]?.path, renamed.path)
    }

    /// A note chosen in a widget that is thrown away, outside the locations, or in a folder you hid isn't shown; back
    /// again, it is.
    func testAGoneOrHiddenNoteIsntShown() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        let id = WidgetData.noteID(path: trip.path, created: .now)
        workspace.widgetNotes = [id: Workspace.widgetNote("Text", url: trip, place: "")]
        workspace.widgetNoteThrownAway(library.appendingPathComponent("Travel"))
        XCTAssertEqual(workspace.widgetNotes[id]?.missing, .gone)
        XCTAssertEqual(workspace.widgetNotes[id]?.title, "")
        workspace.renderWidgetNotes([id])
        try await until("shown again") { workspace.widgetNotes[id]?.missing == nil && workspace.widgetNotes[id]?.title == "Kyoto trip" }
        workspace.setHidden(library.appendingPathComponent("Travel"), true)
        defer { workspace.setHidden(library.appendingPathComponent("Travel"), false) }
        workspace.renderWidgetNotes([id])
        try await until("hidden") { workspace.widgetNotes[id]?.missing == .hidden }
        XCTAssertTrue(workspace.widgetNotes[id]?.blocks.isEmpty == true)
        XCTAssertTrue(workspace.openFromWidget(WidgetData.url(note: id)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(workspace.currentURL, "a hidden note opened")
    }

    /// Edit Widget offers no note in a folder you hid, and gives a new note at an old one's path an ID of its own.
    func testTheNotesToChooseFrom() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations && workspace.index.entry(for: trip) != nil }
        workspace.publishWidgetCatalog()
        try await until("the catalog") { WidgetData.catalog.contains { $0.title == "Kyoto trip" } }
        let first = try XCTUnwrap(WidgetData.catalog.first { $0.title == "Kyoto trip" })
        XCTAssertEqual(WidgetData.notePath(id: first.id), trip.path)
        try FileManager.default.removeItem(at: trip)
        try await Task.sleep(for: .milliseconds(1100))
        try "New".write(to: trip, atomically: true, encoding: .utf8)
        workspace.setHidden(library.appendingPathComponent("Travel"), true)
        defer { workspace.setHidden(library.appendingPathComponent("Travel"), false) }
        workspace.publishWidgetCatalog()
        try await until("the hidden note left") { !WidgetData.catalog.contains { $0.title == "Kyoto trip" } }
        workspace.setHidden(library.appendingPathComponent("Travel"), false)
        workspace.index.refresh(folders: [trip.deletingLastPathComponent()], locations: workspace.locations)
        try await until("read again") { workspace.index.entry(for: self.trip) != nil }
        workspace.publishWidgetCatalog()
        try await until("back") { WidgetData.catalog.contains { $0.title == "Kyoto trip" } }
        XCTAssertNotEqual(WidgetData.catalog.first { $0.title == "Kyoto trip" }?.id, first.id, "the new note has the old one's ID")
    }

    /// Emoji stay whole, a done to-do isn't struck through and a cancelled one is, as in the editor.
    func testEmojiAndMarksInANote() {
        let note = Workspace.widgetNote("Plan 🇯🇵 trip 👍🏽 **ok** 🙂\n\n- [x] Booked\n- [-] Train", url: trip, place: "")
        XCTAssertEqual(note.blocks[0].runs, [WidgetData.Run("Plan 🇯🇵 trip 👍🏽 "), WidgetData.Run("ok", bold: true), WidgetData.Run(" 🙂")])
        XCTAssertEqual(note.blocks[1].kind, .todo(done: true))
        XCTAssertEqual(note.blocks[1].runs, [WidgetData.Run("Booked")])
        XCTAssertEqual(note.blocks[2].runs, [WidgetData.Run("Train", struck: true)])
    }

    /// The links a tap in a widget opens.
    func testATapOpensTheNoteOrTheTodo() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
        let id = WidgetData.noteID(path: trip.path, created: .now)
        workspace.widgetNotes = [id: Workspace.widgetNote("Text", url: trip, place: "")]
        XCTAssertTrue(workspace.openFromWidget(WidgetData.url(note: id)))
        try await until("the note opened") { workspace.currentURL.map { FileNode.samePath($0, self.trip) } == true }
        let milk = try row("Milk", in: workspace)
        XCTAssertTrue(workspace.openFromWidget(WidgetData.url(todo: milk)))
        try await until("the to-do's note opened") { workspace.currentURL.map { FileNode.samePath($0, self.errands) } == true }
        XCTAssertTrue(workspace.openFromWidget(WidgetData.todosURL))
        try await until("To-dos opened") { workspace.showsTodos }
        XCTAssertFalse(workspace.openFromWidget(URL(string: "https://example.com")!))
    }
}
