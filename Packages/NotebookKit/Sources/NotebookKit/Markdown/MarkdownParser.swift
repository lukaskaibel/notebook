import Foundation

/// Reads Markdown the way a note uses it: CommonMark and GitHub's tables, task lists and strikethrough, plus
/// Obsidian's `[[links]]`, `![[embeds]]`, callouts and `$math$`. It reads line by line, so every character keeps
/// its place, which is what the live preview needs; it does not try to be a complete CommonMark parser.
public enum MarkdownParser {
    public static func parse(_ string: String, typing: Bool = false) -> MarkdownDocument {
        parse(units: Array(string.utf16), typing: typing)
    }

    /// The same, reading the text out of an `NSString` in one copy rather than one character at a time.
    public static func parse(_ string: NSString, typing: Bool = false) -> MarkdownDocument {
        var units = [UInt16](repeating: 0, count: string.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { string.getCharacters(base, range: NSRange(location: 0, length: string.length)) }
        }
        return parse(units: units, typing: typing)
    }

    /// `typing`: the note is being typed in (see `InlineParser.spans`).
    static func parse(units u: [UInt16], typing: Bool = false) -> MarkdownDocument {
        var lines = splitLines(u)
        var blocks: [MarkdownBlock] = []
        var index = 0
        var listIndents: [Int] = []

        func closeBlock(_ kind: MarkdownBlock.Kind, from first: Int, to last: Int) {
            let start = lines[first].range.location
            let end = lines[last].range.upperBound
            blocks.append(MarkdownBlock(kind: kind, lines: first...last, range: NSRange(location: start, length: end - start)))
            for line in first...last { lines[line].block = blocks.count - 1 }
        }

        // Frontmatter: a `---` on the very first line, closed by `---` or `...`.
        if lines.count > 1, lineText(u, lines[0].range) == "---" {
            if let close = (1..<lines.count).first(where: { ["---", "..."].contains(lineText(u, lines[$0].range)) }) {
                lines[0].kind = .frontmatterDelimiter
                lines[close].kind = .frontmatterDelimiter
                for line in 1..<close { lines[line].kind = .frontmatter }
                closeBlock(.frontmatter, from: 0, to: close)
                index = close + 1
            }
        }

        while index < lines.count {
            let range = lines[index].range
            let indent = leadingIndent(u, range)

            // Fenced code: ``` or ~~~, up to the closing fence or the end of the note.
            if indent.columns <= 3, let fence = fenceOpening(u, range, after: indent.units) {
                lines[index].kind = .fence
                var last = index
                var line = index + 1
                while line < lines.count {
                    if isFenceClose(u, lines[line].range, fence: fence) {
                        lines[line].kind = .fence
                        last = line
                        break
                    }
                    lines[line].kind = .code
                    last = line
                    line += 1
                }
                let language = fence.info.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                closeBlock(language == "mermaid" ? .mermaid : .code(language: language), from: index, to: last)
                index = last + 1
                listIndents = []
                continue
            }

            let trimmed = lineText(u, range).trimmingCharacters(in: .whitespaces)

            // Display math: `$$` on lines of their own, or `$$ … $$` on one line.
            if indent.columns <= 3, trimmed == "$$" {
                if let close = ((index + 1)..<lines.count).first(where: { lineText(u, lines[$0].range).trimmingCharacters(in: .whitespaces) == "$$" }) {
                    lines[index].kind = .mathDelimiter
                    lines[close].kind = .mathDelimiter
                    for line in (index + 1)..<close { lines[line].kind = .math }
                    closeBlock(.math, from: index, to: close)
                    index = close + 1
                    continue
                }
            } else if indent.columns <= 3, trimmed.count > 4, trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") {
                lines[index].kind = .math
                closeBlock(.math, from: index, to: index)
                index += 1
                continue
            }

            // Tables: a row of cells, a delimiter row under it, and rows until a line without a pipe.
            if index + 1 < lines.count, containsPipe(u, range),
               let alignments = delimiterRow(u, lines[index + 1].range),
               tableCells(u, range).count == alignments.count {
                lines[index].kind = .tableHeader
                lines[index + 1].kind = .tableDelimiter
                var last = index + 1
                var line = index + 2
                while line < lines.count, containsPipe(u, lines[line].range), !isBlank(u, lines[line].range) {
                    lines[line].kind = .tableRow
                    last = line
                    line += 1
                }
                closeBlock(.table(alignments: alignments), from: index, to: last)
                index = last + 1
                listIndents = []
                continue
            }

            // Quotes and callouts: consecutive lines starting with `>`.
            if indent.columns <= 3, quotePrefix(u, range) != nil {
                var last = index
                var line = index
                while line < lines.count, let prefix = quotePrefix(u, lines[line].range) {
                    lines[line].kind = .quote(depth: prefix.depth, prefix: prefix.range)
                    lines[line].content = NSRange(location: prefix.range.upperBound, length: lines[line].range.upperBound - prefix.range.upperBound)
                    last = line
                    line += 1
                }
                let firstContent = lineText(u, lines[index].content)
                if let type = calloutType(firstContent) {
                    closeBlock(.callout(type: type), from: index, to: last)
                } else {
                    closeBlock(.quote, from: index, to: last)
                }
                index = last + 1
                listIndents = []
                continue
            }

            lines[index].kind = classifySingle(u, range, indent: indent, listIndents: &listIndents)
            // Four stars alone make a rule, but while the note is typed in they are the empty pair of bold marks that
            // typing `**` puts in, waiting for their text.
            if typing, lines[index].kind == .thematicBreak, lineText(u, range) == "****" { lines[index].kind = .paragraph }
            switch lines[index].kind {
            case .heading(_, let marker):
                lines[index].content = NSRange(location: marker.upperBound, length: range.upperBound - marker.upperBound)
            case .listItem(let item):
                lines[index].content = NSRange(location: item.prefix.upperBound, length: range.upperBound - item.prefix.upperBound)
            case .footnoteDefinition(let label):
                lines[index].content = NSRange(location: label.upperBound, length: range.upperBound - label.upperBound)
            case .paragraph:
                if indent.columns == 0 { listIndents = [] }
            default:
                break
            }
            index += 1
        }

