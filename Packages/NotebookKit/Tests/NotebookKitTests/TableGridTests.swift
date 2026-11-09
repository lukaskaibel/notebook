import AppKit
import XCTest
@testable import NotebookKit

/// Typing in a table as in Notes: the grid stays while the caret is in it, the Markdown stays in the file.
@MainActor
final class TableGridTests: XCTestCase {
    static let table = "Plan\n\n| Milestone | Goal | Status |\n| --- | --- | --- |\n| M0 | Editor and file spikes | Done |\n| M1 | Finder replacement | Doing |\n\nAfter"

    private func grid(_ h: EditorHarness) -> GridTable? { h.editor.activeGrid }

    /// The point in the middle of the letter at `index` of a cell, as the grid draws it.
    private func point(_ h: EditorHarness, row: Int, column: Int, letter: Int) -> NSPoint? {
        guard let start = h.editor.document.blocks.first(where: { if case .table = $0.kind { true } else { false } })?.range.location,
              let grid = h.editor.gridTable(at: start), let drawn = h.editor.gridDrawing(grid),
              let caret = drawn.model.caretRect(row: row, column: column, at: letter, in: drawn.rect),
              let next = drawn.model.caretRect(row: row, column: column, at: letter + 1, in: drawn.rect) else { return nil }
        return NSPoint(x: (caret.minX + next.minX) / 2 + 0.5, y: caret.midY)
    }

