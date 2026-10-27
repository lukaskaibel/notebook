import XCTest

/// Deleting notes on the iPhone and iPad as you would: a swipe, the context menu, the ⋯ menu of an open note, several in
/// a row, in search. The row goes at once, as in Notes, while the disk is slow (`-NotebookSlowWrites`), and nothing
/// comes back. (Undo isn't here: ⌘Z typed by a test reaches only a text field, and a test can't shake.) Every test starts the app on fresh sample notes in its own home folder, so nothing of yours
/// is touched. With `TEST_RUNNER_PACE=<seconds>` the tests wait that long between steps, for a recording of the screen.
final class DeleteFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        // Recorded, every step shows, also those after one that fails.
        continueAfterFailure = ProcessInfo.processInfo.environment["PACE"] != nil
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// A swipe to the left and Delete: the row goes with the swipe, before the slow disk has done it.
    func testSwipeToDelete() throws {
        try XCTSkipIf(isPad, "the iPad's sidebar has no swipes")
        launch(slowWrites: 2)
        tap("Inbox")
        let row = self.row("Gift ideas")
        pause()
        row.swipeLeft()
        pause(0.5)
        tap("Delete")
        assertGone("Gift ideas", within: 0.8)
        pause(3)
        assertGone("Gift ideas", within: 0.1)
        assertShown("Errands", within: 0.1)
    }

    /// The context menu's Delete.
    func testDeleteFromTheContextMenu() throws {
        launch(slowWrites: 2)
        tap("Inbox")
        let row = self.row("Errands")
        pause()
        row.press(forDuration: 1.2)
        pause(0.5)
        tap("Delete")
        assertGone("Errands", within: 1.2)
        pause(3)
        assertGone("Errands", within: 0.1)
    }

    /// Delete in the ⋯ menu of the note you are in: back to its folder, whose list no longer has it.
    func testDeleteFromInsideTheNote() throws {
        launch(slowWrites: 2)
        tap("Inbox")
        tap("Errands")
        waitForNote()
        pause()
        // On the iPad the sidebar has a ⋯ menu too: the note's is the one on the right.
        let more = app.buttons.matching(NSPredicate(format: "label == %@", "More")).allElementsBoundByIndex.filter(isOnScreen)
        XCTAssertFalse(more.isEmpty, app.debugDescription)
        more.max { $0.frame.minX < $1.frame.minX }?.tap()
        pause(0.5)
        tap("Delete")
        if !isPad { XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3), app.debugDescription) }
        assertGone("Errands", within: 1.2)
        pause(3)
        assertGone("Errands", within: 0.1)
    }

    /// The note you just came back from, which Recent shows first, swiped away.
    func testDeleteTheNoteOpenedLast() throws {
        try XCTSkipIf(isPad, "the iPad's sidebar has no swipes")
        launch(slowWrites: 0)
        tap("Inbox")
        tap("Errands")
        waitForNote()
        pause()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        row("Errands").swipeLeft()
        pause(0.5)
        tap("Delete")
        assertGone("Errands", within: 0.8)
        pause(1.5)
        // Back on the first screen, Recent doesn't have it either.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        assertGone("Errands", within: 1)
    }

    /// Three notes swiped away one after another, as fast as you can.
    func testDeleteSeveralInARow() throws {
        try XCTSkipIf(isPad, "the iPad's sidebar has no swipes")
        launch(slowWrites: 1)
        tap("Travel")
        pause()
        for name in ["Budget", "Getting to the ryokan", "Kyoto trip"] {
            row(name).swipeLeft()
            tap("Delete")
            assertGone(name, within: 0.8)
        }
        pause(4)
        for name in ["Budget", "Getting to the ryokan", "Kyoto trip"] { assertGone(name, within: 0.1) }
        assertShown("Flight tickets.pdf", within: 0.1)
    }

    /// Search showing the note, and Delete from its context menu there: gone from the results too.
    func testDeleteWhileSearching() throws {
        launch(slowWrites: 1)
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) { tap("Search") }
        field.tap()
        field.typeText("Gift")
        let result = row("Gift ideas")
        pause()
        result.press(forDuration: 1.2)
        pause(0.5)
        tap("Delete")
        assertGone("Gift ideas", within: 1.2)
        pause(3)
        assertGone("Gift ideas", within: 0.1)
    }

    /// The only note in a folder: the list says it is empty.
    func testDeleteTheLastNoteInAFolder() throws {
        try XCTSkipIf(isPad, "the iPad's sidebar has no swipes")
        launch(slowWrites: 1)
        tap("Projects")
        tap("Design")
        pause()
        row("Meeting notes").swipeLeft()
        tap("Delete")
        assertGone("Meeting notes", within: 0.8)
        XCTAssertTrue(app.staticTexts["No Notes"].waitForExistence(timeout: 3), app.debugDescription)
        pause(3)
    }

    // MARK: -

    private func launch(slowWrites: Double) {
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library",
                               "-NotebookDemo", "YES", "-NotebookTips", "hide", "-NotebookSlowWrites", "\(slowWrites)",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        pause()
    }

    /// Waits between steps when the screen is being recorded.
    private func pause(_ seconds: Double = 1) {
        guard let pace = ProcessInfo.processInfo.environment["PACE"].flatMap(Double.init), pace > 0 else { return }
        Thread.sleep(forTimeInterval: seconds * pace)
    }

    /// A file's row in a list, by its name.
    private func row(_ name: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func waitForNote() {
        XCTAssertTrue(app.textViews["Note"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// The row is gone from every list on screen within `seconds`. A list keeps the text of a row it took away for a
    /// while, out of sight: only one on screen counts.
    private func assertGone(_ name: String, within seconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.staticTexts.matching(NSPredicate(format: "label == %@", name))
        let end = Date().addingTimeInterval(seconds)
        func shown() -> Bool { rows.allElementsBoundByIndex.contains(where: isOnScreen) }
        while shown(), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(shown(), "“\(name)” still there after \(seconds) s", file: file, line: line)
    }

    /// Whether a row's text is where you can see it: a row a list took away has none, or one of no size.
    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return frame.width >= 1 && frame.height >= 1 && app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The row is in a list on screen within `seconds`.
    private func assertShown(_ name: String, within seconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.staticTexts.matching(NSPredicate(format: "label == %@", name))
        let end = Date().addingTimeInterval(seconds)
        func shown() -> Bool { rows.allElementsBoundByIndex.contains(where: isOnScreen) }
        while !shown(), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(shown(), "“\(name)” not there after \(seconds) s", file: file, line: line)
    }

    /// A row, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }
}
