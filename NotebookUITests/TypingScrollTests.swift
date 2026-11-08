import XCTest

/// Writing at the bottom of what shows on iPhone and iPad: the line being written stays above the bar over the keyboard
/// as you type, press Return, go on with a list or paste, without a hand on the screen to scroll. Typed as the keyboard
/// types; where the caret is on the screen comes from the debug remote. The app starts on fresh sample notes in its own
/// home folder, so nothing of yours is touched.
final class TypingScrollTests: XCTestCase {
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

    /// Return in the middle of a note, on the last line that shows: the lines below move down, and the note with them.
    func testReturnInTheMiddleKeepsTheLineAboveTheKeyboard() throws {
        try writeAtTheBottomOfALongNote()
        for word in ["one", "two", "three", "four", "five", "six"] {
            app.typeText("\n" + word)
            try checkCaretShows("after Return and “\(word)”")
        }
    }

    /// A list goes on with the next bullet, which the editor puts in rather than the keyboard.
    func testAListGoesOnAboveTheKeyboard() throws {
        try writeAtTheBottomOfALongNote()
        app.typeText("\n- milk")
        try checkCaretShows("after the first item")
        for word in ["eggs", "bread", "butter", "tea", "rice"] {
            app.typeText("\n" + word)
            try checkCaretShows("after Return and “\(word)”")
        }
        XCTAssertTrue(remote("text").contains("- milk\n- eggs\n- bread\n- butter\n- tea\n- rice"), "a list")
    }

    /// A bullet point long enough to run on over several lines, then the next bullet, as reported on an iPhone with
    /// iOS 27.2: neither the words running on nor the new bullet scrolled the note.
    func testALongBulletRunsOnAboveTheKeyboard() throws {
        try writeAtTheBottomOfALongNote()
        app.typeText("\n- Packing")
        try checkCaretShows("after the first bullet")
        for item in 1...2 {
            for words in [" for the weekend in the mountains", " with boots, a warm jacket and", " gloves, a thermos for tea, the map", " and the charger for the phone, which", " ran out last time halfway up"] {
                app.typeText(words)
                try checkCaretShows("after “\(words)” in bullet \(item)")
            }
            app.typeText("\nNext")
            try checkCaretShows("after Return for bullet \(item + 1)")
        }
    }

    /// Return on an empty line, again and again: nothing typed between to scroll the note.
    func testEmptyLinesKeepTheCaretAboveTheKeyboard() throws {
        try writeAtTheBottomOfALongNote()
        for index in 1...6 {
            app.typeText("\n")
            try checkCaretShows("after Return \(index)")
        }
    }

    /// At the end of the note, words that run on to the next line and lines after them.
    func testTheEndOfTheNoteFollowsTheCaret() throws {
        try writeAtTheBottomOfALongNote(atEnd: true)
        app.typeText("A sentence long enough to run on over the end of the line and on to the next one, and on.")
        try checkCaretShows("after a long sentence")
        for word in ["one", "two", "three", "four"] {
            app.typeText("\n" + word)
            try checkCaretShows("after Return and “\(word)”")
        }
    }

    /// Lines pasted where you write: the caret after them shows.
    func testPastedLinesShowWhereTheyEnd() throws {
        try writeAtTheBottomOfALongNote()
        // What Paste does, without the pasteboard, which the Simulator shares with the Mac's.
        _ = remote("pastetext " + (1...8).map { "Pasted line \($0)" }.joined(separator: "\\n"))
        try checkCaretShows("after pasting eight lines")
    }

    /// The keys of the keyboard on the screen, tapped: a heading, a to-do and a quote go on with Return.
    func testKeysTappedOnTheKeyboardKeepTheLineAboveIt() throws {
        try writeAtTheBottomOfALongNote()
        for (start, words) in [("\n# ", "Plans"), ("\n- [ ] ", "call"), ("\n> ", "quote")] {
            app.typeText(start)
            tapKeys(words)
            try checkCaretShows("after “\(start)\(words)”")
            for index in 1...3 {
                tapKey("return")
                try checkCaretShows("after Return \(index) after “\(words)”")
                tapKeys("ab")
                try checkCaretShows("after typing after Return \(index) after “\(words)”")
            }
        }
    }

    // MARK: -

    private var note: XCUIElement { app.textViews["Note"].firstMatch }

    /// Letters tapped on the keyboard, one key at a time.
    private func tapKeys(_ letters: String) {
        for letter in letters { tapKey(String(letter)) }
    }

    private func tapKey(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        let key = keyboard.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", name, name)).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "no key \(name): \(keyboard.debugDescription)", file: file, line: line)
        key.tap()
    }

    /// A note longer than the screen, with the keyboard up and the caret on the last line that shows above it (or, with
    /// `atEnd`, at the end of the note).
    private func writeAtTheBottomOfALongNote(atEnd: Bool = false) throws {
        FileManager.default.createFile(atPath: commands.path, contents: nil)
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
        app.launch()
        tap("Personal")
        tap("Weekend")
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        // Below the last line, which puts the caret at the end.
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        let bar = button("Hide Keyboard")
        XCTAssertTrue(bar.waitForExistence(timeout: 30), app.debugDescription)
        // Lines enough to fill the screen twice, put in at once.
        _ = remote("type " + (1...40).map { "Line \($0) of the note" }.joined(separator: "\\n"))
        guard !atEnd else { return try checkCaretShows("at the end") }
        // A tap on the last line above the bar, which puts the caret in it.
        let (_, barTop) = try caretAndBar()
        let window = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width / 2, dy: barTop - 40)).tap()
        let (caret, _) = try caretAndBar()
        XCTAssertGreaterThan(caret.maxY, barTop - 80, "the caret on the last line that shows: \(remote("scrollinfo"))")
    }

    /// The caret's line is above the bar over the keyboard, and below the bar at the top.
    private func checkCaretShows(_ when: String, file: StaticString = #filePath, line: UInt = #line) throws {
        // Scrolling may take a moment, as it eases.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let (caret, barTop) = try caretAndBar()
        let info = remote("scrollinfo")
        XCTAssertLessThanOrEqual(caret.maxY, barTop - 8, "\(when), the caret is under the bar: \(info)", file: file, line: line)
        XCTAssertGreaterThan(caret.minY, 100, "\(when), the caret is under the top: \(info)", file: file, line: line)
    }

    /// The caret's frame on the screen and the top of the bar over the keyboard, in points.
    private func caretAndBar() throws -> (caret: (minY: Double, maxY: Double), barTop: Double) {
        let info = remote("scrollinfo")
        func numbers(after label: String) -> [Double]? {
            guard let range = info.range(of: label + " ") else { return nil }
            let rest = info[range.upperBound...].prefix { $0 != "," }
            return rest.split(separator: "–").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let caret = try XCTUnwrap(numbers(after: "caret y"), info)
        let bar = try XCTUnwrap(numbers(after: "bar y"), info)
        return ((caret[0], caret[1]), bar[0])
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 30), app.debugDescription, file: file, line: line)
        element.tap()
    }

    /// Runs a command of the debug remote and gives back what it logged.
    private func remote(_ command: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let log = commands.appendingPathExtension("log")
        let before = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let handle = try? FileHandle(forWritingTo: commands)
        handle?.seekToEndOfFile()
        handle?.write(Data((command + "\nwait 0.3\n").utf8))
        try? handle?.close()
        let deadline = Date().addingTimeInterval(30)
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
