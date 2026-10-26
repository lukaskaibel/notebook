import AppKit
import XCTest
@testable import NotebookKit

/// A to-do's date and place in the editor: pills in place of their Markdown, one thing for the caret and for Delete,
/// clicked to change them, and written back as an edit Undo takes back.
@MainActor
final class TodoEditorTests: XCTestCase {
    private let pharmacy = TodoPlace(name: "Pharmacy", latitude: 52.52, longitude: 13.405)

    func testMarksShowAsPills() throws {
        let line = "- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00 " + pharmacy.markdown
        let h = EditorHarness(line + "\nNext")
        let due = h.range(of: "⏰ 2026-10-24 14:00")
        let place = h.range(of: pharmacy.markdown)
        XCTAssertEqual(h.visibleText(in: NSRange(location: 0, length: (line as NSString).length)), "Call Dr. Weber", "the marks and the spaces before them are drawn as pills")
        guard case .todoPill(let pill)? = h.editor.layoutManager.object(at: due.location)?.kind else { return XCTFail("no pill for the time") }
        XCTAssertEqual(pill.symbol, "bell.fill")
        XCTAssertTrue(pill.label.hasSuffix(TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0).date().formatted(date: .omitted, time: .shortened)))
        guard case .todoPill(let placePill)? = h.editor.layoutManager.object(at: place.location)?.kind else { return XCTFail("no pill for the place") }
        XCTAssertEqual(placePill.label, "Pharmacy")
        XCTAssertNotNil(h.editor.layoutManager.rect(forObjectAt: place.location, origin: h.textView.textContainerOrigin))
        h.snapshot("todo-pills")

