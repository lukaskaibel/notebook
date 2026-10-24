import XCTest
@testable import NotebookKit

/// A writing bar you changed gets the tools that come with later versions, where they stand in the standard bar, and
/// the ones you took out stay out.
final class WritingBarTests: XCTestCase {
    private let standard = ["format", "checklist", "attach", "drawing", "link", "undo", "redo", "bold", "camera", "scanner"]

    func testANewToolJoinsAChangedBarWhereItStandsInTheStandardOne() {
        // Changed before drawings came: in another order, without the camera.
        let saved = ["checklist", "format", "attach", "link", "bold", "scanner"]
        let bar = NotebookSettings.writingBar(saved, known: NotebookSettings.firstWritingTools, standard: standard)
        XCTAssertEqual(bar, ["checklist", "format", "attach", "drawing", "link", "bold", "scanner"])
    }

    func testToolsTakenOutStayOut() {
        let saved = ["format", "checklist", "link"]
        let known = NotebookSettings.firstWritingTools + ["drawing", "reminder"]
        XCTAssertEqual(NotebookSettings.writingBar(saved, known: known, standard: standard), saved)
    }

    func testANewToolWithNoneBeforeItInTheBarComesFirst() {
        let bar = NotebookSettings.writingBar(["link"], known: ["format", "link"], standard: ["drawing", "format", "link"])
        XCTAssertEqual(bar, ["drawing", "link"])
    }
}
