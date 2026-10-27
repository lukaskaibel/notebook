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

    /// Writing in landscape, the iPad turned to portrait keeps the note in front and the keyboard up, as in Notes; the
    /// sidebar stays out of the way until asked for, and comes back with the keyboard still up in landscape (#204).
    func testTurningWhileWritingKeepsTheKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar beside the note is the iPad's")
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("Personal")
        tap("Weekend")
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), app.debugDescription)
        let sidebarRow = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Personal")).firstMatch

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntil { !sidebarRow.isHittable }
        // Past the turn's animation: the keyboard is still there, and the note in front of it, under nothing.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(keyboard.exists, "the keyboard went down")
        XCTAssertTrue(note.isHittable)
        XCTAssertEqual(note.frame.minX, 0, accuracy: 1)
        app.typeText("Wine")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Wine"), object: note)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: 10), .completed, "\(note.value ?? "")")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Hide Sidebar"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntil { sidebarRow.isHittable }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(keyboard.exists, "the keyboard went down back in landscape")
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
