import XCTest

/// Every menu on the iPhone and the iPad is the system's own, with the app's entries and symbols: a row's, touched and
/// held, and the bars' buttons', such as ⋯ and Attach. A finger that holds a row or a button slides to an entry and
/// picks it as it lets go, on an open menu a finger slides from entry to entry, and Move To asks for the folder in a
/// sheet. On the iPhone and in the iPad's sidebar. The sliding off a row is done on a note, whose menu fits on the
/// screen: a folder's is longer on the iPhone, and the system scrolls a menu that doesn't fit under a sliding finger.
/// The app starts on fresh sample notes in its own home folder, so nothing of yours is touched. With
/// `TEST_RUNNER_MENU_SHOTS` set to a folder, it keeps pictures there.
final class SystemMenuTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", "~/Documents/UITests-\(UUID().uuidString)", "-NotebookLibraryName", "Library",
                               "-NotebookDemo", "YES", "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: A row's menu

    /// Held, the menu comes; without lifting, the finger slides down to Duplicate and lets go on it.
    func testHoldAndSlideToPick() {
        let weekend = note()
        // Where Duplicate comes, from a menu opened and closed again: the menu opens in the same place each time.
        weekend.press(forDuration: 0.8)
        let duplicate = labelled("Duplicate")
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), app.debugDescription)
        keepPicture("held")
        let target = duplicate.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).tap()
        XCTAssertTrue(duplicate.waitForNonExistence(timeout: 5), "a tap elsewhere closes the menu")

        let origin = app.coordinate(withNormalizedOffset: .zero)
        weekend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: target.midX, dy: target.midY)),
                   withVelocity: 250, thenHoldForDuration: 0.3)
        XCTAssertTrue(starting("Weekend copy").waitForExistence(timeout: 10), "letting go on Duplicate duplicates the note\n" + app.debugDescription)
        XCTAssertFalse(labelled("Duplicate").exists, "picking closes the menu")
    }

    /// On an open menu, a finger comes down on Rename, slides to Duplicate and lets go there: Duplicate is picked.
    func testSlideOverAnOpenMenu() {
        note().press(forDuration: 0.8)
        let rename = labelled("Rename")
        let duplicate = labelled("Duplicate")
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), app.debugDescription)
        rename.press(forDuration: 0.15, thenDragTo: duplicate, withVelocity: 200, thenHoldForDuration: 0.2)
        XCTAssertTrue(starting("Weekend copy").waitForExistence(timeout: 10), "letting go on Duplicate duplicates the note\n" + app.debugDescription)
        keepPicture("slid")
    }

    /// Move To can't list every folder of an iCloud Drive in the system's menu: it asks in a sheet, as Files does.
    func testMoveToAsksInASheet() {
        let personal = labelled("Personal")
        XCTAssertTrue(personal.waitForExistence(timeout: 20), app.debugDescription)
        personal.press(forDuration: 0.8)
        let moveTo = labelled("Move To")
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), app.debugDescription)
        moveTo.tap()
        XCTAssertTrue(labelled("Move “Personal”").waitForExistence(timeout: 5), "Move To opens the folder sheet\n" + app.debugDescription)
        keepPicture("move")
    }

    /// The name over a folder's files, touched and held as a row is, brings up its menu, as a tap does: a list's section
    /// header took the touch and hold first, so SwiftUI's menus there never opened (TestFlight, 2026-11-13: a Nextcloud
    /// folder Notebook can't read couldn't be removed on an iPad).
    func testHoldAFoldersName() throws {
        // Once the sample notes are read: reading them again rebuilds the header under a finger that holds it.
        XCTAssertTrue(labelled("Personal").waitForExistence(timeout: 20), app.debugDescription)
        // The name itself: on the iPad the whole header is a button too, which folds the section from its arrow.
        let library = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Library")).allElementsBoundByIndex.last,
                                    app.debugDescription)
        library.press(forDuration: 0.8)
        let remove = labelled("Remove from Notebook")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "touching and holding the name opens its menu\n" + app.debugDescription)
        XCTAssertTrue(labelled("New Note").exists, app.debugDescription)
        keepPicture("folder-name-held")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5), "a tap elsewhere closes the menu")

        library.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "a tap opens it too\n" + app.debugDescription)
        let handwritten = labelled("New Handwritten Note")
        handwritten.tap()
        XCTAssertTrue(labelled("Lined").waitForExistence(timeout: 5), "its submenus open\n" + app.debugDescription)
    }

    // MARK: The bars' menus

    /// The ⋯ of the first screen (of the sidebar on the iPad), held: the finger slides down to Settings and lets go on it,
    /// as on any button's menu of the system's.
    func testHoldTheMoreButtonAndSlideToPick() {
        let more = app.buttons[isPad ? "More for Notebook" : "More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        more.tap()
        let settings = labelled("Settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(labelled("Keep Folders on Top").exists, app.debugDescription)
        XCTAssertFalse(app.textFields["Type to find…"].exists, "the system's menu, without the glass one's field")
        keepPicture("more")
        let target = settings.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.25)).tap()
        XCTAssertTrue(labelled("Keep Folders on Top").waitForNonExistence(timeout: 5), "a tap elsewhere closes the menu")

        // Briskly, over Sort By on the way: a finger that lingers on a submenu's row opens it, as on the iPad.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: origin.withOffset(CGVector(dx: target.midX, dy: target.midY)),
                   withVelocity: 900, thenHoldForDuration: 0.3)
        keepPicture("more-slid")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "letting go on Settings opens them\n" + app.debugDescription)
    }

    /// The ⋯ of an open note: Move To in it asks for the folder in a sheet too.
    func testNoteMenuMovesInASheet() {
        note().tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        let moveTo = labelled("Move To")
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), app.debugDescription)
        keepPicture("note-more")
        moveTo.tap()
        XCTAssertTrue(starting("Move “Weekend").waitForExistence(timeout: 5), "Move To opens the folder sheet\n" + app.debugDescription)
    }

    /// Attach while writing: in the writing bar over the keyboard, which is in the keyboard's window, or in the toolbar
    /// where a keyboard is attached and the bar steps aside: its menu comes up in either.
    func testAttachWhileWriting() {
        note().tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let keyboard = app.keyboards.firstMatch
        let showsKeyboard = keyboard.waitForExistence(timeout: 5)
        // The lowest Attach on the screen: the writing bar's, over the keyboard, or else the toolbar's.
        let attaches = app.buttons.matching(identifier: "Attach").allElementsBoundByIndex.filter { $0.isHittable }
        guard let attach = attaches.max(by: { $0.frame.minY < $1.frame.minY }) else { return XCTFail("no Attach\n" + app.debugDescription) }
        if showsKeyboard {
            XCTAssertGreaterThan(attach.frame.minY, keyboard.frame.minY - 120, "the writing bar's Attach, just over the keyboard")
        }
        attach.tap()
        XCTAssertTrue(labelled("Photo Library").waitForExistence(timeout: 5), app.debugDescription)
        keepPicture("attach")
    }

    // MARK: -

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The note Weekend, in the folder Personal: opened on the iPhone, unfolded in the iPad's sidebar.
    private func note() -> XCUIElement {
        let personal = labelled("Personal")
        XCTAssertTrue(personal.waitForExistence(timeout: 20), app.debugDescription)
        personal.tap()
        let weekend = starting("Weekend")
        XCTAssertTrue(weekend.waitForExistence(timeout: 10), app.debugDescription)
        return weekend
    }

    private func labelled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A note's row, which reads its date and first line after its name.
    private func starting(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    private func keepPicture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["MENU_SHOTS"] else { return }
        let device = isPad ? "pad" : "phone"
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
