import NotebookCapture
import XCTest
@testable import NotebookKit

/// What the share extension leaves for the app, written by it: a new note in the default folder, or the end of the
/// note opened last, with pictures and files in `.assets` as the editor puts them in.
@MainActor
final class SharedNotesTests: XCTestCase {
    private var library: URL!
    private var outbox: URL!
    private var given: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var inbox: URL { library.appendingPathComponent("Inbox") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-shared-\(UUID().uuidString)").standardizedFileURL
        library = root.appendingPathComponent("Notes")
        outbox = root.appendingPathComponent("Shared Notes")
        given = root.appendingPathComponent("Given")
        for folder in [papers, outbox!, given!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "# Draft\n\nSome text.\n".write(to: draft, atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF]).write(to: given.appendingPathComponent("Torii.jpg"))
        try Data("%PDF-1.4".utf8).write(to: given.appendingPathComponent("Tickets.pdf"))
        SharedNotes.folder = outbox
        SharedNotes.defaults = TestRun.settings()
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookWelcome", "expandedFolders"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        SharedNotes.defaults = nil
        SharedNotes.folder = nil
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    private func makeWorkspace() -> Workspace {
        let workspace = Workspace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = workspace.editor.view
        return workspace
    }

    /// As the share extension leaves it: the files are its own copies, moved over.
    @discardableResult
    private func share(_ destination: SharedNote.Destination = .newNote, title: String? = "Kyoto", text: String, files: [String] = []) throws -> SharedNote {
        let copies = given.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        for name in files { try FileManager.default.copyItem(at: given.appendingPathComponent(name), to: copies.appendingPathComponent(name)) }
        let note = SharedNote(destination: destination, title: title, text: text, files: files)
        try SharedNotes.add(note, moving: files.map { (copies.appendingPathComponent($0), $0) })
        return note
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testANewNoteGoesToTheInboxWithItsPicturesAndFiles() async throws {
        try share(text: "[Kyoto guide](https://example.com/kyoto)\n", files: ["Torii.jpg", "Tickets.pdf"])
        let workspace = makeWorkspace()
        await workspace.takeSharedNotes()
        let note = inbox.appendingPathComponent("Kyoto.md")
        XCTAssertEqual(try read(note), """
        [Kyoto guide](https://example.com/kyoto)

        ![](.assets/Torii.jpg)
        ![Tickets.pdf](.assets/Tickets.pdf)

        """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(".assets/Torii.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(".assets/Tickets.pdf").path))
        XCTAssertTrue(SharedNotes.waiting().isEmpty, "written and still waiting")
        XCTAssertNil(workspace.currentURL, "a shared note opened over what was open")
    }

    func testANewNoteGoesToTheDefaultFolderChosen() async throws {
        try share(title: nil, text: "Milk")
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.chooseDefaultFolder(papers)
        await workspace.takeSharedNotes()
        XCTAssertEqual(try read(papers.appendingPathComponent("Untitled.md")), "Milk\n")
    }

    func testAPictureWhoseNameIsTakenGetsAnotherName() async throws {
        let assets = papers.appendingPathComponent(".assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([1]).write(to: assets.appendingPathComponent("Torii.jpg"))
        try share(.endOf(path: draft.path), text: "", files: ["Torii.jpg"])
        await makeWorkspace().takeSharedNotes()
        XCTAssertEqual(try read(draft), "# Draft\n\nSome text.\n\n![](.assets/Torii%202.jpg)\n")
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("Torii.jpg")), Data([1]), "the picture there was replaced")
    }

    /// Not open: read and written in one go, after a blank line.
    func testTextGoesAtTheEndOfTheNoteOpenedLast() async throws {
        try share(.endOf(path: draft.path), text: "A thought.")
        await makeWorkspace().takeSharedNotes()
        XCTAssertEqual(try read(draft), "# Draft\n\nSome text.\n\nA thought.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path), "a new note was made too")
    }

    /// Open: in the editor, as one step of Undo, saved, with the caret where it was.
    func testTextGoesIntoTheOpenNotesEditor() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.open(draft)
        try await until("the note was shown") { workspace.editor.text == "# Draft\n\nSome text.\n" }
        workspace.editor.setSelection(NSRange(location: 2, length: 0))
        try share(.endOf(path: draft.path), text: "A thought.", files: ["Torii.jpg"])
        await workspace.takeSharedNotes()
        let expected = "# Draft\n\nSome text.\n\nA thought.\n\n![](.assets/Torii.jpg)\n"
        XCTAssertEqual(workspace.editor.text, expected)
        XCTAssertEqual(workspace.editor.selection, NSRange(location: 2, length: 0), "the caret moved")
        try await until("it was saved") { (try? self.read(self.draft)) == expected }
        workspace.editor.textView.undoManager?.undo()
        XCTAssertEqual(workspace.editor.text, "# Draft\n\nSome text.\n")
    }

    func testANoteGoneSinceGetsANoteOfItsOwn() async throws {
        try share(.endOf(path: papers.appendingPathComponent("Gone.md").path), title: "Thought", text: "A thought.")
        await makeWorkspace().takeSharedNotes()
        XCTAssertEqual(try read(inbox.appendingPathComponent("Thought.md")), "A thought.\n")
    }

    /// Without a location there is nowhere to write it yet.
    func testWithoutALocationItWaits() async throws {
        UserDefaults.standard.set(true, forKey: "NotebookWelcome")
        try share(text: "Milk")
        await makeWorkspace().takeSharedNotes()
        XCTAssertEqual(SharedNotes.waiting().map(\.note.text), ["Milk"])
    }

    /// Text at the end of a PDF or a picture would ruin it: shared "to the end" of one, it becomes a note of its own.
    func testOnlyANoteIsAddedTo() async throws {
        let pdf = papers.appendingPathComponent("Tickets.pdf")
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        try bytes.write(to: pdf)
        try share(.endOf(path: pdf.path), title: "Thought", text: "A thought.")
        await makeWorkspace().takeSharedNotes()
        XCTAssertEqual(try Data(contentsOf: pdf), bytes, "the PDF was written into")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Thought.md")), "A thought.\n")
    }

    /// The note to add to is looked for in an editor only once its files are copied. The copy is held up here, as
    /// iCloud can, by a coordinated write on the file, and meanwhile another note is opened: the text goes into the
    /// note's file, not into the editor now showing the other one.
    func testTheNoteIsLookedForWhenTheFilesAreCopied() async throws {
        let errands = library.appendingPathComponent("Errands.md")
        try "- [ ] Milk\n".write(to: errands, atomically: true, encoding: .utf8)
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.open(draft)
        try await until("the note was shown") { workspace.editor.text == "# Draft\n\nSome text.\n" }
        let note = try share(.endOf(path: draft.path), text: "A thought.", files: ["Torii.jpg"])
        let file = outbox.appendingPathComponent(note.id.uuidString).appendingPathComponent("Torii.jpg")
        let holding = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: nil) { _ in
                held.signal()
                holding.wait()
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { held.wait(); continuation.resume() } }
        let taking = Task { await workspace.takeSharedNotes() }
        try await Task.sleep(for: .milliseconds(300))
        workspace.open(errands)
        try await until("the other note was shown") { workspace.editor.text == "- [ ] Milk\n" }
        holding.signal()
        await taking.value
        XCTAssertEqual(workspace.editor.text, "- [ ] Milk\n", "it went into the editor of another note")
        try await until("it was written") { (try? self.read(self.draft)) == "# Draft\n\nSome text.\n\nA thought.\n\n![](.assets/Torii.jpg)\n" }
        XCTAssertEqual(try read(errands), "- [ ] Milk\n")
        XCTAssertTrue(SharedNotes.waiting().isEmpty)
    }

    /// Without every one of its files nothing is written and nothing stays in `.assets`, however often it is tried;
    /// it waits for the next time.
    func testAllOrNothing() async throws {
        let note = try share(.endOf(path: draft.path), text: "A thought.", files: ["Torii.jpg", "Tickets.pdf"])
        // The PDF went missing from what the extension left.
        try FileManager.default.removeItem(at: outbox.appendingPathComponent(note.id.uuidString).appendingPathComponent("Tickets.pdf"))
        for _ in 1...2 { await makeWorkspace().takeSharedNotes() }
        XCTAssertEqual(try read(draft), "# Draft\n\nSome text.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: papers.appendingPathComponent(".assets").path), "a copy stayed behind")
        XCTAssertEqual(SharedNotes.waiting().map(\.note.id), [note.id])
    }

    /// When the first file is the one missing, the Inbox made for the note and its `.assets` go again, and the note
    /// waits. It is told about once, not every time it is tried again.
    func testANoteThatCantBeWrittenLeavesNothingAndIsToldAboutOnce() async throws {
        let note = try share(text: "A thought.", files: ["Torii.jpg", "Tickets.pdf"])
        try FileManager.default.removeItem(at: outbox.appendingPathComponent(note.id.uuidString).appendingPathComponent("Torii.jpg"))
        let workspace = makeWorkspace()
        await workspace.takeSharedNotes()
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path), "the Inbox made for it stayed")
        XCTAssertEqual(SharedNotes.waiting().map(\.note.id), [note.id])
        // Not while Notebook is in the background, as after a launch at login: once it comes to the front.
        if !NSApp.isActive {
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(window?.attachedSheet, "told while in the background")
            workspace.showReportsWaiting()
        }
        try await until("the alert") { window?.attachedSheet != nil }
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        let again = makeWorkspace()
        await again.takeSharedNotes()
        again.showReportsWaiting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(window?.attachedSheet, "told about twice")
        XCTAssertEqual(SharedNotes.waiting().map(\.note.id), [note.id])
    }

    /// A note of the same name that arrives while the shared one is written, from iCloud say, isn't written over:
    /// the shared one takes another name.
    func testANoteArrivingMeanwhileIsntWrittenOver() async throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try share(text: "Shared")
        let arriving = inbox.appendingPathComponent("Kyoto.md")
        let holding = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Held while Notebook picks the name and waits to write it; it arrives just before Notebook writes.
            NSFileCoordinator().coordinate(writingItemAt: arriving, options: [], error: nil) { url in
                held.signal()
                holding.wait()
                try? "From iCloud\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { held.wait(); continuation.resume() } }
        let workspace = makeWorkspace()
        let taking = Task { await workspace.takeSharedNotes() }
        try await Task.sleep(for: .milliseconds(500))
        holding.signal()
        await taking.value
        XCTAssertEqual(try read(arriving), "From iCloud\n")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Kyoto 2.md")), "Shared\n")
    }

    /// A folder Notebook made is taken back only while it is empty: a file put in meanwhile keeps it.
    func testAFolderIsTakenBackOnlyWhileEmpty() throws {
        let empty = library.appendingPathComponent("Empty"), used = library.appendingPathComponent("Used")
        for folder in [empty, used] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data([1]).write(to: used.appendingPathComponent("Arrived.jpg"))
        FileOperations.removeEmptyFolder(empty)
        FileOperations.removeEmptyFolder(used)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.appendingPathComponent("Arrived.jpg").path))
    }

    /// When the extension can't leave a note, the files it moved go back, for Save to be tried again.
    func testAFailedSaveGivesTheFilesBack() throws {
        let copy = given.appendingPathComponent("Copy.jpg")
        try FileManager.default.copyItem(at: given.appendingPathComponent("Torii.jpg"), to: copy)
        let note = SharedNote(destination: .newNote, title: nil, text: "", files: ["Torii.jpg", "Gone.pdf"])
        XCTAssertThrowsError(try SharedNotes.add(note, moving: [(copy, "Torii.jpg"), (given.appendingPathComponent("Gone.pdf"), "Gone.pdf")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the picture wasn't given back")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outbox.path), [])
    }

    /// The extension's copies are moved, not copied a second time.
    func testTheFilesAreMoved() throws {
        let copy = given.appendingPathComponent("Copy.jpg")
        try FileManager.default.copyItem(at: given.appendingPathComponent("Torii.jpg"), to: copy)
        let note = SharedNote(destination: .newNote, title: nil, text: "", files: ["Torii.jpg"])
        try SharedNotes.add(note, moving: [(copy, "Torii.jpg")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outbox.appendingPathComponent(note.id.uuidString + "/Torii.jpg").path))
    }

    /// What a stopped extension left half written, and what can't be read, goes once it is old enough.
    func testLeftoversAreRemoved() throws {
        let manager = FileManager.default
        let stopped = outbox.appendingPathComponent("A.partial"), writing = outbox.appendingPathComponent("B.partial")
        let unreadable = outbox.appendingPathComponent("C"), fresh = outbox.appendingPathComponent("D")
        for folder in [stopped, writing, unreadable, fresh] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{".utf8).write(to: unreadable.appendingPathComponent("note.json"))
        try Data("{".utf8).write(to: fresh.appendingPathComponent("note.json"))
        let old = Date().addingTimeInterval(-2 * 86400)
        for folder in [stopped, unreadable] { try manager.setAttributes([.creationDate: old], ofItemAtPath: folder.path) }
        let kept = try share(text: "Milk")
        SharedNotes.removeLeftovers()
        XCTAssertFalse(manager.fileExists(atPath: stopped.path))
        XCTAssertFalse(manager.fileExists(atPath: unreadable.path))
        XCTAssertTrue(manager.fileExists(atPath: writing.path), "one being written was removed")
        XCTAssertTrue(manager.fileExists(atPath: fresh.path), "one too new to judge was removed")
        XCTAssertEqual(SharedNotes.waiting().map(\.note.id), [kept.id])
    }

    /// The extension offers the default folder and the note open, or opened last.
    func testThePlacesOffered() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.open(draft)
        workspace.publishSharePlaces()
        XCTAssertEqual(SharedNotes.places?.defaultFolder, "Inbox")
        XCTAssertEqual(SharedNotes.places?.lastNoteTitle, "Draft")
        // A PDF open, or opened last, isn't offered: the note before it is.
        let pdf = papers.appendingPathComponent("Tickets.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        workspace.open(pdf)
        workspace.publishSharePlaces()
        XCTAssertEqual(SharedNotes.places?.lastNoteTitle, "Draft")
    }
}
