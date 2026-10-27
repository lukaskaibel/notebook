import XCTest

/// What VoiceOver reads in the iPad's sidebar (#217): a folder says whether it is open, nothing it can reach is without
/// a name, and the sidebar's ⋯ isn't called More like the note's next to it. The app starts on fresh sample notes in
/// its own home folder, so nothing of yours is touched.
final class PadSidebarAccessibilityTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testFoldersSayWhetherTheyAreOpen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar is the iPad's")
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let personal = button("Personal")
        XCTAssertTrue(personal.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(personal.value as? String, "collapsed")
        personal.tap()
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "expanded"), object: personal)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 10), .completed, app.debugDescription)
        // The folder's arrow is part of its row, so nothing VoiceOver reaches goes unnamed.
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])

        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Weekend")).firstMatch.tap()
        XCTAssertTrue(app.textViews["Note"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(button("More for Notebook").exists, app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "More")).count, 1, "only the note's ⋯ is More")
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
