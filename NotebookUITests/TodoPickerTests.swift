import XCTest

/// To-dos' bar above the keyboard on iPhone and iPad: Date, Time and Location turn the bar into a field to type in, the
/// choices rising above it, and the keyboard stays up from the to-do's words to the field and back. The to-do stays
/// where it is meanwhile, a sub-to-do opens under it, and a new to-do's circle sits on the line of its words. The app
/// starts on fresh sample notes in its own home folder, so nothing of yours is touched.
final class TodoPickerTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testADateTypedAboveTheKeyboard() throws {
        launch()
        openTodos()
        let plants = row("Water the plants")
        plants.tap()
        let words = app.textFields["To-do"].firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), app.debugDescription)
        let top = words.frame.minY
        shot("1-editing")

        app.buttons["Date"].firstMatch.tap()
        let field = app.textFields["Type a date, like next Thursday"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        keyboardStaysUp(for: 1)
        XCTAssertTrue(field.hasFocus, "the field has the keyboard at once")
        XCTAssertTrue(choice("Tomorrow").exists, app.debugDescription)
        shot("2-picker")

        field.typeText("next week on thursday")
        let next = choice("Next Thursday")
        XCTAssertTrue(next.waitForExistence(timeout: 10), app.debugDescription)
        shot("3-typed")
        next.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), app.debugDescription)
        keyboardStaysUp(for: 1)
        allowNotifications()
        // Back in its words, where it was: it goes to Next 7 Days once it is done.
        XCTAssertTrue(words.hasFocus, app.debugDescription)
        XCTAssertEqual(words.frame.minY, top, accuracy: 1, "the to-do stays where it is while it is edited")
        XCTAssertEqual(app.buttons["Date"].firstMatch.value as? String, nextThursday, app.debugDescription)
        shot("4-picked")

        // The close button leaves it as it was, the keyboard up.
        app.buttons["Time"].firstMatch.tap()
        let time = app.textFields["Type a time, like 9:30 or evening"]
        XCTAssertTrue(time.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Close"].tap()
        XCTAssertTrue(time.waitForNonExistence(timeout: 10), app.debugDescription)
        keyboardStaysUp(for: 0.5)
        XCTAssertTrue(words.hasFocus, app.debugDescription)
    }

    func testHomeAddressSlidesIn() throws {
        launch()
        openTodos()
        row("Water the plants").tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Location"].firstMatch.tap()
        let field = app.textFields["Search for a place"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        choice("Home").tap()
        // A page of its own, with the way back, and the field asks for the address; the keyboard stays.
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textFields["Search for your home address"].exists, app.debugDescription)
        XCTAssertTrue(choice("Choose from Contacts…").exists, app.debugDescription)
        keyboardStaysUp(for: 0.5)
        shot("5-home-address")
        back.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(choice("Current Location").exists, app.debugDescription)
    }

    func testANewTodosCircleIsOnTheLineOfItsWords() throws {
        launch()
        openTodos()
        let new = app.buttons["New To-do"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10), app.debugDescription)
        new.tap()
        let field = app.textFields["To-do"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), app.debugDescription)
        shot("6-new")
        let ring = try XCTUnwrap(tickCircle(beside: field), app.debugDescription)
        // Centred on the capitals of the placeholder, a little above the middle of its line.
        XCTAssertEqual(ring.frame.midY, field.frame.midY, accuracy: 4, "circle \(ring.frame), words \(field.frame)")

        // A sub-to-do: its own circle on its line too, and the keyboard goes to it.
        field.typeText("Plumber")
        app.buttons["Add Sub-to-do"].firstMatch.tap()
        let sub = app.textFields["Sub-to-do"].firstMatch
        XCTAssertTrue(sub.waitForExistence(timeout: 10), app.debugDescription)
        keyboardStaysUp(for: 0.5)
        XCTAssertTrue(sub.hasFocus, app.debugDescription)
        shot("7-sub-to-do")
        let small = try XCTUnwrap(tickCircle(beside: sub), app.debugDescription)
        XCTAssertEqual(small.frame.midY, sub.frame.midY, accuracy: 4, "circle \(small.frame), words \(sub.frame)")
    }

    // MARK: - Helpers

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
        XCTAssertTrue(row("Water the plants").waitForExistence(timeout: 240), app.debugDescription)
    }

    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    /// The keyboard is there each time it is looked at, for this long.
    private func keyboardStaysUp(for seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date.now.addingTimeInterval(seconds)
        repeat {
            XCTAssertTrue(keyboard.exists, "the keyboard went down", file: file, line: line)
        } while Date.now < end
    }

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// A choice above the keyboard, read with its details: "Tomorrow, Wed, Oct 28".
    private func choice(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// The circle to tick on the line of a field.
    private func tickCircle(beside field: XCUIElement) -> XCUIElement? {
        app.buttons.matching(identifier: "Mark as Done").allElementsBoundByIndex
            // Its touch area reaches a little past the circle.
            .filter { $0.frame.midX < field.frame.minX && abs($0.frame.midY - field.frame.midY) < 40 }
            .min { abs($0.frame.midY - field.frame.midY) < abs($1.frame.midY - field.frame.midY) }
    }

    /// The first date set asks to send notifications: yes.
    private func allowNotifications() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// Next week's Thursday as the bar shows it.
    private var nextThursday: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        let thursday = calendar.date(byAdding: .day, value: 3, to: monday)!
        // The app runs in English, the test runner as the Mac does.
        let style = Date.FormatStyle(locale: Locale(identifier: "en_US"))
        return calendar.dateComponents([.day], from: today, to: thursday).day! < 7
            ? thursday.formatted(style.weekday(.wide)) : thursday.formatted(style.month(.abbreviated).day())
    }

    private func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-todo-picker-\(name).png"))
    }
}

private extension XCUIElement {
    var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
