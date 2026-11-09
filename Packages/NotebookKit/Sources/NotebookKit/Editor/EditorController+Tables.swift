#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A table typed in as a grid, read from the note as it is now: its rows (the header first), each cell from pipe to
/// pipe, and where each cell's text is. Only a Markdown table whose rows all have its columns is one.
struct GridTable {
    let block: Int
    let range: NSRange
    let alignments: [TableAlignment]
    /// The ranges of its rows' lines, the header first, without the delimiter row.
    let rows: [NSRange]
    let delimiter: NSRange
    /// For each row, each cell from one pipe to the next, in the note.
    let slots: [[NSRange]]
    let delimiterSlots: [NSRange]
    /// For each row, where each cell's text is, or in an empty cell where typing goes.
    let contents: [[NSRange]]

    var columns: Int { alignments.count }

    init?(block index: Int, in document: MarkdownDocument, text: NSString) {
        guard let block = document.blocks[safe: index], case .table(let alignments) = block.kind, !alignments.isEmpty else { return nil }
        let lines = Array(document.lines[block.lines])
        let units = text.units(of: lines)
        // As the styler decides it: a table the grid can't show shows its Markdown.
        guard TableModel.fitsGrid(units, lines: lines, columns: alignments.count) else { return nil }
        var rows: [NSRange] = [], slots: [[NSRange]] = [], contents: [[NSRange]] = []
        var delimiter: NSRange?
        var delimiterSlots: [NSRange] = []
        for line in lines {
            let lineSlots = MarkdownParser.tableSlots(units, line.range)
            guard lineSlots.count == alignments.count else { return nil }
            if line.kind == .tableDelimiter {
                delimiter = line.range
                delimiterSlots = lineSlots
                continue
            }
            rows.append(line.range)
            slots.append(lineSlots)
            contents.append(zip(lineSlots, MarkdownParser.tableCells(units, line.range)).map { TableModel.content(of: $1, in: $0, units) })
        }
        guard let delimiter, !rows.isEmpty else { return nil }
        self.block = index
        range = block.range
        self.alignments = alignments
        self.rows = rows
        self.delimiter = delimiter
        self.slots = slots
        self.delimiterSlots = delimiterSlots
        self.contents = contents
    }

    /// The cell a place in the note is in: the row of its line, the column between whose pipes it is (before the
    /// first, the first; after the last, the last). None in the delimiter row.
    func cell(at index: Int) -> (row: Int, column: Int)? {
        guard let row = rows.firstIndex(where: { index >= $0.location && index <= $0.upperBound }) else { return nil }
        let column = slots[row].firstIndex { index <= $0.upperBound } ?? columns - 1
        return (row, column)
    }

    /// A place in a cell the caret may be at: in its text, or after spaces typed at its end, but never before the
    /// space after its pipe, nor between the backslash and the pipe it keeps in the cell.
    func clamp(_ index: Int, row: Int, column: Int, in text: NSString) -> Int {
        let content = contents[row][column]
        let slot = slots[row][column]
        var place = min(max(index, content.location), max(content.upperBound, slot.upperBound))
        if place > content.upperBound, !(content.upperBound..<place).allSatisfy({ [32, 9].contains(text.character(at: $0)) }) { place = content.upperBound }
        if place > content.location, place < content.upperBound, text.character(at: place - 1) == 92, text.character(at: place) == 124 { place -= 1 }
        return place
    }

    /// Whether a place is somewhere the caret may be in this table.
    func isCaretPlace(_ index: Int, in text: NSString) -> Bool {
        guard let (row, column) = cell(at: index) else { return false }
        return clamp(index, row: row, column: column, in: text) == index
    }
}

/// What a table's handles, its + and Format › Table do.
enum TableEdit: Equatable {
    case addRow(above: Bool)
    case addColumn(left: Bool)
    case deleteRow
    case deleteColumn
    case align(TableAlignment)
    case deleteTable
}

/// Typing in a table as in Notes: the grid stays while the caret is in it, and you type in its cells. The note keeps
/// the table's Markdown, which is what the caret, a click and a selection are worked out in; the grid only shows it.
/// A `|` typed in a cell is kept as `\|`, and Return, Tab, the arrow keys and Delete never take a cell's pipes.
extension EditorController {
    // MARK: - Which table

    /// The table typed in as a grid that a place in the note is in, if it is one.
    func gridTable(at index: Int) -> GridTable? {
        guard syntax == .markdown, !NotebookSettings.shared.editsTablesAsMarkdown, !document.lines.isEmpty, index >= 0, index <= storage.length else { return nil }
        guard let block = document.lines[document.lineIndex(containing: index)].block, case .table = document.blocks[block].kind else { return nil }
        return GridTable(block: block, in: document, text: nsText)
    }

    /// The table the caret is typing in, shown as a grid.
    var activeGrid: GridTable? {
        guard let block = activeBlock, let start = document.blocks[safe: block]?.range.location else { return nil }
        return gridTable(at: start)
    }

