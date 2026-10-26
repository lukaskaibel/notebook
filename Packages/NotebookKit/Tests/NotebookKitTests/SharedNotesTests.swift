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
        SharedNotes.defaults = UserDefaults(suiteName: "notebook-shared-tests")
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookWelcome", "expandedFolders"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        SharedNotes.defaults?.removePersistentDomain(forName: "notebook-shared-tests")
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

    private func share(_ destination: SharedNote.Destination = .newNote, title: String? = "Kyoto", text: String, files: [String] = []) throws {
        let note = SharedNote(destination: destination, title: title, text: text, files: files)
        try SharedNotes.add(note, files: files.map { (given.appendingPathComponent($0), $0) })
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
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

    /// The extension offers the default folder and the note open, or opened last.
    func testThePlacesOffered() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.open(draft)
        workspace.publishSharePlaces()
        XCTAssertEqual(SharedNotes.places?.defaultFolder, "Inbox")
        XCTAssertEqual(SharedNotes.places?.lastNoteTitle, "Draft")
    }
}
