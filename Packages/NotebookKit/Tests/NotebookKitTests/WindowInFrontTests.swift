import XCTest
@testable import NotebookKit

/// The window you are working in on the Mac, which the File and Edit menus act on, and where Undo of what they did is
/// kept: ⌘Z reaches it there, also after the main window was closed and opened again.
@MainActor
final class WindowInFrontTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var other: URL { papers.appendingPathComponent("Other.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-front-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "# Draft\n\nText.\n".write(to: draft, atomically: true, encoding: .utf8)
        try "# Other\n\nMore.\n".write(to: other, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName"] { UserDefaults.standard.removeObject(forKey: key) }
        window?.close()
        try? FileManager.default.removeItem(at: library)
    }

    /// The sidebar and the note in one window, as in the app, the library read.
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
        await withCheckedContinuation { done in workspace.readFolders(to: papers, including: true) { done.resume() } }
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A note trashed in its own window while the main window is closed: its Undo waits in Notebook's own undo
    /// manager, which nothing reaches, and goes to the main window's once that opens again, where ⌘Z takes it back.
    func testATrashWhileTheMainWindowIsClosedIsUndoneThereOnceItOpens() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.isMainWindowOpen = false
        _ = await workspace.trash(other).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(manager.canUndo, "kept in a window that is closed")

        workspace.mainWindowOpened()
        try await until("in the main window's Undo") { manager.canUndo }
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move to Trash")
        XCTAssertFalse(workspace.ownUndoManager.canUndo)
        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("back from the Trash") { FileManager.default.fileExists(atPath: self.other.path) }
    }

    /// The main window opened again showing neither the sidebar nor the note (To-dos, the sidebar away): the Trash
    /// kept while it was closed goes to that window all the same, so it isn't left for a later reopen, on top of newer
    /// changes.
    func testATrashKeptWhileClosedFindsTheWindowWithoutItsSidebarOrNote() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.isMainWindowOpen = false
        _ = await workspace.trash(other).value
        workspace.editor.view.removeFromSuperview()
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        main.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        defer { main.close() }
        workspace.isMainWindowOpen = true
        workspace.moveUndoToMainWindow()
        XCTAssertEqual(main.undoManager?.undoMenuItemTitle, "Undo Move to Trash")
        XCTAssertFalse(workspace.ownUndoManager.canUndo)
        XCTAssertFalse(manager.canUndo)
        workspace.moveUndoToMainWindow()
        XCTAssertEqual(main.undoManager?.undoMenuItemTitle, "Undo Move to Trash", "moved once")
    }

    /// ⌘N in a note's own window makes the note in the main window, which comes to the front: what it does is kept for
    /// Undo there, where ⌘Z in the main window finds it, not in the note's window it came from.
    func testWhatAMainWindowCommandDoesIsUndoneInTheMainWindow() async throws {
        let (workspace, manager) = try await makeWindow()
        let controller = FileWindowController(url: draft)
        workspace.keyFileWindow = controller
        workspace.keyFileNote = controller.noteDocument
        XCTAssertTrue(workspace.fileUndoManager === controller.window?.undoManager, "the note's window is in front")
        var kept: FileChange?
        workspace.inMainWindow { kept = workspace.keepForUndo(FileChange(.make, "New Note")) }
        XCTAssertNil(workspace.keyFileNote, "the main window is the one you work in now")
        XCTAssertTrue(kept?.manager === manager)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo New Note")
        XCTAssertEqual(controller.window?.undoManager?.canUndo, false)
        if let kept { workspace.dropFromUndo(kept) }
        controller.close()
    }

    /// Settings in front: no note for the menus to act on, until a note's window or the main window is in front again.
    func testSettingsInFrontLeavesNoNoteToActOn() async throws {
        _ = try await makeWindow()
        _ = FileWindows.shared
        let controller = FileWindowController(url: draft)
        let noteWindow = try XCTUnwrap(controller.window)
        FileWindows.becameMain(noteWindow)
        XCTAssertTrue(Workspace.shared.keyFileWindow === controller)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        FileWindows.becameMain(settings)
        XCTAssertNil(Workspace.shared.keyFileNote)
        XCTAssertTrue(Workspace.shared.isOtherWindowInFront)
        FileWindows.becameMain(noteWindow)
        XCTAssertFalse(Workspace.shared.isOtherWindowInFront)
        noteWindow.close()
        XCTAssertNil(Workspace.shared.keyFileWindow, "closed")
    }
}
