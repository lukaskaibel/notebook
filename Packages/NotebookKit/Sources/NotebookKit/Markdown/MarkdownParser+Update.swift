import Foundation

/// Reading a note again after an edit without reading all of it: from a line above the edit where reading could start
/// again, to a line below it where the new reading is in the same state as the old one was. From there on the text is
/// the same, so it reads as before: the old lines and blocks are kept, moved along by the edit. The result is what
/// `parse` makes of the whole text (`IncrementalParsingTests`).
extension MarkdownParser {
    /// A note read again after an edit, and which of its lines and blocks are the old ones.
    struct Update {
        var document: MarkdownDocument
        /// The lines before this one are the old ones, where they were, and so are the blocks before `blockStart`.
        var start: Int
        var blockStart: Int
        /// The lines from this one on are the old ones from `oldEnd` on, moved along by the edit, and the blocks from
        /// `blockEnd` on the old ones from `oldBlockEnd` on.
        var end: Int
        var oldEnd: Int
        var blockEnd: Int
        var oldBlockEnd: Int

        /// The new index of an old block that was kept, nil for one read again.
        func block(fromOld block: Int) -> Int? {
            if block < blockStart { return block }
            if block >= oldBlockEnd { return block - oldBlockEnd + blockEnd }
            return nil
        }
    }

    /// Reads a note again after an edit: `old` was read from the text before it, `edited` is the range of the changed
    /// characters in the new text and `delta` the change in length, as `NSTextStorage` tells them. A note that `old`
    /// read in another syntax, or the other way for typing (`MarkdownDocument.typing`), is read whole.
    static func update(_ old: MarkdownDocument, _ string: NSString, edited: NSRange, changeInLength delta: Int, typing: Bool,
                       syntax: NoteSyntax) -> Update {
        update(old, units: units(of: string), edited: edited, changeInLength: delta, typing: typing, syntax: syntax)
    }

