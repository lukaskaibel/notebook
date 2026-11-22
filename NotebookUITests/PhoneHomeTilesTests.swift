import XCTest

/// The tiles at the top of the iPhone's first screen: To-dos opens To-dos alone, Favorites opens Favorites alone, and
/// Back from either leads straight to the first screen. Both tiles share a row of the list, and a row with two links in
/// it once pushed both. The app starts on fresh sample notes in its own home folder, so nothing of yours is touched.
final class PhoneHomeTilesTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testToDosTileOpensToDosAlone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the tiles open screens of their own on the iPhone")
        launch()
        tile("To-dos").tap()
        XCTAssertTrue(todosList.waitForExistence(timeout: 240), app.debugDescription)
        shot("1-todos")
        // Still To-dos a moment later: no Favorites screen comes over it.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(todosList.isHittable, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Favorites"].exists, app.debugDescription)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(tile("Favorites").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(todosList.exists, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Favorites"].exists, app.debugDescription)
    }

    func testFavoritesTileOpensFavoritesAlone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the tiles open screens of their own on the iPhone")
        launch()
        tile("Favorites").tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(todosList.exists, app.debugDescription)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(tile("To-dos").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Favorites"].exists, app.debugDescription)
    }

    /// Back from To-dos by a swipe from the screen's edge, held partway: the first screen comes in under it as it is,
    /// with Recent's cards their size all the way. (Seen in a recording of the screen; `HOLD` gives the seconds held.)
    func testSwipeBackFromToDos() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the tiles open screens of their own on the iPhone")
        launch()
        // A note opened and left, for a card in Recent.
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 10), app.debugDescription)
        app.cells.firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        app.navigationBars.buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        app.navigationBars.buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        tile("To-dos").tap()
        XCTAssertTrue(todosList.waitForExistence(timeout: 240), app.debugDescription)
        Thread.sleep(forTimeInterval: 2)
        let hold = Double(ProcessInfo.processInfo.environment["HOLD"] ?? "") ?? 1.5
        let window = app.windows.firstMatch
        for end in [0.3, 0.6, 0.45] {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)), withVelocity: 150, thenHoldForDuration: hold)
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(tile("To-dos").waitForExistence(timeout: 30), app.debugDescription)
    }

    /// A to-do of the sample notes: the To-dos screen is up. (Its title is in the list, not in a navigation bar.)
    private var todosList: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Return the library books")).firstMatch
    }

    private func tile(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("iphone-tiles-\(name).png"))
    }
}
