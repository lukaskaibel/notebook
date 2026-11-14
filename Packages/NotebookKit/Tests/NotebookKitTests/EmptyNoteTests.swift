import XCTest
@testable import NotebookKit

/// A note left with no text in it, or only spaces and empty lines, goes to the Trash, whatever its name and whether it
/// is new or not, and its card leaves Recent at once. Undo brings it back. One with a reminder or a star stays, and so
/// does one written in on another device before it went, or any once Settings keep notes left empty.
@MainActor
final class EmptyNoteTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var trip: URL { papers.appendingPathComponent("Trip.md") }
    /// Nothing in it but spaces, a tab and empty lines.
    private var ideas: URL { papers.appendingPathComponent("Ideas.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-empty-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "# Draft\n\nSome text.\n".write(to: draft, atomically: true, encoding: .utf8)
        try "Five days in October.\n".write(to: trip, atomically: true, encoding: .utf8)
        try "  \n\t\n\n".write(to: ideas, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
        Workspace.recentCardsDelay = .milliseconds(300)
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections", "deletesEmptyNewNotes"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotebookSettings.shared.deletesEmptyNotes = true
        Workspace.recentCardsDelay = .seconds(2)
        window?.close()
        try? FileManager.default.removeItem(at: library)
    }

    /// The library read, with the sidebar and the note in one window, as in the app: they share its undo manager.
    private func makeWorkspace() async throws -> (Workspace, UndoManager) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView!.addSubview(sidebar.scrollView)
        workspace.editor.view.frame = NSRect(x: 260, y: 0, width: 640, height: 600)
        window.contentView!.addSubview(workspace.editor.view)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        await withCheckedContinuation { done in workspace.readFolders(to: papers, including: true) { done.resume() } }
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Everything asked for has been written, notes left too.
    private func settle(_ workspace: Workspace) async {
        await workspace.changeFiles { _ in }.value
        await NoteDocument.allWritten()
    }

    private func notes() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: papers.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    }

    private func cards(_ workspace: Workspace) -> [String] {
        workspace.recentCardURLs.map(\.lastPathComponent)
    }

    private func isRecent(_ url: URL, in workspace: Workspace) -> Bool {
        workspace.recents.contains { FileNode.samePath(URL(fileURLWithPath: $0), url) }
    }

    func testANoteWithOnlySpacesGoesWhenLeft() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(ideas)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Trip.md"])
        XCTAssertFalse(isRecent(ideas, in: workspace), "still among the files opened last")
    }

    /// Empty is how it is left: a note written in before, whatever its name, goes once its text is taken out.
    func testANoteEmptiedGoesWhenLeft() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(trip)
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        textView.insertText("   \n ", replacementRange: textView.selectedRange())
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md"], "only new notes go")
    }

    func testANoteWithTextStays() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(trip)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertEqual(try String(contentsOf: trip, encoding: .utf8), "Five days in October.\n")
    }

    /// Only one made a moment ago with New Note goes as if it had never been made.
    func testUndoBringsItBack() async throws {
        let (workspace, manager) = try await makeWorkspace()
        workspace.open(ideas)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Trip.md"])
        XCTAssertEqual(manager.undoActionName, "Delete Empty Note")
        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertEqual(try String(contentsOf: ideas, encoding: .utf8), "  \n\t\n\n", "back as it was")
        XCTAssertEqual(workspace.currentURL.map(\.lastPathComponent), "Draft.md", "not opened again: it was left")
    }

    func testANewNoteLeftEmptyLeavesNothingToUndo() async throws {
        let (workspace, manager) = try await makeWorkspace()
        workspace.open(draft)
        _ = await workspace.newNote(in: papers).value
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertFalse(manager.canUndo, "\(manager.undoActionName) is there to undo")
    }

    /// A name typed into a new note left without text isn't given first: the note goes as it is.
    func testANewNoteWithOnlyANameGoes() async throws {
        let (workspace, _) = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        let fieldEditor = try XCTUnwrap(workspace.editor.textView.titleField.currentEditor() as? NSTextView, "the title isn't being typed")
        fieldEditor.insertText("Groceries", replacementRange: fieldEditor.selectedRange())
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
    }

    func testANoteWithAReminderOrAStarStays() async throws {
        let (workspace, _) = try await makeWorkspace()
        let starred = papers.appendingPathComponent("Starred.md")
        try "".write(to: starred, atomically: true, encoding: .utf8)
        workspace.setReminder(for: ideas, at: .now + 3600)
        workspace.toggleFavorite(starred)
        workspace.open(ideas)
        workspace.open(starred)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Starred.md", "Trip.md"])
    }

    func testSettingsCanKeepNotesLeftEmpty() async throws {
        NotebookSettings.shared.deletesEmptyNotes = false
        let (workspace, _) = try await makeWorkspace()
        workspace.open(ideas)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertTrue(isRecent(ideas, in: workspace))
    }

    /// Written in on another device while it was on its way: it stays, and its card comes back.
    func testANoteWrittenInMeanwhileStays() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(ideas)
        XCTAssertEqual(cards(workspace), ["Ideas.md"])
        // The change to files before it waits until the other device has written.
        let gate = Gate()
        workspace.changeFiles { _ in await gate.wait() }
        workspace.open(draft)
        XCTAssertFalse(cards(workspace).contains("Ideas.md"), "its card stayed while it was going")
        try "Written on the iPad.\n".write(to: ideas, atomically: true, encoding: .utf8)
        gate.open()
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertEqual(try String(contentsOf: ideas, encoding: .utf8), "Written on the iPad.\n")
        try await until("its card came back") { cards(workspace).contains("Ideas.md") }
    }

    /// Opened again before it went, as its card can be on the iPhone for a moment after Back: it stays, open.
    func testANoteOpenedAgainBeforeItWentStays() async throws {
        let (workspace, _) = try await makeWorkspace()
        let gate = Gate()
        workspace.open(ideas)
        workspace.changeFiles { _ in await gate.wait() }
        workspace.open(draft)
        workspace.open(ideas)
        gate.open()
        await workspace.changeFiles { _ in }.value
        XCTAssertEqual(notes(), ["Draft.md", "Ideas.md", "Trip.md"])
        XCTAssertEqual(workspace.currentURL.map(\.lastPathComponent), "Ideas.md")
    }

    // MARK: - Recent

    /// Its card goes as it is left, not once the disk is done, and doesn't come back with the next file's.
    func testItsCardLeavesRecentAtOnce() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(trip)
        workspace.open(ideas)
        try await until("the cards took the new order") { cards(workspace) == ["Ideas.md", "Trip.md"] }
        workspace.open(draft)
        XCTAssertEqual(cards(workspace), ["Trip.md"])
        await settle(workspace)
        XCTAssertFalse(cards(workspace).contains("Ideas.md"), "back once it was gone")
        try await until("the next file joined the cards") { cards(workspace) == ["Draft.md", "Trip.md"] }
    }

    /// The only card going takes Recent with it: the next file's card comes at once, as the first card does.
    func testTheOnlyCardGoing() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(ideas)
        workspace.open(draft)
        XCTAssertEqual(cards(workspace), ["Draft.md"])
        await settle(workspace)
        XCTAssertEqual(cards(workspace), ["Draft.md"])
    }

    /// While the pointer is on the cards, the card you clicked stays under it: the one that went is faded in its place
    /// until the pointer leaves, and the others close up a moment after.
    func testWhileThePointerIsOnTheCardsTheGoneCardFadesInPlace() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(trip)
        workspace.open(ideas)
        try await until("the cards took the new order") { cards(workspace) == ["Ideas.md", "Trip.md"] }
        workspace.holdRecentCards(true)
        workspace.open(trip)
        await settle(workspace)
        XCTAssertEqual(notes(), ["Draft.md", "Trip.md"])
        XCTAssertEqual(cards(workspace), ["Ideas.md", "Trip.md"], "the card clicked moved under the pointer")
        XCTAssertTrue(workspace.isFadedCard(ideas))
        XCTAssertFalse(workspace.isFadedCard(trip))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(cards(workspace), ["Ideas.md", "Trip.md"], "not while the pointer is there")
        workspace.holdRecentCards(false)
        try await until("the cards closed up") { cards(workspace) == ["Trip.md"] }
        XCTAssertFalse(workspace.isFadedCard(ideas))
    }
}

/// Holds a change to files until it is opened.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
