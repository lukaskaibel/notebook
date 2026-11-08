import AppKit
import XCTest
@testable import NotebookKit

/// Writing at the bottom of the window: the line being written stays in view as you type, press Return, go on with a
/// list or paste, without scrolling by hand. On iPhone and iPad, `NotebookUITests/TypingScrollTests` checks the same
/// above the keyboard.
@MainActor
final class TypingScrollTests: XCTestCase {
    private let lines = (1...60).map { "Line \($0) of the note" }.joined(separator: "\n")

    /// Return in the middle of a note, on the last line that shows: the lines below move down, and the note with them.
    func testReturnInTheMiddleKeepsTheLineInView() {
        let h = atTheBottom(of: lines)
        for word in ["one", "two", "three", "four", "five", "six"] {
            h.type("\n" + word)
            assertCaretShows(in: h, "after Return and “\(word)”")
        }
    }

    /// A list goes on with the next bullet, which the editor puts in rather than the text view.
    func testAListGoesOnInView() {
        let h = atTheBottom(of: lines)
        h.type("\n- milk")
        assertCaretShows(in: h, "after the first item")
        for word in ["eggs", "bread", "butter", "tea", "rice"] {
            h.type("\n" + word)
            assertCaretShows(in: h, "after Return and “\(word)”")
        }
        XCTAssertTrue(h.text.contains("- milk\n- eggs\n- bread\n- butter\n- tea\n- rice"), h.text)
    }

    /// A bullet point long enough to run on over several lines, then the next bullet.
    func testALongBulletRunsOnInView() {
        let h = atTheBottom(of: lines)
        h.type("\n- Packing")
        assertCaretShows(in: h, "after the first bullet")
        for item in 1...2 {
            for words in [" for the weekend in the mountains", " with boots, a warm jacket and", " gloves, a thermos for tea, the map", " and the charger for the phone, which", " ran out last time halfway up"] {
                h.type(words)
                assertCaretShows(in: h, "after “\(words)” in bullet \(item)")
            }
            h.type("\nNext")
            assertCaretShows(in: h, "after Return for bullet \(item + 1)")
        }
        XCTAssertTrue(h.text.contains("\n- Next"), "a new bullet")
    }

    /// Return on empty lines, again and again.
    func testEmptyLinesKeepTheCaretInView() {
        let h = atTheBottom(of: lines)
        for index in 1...6 {
            h.type("\n")
            assertCaretShows(in: h, "after Return \(index)")
        }
    }

    /// Lines pasted where you write: the caret after them shows.
    func testPastedLinesShowWhereTheyEnd() {
        let h = atTheBottom(of: lines)
        h.editor.pasteText((1...8).map { "Pasted line \($0)" }.joined(separator: "\n"), at: h.selection)
        h.settle()
        assertCaretShows(in: h, "after pasting eight lines")
    }

    /// At the end of the note, which grows as it is written: items of a list, and lines pasted after them.
    func testTheEndOfTheNoteFollowsTheCaret() {
        let h = EditorHarness(lines, height: 420)
        h.editor.scrollView.contentInsets.top = 52
        h.settle()
        h.caret(h.text.utf16.count)
        h.textView.scrollRangeToVisible(h.selection)
        h.settle()
        h.type("\n- milk")
        for word in ["eggs", "bread", "butter"] {
            h.type("\n" + word)
            assertCaretShows(in: h, "after Return and “\(word)”")
        }
        h.editor.pasteText("\n" + (1...8).map { "Pasted line \($0)" }.joined(separator: "\n"), at: h.selection)
        assertCaretShows(in: h, "after pasting eight lines at the end")
    }

    /// Typing where the note shows doesn't scroll it: only a caret that would leave the view brings the note along.
    func testTypingInViewLeavesTheNoteWhereItIs() {
        let h = atTheBottom(of: lines)
        let line = h.range(of: "Line 3 of the note")
        h.setScrollTop(h.editor.yPosition(of: line.location) - 40 - h.editor.topInset)
        h.caret(NSMaxRange(line))
        let top = h.editor.scrollTop
        h.type("\nmore")
        XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the note stayed where it was")
    }

    // MARK: -

    /// A note in a window shorter than it, the caret at the end of the last line that shows in full.
    private func atTheBottom(of text: String) -> EditorHarness {
        let h = EditorHarness(text, height: 420)
        h.editor.scrollView.contentInsets.top = 52
        h.settle()
        let visible = h.editor.visibleRect
        var index = 0
        for line in 1...60 {
            let range = h.range(of: "Line \(line) of the note")
            let rect = h.lineRect(of: range.location)
            if rect.maxY > visible.maxY { break }
            index = NSMaxRange(range)
        }
        h.caret(index)
        assertCaretShows(in: h, "at first")
        XCTAssertGreaterThan(h.lineRect(of: index).maxY, visible.maxY - 60, "the caret is on the last line that shows")
        return h
    }

    private func assertCaretShows(in h: EditorHarness, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        h.settle(0.4)
        let visible = h.editor.visibleRect
        let caret = h.lineRect(of: h.selection.location)
        XCTAssertLessThanOrEqual(caret.maxY, visible.maxY, "\(when): the caret's line is below the window", file: file, line: line)
        XCTAssertGreaterThanOrEqual(caret.minY, visible.minY + h.editor.topInset, "\(when): the caret's line is under the toolbar", file: file, line: line)
    }
}

private extension EditorHarness {
    /// The line a character is on, in the text view's coordinates; the empty line after a last line break too.
    func lineRect(of index: Int) -> NSRect {
        let layout = editor.layoutManager
        let origin = textView.textContainerOrigin
        if index >= editor.storage.length, layout.extraLineFragmentTextContainer != nil {
            return layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
        }
        let glyph = layout.glyphIndexForCharacter(at: min(index, editor.storage.length - 1))
        return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
    }

    func setScrollTop(_ y: CGFloat) {
        editor.setScrollTop(y)
        settle()
    }
}
