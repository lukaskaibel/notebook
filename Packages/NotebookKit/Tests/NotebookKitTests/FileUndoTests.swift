import XCTest
@testable import NotebookKit

/// Edit › Undo (⌘Z) and Redo (⇧⌘Z) for changes to files, as in the Finder: what went to the Trash comes back, a rename
/// or move goes back, what was made goes to the Trash. On the Mac they are in the window's undo manager with the
/// changes to the note's text, so Undo takes back the newest first, whichever it is.
@MainActor
final class FileUndoTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var archive: URL { library.appendingPathComponent("Archive") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var other: URL { papers.appendingPathComponent("Other.md") }
    private var chart: URL { papers.appendingPathComponent(".assets/chart.png") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-undo-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Draft\n\n![Chart](.assets/chart.png)\n".write(to: draft, atomically: true, encoding: .utf8)
        try "# Other\n\nSee [[Draft]].\n".write(to: other, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: chart)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookSlowWrites", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        window?.close()
        try? FileManager.default.removeItem(at: library)
    }

    /// The library read, with the sidebar and the note in one window, as in the app: they share its undo manager.
    private func makeWindow() async throws -> (Workspace, UndoManager) {
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
        for folder in [papers, archive] {
            await withCheckedContinuation { done in workspace.readFolders(to: folder, including: true) { done.resume() } }
        }
        let manager = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(workspace.fileUndoManager === manager, "kept elsewhere than in the window")
        return (workspace, manager)
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Everything asked for has been written, and the undo manager's group for it is closed, as after an event.
    private func settle(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("written") { manager.groupingLevel == 0 }
        await workspace.changeFiles { _ in }.value
    }

    /// Undo as Edit › Undo does it, once what was asked for is written.
    private func undo(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await settle(workspace, manager)
    }

    private func redo(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.redo()
        try await settle(workspace, manager)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Undo and Redo write off the main thread, as the changes themselves do.
    private func assertNothingOnTheMainThread(since writes: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(FileOperations.mainThreadWrites.withLock { $0 }, writes, "files changed on the main thread", file: file, line: line)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - The Trash

    /// The open note thrown away comes back where it was, opens again, and goes to the Trash again with Redo.
    func testUndoPutsATrashedNoteBackAndRedoThrowsItAwayAgain() async throws {
        let (workspace, manager) = try await makeWindow()
        let writes = FileOperations.mainThreadWrites.withLock { $0 }
        workspace.open(draft)
        workspace.open(other)
        workspace.toggleFavorite(other)
        let trashing = workspace.trash(other)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move to Trash")
        _ = await trashing.value
        XCTAssertFalse(exists(other))
        XCTAssertFalse(workspace.isFavorite(other))
        XCTAssertEqual(workspace.currentURL?.path, draft.path)

        try await undo(workspace, manager)
        XCTAssertEqual(text(other), "# Other\n\nSee [[Draft]].\n")
        XCTAssertEqual(workspace.currentURL?.path, other.path, "it was open")
        XCTAssertTrue(workspace.isFavorite(other), "it was a favourite")
        XCTAssertNotNil(workspace.node(for: other, reading: false), "not in the sidebar")
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Move to Trash")

        try await redo(workspace, manager)
        XCTAssertFalse(exists(other))
        XCTAssertNil(workspace.node(for: other, reading: false), "still in the sidebar")
        try await undo(workspace, manager)
        XCTAssertTrue(exists(other))
        assertNothingOnTheMainThread(since: writes)
    }

    /// Undo pressed while the file is still on its way to the Trash waits for it.
    func testUndoAtOnceWaitsForTheChange() async throws {
        let (workspace, manager) = try await makeWindow()
        UserDefaults.standard.set(0.3, forKey: "NotebookSlowWrites")
        workspace.trash(other)
        try await undo(workspace, manager)
        XCTAssertTrue(exists(other))
        XCTAssertFalse(manager.canUndo)
    }

    /// A folder that was hidden, with a note in it that had a reminder, comes back hidden, the reminder with it.
    func testWhatNotebookKnewComesBackFromTheTrash() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.setHidden(archive, true)
        let note = archive.appendingPathComponent("Plan.md")
        try "# Plan\n".write(to: note, atomically: true, encoding: .utf8)
        workspace.setReminder(for: note, at: Date.now + 3600)
        let id = try XCTUnwrap(workspace.reminder(for: note)?.id)
        _ = await workspace.trash(archive).value
        XCTAssertFalse(workspace.isHidden(archive))
        XCTAssertNil(workspace.reminder(for: note))

        try await undo(workspace, manager)
        XCTAssertTrue(exists(note))
        XCTAssertTrue(workspace.isHidden(archive))
        XCTAssertEqual(workspace.reminder(for: note)?.id, id)
    }

    // MARK: - Renaming and moving

    /// A renamed note gets its name back, and the links to it in other notes follow it back.
    func testUndoRenameGivesTheNameBack() async throws {
        let (workspace, manager) = try await makeWindow()
        let plan = papers.appendingPathComponent("Plan.md")
        let renamed = await workspace.rename(draft, to: "Plan").value
        XCTAssertEqual(renamed?.path, plan.path)
        try await until("the link followed") { self.text(self.other)?.contains("[[Plan]]") == true }
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Rename")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertFalse(exists(plan))
        try await until("the link followed back") { self.text(self.other)?.contains("[[Draft]]") == true }

        try await redo(workspace, manager)
        XCTAssertTrue(exists(plan))
        XCTAssertFalse(exists(draft))
    }

    /// A moved note goes back to its folder with its picture.
    func testUndoMoveTakesTheNoteBackWithItsPicture() async throws {
        let (workspace, manager) = try await makeWindow()
        let writes = FileOperations.mainThreadWrites.withLock { $0 }
        workspace.open(draft)
        _ = await workspace.move(draft, into: archive).value
        try await until("the picture left behind went") { !self.exists(self.chart) }
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertFalse(exists(archive.appendingPathComponent("Draft.md")))
        XCTAssertEqual(workspace.currentURL?.path, draft.path, "the open note followed")
        try await until("its picture came back") { self.exists(self.chart) && !self.exists(self.archive.appendingPathComponent(".assets/chart.png")) }
        assertNothingOnTheMainThread(since: writes)
    }

    /// Files dropped together go back together.
    func testOneUndoTakesBackADrop() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.drop([draft, other], into: archive)
        try await settle(workspace, manager)
        XCTAssertTrue(exists(archive.appendingPathComponent("Other.md")))

        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertTrue(exists(other))
        XCTAssertFalse(manager.canUndo)
    }

    /// A change that couldn't be made leaves nothing to undo.
    func testANameAlreadyTakenLeavesNothingToUndo() async throws {
        let (workspace, manager) = try await makeWindow()
        let renamed = await workspace.rename(draft, to: "Other").value
        XCTAssertNil(renamed)
        try await settle(workspace, manager)
        XCTAssertFalse(manager.canUndo)
    }

    // MARK: - New files

    /// A new folder and a copy go to the Trash with Undo, and come back with Redo.
    func testUndoTakesNewFilesAway() async throws {
        let (workspace, manager) = try await makeWindow()
        let ideas = papers.appendingPathComponent("Ideas")
        workspace.newFolder(in: papers, named: "Ideas")
        try await settle(workspace, manager)
        XCTAssertTrue(exists(ideas))
        let copying = await workspace.duplicate(draft).value
        let copy = try XCTUnwrap(copying)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Duplicate")

        try await undo(workspace, manager)
        XCTAssertFalse(exists(copy))
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo New Folder")
        try await undo(workspace, manager)
        XCTAssertFalse(exists(ideas))
        try await redo(workspace, manager)
        XCTAssertTrue(exists(ideas))
    }

    /// A new note left empty goes away by itself, and with it its New Note in Undo.
    func testANewNoteLeftEmptyLeavesNothingToUndo() async throws {
        let (workspace, manager) = try await makeWindow()
        let making = await workspace.newNote(in: papers).value
        let untitled = try XCTUnwrap(making)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo New Note")
        workspace.open(draft)
        try await until("the empty note went") { !self.exists(untitled) }
        try await settle(workspace, manager)
        XCTAssertFalse(manager.canUndo)
    }

    // MARK: - With the text

    /// Typing and changes to files are taken back newest first; another note forgets the typing, not the files.
    func testUndoTakesBackTypingAndFilesNewestFirst() async throws {
        let (workspace, manager) = try await makeWindow()
        let third = papers.appendingPathComponent("Third.md")
        try "# Third\n".write(to: third, atomically: true, encoding: .utf8)
        workspace.open(draft)
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: workspace.editor.text.utf16.count, length: 0))
        textView.insertText("One.", replacementRange: textView.selectedRange())
        try await settle(workspace, manager)
        workspace.trash(other)
        try await settle(workspace, manager)
        textView.insertText(" Two.", replacementRange: textView.selectedRange())
        try await settle(workspace, manager)
        XCTAssertTrue(workspace.editor.text.hasSuffix("One. Two."))

        try await undo(workspace, manager)
        XCTAssertTrue(workspace.editor.text.hasSuffix("One."), "the typing last")
        XCTAssertFalse(exists(other))
        try await undo(workspace, manager)
        XCTAssertTrue(exists(other), "the Trash before it")
        try await undo(workspace, manager)
        XCTAssertFalse(workspace.editor.text.contains("One."), "the typing before that")

        try await redo(workspace, manager)
        try await redo(workspace, manager)
        XCTAssertFalse(exists(other))
        workspace.open(third)
        try await settle(workspace, manager)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move to Trash", "the typing in another note")
        try await undo(workspace, manager)
        XCTAssertTrue(exists(other))
        XCTAssertEqual(workspace.editor.text, "# Third\n")
    }
}
