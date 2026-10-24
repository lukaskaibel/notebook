import XCTest
@testable import NotebookKit

/// Links follow the notes, files and folders Notebook renames and moves, from the sidebar, by drag and drop, Move To
/// and Undo alike: written off the main thread in the notes' files, and in a note shown in an editor as an edit of its
/// text. Undo puts them back as they were; copies change nothing.
@MainActor
final class LinkFollowingTests: XCTestCase {
    private var library: URL!
    private var outside: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var archive: URL { library.appendingPathComponent("Archive") }
    private var later: URL { library.appendingPathComponent("Later") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var plan: URL { papers.appendingPathComponent("Plan.md") }
    private var index: URL { library.appendingPathComponent("Index.md") }
    private var window: NSWindow?
    private var fileWindows: [NSWindow] = []

    private let draftText = "# Draft\n\n![Chart](.assets/chart.png)\n\nSee [[Plan]].\n"
    private let indexText = "[[Papers/Plan|the plan]] and [[Draft]]\n"

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-following-\(UUID().uuidString)").standardizedFileURL
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-outside-\(UUID().uuidString)").standardizedFileURL
        for folder in [papers.appendingPathComponent(".assets"), archive, later, outside!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try draftText.write(to: draft, atomically: true, encoding: .utf8)
        try "# Plan\n".write(to: plan, atomically: true, encoding: .utf8)
        try "# Old plan\n".write(to: archive.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
        try indexText.write(to: index, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: papers.appendingPathComponent(".assets/chart.png"))
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
        for window in fileWindows { window.close() }
        try? FileManager.default.removeItem(at: library)
        try? FileManager.default.removeItem(at: outside)
    }

    /// The library read and its index built, with the sidebar and the note in one window, as in the app.
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
        for folder in [papers, archive, later] {
            await withCheckedContinuation { done in workspace.readFolders(to: folder, including: true) { done.resume() } }
        }
        try await until("the index was built") { workspace.index.hasBuilt && !workspace.index.isBuilding }
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Everything asked for is written, links and all, and the undo manager's group for it is closed, as after an event.
    private func settle(_ workspace: Workspace, _ manager: UndoManager) async throws {
        try await until("written") { manager.groupingLevel == 0 }
        await workspace.changeFiles { _ in }.value
        await workspace.linksFollowed()
    }

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

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private var mainThreadWrites: Int { FileOperations.mainThreadWrites.withLock { $0 } }

    // MARK: - Moving

    /// Moved where another note of its name comes first, a note keeps its links: they say which it is now. Undo puts
    /// them back as they were written, Redo has them follow again; nothing is written on the main thread.
    func testAMovedNotesLinksFollowItAndComeBackWithUndo() async throws {
        let (workspace, manager) = try await makeWindow()
        let writes = mainThreadWrites
        _ = await workspace.move(plan, into: later).value
        try await settle(workspace, manager)
        XCTAssertTrue(exists(later.appendingPathComponent("Plan.md")))
        XCTAssertEqual(text(draft), draftText.replacingOccurrences(of: "[[Plan]]", with: "[[Later/Plan]]"))
        XCTAssertEqual(text(index), "[[Later/Plan|the plan]] and [[Draft]]\n")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(plan))
        XCTAssertEqual(text(draft), draftText)
        XCTAssertEqual(text(index), indexText)

        try await redo(workspace, manager)
        XCTAssertTrue(exists(later.appendingPathComponent("Plan.md")))
        XCTAssertEqual(text(index), "[[Later/Plan|the plan]] and [[Draft]]\n")
        try await undo(workspace, manager)
        XCTAssertEqual(text(draft), draftText)
        XCTAssertEqual(text(index), indexText)
        XCTAssertEqual(mainThreadWrites, writes, "files changed on the main thread")
    }

    /// Dragged onto a folder, a note's links follow; Option-dragged, it is copied, and a copy changes no link, nor
    /// does a duplicate.
    func testDropsMoveWithTheirLinksAndCopiesChangeNone() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.drop([plan], into: archive, copying: true)
        _ = await workspace.duplicate(plan).value
        try await settle(workspace, manager)
        XCTAssertTrue(exists(archive.appendingPathComponent("Plan 2.md")), "copied")
        XCTAssertTrue(exists(papers.appendingPathComponent("Plan copy.md")))
        XCTAssertEqual(text(draft), draftText)
        XCTAssertEqual(text(index), indexText)

        workspace.drop([plan], into: later)
        try await settle(workspace, manager)
        XCTAssertTrue(exists(later.appendingPathComponent("Plan.md")))
        XCTAssertEqual(text(index), "[[Later/Plan|the plan]] and [[Draft]]\n")
    }

