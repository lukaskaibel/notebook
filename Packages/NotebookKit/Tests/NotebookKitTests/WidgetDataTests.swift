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

    /// The overdue ones and today's, and the coming week's for the widget to move on by itself; none without a date.
    func testTheTodosAreTodaysOverdueAndTheWeeksToCome() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
        let rows = workspace.widgetTodoRows()
        XCTAssertEqual(rows.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
        XCTAssertTrue(rows[0].isOverdue(at: .now))
        XCTAssertFalse(rows[1].isOverdue(at: .now))
        XCTAssertEqual(rows.filter { $0.isShown(at: .now) }.map(\.text), ["Dry cleaning", "Milk"])
        let inFiveDays = Calendar.current.date(byAdding: .day, value: 5, to: .now)!
        XCTAssertEqual(rows.filter { $0.isShown(at: inFiveDays) }.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
        workspace.publishWidgetTodos()
        XCTAssertEqual(WidgetData.todos?.rows.map(\.text), ["Dry cleaning", "Milk", "Dentist"])
    }

    /// A tick in the widget goes into the note as To-dos would write it, and leaves the widget's queue.
    func testATickFromTheWidgetIsWrittenIntoTheNote() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
        let milk = try XCTUnwrap(workspace.widgetTodoRows().first { $0.text == "Milk" })
        WidgetData.tick(milk)
        XCTAssertEqual(WidgetData.ticked.map(\.id), [milk.id])
        await workspace.takeWidgetTicks()
        let text = try String(contentsOf: errands, encoding: .utf8)
        XCTAssertTrue(text.contains("- [x] Milk"), text)
        XCTAssertTrue(text.contains("- [ ] Dry cleaning"), "another to-do was ticked")
        XCTAssertTrue(WidgetData.ticked.isEmpty)
    }

    /// A to-do changed since it was ticked in the widget is left as it is: nothing written over it.
    func testATickOfATodoThatChangedSinceIsDropped() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
        let milk = try XCTUnwrap(workspace.widgetTodoRows().first { $0.text == "Milk" })
        WidgetData.tick(milk)
        let changed = try String(contentsOf: errands, encoding: .utf8).replacingOccurrences(of: "Milk", with: "Oat milk")
        try changed.write(to: errands, atomically: true, encoding: .utf8)
        await workspace.takeWidgetTicks()
        XCTAssertEqual(try String(contentsOf: errands, encoding: .utf8), changed)
        XCTAssertTrue(WidgetData.ticked.isEmpty)
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
        let id = trip.path
        WidgetData.notes = [id: Workspace.widgetNote("Text", url: trip, place: "")]
        let renamed = library.appendingPathComponent("Travel/Japan.md")
        workspace.widgetNoteMoved(from: trip, to: renamed)
        XCTAssertEqual(WidgetData.notes[id]?.path, renamed.path)
        XCTAssertEqual(WidgetData.notes[id]?.title, "Japan")
        let moved = library.appendingPathComponent("Archive/Travel")
        workspace.widgetNoteMoved(from: library.appendingPathComponent("Travel"), to: moved)
        XCTAssertEqual(WidgetData.notes[id]?.path, moved.appendingPathComponent("Japan.md").path)
    }

    /// The links a tap in a widget opens.
    func testATapOpensTheNoteOrTheTodo() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the to-dos were read", seconds: 20) { workspace.todos.isReady && workspace.todos.items.contains { $0.todo.text == "Milk" } }
        WidgetData.notes = [trip.path: Workspace.widgetNote("Text", url: trip, place: "")]
        XCTAssertTrue(workspace.openFromWidget(WidgetData.url(note: trip.path)))
        try await until("the note opened") { workspace.currentURL.map { FileNode.samePath($0, self.trip) } == true }
        let milk = try XCTUnwrap(workspace.widgetTodoRows().first { $0.text == "Milk" })
        XCTAssertTrue(workspace.openFromWidget(WidgetData.url(todo: milk)))
        try await until("the to-do's note opened") { workspace.currentURL.map { FileNode.samePath($0, self.errands) } == true }
        XCTAssertTrue(workspace.openFromWidget(WidgetData.todosURL))
        try await until("To-dos opened") { workspace.showsTodos }
        XCTAssertFalse(workspace.openFromWidget(URL(string: "https://example.com")!))
    }
}
