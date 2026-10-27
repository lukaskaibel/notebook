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
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

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

    /// ⌘F finds in the note, as on the Mac and in Notes; ⌥⌘F puts the caret in Search, which finds in every note.
    func testFindAndSearchFromTheKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the menu bar's shortcuts are the iPad's")
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        tap("Personal")
        tap("Weekend")
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("f", modifierFlags: [.command, .option])
        // Search has the caret: the tree says so, which the field's attributes don't.
        var searching = false
        for _ in 0..<10 where !searching {
            sleep(1)
            searching = app.debugDescription.split(separator: "\n").contains { $0.contains("label: 'Search'") && $0.contains("Keyboard Focused") }
        }
        XCTAssertTrue(searching, "⌥⌘F: no caret in Search")

        note.tap()
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields["find.searchField"].waitForExistence(timeout: 5), "⌘F: no find bar in the note")
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
