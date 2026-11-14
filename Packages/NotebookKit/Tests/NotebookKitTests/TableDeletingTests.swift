import AppKit
import XCTest
@testable import NotebookKit

/// Rows and columns that come and go leave the note where it is on the screen, and Delete in an empty row or column
/// marks it to go and deletes it when pressed again, as Numbers and Excel delete rows, without their dialog.
@MainActor
final class TableDeletingTests: XCTestCase {
    private static let table = TableGridTests.table

    private func backspace(_ h: EditorHarness) { h.command(#selector(NSResponder.deleteBackward(_:))) }

    private func tableStart(_ h: EditorHarness) -> Int { h.range(of: "| Milestone").location }

    private func cell(_ h: EditorHarness) -> [Int]? {
        h.editor.activeGrid?.cell(at: h.selection.location).map { [$0.row, $0.column] }
    }

    // MARK: - The note stays where it is

    /// A long note scrolled so its table is in the middle of the window.
    private func scrolledToTable() -> EditorHarness {
        let above = (1...40).map { "Line \($0) above the table" }.joined(separator: "\n")
        let below = (1...40).map { "Line \($0) below the table" }.joined(separator: "\n")
        let table = "| Milestone | Goal | Status |\n| --- | --- | --- |\n| M0 | Editor and file spikes | Done |\n| M1 | Finder replacement | Doing |\n| M2 | More | Later |"
        let h = EditorHarness(above + "\n\n" + table + "\n\n" + below, height: 420)
        h.editor.scrollView.contentInsets.top = 52
        h.settle()
        h.caret(h.range(of: "Later").upperBound)
        h.editor.setScrollTop(h.editor.yPosition(of: tableStart(h)) - 150)
        h.settle(0.2)
        return h
    }

    /// Each change with the caret where it moved the note before: in the last row or column, which goes, or in the
    /// header, above which a row comes.
    func testTheNoteStaysWhereItIsAsRowsAndColumnsComeAndGo() throws {
        let h = scrolledToTable()
        let top = h.editor.scrollTop
        let tableY = h.editor.yPosition(of: tableStart(h))
        let cases: [(TableEdit, last: Bool)] = [
            (.deleteRow, true), (.addRow(above: false), true), (.deleteRow, true), (.addRow(above: true), false), (.deleteRow, false),
            (.deleteColumn, true), (.addColumn(left: false), true), (.addColumn(left: true), false), (.deleteColumn, false),
            (.clearRow, true), (.clearColumn, true), (.align(.center), true),
        ]
        for (edit, last) in cases {
            let grid = try XCTUnwrap(h.editor.gridTable(at: tableStart(h)))
            h.caret(last ? grid.contents[grid.rows.count - 1][grid.columns - 1].upperBound : grid.contents[0][0].upperBound)
            XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the caret put in the table moved nothing before \(edit)")
            XCTAssertTrue(h.editor.editTable(edit), "\(edit)")
            h.settle(0.2)
            XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the note stayed where it was after \(edit)")
            XCTAssertEqual(h.editor.yPosition(of: tableStart(h)), tableY, accuracy: 0.5, "and the table where it was in it after \(edit)")
            XCTAssertNotNil(h.editor.activeGrid, "the caret still in the table after \(edit)")
        }
    }

    // MARK: - Delete in an empty row or column

    func testDeleteInAnEmptyRowMarksItAndThenDeletesIt() throws {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Doing").upperBound)
        XCTAssertTrue(h.editor.editTable(.addRow(above: false)))
        let added = h.text
        XCTAssertEqual(cell(h), [3, 2], "in the new row")

        backspace(h)
        XCTAssertEqual(h.text, added, "nothing goes at the first Delete")
        XCTAssertEqual(h.editor.tableDeletion?.part, .row(3))
        let overlay = h.editor.tableOverlay(at: tableStart(h))
        XCTAssertEqual(overlay.deleting, .row(3), "the row is drawn marked")
        XCTAssertEqual(overlay.deleteTitle, "Delete Row  ⌫")
        h.settle(0.2)
        h.snapshot("table-delete-row-marked")

        backspace(h)
        XCTAssertEqual(h.text, Self.table, "the second Delete takes the row")
        XCTAssertNil(h.editor.tableDeletion)
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "Doing").upperBound, length: 0), "the caret at the end of the row above, as after Delete on an empty line")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, added, "one step of Undo brings it back")
    }

    func testAnythingElseLeavesTheMarkedRow() throws {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Doing").upperBound)
        h.editor.editTable(.addRow(above: false))
        let added = h.text

        // Typing: the letter goes into the cell, and the row holds something.
        backspace(h)
        XCTAssertNotNil(h.editor.tableDeletion)
        h.type("x")
        XCTAssertNil(h.editor.tableDeletion)
        XCTAssertTrue(h.text.contains("| x"), h.text)
        backspace(h)
        XCTAssertEqual(h.text, added, "Delete takes the letter, not the row")
        XCTAssertNil(h.editor.tableDeletion)

        // Moving away.
        backspace(h)
        XCTAssertNotNil(h.editor.tableDeletion)
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertNil(h.editor.tableDeletion)
        XCTAssertEqual(h.text, added)

        // Escape.
        backspace(h)
        XCTAssertNotNil(h.editor.tableDeletion)
        h.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(h.editor.tableDeletion)
        backspace(h)
        XCTAssertNotNil(h.editor.tableDeletion, "marked again from the start")
        XCTAssertEqual(h.text, added)
    }

    func testDeleteInAnEmptyColumnMarksItAndThenDeletesIt() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "Goal").location)
        h.editor.editTable(.addColumn(left: true))
        XCTAssertEqual(cell(h), [0, 1], "in the new column's header")

        backspace(h)
        XCTAssertEqual(h.editor.tableDeletion?.part, .column(1), "the row holds something, the column nothing")
        XCTAssertEqual(h.editor.tableOverlay(at: tableStart(h)).deleteTitle, "Delete Column  ⌫")
        h.settle(0.2)
        h.snapshot("table-delete-column-marked")
        backspace(h)
        XCTAssertEqual(h.text, Self.table)
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "Milestone").upperBound, length: 0), "the caret in the cell on the left")

        // Forward Delete does it too, the caret then in what takes its place.
        h.caret(h.range(of: "Goal").location)
        h.editor.editTable(.addColumn(left: true))
        h.command(#selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(h.editor.tableDeletion?.part, .column(1))
        h.command(#selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(h.text, Self.table)
        XCTAssertEqual(cell(h), [0, 1])
    }

    /// A cell left empty in a row and a column that hold something: Delete does nothing there, as before.
    func testDeleteInAnEmptyCellOfAFullRowDoesNothing() {
        let table = "| A | B |\n| --- | --- |\n| one |  |\n| three | four |"
        let h = EditorHarness(table)
        h.caret(h.range(of: "one").upperBound + 3)
        XCTAssertEqual(cell(h), [1, 1])
        backspace(h)
        backspace(h)
        XCTAssertEqual(h.text, table)
        XCTAssertNil(h.editor.tableDeletion)
    }

    /// A table with nothing in it, such as one put in by mistake: the whole table.
    func testDeleteInAnEmptyTableDeletesTheTable() throws {
        let h = EditorHarness("Plan\n\n|     |     |\n| --- | --- |\n|     |     |\n\nAfter")
        h.caret(try XCTUnwrap(h.editor.gridTable(at: h.range(of: "|     |").location)).contents[1][1].location)
        backspace(h)
        XCTAssertEqual(h.editor.tableDeletion?.part, .table)
        XCTAssertEqual(h.editor.tableOverlay(at: h.range(of: "|     |").location).deleteTitle, "Delete Table  ⌫")
        backspace(h)
        XCTAssertEqual(h.text, "Plan\n\n\nAfter")
    }

    /// The last row, or the last column, is the table: its button says so.
    func testTheLastRowSaysItDeletesTheTable() {
        let h = EditorHarness("Plan\n\n| A |     |\n| --- | --- |\n\nAfter")
        h.caret(h.range(of: "| A |").upperBound + 1)
        XCTAssertEqual(cell(h), [0, 1])
        backspace(h)
        XCTAssertEqual(h.editor.tableDeletion?.part, .column(1))
        XCTAssertEqual(h.editor.tableOverlay(at: h.range(of: "| A |").location).deleteTitle, "Delete Column  ⌫")
    }

    func testTheButtonDeletesTheMarkedRow() throws {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "M0").upperBound)
        h.editor.editTable(.addRow(above: false))
        backspace(h)
        let grid = try XCTUnwrap(h.editor.activeGrid)
        let drawn = try XCTUnwrap(h.editor.gridDrawing(grid))
        let mark = try XCTUnwrap(h.editor.tableDeletion)
        let button = try XCTUnwrap(drawn.model.deleteButtonRect(mark.part, title: h.editor.deleteButtonTitle(mark.part, in: grid), in: drawn.rect))
        XCTAssertTrue(drawn.model.area(of: mark.part, in: drawn.rect)?.contains(NSPoint(x: button.midX, y: button.midY)) == true, "the button is on the row")
        h.click(at: NSPoint(x: button.midX, y: button.midY))
        XCTAssertEqual(h.text, Self.table, "the click deletes the row")
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "Done").upperBound, length: 0))
    }

    // MARK: - Clear

    func testClearEmptiesARowOrAColumnAndKeepsTheTable() {
        let h = EditorHarness(Self.table)
        h.caret(h.range(of: "M0").upperBound)
        XCTAssertTrue(h.editor.editTable(.clearRow))
        XCTAssertTrue(h.text.contains("| --- | --- | --- |\n|  |  |  |\n| M1"), h.text)
        XCTAssertEqual(h.editor.activeGrid?.rows.count, 3)
        XCTAssertEqual(cell(h), [1, 0])
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, Self.table, "one step of Undo")

        h.caret(h.range(of: "Goal").location)
        XCTAssertTrue(h.editor.editTable(.clearColumn))
        XCTAssertTrue(h.text.contains("| Milestone |  | Status |\n| --- | --- | --- |\n| M0 |  | Done |\n| M1 |  | Doing |"), h.text)
        // Now the column holds nothing: Delete marks it.
        backspace(h)
        XCTAssertEqual(h.editor.tableDeletion?.part, .column(1))
    }
}
