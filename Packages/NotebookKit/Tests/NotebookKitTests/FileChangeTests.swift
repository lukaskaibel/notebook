import XCTest
@testable import NotebookKit

/// Renaming, new notes, duplicating, moving and throwing away never make the window wait for the disk or iCloud: each
/// is written off the main thread, shows in the sidebar as soon as it has been, before its folder is read again, and
/// nothing goes back to how it was meanwhile. `-NotebookSlowWrites` and `-NotebookSlowFolders` stand in for a slow
/// iCloud; no folder is read and no file changed on the main thread.
@MainActor
final class FileChangeTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var archive: URL { library.appendingPathComponent("Archive") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var other: URL { papers.appendingPathComponent("Other.md") }
    private var chart: URL { papers.appendingPathComponent(".assets/chart.png") }
    private var windows: [NSWindow] = []
    private var readsBefore = 0
    private var writesBefore = 0

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-changes-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Draft\n\n![Chart](.assets/chart.png)\n".write(to: draft, atomically: true, encoding: .utf8)
        try "# Other\n".write(to: other, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: chart)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookSlowFolders", "NotebookSlowWrites", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FileLoading.debugDelay = nil
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        try? FileManager.default.removeItem(at: library)
    }

    /// The library, read, in a sidebar in a window, with Papers and Archive open.
    private func makeSidebar() async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle && self.row("Papers", in: sidebar) != nil }
        for folder in [papers, archive] {
            await withCheckedContinuation { done in workspace.readFolders(to: folder, including: true) { done.resume() } }
            sidebar.outline.expandItem(try XCTUnwrap(workspace.node(for: folder, reading: false)))
        }
        window.layoutIfNeeded()
        readsBefore = FileNode.mainThreadReads.withLock { $0 }
        writesBefore = FileOperations.mainThreadWrites.withLock { $0 }
        return (workspace, sidebar)
    }

    /// The editor in a window of its own, for the alerts that come over it.
    private func showEditor(of workspace: Workspace) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        window.contentView = workspace.editor.view
        return window
    }

    private func slow(writes: Double = 0, folders: Double = 0) {
        UserDefaults.standard.set(writes, forKey: "NotebookSlowWrites")
        UserDefaults.standard.set(folders, forKey: "NotebookSlowFolders")
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The row of a file by its file name, wherever it is in the sidebar.
    private func row(_ fileName: String, under folder: URL? = nil, in sidebar: SidebarController) -> Int? {
        (0..<sidebar.outline.numberOfRows).first {
            guard let node = sidebar.outline.item(atRow: $0) as? FileNode, node.url.lastPathComponent == fileName else { return false }
            return folder.map { FileNode.samePath(node.url.deletingLastPathComponent(), $0) } ?? true
        }
    }

    /// What the rows of a folder's files say.
    private func names(under folder: URL, in sidebar: SidebarController) -> [String] {
        (0..<sidebar.outline.numberOfRows).compactMap { row in
            guard let node = sidebar.outline.item(atRow: row) as? FileNode, FileNode.samePath(node.url.deletingLastPathComponent(), folder) else { return nil }
            return label(at: row, in: sidebar)
        }
    }

    private func label(at row: Int, in sidebar: SidebarController) -> String? {
        (sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFileCell)?.label.stringValue
    }

    /// Renames a file in the sidebar as you would: Return, the name, Return.
    private func typeName(_ name: String, for fileName: String, in sidebar: SidebarController) throws {
        let row = try XCTUnwrap(row(fileName, in: sidebar))
        sidebar.beginRenaming(try XCTUnwrap((sidebar.outline.item(atRow: row) as? FileNode)?.url))
        let field = try XCTUnwrap((sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFileCell)?.label.currentEditor() as? NSTextView)
        field.insertText(name, replacementRange: field.selectedRange())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    private func assertNothingOnTheMainThread(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(FileNode.mainThreadReads.withLock { $0 }, readsBefore, "folders read on the main thread", file: file, line: line)
        XCTAssertEqual(FileOperations.mainThreadWrites.withLock { $0 }, writesBefore, "files changed on the main thread", file: file, line: line)
    }

    // MARK: - Renaming

    /// While iCloud takes its time, the row keeps the name typed, whatever reloads the sidebar meanwhile; once the file
    /// is renamed it shows under its new name before Papers has been read again, and never under the old one.
    func testARenameInTheSidebarKeepsTheNameTypedWhileItIsWritten() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        slow(writes: 0.5, folders: 0.5)
        let start = Date()
        try typeName("Plan", for: "Draft.md", in: sidebar)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3, "waited for the disk")
        XCTAssertTrue(exists(draft), "renamed before the slow write")
        sidebar.reloadAll()
        XCTAssertEqual(names(under: papers, in: sidebar), ["Plan", "Other"], "went back to the old name while it was written")

        let plan = papers.appendingPathComponent("Plan.md")
        try await until("renamed in the sidebar") { self.row("Plan.md", in: sidebar) != nil }
        XCTAssertTrue(exists(plan))
        // Writing takes half a second, reading Papers again another.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.95, "waited for Papers to be read again")
        XCTAssertEqual(names(under: papers, in: sidebar), ["Other", "Plan"])
        try await until("Papers read again", seconds: 5) { workspace.reader.isIdle }
        XCTAssertEqual(names(under: papers, in: sidebar), ["Other", "Plan"])
        XCTAssertTrue(workspace.newNames.isEmpty)
        assertNothingOnTheMainThread()
    }

    /// A name that is taken: an alert says so, and the row says the old name again.
    func testANameAlreadyTakenGoesBack() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let window = showEditor(of: workspace)
        try typeName("Other", for: "Draft.md", in: sidebar)
        try await until("the alert") { window.attachedSheet != nil }
        sidebar.reloadAll()
        XCTAssertEqual(names(under: papers, in: sidebar), ["Draft", "Other"])
        XCTAssertTrue(exists(draft))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "# Other\n")
        assertNothingOnTheMainThread()
    }

    /// The open note renamed by its title: what is typed meanwhile is saved under the new name, and the old one never
    /// comes back on disk.
    func testWhatIsTypedWhileTheOpenNoteIsRenamedIsSavedUnderItsNewName() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        _ = showEditor(of: workspace)
        workspace.open(draft)
        slow(writes: 0.5)
        workspace.editor(workspace.editor, commitTitle: "Plan")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(exists(draft), "renamed before the slow write")
        XCTAssertEqual(names(under: papers, in: sidebar), ["Plan", "Other"], "the sidebar said the old name meanwhile")
        XCTAssertEqual(workspace.currentTitle, "Plan")
        let note = try XCTUnwrap(workspace.note)
        note.update(text: "# Draft\n\nMore.\n")
        note.saveNow()
        XCTAssertTrue(note.hasUnsavedChanges, "saved where the note was, while it moved")

        let plan = papers.appendingPathComponent("Plan.md")
        try await until("renamed and saved") { (try? String(contentsOf: plan, encoding: .utf8)) == "# Draft\n\nMore.\n" }
        XCTAssertFalse(exists(draft), "the old name came back")
        XCTAssertEqual(workspace.currentURL?.lastPathComponent, "Plan.md")
        XCTAssertEqual(workspace.editor.titleText, "Plan")
        try await until("in the sidebar") { self.row("Plan.md", in: sidebar) != nil }
        assertNothingOnTheMainThread()
    }

    /// A renamed folder stays open, with the folders in it that were open, as in the Finder. The note open in it
    /// follows, its pictures with it, and search finds what is in it under its new name, however deep.
    func testARenamedFolderStaysOpen() async throws {
        let figures = papers.appendingPathComponent("Figures")
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        try Data().write(to: figures.appendingPathComponent("plot.png"))
        let (workspace, sidebar) = try await makeSidebar()
        await withCheckedContinuation { done in workspace.readFolders(to: figures, including: true) { done.resume() } }
        sidebar.outline.expandItem(try XCTUnwrap(workspace.node(for: figures, reading: false)))
        XCTAssertEqual(names(under: figures, in: sidebar), ["plot.png"])
        workspace.open(draft)
        try await until("search knows the picture") { workspace.index.entry(for: figures.appendingPathComponent("plot.png")) != nil }

        slow(folders: 0.3)
        let renamed = await workspace.rename(papers, to: "Writing").value
        let writing = library.appendingPathComponent("Writing")
        XCTAssertEqual(renamed?.path, writing.path)
        XCTAssertEqual(names(under: writing, in: sidebar), ["Figures", "Draft", "Other"], "closed, or waited for Writing to be read")
        XCTAssertEqual(names(under: writing.appendingPathComponent("Figures"), in: sidebar), ["plot.png"])
        XCTAssertEqual(workspace.currentURL?.path, writing.appendingPathComponent("Draft.md").path)
        XCTAssertEqual(workspace.editor.folder?.path, writing.path, "its pictures were looked for where it was")
        try await until("search finds what is in it") {
            workspace.index.entry(for: writing.appendingPathComponent("Figures/plot.png")) != nil
                && workspace.index.entry(for: figures.appendingPathComponent("plot.png")) == nil
        }
        let other = try XCTUnwrap(workspace.index.resolve("Other", from: workspace.currentURL))
        XCTAssertTrue(FileNode.samePath(other, writing.appendingPathComponent("Other.md")), other.path)
        assertNothingOnTheMainThread()
    }

    // MARK: - New notes and copies

    /// ⌘N: the call comes back at once, the note shows and opens once it has been made, before its folder has been
    /// read again; left empty, it goes away again.
    func testANewNoteShowsAndOpensAtOnce() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        slow(writes: 0.3, folders: 1)
        let start = Date()
        let making = workspace.newNote(in: papers)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "waited for the disk")
        let made = await making.value
        // Reading Papers again takes a second.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9, "waited for Papers to be read again")
        let untitled = try XCTUnwrap(made)
        XCTAssertEqual(untitled.lastPathComponent, "Untitled.md")
        XCTAssertEqual(workspace.currentURL?.path, untitled.path)
        XCTAssertEqual(workspace.note?.isNew, true)
        XCTAssertEqual(names(under: papers, in: sidebar), ["Draft", "Other", "Untitled"])

        slow()
        workspace.open(draft)
        try await until("the empty note went") { !self.exists(untitled) && self.names(under: self.papers, in: sidebar) == ["Draft", "Other"] }
        assertNothingOnTheMainThread()
    }

    /// The first note with nothing selected goes into an Inbox, which shows with it.
    func testTheFirstNoteMakesTheInbox() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        slow(folders: 1)
        let made = await workspace.newNote(title: "Groceries").value
        let note = try XCTUnwrap(made)
        XCTAssertEqual(note.deletingLastPathComponent().lastPathComponent, "Inbox")
        XCTAssertEqual(workspace.note?.isNew, false, "it has its name")
        XCTAssertNotNil(row("Inbox", in: sidebar))
        assertNothingOnTheMainThread()
    }

    func testADuplicateShowsNextToTheFile() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        slow(writes: 0.3, folders: 1)
        let copying = workspace.duplicate(draft)
        let copy = await copying.value
        XCTAssertEqual(copy?.lastPathComponent, "Draft copy.md")
        // In the Finder's order, before Papers has been read again.
        let files = ["Draft.md", "Draft copy.md", "Other.md"].sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(names(under: papers, in: sidebar), files.map { ($0 as NSString).deletingPathExtension })
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(copy), encoding: .utf8), try String(contentsOf: draft, encoding: .utf8))
        assertNothingOnTheMainThread()
    }

    // MARK: - Throwing away

    /// The open note thrown away: gone from the sidebar at once, and the Mac goes back to the note before.
    func testATrashedNoteGoesAtOnce() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        workspace.open(draft)
        workspace.open(other)
        slow(writes: 0.3, folders: 1)
        let trashed = await workspace.trash(other).value
        XCTAssertTrue(trashed)
        XCTAssertFalse(exists(other))
        XCTAssertEqual(names(under: papers, in: sidebar), ["Draft"])
        XCTAssertEqual(workspace.currentURL?.path, draft.path)
        assertNothingOnTheMainThread()
    }

    /// A file on its way to the Trash, or a folder it is in, is out of Recent and Favorites until it has gone, and back
    /// in them if it couldn't go. The same file asked to go twice is out until both are done.
    func testFilesOnTheirWayToTheTrashLeaveTheLists() async throws {
        let (workspace, _) = try await makeSidebar()
        workspace.open(draft)
        workspace.open(other)
        workspace.open(chart)
        workspace.toggleFavorite(draft)
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Other.md", "Draft.md"])
        XCTAssertTrue(workspace.recentURLs(includingOpen: true).contains(draft))

        workspace.beginLeaving(papers)
        XCTAssertTrue(workspace.isLeaving(draft))
        XCTAssertTrue(workspace.isLeaving(papers))
        XCTAssertFalse(workspace.isLeaving(archive))
        XCTAssertFalse(workspace.isLeaving(library.appendingPathComponent("Papers copy/Draft.md")))
        XCTAssertEqual(workspace.recentURLs, [])
        // Nor on the iPhone's first screen, which lists the open note too.
        XCTAssertFalse(workspace.recentURLs(includingOpen: true).contains(draft))
        XCTAssertEqual(workspace.favoriteURLs, [])

        workspace.beginLeaving(papers)
        workspace.endLeaving(papers)
        XCTAssertTrue(workspace.isLeaving(draft), "asked twice, done once")
        // "/private/var/…" and "/var/…" are one folder.
        workspace.endLeaving(URL(fileURLWithPath: HiddenFolders.withoutPrivate(papers.path)), animated: true)
        XCTAssertFalse(workspace.isLeaving(draft))
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Other.md", "Draft.md"])
        XCTAssertEqual(workspace.favoriteURLs.map(\.lastPathComponent), ["Draft.md"])
    }

    /// Deleted while its rename, or its folder's, is still under way, a file stays out of the lists under its new name
    /// too, rather than showing again once the rename is done.
    func testAFileLeavingFollowsARenameUnderWay() async throws {
        let (workspace, _) = try await makeSidebar()
        let renaming = workspace.rename(draft, to: "Plan")
        workspace.beginLeaving(draft)
        let renamed = await renaming.value
        let plan = try XCTUnwrap(renamed)
        XCTAssertEqual(plan.lastPathComponent, "Plan.md")
        XCTAssertTrue(workspace.isLeaving(plan))
        XCTAssertFalse(workspace.isLeaving(draft))

        let renamingFolder = workspace.rename(papers, to: "Writing")
        let renamedFolder = await renamingFolder.value
        let writing = try XCTUnwrap(renamedFolder)
        XCTAssertTrue(workspace.isLeaving(writing.appendingPathComponent("Plan.md")))
        workspace.endLeaving(writing.appendingPathComponent("Plan.md"))
        XCTAssertFalse(workspace.isLeaving(writing.appendingPathComponent("Plan.md")))
        XCTAssertTrue(workspace.leaving.isEmpty)
    }

    /// "Delete immediately?" asks about one file at a time, in the order they couldn't go to the Trash, and the next
    /// question waits until the alert answered has gone. One that fails while it is going away waits its turn too,
    /// rather than showing at once, where it wouldn't show, and putting the one before it off for good.
    func testDeleteQuestionsAskOneAtATime() {
        let a = library.appendingPathComponent("A.md"), b = library.appendingPathComponent("B.md")
        let c = library.appendingPathComponent("C.md")
        var questions = DeleteQuestions()
        questions.ask(a)
        questions.ask(b)
        XCTAssertEqual(questions.asking, a)
        questions.answered(a)
        XCTAssertNil(questions.asking, "the alert is still going away")
        questions.ask(c)
        XCTAssertNil(questions.asking)
        questions.gone()
        XCTAssertEqual(questions.asking, b)
        XCTAssertEqual(questions.waiting, [c])
        questions.answered(b)
        questions.gone()
        XCTAssertEqual(questions.asking, c)
        questions.answered(c)
        questions.gone()
        XCTAssertNil(questions.asking)
        XCTAssertEqual(questions.waiting, [])
        questions.ask(a)
        XCTAssertEqual(questions.asking, a, "with no alert going away, at once")
    }

    /// Search finds a note thrown away until it has read its folder again: it is left out of the results meanwhile,
    /// and so is what was in a folder thrown away. Put back from the Trash, it is there again.
    func testSearchLeavesOutWhatWasThrownAway() async throws {
        let (workspace, _) = try await makeSidebar()
        let manager = workspace.fileUndoManager
        XCTAssertFalse(workspace.isThrownAway(other))
        let trashed = await workspace.trash(other).value
        XCTAssertTrue(trashed)
        XCTAssertTrue(workspace.isThrownAway(other))
        XCTAssertFalse(workspace.isThrownAway(draft))

        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("put back") { self.exists(self.other) }
        await workspace.changeFiles { _ in }.value
        XCTAssertFalse(workspace.isThrownAway(other), "back where it was")

        let folderTrashed = await workspace.trash(papers).value
        XCTAssertTrue(folderTrashed)
        XCTAssertTrue(workspace.isThrownAway(draft), "in a folder thrown away")
        XCTAssertFalse(workspace.isThrownAway(archive))
    }

    /// A note thrown away a moment after it was left, while what was typed in it is still being written: that goes
    /// along to the Trash, and the note doesn't come back where it was.
    func testWhatWasTypedGoesAlongToTheTrash() async throws {
        let (workspace, _) = try await makeSidebar()
        workspace.open(other)
        slow(writes: 0.4)
        workspace.editor.insert("Typed. ")
        workspace.saveAll()
        // Saved after the save under way.
        workspace.editor.insert("More. ")
        workspace.open(draft)
        XCTAssertTrue(NoteDocument.isWriting, "written before it was left")
        let trashed = await workspace.trashNow(other)
        XCTAssertTrue(trashed.done)
        defer { trashed.place.map { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(trashed.place.flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "Typed. More. # Other\n")
        await NoteDocument.allWritten()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(exists(other), "came back")
        assertNothingOnTheMainThread()
    }

    // MARK: - Moving

    /// A note moved a moment after it was left, while what was typed in it is still being written: that is written
    /// before it moves, and nothing is left where it was.
    func testWhatWasTypedMovesAlong() async throws {
        let (workspace, _) = try await makeSidebar()
        workspace.open(other)
        workspace.editor.insert("Typed. ")
        slow(writes: 0.4)
        workspace.open(draft)
        let moving = await workspace.move(other, into: archive).value
        let moved = try XCTUnwrap(moving)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "Typed. # Other\n")
        await NoteDocument.allWritten()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(exists(other), "came back")
        assertNothingOnTheMainThread()
    }

    /// Moved to another folder, the open note follows, takes its picture along before it shows there, and the picture
    /// no note in Papers uses any more goes away from there.
    func testAMovedNoteTakesItsPicturesAlong() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        workspace.open(draft)
        slow(writes: 0.3, folders: 1)
        let moving = await workspace.move(draft, into: archive).value
        let moved = try XCTUnwrap(moving)
        let target = archive.appendingPathComponent("Draft.md")
        XCTAssertEqual(moved.path, target.path)
        XCTAssertEqual(names(under: papers, in: sidebar), ["Other"])
        XCTAssertEqual(names(under: archive, in: sidebar), ["Draft"])
        XCTAssertEqual(workspace.note?.url.path, target.path)
        XCTAssertEqual(workspace.editor.folder?.path, archive.path)
        XCTAssertTrue(exists(archive.appendingPathComponent(".assets/chart.png")), "its picture came along before it showed there")
        try await until("the picture left behind went") { !self.exists(self.chart) }

        // Into the folder it is in: nothing happens, rather than a copy of its name with a number.
        let again = await workspace.move(target, into: archive).value
        XCTAssertEqual(again?.path, target.path)
        XCTAssertFalse(exists(archive.appendingPathComponent("Draft 2.md")))
        assertNothingOnTheMainThread()
    }

    /// A note still in iCloud (issue #48) moves at once; its pictures follow once its text has come down.
    func testANoteStillInICloudMovesWithoutWaitingForIt() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        FileLoading.debugDelay = 1
        let start = Date()
        let moved = await workspace.move(draft, into: archive).value
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "waited for the note to come down")
        XCTAssertEqual(moved?.lastPathComponent, "Draft.md")
        XCTAssertEqual(names(under: archive, in: sidebar), ["Draft"])
        let picture = archive.appendingPathComponent(".assets/chart.png")
        XCTAssertFalse(exists(picture))
        try await until("its picture came along", seconds: 4) { self.exists(picture) && !self.exists(self.chart) }
        assertNothingOnTheMainThread()
    }

    /// Dropped on a folder: moved from elsewhere in the locations, copied from anywhere else.
    func testDroppedFilesMoveOrAreCopied() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let outside = library.deletingLastPathComponent().appendingPathComponent("notebook-outside-\(UUID().uuidString).md")
        try "# Outside\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        slow(writes: 0.2, folders: 1)
        workspace.drop([other, outside], into: archive)
        try await until("both in Archive") { self.names(under: self.archive, in: sidebar).count == 2 }
        let files = [outside.lastPathComponent, "Other.md"].sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(names(under: archive, in: sidebar), files.map { ($0 as NSString).deletingPathExtension })
        XCTAssertEqual(names(under: papers, in: sidebar), ["Draft"])
        XCTAssertTrue(exists(outside), "copied, not moved")
        assertNothingOnTheMainThread()
    }

    // MARK: - One after another

    /// Changes asked for while one is still being written wait for it, and find the file where it went: a note renamed,
    /// then moved by the name it had in the sidebar a moment ago, then thrown away there.
    func testChangesAskedForMeanwhileFollowTheFile() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        slow(writes: 0.3)
        let renaming = workspace.rename(draft, to: "Plan")
        let moving = workspace.move(draft, into: archive)
        let renamingFolder = workspace.rename(archive, to: "Old")
        let renamed = await renaming.value
        let moved = await moving.value
        let folder = await renamingFolder.value
        XCTAssertEqual(renamed?.lastPathComponent, "Plan.md")
        XCTAssertEqual(moved?.path, archive.appendingPathComponent("Plan.md").path)
        let old = library.appendingPathComponent("Old")
        XCTAssertEqual(folder?.path, old.path)
        XCTAssertTrue(exists(old.appendingPathComponent("Plan.md")))
        XCTAssertTrue(exists(old.appendingPathComponent(".assets/chart.png")))

        let trashed = await workspace.trash(draft).value
        XCTAssertFalse(trashed, "the relocations are forgotten once nothing is under way")
        XCTAssertNotNil(row("Old", in: sidebar))
        assertNothingOnTheMainThread()
    }
}
