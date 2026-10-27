import XCTest

/// The buttons at the bottom of a note on the iPhone work at the end of a note you haven't put the caret in, as in Notes,
/// and where you put it otherwise, also at the very start. The app starts on fresh sample notes in its own home
/// folder, so nothing of yours is touched.
final class ToolbarCaretTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Attach, a picker, Cancel: nothing went in, so the caret stays where the note opened, and Checklist starts a
    /// to-do after the last line rather than making the last line one.
    func testChecklistAfterACancelledAttachStartsANewToDo() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Checklist and Attach at the bottom are the iPhone's")
        try openNewNote()
        tap("Attach")
        tap("Photo Library")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        cancel.tap()
        tap("Checklist")
        XCTAssertTrue(waitForText("First line\nLast line\n- [ ] "), "the last line changed: \(noteText)")
    }

    /// Return in the title puts the caret at the start of the text: Checklist, after the keyboard went away, makes the
    /// first line a to-do there.
    func testChecklistWorksWhereTheCaretWasPutAtTheStart() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Checklist at the bottom is the iPhone's")
        try openNewNote()
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.tap()
        app.typeText("\n")
        tap("Done")
        tap("Checklist")
        XCTAssertTrue(waitForText("- [ ] First line\nLast line"), "not at the start: \(noteText)")
    }

    // MARK: - Steps

    /// A new note with two lines, opened again from its folder after the app started again, so nothing in it has the
    /// caret.
    private func openNewNote() throws {
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("New Note")
        app.typeText("Groceries\nFirst line\nLast line")
        // Saved as it is left.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        // The same library again, without the note in memory.
        app.terminate()
        app.launchArguments[5] = "NO"
        app.launch()
        tap("Inbox")
        // The row, not the Recent one on the screen behind.
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Groceries,"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: \.isHittable), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.textViews["Note"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForText("First line\nLast line"), noteText)
    }

    private var noteText: String {
        let note = app.textViews["Note"].firstMatch
        return note.exists ? note.value as? String ?? "" : ""
    }

    private func waitForText(_ text: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if noteText == text { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// A row of a list, a button or anything else, by its name: the one on screen.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        (matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch).tap()
    }
}
