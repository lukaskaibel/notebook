import AppKit
import XCTest
@testable import NotebookKit

/// Typing must stay instant in long notes, and nothing on screen may jump when things change out of view.
@MainActor
final class EditorSmoothnessTests: XCTestCase {
    private func longNote(sections: Int) -> String {
        var text = ""
        for index in 0..<sections {
            text += """
            ## Section \(index)
            Some **bold** text, *italics*, a [[Budget]] link and `code` in paragraph \(index), long enough to wrap onto a second line in the editor.
            - [ ] A task
            - [x] A done task
              - nested item with ~~strike~~
            > A quote

            | A | B |
            | --- | --- |
            | \(index) | two |

            ```swift
            let value = \(index) // comment
            ```

            """
        }
        return text
    }

    /// A keystroke fits in one frame, however long the note. Timed in the main thread's processor time, the work a
    /// keystroke takes: other test runs and builds on the Mac add the time it waits for a core, which says nothing
    /// about the editor. On a Mac with cores to spare, the time that passes shows a keystroke that waits for something.
    func testTypingInLongNoteIsFast() throws {
        let long = EditorHarness(longNote(sections: 150))
        XCTAssertGreaterThan(long.text.count, 40_000)
        long.caret(long.range(of: "paragraph 75").location)
        let short = EditorHarness(longNote(sections: 3))
        short.caret(short.range(of: "paragraph 1").location)
        // In a short note a keystroke takes a sixth to a tenth of what it takes in the long one.
        try assertFast("a keystroke in a long note", under: 0.016, comparedWith: ("in a short note", 15, { self.keystroke(in: short) })) {
            keystroke(in: long)
        }
    }

    /// What a keystroke at the caret takes on average, laid out.
    private func keystroke(in h: EditorHarness) -> Timing.Sample {
        let caret = h.selection.location
        var times: [Timing.Sample] = []
        for character in "quick brown fox " {
            times.append(Timing.measure {
                h.textView.insertText(String(character), replacementRange: h.textView.selectedRange())
                h.editor.layoutManager.ensureLayout(forCharacterRange: NSRange(location: caret, length: min(200, h.editor.storage.length - caret)))
            })
        }
        let average = times.reduce(Timing.Sample(processor: 0, wall: 0), +) / times.count
        print(String(format: "typing in a %d character note: average %.1f ms (%.1f ms passed), worst %.1f ms", h.text.count,
                     average.processor * 1000, average.wall * 1000, (times.map(\.processor).max() ?? 0) * 1000))
        return average
    }

    func testBlockClosingAboveViewDoesNotMoveWhatYouSee() {
        let h = EditorHarness(longNote(sections: 12), height: 600)
        // Open the first table for editing: it shows its Markdown, taller than the rendered table.
        let table = h.range(of: "| A | B |")
        h.caret(table.location + 2)
        XCTAssertNotNil(h.editor.activeBlock)
        // Scroll far below it and click there: the table closes above the visible part.
        let target = h.range(of: "paragraph 6")
        let clip = h.editor.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: h.editor.yPosition(of: target.location) - 200))
        h.editor.scrollView.reflectScrolledClipView(clip)
        let before = h.editor.yPosition(of: target.location) - clip.bounds.minY
        h.click(at: h.point(of: target.location))
        XCTAssertNil(h.editor.activeBlock, "the table closed")
        let after = h.editor.yPosition(of: target.location) - clip.bounds.minY
        XCTAssertEqual(before, after, accuracy: 1, "the line you clicked stays where it was on screen")
    }

    func testDeadKeysComposeCharacters() {
        let h = EditorHarness("Cafe ")
        h.caret(5)
        // ´ then e, as on a German keyboard: the accent waits as marked text, then becomes é.
        h.textView.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertTrue(h.textView.hasMarkedText())
        h.textView.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertFalse(h.textView.hasMarkedText())
        XCTAssertEqual(h.text, "Cafe é")
    }

    func testMarkedTextInsideBoldKeepsStyle() {
        let h = EditorHarness("a **bold** b")
        h.caret(5)
        h.textView.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertText("ö", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertEqual(h.text, "a **böold** b")
        let font = h.editor.storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(EditorStyle.weight(of: font ?? .systemFont(ofSize: 1)), 0.2, "the new letter is bold like the rest")
    }
}
