import AppKit
import CoreText
import XCTest
@testable import NotebookKit

/// The typing rules of `MarkdownEditing` in the note with real keystrokes: they reach the text view after the editor's
/// own rules, make one undoable edit each, and the text eases into its new look.
@MainActor
final class TypingRulesTests: XCTestCase {
    private func weight(_ h: EditorHarness, at index: Int) -> Double {
        let font = h.editor.storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: 0x7767_6874)]?.doubleValue ?? 400
    }

    private func settle(_ h: EditorHarness, until condition: () -> Bool, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { h.settle(0.01) }
    }

    func testADashStartsAListThatReturnContinuesAndEnds() {
        let h = EditorHarness("")
        h.type("-one\ntwo\n\nafter")
        XCTAssertEqual(h.text, "- one\n- two\nafter")
    }

    func testADashAndBracketsMakeACheckbox() {
        let h = EditorHarness("")
        h.type("-[]todo")
        XCTAssertEqual(h.text, "- [ ] todo")
    }

    func testTypingBoldWithItsStarsLeavesTheCaretAfterIt() {
        let h = EditorHarness("")
        h.type("Buy **")
        XCTAssertEqual(h.text, "Buy ****", "the closing pair comes along")
        XCTAssertEqual(h.selection.location, 6, "with the caret between")
        h.type("milk** today")
        XCTAssertEqual(h.text, "Buy **milk** today", "the closing stars typed are stepped over")
    }

    func testBoldStartedAtTheStartOfALineIsNoRuleAndNothingMoves() {
        let h = EditorHarness("Intro\n")
        h.caret(6)
        h.type("**")
        XCTAssertEqual(h.text, "Intro\n****")
        XCTAssertEqual(h.editor.document.lines[1].kind, .paragraph, "the empty pair is not a rule while typing")
        let y = h.editor.yPosition(of: 6)
        h.type("b")
        XCTAssertEqual(h.editor.yPosition(of: 6), y, "the line stays where it is when its text comes")
        XCTAssertEqual(MarkdownParser.parse("Intro\n****").lines[1].kind, .thematicBreak, "read, four stars are still a rule")
    }

    func testStarsWithSpacesStayStars() {
        let h = EditorHarness("")
        h.type("2 ** 3")
        XCTAssertEqual(h.text, "2 ** 3")
    }

    func testHashesTypedInFrontOfALineMakeItAHeading() {
        let h = EditorHarness("Groceries")
        h.caret(0)
        h.type("##")
        XCTAssertEqual(h.text, "## Groceries")
        XCTAssertEqual(h.editor.headingMarkLevel?.level, 2)
        h.type(" ")
        XCTAssertEqual(h.text, "## Groceries", "a space there steps over the heading's own")
        XCTAssertEqual(h.selection.location, 3)
    }

    func testThreeDashesStillMakeARule() {
        let h = EditorHarness("")
        h.type("---")
        XCTAssertEqual(h.text, "---")
    }

    func testBoldTurnsOnAndOff() {
        let h = EditorHarness("")
        h.type("a ")
        h.textView.toggleBoldface(nil)
        h.type("bold")
        XCTAssertEqual(h.text, "a **bold**")
        h.textView.toggleBoldface(nil)
        h.type(" b")
        XCTAssertEqual(h.text, "a **bold** b")
    }

    func testBoldAtACaretInAWordMakesTheWordBold() {
        let h = EditorHarness("some words")
        h.caret(7)
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "some **words**")
        XCTAssertEqual(h.selection, NSRange(location: 9, length: 0), "the caret stays with its letter")
    }

    func testBoldInBoldTakesItOffAndASecondPressPutsItBack() {
        let h = EditorHarness("a **two words** b")
        h.caret(h.range(of: "words").location + 2)
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "a two words b")
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "a **two words** b")
    }

    func testBoldThickensAndAlwaysGetsThere() {
        let h = EditorHarness("some words")
        h.caret(7)
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "some **words**")
        // It starts from how the text looked...
        XCTAssertEqual(weight(h, at: 8), 400)
        // ...and ends bold, even where the screen doesn't draw (as here), when no frame comes.
        settle(h, until: { weight(h, at: 8) >= 590 }, timeout: TestRun.patience)
        XCTAssertEqual(weight(h, at: 8), 590)
    }

    func testDeletingStarsTakesThemInPairsAndTypingBringsThemBack() {
        let h = EditorHarness("a **bold** b")
        h.caret(10)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "a *bold* b", "bold becomes italics")
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "a bold b", "and then plain")
        h.type("*")
        XCTAssertEqual(h.text, "a *bold* b", "a star brings italics back")
        h.type("*")
        XCTAssertEqual(h.text, "a **bold** b", "and another bold")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "a *bold* b", "each step is one undo")
    }

    func testDeletingAfterTypingSomethingElseForgetsTheMarks() {
        let h = EditorHarness("*bold*")
        h.caret(6)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        h.type("x*")
        XCTAssertEqual(h.text, "boldx*")
    }

    func testDeletingASelectionWithOneMarkTakesTheOther() {
        let h = EditorHarness("a **bold** b")
        h.select(NSRange(location: 0, length: 4))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "bold b")
    }

    func testReturnAtTheEndOfBoldLeavesIt() {
        let h = EditorHarness("**bold**")
        h.caret(6)
        h.type("\nplain")
        XCTAssertEqual(h.text, "**bold**\nplain")
    }

    func testReturnInAnOrderedListNumbersTheRest() {
        let h = EditorHarness("1. one\n2. two")
        h.caret(6)
        h.type("\nnew")
        XCTAssertEqual(h.text, "1. one\n2. new\n3. two")
    }

    func testEachRuleIsOneUndoStep() {
        let h = EditorHarness("")
        h.type("word")
        // The undo manager closes a group at the end of each turn of the run loop, as after each key press.
        h.settle(0.01)
        h.caret(2)
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "**word**")
        h.settle(0.01)
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "word")
    }

    func testAnEmojiKeepsItsFontInStyledText() {
        let h = EditorHarness("")
        h.type("😀 **x**")
        let font = h.editor.storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontName.contains("Emoji"), font.fontName)
    }

    func testASpaceTypedAtTheEndOfBoldKeepsItBoldWhileTyping() {
        let h = EditorHarness("a **bold**")
        h.caret(8)
        h.type(" ")
        XCTAssertEqual(h.text, "a **bold **")
        XCTAssertTrue(h.editor.document.lines[0].spans.contains { $0.kind == .strong }, "bold while typing")
        h.window.makeFirstResponder(nil)
        h.settle()
        XCTAssertFalse(h.editor.document.lines[0].spans.contains { $0.kind == .strong }, "read, it is what other apps show")
    }

    func testRulesLeaveCodeAlone() {
        let h = EditorHarness("```\nx\n```")
        h.caret(5)
        h.type("\n-")
        XCTAssertEqual(h.text, "```\nx\n-\n```")
    }

    func testBoldInATableStillWrapsTheWordsOfItsCell() {
        let h = EditorHarness("| a | b |\n| - | - |\n| one | two |")
        h.select(h.range(of: "one"))
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "| a | b |\n| - | - |\n| **one** | two |")
    }
}
