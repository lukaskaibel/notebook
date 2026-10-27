import XCTest

/// To-dos on iPhone and iPad as in Reminders: a to-do swiped to the left shows Delete behind it, and swiped all the
/// way across it goes from its note; a drag up or down still scrolls. New To-do adds one in no note, and Move to Note…
/// puts it into a note. The app starts on fresh sample notes in its own home folder, so nothing of yours is touched.
final class TodosTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testSwipeToDelete() throws {
        launch()
        openTodos()
        let books = row("Return the library books")
        let delete = app.buttons["Delete"]
        XCTAssertFalse(delete.exists)
        // VoiceOver reads a row's date as one button in words, not its symbol's name ("Calendar") beside it.
        XCTAssertTrue(app.buttons["Overdue, Yesterday"].exists, app.debugDescription)

        // Partway across: Delete shows, and stays when the finger lifts.
        drag(books, from: 0.85, to: 0.55)
        XCTAssertTrue(delete.waitForExistence(timeout: 10), app.debugDescription)
        shot("1-swiped")
        // A tap on the row closes it again.
        books.tap()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 10), app.debugDescription)

        drag(books, from: 0.85, to: 0.55)
        XCTAssertTrue(delete.waitForExistence(timeout: 10), app.debugDescription)
        delete.tap()
        XCTAssertTrue(books.waitForNonExistence(timeout: 10), app.debugDescription)
        shot("2-deleted")

        // All the way across: it goes at once.
        let mia = row("Send the map to Mia")
        drag(mia, from: 0.9, to: 0.05)
        XCTAssertTrue(mia.waitForNonExistence(timeout: 10), app.debugDescription)

        // Up and down is scrolling, not a swipe.
        let plants = row("Water the plants")
        let before = plants.frame.minY
        plants.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: plants.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: -4)), withVelocity: 400, thenHoldForDuration: 0.2)
        XCTAssertLessThan(plants.frame.minY, before - 50, "the list scrolled")
        XCTAssertFalse(delete.exists)
        shot("3-scrolled")
    }

    /// Shaken, as Reminders: Undo Delete To-do brings it back, with the lines under it.
    func testShakeToUndoADelete() throws {
        launch()
        openTodos()
        let cleaning = row("Pick up the dry cleaning")
        XCTAssertTrue(cleaning.waitForExistence(timeout: 10), app.debugDescription)
        drag(cleaning, from: 0.85, to: 0.55)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), app.debugDescription)
        delete.tap()
        XCTAssertTrue(cleaning.waitForNonExistence(timeout: 10), app.debugDescription)

        shake()
        let undo = app.alerts.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        shot("4-shaken")
        undo.tap()
        XCTAssertTrue(cleaning.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(row("The ticket is in the blue jacket").exists, app.debugDescription)
    }

    /// New To-do at the bottom, as in Reminders: one for today, typed in; Return starts the next, and one left empty
    /// goes. Move to Note… puts it into a note picked in ⌘K, and shaking takes that back.
    func testNewTodoAndMoveToNote() throws {
        launch()
        openTodos()
        let new = app.buttons["New To-do"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10), app.debugDescription)
        new.tap()
        let field = app.textFields["To-do"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        // One word each: a fresh Simulator's keyboard can drop the first space typed.
        field.typeText("Plumber")
        shot("5-new")
        field.typeText("\n")
        // The next one, under it.
        let next = app.textFields["To-do"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), app.debugDescription)
        next.typeText("Milk\n")
        XCTAssertTrue(app.textFields["To-do"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // Return in one left empty is done, and it goes.
        app.textFields["To-do"].firstMatch.typeText("\n")
        XCTAssertTrue(app.textFields["To-do"].firstMatch.waitForNonExistence(timeout: 10), app.debugDescription)
        let plumber = row("Plumber")
        XCTAssertTrue(plumber.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row("Milk").exists, app.debugDescription)
        shot("6-added")

        // Into a note, picked in ⌘K.
        plumber.press(forDuration: 1.2)
        let move = app.buttons["Move to Note…"]
        XCTAssertTrue(move.waitForExistence(timeout: 10), app.debugDescription)
        shot("7-menu")
        move.tap()
        let search = app.textFields["Search or run a command"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        shot("8-picker")
        search.typeText("Errands")
        let errands = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Errands")).element(boundBy: 0)
        XCTAssertTrue(errands.waitForExistence(timeout: 30), app.debugDescription)
        shot("9-picker-typed")
        errands.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 10), app.debugDescription)
        // Now in Errands: its menu opens the note rather than moving it.
        XCTAssertTrue(plumber.waitForExistence(timeout: 30), app.debugDescription)
        shot("10-moved")
        plumber.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Mark as In Progress"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["Move to Note…"].exists, app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(app.buttons["Mark as In Progress"].waitForNonExistence(timeout: 10), app.debugDescription)

        // Shaken, Undo puts it back among those in no note.
        shake()
        let undo = app.alerts.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.alerts.staticTexts["Undo Move to Note"].exists, app.debugDescription)
        undo.tap()
        plumber.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Move to Note…"].waitForExistence(timeout: 30), app.debugDescription)
    }

    /// The Simulator's Device › Shake: a notification the app's UIKit takes for a shake.
    private func shake() {
        typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post") else { return XCTFail("no notify_post") }
        _ = unsafeBitCast(symbol, to: Post.self)("com.apple.UIKit.SimulatorShake")
    }

    private func launch() {
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func openTodos() {
        let todos = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "To-dos")).firstMatch
        XCTAssertTrue(todos.waitForExistence(timeout: 30), app.debugDescription)
        todos.tap()
        // The to-dos are read once the notes have been: on a fresh library that takes a while.
        XCTAssertTrue(row("Return the library books").waitForExistence(timeout: 240), app.debugDescription)
    }

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// A finger across a row's words, from and to these parts of their width.
    private func drag(_ element: XCUIElement, from start: CGFloat, to end: CGFloat) {
        element.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)), withVelocity: 300, thenHoldForDuration: 0.1)
    }

    private func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-todos-\(name).png"))
    }
}
