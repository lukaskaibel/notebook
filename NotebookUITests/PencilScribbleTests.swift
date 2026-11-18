import XCTest

/// Apple Pencil in a note on iPad (#384). A simulator has no Apple Pencil, so these ask the editor what the system
/// asks it, and make the calls Scribble makes, through the debug remote. The app starts on fresh sample notes in its
/// own home folder, so nothing of yours is touched.
final class PencilScribbleTests: XCTestCase {
    private var app: XCUIApplication!
    private let commands = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("commands-\(UUID().uuidString).txt")
    private var log: URL { commands.appendingPathExtension("log") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        FileManager.default.createFile(atPath: commands.path, contents: nil)
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-NotebookFingerIsPencil", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
        app.launch()
        XCTAssertTrue(waitForLog("ready"), "the debug remote didn't start")
        send("open Personal/Weekend.md")
        XCTAssertTrue(app.textViews["Note"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: commands)
        try? FileManager.default.removeItem(at: log)
        super.tearDown()
    }

    /// Scribble never writes in the note's text, where Apple Pencil draws. It writes in the title, except while drawing.
    func testScribbleStaysOutOfTheNote() {
        XCTAssertEqual(answer("scribbleat 300 300", startingWith: "scribble"), "scribble text [false] title [true]")
        XCTAssertEqual(answer("drawing", startingWith: "drawing"), "drawing true")
        XCTAssertEqual(answer("scribbleat 300 300", startingWith: "scribble"), "scribble text [false] title [false]")
    }

    /// A stroke on the text starts a drawing with the stroke in it, and the next one, right after, isn't lost. (A finger
    /// stands in for Apple Pencil.)
    func testAStrokeOnTheTextStartsADrawing() {
        stroke(fromY: 0.45)
        // Right after it, as in handwriting: PencilKit's canvas has to take this one itself.
        stroke(fromY: 0.53)
        let info = waitForInfo { $0.contains("drawing mode true") && $0.contains(" 2 strokes ") }
        XCTAssertEqual(info.components(separatedBy: "    stroke ").count - 1, 2, info)
    }

    /// A tap stays a tap: no drawing.
    func testATapStartsNoDrawing() {
        app.textViews["Note"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(answer("drawinfo", startingWith: "drawing mode").hasPrefix("drawing mode false"))
    }

    private func stroke(fromY y: Double) {
        let note = app.textViews["Note"].firstMatch
        let start = note.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: y))
        start.press(forDuration: 0.05, thenDragTo: note.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: y + 0.03)))
    }

    /// What `drawinfo` says once `done` holds for it.
    private func waitForInfo(_ done: (String) -> Bool) -> String {
        var info = ""
        for _ in 0..<40 {
            let before = logged.count
            send("drawinfo")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            info = String(logged.dropFirst(before))
            if done(info) { return info }
        }
        XCTFail("not as expected: \(info)")
        return info
    }

    /// What Scribble does to the text, at random places, in and out of drawing mode, leaves the app running.
    func testTheCallsScribbleMakesLeaveTheAppRunning() {
        send("scribblefuzz 384 200")
        XCTAssertTrue(waitForLog("scribblefuzz done", timeout: 60), "\(lastLines())")
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func send(_ command: String) {
        let handle = try? FileHandle(forWritingTo: commands)
        handle?.seekToEndOfFile()
        handle?.write(Data((command + "\n").utf8))
        try? handle?.close()
    }

    private var logged: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    private func lastLines() -> String { logged.components(separatedBy: "\n").suffix(5).joined(separator: "\n") }

    private func waitForLog(_ text: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if logged.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Runs a command and gives back the first line it logged that starts with `prefix`.
    private func answer(_ command: String, startingWith prefix: String) -> String {
        let before = logged.count
        send(command)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let added = logged.dropFirst(before).components(separatedBy: "\n")
            if let line = added.first(where: { $0.hasPrefix(prefix) }) { return line }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("no answer to \(command): \(lastLines())")
        return ""
    }
}
