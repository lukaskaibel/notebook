import PDFKit
import PencilKit
import XCTest

/// All Pages on the iPad, with real touches: a page dragged to another place, Duplicate and Delete from its menu, and
/// Undo, each ending up in the PDF in that order. The sample lecture has five pages of four papers, told apart in the
/// file by the marker of their paper. The app writes its sample notes into the test's own folder, which it can reach
/// in the Simulator, so the test reads the PDF it saves.
final class PageOverviewUITests: XCTestCase {
    var app: XCUIApplication!
    private var library: URL!
    private var lecture: URL { library.appendingPathComponent("University/Linear algebra/Lecture 4.pdf") }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        library = FileManager.default.temporaryDirectory.appendingPathComponent("PageOverview-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: library)
        super.tearDown()
    }

    func testPagesAreMovedDuplicatedAndDeletedWithUndo() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar and the grid in the toolbar are the iPad's")
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", library.path, "-NotebookLibraryName", "Library", "-NotebookDemo", "YES",
                               "-NotebookTips", "hide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap("University")
        tap("Linear algebra")
        tap("Lecture 4.pdf", prefix: "Lecture 4")
        tap("Draw")
        XCTAssertEqual(papers(), ["cornell", "squared", "lined", "dotted", "cornell"])
        tap("All Pages")
        let first = page(1)
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(page(5).waitForExistence(timeout: 10), app.debugDescription)

        // The first page dragged onto the third: it goes there, the two after it move up.
        first.press(forDuration: 1.2, thenDragTo: page(3), withVelocity: .slow, thenHoldForDuration: 0.8)
        waitForFile(["squared", "lined", "cornell", "dotted", "cornell"])

        // Undo puts it back; Redo moves it again.
        tap("Undo")
        waitForFile(["cornell", "squared", "lined", "dotted", "cornell"])
        tap("Redo")
        waitForFile(["squared", "lined", "cornell", "dotted", "cornell"])

        // Duplicate, from the page's menu: a copy right after it, with what is on it.
        page(4).press(forDuration: 1.2)
        tap("Duplicate")
        XCTAssertTrue(page(6).waitForExistence(timeout: 10), app.debugDescription)
        waitForFile(["squared", "lined", "cornell", "dotted", "dotted", "cornell"])
        let pdf = try XCTUnwrap(PDFDocument(url: lecture))
        XCTAssertEqual(strokes(on: pdf.page(at: 3)!), strokes(on: pdf.page(at: 4)!))
        XCTAssertGreaterThan(strokes(on: pdf.page(at: 4)!), 0)

        // Delete, from the page's menu; Undo brings it back.
        page(1).press(forDuration: 1.2)
        tap("Delete")
        waitForFile(["lined", "cornell", "dotted", "dotted", "cornell"])
        tap("Undo")
        waitForFile(["squared", "lined", "cornell", "dotted", "dotted", "cornell"])

        // A page tapped is the one shown when the overview goes.
        page(5).tap()
        XCTAssertTrue(app.buttons["All Pages"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(page(5).exists)
    }

    // MARK: - Helpers

    private func page(_ number: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Page \(number) of ")).firstMatch
    }

    /// The papers of the PDF's pages as saved, from their markers.
    private func papers() -> [String] {
        guard let document = PDFDocument(url: lecture) else { return [] }
        return (0..<document.pageCount).map { index in
            let page = document.page(at: index)
            let marker = page?.annotations.lazy.compactMap { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookPaper")) as? String }.first
            return marker ?? "-"
        }
    }

    /// The strokes on a page, as Notebook keeps them.
    private func strokes(on page: PDFPage) -> Int {
        page.annotations.compactMap { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookDrawing")) as? String }
            .compactMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters).flatMap { try? PKDrawing(data: $0) } }
            .reduce(0) { $0 + $1.strokes.count }
    }

    /// Saves come a moment after a change.
    private func waitForFile(_ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.papers() == expected }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed, "the file has \(papers())", file: file, line: line)
    }

    private func tap(_ label: String, prefix: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = prefix.map { NSPredicate(format: "label BEGINSWITH %@", $0) } ?? NSPredicate(format: "label == %@", label)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), app.debugDescription, file: file, line: line)
        element.tap()
    }
}