        // A click on a pill asks for the to-do's Remind Me.
        h.click(at: h.point(of: place.location))
        XCTAssertEqual(h.todoReminders, [0])
        XCTAssertEqual(h.text, line + "\nNext", "the click changed nothing")
    }

    func testTheCaretStepsOverAPillAndDeleteTakesItWhole() {
        let h = EditorHarness("- [ ] Pay rent 📅 2026-11-01")
        let mark = h.range(of: "📅 2026-11-01")
        h.caret(mark.location + 3)
        XCTAssertTrue([mark.location, mark.upperBound].contains(h.selection.location), "the caret never rests inside a pill")
        h.caret(mark.upperBound)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "- [ ] Pay rent ", "Delete after a pill takes all of it")
    }

    func testSettingAndRemovingAReminderIsOneUndo() throws {
        let h = EditorHarness("- [ ] Call Dr. Weber\n- [ ] Second")
        h.caret(h.range(of: "Weber").location)
        let due = TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0)
        XCTAssertTrue(h.editor.setTodoSchedule(line: 0, due: due, place: nil))
        XCTAssertEqual(h.text, "- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00\n- [ ] Second")
        XCTAssertEqual(h.selection.location, h.range(of: "Weber").location, "the caret stays in the words")
        XCTAssertEqual(h.editor.todo(onLine: 0)?.due, due)

        h.settle(0.05)
        XCTAssertTrue(h.editor.setTodoSchedule(line: 0, due: due.at(hour: nil, minute: nil), place: pharmacy))
        XCTAssertEqual(h.text, "- [ ] Call Dr. Weber 📅 2026-10-24 " + pharmacy.markdown + "\n- [ ] Second")
        XCTAssertFalse(h.editor.setTodoSchedule(line: 0, due: due.at(hour: nil, minute: nil), place: pharmacy), "nothing to change")
        // Each change its own event, as when you choose them, so Undo takes back one at a time.
        h.settle(0.05)

        XCTAssertTrue(h.editor.setTodoSchedule(line: 0, due: nil, place: nil))
        XCTAssertEqual(h.text, "- [ ] Call Dr. Weber\n- [ ] Second")
        h.settle(0.05)
        h.textView.undoManager?.undo()
        h.settle(0)
        XCTAssertEqual(h.text, "- [ ] Call Dr. Weber 📅 2026-10-24 " + pharmacy.markdown + "\n- [ ] Second")
        XCTAssertFalse(h.editor.setTodoSchedule(line: 1 + 5, due: due, place: nil), "no such line")
    }

    func testReturnAfterAPillMakesTheNextTodo() {
        let h = EditorHarness("- [ ] Pay rent 📅 2026-11-01")
        h.caret((h.text as NSString).length)
        h.type("\nCall mum")
        XCTAssertEqual(h.text, "- [ ] Pay rent 📅 2026-11-01\n- [ ] Call mum")
    }

    func testReturnAtTheEndOfTheWordsLeavesThePillWithThem() {
        let h = EditorHarness("- [ ] Pay rent 📅 2026-11-01")
        h.caret(h.range(of: "rent").upperBound)
        h.type("\nCall mum")
        XCTAssertEqual(h.text, "- [ ] Pay rent 📅 2026-11-01\n- [ ] Call mum")
        // Typing there goes into the words.
        let other = EditorHarness("- [ ] Pay rent 📅 2026-11-01")
        other.caret(other.range(of: "rent").upperBound)
        other.type(" today")
        XCTAssertEqual(other.text, "- [ ] Pay rent today 📅 2026-11-01")
    }

    func testDoneTodosShowGreyPillsAndOverdueOnesRed() {
        let h = EditorHarness("- [x] Old ⏰ 2020-01-01 10:00\n- [ ] Late ⏰ 2020-01-01 10:00\n- [ ] Soon ⏰ 2099-01-01 10:00")
        func tone(_ mark: String, after word: String) -> TodoPill.Tone? {
            let start = h.range(of: word).upperBound
            let range = (h.text as NSString).range(of: mark, range: NSRange(location: start, length: (h.text as NSString).length - start))
            guard case .todoPill(let pill)? = h.editor.layoutManager.object(at: range.location)?.kind else { return nil }
            return pill.tone
        }
        XCTAssertEqual(tone("⏰", after: "Old"), .done)
        XCTAssertEqual(tone("⏰", after: "Late"), .overdue)
        XCTAssertEqual(tone("⏰", after: "Soon"), .normal)
    }

    func testTickingARepeatingTodoWritesTheNextOneInOneUndo() {
        let line = "- [ ] Water the plants 🔁 every week 📅 2099-01-05"
        let h = EditorHarness(line + "\n- [ ] Call mum")
        let today = TodoDay.today
        let next = "- [ ] Water the plants 🔁 every week 📅 2099-01-12"
        let done = "- [x] Water the plants 🔁 every week 📅 2099-01-05 ✅ \(today)"
        h.caret(h.range(of: "plants").location)
        h.click(at: h.point(of: h.range(of: "[ ]").location))
        XCTAssertEqual(h.text, next + "\n" + done + "\n- [ ] Call mum", "the next one above the done one, as the Tasks plugin writes it")
        XCTAssertEqual(h.selection.location, (h.text as NSString).range(of: "plants", options: .backwards).location, "the caret stays in the words, of the done one")

        h.settle(0.05)
        h.textView.undoManager?.undo()
        h.settle(0)
        XCTAssertEqual(h.text, line + "\n- [ ] Call mum", "one Undo takes back both")
        h.textView.undoManager?.redo()
        h.settle(0.05)
        XCTAssertEqual(h.text, next + "\n" + done + "\n- [ ] Call mum")

        // Unticking the done one makes no other, and ticking it again doesn't either.
        h.click(at: h.point(of: h.range(of: "[x]").location))
        XCTAssertEqual(h.text, next + "\n" + line + "\n- [ ] Call mum")
        h.settle(0.05)
        h.editor.toggleCheckbox(line: 1)
        XCTAssertEqual(h.text, next + "\n" + done + "\n- [ ] Call mum")
    }

    func testTheClickedLineStaysUnderThePointer() {
        let filler = (1...60).map { "Line \($0)" }.joined(separator: "\n")
        let h = EditorHarness(filler + "\n- [ ] Water the plants 🔁 every week 📅 2099-01-05\n" + filler, height: 500)
        let box = h.range(of: "[ ] Water").location
        h.editor.setScrollTop(h.point(of: box).y - 200)
        h.settle()
        let before = h.point(of: box).y - h.textView.visibleRect.minY
        h.click(at: h.point(of: box))
        let done = h.range(of: "[x] Water").location
        XCTAssertGreaterThan(done, box, "the next one went in above")
        XCTAssertEqual(h.point(of: done).y - h.textView.visibleRect.minY, before, accuracy: 1, "the ticked line is where it was clicked")
    }

    func testADoubleClickTicksOnce() {
        let h = EditorHarness("- [ ] Water the plants 🔁 every week 📅 2099-01-05\n- [ ] Call mum")
        let point = h.point(of: h.range(of: "[ ]").location)
        h.click(at: point)
        h.click(at: point, count: 2)
        XCTAssertEqual(h.text, "- [ ] Water the plants 🔁 every week 📅 2099-01-12\n- [x] Water the plants 🔁 every week 📅 2099-01-05 ✅ \(TodoDay.today)\n- [ ] Call mum")
    }

    func testABellShowsAtTheEndOfATodoWithoutAReminder() throws {
        let h = EditorHarness("- [ ] Buy milk\n- [ ] Pay rent 📅 2026-11-01\nPlain line")
        let milk = h.point(of: h.range(of: "milk").location)
        h.editor.updateTodoBell(at: milk)
        XCTAssertFalse(h.textView.todoBell.isHidden)
        XCTAssertEqual(h.textView.todoBell.line, 0)
        let end = try XCTUnwrap(h.editor.todoEnd(line: 0))
        XCTAssertGreaterThan(h.textView.todoBell.frame.minX, end.x)
        XCTAssertEqual(h.textView.todoBell.frame.midY, end.y, accuracy: 1.5)

        h.editor.updateTodoBell(at: h.point(of: h.range(of: "rent").location))
        XCTAssertTrue(h.textView.todoBell.isHidden, "a to-do with a date has its pill to click")
        h.editor.updateTodoBell(at: h.point(of: h.range(of: "Plain").location))
        XCTAssertTrue(h.textView.todoBell.isHidden)

        h.editor.updateTodoBell(at: milk)
        h.textView.todoBell.performClick(nil)
        XCTAssertEqual(h.todoReminders, [0])
    }
}