    static func update(_ old: MarkdownDocument, units u: [UInt16], edited: NSRange, changeInLength delta: Int, typing: Bool,
                       syntax: NoteSyntax) -> Update {
        func readAll() -> Update {
            let document = parse(units: u, typing: typing, syntax: syntax)
            return Update(document: document, start: 0, blockStart: 0, end: document.lines.count, oldEnd: old.lines.count,
                          blockEnd: document.blocks.count, oldBlockEnd: old.blocks.count)
        }
        let oldEditEnd = edited.upperBound - delta
        guard old.syntax == syntax, old.typing == typing, old.length + delta == u.count, !old.lines.isEmpty, edited.location >= 0,
              edited.upperBound <= u.count, oldEditEnd >= edited.location, oldEditEnd <= old.length else { return readAll() }

        // The edited lines: from the start of the first to the end of the last, which moved by `delta`.
        let first = old.lineIndex(containing: edited.location)
        let last = old.lineIndex(containing: oldEditEnd)
        let editedStart = old.lines[first].range.location
        let editedEnd = old.lines[last].fullRange.upperBound + delta
        guard editedEnd >= edited.upperBound, editedEnd <= u.count, editedEnd == u.count || u[editedEnd - 1] == 10 else { return readAll() }
        let editedLines = splitLines(u, in: editedStart..<editedEnd, last: last == old.lines.count - 1)

        // Reading starts again at the last line above the edited ones where it could: not at the first edited line,
        // as the line above it may read differently with what is under it now (a table's header, a list item that
        // a line goes on with).
        let points = old.resumePoints
        let below = firstIndex(points.count) { points[$0].line >= first }
        var restart = below > 0 ? points[below - 1] : nil
        if syntax == .markdown, restart != nil {
            // A `---` first line opens frontmatter once a `---` or `...` anywhere below closes it, and a `$$` line
            // closes a `$$` left open anywhere above: both read from the start.
            if old.blocks.first?.kind != .frontmatter, lineText(u, old.lines[0].range) == "---" {
                restart = nil
            } else if editedLines.contains(where: { lineText(u, $0.range).trimmingCharacters(in: .whitespaces) == "$$" }) {
                restart = nil
            }
        }
        let start = restart?.line ?? 0
        let keptPoints = restart == nil ? 0 : below - 1
        let blockStart = firstIndex(old.blocks.count) { old.blocks[$0].lines.lowerBound >= start }

        // The lines from there on, not read yet.
        var lines = Array(old.lines[0..<start])
        lines.reserveCapacity(old.lines.count + editedLines.count - (last - first + 1))
        for line in old.lines[start..<first] { lines.append(rawLine(u, line.range, breakLength: line.breakLength)) }
        lines += editedLines
        for line in old.lines[(last + 1)...] { lines.append(rawLine(u, line.range.shifted(by: delta), breakLength: line.breakLength)) }
        let lineDelta = lines.count - old.lines.count

        // Reading stops at a line below the edited ones where it could start again, if the old reading could start
        // there too, carrying the same state: from there on it reads as before.
        let firstUnchanged = last + 1 + lineDelta
        var next = below
        let stop: (Int, ParserState) -> Bool = { line, state in
            guard line >= firstUnchanged else { return false }
            let oldLine = line - lineDelta
            while next < points.count, points[next].line < oldLine { next += 1 }
            return next < points.count && points[next].line == oldLine && points[next].state == state
        }

        var blocks: [MarkdownBlock]
        var newPoints: [ResumePoint]
        let stopped: Bool
        let end: Int
        switch syntax {
        case .markdown:
            var reader = Reader(u: u, typing: typing, lines: lines)
            lines = []
            reader.blocks = Array(old.blocks[0..<blockStart])
            reader.index = start
            if case .markdown(let listIndents)? = restart?.state { reader.listIndents = listIndents } else { reader.readFrontmatter() }
            stopped = reader.read(stop: stop)
            end = stopped ? reader.index : reader.lines.count
            swap(&lines, &reader.lines)
            blocks = reader.blocks
            newPoints = reader.resumePoints
        case .asciidoc:
            var reader = AsciiDocParser.Reader(u: u, typing: typing, lines: lines, from: restart)
            lines = []
            stopped = reader.read(stop: stop)
            end = stopped ? reader.index : reader.lines.count
            swap(&lines, &reader.lines)
            blocks = Array(old.blocks[0..<blockStart])
            blocks += AsciiDocParser.Reader.ordered(reader.blocks, lines: &lines, in: start..<end, offset: blockStart)
            newPoints = reader.resumePoints
        }

        // The old lines, blocks and places to start again from where reading stopped, moved along.
        let oldEnd = end - lineDelta
        let blockEnd = blocks.count
        var oldBlockEnd = old.blocks.count
        var resumePoints = Array(points[0..<keptPoints])
        resumePoints += newPoints
        if stopped {
            oldBlockEnd = firstIndex(old.blocks.count) { old.blocks[$0].lines.lowerBound >= oldEnd }
            let blockDelta = blockEnd - oldBlockEnd
            blocks += old.blocks[oldBlockEnd...].map { $0.moved(by: delta, lines: lineDelta) }
            lines.replaceSubrange(end..., with: old.lines[oldEnd...].map { $0.moved(by: delta, lines: lineDelta, blocks: blockDelta) })
            resumePoints += points[next...].map { $0.moved(lines: lineDelta) }
        }

        fingerprint(&lines, u, in: start..<end)
        var attributes: [String: String] = [:]
        switch syntax {
        case .markdown:
            readSpans(&lines, u, in: start..<end, typing: typing)
        case .asciidoc:
            attributes = AsciiDocParser.attributes(in: u, lines: lines)
            // The inline markup of every line reads the attributes.
            guard attributes == old.attributes else { return readAll() }
            AsciiDocParser.readSpans(&lines, u, in: start..<end, attributes: attributes, typing: typing)
        }
        let document = MarkdownDocument(lines: lines, blocks: blocks, length: u.count, syntax: syntax, typing: typing,
                                        resumePoints: resumePoints, attributes: attributes)
        return Update(document: document, start: start, blockStart: blockStart, end: end, oldEnd: oldEnd,
                      blockEnd: blockEnd, oldBlockEnd: oldBlockEnd)
    }

    /// The first index below `count` where `condition` holds, for a condition that holds from some index on.
    private static func firstIndex(_ count: Int, where condition: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if condition(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