        // A cheap fingerprint of every line, for telling which lines changed.
        for line in lines.indices {
            var hash: UInt64 = 0xcbf29ce484222325
            let range = lines[line].fullRange
            for i in range.location..<min(range.upperBound, u.count) {
                hash = (hash ^ UInt64(u[i])) &* 0x100000001b3
            }
            lines[line].textHash = Int(truncatingIfNeeded: hash)
        }

        // Inline Markdown in every line that holds text.
        for line in lines.indices {
            switch lines[line].kind {
            case .paragraph, .heading, .listItem, .quote, .footnoteDefinition, .tableHeader, .tableRow:
                lines[line].spans = InlineParser.spans(in: u, range: lines[line].content, typing: typing)
            default:
                break
            }
        }
        return MarkdownDocument(lines: lines, blocks: blocks, length: u.count)
    }

    // MARK: - Lines

    static func splitLines(_ u: [UInt16]) -> [MarkdownLine] {
        var result: [MarkdownLine] = []
        var start = 0
        var i = 0
        while i < u.count {
            if u[i] == 10 {
                let end = i > start && u[i - 1] == 13 ? i - 1 : i
                let range = NSRange(location: start, length: end - start)
                result.append(MarkdownLine(range: range, breakLength: i + 1 - end, kind: .paragraph, block: nil, content: range, spans: []))
                start = i + 1
            }
            i += 1
        }
        let range = NSRange(location: start, length: u.count - start)
        result.append(MarkdownLine(range: range, breakLength: 0, kind: .paragraph, block: nil, content: range, spans: []))
        for index in result.indices where isBlank(u, result[index].range) {
            result[index].kind = .blank
        }
        return result
    }

    static func lineText(_ u: [UInt16], _ range: NSRange) -> String {
        String(decoding: u[range.location..<range.upperBound], as: UTF16.self)
    }

    static func isBlank(_ u: [UInt16], _ range: NSRange) -> Bool {
        for i in range.location..<range.upperBound where u[i] != 32 && u[i] != 9 { return false }
        return true
    }

    /// Spaces and tabs at the start of a line: how far they indent (a tab to the next multiple of four) and how
    /// many characters they are.
    static func leadingIndent(_ u: [UInt16], _ range: NSRange) -> (columns: Int, units: Int) {
        var columns = 0
        var units = 0
        var i = range.location
        while i < range.upperBound {
            if u[i] == 32 { columns += 1 } else if u[i] == 9 { columns += 4 - columns % 4 } else { break }
            units += 1
            i += 1
        }
        return (columns, units)
    }

    static func classifySingle(_ u: [UInt16], _ range: NSRange, indent: (columns: Int, units: Int), listIndents: inout [Int]) -> LineKind {
        if isBlank(u, range) { return .blank }
        let start = range.location + indent.units
        let end = range.upperBound

        // ATX heading.
        if indent.columns <= 3, u[start] == 35 {
            var hashes = 0
            var i = start
            while i < end, u[i] == 35 { hashes += 1; i += 1 }
            if hashes <= 6, i == end || u[i] == 32 || u[i] == 9 {
                while i < end, u[i] == 32 || u[i] == 9 { i += 1 }
                return .heading(level: hashes, marker: NSRange(location: range.location, length: i - range.location))
            }
        }

        // Thematic break: three or more of the same `*`, `-` or `_`, spaces allowed.
        if indent.columns <= 3, [42, 45, 95].contains(u[start]) {
            let character = u[start]
            var count = 0
            var only = true
            for i in start..<end {
                if u[i] == character { count += 1 } else if u[i] != 32 && u[i] != 9 { only = false; break }
            }
            if only, count >= 3 { return .thematicBreak }
        }

        // List item, with a checkbox for a task.
        if let item = listItem(u, range, indent: indent, listIndents: &listIndents) {
            return .listItem(item)
        }

        // Footnote definition: [^label]: text
        if indent.columns <= 3, end - start > 4, u[start] == 91, u[start + 1] == 94 {
            var i = start + 2
            while i < end, u[i] != 93, u[i] != 32 { i += 1 }
            if i < end - 1, u[i] == 93, u[i + 1] == 58, i > start + 2 {
                var labelEnd = i + 2
                while labelEnd < end, u[labelEnd] == 32 { labelEnd += 1 }
                return .footnoteDefinition(label: NSRange(location: range.location, length: labelEnd - range.location))
            }
        }
        return .paragraph
    }

    static func listItem(_ u: [UInt16], _ range: NSRange, indent: (columns: Int, units: Int), listIndents: inout [Int]) -> ListItem? {
        let start = range.location + indent.units
        let end = range.upperBound
        guard start < end else { return nil }
        var i = start
        let marker: ListItem.Marker
        if [45, 42, 43].contains(u[i]) {
            marker = .bullet(Character(UnicodeScalar(u[i])!))
            i += 1
        } else {
            var number = 0
            var digits = 0
            while i < end, u[i] >= 48, u[i] <= 57, digits < 9 {
                number = number * 10 + Int(u[i] - 48)
                digits += 1
                i += 1
            }
            guard digits > 0, i < end, u[i] == 46 || u[i] == 41 else { return nil }
            marker = .ordered(number, Character(UnicodeScalar(u[i])!))
            i += 1
        }
        let markerRange = NSRange(location: start, length: i - start)
        // A marker needs a space after it, or nothing at all (an item still empty).
        guard i == end || u[i] == 32 || u[i] == 9 else { return nil }
        while i < end, u[i] == 32 || u[i] == 9 { i += 1 }

        var checkbox: NSRange?
        var checked = false
        if i + 3 <= end, u[i] == 91, u[i + 2] == 93, [32, 120, 88].contains(u[i + 1]),
           i + 3 == end || u[i + 3] == 32 || u[i + 3] == 9 {
            checkbox = NSRange(location: i, length: 3)
            checked = u[i + 1] != 32
            i += 3
            while i < end, u[i] == 32 || u[i] == 9 { i += 1 }
        }

        while let last = listIndents.last, last > indent.columns { listIndents.removeLast() }
        if listIndents.last != indent.columns { listIndents.append(indent.columns) }
        let level = listIndents.count - 1

        return ListItem(
            indent: indent.columns,
            level: level,
            indentRange: NSRange(location: range.location, length: indent.units),
            marker: marker,
            markerRange: markerRange,
            prefix: NSRange(location: range.location, length: i - range.location),
            checkbox: checkbox,
            checked: checked
        )
    }

    // MARK: - Fences

    struct Fence {
        var character: UInt16
        var length: Int
        var info: String
    }

    static func fenceOpening(_ u: [UInt16], _ range: NSRange, after indent: Int) -> Fence? {
        let start = range.location + indent
        let end = range.upperBound
        guard start < end, u[start] == 96 || u[start] == 126 else { return nil }
        let character = u[start]
        var i = start
        while i < end, u[i] == character { i += 1 }
        let length = i - start
        guard length >= 3 else { return nil }
        let info = lineText(u, NSRange(location: i, length: end - i)).trimmingCharacters(in: .whitespaces)
        if character == 96, info.contains("`") { return nil }
        return Fence(character: character, length: length, info: info)
    }

    static func isFenceClose(_ u: [UInt16], _ range: NSRange, fence: Fence) -> Bool {
        let indent = leadingIndent(u, range)
        guard indent.columns <= 3 else { return false }
        var i = range.location + indent.units
        let end = range.upperBound
        var count = 0
        while i < end, u[i] == fence.character { count += 1; i += 1 }
        guard count >= fence.length else { return false }
        while i < end { if u[i] != 32 && u[i] != 9 { return false }; i += 1 }
        return true
    }

    // MARK: - Quotes

    static func quotePrefix(_ u: [UInt16], _ range: NSRange) -> (depth: Int, range: NSRange)? {
        var i = range.location
        let end = range.upperBound
        var spaces = 0
        while i < end, u[i] == 32, spaces < 3 { i += 1; spaces += 1 }
        guard i < end, u[i] == 62 else { return nil }
        var depth = 0
        while i < end, u[i] == 62 {
            depth += 1
            i += 1
            if i < end, u[i] == 32 { i += 1 }
            // Nested quotes may be written "> >".
            var look = i
            while look < end, u[look] == 32 { look += 1 }
            if look < end, u[look] == 62 { i = look }
        }
        return (depth, NSRange(location: range.location, length: i - range.location))
    }

    /// `[!note]`, `[!tip]-` and the like at the start of a quote make it a callout.
    static func calloutType(_ content: String) -> String? {
        guard content.hasPrefix("[!"), let close = content.firstIndex(of: "]") else { return nil }
        let type = content[content.index(content.startIndex, offsetBy: 2)..<close]
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return type.lowercased()
    }

    // MARK: - Tables

    static func containsPipe(_ u: [UInt16], _ range: NSRange) -> Bool {
        var i = range.location
        while i < range.upperBound {
            if u[i] == 92 { i += 2; continue }
            if u[i] == 124 { return true }
            i += 1
        }
        return false
    }

    /// The cells of a table row: the ranges between pipes, without the outer pipes and the spaces around the text.
    public static func tableCells(_ u: [UInt16], _ range: NSRange) -> [NSRange] {
        var cells: [NSRange] = []
        var start = range.location
        var end = range.upperBound
        while start < end, u[start] == 32 || u[start] == 9 { start += 1 }
        while end > start, u[end - 1] == 32 || u[end - 1] == 9 { end -= 1 }
        if start < end, u[start] == 124 { start += 1 }
        if end > start, u[end - 1] == 124, end - 2 < start || u[end - 2] != 92 { end -= 1 }
        var cellStart = start
        var i = start
        var inCode = false
        while i <= end {
            if i == end || (u[i] == 124 && !inCode) {
                var a = cellStart, b = i
                while a < b, u[a] == 32 || u[a] == 9 { a += 1 }
                while b > a, u[b - 1] == 32 || u[b - 1] == 9 { b -= 1 }
                cells.append(NSRange(location: a, length: b - a))
                cellStart = i + 1
            } else if u[i] == 92 {
                i += 1
            } else if u[i] == 96 {
                inCode.toggle()
            }
            i += 1
        }
        return cells
    }

    static func delimiterRow(_ u: [UInt16], _ range: NSRange) -> [TableAlignment]? {
        guard containsPipe(u, range) || lineText(u, range).contains("-") else { return nil }
        var alignments: [TableAlignment] = []
        for cell in tableCells(u, range) {
            let text = lineText(u, cell)
            guard !text.isEmpty else { return nil }
            let left = text.hasPrefix(":")
            let right = text.hasSuffix(":")
            let dashes = text.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }
}
