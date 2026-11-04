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

    static let padding = CGSize(width: 12, height: 7)
    static var font: NSFont { EditorStyle.face((EditorStyle.bodySize * 0.93).rounded()) }
    static var headerFont: NSFont { EditorStyle.face((EditorStyle.bodySize * 0.93).rounded(), weight: .semibold) }

    init(text: NSString, lines: [MarkdownLine], alignments: [TableAlignment]) {
        let units = Array((text as String).utf16)
        var rows: [[NSAttributedString]] = []
        var ranges: [[NSRange]] = []
        var signature = ""
        for line in lines where line.kind != .tableDelimiter {
            let cells = MarkdownParser.tableCells(units, line.range)
            let isHeader = line.kind == .tableHeader
            var row: [NSAttributedString] = []
            for index in 0..<alignments.count {
                let source = index < cells.count ? text.substring(with: cells[index]) : ""
                row.append(InlineRenderer.render(
                    source.replacingOccurrences(of: "\\|", with: "|"),
                    font: isHeader ? Self.headerFont : Self.font,
                    color: isHeader ? Theme.text : Theme.textBody
                ))
            }
            rows.append(row)
            ranges.append(cells)
            signature += text.substring(with: line.range) + "\n"
        }
        self.rows = rows
        self.alignments = alignments
        self.cellRanges = ranges
        self.signature = signature
        weights = []
        hasHeader = true
    }

    /// An AsciiDoc table (`|===`), its lines from its attributes to its closing delimiter: cells may run over lines
    /// and span columns, and `cols` sets how wide the columns are.
    init(asciidoc text: NSString, lines: [MarkdownLine], alignments: [TableAlignment]) {
        let units = Array((text as String).utf16)
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
        signature = lines.map { text.substring(with: $0.range) }.joined(separator: "\n")
        weights = spec.weights.count == columns ? spec.weights.map { CGFloat($0) } : []
        hasHeader = header
    }

    struct Layout {
        var columnWidths: [CGFloat]
        var rowHeights: [CGFloat]
        var size: CGSize
    }

    private var cachedLayout: (width: CGFloat, layout: Layout)?

    /// Columns as wide as their widest cell; when that is wider than the page, wide columns give up room first and
    /// their text wraps.
    func layout(maxWidth: CGFloat) -> Layout {
        if let cached = cachedLayout, abs(cached.width - maxWidth) < 0.5 { return cached.layout }
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
        cachedLayout = (maxWidth, layout)
        return layout
    }

    func draw(in rect: CGRect) {
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
