import XCTest
@testable import NotebookKit

/// A new note opens with the caret in its title, to type its name at once. Left without a name or text, it goes to the
/// Trash again, as if it had never been made, unless Settings keeps new notes left empty.
@MainActor
final class NewNoteTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var draft: URL { papers.appendingPathComponent("Draft.md") }
    private var untitled: URL { papers.appendingPathComponent("Untitled.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-new-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "# Draft\n\nSome text.\n".write(to: draft, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections", "deletesEmptyNewNotes"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotebookSettings.shared.deletesEmptyNewNotes = true
        window?.close()
        try? FileManager.default.removeItem(at: library)
    }

    /// The library read, with the note in a window, where its title can have the caret.
    private func makeWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = workspace.editor.view
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        await withCheckedContinuation { done in workspace.readFolders(to: papers, including: true) { done.resume() } }
        return workspace
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
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

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func notes(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    }

    /// Types in the title, as the keyboard does, without leaving it.
    private func typeTitle(_ name: String, in workspace: Workspace) throws {
        let fieldEditor = try XCTUnwrap(workspace.editor.textView.titleField.currentEditor() as? NSTextView, "the title isn't being typed")
        fieldEditor.insertText(name, replacementRange: fieldEditor.selectedRange())
    }

    private func typeText(_ text: String, in workspace: Workspace) {
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func testANewNoteHasTheCaretInItsTitle() async throws {
        let workspace = try await makeWorkspace()
        workspace.open(draft)
        window?.makeFirstResponder(workspace.editor.textView)
        let made = await workspace.newNote(in: papers).value
        XCTAssertEqual(made?.lastPathComponent, "Untitled.md")
        XCTAssertTrue(workspace.editor.isEditingTitle)
        XCTAssertEqual(workspace.editor.titleText, "", "the placeholder shows, not a name to type over")
    }

    func testANewNoteLeftAsItCameGoesToTheTrash() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        XCTAssertTrue(exists(untitled))
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(in: papers), ["Draft.md"])
        XCTAssertFalse(workspace.recents.contains { $0.hasSuffix("/Untitled.md") }, "still among the files opened last")
    }

    /// Empty is how it is left, not whether anything was ever typed in it.
    func testANewNoteEmptiedAgainGoesToTheTrash() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        typeText("Milk", in: workspace)
        workspace.saveAll()
        await NoteDocument.allWritten()
        XCTAssertEqual(try String(contentsOf: untitled, encoding: .utf8), "Milk")
        let textView = workspace.editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.deleteBackward(nil)
        XCTAssertEqual(workspace.editor.text, "")
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(in: papers), ["Draft.md"])
    }

    func testANewNoteWithTextStays() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        typeText("Milk", in: workspace)
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(in: papers), ["Draft.md", "Untitled.md"])
        XCTAssertEqual(try String(contentsOf: untitled, encoding: .utf8), "Milk")
    }

    /// ⌘N or Back while the name is still being typed: the name counts, as it would once the title is left.
    func testANameStillBeingTypedKeepsTheNote() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        try typeTitle("Groceries", in: workspace)
        _ = await workspace.newNote(in: papers).value
        await settle(workspace)
        XCTAssertTrue(exists(papers.appendingPathComponent("Groceries.md")), "the name typed was lost: \(notes(in: papers))")
        XCTAssertTrue(workspace.editor.isEditingTitle, "the new note's title has the caret")
        XCTAssertEqual(workspace.editor.titleText, "")

        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(in: papers), ["Draft.md", "Groceries.md"])
        XCTAssertEqual(workspace.editor.titleText, "Draft")
        XCTAssertFalse(workspace.editor.isEditingTitle, "the next note's title isn't being typed")
    }

    func testSettingsCanKeepNewNotesLeftEmpty() async throws {
        NotebookSettings.shared.deletesEmptyNewNotes = false
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        workspace.open(draft)
        await settle(workspace)
        XCTAssertEqual(notes(in: papers), ["Draft.md", "Untitled.md"])
        XCTAssertEqual(try String(contentsOf: untitled, encoding: .utf8), "")
    }

    /// Quitting leaves the note too, and the next launch wouldn't know it was new.
    func testQuittingThrowsAwayANewNoteLeftEmpty() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        workspace.saveAll(quitting: true)
        XCTAssertFalse(exists(untitled))
    }

    func testQuittingKeepsANewNoteWithANameBeingTyped() async throws {
        let workspace = try await makeWorkspace()
        _ = await workspace.newNote(in: papers).value
        try typeTitle("Groceries", in: workspace)
        workspace.saveAll(quitting: true)
        XCTAssertTrue(exists(untitled))
    }

    // MARK: - The default folder

    private var inbox: URL { library.appendingPathComponent("Inbox") }

    private func folder(of note: URL?) -> String? {
        note.map { HiddenFolders.withoutPrivate($0.deletingLastPathComponent().path) }
    }

    private func path(_ url: URL?) -> String? {
        url.map { HiddenFolders.withoutPrivate($0.standardizedFileURL.path) }
    }

    func testWithNoFolderChosenANewNoteGoesToTheInbox() async throws {
        let workspace = try await makeWorkspace()
        let made = await workspace.newNote().value
        XCTAssertEqual(folder(of: made), path(inbox))
        XCTAssertEqual(workspace.place(of: inbox), "Notes › Inbox")
    }

    func testANewNoteMadeOutsideAFolderGoesToTheDefaultFolder() async throws {
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(papers)
        XCTAssertEqual(path(workspace.defaultFolder), path(papers))
        XCTAssertEqual(workspace.place(of: papers), "Notes › Papers")
        let made = await workspace.newNote().value
        XCTAssertEqual(folder(of: made), path(papers))
        XCTAssertFalse(exists(inbox), "the Inbox was made all the same")
    }

    /// Next to the open note, as before.
    func testANewNoteNextToTheOpenOneDoesntGoToTheDefaultFolder() async throws {
        let other = library.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(other)
        workspace.open(draft)
        let made = await workspace.newNote().value
        XCTAssertEqual(folder(of: made), path(papers))
    }

    func testChoosingTheInboxIsChoosingNone() async throws {
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(papers)
        workspace.chooseDefaultFolder(inbox)
        XCTAssertNil(workspace.chosenDefaultFolder)
        workspace.chooseDefaultFolder(papers)
        workspace.chooseDefaultFolder(nil)
        XCTAssertNil(workspace.chosenDefaultFolder)
        XCTAssertEqual(path(workspace.defaultFolder), path(inbox))
    }

    /// One outside every location, kept from a location removed since, say.
    func testAFolderOutsideTheLocationsIsntUsed() async throws {
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(FileManager.default.temporaryDirectory)
        XCTAssertEqual(path(workspace.defaultFolder), path(inbox))
    }

    func testTheDefaultFolderFollowsARename() async throws {
        let drafts = papers.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(drafts)
        let renaming = await workspace.rename(papers, to: "Essays").value
        let renamed = try XCTUnwrap(renaming)
        XCTAssertEqual(path(workspace.defaultFolder), path(renamed.appendingPathComponent("Drafts")), "the folder it is in was renamed")
        let moving = await workspace.move(renamed.appendingPathComponent("Drafts"), into: library).value
        let moved = try XCTUnwrap(moving)
        XCTAssertEqual(path(workspace.defaultFolder), path(moved))
        let made = await workspace.newNote().value
        XCTAssertEqual(folder(of: made), path(moved))
    }

    func testADefaultFolderThrownAwayLeavesTheInbox() async throws {
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(papers)
        let trashed = await workspace.trash(papers).value
        XCTAssertTrue(trashed)
        XCTAssertNil(workspace.chosenDefaultFolder)
        XCTAssertEqual(path(workspace.defaultFolder), path(inbox))
    }

    /// Thrown away in the Finder: the note goes to the Inbox, and the folder isn't made again.
    func testADefaultFolderGoneFromTheDiskLeavesTheInbox() async throws {
        let workspace = try await makeWorkspace()
        workspace.chooseDefaultFolder(papers)
        try FileManager.default.removeItem(at: papers)
        let made = await workspace.newNote().value
        XCTAssertEqual(folder(of: made), path(inbox))
        XCTAssertFalse(exists(papers))
    }

    /// Settings lists the Inbox before the first note made it, in its place among the folders, and only once after.
    func testSettingsOfferTheInboxAmongTheFolders() async throws {
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let workspace = try await makeWorkspace()
        func names() -> [String] { workspace.defaultFolderChoices.first?.folders.map(\.name) ?? [] }
        try await until("the folders were found") { names().contains("Papers") && names().contains("Archive") }
        XCTAssertEqual(names(), ["Notes", "Archive", "Inbox", "Papers"])
        _ = await workspace.newNote().value
        try await until("the Inbox was found") { workspace.index.allFolders().contains { $0.name == "Inbox" } }
        try await until("the list was sorted again") { names() == ["Notes", "Archive", "Inbox", "Papers"] }
    }
}
