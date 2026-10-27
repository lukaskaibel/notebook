import XCTest
@testable import NotebookKit

/// iOS moves an app's folder with each update of the app, and the notes kept in it move along: a path kept from before
/// is found again at the same place in the new folder.
final class MovedFolderTests: XCTestCase {
    private var root: URL!
    private var old: String { root.appendingPathComponent("Data/Application/OLD-UUID/Documents").path }
    private var new: String { root.appendingPathComponent("Data/Application/NEW-UUID/Documents").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-moved-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(atPath: new + "/Journal", withIntermediateDirectories: true)
        try "Rain all day.\n".write(toFile: new + "/Journal/Day 1.md", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAPathInTheOldFolderIsFoundInTheNewOne() {
        XCTAssertEqual(Workspace.rerooted(old + "/Journal/Day 1.md", into: new), new + "/Journal/Day 1.md")
        XCTAssertEqual(Workspace.rerooted(old + "/Journal", into: new), new + "/Journal")
        XCTAssertEqual(Workspace.rerooted(old, into: new), new, "the folder itself, as a default folder")
    }

    func testOtherPathsStayAsTheyWere() {
        XCTAssertEqual(Workspace.rerooted(old + "/Gone.md", into: new), old + "/Gone.md", "not in the new folder either")
        XCTAssertEqual(Workspace.rerooted(new + "/Journal/Day 1.md", into: old), new + "/Journal/Day 1.md", "still where it was")
        XCTAssertEqual(Workspace.rerooted("/Users/anna/Documents/Journal/Day 1.md", into: new), "/Users/anna/Documents/Journal/Day 1.md",
                       "not in an app's folder")
        let archive = root.appendingPathComponent("Data/Application/OLD-UUID/Documents Archive/Day 1.md").path
        XCTAssertEqual(Workspace.rerooted(archive, into: new), archive, "not its Documents")
    }
}
