import XCTest

/// An iPhone: the folder chosen in Settings › Default Folder is where New Note on the first screen puts the note. The
/// app starts on fresh sample notes in its own home folder, so nothing of yours is touched.
final class PhoneDefaultFolderTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testNewNoteGoesToTheDefaultFolder() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the first screen's New Note is the iPhone's")
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        tap("More")
        tap("Settings")
        let row = element(beginningWith: "Default Folder")
        XCTAssertEqual(row.label, "Default Folder, Inbox")
        row.tap()
        XCTAssertTrue(app.navigationBars["Default Folder"].waitForExistence(timeout: 5), app.debugDescription)
        // The screens behind have rows of these names too: the ticked one is the list's.
        let ticked = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == true", "Inbox")).firstMatch
        XCTAssertTrue(ticked.waitForExistence(timeout: 5), "the Inbox isn’t ticked: \(app.debugDescription)")
        tap("Design")
        // Back in Settings, with the folder chosen.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(element(beginningWith: "Default Folder").label, "Default Folder, Design")
        tap("Done")

        tap("New Note")
        // Named, so it stays when it is left.
        app.typeText("Moodboard")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        tap("Projects")
        tap("Design")
        XCTAssertTrue(element(beginningWith: "Moodboard").waitForExistence(timeout: 5), "not in Design: \(app.debugDescription)")
    }

    /// A row of a list, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }

    private func element(beginningWith text: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        return element
    }
}
