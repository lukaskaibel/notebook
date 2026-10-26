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

    func testVersionsGoToTheTrashWithTheNoteAndComeBackWithUndo() async throws {
        let (workspace, manager) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        let trashed = await workspace.trash(draft).value
        XCTAssertTrue(trashed)
        let gone = await versions(of: draft)
        XCTAssertEqual(gone, [], "a note made under its name starts without them")
        try await undo(workspace, manager)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.path))
        let back = await versions(of: draft)
        XCTAssertEqual(back.count, 1)
    }

    func testVersionsComeBackUnderTheNameANotePutBackGets() async throws {
        let (workspace, manager) = try await makeWindow()
        history.keep("# Draft\n\nAn earlier version.\n", of: draft)
        _ = await workspace.trash(draft).value
        // Its name is taken meanwhile: Undo puts it back as "Draft 2".
        try "# Draft\n\nAnother note.\n".write(to: draft, atomically: true, encoding: .utf8)
        try await undo(workspace, manager)
        let second = papers.appendingPathComponent("Draft 2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let its = await versions(of: second)
        XCTAssertEqual(its.count, 1)
        let others = await versions(of: draft)
        XCTAssertEqual(others, [])
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

/// When a note's text is kept as a version (#119): as it was when you start changing it, now and then while you
/// write, when you stop, and both texts before a change from elsewhere is merged in or a conflict is settled.
@MainActor
final class VersionCopyTests: XCTestCase {
    private var folder: URL!
    private var history: NoteHistory!
    private var url: URL { folder.appendingPathComponent("Notes/Note.md") }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-copies-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        history = NoteHistory(local: folder.appendingPathComponent("History.noindex", isDirectory: true), iCloudDrive: folder.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ text: String, at url: URL? = nil) throws -> NoteDocument {
        let url = url ?? self.url
        try text.write(to: url, atomically: true, encoding: .utf8)
        let note = NoteDocument(url: url, history: history)
        return note
    }

    /// The texts of the note's versions, newest first.
    private func versions(of url: URL? = nil) async -> [String] {
        var texts: [String] = []
        for version in await history.versions(of: url ?? self.url) { texts.append(await history.text(of: version) ?? "?") }
        return texts
    }

    func testTheFirstChangeKeepsTheNoteAsItWasOnce() async throws {
        let note = try open("as opened\n")
        let none = await versions()
        XCTAssertEqual(none, [], "opening alone keeps nothing")
        note.update(text: "as opened\nmore\n")
        note.update(text: "as opened\nmore and more\n")
        let kept = await versions()
        XCTAssertEqual(kept, ["as opened\n"])
        XCTAssertEqual(note.openedText, "as opened\n")
        note.close()
        await note.saved()
    }

    func testStoppingKeepsWhatWasWritten() async throws {
        let note = try open("one\n")
        note.update(text: "one\ntwo\n")
        note.close()
        await note.saved()
        let kept = await versions()
        XCTAssertEqual(kept, ["one\ntwo\n", "one\n"])
    }

    func testStoppingWithoutWritingKeepsNothing() async throws {
        let note = try open("one\n")
        note.keepCopyOfChanges()
        note.close()
        await note.saved()
        let kept = await versions()
        XCTAssertEqual(kept, [])
    }

    func testWritingKeepsACopyNowAndThen() async throws {
        let note = try open("one\n")
        note.copyInterval = 0.3
        note.update(text: "one\ntwo\n")
        note.saveNow()
        await note.saved()
        let soon = await versions()
        XCTAssertEqual(soon, ["one\n"], "not yet")
        try await Task.sleep(for: .milliseconds(400))
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        await note.saved()
        let later = await versions()
        XCTAssertEqual(later, ["one\ntwo\nthree\n", "one\n"])
        note.close()
        await note.saved()
        let closed = await versions()
        XCTAssertEqual(closed.count, 2, "nothing changed since")
    }

    func testAChangeFromElsewhereKeepsWhatYouWroteAndIt() async throws {
        let note = try open("one\n")
        note.update(text: "one\nmine\n")
        note.saveNow()
        await note.saved()
        try "one\nmine\ntheirs\n".write(to: url, atomically: true, encoding: .utf8)
        note.presentedItemDidChange()
        await note.saved()
        XCTAssertEqual(note.text, "one\nmine\ntheirs\n")
        let kept = await versions()
        XCTAssertEqual(kept, ["one\nmine\n", "one\nmine\ntheirs\n", "one\n"], "yours newest, then theirs")
        note.close()
        await note.saved()
        let closed = await versions()
        XCTAssertEqual(closed.count, 3, "theirs is kept already")
    }

    func testAChangeFromElsewhereAloneIsLeftToItsDevice() async throws {
        let note = try open("one\n")
        try "one\ntheirs\n".write(to: url, atomically: true, encoding: .utf8)
        note.presentedItemDidChange()
        await note.saved()
        XCTAssertEqual(note.text, "one\ntheirs\n")
        note.close()
        await note.saved()
        let kept = await versions()
        XCTAssertEqual(kept, [])
    }

    func testAMergeKeepsBothTexts() async throws {
        let note = try open("one\ntwo\nthree\n")
        note.update(text: "one, mine\ntwo\nthree\n")
        try "one\ntwo\nthree, theirs\n".write(to: url, atomically: true, encoding: .utf8)
        note.presentedItemDidChange()
        await note.saved()
        XCTAssertEqual(note.text, "one, mine\ntwo\nthree, theirs\n")
        let kept = await versions()
        XCTAssertEqual(kept, ["one, mine\ntwo\nthree\n", "one\ntwo\nthree, theirs\n", "one\ntwo\nthree\n"])
        note.close()
        await note.saved()
        let closed = await versions()
        XCTAssertEqual(closed.first, "one, mine\ntwo\nthree, theirs\n", "and what they made")
    }

    func testUseOtherCanBeTakenBack() async throws {
        let note = try open("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        await note.saved()
        XCTAssertNotNil(note.conflict)
        XCTAssertEqual(note.resolve(.takeOther), "one theirs\ntwo\n")
        let kept = await versions()
        XCTAssertEqual(kept, ["one mine\ntwo\n", "one theirs\ntwo\n", "one\ntwo\n"])
        note.close()
        await note.saved()
    }

    func testLeavingANoteInAConflictKeepsWhatYouWroteAsAVersion() async throws {
        let note = try open("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        await note.saved()
        XCTAssertNotNil(note.conflict)
        // No one left to ask: a copy of the note is written next to it (#137), and the version is kept too.
        note.close()
        await note.saved()
        await NoteDocument.allWritten()
        let kept = await versions()
        XCTAssertEqual(kept.first, "one mine\ntwo\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one theirs\ntwo\n")
    }

    func testOpeningANoteAnotherAppChangedKeepsIt() async throws {
        history.keep("as Notebook left it\n", of: url, at: Date() - 60)
        await history.written()
        let note = try open("as another app left it\n")
        let kept = await versions()
        XCTAssertEqual(kept, ["as another app left it\n", "as Notebook left it\n"])
        note.close()
        await note.saved()
        // Opening it again as it is keeps nothing new.
        let again = NoteDocument(url: url, history: history)
        let same = await versions()
        XCTAssertEqual(same.count, 2)
        again.close()
        await again.saved()
    }

    func testCopiesWaitForARenameAndGoWhereTheNoteWent() async throws {
        let note = try open("one\n")
        note.beginMove()
        note.update(text: "one\ntwo\n")
        let renamed = folder.appendingPathComponent("Notes/Renamed.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        history.follow(from: url, to: renamed)
        note.endMove(to: renamed)
        note.close()
        await note.saved()
        let old = await versions()
        XCTAssertEqual(old, [])
        let kept = await versions(of: renamed)
        XCTAssertEqual(kept, ["one\ntwo\n", "one\n"])
    }
}
