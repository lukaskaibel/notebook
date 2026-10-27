import XCTest

/// An iPhone: a note's text follows the system's text size, on top of the size chosen in Settings › Text. The app starts
/// on fresh sample notes in its own home folder, once at the standard size and once at a larger one, and the note's
/// title, twice the text's size, is taller at the larger.
final class TextSizeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testANoteFollowsTheSystemTextSize() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "it goes through the iPhone's screens")
        let standard = try titleHeight(category: "UICTContentSizeCategoryL")
        let larger = try titleHeight(category: "UICTContentSizeCategoryAccessibilityM")
        XCTAssertGreaterThan(larger, standard * 1.4, "the note's text didn't grow with the system's text size")
    }

    /// The height of the open note's title, with the app started at a text size.
    private func titleHeight(category: String) throws -> CGFloat {
        app?.terminate()
        app = XCUIApplication()
        // A `~` is the app's home in the Simulator.
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        tap("Inbox")
        tap("Errands")
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        return title.frame.height
    }

    /// A row of a list, a button or anything else, by its name.
    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        element.tap()
    }
}
