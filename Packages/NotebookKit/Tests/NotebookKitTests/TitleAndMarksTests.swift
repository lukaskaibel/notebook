import AppKit
import XCTest
@testable import NotebookKit

/// Going between the title and the text with the keys, the marks of styles with a keyboard and on a touch keyboard,
/// and marks folding in and out as the caret comes and goes.
@MainActor
final class TitleAndMarksTests: XCTestCase {
    private func inTitle(_ h: EditorHarness, caret: Int? = nil) throws -> NSTextView {
        h.editor.focusTitle(caretAtEnd: caret == nil)
        h.settle(0)
        let editor = try XCTUnwrap(h.textView.titleField.currentEditor() as? NSTextView)
        if let caret { editor.setSelectedRange(NSRange(location: caret, length: 0)) }
        return editor
    }

    // MARK: - The title

    func testTabDownAndRightAtTheEndGoFromTheTitleIntoTheText() throws {
        for selector in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:))] {
            let h = EditorHarness("Body")
            let title = try inTitle(h)
            title.doCommand(by: selector)
            h.settle(0)
            XCTAssertFalse(h.editor.isEditingTitle, "\(selector) leaves the title")
            XCTAssertTrue(h.editor.isFocused)
            XCTAssertEqual(h.selection, NSRange(location: 0, length: 0), "at the start of the text")
        }
    }

    func testRightInsideTheTitleMovesWithinIt() throws {
        let h = EditorHarness("Body")
        let title = try inTitle(h, caret: 2)
        title.doCommand(by: #selector(NSResponder.moveRight(_:)))
        h.settle(0)
        XCTAssertTrue(h.editor.isEditingTitle)
        XCTAssertEqual(title.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testUpLeftAndDeleteAtTheStartOfTheTextGoToTheEndOfTheTitle() throws {
        for selector in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.deleteBackward(_:))] {
            let h = EditorHarness("Body")
            h.caret(0)
            h.command(selector)
            XCTAssertTrue(h.editor.isEditingTitle, "\(selector) goes into the title")
            let title = try XCTUnwrap(h.textView.titleField.currentEditor() as? NSTextView)
            XCTAssertEqual(title.selectedRange(), NSRange(location: ("Kyoto trip" as NSString).length, length: 0), "to its end, nothing selected")
            XCTAssertEqual(h.text, "Body", "nothing is deleted")
        }
    }

    func testDeleteHeldDownStopsAtTheStartOfTheText() {
        let h = EditorHarness("Body")
        h.caret(1)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertFalse(h.editor.isEditingTitle, "a Delete right after one that reached the start, as when it is held, stays")
        XCTAssertEqual(h.text, "ody")
        h.settle(0.6)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(h.editor.isEditingTitle, "pressed again, it goes into the title")
        XCTAssertEqual(h.textView.titleField.stringValue, "Kyoto trip")
    }

    func testLeftFurtherInTheTextStaysInIt() {
        let h = EditorHarness("Body")
        h.caret(2)
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertFalse(h.editor.isEditingTitle)
        XCTAssertEqual(h.selection.location, 1)
    }

    // MARK: - Marks with a keyboard and on a touch keyboard

    func testWithAKeyboardTheStarsOfBoldShowNextToTheCaret() {
        let h = EditorHarness("Some **bold** text")
        h.caret(h.range(of: "bold").location + 2)
        XCTAssertEqual(h.visibleText(in: NSRange(location: 0, length: (h.text as NSString).length)), "Some **bold** text")
    }

    func testOnATouchKeyboardTheStarsStayHidden() {
        let h = EditorHarness("Some **bold** text")
        h.editor.marksShowOverride = false
        h.caret(h.range(of: "bold").location + 2)
        XCTAssertEqual(h.visibleText(in: NSRange(location: 0, length: (h.text as NSString).length)), "Some bold text")
    }

    func testOnATouchKeyboardATapAtTheEndOfBoldTypesOnInBold() {
        let h = EditorHarness("Some **bold** text")
        h.editor.marksShowOverride = false
        h.caret(h.range(of: "**bold**").upperBound)
        XCTAssertEqual(h.selection.location, h.range(of: "bold").upperBound, "in front of the closing stars, which don't show")
        h.type("er")
        XCTAssertEqual(h.text, "Some **bolder** text")
    }

    func testOnATouchKeyboardATapAtTheStartOfBoldTypesOnPlainly() {
        let h = EditorHarness("Some **bold** text")
        h.editor.marksShowOverride = false
        h.caret(h.range(of: "bold").location)
        XCTAssertEqual(h.selection.location, h.range(of: "**bold").location, "in front of the opening stars")
        h.caret(0)
        h.caret(h.range(of: "**bold").location + 1)
        XCTAssertEqual(h.selection.location, h.range(of: "**bold").location, "never between them")
    }

    func testOnATouchKeyboardDeleteTakesTheLetterYouSeeAndKeepsTheStyle() {
        let h = EditorHarness("Some **bold** text")
        // Right behind the stars, where leaving the bold puts the caret.
        h.caret(h.range(of: "**bold**").upperBound)
        h.editor.marksShowOverride = false
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Some **bol** text")
        XCTAssertEqual(h.selection.location, h.range(of: "bol").upperBound, "in the bold")
        h.type("t")
        XCTAssertEqual(h.text, "Some **bolt** text", "what you type next is bold too")
    }

    func testOnATouchKeyboardDeletingTheLastLetterTakesTheStyle() {
        let h = EditorHarness("a **b** c")
        h.caret(h.range(of: "**b**").upperBound)
        h.editor.marksShowOverride = false
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "a  c")
        XCTAssertEqual(h.selection, NSRange(location: 2, length: 0))
    }

    func testWithAKeyboardDeleteStillTakesStarsInPairs() {
        let h = EditorHarness("Some **bold** text")
        h.caret(h.range(of: "**bold**").upperBound)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Some *bold* text")
    }

    // MARK: - Folding

    func testMarksFoldInAndOutInsteadOfPopping() throws {
        let h = EditorHarness("Some **bold** text and more")
        let animator = h.editor.revealAnimator
        animator.isForced = true
        defer { animator.isForced = nil }
        let stars = h.range(of: "**")
        let after = h.range(of: "bold").location

        h.caret(after + 2)
        XCTAssertTrue(h.isVisible(stars.location), "the stars are there at once")
        let start = try XCTUnwrap(h.editor.storage.attribute(.expansion, at: stars.location, effectiveRange: nil) as? CGFloat)
        XCTAssertLessThan(exp(start), 0.05, "but squeezed to nothing")
        animator.advance(to: 0.5)
        let half = try XCTUnwrap(h.editor.storage.attribute(.expansion, at: stars.location, effectiveRange: nil) as? CGFloat)
        XCTAssertGreaterThan(exp(half), 0.5, "half way they take most of their room")
        XCTAssertLessThan(exp(half), 1)
        animator.advance(to: 1)
        XCTAssertNil(h.editor.storage.attribute(.expansion, at: stars.location, effectiveRange: nil), "then they are plain text")
        XCTAssertNil(h.editor.storage.attribute(.notebookFade, at: stars.location, effectiveRange: nil))

        h.caret(h.range(of: "more").location)
        h.settle(0)
        XCTAssertTrue(h.isVisible(stars.location), "leaving, they stay while they fold away")
        XCTAssertTrue(h.editor.isRevealed(stars.location))
        animator.advance(to: 1)
        h.settle(0)
        XCTAssertFalse(h.isVisible(stars.location), "and are hidden at the end")
        XCTAssertNil(h.editor.storage.attribute(.expansion, at: stars.location, effectiveRange: nil))
    }

    func testTypingWhileMarksFoldKeepsThemFolding() {
        let h = EditorHarness("Some **bold**")
        let animator = h.editor.revealAnimator
        animator.isForced = true
        defer { animator.isForced = nil }
        h.caret((h.text as NSString).length)
        animator.complete()
        h.type(" and")
        XCTAssertTrue(animator.isRunning, "a space after the stars folds them away")
        XCTAssertNotNil(h.editor.storage.attribute(.expansion, at: h.range(of: "**").location, effectiveRange: nil), "still folding after more letters")
        animator.complete()
        h.settle(0)
        XCTAssertEqual(h.visibleText(in: NSRange(location: 0, length: (h.text as NSString).length)), "Some bold and")
    }
}
