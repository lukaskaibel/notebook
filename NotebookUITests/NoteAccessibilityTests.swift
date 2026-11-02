import XCTest

/// What VoiceOver reads in a note on iPhone and iPad (#214): each line as it shows, without its Markdown; a to-do says
/// whether it is done and VoiceOver's double-tap ticks it; links are links and pictures and drawings have names. A
/// double-tap on a line starts writing there, in the one text field VoiceOver edits. The app starts on fresh sample
/// notes in its own home folder, so nothing of yours is touched; VoiceOver's double-tap comes through the debug remote,
/// which calls the element's `accessibilityActivate()` as VoiceOver does.
final class NoteAccessibilityTests: XCTestCase {
    var app: XCUIApplication!
    private var commands = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("commands-\(UUID().uuidString).txt")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: commands)
        try? FileManager.default.removeItem(at: commands.appendingPathExtension("log"))
        super.tearDown()
    }

    func testANoteReadsAsItShows() throws {
        launch()
        open("Travel", "Kyoto trip")
        XCTAssertTrue(element("Packing").waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(element("Packing").elementType, .staticText, "a heading")
        XCTAssertTrue(find(.staticText, "Five days in October. Flights and the ryokan are booked, everything else stays loose. Costs are in Budget, the tickets in Flight tickets.pdf.").exists, app.debugDescription)
        XCTAssertTrue(find(.link, "Budget").exists, app.debugDescription)
        XCTAssertTrue(find(.link, "ryokan's site").exists, app.debugDescription)
        XCTAssertTrue(find(.image, "torii").exists, "a picture by its name: \(app.debugDescription)")
        XCTAssertTrue(find(.staticText, "Day 2 Arashiyama: bamboo grove early, then along the river").exists, app.debugDescription)
        XCTAssertTrue(find(.staticText, "Tip: Good to know").exists, app.debugDescription)
        XCTAssertTrue(find(.staticText, "Day: 1, Area: Fushimi, Note: Early start").exists, "a table's row: \(app.debugDescription)")
        XCTAssertEqual(find(.button, "Passport").value as? String, "Completed")
        XCTAssertEqual(find(.button, "Rain jacket").value as? String, "Not completed")
        XCTAssertTrue(find(.button, "Flight tickets.pdf").exists, "the PDF shown in the note: \(app.debugDescription)")
        // Nothing reads the Markdown: what VoiceOver goes through in the note, label | value | traits | frame | actions.
        let reading = remote("reading")
        XCTAssertGreaterThan(reading.components(separatedBy: "\n").count, 25, reading)
        for mark in ["- [", "[[", "**", "](", "==", "> [!", "| ---", "## ", ".assets"] {
            XCTAssertFalse(reading.contains(mark), "reads \(mark): \(reading)")
        }

        open("Travel", "Getting to the ryokan", back: true)
        XCTAssertTrue(find(.image, "Drawing").waitForExistence(timeout: 30), app.debugDescription)
    }

    /// VoiceOver's double-tap ticks a to-do as a tap on its circle does, and says so; its other actions are there.
    func testADoubleTapTicksAToDo() throws {
        launch()
        open("Travel", "Kyoto trip")
        let jacket = find(.button, "Rain jacket")
        XCTAssertTrue(jacket.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(jacket.value as? String, "Not completed")

        XCTAssertEqual(remote("activate Rain jacket"), "activate Rain jacket: ReadingElement true")
        waitFor(jacket, value: "Completed")
        XCTAssertTrue(remote("text").contains("- [x] Rain jacket"), "written in the note")
        XCTAssertEqual(app.keyboards.count, 0, "ticking doesn't start writing")
        let reading = remote("reading")
        XCTAssertTrue(reading.contains("Rain jacket | Completed | 1 |"), reading)
        XCTAssertTrue(reading.contains("Power adapter, type A | Not completed | 1 |") && reading.contains("| Edit,Remind Me"), reading)

        // And back, as a tap on its circle: VoiceOver's own tap lands there when an app doesn't act on the double-tap.
        jacket.tap()
        waitFor(jacket, value: "Not completed")
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertTrue(remote("text").contains("- [ ] Rain jacket"))
    }

    /// A double-tap on a line writes at its end; while writing, the note is the text field VoiceOver edits, and when the
    /// keyboard goes it is read line by line again.
    func testADoubleTapOnALineStartsWritingThere() throws {
        launch()
        open("Personal", "Weekend")
        let line = "Market on Saturday morning, cooking with Mia in the evening. Sunday stays empty on purpose."
        XCTAssertTrue(find(.staticText, line).waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(remote("activate \(line)").hasSuffix("ReadingElement true"))
        let hide = app.buttons.matching(NSPredicate(format: "label == %@", "Hide Keyboard")).firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 30), app.debugDescription)
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue((note.value as? String)?.contains("- [ ] Market shopping") == true, "one text to edit, as it is written")
        app.typeText(" Or not.")
        XCTAssertTrue(remote("text").contains("empty on purpose. Or not.\n"), "written at the end of the line")
        hide.tap()
        XCTAssertTrue(find(.staticText, line + " Or not.").waitForExistence(timeout: 30), app.debugDescription)
    }

    // MARK: - Steps

    private func launch() {
        FileManager.default.createFile(atPath: commands.path, contents: nil)
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
        app.launch()
    }

    /// A note in a folder, from the start screen or, `back`, from another note in the same folder.
    private func open(_ folder: String, _ name: String, back: Bool = false) {
        if back { app.navigationBars.buttons.element(boundBy: 0).tap() } else { tap(folder) }
        tap(name)
    }

    /// An element of a kind in the note, by what VoiceOver reads.
    private func find(_ type: XCUIElement.ElementType, _ label: String) -> XCUIElement {
        app.textViews["Note"].firstMatch.descendants(matching: type).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = element(label)
        XCTAssertTrue(element.waitForExistence(timeout: 30), app.debugDescription, file: file, line: line)
        element.tap()
    }

    private func waitFor(_ element: XCUIElement, value: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "\(element.value ?? "")", file: file, line: line)
    }

    /// Runs a debug remote command in the app and returns what it logged for it.
    @discardableResult
    private func remote(_ command: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let log = commands.appendingPathExtension("log")
        let before = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let handle = try? FileHandle(forWritingTo: commands)
        handle?.seekToEndOfFile()
        handle?.write(Data((command + "\nwait 0.3\n").utf8))
        try? handle?.close()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let now = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let added = String(now.dropFirst(before.count))
            if let start = added.range(of: "> \(command)\n"), let end = added.range(of: "> wait 0.3", range: start.upperBound..<added.endIndex) {
                return String(added[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .newlines)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("no answer to \(command)", file: file, line: line)
        return ""
    }
}
