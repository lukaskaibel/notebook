import NotebookCapture
import XCTest
@testable import NotebookKit

/// New Note from Shortcuts, Spotlight or the Action button: a note in the default folder, whatever is open, with the
/// caret in its title and the text the shortcut gave it. When it starts the app, it waits for the locations.
@MainActor
final class NewNoteIntentTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var inbox: URL { library.appendingPathComponent("Inbox") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-intent-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "# Draft\n\nSome text.\n".write(to: draft, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookWelcome", "NotebookSlowFolders", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        try? FileManager.default.removeItem(at: library)
    }

    /// A workspace with its note in a window, where the title can have the caret; not started, as when the intent
    /// starts the app.
    private func makeWorkspace() -> Workspace {
        let workspace = Workspace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = workspace.editor.view
        return workspace
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func folder(of note: URL?) -> String? {
        note.map { HiddenFolders.withoutPrivate($0.deletingLastPathComponent().path) }
    }

    private func path(_ url: URL?) -> String? {
        url.map { HiddenFolders.withoutPrivate($0.standardizedFileURL.path) }
    }

    /// In the App Store build, the locations' bookmarks are what lets Notebook write in them.
    func testStartingTheAppTheNoteWaitsForTheLocations() async throws {
        UserDefaults.standard.set(0.5, forKey: "NotebookSlowFolders")
        let workspace = makeWorkspace()
        let made = await workspace.newNoteFromOutside()
        XCTAssertTrue(workspace.hasReadLocations, "made before the locations were looked up")
        XCTAssertEqual(folder(of: made), path(inbox))
        XCTAssertTrue(workspace.editor.isEditingTitle)
        XCTAssertEqual(workspace.editor.titleText, "", "the placeholder shows, not a name to type over")
    }

    /// Not next to the open note, as ⌘N would make it: wherever you are, it goes where new notes go.
    func testTheNoteGoesToTheDefaultFolderWhateverIsOpen() async throws {
        let workspace = makeWorkspace()
        workspace.start()
        try await until("the library was read") { workspace.hasReadLocations }
        workspace.open(draft)
        let made = await workspace.newNoteFromOutside()
        XCTAssertEqual(folder(of: made), path(inbox))
        workspace.chooseDefaultFolder(papers)
        let second = await workspace.newNoteFromOutside()
        XCTAssertEqual(folder(of: second), path(papers))
    }

    /// The words a shortcut gave it are the note's text, and with them it stays when it is left without a name.
    func testTheTextGivenIsTheNotesText() async throws {
        let workspace = makeWorkspace()
        let making = await workspace.newNoteFromOutside(text: "Milk\nEggs")
        let made = try XCTUnwrap(making)
        XCTAssertEqual(try String(contentsOf: made, encoding: .utf8), "Milk\nEggs")
        try await until("the text was shown") { workspace.editor.text == "Milk\nEggs" }
        XCTAssertTrue(workspace.editor.isEditingTitle)
        workspace.open(draft)
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path), "a new note with text went to the Trash")
    }

    func testWithoutALocationThereIsNoNote() async throws {
        UserDefaults.standard.set(true, forKey: "NotebookWelcome")
        let workspace = makeWorkspace()
        let made = await workspace.newNoteFromOutside(text: "Milk")
        XCTAssertNil(made)
        XCTAssertTrue(workspace.locations.isEmpty)
    }

    /// The intent itself, as Shortcuts or a widget runs it in the app: the app's own workspace makes the note.
    func testTheIntentMakesTheNoteInTheApp() async throws {
        XCTAssertEqual(NewNoteIntent.supportedModes, .foreground(.immediate), "it has to open the app to show the note")
        NewNoteIntent.makeNote = nil
        do {
            _ = try await NewNoteIntent(text: "Nowhere").perform()
            XCTFail("made a note without the app")
        } catch {}
        QuickCapture.start()
        _ = try await NewNoteIntent(text: "From a shortcut").perform()
        let made = inbox.appendingPathComponent("Untitled.md")
        XCTAssertEqual(try String(contentsOf: made, encoding: .utf8), "From a shortcut")
        XCTAssertTrue(FileNode.samePath(try XCTUnwrap(Workspace.shared.currentURL), made))
    }
}
