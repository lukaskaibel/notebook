import XCTest

/// An iPad with a hardware keyboard: the Format menu's shortcuts reach the note being typed in. Every test starts the
/// app on fresh sample notes in its own home folder, so nothing of yours is touched.
final class PadKeyboardTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testFormatShortcutsFromTheKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the menu bar's shortcuts are the iPad's")
        launch()

        tap("Personal")
        tap("Weekend")
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        note.tap()
        // A line of its own, wherever the caret landed: Return twice ends a list it may be in.
        note.typeText("\n\nGroceries")

        app.typeKey("t", modifierFlags: [.command, .shift])
        waitForValue(note, containing: "\n# Groceries")
        app.typeKey("l", modifierFlags: [.command, .shift])
        waitForValue(note, containing: "\n- [ ] Groceries")
        app.typeKey("u", modifierFlags: [.command, .shift])
        waitForValue(note, containing: "\n- [x] Groceries")
        app.typeKey("7", modifierFlags: [.command, .shift])
        waitForValue(note, containing: "\n- Groceries")
        app.typeKey("b", modifierFlags: [.command, .shift])
        waitForValue(note, containing: "\nGroceries")
        waitForValue(note, lacking: "- Groceries")
    }

    /// What ⌘K shows next to its commands works from the keyboard too: the outline, a new folder.
    func testMenuShortcutsFromTheKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the menu bar's shortcuts are the iPad's")
        launch()
        tap("Personal")
        tap("Weekend")
        XCTAssertTrue(app.textViews["Note"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        app.typeKey("i", modifierFlags: [.command, .control])
        XCTAssertTrue(app.buttons["Hide Outline"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("i", modifierFlags: [.command, .control])
        XCTAssertTrue(app.buttons["Show Outline"].waitForExistence(timeout: 10), app.debugDescription)

        app.typeKey("n", modifierFlags: [.command, .shift])
        let newFolder = app.alerts["New Folder"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10), app.debugDescription)
        newFolder.buttons["Cancel"].tap()
    }

    /// The app on fresh sample notes in its own home folder (a `~` is the app's home in the Simulator).
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    /// A row of the sidebar, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in ((object as? XCUIElement)?.value as? String)?.contains(text) == true }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 6), .completed, "\(String(describing: element.value)) lacks \(text)", file: file, line: line)
    }

    private func waitForValue(_ element: XCUIElement, lacking text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in ((object as? XCUIElement)?.value as? String)?.contains(text) != true }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 6), .completed, "\(String(describing: element.value)) still has \(text)", file: file, line: line)
    }
}
