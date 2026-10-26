import XCTest

/// An iPhone: Import from Apple Notes in a folder's ⋯ menu, with the folder Notes exported picked in the Files app's
/// picker, where you would have saved it: On My iPhone. The app starts on fresh sample notes in its own home folder,
/// and writes a made-up Notes export to On My iPhone (`-NotebookDemoExport`), which the test takes away again, so
/// nothing of yours is touched.
final class PhoneImportTests: XCTestCase {
    var app: XCUIApplication!
    var export: URL?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        if let export { try? FileManager.default.removeItem(at: export) }
        super.tearDown()
    }

    func testImportFromAppleNotes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "a folder's ⋯ menu is the iPhone's")
        let export = try onMyIPhone().appendingPathComponent("From Notes", isDirectory: true)
        self.export = export
        try? FileManager.default.removeItem(at: export)
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library",
                               "-NotebookDemo", "YES", "-NotebookDemoExport", export.path, "-NotebookTips", "hide",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        tap("Inbox")
        tap("More")
        shot("1-menu")
        tap("Import from Apple Notes")
        // The Files app's picker, from another process a moment later: On My iPhone, then into the folder Notes' export
        // is in, and Open.
        let browse = app.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20), app.debugDescription)
        browse.tap()
        if !element(containing: "From Notes").waitForExistence(timeout: 5) { tap("On My iPhone") }
        let folder = element(containing: "From Notes")
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        XCTAssertTrue(element(containing: "Trips").waitForExistence(timeout: 10), app.debugDescription)
        shot("2-picker")
        tap("Open")

        // In the Inbox now, with the folders the exports were saved in, each note's picture in its `.assets`, and
        // links between the notes as [[links]].
        tap("From Notes")
        tap("Trips")
        XCTAssertTrue(app.staticTexts["Shrines to see"].waitForExistence(timeout: 10), app.debugDescription)
        shot("3-folder")
        tap("Osaka weekend")
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(note, containing: "What to take is in [[Packing list]], the shrines in [[Shrines to see]].")
        waitForValue(note, containing: "![](.assets/IMG_2050.jpg)")
        waitForValue(note, lacking: "Osaka weekend\n")
        Thread.sleep(forTimeInterval: 1)
        shot("4-note")
    }

    /// On My iPhone in the Files app: the folder of the Simulator's File Provider for this device's own storage, next
    /// to the containers of the apps.
    private func onMyIPhone() throws -> URL {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let groups = containers.appendingPathComponent("Shared/AppGroup")
        for group in (try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let metadata = NSDictionary(contentsOf: group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
            if metadata?["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage" {
                return group.appendingPathComponent("File Provider Storage", isDirectory: true)
            }
        }
        throw XCTSkip("this Simulator has no On My iPhone")
    }

    /// A row, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }

    /// The first cell whose name starts with `text`, as the Files app's picker names its rows ("From Notes, Folder, …").
    private func element(containing text: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func waitForValue(_ element: XCUIElement, containing text: String? = nil, lacking: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return text.map(value.contains) ?? true && !(lacking.map(value.contains) ?? false)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 6), .completed, "\(String(describing: element.value))", file: file, line: line)
    }

    /// The screen, for a pull request's pictures, when the runner is given a folder for them
    /// (`TEST_RUNNER_SHOTS=<folder> xcodebuild test …`).
    private func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("iphone-\(name).png"))
    }
}
