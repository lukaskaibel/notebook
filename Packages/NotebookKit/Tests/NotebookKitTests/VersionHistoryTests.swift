import XCTest
@testable import NotebookKit

/// Version history in the app: a note's earlier versions go where Notebook renames or moves it, and back with Undo, and
/// stay where they are when it goes to the Trash, for Undo and Put Back to find.
@MainActor
final class VersionHistoryTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var archive: URL { library.appendingPathComponent("Archive") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var window: NSWindow?
    private let history = NoteHistory.shared

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-versions-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Draft\n\nFirst words.\n".write(to: draft, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookSlowWrites", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("written") { manager.groupingLevel == 0 }
        await workspace.changeFiles { _ in }.value
    }

    private func undo(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await settle(workspace, manager)
    }

    /// The texts of a note's versions, newest first.
    private func versions(of note: URL) async -> [String] {
        var texts: [String] = []
        for version in await history.versions(of: note) { texts.append(await history.text(of: version) ?? "?") }
        return texts
    }

    // MARK: - Following the note (#120)

    func testVersionsFollowRenamesAndMovesAndComeBackWithUndo() async throws {
        let (workspace, manager) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        await history.written()

        let plan = papers.appendingPathComponent("Plan.md")
        _ = await workspace.rename(draft, to: "Plan").value
        let renamed = await versions(of: plan)
        XCTAssertEqual(renamed, ["# Draft\n\nAn earlier version.\n"])
        let left = await versions(of: draft)
        XCTAssertEqual(left, [])

        _ = await workspace.move(plan, into: archive).value
        let moved = await versions(of: archive.appendingPathComponent("Plan.md"))
        XCTAssertEqual(moved.count, 1)

        try await undo(workspace, manager)
        let back = await versions(of: plan)
        XCTAssertEqual(back.count, 1, "back with Undo")
        try await undo(workspace, manager)
        let first = await versions(of: draft)
        XCTAssertEqual(first.count, 1, "under its first name again")
    }

    func testVersionsFollowARenamedFolder() async throws {
        let (workspace, _) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        let renamed = await workspace.rename(papers, to: "Documents").value
        let inside = try XCTUnwrap(renamed).appendingPathComponent("Draft.md")
        let followed = await versions(of: inside)
        XCTAssertEqual(followed.count, 1)
    }

    func testVersionsStayWhenTheNoteGoesToTheTrashForUndoToFind() async throws {
        let (workspace, manager) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        let trashed = await workspace.trash(draft).value
        XCTAssertTrue(trashed)
        let stayed = await versions(of: draft)
        XCTAssertEqual(stayed.count, 1)
        try await undo(workspace, manager)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.path))
        let back = await versions(of: draft)
        XCTAssertEqual(back.count, 1)
    }

    func testADuplicateStartsWithoutVersions() async throws {
        let (workspace, _) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        let duplicate = await workspace.duplicate(draft).value
        let copy = try XCTUnwrap(duplicate)
        let none = await versions(of: copy)
        XCTAssertEqual(none, [])
        let own = await versions(of: draft)
        XCTAssertEqual(own.count, 1)
    }
}
