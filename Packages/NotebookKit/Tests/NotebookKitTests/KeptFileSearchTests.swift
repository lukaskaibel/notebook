import XCTest
@testable import NotebookKit

/// Search reads the files kept on their own (Open File on iPhone and iPad, #376) as files of a place of their own,
/// Files: their names and text are found, links find them, and what Notebook writes in them, or the app they come from
/// changes, is read again. They leave search when they leave Files, and stay out of To-dos.
@MainActor
final class KeptFileSearchTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    /// Somewhere no location reaches, as another app's storage is.
    private var elsewhere: URL { base.appendingPathComponent("Elsewhere/ocA1B2") }
    private var meeting: URL { elsewhere.appendingPathComponent("Meeting.md") }
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-kept-search-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "Milk, eggs.\n".write(to: groceries, atomically: true, encoding: .utf8)
        try "# Agenda\n\nBudget for the Lisbon trip.\n\n- [ ] Call Ana\n".write(to: meeting, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func readWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        workspace.start()
        try await waitFor("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle && workspace.index.hasBuilt }
        return workspace
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func found(_ query: String, in workspace: Workspace) -> [URL] {
        workspace.index.files(matching: query).map(\.url.standardizedFileURL)
    }

    private func inText(_ query: String, in workspace: Workspace) -> [URL] {
        workspace.index.textHits(query).map(\.item.url.standardizedFileURL)
    }

    /// Kept, a file is found by its name and its text, under Files, and a link by its name leads to it.
    func testAKeptFileIsSearchedAndLinkedTo() async throws {
        let workspace = try await readWorkspace()
        XCTAssertEqual(found("Meeting", in: workspace), [])
        workspace.keep(meeting)
        try await waitFor("indexed") { workspace.index.entry(for: meeting) != nil }
        XCTAssertEqual(workspace.index.entry(for: meeting)?.place, "Files")
        XCTAssertEqual(found("Meeting", in: workspace), [meeting])
        XCTAssertEqual(inText("Lisbon", in: workspace), [meeting])
        XCTAssertEqual(workspace.index.entry(for: meeting)?.headings.map(\.title), ["Agenda"])
        XCTAssertEqual(workspace.index.resolve("Meeting", from: groceries)?.standardizedFileURL, meeting)
    }

    /// Taken off Files, it leaves search.
    func testARemovedFileLeavesSearch() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        try await waitFor("indexed") { workspace.index.entry(for: meeting) != nil }
        workspace.removeKeptFile(meeting)
        XCTAssertNil(workspace.index.entry(for: meeting))
        XCTAssertEqual(found("Meeting", in: workspace), [])
        XCTAssertNil(workspace.index.resolve("Meeting", from: groceries))
    }

    /// What changes in it is read again: when Notebook writes it, and when the app comes back to the front, as the app
    /// it comes from may have changed it. Gone, it leaves search and stays under Files to come back.
    func testChangesAreReadAgain() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        try await waitFor("indexed") { workspace.index.entry(for: meeting) != nil }
        try "Porto instead.\n".write(to: meeting, atomically: true, encoding: .utf8)
        // What `Workspace.refresh` does for them as iPhone and iPad come back to the front.
        workspace.index.refreshFiles()
        try await waitFor("read again") { inText("Porto", in: workspace) == [meeting] }
        XCTAssertEqual(inText("Lisbon", in: workspace), [])

        try FileManager.default.removeItem(at: meeting)
        workspace.index.refreshFiles()
        try await waitFor("gone from search") { workspace.index.entry(for: meeting) == nil }
        XCTAssertTrue(workspace.keptFiles.contains { $0.url == meeting }, "still kept, for when it is back")
    }

    /// A note open and saved by Notebook is read again for search.
    func testASavedKeptNoteIsReadAgain() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        workspace.open(meeting)
        try await waitFor("loaded") { workspace.note?.isLoaded == true && workspace.index.entry(for: meeting) != nil }
        workspace.note?.update(text: "# Agenda\n\nSevilla now.\n")
        workspace.note?.saveNow()
        await NoteDocument.allWritten()
        try await waitFor("read again") { inText("Sevilla", in: workspace) == [meeting] }
    }

    /// One in a folder you open since is that folder's, once, not under Files as well.
    func testAFolderOpenedSinceHasItOnce() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        try await waitFor("indexed") { workspace.index.entry(for: meeting) != nil }
        workspace.addLocation(elsewhere)
        try await waitFor("the folder was read") {
            workspace.index.entry(for: meeting).map { $0.locationID != SearchIndex.filesID } ?? false && !workspace.index.isBuilding
        }
        XCTAssertEqual(found("Meeting", in: workspace), [meeting])
        XCTAssertEqual(workspace.index.files, [])
    }

    /// To-dos lists the locations' notes, not those kept on their own.
    func testToDosLeaveKeptNotesOut() async throws {
        let errands = library.appendingPathComponent("Errands.md")
        try "- [ ] Post the letter\n".write(to: errands, atomically: true, encoding: .utf8)
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        try await waitFor("both indexed") { workspace.index.entry(for: meeting) != nil && workspace.index.entry(for: errands) != nil }
        try await waitFor("to-dos read") { workspace.todos.items.contains { $0.todo.text == "Post the letter" } }
        XCTAssertFalse(workspace.todos.items.contains { $0.todo.text == "Call Ana" })
    }

    /// The index kept between launches keeps them, under Files.
    func testTheKeptIndexKeepsThem() throws {
        let entry = try XCTUnwrap(SearchIndex.fileEntries([meeting], known: [:]).first)
        XCTAssertEqual(entry.locationID, SearchIndex.filesID)
        let store = base.appendingPathComponent("Search index")
        try KeptIndex.write([entry], locations: SearchIndex.keptRoots([]), to: store)
        let read = try XCTUnwrap(KeptIndex.read(store, locations: SearchIndex.keptRoots([])))
        XCTAssertEqual(read.map(\.path), [meeting.path])
        XCTAssertEqual(read.first?.locationID, SearchIndex.filesID)
        XCTAssertEqual(read.first?.place, "Files")
        XCTAssertEqual(SearchIndex.fileEntries([elsewhere, base.appendingPathComponent("Gone.md")], known: [:]).count, 0,
                       "neither a folder nor what isn't there")
    }
}
