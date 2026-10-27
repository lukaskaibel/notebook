import XCTest
@testable import NotebookKit

/// Whether you put the caret somewhere decides where Checklist, Attach and Aa in the toolbar of iPhone and iPad act:
/// there, or at the end of a note you haven't put it in, as in Notes. Back brings that back with the place.
@MainActor
final class CaretPlacedTests: XCTestCase {
    func testANoteOpensWithTheCaretNotPlaced() {
        let h = EditorHarness("First line\nLast line")
        XCTAssertFalse(h.editor.caretWasPlaced)
        h.caret(5)
        XCTAssertTrue(h.editor.caretWasPlaced)
        h.editor.load(text: "Another note", folder: h.folder, title: "Other", meta: "")
        XCTAssertFalse(h.editor.caretWasPlaced, "a note opened afresh")
    }

    func testBackBringsBackWhetherTheCaretWasPlaced() {
        let h = EditorHarness("First line\nLast line")
        h.window.makeFirstResponder(nil)
        let untouched = h.editor.place
        h.caret(5)
        h.caret(0)
        let putAtStart = h.editor.place
        XCTAssertEqual(putAtStart.selection, untouched.selection, "both at the very start")

        h.editor.load(text: h.text, folder: h.folder, title: "Kyoto trip", meta: "")
        h.editor.restore(putAtStart)
        XCTAssertTrue(h.editor.caretWasPlaced, "put there, even at the start")
        h.editor.load(text: h.text, folder: h.folder, title: "Kyoto trip", meta: "")
        h.editor.restore(untouched)
        XCTAssertFalse(h.editor.caretWasPlaced, "left where the note opened, though Back puts the caret there")
    }
}
