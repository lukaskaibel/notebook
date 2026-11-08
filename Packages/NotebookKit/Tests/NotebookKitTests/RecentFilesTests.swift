import XCTest
@testable import NotebookKit

/// What you opened last. The iPhone's first screen lists the note you are in too, so going back to it doesn't put the
/// note's row in once you are there; menus, search and ⌘K leave it out. Recent's cards take a new order a moment later,
/// and not while the pointer is on them, so a card you click stays where you clicked it.
@MainActor
final class RecentFilesTests: XCTestCase {
    private var library: URL!
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }
    private var trip: URL { library.appendingPathComponent("Trip.md") }

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-recent-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "Milk, eggs.\n".write(to: groceries, atomically: true, encoding: .utf8)
        try "Five days in October.\n".write(to: trip, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName"] { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: library)
        Workspace.recentCardsDelay = .seconds(2)
    }

    private func readWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        workspace.start()
        let end = Date().addingTimeInterval(5)
        while !(workspace.hasReadLocations && workspace.reader.isIdle) {
            guard Date() < end else { throw XCTSkip("the library was never read") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return workspace
    }

    func testTheOpenNoteIsRecentOnlyWhereAskedFor() async throws {
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(trip)
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Groceries.md"])
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Groceries.md"])
    }

    /// The first card shows at once, as Recent comes with it; a file opened after it joins the cards a moment later, at
    /// their front. Menus and search have the new order at once.
    func testTheCardsTakeTheNewOrderAMomentLater() async throws {
        Workspace.recentCardsDelay = .milliseconds(300)
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Groceries.md"])
        workspace.open(trip)
        workspace.open(groceries)
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Groceries.md"], "not yet")
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Trip.md"])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Groceries.md", "Trip.md"])
    }

    /// While the pointer is on the cards they keep their order; it changes a moment after the pointer leaves.
    func testThePointerHoldsTheCards() async throws {
        Workspace.recentCardsDelay = .milliseconds(300)
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(trip)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Trip.md", "Groceries.md"])

        workspace.holdRecentCards(true)
        workspace.open(groceries)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Trip.md", "Groceries.md"], "the card clicked stays put")
        workspace.holdRecentCards(false)
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Trip.md", "Groceries.md"], "a moment after the pointer left")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Groceries.md", "Trip.md"])
    }

    /// A renamed file keeps its card where it is, under its new name.
    func testARenamedFileKeepsItsCard() async throws {
        Workspace.recentCardsDelay = .milliseconds(300)
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(trip)
        try await Task.sleep(for: .milliseconds(600))
        let shopping = library.appendingPathComponent("Shopping.md")
        try await rename(groceries, to: shopping, in: workspace)
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Trip.md", "Shopping.md"])
    }

    /// A file from a folder that is no longer one of the locations isn't recent or a favourite any more: Notebook can't
    /// read it (on the Mac the sandbox shows that it is there, but not what is in it).
    func testFilesOutsideTheLocationsAreLeftOut() async throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-elsewhere-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("Solution strategy.adoc")
        try "== Solution Strategy\n".write(to: outside, atomically: true, encoding: .utf8)
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(outside)
        workspace.open(trip)
        workspace.toggleFavorite(outside)
        workspace.toggleFavorite(groceries)
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Groceries.md"])
        XCTAssertEqual(workspace.recentCardURLs.map(\.lastPathComponent), ["Groceries.md"])
        XCTAssertEqual(workspace.favoriteURLs.map(\.lastPathComponent), ["Groceries.md"])
        XCTAssertTrue(workspace.isFavorite(outside), "kept, for when the folder is added again")
    }

    private func rename(_ url: URL, to new: URL, in workspace: Workspace) async throws {
        _ = await workspace.rename(url, to: new.deletingPathExtension().lastPathComponent).value
        let end = Date().addingTimeInterval(5)
        while workspace.recents.contains(url.path) || !FileManager.default.fileExists(atPath: new.path) {
            guard Date() < end else { return XCTFail("never renamed") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