    /// Undo pressed while the links are still being written takes them back too, however far it had got.
    func testUndoAtOnceTakesBackLinksStillBeingWritten() async throws {
        var notes: [URL: String] = [:]
        for number in 0..<5 {
            let note = papers.appendingPathComponent("Note \(number).md")
            notes[note] = "Note \(number) links to [[Plan]] and [[Plan#Top|the top]].\n"
            try notes[note]!.write(to: note, atomically: true, encoding: .utf8)
        }
        let (workspace, manager) = try await makeWindow()
        UserDefaults.standard.set(0.2, forKey: "NotebookSlowWrites")
        workspace.move(plan, into: later)
        try await until("moved") { self.exists(self.later.appendingPathComponent("Plan.md")) }
        try await until("a link written") { notes.keys.contains { self.text($0) != notes[$0] } }
        try await undo(workspace, manager)
        XCTAssertTrue(exists(plan))
        for (note, original) in notes { XCTAssertEqual(text(note), original, note.lastPathComponent) }
        XCTAssertEqual(text(index), indexText)
    }

    /// A note the index has no text of, as one still in iCloud: read once it has come down, and written when a link in
    /// it changes. Stopped before it began, nothing is.
    func testANoteTheIndexHasntReadIsReadWhenItComes() async throws {
        let unread = archive.appendingPathComponent("Unread.md")
        try "[[Plan]] here, [[Papers/Plan]] there".write(to: unread, atomically: true, encoding: .utf8)
        var targets = LinkTargets.reading(library, deep: true)
        let key = try XCTUnwrap(targets.entry(for: unread)).path
        targets.byPath[key]?.text = nil
        targets.byPath[key]?.folded = nil
        let moved = later.appendingPathComponent("Plan.md")
        try FileManager.default.moveItem(at: plan, to: moved)
        let workspace = Workspace()
        let stopped = workspace.followLinks(LinkUpdate.Move(from: plan, to: moved), from: Workspace.LinkSnapshot(targets: targets))
        stopped.stop()
        await workspace.linksFollowed()
        XCTAssertEqual(text(unread), "[[Plan]] here, [[Papers/Plan]] there")

        let following = workspace.followLinks(LinkUpdate.Move(from: plan, to: moved), from: Workspace.LinkSnapshot(targets: targets))
        await workspace.linksFollowed()
        XCTAssertEqual(text(unread), "[[Plan]] here, [[Later/Plan]] there")
        XCTAssertEqual(text(draft), draftText.replacingOccurrences(of: "[[Plan]]", with: "[[Later/Plan]]"), "the others too")
        XCTAssertEqual(Set(following.edits.map(\.note.lastPathComponent)), ["Unread.md", "Draft.md", "Index.md"])
    }

    // MARK: - Folders

    /// A renamed folder takes the links into it along, as short as they can be, and gives them back with Undo.
    func testARenamedFolderTakesTheLinksIntoItAlong() async throws {
        let (workspace, manager) = try await makeWindow()
        let work = library.appendingPathComponent("Work")
        _ = await workspace.rename(papers, to: "Work").value
        try await settle(workspace, manager)
        XCTAssertEqual(text(index), "[[Work/Plan|the plan]] and [[Draft]]\n")
        XCTAssertEqual(text(work.appendingPathComponent("Draft.md")), draftText, "the links inside find what they found")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Rename")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(papers))
        XCTAssertEqual(text(index), indexText)
        try await redo(workspace, manager)
        XCTAssertEqual(text(index), "[[Work/Plan|the plan]] and [[Draft]]\n")
    }

