import XCTest

/// The iPad's sidebar as the iPad turns: beside the note in landscape, out of the way in portrait, and back again,
/// in the one split view. The app starts on fresh sample notes in its own home folder, so nothing of yours is touched.
final class PadSplitViewTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        super.tearDown()
    }

    func testSidebarMakesWayInPortrait() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar beside the note is the iPad's")
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("Personal")
        tap("Weekend")
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        let sidebarRow = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Personal")).firstMatch
        XCTAssertTrue(sidebarRow.isHittable)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntil { !sidebarRow.isHittable }
        // The note fills the screen, under nothing.
        XCTAssertTrue(note.isHittable)
        XCTAssertEqual(note.frame.minX, 0, accuracy: 1)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Hide Sidebar"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntil { sidebarRow.isHittable }
        XCTAssertGreaterThan(note.frame.minX, 200)

        // Put away by hand, it stays away as the iPad turns.
        tap("Hide Sidebar")
        waitUntil { !sidebarRow.isHittable }
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(sidebarRow.isHittable)
    }

    /// A row of the sidebar, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, app.debugDescription, file: file, line: line)
    }
}
