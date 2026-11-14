import XCTest
@testable import NotebookKit

/// Files kept on their own, outside every location: what Open File chooses on iPhone and iPad, and what another app
/// hands over, for apps that give single files but no folders (Nextcloud). They show under Files, in Recent and in
/// Favorites, and a new note made while one is open goes where new notes go, not next to it.
@MainActor
final class KeptFilesTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    /// Somewhere no location reaches, as another app's storage is.
    private var elsewhere: URL { base.appendingPathComponent("Elsewhere/ocA1B2") }
    private var meeting: URL { elsewhere.appendingPathComponent("Meeting.md") }
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-kept-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "Milk, eggs.\n".write(to: groceries, atomically: true, encoding: .utf8)
        try "Agenda.\n".write(to: meeting, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func readWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        workspace.start()
        try await waitFor { workspace.hasReadLocations && workspace.reader.isIdle }
        return workspace
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition() {
            guard Date() < end else { throw XCTSkip("never happened") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Open File keeps a file from outside the locations and opens it: it is under Files, in Recent, and can be a
    /// favourite. Removing it takes it off all of them and leaves the file where it is.
    func testAChosenFileIsKeptAndListed() async throws {
        let workspace = try await readWorkspace()
        var opened: URL?
        workspace.openChosen([meeting]) { opened = $0 }
        try await waitFor { opened != nil }
        XCTAssertEqual(workspace.currentURL, meeting)
        XCTAssertTrue(workspace.isKept(meeting))
        XCTAssertEqual(workspace.keptFileURLs, [meeting])

        workspace.open(groceries)
        XCTAssertEqual(workspace.recentURLs, [meeting], "a kept file is in Recent like the others")
        workspace.toggleFavorite(meeting)
        XCTAssertEqual(workspace.favoriteURLs, [meeting])

        workspace.removeKeptFile(meeting)
        XCTAssertFalse(workspace.isKept(meeting))
        XCTAssertEqual(workspace.keptFileURLs, [])
        XCTAssertEqual(workspace.recentURLs, [], "Notebook may not reach it any more")
        XCTAssertEqual(workspace.favoriteURLs, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.path), "the file itself stays")
    }

    /// A file a location has opens from there and isn't kept twice; a folder chosen becomes a location.
    func testAFileInALocationIsNotKeptAndAFolderIsAdded() async throws {
        let workspace = try await readWorkspace()
        var done = false
        workspace.openChosen([groceries, elsewhere]) { _ in done = true }
        try await waitFor { done }
        XCTAssertEqual(workspace.currentURL, groceries)
        XCTAssertEqual(workspace.keptFileURLs, [])
        XCTAssertTrue(workspace.locations.contains { $0.url == elsewhere }, "the folder chosen is a location")
    }

    /// A kept file whose folder you open since is in that folder now, not under Files as well; Files has it again once
    /// the folder is taken out.
    func testAFolderOpenedSinceTakesTheFile() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        XCTAssertEqual(workspace.keptFileURLs, [meeting])
        workspace.addLocation(elsewhere)
        XCTAssertEqual(workspace.keptFileURLs, [])
        XCTAssertFalse(workspace.isKept(meeting))
        if let id = workspace.locations.first(where: { $0.url == elsewhere })?.id { workspace.removeLocation(id) }
        XCTAssertEqual(workspace.keptFileURLs, [meeting])
    }

    /// Notebook has a kept file, not its folder: a new note made while it is open goes to the default folder.
    func testANewNoteDoesNotGoNextToAKeptFile() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        workspace.open(meeting)
        XCTAssertEqual(workspace.folderForNewNote, workspace.defaultFolder)
        workspace.open(groceries)
        XCTAssertEqual(workspace.folderForNewNote, library, "next to a note in a location, as before")
    }

    /// Kept files are found again by their bookmarks, where they moved; one whose bookmark leads nowhere now stays.
    func testBookmarksFindAKeptFileThatMoved() async throws {
        let made = LocationStore.bookmark(for: meeting).bookmark
        let bookmark = try XCTUnwrap(made)
        let moved = base.appendingPathComponent("Elsewhere/Minutes.md")
        try FileManager.default.moveItem(at: meeting, to: moved)
        let gone = KeptFile(path: "/nowhere/Gone.md", bookmark: Data("not a bookmark".utf8))
        let resolved = KeptFileStore.resolve([KeptFile(path: meeting.path, bookmark: bookmark), gone])
        XCTAssertEqual(resolved.first?.url, moved.standardizedFileURL)
        XCTAssertEqual(resolved.last, gone)
    }

    /// Recent and Favorites follow a kept file to where its bookmark found it.
    func testRecentFollowsAKeptFileThatMoved() async throws {
        let workspace = try await readWorkspace()
        workspace.keep(meeting)
        workspace.open(meeting)
        workspace.open(groceries)
        workspace.toggleFavorite(meeting)
        try await waitFor { workspace.keptFiles.first?.bookmark != nil }
        let moved = elsewhere.appendingPathComponent("Minutes.md")
        try FileManager.default.moveItem(at: meeting, to: moved)
        workspace.resolveKeptFiles(thenOpen: nil)
        try await waitFor { workspace.keptFileURLs == [moved] }
        XCTAssertEqual(workspace.recentURLs, [moved])
        XCTAssertEqual(workspace.favoriteURLs, [moved])
    }
}
