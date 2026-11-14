#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A Markdown table, ready to draw: the cells as styled text and, for each, where its Markdown is, so a click on a
/// cell can put the caret in it.
@MainActor
final class TableModel {
    let rows: [[NSAttributedString]]
    let alignments: [TableAlignment]
    /// For each drawn row (the header first), the ranges of its cells in the note.
    let cellRanges: [[NSRange]]
    let signature: String
    /// How wide the columns are relative to each other, as AsciiDoc's `cols` says; empty to fit them to their text.
    let weights: [CGFloat]
    /// The first row is a header, tinted. AsciiDoc tables may have none.
    let hasHeader: Bool

    /// Typed in as a grid (a Markdown table whose rows all have its columns): for each drawn row and column, where
    /// its text is in the note, or for an empty cell where typing goes, and for each place in that text the place in
    /// what the cell shows. Empty for other tables.
    let contents: [[NSRange]]
    let maps: [[[Int]]]
    /// The cell the caret is in, while the table is typed in.
    let focus: Focus?

    struct Focus: Equatable {
        var row: Int
        var column: Int
        /// The spans of the cell whose marks show, relative to its text: those next to the caret, with a keyboard.
        var revealing: [NSRange] = []
    }

    static let padding = CGSize(width: 12, height: 7)
    static var font: NSFont { EditorStyle.face((EditorStyle.bodySize * 0.93).rounded()) }
    static var headerFont: NSFont { EditorStyle.face((EditorStyle.bodySize * 0.93).rounded(), weight: .semibold) }

    init(text: NSString, lines: [MarkdownLine], alignments: [TableAlignment], focus: Focus? = nil) {
        let units = text.units(of: lines)
        var rows: [[NSAttributedString]] = []
        var ranges: [[NSRange]] = []
        var contents: [[NSRange]] = []
        var maps: [[[Int]]] = []
        var signature = ""
        let grid = Self.fitsGrid(units, lines: lines, columns: alignments.count)
        for line in lines where line.kind != .tableDelimiter {
            let slots = MarkdownParser.tableSlots(units, line.range)
            let cells = MarkdownParser.tableCells(units, line.range)
            let isHeader = line.kind == .tableHeader
            let rowIndex = rows.count
            var row: [NSAttributedString] = []
            var rowMaps: [[Int]] = []
            for index in 0..<alignments.count {
                let source = index < cells.count ? text.substring(with: cells[index]) : ""
                let revealing = focus.flatMap { $0.row == rowIndex && $0.column == index ? $0.revealing : nil } ?? []
                let rendered = InlineRenderer.renderMapped(source, font: isHeader ? Self.headerFont : Self.font,
                                                           color: isHeader ? Theme.text : Theme.textBody, revealing: revealing)
                row.append(rendered.shown)
                rowMaps.append(rendered.map)
            }
            rows.append(row)
            ranges.append(cells)
            if grid {
                contents.append(zip(slots, cells).map { slot, cell in Self.content(of: cell, in: slot, units) })
                maps.append(rowMaps)
            }
            signature += text.substring(with: line.range) + "\n"
        }
        self.rows = rows
        self.alignments = alignments
        self.cellRanges = ranges
        self.contents = contents
        self.maps = maps
        self.focus = grid ? focus : nil
        self.signature = signature + (focus.map { "\($0.row),\($0.column),\($0.revealing)" } ?? "")
        weights = []
        hasHeader = true
    }

    /// Whether a table is typed in as a grid: every row has as many cells as the table has columns. A row with more
    /// would lose the cells the grid can't show, one with fewer has nowhere for what is typed in the rest: such a
    /// table shows its Markdown, as all of them do with Settings › Text › Edit tables as Markdown.
    /// A row being written by hand, its closing pipe still to come where the header has one, shows its Markdown too.
    nonisolated static func fitsGrid(_ units: [UInt16], lines: [MarkdownLine], columns: Int) -> Bool {
        func closes(_ range: NSRange) -> Bool {
            var end = range.upperBound
            while end > range.location, units[end - 1] == 32 || units[end - 1] == 9 { end -= 1 }
            return end > range.location && units[end - 1] == 124 && (end - 2 < range.location || units[end - 2] != 92)
        }
        guard let first = lines.first else { return false }
        let closed = closes(first.range)
        return lines.allSatisfy { MarkdownParser.tableSlots(units, $0.range).count == columns && closes($0.range) == closed }
    }

