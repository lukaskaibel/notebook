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
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
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

    /// While drawing, Apple Pencil draws: neither the text nor the title takes it for handwriting. Otherwise they do.
    func testScribbleWaitsWhileDrawing() {
        XCTAssertEqual(answer("scribbleat 300 300", startingWith: "scribble"), "scribble text [true] title [true]")
        XCTAssertEqual(answer("drawing", startingWith: "drawing"), "drawing true")
        XCTAssertEqual(answer("scribbleat 300 300", startingWith: "scribble"), "scribble text [false] title [false]")
        XCTAssertEqual(answer("drawing", startingWith: "drawing"), "drawing false")
        XCTAssertEqual(answer("scribbleat 300 300", startingWith: "scribble"), "scribble text [true] title [true]")
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