    /// A folder moved into another one: links that still find what they found by its name stay, and one that found a
    /// note in it because it was shallower than another of its name says which it means now.
    func testAMovedFolderTakesTheLinksIntoItAlong() async throws {
        let deep = archive.appendingPathComponent("2025/Old")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: archive.appendingPathComponent("Plan.md"), to: deep.appendingPathComponent("Plan.md"))
        let top = library.appendingPathComponent("Top.md")
        try "[[Plan]] and [[Old/Plan]]".write(to: top, atomically: true, encoding: .utf8)
        let (workspace, manager) = try await makeWindow()
        _ = await workspace.move(papers, into: archive.appendingPathComponent("2025")).value
        try await settle(workspace, manager)
        XCTAssertEqual(text(index), "[[Papers/Plan|the plan]] and [[Draft]]\n", "still found by its folder's name")
        XCTAssertEqual(text(archive.appendingPathComponent("2025/Papers/Draft.md")), draftText)
        XCTAssertEqual(text(top), "[[Papers/Plan]] and [[Old/Plan]]")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertEqual(text(top), "[[Plan]] and [[Old/Plan]]")
    }

    // MARK: - Open notes

    /// The note open in the editor changes there, with what was typed and not saved yet, and the caret where it was;
    /// the change to its text is a step of Undo of its own, before the move's.
    func testTheOpenNoteChangesInTheEditor() async throws {
        let (workspace, manager) = try await makeWindow()
        let writes = mainThreadWrites
        workspace.open(draft)
        try await until("open") { workspace.note?.isLoaded == true }
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: workspace.editor.text.utf16.count, length: 0))
        textView.insertText("Typed.", replacementRange: textView.selectedRange())
        // The typing's step of Undo closes, as at the end of an event; it may not be saved yet.
        try await until("the group closed") { manager.groupingLevel == 0 }
        _ = await workspace.move(plan, into: later).value
        try await settle(workspace, manager)
        XCTAssertEqual(workspace.editor.text, draftText.replacingOccurrences(of: "[[Plan]]", with: "[[Later/Plan]]") + "Typed.")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: workspace.editor.text.utf16.count, length: 0), "the caret stayed")
        try await until("saved") { self.text(self.draft) == workspace.editor.text }
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Update Links")

        try await undo(workspace, manager)
        XCTAssertEqual(workspace.editor.text, draftText + "Typed.")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move")
        try await undo(workspace, manager)
        XCTAssertTrue(exists(plan))
        XCTAssertEqual(workspace.editor.text, draftText + "Typed.")
        try await until("saved") { self.text(self.draft) == self.draftText + "Typed." }
        XCTAssertEqual(text(index), indexText)
        XCTAssertEqual(mainThreadWrites, writes, "files changed on the main thread")
    }

    /// The open note moved: its own links look in its new folder first, so the one that would find another note
    /// there says which it means; its picture comes along.
    func testTheMovedOpenNoteKeepsItsLinksAndPicture() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.open(draft)
        try await until("open") { workspace.note?.isLoaded == true }
        let moved = archive.appendingPathComponent("Draft.md")
        _ = await workspace.move(draft, into: archive).value
        try await settle(workspace, manager)
        XCTAssertEqual(workspace.currentURL?.path, moved.path)
        XCTAssertEqual(workspace.editor.text, draftText.replacingOccurrences(of: "[[Plan]]", with: "[[Papers/Plan]]"))
        try await until("saved") { self.text(moved) == workspace.editor.text }
        try await until("its picture came along") { self.exists(self.archive.appendingPathComponent(".assets/chart.png")) }
        XCTAssertEqual(workspace.index.resolve("Papers/Plan", from: moved)?.path, plan.path)

        try await undo(workspace, manager)
        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertEqual(workspace.editor.text, draftText)
        try await until("saved") { self.text(self.draft) == self.draftText }
    }

    // MARK: - Pictures

    /// Moved into a folder whose `.assets` has another picture of the same name, a note's picture comes along under a
    /// name of its own, which the note says; the other picture stays as it was. Undo takes the note back to its own.
    func testAPictureWhoseNameIsTakenThereComesUnderItsOwn() async throws {
        let ownPicture = Data([0x89, 0x50, 0x4E, 0x47])
        let otherPicture = Data([1, 2, 3])
        try FileManager.default.createDirectory(at: archive.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try otherPicture.write(to: archive.appendingPathComponent(".assets/chart.png"))
        let report = archive.appendingPathComponent("Report.md")
        try "![Other chart](.assets/chart.png)\n".write(to: report, atomically: true, encoding: .utf8)
        let (workspace, manager) = try await makeWindow()
        let moved = archive.appendingPathComponent("Draft.md")
        _ = await workspace.move(draft, into: archive).value
        try await settle(workspace, manager)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(".assets/chart 2.png")), ownPicture)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(".assets/chart.png")), otherPicture)
        XCTAssertEqual(text(moved), "# Draft\n\n![Chart](.assets/chart%202.png)\n\nSee [[Papers/Plan]].\n")
        XCTAssertEqual(text(report), "![Other chart](.assets/chart.png)\n")

        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertEqual(text(draft), "# Draft\n\n![Chart](.assets/chart%202.png)\n\nSee [[Plan]].\n", "the links back, the picture under its new name")
        try await until("its picture came back") { self.exists(self.papers.appendingPathComponent(".assets/chart 2.png")) }
        XCTAssertEqual(try Data(contentsOf: papers.appendingPathComponent(".assets/chart 2.png")), ownPicture)
        XCTAssertEqual(try Data(contentsOf: papers.appendingPathComponent(".assets/chart.png")), ownPicture, "kept where it was")
    }

    /// The same with the note open: it shows its own picture under its new name at once.
    func testThePictureOfTheOpenNoteMovedWhereItsNameIsTaken() async throws {
        try FileManager.default.createDirectory(at: archive.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: archive.appendingPathComponent(".assets/chart.png"))
        let (workspace, manager) = try await makeWindow()
        workspace.open(draft)
        try await until("open") { workspace.note?.isLoaded == true }
        _ = await workspace.move(draft, into: archive).value
        try await settle(workspace, manager)
        XCTAssertEqual(workspace.editor.text, "# Draft\n\n![Chart](.assets/chart%202.png)\n\nSee [[Papers/Plan]].\n")
        try await until("saved") { self.text(self.archive.appendingPathComponent("Draft.md")) == workspace.editor.text }
        // Undo takes back the links, the picture's name and the move, one after another, as each came.
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Update Links")
        try await undo(workspace, manager)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Change from Another Device")
        try await undo(workspace, manager)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Move")
        try await undo(workspace, manager)
        XCTAssertTrue(exists(draft))
        XCTAssertEqual(workspace.editor.text, draftText)
        try await until("saved") { self.text(self.draft) == self.draftText }
        XCTAssertEqual(try Data(contentsOf: papers.appendingPathComponent(".assets/chart.png")), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Another note open while a move's links are taken back by Undo: it changes in its editor too.
    func testUndoChangesTheNoteOpenThen() async throws {
        let (workspace, manager) = try await makeWindow()
        _ = await workspace.move(plan, into: later).value
        try await settle(workspace, manager)
        XCTAssertEqual(text(index), "[[Later/Plan|the plan]] and [[Draft]]\n")
        workspace.open(index)
        try await until("open") { workspace.note?.isLoaded == true }
        try await undo(workspace, manager)
        XCTAssertEqual(workspace.editor.text, indexText)
        try await until("saved") { self.text(self.index) == self.indexText }
        XCTAssertEqual(text(draft), draftText)
    }

    // MARK: - Renaming

    /// A renamed note's links follow it, only those that found it, and keep what they show.
    func testARenamedNotesLinksFollowIt() async throws {
        let (workspace, manager) = try await makeWindow()
        let other = archive.appendingPathComponent("Notes.md")
        try "[[Plan]] is the old one, [[Papers/Plan]] the new.".write(to: other, atomically: true, encoding: .utf8)
        workspace.index.refresh(folders: [archive], locations: workspace.locations)
        try await until("indexed") { workspace.index.entry(for: other)?.text != nil }
        _ = await workspace.rename(plan, to: "Proposal").value
        try await settle(workspace, manager)
        XCTAssertEqual(text(draft), draftText.replacingOccurrences(of: "[[Plan]]", with: "[[Proposal]]"))
        XCTAssertEqual(text(index), "[[Proposal|the plan]] and [[Draft]]\n")
        XCTAssertEqual(text(other), "[[Plan]] is the old one, [[Proposal]] the new.")
        try await undo(workspace, manager)
        XCTAssertEqual(text(other), "[[Plan]] is the old one, [[Papers/Plan]] the new.")
        XCTAssertEqual(text(index), indexText)
    }

    /// A note from outside the locations, renamed in its own window: the links to it in the notes next to it follow.
    func testANoteFromOutsideRenamedInItsWindow() async throws {
        let note = outside.appendingPathComponent("Draft.md")
        try "# Draft\n\n[[Other]]\n".write(to: note, atomically: true, encoding: .utf8)
        try "See [[Draft]] and [[Draft#Top|the top]].\n".write(to: outside.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        try "[[draft.md]]\n".write(to: outside.appendingPathComponent("Third.md"), atomically: true, encoding: .utf8)
        FileWindows.shared.open(note)
        let controller = try XCTUnwrap(FileWindows.shared.windows.compactMap { $0.windowController as? FileWindowController }.first { FileNode.samePath($0.url, note) })
        fileWindows.append(try XCTUnwrap(controller.window))
        try await until("open") { controller.isLoaded }
        controller.editor(controller.editor, commitTitle: "Plan")
        try await until("renamed") { self.exists(self.outside.appendingPathComponent("Plan.md")) }
        try await until("its window followed") { FileNode.samePath(controller.url, self.outside.appendingPathComponent("Plan.md")) }
        await Workspace.shared.linksFollowed()
        XCTAssertEqual(text(outside.appendingPathComponent("Other.md")), "See [[Plan]] and [[Plan#Top|the top]].\n")
        XCTAssertEqual(text(outside.appendingPathComponent("Third.md")), "[[Plan.md]]\n")
        XCTAssertEqual(text(outside.appendingPathComponent("Plan.md")), "# Draft\n\n[[Other]]\n")
    }
}