    /// Where a cell's text is, or in an empty cell where typing goes: after the space that follows the pipe, as Tab
    /// leaves it.
    nonisolated static func content(of cell: NSRange, in slot: NSRange, _ units: [UInt16]) -> NSRange {
        guard cell.length == 0 else { return cell }
        return NSRange(location: slot.length > 0 && units[slot.location] == 32 ? slot.location + 1 : slot.location, length: 0)
    }

    /// An AsciiDoc table (`|===`), its lines from its attributes to its closing delimiter: cells may run over lines
    /// and span columns, and `cols` sets how wide the columns are.
    init(asciidoc text: NSString, lines: [MarkdownLine], alignments: [TableAlignment]) {
        let units = text.units(of: lines)
        let attributes = lines.filter { $0.kind == .markup }.compactMap { line -> String? in
            let trimmed = text.substring(with: line.range).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : nil
        }
        let spec = AsciiDocTable.Spec(attributes: attributes)
        let delimiters = lines.indices.filter { lines[$0].kind == .tableDelimiter }
        let open = delimiters.first ?? 0
        let close = delimiters.count > 1 ? delimiters[delimiters.count - 1] : lines.count
        let separator = lines.indices.contains(open) && lines[open].range.length > 0 ? units[lines[open].range.location] : 124
        let columns = max(1, alignments.count)
        let found = AsciiDocTable.rows(units, lines: lines, inner: (open + 1)..<max(open + 1, close), separator: separator, columns: columns)
        let header = lines.contains { $0.kind == .tableHeader }
        var rows: [[NSAttributedString]] = []
        var ranges: [[NSRange]] = []
        for (index, row) in found.enumerated() {
            let isHeader = header && index == 0
            var drawn: [NSAttributedString] = []
            var cells: [NSRange] = []
            for cell in row.cells {
                // Lines of a cell run on as one paragraph; a blank line between them starts another.
                let source = text.substring(with: cell.range)
                    .replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\u{2029}", options: .regularExpression)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\u{2029}", with: "\n")
                    .replacingOccurrences(of: "\\" + String(UnicodeScalar(separator)!), with: String(UnicodeScalar(separator)!))
                drawn.append(InlineRenderer.render(source, font: isHeader ? Self.headerFont : Self.font, color: isHeader ? Theme.text : Theme.textBody, syntax: .asciidoc))
                cells.append(cell.range)
                for _ in 1..<max(1, cell.span) {
                    drawn.append(NSAttributedString())
                    cells.append(NSRange(location: cell.range.upperBound, length: 0))
                }
            }
            if drawn.count < columns {
                drawn += Array(repeating: NSAttributedString(), count: columns - drawn.count)
                cells += Array(repeating: NSRange(location: row.cells.last?.range.upperBound ?? 0, length: 0), count: columns - cells.count)
            }
            rows.append(Array(drawn.prefix(columns)))
            ranges.append(Array(cells.prefix(columns)))
        }
        if rows.isEmpty {
            rows = [Array(repeating: NSAttributedString(), count: columns)]
            ranges = [Array(repeating: NSRange(location: lines.first?.range.location ?? 0, length: 0), count: columns)]
        }
        self.rows = rows
        self.alignments = Array((alignments + Array(repeating: .leading, count: columns)).prefix(columns))
        cellRanges = ranges
        contents = []
        maps = []
        focus = nil
        signature = lines.map { text.substring(with: $0.range) }.joined(separator: "\n")
        weights = spec.weights.count == columns ? spec.weights.map { CGFloat($0) } : []
        hasHeader = header
    }

    struct Layout {
        var columnWidths: [CGFloat]
        var rowHeights: [CGFloat]
        var size: CGSize
    }

    /// Layouts made, by the width they were made for: layout asks for the page's width and drawing for the table's
    /// own, so one alone was made again on every frame the table is in.
    private var cachedLayouts: [(width: CGFloat, layout: Layout)] = []

    /// Columns as wide as their widest cell; when that is wider than the page, wide columns give up room first and
    /// their text wraps.
    func layout(maxWidth: CGFloat) -> Layout {
        if let cached = cachedLayouts.first(where: { abs($0.width - maxWidth) < 0.5 }) { return cached.layout }
        let columns = alignments.count
        var natural = Array(repeating: CGFloat(40), count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columns {
                let width = ceil(cell.boundingRect(with: CGSize(width: 10_000, height: 1_000), options: [.usesLineFragmentOrigin], context: nil).width)
                natural[index] = max(natural[index], width + Self.padding.width * 2)
            }
        }
        var widths = natural
        let total = natural.reduce(0, +)
        if weights.count == columns, columns > 0 {
            // As wide as the page, the columns sharing it as `cols` says, none narrower than a word or two.
            let sum = weights.reduce(0, +)
            widths = weights.map { max(56, floor(maxWidth * $0 / max(1, sum))) }
            let over = widths.reduce(0, +) - maxWidth
            if over > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[widest] -= over }
        } else if total > maxWidth {
            let minimum: CGFloat = 72
            var excess = total - maxWidth
            while excess > 0.5 {
                let shrinkable = widths.indices.filter { widths[$0] > minimum }
                guard !shrinkable.isEmpty else { break }
                let share = excess / CGFloat(shrinkable.count)
                for index in shrinkable {
                    let cut = min(share, widths[index] - minimum)
                    widths[index] -= cut
                    excess -= cut
                }
            }
        }
        var heights: [CGFloat] = []
        for row in rows {
            var height: CGFloat = 0
            for (index, cell) in row.enumerated() where index < columns {
                let textWidth = widths[index] - Self.padding.width * 2
                let rect = cell.boundingRect(with: CGSize(width: max(10, textWidth), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                height = max(height, ceil(rect.height))
            }
            heights.append(max(height, 18) + Self.padding.height * 2)
        }
        let layout = Layout(columnWidths: widths, rowHeights: heights, size: CGSize(width: ceil(widths.reduce(0, +)), height: ceil(heights.reduce(0, +))))
        cachedLayouts.append((maxWidth, layout))
        if cachedLayouts.count > 4 { cachedLayouts.removeFirst() }
        return layout
    }

    /// What is drawn over a table while it is typed in, beyond the cell the caret is in: the text selected in its cell
    /// (the Mac's; UIKit draws its own), a row or column picked by its handle, and the + along its edges while the
    /// pointer is over it.
    struct Overlay {
        var selection: NSRange?
        var selectionColor: NSColor = Theme.accent.withAlphaComponent(0.25)
        var band: TableBand?
        /// What Delete, pressed again, takes: tinted red, with a button that deletes it, named by `deleteTitle`.
        var deleting: TableDeletion?
        var deleteTitle = ""
        var showsAdd = false
        var showsHandles = true
        /// The Mac's text view keeps its text from the margin, where half of the row's handle is: it draws that one
        /// itself, over the text (`drawRowHandle`).
        var drawsRowHandle = true
    }

    func draw(in rect: CGRect, overlay: Overlay = Overlay()) {
        let layout = layout(maxWidth: rect.width)
        let frame = CGRect(origin: rect.origin, size: layout.size)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.card.setFill()
        outline.fill()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        // A tinted header and every other row striped; only the columns are ruled.
        var y = frame.minY
        for (index, height) in layout.rowHeights.enumerated() {
            if index == 0, hasHeader {
                Theme.tableHeader.setFill()
                CGRect(x: frame.minX, y: y, width: frame.width, height: height).fill()
            } else if index % 2 == (hasHeader ? 0 : 1) {
                Theme.tableStripe.setFill()
                CGRect(x: frame.minX, y: y, width: frame.width, height: height).fill()
            }
            y += height
        }
        if let band = overlay.band {
            Theme.accent.withAlphaComponent(0.12).setFill()
            switch band {
            case .row(let row): if let cell = cellFrame(row: row, column: 0, in: rect) { CGRect(x: frame.minX, y: cell.minY, width: frame.width, height: cell.height).fill() }
            case .column(let column): if let cell = cellFrame(row: 0, column: column, in: rect) { CGRect(x: cell.minX, y: frame.minY, width: cell.width, height: frame.height).fill() }
            }
        }
        if let deleting = overlay.deleting, let area = area(of: deleting, in: rect) {
            Self.deleteColor.withAlphaComponent(0.1).setFill()
            area.fill()
        }
        if let selection = overlay.selection {
            overlay.selectionColor.setFill()
            for box in selectionBoxes(for: selection, in: rect) { box.fill() }
        }
        Theme.cardBorder.setFill()
        var x = frame.minX
        for (index, width) in layout.columnWidths.enumerated() {
            if index > 0 { CGRect(x: x, y: frame.minY, width: 1, height: frame.height).fill() }
            x += width
        }

        y = frame.minY
        for (rowIndex, row) in rows.enumerated() {
            x = frame.minX
            let height = layout.rowHeights[rowIndex]
            for (index, cell) in row.enumerated() where index < layout.columnWidths.count {
                let width = layout.columnWidths[index]
                let textWidth = width - Self.padding.width * 2
                let size = cell.boundingRect(with: CGSize(width: max(10, textWidth), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
                var originX = x + Self.padding.width
                switch alignments[index] {
                case .center: originX = x + (width - min(size.width, textWidth)) / 2
                case .trailing: originX = x + width - Self.padding.width - min(size.width, textWidth)
                case .leading: break
                }
                cell.draw(with: CGRect(x: originX, y: y + Self.padding.height, width: textWidth, height: height - Self.padding.height * 2),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                x += width
            }
            y += height
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.cardBorder.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        if let focus, let cell = cellFrame(row: focus.row, column: focus.column, in: rect) {
            // The cell you type in, ringed as a field you type in is; its corner rounded where the table's is.
            let ring = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            Theme.accent.setStroke()
            ring.stroke()
            if overlay.showsHandles {
                if let handle = columnHandleRect(in: rect) {
                    let marked = overlay.deleting == .column(focus.column) || overlay.deleting == .table
                    Self.drawHandle(in: handle, vertical: false, picked: overlay.band == .column(focus.column) || marked, deleting: marked)
                }
                if overlay.drawsRowHandle { drawRowHandle(in: rect, band: overlay.band, deleting: overlay.deleting) }
            }
        }
        if let deleting = overlay.deleting, let button = deleteButtonRect(deleting, title: overlay.deleteTitle, in: rect) {
            Self.drawDeleteButton(in: button, title: overlay.deleteTitle)
        }
        if overlay.showsAdd {
            for (bar, vertical) in [(addColumnRect(in: rect), true), (addRowRect(in: rect), false)] {
                Theme.tableStripe.blended(withFraction: 0.5, of: Theme.cardBorder)?.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
                let side: CGFloat = 9
                let center = CGPoint(x: bar.midX, y: vertical ? min(bar.midY, bar.minY + 40) : bar.midY)
                Theme.textTertiary.setFill()
                CGRect(x: center.x - side / 2, y: center.y - 0.75, width: side, height: 1.5).fill()
                CGRect(x: center.x - 0.75, y: center.y - side / 2, width: 1.5, height: side).fill()
            }
        }
    }

    /// The handle across the left edge of the row the caret is in.
    func drawRowHandle(in rect: CGRect, band: TableBand?, deleting: TableDeletion? = nil) {
        guard let focus, let handle = rowHandleRect(in: rect) else { return }
        let marked = deleting == .row(focus.row) || deleting == .table
        Self.drawHandle(in: handle, vertical: true, picked: band == .row(focus.row) || marked, deleting: marked)
    }

    /// A handle: a capsule with three dots, across a column's top edge or a row's left one. Red while what it is for
    /// is marked to be deleted.
    static func drawHandle(in rect: CGRect, vertical: Bool, picked: Bool, deleting: Bool = false) {
        let capsule = NSBezierPath(roundedRect: rect, xRadius: min(rect.width, rect.height) / 2, yRadius: min(rect.width, rect.height) / 2)
        let tint = deleting ? deleteColor : Theme.accent
        (picked ? tint : Theme.card).setFill()
        capsule.fill()
        capsule.lineWidth = 1
        (picked ? tint : Theme.cardBorder.blended(withFraction: 0.3, of: Theme.textTertiary) ?? Theme.cardBorder).setStroke()
        capsule.stroke()
        (picked ? NSColor.white : Theme.textSecondary).setFill()
        for step in -1...1 {
            let center = vertical ? CGPoint(x: rect.midX, y: rect.midY + CGFloat(step) * 4.5) : CGPoint(x: rect.midX + CGFloat(step) * 4.5, y: rect.midY)
            NSBezierPath(ovalIn: CGRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5)).fill()
        }
    }

    // MARK: - Typing in the grid

    /// Where a cell is, in a table drawn in `rect`.
    func cellFrame(row: Int, column: Int, in rect: CGRect) -> CGRect? {
        let layout = layout(maxWidth: rect.width)
        guard layout.rowHeights.indices.contains(row), layout.columnWidths.indices.contains(column) else { return nil }
        return CGRect(x: rect.minX + layout.columnWidths[..<column].reduce(0, +), y: rect.minY + layout.rowHeights[..<row].reduce(0, +),
                      width: layout.columnWidths[column], height: layout.rowHeights[row])
    }

    /// Where a cell's text is drawn: inside its padding, moved over as its column is aligned.
    func textFrame(row: Int, column: Int, in rect: CGRect) -> CGRect? {
        guard let cell = cellFrame(row: row, column: column, in: rect), let text = rows[safe: row]?[safe: column] else { return nil }
        let width = max(10, cell.width - Self.padding.width * 2)
        let size = text.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        var x = cell.minX + Self.padding.width
        switch alignments[safe: column] ?? .leading {
        case .center: x = cell.minX + (cell.width - min(size.width, width)) / 2
        case .trailing: x = cell.maxX - Self.padding.width - min(size.width, width)
        case .leading: break
        }
        return CGRect(x: x, y: cell.minY + Self.padding.height, width: width, height: cell.height - Self.padding.height * 2)
    }

    /// The caret at a place in what a cell shows: as tall as its text, from above the letters to below them.
    func caretRect(row: Int, column: Int, at offset: Int, in rect: CGRect) -> CGRect? {
        guard let frame = textFrame(row: row, column: column, in: rect), let text = rows[safe: row]?[safe: column] else { return nil }
        let fallback = row == 0 && hasHeader ? Self.headerFont : Self.font
        return CellText.measure(text, width: frame.width) { layout, container in
            let length = text.length
            let place = min(max(0, offset), length)
            guard length > 0 else {
                return Self.caret(x: frame.minX, baseline: frame.minY + layout.defaultBaselineOffsetFor(fallback), font: fallback)
            }
            let character = place < length ? place : length - 1
            let glyph = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layout.location(forGlyphAt: glyph)
            var x = line.minX + location.x
            if place == length {
                x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
            }
            let font = (text.attribute(.font, at: character, effectiveRange: nil) as? NSFont) ?? fallback
            return Self.caret(x: frame.minX + x, baseline: frame.minY + line.minY + location.y, font: font)
        }
    }

    private static func caret(x: CGFloat, baseline: CGFloat, font: NSFont) -> CGRect {
        CGRect(x: x, y: baseline - font.ascender - 1, width: 2, height: font.ascender - font.descender + 2)
    }

    /// The place in what a cell shows nearest a point, as a click puts the caret there.
    func offset(row: Int, column: Int, at point: CGPoint, in rect: CGRect) -> Int {
        guard let frame = textFrame(row: row, column: column, in: rect), let text = rows[safe: row]?[safe: column], text.length > 0 else { return 0 }
        return CellText.measure(text, width: frame.width) { layout, container in
            let local = CGPoint(x: point.x - frame.minX, y: min(max(point.y - frame.minY, 0), max(0, layout.usedRect(for: container).height - 1)))
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let character = layout.characterIndexForGlyph(at: glyph)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            // Past the end of a line, the caret goes after its last letter.
            if local.x >= line.maxX { return min(text.length, NSMaxRange(layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: line, in: container), actualGlyphRange: nil))) }
            return min(text.length, character + (fraction > 0.5 ? 1 : 0))
        }
    }

    /// The place on the line above or below in a cell whose text wraps, nearest `x`; nil on its first or last line.
    func offset(row: Int, column: Int, from offset: Int, lines direction: Int, x: CGFloat, in rect: CGRect) -> Int? {
        guard let frame = textFrame(row: row, column: column, in: rect), let text = rows[safe: row]?[safe: column], text.length > 0,
              let caret = caretRect(row: row, column: column, at: offset, in: rect) else { return nil }
        let lineHeight = caret.height
        let target = CGPoint(x: x, y: direction < 0 ? caret.minY - lineHeight / 2 : caret.maxY + lineHeight / 2)
        guard target.y >= frame.minY - 1, target.y <= frame.minY + CellText.measure(text, width: frame.width, { $0.usedRect(for: $1).height }) + 1 else { return nil }
        return self.offset(row: row, column: column, at: target, in: rect)
    }

    /// The boxes a selection in a cell is drawn in, as the text of a note is: `range` is in the note.
    func selectionRects(row: Int, column: Int, range: NSRange, in rect: CGRect) -> [CGRect] {
        guard let content = contents[safe: row]?[safe: column], let map = maps[safe: row]?[safe: column],
              let frame = textFrame(row: row, column: column, in: rect), let text = rows[safe: row]?[safe: column] else { return [] }
        let start = max(range.location, content.location) - content.location
        let end = min(range.upperBound, content.upperBound) - content.location
        guard end > start, start >= 0, end < map.count else { return [] }
        let shown = NSRange(location: map[start], length: map[end] - map[start])
        guard shown.length > 0 else { return [] }
        return CellText.measure(text, width: frame.width) { layout, container in
            var rects: [CGRect] = []
            let glyphs = layout.glyphRange(forCharacterRange: shown, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { box, _ in
                rects.append(box.offsetBy(dx: frame.minX, dy: frame.minY))
            }
            return rects
        }
    }

    /// What a selection takes in the grid: the text selected in one cell, or every cell a selection over several
    /// of them reaches into, whole.
    func selectionBoxes(for range: NSRange, in rect: CGRect) -> [CGRect] {
        var touched: [(row: Int, column: Int)] = []
        for (row, cells) in contents.enumerated() {
            for (column, content) in cells.enumerated() {
                if NSIntersectionRange(range, content).length > 0 || (content.length == 0 && content.location > range.location && content.location < range.upperBound) {
                    touched.append((row, column))
                }
            }
        }
        if touched.count == 1, let only = touched.first { return selectionRects(row: only.row, column: only.column, range: range, in: rect) }
        return touched.compactMap { cellFrame(row: $0.row, column: $0.column, in: rect)?.insetBy(dx: 1, dy: 1) }
    }

    // MARK: - Handles and the + along the edges

    /// Across the top edge of the column the caret is in, as in Notes.
    func columnHandleRect(in rect: CGRect) -> CGRect? {
        guard let focus, let cell = cellFrame(row: 0, column: focus.column, in: rect) else { return nil }
        return CGRect(x: cell.midX - 13, y: cell.minY - 6, width: 26, height: 12)
    }

    /// Across the left edge of the row the caret is in.
    func rowHandleRect(in rect: CGRect) -> CGRect? {
        guard let focus, let cell = cellFrame(row: focus.row, column: 0, in: rect) else { return nil }
        return CGRect(x: cell.minX - 6, y: cell.midY - 13, width: 12, height: 26)
    }

    /// Along the right edge: adds a column at the end.
    func addColumnRect(in rect: CGRect) -> CGRect {
        let size = layout(maxWidth: rect.width).size
        return CGRect(x: rect.minX + size.width + 5, y: rect.minY, width: 16, height: size.height)
    }

    /// Along the bottom edge: adds a row at the end.
    func addRowRect(in rect: CGRect) -> CGRect {
        let size = layout(maxWidth: rect.width).size
        return CGRect(x: rect.minX, y: rect.minY + size.height + 5, width: size.width, height: 16)
    }

    // MARK: - Deleting an empty row or column

    static var deleteColor: NSColor { .systemRed }
    private static var deleteFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }

    /// The row, column or table marked to be deleted, as drawn in `rect`.
    func area(of deletion: TableDeletion, in rect: CGRect) -> CGRect? {
        let size = layout(maxWidth: rect.width).size
        let frame = CGRect(origin: rect.origin, size: size)
        switch deletion {
        case .row(let row):
            guard let cell = cellFrame(row: row, column: 0, in: rect) else { return nil }
            return CGRect(x: frame.minX, y: cell.minY, width: frame.width, height: cell.height)
        case .column(let column):
            guard let cell = cellFrame(row: 0, column: column, in: rect) else { return nil }
            return CGRect(x: cell.minX, y: frame.minY, width: cell.width, height: frame.height)
        case .table:
            return frame
        }
    }

    /// The button that deletes what is marked: in the middle of it, which holds nothing, inside the text's width.
    func deleteButtonRect(_ deletion: TableDeletion, title: String, in rect: CGRect) -> CGRect? {
        guard let area = area(of: deletion, in: rect) else { return nil }
        let text = (title as NSString).size(withAttributes: [.font: Self.deleteFont])
        let size = CGSize(width: ceil(text.width) + 20, height: 22)
        var x = area.midX - size.width / 2
        x = max(rect.minX, min(x, rect.maxX - size.width))
        return CGRect(x: x.rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// Over a column it may lie across the text of the cells beside it: it floats over them, ringed in the table's
    /// colour and with a shadow, as a popover would.
    static func drawDeleteButton(in rect: CGRect, title: String) {
        #if os(macOS)
        let context = NSGraphicsContext.current?.cgContext
        #else
        let context = UIGraphicsGetCurrentContext()
        #endif
        let halo = rect.insetBy(dx: -2, dy: -2)
        context?.saveGState()
        context?.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        Theme.card.setFill()
        NSBezierPath(roundedRect: halo, xRadius: halo.height / 2, yRadius: halo.height / 2).fill()
        context?.restoreGState()
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        deleteColor.setFill()
        capsule.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: deleteFont, .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// Where a row is drawn, the header first, in a table drawn in `rect`.
    func rowRect(_ row: Int, in rect: CGRect) -> CGRect? {
        let heights = layout(maxWidth: rect.width).rowHeights
        guard heights.indices.contains(row) else { return nil }
        return CGRect(x: rect.minX, y: rect.minY + heights[..<row].reduce(0, +), width: rect.width, height: heights[row])
    }

    /// The cell at a point in a table drawn at `rect`: its row (0 is the header) and column.
    func cell(at point: CGPoint, in rect: CGRect) -> (row: Int, column: Int)? {
        let layout = layout(maxWidth: rect.width)
        var y = rect.minY
        for (rowIndex, height) in layout.rowHeights.enumerated() {
            if point.y >= y, point.y < y + height {
                var x = rect.minX
                for (columnIndex, width) in layout.columnWidths.enumerated() {
                    if point.x >= x, point.x < x + width { return (rowIndex, columnIndex) }
                    x += width
                }
                return (rowIndex, max(0, layout.columnWidths.count - 1))
            }
            y += height
        }
        return nil
    }
}

extension NSString {
    /// The UTF-16 units of these lines (a table's), at their places in the text, the rest left 0: one copy of the
    /// part, where the whole note read a character at a time for every table took seconds in a note of many tables.
    func units(of lines: [MarkdownLine]) -> [UInt16] {
        let start = min(length, lines.first?.range.location ?? 0)
        let end = min(length, max(start, lines.last?.fullRange.upperBound ?? 0))
        var units = [UInt16](repeating: 0, count: end)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress, end > start { getCharacters(base + start, range: NSRange(location: start, length: end - start)) }
        }
        return units
    }
}

/// A row or a column picked by its handle, shown while its menu is open.
enum TableBand: Equatable {
    case row(Int)
    case column(Int)
}

/// What Delete pressed in an empty cell marks to go, pressed again: the cell's row when nothing is in it, else its
/// column, or the whole table when none of its cells holds anything.
enum TableDeletion: Equatable {
    case row(Int)
    case column(Int)
    case table
}

/// One TextKit stack, its text swapped for each cell measured: where the caret goes in a cell, what a click hits,
/// what a selection covers. Laid out as `NSAttributedString` draws a cell, so the caret sits where its letters are.
@MainActor
enum CellText {
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: CGSize(width: 100, height: 10_000))
        container.lineFragmentPadding = 0
        return container
    }()
    private static let layout: NSLayoutManager = {
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return layout
    }()

    static func measure<T>(_ text: NSAttributedString, width: CGFloat, _ body: (NSLayoutManager, NSTextContainer) -> T) -> T {
        let layout = self.layout
        if storage.length != text.length || !storage.isEqual(to: text) { storage.setAttributedString(text) }
        if container.size.width != width { container.size = CGSize(width: width, height: 10_000) }
        layout.ensureLayout(for: container)
        return body(layout, container)
    }
}

extension NSLayoutManager {
    /// Where the baseline of an empty line of this font is, from its top.
    func defaultBaselineOffsetFor(_ font: NSFont) -> CGFloat {
        #if os(macOS)
        defaultBaselineOffset(for: font)
        #else
        font.ascender
        #endif
    }
}