    func testAClickInACellPutsTheCaretAtTheLetterAndTheGridStays() throws {
        let h = EditorHarness(Self.table)
        let clicked = try XCTUnwrap(point(h, row: 2, column: 1, letter: 2))
        h.click(at: clicked)
        // Between "Fi" and "nder": the click was right of the middle of the "n".
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "Finder").location + 3, length: 0))
        XCTAssertNotNil(grid(h), "the table is typed in as a grid")
        XCTAssertFalse(h.isVisible(h.range(of: "| --- |").location), "its Markdown stays hidden")
        let caret = h.editor.caretRect(proposed: NSRect(x: 0, y: 0, width: 1, height: 10_000))
        let cell = try XCTUnwrap(h.editor.gridDrawing(try XCTUnwrap(grid(h))).flatMap { $0.model.cellFrame(row: 2, column: 1, in: $0.rect) })
        XCTAssertTrue(cell.contains(NSPoint(x: caret.midX, y: caret.midY)), "the caret is drawn in the cell, at \(caret), cell \(cell)")
        XCTAssertEqual(caret.minX, clicked.x, accuracy: 6)
        XCTAssertEqual(grid(h)?.cell(at: h.selection.location).map { [$0.row, $0.column] }, [2, 1])
    }

    func testTypingGoesIntoTheCellAndAPipeStaysInIt() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Doing").upperBound)
        h.type(" | soon")
        XCTAssertTrue(h.text.contains("| Doing \\| soon |"), h.text)
        XCTAssertNotNil(grid(h), "still one table, in the grid")
        XCTAssertEqual(grid(h)?.rows.count, 3)
        // Backspace takes the pipe with its backslash.
        for _ in 0..<6 { h.command(#selector(NSResponder.deleteBackward(_:))) }
        XCTAssertTrue(h.text.contains("| Doing  |"), h.text)
        // Pasted lines and pipes stay in the cell too.
        XCTAssertEqual(EditorController.cellText("a|b\nc"), "a\\|b c")
        XCTAssertEqual(EditorController.cellText("kept \\| as is"), "kept \\| as is")
    }

    func testBackspaceAndDeleteStopAtTheEdgesOfACell() {
        let h = EditorHarness(Self.table)
        let done = h.range(of: "Done")
        h.caret(done.location)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, Self.table, "nothing before the cell's text is taken")
        h.caret(done.upperBound)
        h.command(#selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(h.text, Self.table)
        // A selection over several cells empties them.
        h.select(NSRange(location: h.range(of: "M0").location, length: h.range(of: "spikes").upperBound - h.range(of: "M0").location))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(h.text.contains("|  |  | Done |"), h.text)
        XCTAssertEqual(grid(h)?.rows.count, 3)
    }

    func testArrowKeysGoThroughCellsAndOutOfTheTable() {
        let h = EditorHarness(Self.table)
        let status = h.range(of: "Status")
        h.caret(status.upperBound)
        h.command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(h.selection.location, h.range(of: "M0").location, "on from the end of a row to the next row's first cell")
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(h.selection.location, status.upperBound, "and back")
        h.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(grid(h)?.cell(at: h.selection.location).map { [$0.row, $0.column] }, [1, 2], "down to the cell below")
        h.command(#selector(NSResponder.moveDown(_:)))
        h.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(h.selection.location, h.range(of: "\n\nAfter").location + 1, "past the last row, out of the table")
        XCTAssertNil(grid(h))
        h.caret(h.range(of: "Milestone").location)
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(h.selection.location, h.range(of: "Plan\n").location + 5, "before the first cell, out above")
        // ⌘→ goes to the end of the cell, not of the row.
        h.caret(h.range(of: "Editor").location)
        h.command(#selector(NSResponder.moveToEndOfLine(_:)))
        XCTAssertEqual(h.selection.location, h.range(of: "spikes").upperBound)
        h.command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
        h.command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "spikes").upperBound - 2, length: 2), "Shift grows the selection in the cell")
    }

    func testTheCaretGoesIntoACellWhereverItIsPut() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "| --- |").location + 3)
        XCTAssertEqual(grid(h)?.cell(at: h.selection.location).map { $0.row }, 0, "out of the delimiter row, into the header")
        h.caret(h.range(of: "| M1").location)
        XCTAssertEqual(h.selection.location, h.range(of: "M1").location, "before a row's pipe, into its first cell")
    }

    func testRowsAndColumnsComeAndGo() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "M0").upperBound)
        XCTAssertTrue(h.editor.editTable(.addRow(above: false)))
        XCTAssertTrue(h.text.contains("| M0 | Editor and file spikes | Done |\n|     |     |     |\n| M1"), h.text)
        XCTAssertEqual(grid(h)?.cell(at: h.selection.location).map { [$0.row, $0.column] }, [2, 0], "the caret in the new row's cell")
        h.type("M½")
        XCTAssertTrue(h.text.contains("| M½    |     |     |"), h.text)
        h.textView.undoManager?.undo()
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, Self.table, "one step of Undo each")

        h.caret(h.range(of: "Goal").location)
        h.editor.editTable(.addColumn(left: true))
        XCTAssertTrue(h.text.contains("| Milestone |     | Goal | Status |\n| --- | --- | --- | --- |\n| M0 |     | Editor"), h.text)
        XCTAssertEqual(grid(h)?.columns, 4)
        h.editor.editTable(.deleteColumn)
        XCTAssertEqual(h.text, Self.table)

        h.caret(h.range(of: "Status").location)
        h.editor.editTable(.align(.trailing))
        XCTAssertTrue(h.text.contains("| --- | --- | ---: |"), h.text)
        h.editor.editTable(.align(.center))
        XCTAssertTrue(h.text.contains("| --- | --- | :---: |"), h.text)

        // The header deleted: the first row takes its place.
        h.caret(h.range(of: "Milestone").location)
        h.editor.editTable(.deleteRow)
        XCTAssertTrue(h.text.contains("Plan\n\n| M0 | Editor and file spikes | Done |\n| --- | --- | :---: |\n| M1"), h.text)
        // A row above the header: a new header, the old one a row.
        h.editor.editTable(.addRow(above: true))
        XCTAssertTrue(h.text.contains("Plan\n\n|     |     |       |\n| --- | --- | :---: |\n| M0 | Editor"), "an empty row is a copy of the delimiter row, so its pipes line up: \(h.text)")
        h.editor.editTable(.deleteTable)
        XCTAssertEqual(h.text, "Plan\n\n\nAfter")
    }

    func testTheSettingShowsTheMarkdownAndSoDoesARowTheGridCantShow() {
        EditorHarness.withTablesAsMarkdown {
            let h = EditorHarness(Self.table)
            h.caret(h.range(of: "Doing").location)
            XCTAssertNil(h.editor.activeGrid)
            XCTAssertTrue(h.isVisible(h.range(of: "| --- |").location))
        }
        let h = EditorHarness("| A | B |\n| --- | --- |\n| one | two | three |")
        h.caret(h.range(of: "one").location)
        XCTAssertNil(h.editor.activeGrid, "a row with a cell more than the header has")
        XCTAssertTrue(h.isVisible(h.range(of: "three").location))
    }

    func testTheGridDrawsTheCellYouTypeIn() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Finder").location + 2)
        h.settle(0.2)
        h.snapshot("table-grid-caret")
        guard let grid = grid(h), let drawn = h.editor.gridDrawing(grid) else { return XCTFail("no grid") }
        XCTAssertEqual(drawn.model.focus?.row, 2)
        XCTAssertEqual(drawn.model.focus?.column, 1)
        XCTAssertNotNil(drawn.model.columnHandleRect(in: drawn.rect))
        // With a keyboard the bold marks show next to the caret, as in the rest of the note.
        h.caret(h.range(of: "Finder").location)
        h.type("**")
        h.caret(h.range(of: "Finder").upperBound)
        h.type("**")
        h.caret(h.range(of: "Finder").location + 1)
        XCTAssertTrue(h.text.contains("| **Finder** replacement |"), h.text)
        let shown = h.editor.gridDrawing(grid).map { $0.model.rows[2][1].string }
        XCTAssertEqual(shown, "**Finder** replacement")
        h.caret(h.range(of: "replacement").upperBound)
        XCTAssertEqual(h.editor.gridDrawing(self.grid(h)!).map { $0.model.rows[2][1].string }, "Finder replacement")
    }

    func testPastedTextStaysInItsCell() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Done").upperBound)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("table-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("a | b\nc\n", forType: .string)
        XCTAssertTrue(h.editor.paste(from: pasteboard, at: nil))
        XCTAssertTrue(h.text.contains("| Donea \\| b c |"), h.text)
        XCTAssertEqual(h.editor.activeGrid?.rows.count, 3)
        pasteboard.releaseGlobally()
    }
}
