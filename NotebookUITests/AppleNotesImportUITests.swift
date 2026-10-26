import XCTest

/// Import from Apple Notes in the ⋯ menu, with the folder Notes exported picked in the Files app's picker, where you
/// would have saved it: On My iPhone (On My iPad). The app starts on fresh sample notes in its own home folder, and
/// writes a made-up Notes export to On My iPhone (`-NotebookDemoExport`), which the test takes away again, so nothing
/// of yours is touched.
final class AppleNotesImportUITests: XCTestCase {
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

    /// On the iPhone, from a folder's ⋯ menu, into that folder.
    func testImportOnTheIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "a folder's ⋯ menu is the iPhone's")
        try launch()
        tap("Inbox")
        tap("More")
        shot("1-menu")
        tap("Import from Apple Notes")
        try pickExport()

        // In the Inbox now, with the folders the exports were saved in, each note's picture in its `.assets`, and
        // links between the notes as [[links]].
        tap("From Notes")
        tap("Trips")
        XCTAssertTrue(app.staticTexts["Shrines to see"].waitForExistence(timeout: 10), app.debugDescription)
        shot("3-folder")
        tap("Osaka weekend")
        try checkNote()
    }

    /// On the iPad, from the sidebar's ⋯ menu, into the default folder with no note open: the Inbox.
    func testImportOnTheIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar's ⋯ menu is the iPad's")
        XCUIDevice.shared.orientation = .landscapeLeft
        try launch()
        tap("More")
        shot("1-menu")
        tap("Import from Apple Notes")
        try pickExport()

        // The sidebar shows what came, opened down to it.
        XCTAssertTrue(app.staticTexts["From Notes"].waitForExistence(timeout: 10), app.debugDescription)
        tap("Trips")
        tap("Osaka weekend")
        try checkNote()
    }

    private func launch() throws {
        let export = try onMyDevice().appendingPathComponent("From Notes", isDirectory: true)
        self.export = export
        try? FileManager.default.removeItem(at: export)
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library",
                               "-NotebookDemo", "YES", "-NotebookDemoExport", export.path, "-NotebookTips", "hide",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    /// The Files app's picker, from another process a moment later: On My iPhone, into the folder Notes' export is in,
    /// and Open. On the iPhone, On My iPhone is under Browse; on the iPad, in the picker's sidebar.
    private func pickExport() throws {
        let place = UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
        let browse = app.buttons["Browse"]
        let sidebarItem = app.cells["DOC.sidebar.item.\(place)"]
        let end = Date().addingTimeInterval(20)
        while !browse.exists, !sidebarItem.exists, Date() < end { Thread.sleep(forTimeInterval: 0.5) }
        if sidebarItem.exists {
            sidebarItem.tap()
        } else {
            XCTAssertTrue(browse.exists, app.debugDescription)
            browse.tap()
            if !cell("From Notes").waitForExistence(timeout: 5) { tap(place) }
        }
        let folder = cell("From Notes")
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        XCTAssertTrue(cell("Trips").waitForExistence(timeout: 10), app.debugDescription)
        shot("2-picker")
        tap("Open")
    }

    private func checkNote() throws {
        let note = app.textViews["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(note, containing: "What to take is in [[Packing list]], the shrines in [[Shrines to see]].")
        waitForValue(note, containing: "![](.assets/IMG_2050.jpg)")
        waitForValue(note, lacking: "Osaka weekend\n")
        Thread.sleep(forTimeInterval: 1)
        shot("4-note")
    }

    /// On My iPhone in the Files app: the folder of the Simulator's File Provider for the device's own storage, next to
    /// the containers of the apps.
    private func onMyDevice() throws -> URL {
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

    /// A row of the Files app's picker, whose name starts with the file's ("From Notes, Folder, …").
    private func cell(_ name: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
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
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