    /// The table as it is drawn, and where.
    func gridDrawing(_ grid: GridTable) -> (model: TableModel, rect: NSRect)? {
        let start = grid.range.location
        guard start < storage.length else { return nil }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: start, length: 1))
        guard let object = layoutManager.object(at: start), case .table(let model) = object.kind,
              let rect = layoutManager.blockObjectRect(at: start, origin: textOrigin) else { return nil }
        return (model, NSRect(x: rect.minX, y: rect.minY, width: rect.width - 1, height: rect.height))
    }

    /// The cell the caret is in and the marks next to it that show, for the styler to draw the table with.
    func tableFocusTarget(block: Int?) -> (location: Int, focus: TableModel.Focus)? {
        guard isFocused, let block, let start = document.blocks[safe: block]?.range.location, let grid = gridTable(at: start) else { return nil }
        let selection = self.selection
        // While text is selected nothing appears or disappears, as in the rest of the note.
        if selection.length > 0, let focus = tableFocus, focus.location == start { return focus }
        let (row, column) = grid.cell(at: selection.location) ?? (0, 0)
        let content = grid.contents[row][column]
        let source = Array(nsText.substring(with: content).utf16)
        let caret = selection.location - content.location
        var revealing: [NSRange] = []
        for span in InlineParser.spans(in: source, range: NSRange(location: 0, length: source.count)) where !span.isAtomic && span.range.touches(caret) {
            // On a touch keyboard the bar above it shows the styles the caret is in.
            if !showsMarks, span.kind.isStyle { continue }
            revealing.append(span.range)
        }
        return (start, TableModel.Focus(row: row, column: column, revealing: revealing))
    }

    // MARK: - Caret and clicks

    /// The caret in a cell of the table being typed in, where its letters are drawn.
    func tableCaretRect(at index: Int) -> NSRect? {
        guard let grid = activeGrid, index >= grid.range.location, index <= grid.range.upperBound,
              let (row, column) = grid.cell(at: index), let drawn = gridDrawing(grid) else { return nil }
        let content = grid.contents[row][column]
        guard let map = drawn.model.maps[safe: row]?[safe: column], map.count == content.length + 1 else { return nil }
        let offset = min(max(index, content.location), content.upperBound) - content.location
        guard var caret = drawn.model.caretRect(row: row, column: column, at: map[offset], in: drawn.rect) else { return nil }
        // Spaces typed at the end of a cell don't show until something follows them; the caret goes on past them.
        if index > content.upperBound {
            let font = (drawn.model.rows[row][column].length > 0 ? drawn.model.rows[row][column].attribute(.font, at: max(0, drawn.model.rows[row][column].length - 1), effectiveRange: nil) as? NSFont : nil) ?? TableModel.font
            caret.origin.x += CGFloat(index - content.upperBound) * (" " as NSString).size(withAttributes: [.font: font]).width
        }
        return caret
    }

    /// The place in the note a point in a table typed in as a grid stands for: the cell it is over (or nearest), and
    /// in it the letter nearest it. `cell` keeps it to one cell, as while a selection is dragged.
    func gridIndex(at point: NSPoint, in grid: GridTable, cell fixed: (row: Int, column: Int)? = nil) -> Int? {
        guard let drawn = gridDrawing(grid) else { return nil }
        let layout = drawn.model.layout(maxWidth: drawn.rect.width)
        func index(of widths: [CGFloat], at position: CGFloat, from start: CGFloat) -> Int {
            var edge = start
            for (index, width) in widths.enumerated() {
                edge += width
                if position < edge { return index }
            }
            return max(0, widths.count - 1)
        }
        let row = fixed?.row ?? index(of: layout.rowHeights, at: point.y, from: drawn.rect.minY)
        let column = fixed?.column ?? index(of: layout.columnWidths, at: point.x, from: drawn.rect.minX)
        guard grid.contents.indices.contains(row), grid.contents[row].indices.contains(column),
              let map = drawn.model.maps[safe: row]?[safe: column] else { return nil }
        let content = grid.contents[row][column]
        let shown = drawn.model.offset(row: row, column: column, at: point, in: drawn.rect)
        let offset = map.firstIndex { $0 >= shown } ?? content.length
        return grid.clamp(content.location + min(offset, content.length), row: row, column: column, in: nsText)
    }

    /// Where the caret goes for a click in a table drawn whole: in the cell clicked, at the letter clicked, if the
    /// table is typed in as a grid; at the end of the cell's Markdown if it shows its Markdown then.
    func tableCaret(at point: NSPoint, block: Int, model: TableModel, objectRect: NSRect) -> Int {
        let start = document.blocks[block].range.location
        if let grid = gridTable(at: start), let index = gridIndex(at: point, in: grid) { return index }
        var caret = start
        if let cell = model.cell(at: point, in: objectRect), let ranges = model.cellRanges[safe: cell.row] {
            caret = ranges[safe: cell.column]?.upperBound ?? ranges.last?.upperBound ?? caret
        }
        return caret
    }

    /// The caret put somewhere in a table typed in as a grid that isn't in a cell (by the text view, a click beside
    /// the table, an undo) goes into the cell of its row it is nearest; from the delimiter row, into the header.
    func snapIntoGrid(_ location: Int) -> Int? {
        guard let grid = gridTable(at: location), location >= grid.range.location, location <= grid.range.upperBound,
              !grid.isCaretPlace(location, in: nsText) else { return nil }
        if let (row, column) = grid.cell(at: location) {
            return grid.clamp(location, row: row, column: column, in: nsText)
        }
        // In the delimiter row: the header's cell above.
        let column = grid.delimiterSlots.firstIndex { location <= $0.upperBound } ?? 0
        return grid.contents[0][column].upperBound
    }

    // MARK: - Moving in the grid

    enum TableMove {
        case left, right, up, down, wordLeft, wordRight, cellStart, cellEnd
    }

    /// The arrow keys in a table typed in as a grid: through the letters of a cell, then on to the next cell, the row
    /// above or below; out of the table past its first and last cell. With Shift the selection grows within the cell.
    func moveInGrid(_ move: TableMove, extending: Bool = false) -> Bool {
        guard isFocused, let grid = activeGrid else { return false }
        let selection = self.selection
        guard selection.location >= grid.range.location, selection.upperBound <= grid.range.upperBound else { return false }
        let text = nsText
        // The end of the selection that moves.
        let anchor = extending ? (gridAnchor ?? selection.location) : nil
        let moving = extending && selection.length > 0 ? (anchor == selection.location ? selection.upperBound : selection.location)
            : (move == .left || move == .up || move == .wordLeft || move == .cellStart ? selection.location : selection.upperBound)
        guard let (row, column) = grid.cell(at: moving) else { return false }
        let content = grid.contents[row][column]
        let place = grid.clamp(moving, row: row, column: column, in: text)

        // A selection collapses to its end that way, as in text.
        if !extending, selection.length > 0, move == .left || move == .right {
            setSelection(NSRange(location: move == .left ? selection.location : selection.upperBound, length: 0))
            return true
        }

        var target: Int?
        switch move {
        case .right, .wordRight:
            if place < content.upperBound {
                target = move == .right ? nextPlace(after: place, row: row, column: column, in: grid) : wordEnd(after: place, in: content)
            } else if !extending {
                target = neighbour(of: (row, column), by: 1, in: grid).map { grid.contents[$0.row][$0.column].location } ?? leaveTable(grid, down: true)
            }
        case .left, .wordLeft:
            if place > content.location {
                target = move == .left ? previousPlace(before: place, row: row, column: column, in: grid) : wordStart(before: place, in: content)
            } else if !extending {
                target = neighbour(of: (row, column), by: -1, in: grid).map { grid.contents[$0.row][$0.column].upperBound } ?? leaveTable(grid, down: false)
            }
        case .cellStart:
            target = content.location
        case .cellEnd:
            target = content.upperBound
        case .up, .down:
            let direction = move == .up ? -1 : 1
            if let drawn = gridDrawing(grid), let map = drawn.model.maps[safe: row]?[safe: column],
               let caret = tableCaretRect(at: place) {
                let x = gridColumnX ?? caret.minX
                gridColumnX = x
                if let shown = drawn.model.offset(row: row, column: column, from: map[min(place, content.upperBound) - content.location], lines: direction, x: x, in: drawn.rect) {
                    target = content.location + (map.firstIndex { $0 >= shown } ?? content.length)
                } else if extending {
                    target = direction < 0 ? content.location : content.upperBound
                } else if grid.rows.indices.contains(row + direction) {
                    let point = NSPoint(x: x, y: direction < 0 ? (drawn.model.cellFrame(row: row + direction, column: column, in: drawn.rect)?.maxY ?? 0) - TableModel.padding.height - 2
                                                         : (drawn.model.cellFrame(row: row + direction, column: column, in: drawn.rect)?.minY ?? 0) + TableModel.padding.height + 2)
                    target = gridIndex(at: point, in: grid, cell: (row + direction, column))
                } else {
                    target = leaveTable(grid, down: direction > 0)
                }
            }
            if let target { setGridSelection(target, anchor: anchor, keepsColumn: true) }
            return true
        }
        if let target { setGridSelection(target, anchor: anchor, keepsColumn: false) }
        return true
    }

    private func setGridSelection(_ target: Int, anchor: Int?, keepsColumn: Bool) {
        let x = gridColumnX
        if let anchor {
            gridAnchor = anchor
            setSelection(NSRange(location: min(anchor, target), length: abs(target - anchor)))
            gridAnchor = anchor
        } else {
            setSelection(NSRange(location: target, length: 0))
        }
        if keepsColumn { gridColumnX = x }
        scrollCaretIntoView()
    }

    /// The next place in a cell that shows somewhere else: hidden marks and the backslash before a `|` are passed over.
    private func nextPlace(after place: Int, row: Int, column: Int, in grid: GridTable) -> Int {
        let content = grid.contents[row][column]
        guard let map = gridDrawing(grid)?.model.maps[safe: row]?[safe: column], map.count == content.length + 1 else { return min(place + 1, content.upperBound) }
        let offset = place - content.location
        let next = (offset + 1..<map.count).first { map[$0] > map[offset] } ?? content.length
        return grid.clamp(content.location + next, row: row, column: column, in: nsText)
    }

    private func previousPlace(before place: Int, row: Int, column: Int, in grid: GridTable) -> Int {
        let content = grid.contents[row][column]
        guard place <= content.upperBound, let map = gridDrawing(grid)?.model.maps[safe: row]?[safe: column], map.count == content.length + 1 else {
            return max(content.location, place - 1)
        }
        let offset = place - content.location
        guard let shown = (0..<offset).last(where: { map[$0] < map[offset] }).map({ map[$0] }) else { return content.location }
        let previous = map.firstIndex(of: shown) ?? 0
        return grid.clamp(content.location + previous, row: row, column: column, in: nsText)
    }

    private func wordEnd(after place: Int, in content: NSRange) -> Int {
        let text = nsText
        var index = place
        while index < content.upperBound, !Self.isWordCharacter(text.character(at: index)) { index += 1 }
        while index < content.upperBound, Self.isWordCharacter(text.character(at: index)) { index += 1 }
        return index
    }

    private func wordStart(before place: Int, in content: NSRange) -> Int {
        let text = nsText
        var index = place
        while index > content.location, !Self.isWordCharacter(text.character(at: index - 1)) { index -= 1 }
        while index > content.location, Self.isWordCharacter(text.character(at: index - 1)) { index -= 1 }
        return index
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The cell after or before one, row by row.
    private func neighbour(of cell: (row: Int, column: Int), by step: Int, in grid: GridTable) -> (row: Int, column: Int)? {
        let index = cell.row * grid.columns + cell.column + step
        guard index >= 0, index < grid.rows.count * grid.columns else { return nil }
        return (index / grid.columns, index % grid.columns)
    }

    /// Out of the table: to the end of the line above it or the start of the line below, where there is one.
    private func leaveTable(_ grid: GridTable, down: Bool) -> Int? {
        if down { return grid.range.upperBound < storage.length ? grid.range.upperBound + 1 : nil }
        return grid.range.location > 0 ? grid.range.location - 1 : nil
    }

    // MARK: - Typing in a cell

    /// What goes into a cell for text typed or pasted: a `|` kept as `\|` and line breaks as spaces, so the table
    /// stays one.
    static func cellText(_ string: String) -> String {
        var result = ""
        var previous: Character?
        for character in string {
            switch character {
            case "\n", "\r", "\r\n", "\u{2028}", "\u{2029}": result.append(" ")
            case "|": result += previous == "\\" ? "|" : "\\|"
            default: result.append(character)
            }
            previous = character
        }
        return result
    }

    /// Text typed, pasted or put back over a selection in a table typed in as a grid: inside a cell it goes in as
    /// `cellText` makes it; over several cells, it empties what is selected of each and goes into the first. Nil when
    /// the rules of the rest of the note take it as it is.
    func insertInGrid(_ replacement: String, in range: NSRange) -> Bool? {
        guard let grid = activeGrid, range.location >= grid.range.location, range.upperBound <= grid.range.upperBound,
              let (row, column) = grid.cell(at: range.location) else { return nil }
        // A `|` at the start of an empty row is a row being written by hand, as after Return under a header typed by
        // hand: the row shows its Markdown from there (`shouldInsert`'s rule), and the table its own once it's written.
        if replacement == "|", range.length == 0, column == 0, grid.contents[row].allSatisfy({ $0.length == 0 }) { return nil }
        let cleaned = Self.cellText(replacement)
        let slot = grid.slots[row][column]
        if range.location >= slot.location, range.upperBound <= slot.upperBound {
            guard cleaned != replacement else { return nil }
            replace(range, with: cleaned, select: NSRange(location: range.location + (cleaned as NSString).length, length: 0))
            return false
        }
        clearCells(range, in: grid, inserting: cleaned)
        return false
    }

    /// Pasting into a cell of the table being typed in: the text only, its line breaks as spaces and its `|` kept in the
    /// cell; a picture or a file, which a cell can't hold, not at all. False outside a table typed in as a grid.
    func pasteIntoGrid(_ string: String?, at target: NSRange) -> Bool {
        guard let grid = activeGrid, target.location >= grid.range.location, target.upperBound <= grid.range.upperBound else { return false }
        guard let string = string?.trimmingCharacters(in: .newlines), !string.isEmpty else { return true }
        if insertInGrid(string, in: target) == nil {
            replace(target, with: string, select: NSRange(location: target.location + (string as NSString).length, length: 0), actionName: "Paste")
        }
        return true
    }

    /// Empties what a selection over several cells holds of each, and puts `text` into the first.
    private func clearCells(_ range: NSRange, in grid: GridTable, inserting text: String) {
        var changes: [(range: NSRange, replacement: String)] = grid.contents.joined().compactMap { content in
            let part = NSIntersectionRange(range, content)
            return part.length > 0 ? (part, "") : nil
        }
        if changes.isEmpty {
            guard let (row, column) = grid.cell(at: range.location) else { return }
            changes = [(NSRange(location: grid.clamp(range.location, row: row, column: column, in: nsText), length: 0), "")]
        }
        changes[0].replacement = text
        let start = changes[0].range.location
        guard changes.contains(where: { $0.range.length > 0 || !$0.replacement.isEmpty }) else {
            setSelection(NSRange(location: start, length: 0))
            return
        }
        replace(changes, actionName: text.isEmpty ? "Delete" : "Typing")
        setSelection(NSRange(location: start + (text as NSString).length, length: 0))
    }

    /// Backspace and Delete in a table typed in as a grid: at the edge of a cell they do nothing, as in Notes, a `|`
    /// goes with the backslash that keeps it in the cell, and a selection over several cells empties them. Nil when
    /// the rules of the rest of the note take it.
    func deleteInGrid(forward: Bool) -> Bool? {
        guard let grid = activeGrid else { return nil }
        let selection = self.selection
        guard selection.location >= grid.range.location, selection.upperBound <= grid.range.upperBound,
              let (row, column) = grid.cell(at: selection.location) else { return nil }
        let content = grid.contents[row][column]
        let slot = grid.slots[row][column]
        let text = nsText
        if selection.length > 0 {
            if selection.location >= slot.location, selection.upperBound <= slot.upperBound { return nil }
            clearCells(selection, in: grid, inserting: "")
            return true
        }
        let place = selection.location
        if forward {
            guard place < content.upperBound else { return true }
            if text.character(at: place) == 92, place + 1 < content.upperBound, text.character(at: place + 1) == 124 {
                replace(NSRange(location: place, length: 2), with: "", select: NSRange(location: place, length: 0), actionName: "Delete")
                return true
            }
            return nil
        }
        // Spaces typed after a cell's text go one by one.
        if place > content.upperBound {
            replace(NSRange(location: place - 1, length: 1), with: "", select: NSRange(location: place - 1, length: 0), actionName: "Delete")
            return true
        }
        guard place > content.location else { return true }
        if text.character(at: place - 1) == 124, place - 2 >= content.location, text.character(at: place - 2) == 92 {
            replace(NSRange(location: place - 2, length: 2), with: "", select: NSRange(location: place - 2, length: 0), actionName: "Delete")
            return true
        }
        return nil
    }

    // MARK: - Rows and columns

    /// The cell of the table being typed in that the caret is in.
    var gridCaretCell: (grid: GridTable, row: Int, column: Int)? {
        guard let grid = activeGrid, let (row, column) = grid.cell(at: selection.location) else { return nil }
        return (grid, row, column)
    }

    /// Adds or deletes a row or a column of the table the caret is in, or aligns a column, as one step of Undo; the
    /// caret goes into the cell that takes the place of the one it was in. `row` and `column` pick another cell than
    /// the caret's, as a handle does.
    @discardableResult
    func editTable(_ edit: TableEdit, row pickedRow: Int? = nil, column pickedColumn: Int? = nil) -> Bool {
        guard !isReadOnly, !isWaitingForText, let (grid, caretRow, caretColumn) = gridCaretCell ?? pickedGrid() else { return false }
        let row = min(pickedRow ?? caretRow, grid.rows.count - 1)
        let column = min(pickedColumn ?? caretColumn, grid.columns - 1)
        let text = nsText
        let start = grid.range.location
        var changes: [(range: NSRange, replacement: String)] = []
        var next = (row: row, column: column)
        let lines = [grid.rows[0], grid.delimiter] + grid.rows.dropFirst()
        let lineSlots = [grid.slots[0], grid.delimiterSlots] + grid.slots.dropFirst()
        let emptyRow = Self.emptyTableRow(like: Array(text.substring(with: grid.delimiter).utf16)).row

        switch edit {
        case .addRow(let above):
            if above, row == 0 {
                // A new header: the old one becomes the first row under the delimiter.
                let header = text.substring(with: grid.rows[0])
                let delimiter = text.substring(with: grid.delimiter)
                changes.append((NSRange(location: grid.rows[0].location, length: grid.delimiter.upperBound - grid.rows[0].location),
                                emptyRow + "\n" + delimiter + "\n" + header))
                next = (0, column)
            } else if above, row > 1 {
                changes.append((NSRange(location: grid.rows[row].location, length: 0), emptyRow + "\n"))
                next = (row, column)
            } else {
                // Below the header (or above the first row) the new row goes under the delimiter.
                let after = row == 0 || (above && row == 1) ? grid.delimiter : grid.rows[row]
                changes.append((NSRange(location: after.upperBound, length: 0), "\n" + emptyRow))
                next = (above ? row : row + 1, column)
                if row == 0 { next = (1, column) }
            }
        case .deleteRow:
            guard grid.rows.count > 1 else { return editTable(.deleteTable) }
            if row == 0 {
                // The first row becomes the header.
                changes.append((grid.rows[0], text.substring(with: grid.rows[1])))
                changes.append((NSRange(location: grid.delimiter.upperBound, length: grid.rows[1].upperBound - grid.delimiter.upperBound), ""))
            } else {
                let above = row == 1 ? grid.delimiter : grid.rows[row - 1]
                changes.append((NSRange(location: above.upperBound, length: grid.rows[row].upperBound - above.upperBound), ""))
            }
            next = (min(row, grid.rows.count - 2), column)
        case .addColumn(let left):
            for (line, slots) in zip(lines, lineSlots) {
                let cell = line == grid.delimiter ? " --- " : "     "
                if left {
                    changes.append((NSRange(location: slots[column].location, length: 0), cell + "|"))
                } else {
                    changes.append((NSRange(location: slots[column].upperBound, length: 0), "|" + cell))
                }
            }
            next = (row, left ? column : column + 1)
        case .deleteColumn:
            guard grid.columns > 1 else { return editTable(.deleteTable) }
            for slots in lineSlots {
                if column < slots.count - 1 {
                    changes.append((NSRange(location: slots[column].location, length: slots[column + 1].location - slots[column].location), ""))
                } else {
                    changes.append((NSRange(location: slots[column - 1].upperBound, length: slots[column].upperBound - slots[column - 1].upperBound), ""))
                }
            }
            next = (row, min(column, grid.columns - 2))
        case .align(let alignment):
            let units = Array(text.substring(with: grid.delimiter).utf16)
            guard let cell = MarkdownParser.tableCells(units, NSRange(location: 0, length: units.count))[safe: column] else { return false }
            let dashes = String(repeating: "-", count: max(3, text.substring(with: NSRange(location: grid.delimiter.location + cell.location, length: cell.length)).filter { $0 == "-" }.count))
            let written = (alignment == .center ? ":" : "") + dashes + (alignment == .trailing || alignment == .center ? ":" : "")
            changes.append((NSRange(location: grid.delimiter.location + cell.location, length: cell.length), written))
        case .deleteTable:
            // With the line break after it, or before it at the end of the note.
            var range = grid.range
            if range.upperBound < storage.length { range.length += 1 } else if range.location > 0 { range = NSRange(location: range.location - 1, length: range.length + 1) }
            return replace(range, with: "", select: NSRange(location: range.location, length: 0), actionName: "Delete Table")
        }
        guard replace(changes, actionName: edit.actionName) else { return false }
        if let table = gridTable(at: start), table.contents.indices.contains(next.row), table.contents[next.row].indices.contains(next.column) {
            let content = table.contents[next.row][next.column]
            setSelection(NSRange(location: content.upperBound, length: 0))
        }
        return true
    }

    /// The table a handle's menu is about while it is open, though the caret may have gone from it.
    private func pickedGrid() -> (grid: GridTable, row: Int, column: Int)? {
        guard let band = tableBand, let grid = gridTable(at: band.location) else { return nil }
        switch band.band {
        case .row(let row): return (grid, row, 0)
        case .column(let column): return (grid, 0, column)
        }
    }

    /// The + along a table's right edge or its bottom: a column or a row at the end, the caret in its cell.
    func addAtEdge(of block: Int, column: Bool) {
        guard let start = document.blocks[safe: block]?.range.location, let grid = gridTable(at: start) else { return }
        makeTextFirstResponder()
        let row = column ? 0 : grid.rows.count - 1
        let lastColumn = grid.columns - 1
        setSelection(NSRange(location: grid.contents[row][column ? lastColumn : 0].upperBound, length: 0))
        editTable(column ? .addColumn(left: false) : .addRow(above: false), row: row, column: column ? lastColumn : 0)
    }

    // MARK: - Menus

    /// A column's menu, from its handle: add one on either side, align it, delete it. `compact` for the edit menu of
    /// iPhone and iPad, a row of short words.
    func tableColumnEntries(column: Int? = nil, compact: Bool = false) -> [MenuEntry] {
        let start = tableBand?.location ?? activeGrid?.range.location
        let alignment = start.flatMap { gridTable(at: $0) }.flatMap { grid in grid.alignments[safe: column ?? gridCaretCell?.column ?? 0] } ?? .leading
        let names: [TableAlignment: String] = [.leading: "Left", .center: "Center", .trailing: "Right"]
        let align = MenuEntry.submenu("Align", "text.aligncenter") { [weak self] in
            for (choice, symbol) in [(TableAlignment.leading, "text.alignleft"), (.center, "text.aligncenter"), (.trailing, "text.alignright")] {
                MenuEntry(names[choice] ?? "", symbol, checked: alignment == choice) { self?.editTable(.align(choice), column: column) }
            }
        }.with { $0.value = names[alignment] }
        return [
            MenuEntry(compact ? "Add Left" : "Add Column Left", "arrow.left", keys: "⌥⌘←") { [weak self] in self?.editTable(.addColumn(left: true), column: column) },
            MenuEntry(compact ? "Add Right" : "Add Column Right", "arrow.right", keys: "⌥⌘→") { [weak self] in self?.editTable(.addColumn(left: false), column: column) },
            .divider,
            align,
            .divider,
            MenuEntry(compact ? "Delete" : "Delete Column", "trash", destructive: true) { [weak self] in self?.editTable(.deleteColumn, column: column) },
        ]
    }

    /// A row's menu, from its handle: add one above or below it, delete it.
    func tableRowEntries(row: Int? = nil, compact: Bool = false) -> [MenuEntry] {
        [
            MenuEntry(compact ? "Add Above" : "Add Row Above", "arrow.up", keys: "⌥⌘↑") { [weak self] in self?.editTable(.addRow(above: true), row: row) },
            MenuEntry(compact ? "Add Below" : "Add Row Below", "arrow.down", keys: "⌥⌘↓") { [weak self] in self?.editTable(.addRow(above: false), row: row) },
            .divider,
            MenuEntry(compact ? "Delete" : "Delete Row", "trash", destructive: true) { [weak self] in self?.editTable(.deleteRow, row: row) },
        ]
    }

    /// The table's menu where the caret is in one: Table in the toolbar and the writing bar, the right-click menu.
    func tableEntries() -> [MenuEntry] {
        [
            MenuEntry("Add Row Above", "arrow.up", keys: "⌥⌘↑") { [weak self] in self?.editTable(.addRow(above: true)) },
            MenuEntry("Add Row Below", "arrow.down", keys: "⌥⌘↓") { [weak self] in self?.editTable(.addRow(above: false)) },
            MenuEntry("Add Column Left", "arrow.left", keys: "⌥⌘←") { [weak self] in self?.editTable(.addColumn(left: true)) },
            MenuEntry("Add Column Right", "arrow.right", keys: "⌥⌘→") { [weak self] in self?.editTable(.addColumn(left: false)) },
            .divider,
            MenuEntry("Delete Row", "minus.rectangle") { [weak self] in self?.editTable(.deleteRow) },
            MenuEntry("Delete Column", "minus.rectangle.portrait") { [weak self] in self?.editTable(.deleteColumn) },
            MenuEntry("Delete Table", "trash", destructive: true) { [weak self] in self?.editTable(.deleteTable) },
        ]
    }

    /// The boxes a selection in the table being typed in is drawn in: the text selected in a cell, or the cells a
    /// selection over several of them takes. Nil outside one.
    func gridSelectionRects(_ range: NSRange) -> [CGRect]? {
        guard range.length > 0, let grid = activeGrid, range.location >= grid.range.location, range.upperBound <= grid.range.upperBound,
              let drawn = gridDrawing(grid) else { return nil }
        return drawn.model.selectionBoxes(for: range, in: drawn.rect)
    }

    /// The place in the table being typed in nearest a point over it, for the loupe and a selection's handles.
    func gridIndex(near point: CGPoint) -> Int? {
        guard let grid = activeGrid, let drawn = gridDrawing(grid), drawn.rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return gridIndex(at: point, in: grid)
    }

    // MARK: - Handles and the + along the edges

    enum TableControl: Equatable {
        case columnHandle(block: Int, column: Int)
        case rowHandle(block: Int, row: Int)
        case addColumn(block: Int)
        case addRow(block: Int)
    }

    /// The handle or + at a point, of the table being typed in or of the one under the pointer. A finger gets more
    /// room round them than the pointer.
    func tableControl(at point: NSPoint, slop: CGFloat) -> TableControl? {
        if let grid = activeGrid, let drawn = gridDrawing(grid), let focus = drawn.model.focus {
            if let rect = drawn.model.columnHandleRect(in: drawn.rect), rect.insetBy(dx: -slop, dy: -slop).contains(point) {
                return .columnHandle(block: grid.block, column: focus.column)
            }
            if let rect = drawn.model.rowHandleRect(in: drawn.rect), rect.insetBy(dx: -slop, dy: -slop).contains(point) {
                return .rowHandle(block: grid.block, row: focus.row)
            }
        }
        if let block = hoveredTable, let start = document.blocks[safe: block]?.range.location, let grid = gridTable(at: start), let drawn = gridDrawing(grid) {
            if drawn.model.addColumnRect(in: drawn.rect).insetBy(dx: -slop / 2, dy: 0).contains(point) { return .addColumn(block: grid.block) }
            if drawn.model.addRowRect(in: drawn.rect).insetBy(dx: 0, dy: -slop / 2).contains(point) { return .addRow(block: grid.block) }
        }
        return nil
    }

    /// The table typed in as a grid under the pointer, with the room its + take: they show while it is there.
    func updateTableHover(at point: NSPoint?) {
        var found: Int?
        if let point, !isDrawing, textView.isEditable {
            for block in document.blocks.indices {
                guard case .table = document.blocks[block].kind else { continue }
                let start = document.blocks[block].range.location
                guard start < storage.length, let rect = layoutManager.blockObjectRect(at: start, origin: textOrigin) else { continue }
                if rect.minY > point.y + 40 { break }
                guard rect.insetBy(dx: -10, dy: -10).union(NSRect(x: rect.minX, y: rect.minY, width: rect.width + 30, height: rect.height + 30)).contains(point),
                      gridTable(at: start) != nil else { continue }
                found = block
                break
            }
        }
        guard found != hoveredTable else { return }
        let old = hoveredTable
        hoveredTable = found
        for block in [old, found].compactMap({ $0 }) {
            if let range = document.blocks[safe: block]?.range { linesNeedDisplay([range]) }
        }
    }

    /// What the layout manager draws over a table: the selection in its cell on the Mac, the row or column whose menu
    /// is open, the + while the pointer is over it.
    func tableOverlay(at location: Int) -> TableModel.Overlay {
        var overlay = TableModel.Overlay()
        let block = document.lines.isEmpty ? nil : document.lines[document.lineIndex(containing: location)].block
        overlay.showsAdd = block != nil && block == hoveredTable && textView.isEditable
        overlay.showsHandles = isFocused && textView.isEditable
        if let band = tableBand, band.location == location { overlay.band = band.band }
        #if os(macOS)
        let selection = self.selection
        if selection.length > 0, let block, selection.location >= location, selection.upperBound <= document.blocks[block].range.upperBound {
            overlay.selection = selection
            let isKey = textView.window?.isKeyWindow == true && isFocused
            overlay.selectionColor = isKey ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        }
        #endif
        return overlay
    }

    #if os(macOS)
    /// The handle of the row the caret is in, over the text: half of it is in the margin, where the text system doesn't
    /// draw.
    func drawTableRowHandle(in dirtyRect: NSRect) {
        guard isFocused, textView.isEditable, let grid = activeGrid, let drawn = gridDrawing(grid),
              let handle = drawn.model.rowHandleRect(in: drawn.rect), handle.intersects(dirtyRect),
              let context = NSGraphicsContext.current?.cgContext else { return }
        // The text view leaves its drawing clipped to the text.
        context.saveGState()
        context.resetClip()
        context.clip(to: dirtyRect.intersection(textView.bounds))
        drawn.model.drawRowHandle(in: drawn.rect, band: tableBand?.location == grid.range.location ? tableBand?.band : nil)
        context.restoreGState()
    }
    #endif

    /// Shows a row or column as picked while its handle's menu is open.
    func showTableBand(_ band: TableBand?, block: Int?) {
        let old = tableBand
        tableBand = band.flatMap { band in block.flatMap { document.blocks[safe: $0] }.map { (location: $0.range.location, band: band) } }
        let ranges = [old?.location, tableBand?.location].compactMap { $0 }.map { NSRange(location: $0, length: 1) }
        linesNeedDisplay(ranges)
        marginNeedsDisplay()
    }
}

