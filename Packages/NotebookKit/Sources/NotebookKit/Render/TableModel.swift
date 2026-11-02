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
        if total > maxWidth {
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
            if index == 0 {
                Theme.tableHeader.setFill()
                CGRect(x: frame.minX, y: y, width: frame.width, height: height).fill()
            } else if index % 2 == 0 {
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
