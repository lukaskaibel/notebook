import XCTest

/// The bar above the keyboard on iPhone and iPad, pressed as you would: its tools do what they say, a style the caret
/// is in shows on the left and a tap on it ends it, and the circle at the right end hides the keyboard. The app starts
/// on fresh sample notes in its own home folder, so nothing of yours is touched.
final class WritingBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testTheToolsDoWhatTheySay() throws {
        try writeInWeekend()
        tap("Checklist")
        waitForValue(containing: "\n- [ ] Groceries")
        // A to-do's bell joins the buttons for the caret.
        XCTAssertTrue(button("Remind Me").waitForExistence(timeout: 10), app.debugDescription)
        tap("Checklist")
        waitForValue(lacking: "- [ ] Groceries")

        tap("Format")
        let close = button("Close")
        XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
        close.tap()
        // The keyboard is back, and the bar with it.
        XCTAssertTrue(button("Hide Keyboard").waitForExistence(timeout: 10), app.debugDescription)

        tap("Link")
        waitForValue(containing: "Groceries[[]]")
        tap("Undo")
        waitForValue(lacking: "[[]]")

        tap("Attach")
        XCTAssertTrue(button("Attach File").waitForExistence(timeout: 10), app.debugDescription)
    }

    func testAStyleShowsOnTheLeftAndATapEndsIt() throws {
        try writeInWeekend()
        app.typeText(" ")
        // Bold may wait on the next page of tools.
        if !button("Bold").isHittable { button("Format").swipeLeft() }
        tap("Bold")
        app.typeText("wine")
        waitForValue(containing: "Groceries **wine**")
        let on = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == true", "Bold")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 10), app.debugDescription)
        // At the end of the bold words, what comes next is plain, as in Notes.
        on.tap()
        app.typeText(" tonight")
        waitForValue(containing: "Groceries **wine** tonight")
    }

    func testTheCircleHidesTheKeyboard() throws {
        try writeInWeekend()
        tap("Hide Keyboard")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button("Hide Keyboard"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, app.debugDescription)
        XCTAssertEqual(app.keyboards.count, 0)
    }

    // MARK: -

    private var note: XCUIElement { app.textViews["Note"].firstMatch }

    /// Weekend open with the caret on its last line, which is empty, and "Groceries" typed there.
    private func writeInWeekend() throws {
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("Personal")
        tap("Weekend")
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        // Below the last line, which puts the caret at the end.
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(button("Hide Keyboard").waitForExistence(timeout: 30), app.debugDescription)
        app.typeText("Groceries")
        waitForValue(containing: "\nGroceries")
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 30), app.debugDescription, file: file, line: line)
        element.tap()
    }

    private func waitForValue(containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in ((object as? XCUIElement)?.value as? String)?.contains(text) == true }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: note)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "\(note.value ?? "")", file: file, line: line)
    }

    private func waitForValue(lacking text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in ((object as? XCUIElement)?.value as? String)?.contains(text) == false }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: note)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "\(note.value ?? "")", file: file, line: line)
    }
}