extension TableEdit {
    var actionName: String {
        switch self {
        case .addRow: "Add Row"
        case .addColumn: "Add Column"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        case .align: "Align Column"
        case .deleteTable: "Delete Table"
        }
    }
}

#if DEBUG
extension EditorController {
    /// For the debug remote: the middle of a letter of a cell of the table the caret is in, or else the first one.
    func debugTablePoint(row: Int, column: Int, letter: Int?) -> CGPoint? {
        let table = activeGrid ?? document.blocks.first { if case .table = $0.kind { true } else { false } }.flatMap { gridTable(at: $0.range.location) }
        guard let table, let drawn = gridDrawing(table), let cell = drawn.model.cellFrame(row: row, column: column, in: drawn.rect) else { return nil }
        guard let letter, let caret = drawn.model.caretRect(row: row, column: column, at: letter, in: drawn.rect),
              let next = drawn.model.caretRect(row: row, column: column, at: letter + 1, in: drawn.rect) else { return CGPoint(x: cell.midX, y: cell.midY) }
        return CGPoint(x: (caret.minX + next.minX) / 2, y: caret.midY)
    }

    /// For the debug remote: where a handle of the table the caret is in is.
    func debugTableHandle(row: Bool) -> CGPoint? {
        guard let grid = activeGrid, let drawn = gridDrawing(grid),
              let rect = row ? drawn.model.rowHandleRect(in: drawn.rect) : drawn.model.columnHandleRect(in: drawn.rect) else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    var debugTableInfo: String {
        guard let grid = activeGrid else { return "table: none (active block \(activeBlock.map(String.init) ?? "nil"))" }
        let cell = grid.cell(at: selection.location)
        let caret = tableCaretRect(at: selection.location)
        let drawn = gridDrawing(grid)
        return "table: \(grid.rows.count)x\(grid.columns), cell \(cell.map { "\($0.row),\($0.column)" } ?? "-"), selection \(selection), caret \(caret.map { "\($0)" } ?? "-"), focus \(drawn?.model.focus.map { "\($0.row),\($0.column)" } ?? "-"), rect \(drawn.map { "\($0.rect)" } ?? "-"), inTable \(caretContext.isInTable)"
    }
}
#endif
