import XCTest
@testable import NotebookKit

/// What you opened last. The iPhone's first screen lists the note you are in too, so going back to it doesn't put the
/// note's row in once you are there; menus, search and ⌘K leave it out.
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
    }

    func testTheOpenNoteIsRecentOnlyWhereAskedFor() async throws {
        let workspace = Workspace()
        workspace.start()
        let end = Date().addingTimeInterval(5)
        while !(workspace.hasReadLocations && workspace.reader.isIdle) {
            guard Date() < end else { return XCTFail("the library was never read") }
            try await Task.sleep(for: .milliseconds(20))
        }
        workspace.open(groceries)
        workspace.open(trip)
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Groceries.md"])
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Groceries.md"])
    }
}
