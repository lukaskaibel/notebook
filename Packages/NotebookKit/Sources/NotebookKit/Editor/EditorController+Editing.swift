#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Typing as in a notes app: lists continue on Return and end on an empty item, Tab nests them, Backspace at the
/// start of an item takes its bullet away, `[[` opens link suggestions. Where the editor has no rule of its own, the
/// typing rules of `MarkdownEditing` take over: styles turn on and off at the caret, a style's marks come and go as a
/// pair, Return leaves a style at its end, and `-` starts a bullet.
extension EditorController {
    // MARK: - Changing text

    /// Replaces text the way typing does, so it can be undone, and puts the selection where asked. A change where you
    /// write keeps the caret in view, as typing does: Return on the last line that shows, the next bullet of a list,
    /// lines pasted at the bottom of the window or above the keyboard.
    @discardableResult
    func replace(_ range: NSRange, with string: String, select selection: NSRange? = nil, actionName: String? = nil) -> Bool {
        guard range.upperBound <= storage.length, !isWaitingForText else { return false }
        let before = self.selection
        isPerformingEdit = true
        defer { isPerformingEdit = false }
        guard performEdit(range, with: string) else { return false }
        if let actionName { textView.undoManager?.setActionName(actionName) }
        if let selection {
            setSelection(NSRange(location: min(selection.location, storage.length), length: min(selection.length, storage.length - min(selection.location, storage.length))))
        }
        // Where you write: at the caret or over the selection, not a to-do ticked or a link changed elsewhere.
        if range.location <= before.upperBound, range.upperBound >= before.location, revealsCaretAfterEdit {
            scrollCaretIntoView()
        }
        return true
    }

    /// Puts text at the end of the note, after its last line and a blank one, as one step of Undo of its own:
    /// something shared to the note from another app. The caret and the scroll position stay where they are.
    @discardableResult
    func appendAtEnd(_ addition: String, actionName: String) -> Bool {
        let end = Workspace.sharedEnd(addition, after: nsText)
        // Made as a link's change is: one step, the caret and the scroll position kept.
        return changeLinks([(NSRange(location: end.kept, length: storage.length - end.kept), end.tail)], actionName: actionName)
    }

    /// Puts other text in the note's place, an earlier version's, as one step of Undo of its own. Only the part that
    /// differs is replaced, so the caret and the scroll position stay where they can. Nothing changes while the text
    /// isn't in.
    @discardableResult
    func restore(text: String, actionName: String) -> Bool {
        guard !isWaitingForText, !isReadOnly else { return false }
        guard let change = change(to: text) else { return true }
        // A caret in what is replaced stays where that begins, near where you were, rather than after it all, and what
        // is above it stays where it is on screen.
        let selection = self.selection
        let inside = selection.location > change.range.location && selection.location < change.range.upperBound
        let caret = inside ? NSRange(location: change.range.location, length: 0) : change.caret
        let manager = textView.undoManager
        breakTyping()
        let opens = manager?.groupingLevel == 0
        if opens { manager?.beginUndoGrouping() }
        preservingScroll(anchor: inside ? change.range.location : nil) {
            replace(change.range, with: change.replacement, select: caret)
        }
        manager?.setActionName(actionName)
        if opens { manager?.endUndoGrouping() }
        breakTyping()
        return true
    }

    /// What is typed next is a step of Undo of its own, apart from what was typed before.
    private func breakTyping() {
        #if os(macOS)
        textView.breakUndoCoalescing()
        #else
        openStep = nil
        #endif
    }

    /// Changes the addresses of links, each where it is, as one step of Undo of its own: a file they point at was
    /// renamed or moved. The caret and the scroll position stay where they are. Nothing changes while the text isn't in.
    @discardableResult
    func changeLinks(_ changes: [(range: NSRange, replacement: String)], actionName: String) -> Bool {
        replace(changes, actionName: actionName)
    }

    /// Makes several changes, each where it is, as one step of Undo of its own; the selection goes with the text around
    /// it. What is at `anchor` stays where it is on the screen, found at `movedTo` once the changes are made, else the
    /// caret. Nothing changes while the text isn't in.
    @discardableResult
    func replace(_ changes: [(range: NSRange, replacement: String)], actionName: String, anchor: Int? = nil, movedTo: Int? = nil) -> Bool {
        guard !isWaitingForText, !changes.isEmpty, changes.allSatisfy({ $0.range.upperBound <= storage.length }) else { return false }
        let manager = textView.undoManager
        breakTyping()
        // Outside an event the undo manager would keep its group open until after the next, and take it in.
        let opens = manager?.groupingLevel == 0
        if opens { manager?.beginUndoGrouping() }
        var selection = self.selection
        preservingScroll(anchor: anchor, movedTo: movedTo) {
            // From the last back, so the ranges before stay where they are.
            for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
                let delta = (change.replacement as NSString).length - change.range.length
                if selection.location >= change.range.upperBound {
                    selection.location += delta
                } else if selection.location <= change.range.location, selection.upperBound >= change.range.upperBound {
                    selection.length += delta
                } else if selection.upperBound > change.range.location {
                    selection = NSRange(location: change.range.location, length: 0)
                }
                replace(change.range, with: change.replacement)
            }
            setSelection(NSRange(location: min(selection.location, storage.length), length: min(selection.length, storage.length - min(selection.location, storage.length))))
        }
        manager?.setActionName(actionName)
        if opens { manager?.endUndoGrouping() }
        breakTyping()
        return true
    }

    func insert(_ string: String) {
        let selection = self.selection
        replace(selection, with: string, select: NSRange(location: selection.location + (string as NSString).length, length: 0))
    }

    // MARK: - Up into the title

    /// ↑ on the first line goes into the title, to its end.
    func moveUpIntoTitle() -> Bool {
        guard isCaretOnFirstLine else { return false }
        focusTitle(caretAtEnd: true)
        return true
    }

    /// ← or Delete at the very start of the note goes back into the title, to its end, as if it were the line above.
    func moveBackIntoTitle() -> Bool {
        guard selection == NSRange(location: 0, length: 0), !isWaitingForText else { return false }
        focusTitle(caretAtEnd: true)
        return true
    }

    /// Delete at the very start of the note goes into the title, but not while Delete is held down (or pressed again
    /// right away), which would go on to delete the title.
    func deleteBackIntoTitle() -> Bool {
        let now = CACurrentMediaTime()
        let held = now - lastDeleteBackward < 0.5
        lastDeleteBackward = now
        return !held && moveBackIntoTitle()
    }

    /// The caret rests on the note's first line, where ↑ goes into the title.
    var isCaretOnFirstLine: Bool {
        let selection = self.selection
        guard selection.length == 0 else { return false }
        if storage.length == 0 { return true }
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let line: NSRect
        if selection.location >= storage.length, layoutManager.extraLineFragmentTextContainer != nil {
            line = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(selection.location, storage.length - 1))
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return line.minY <= first.minY + 0.5
    }

    // MARK: - Return

    func insertNewline() -> Bool {
        // Return over text selected in a cell: a new row under it, as from its end.
        if self.selection.length > 0, let grid = activeGrid, self.selection.location >= grid.range.location, self.selection.upperBound <= grid.range.upperBound {
            setSelection(NSRange(location: self.selection.upperBound, length: 0))
        }
        let selection = self.selection
        guard !document.lines.isEmpty else { return false }
        let index = document.lineIndex(containing: selection.location)
        let line = document.lines[index]
        let text = nsText

        // ```lang + Return closes the fence for you; in AsciiDoc `----` and the other delimiters too.
        if line.kind == .fence, selection.length == 0, selection.location == line.range.upperBound,
           let block = line.block, index == document.blocks[block].lines.first(where: { document.lines[$0].kind == .fence }), !isClosed(block) {
            let fenceText = text.substring(with: line.range).trimmingCharacters(in: .whitespaces)
            let isDelimiter = syntax == .asciidoc && fenceText.count >= 4 && Set(fenceText).count == 1
            let fence = isDelimiter ? fenceText : String(fenceText.prefix { $0 == "`" || $0 == "~" })
            replace(selection, with: "\n\n" + fence, select: NSRange(location: selection.location + 1, length: 0))
            return true
        }

        if case .heading(_, let marker) = line.kind, selection.length == 0 {
            let content = text.substring(with: NSRange(location: marker.upperBound, length: line.range.upperBound - marker.upperBound))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Return on a heading without text takes the heading off, as on an empty list item.
                replace(line.range, with: "", select: NSRange(location: line.range.location, length: 0), actionName: "Format")
                return true
            }
            if selection.location <= marker.upperBound {
                // At the start of a heading's text: a line above it, and the heading stays one.
                replace(NSRange(location: line.range.location, length: 0), with: "\n", select: NSRange(location: selection.location + 1, length: 0))
                return true
            }
        }

        if syntax == .asciidoc {
            if [.tableHeader, .tableDelimiter, .tableRow].contains(line.kind), let block = line.block, case .table = document.blocks[block].kind {
                if insertAsciiDocTableRow(at: index, in: document.blocks[block]) { return true }
            }
        } else {
            if [.tableHeader, .tableDelimiter, .tableRow].contains(line.kind), selection.length == 0, let block = line.block,
               case .table(let alignments) = document.blocks[block].kind, insertTableRow(at: index, in: document.blocks[block], columns: alignments.count) {
                return true
            }
            if startTable(on: index) { return true }
        }

        switch line.kind {
        case .code:
            let leading = text.substring(with: line.range).prefix { $0 == " " || $0 == "\t" }
            replace(selection, with: "\n" + leading, select: NSRange(location: selection.location + 1 + (String(leading) as NSString).length, length: 0))
            return true
        case .fence, .math, .mathDelimiter, .tableHeader, .tableDelimiter, .tableRow, .frontmatterDelimiter, .frontmatter, .markup, .comment:
            return false
        default:
            break
        }

        // Between a to-do's words and its date or place, Return makes the next to-do, as at the end of the line: the
        // pills stay with the to-do they belong to.
        if selection.length == 0, case .listItem(let item) = line.kind, item.isTask, selection.location < line.range.upperBound,
           line.spans.contains(where: { if case .todoMark = $0.kind { true } else { false } }), selection.location >= todoWordsEnd(line: index) {
            setSelection(NSRange(location: line.range.upperBound, length: 0))
            return insertNewline()
        }

        if syntax == .asciidoc, selection.length == 0, newAsciiDocParagraph(at: index) { return true }

        // Return leaves a style at its end and splits one in its middle, continues a list or quote with the next
        // marker, and ends it on an empty item.
        if perform(MarkdownEditing.insertNewline) {
            if case .listItem(let item) = line.kind, item.isOrdered { renumberList(after: self.selection.location) }
            return true
        }

        switch line.kind {
        case .listItem(let item):
            let content = text.substring(with: line.content).trimmingCharacters(in: .whitespaces)
            if content.isEmpty, selection.length == 0 {
                // Return on an empty item ends the list (or, nested, moves the item out one level).
                if item.level > 0 {
                    return indent(by: -1)
                }
                replace(item.prefix, with: "", select: NSRange(location: item.prefix.location, length: 0))
                return true
            }
            let prefix = continuation(of: item, text: text)
            replace(selection, with: "\n" + prefix, select: NSRange(location: selection.location + 1 + (prefix as NSString).length, length: 0))
            renumberList(after: selection.location + 1)
            return true
        case .quote(_, let prefix):
            let content = text.substring(with: line.content).trimmingCharacters(in: .whitespaces)
            if line.block.map({ document.blocks[$0].lines.lowerBound }) == index, case .callout = line.block.map({ document.blocks[$0].kind }) ?? .quote {
                // The callout's title line: the body continues inside the callout.
            } else if content.isEmpty, selection.length == 0 {
                replace(prefix, with: "", select: NSRange(location: prefix.location, length: 0))
                return true
            }
            let prefixText = text.substring(with: prefix)
            replace(selection, with: "\n" + prefixText, select: NSRange(location: selection.location + 1 + (prefixText as NSString).length, length: 0))
            return true
        default:
            return false
        }
    }

    /// Return in an AsciiDoc paragraph starts the next paragraph, with the blank line between them AsciiDoc needs: a line
    /// break alone would keep the paragraph going, as it shows. Right before a break inside a paragraph, that break
    /// and the new one make the blank line. In the text that goes on with a list item, Return makes the next item.
    private func newAsciiDocParagraph(at index: Int) -> Bool {
        let line = document.lines[index]
        let caret = selection.location
        guard caret >= line.range.location, caret <= line.range.upperBound else { return false }
        switch line.kind {
        case .continuation(let item, _):
            if case .listItem(let found) = document.lines[safe: item]?.kind {
                let prefix = continuation(of: found, text: nsText)
                replace(NSRange(location: caret, length: 0), with: "\n" + prefix, select: NSRange(location: caret + 1 + (prefix as NSString).length, length: 0))
                return true
            }
        case .paragraph, .admonition:
            break
        default:
            return false
        }
        // An empty line is no paragraph to end.
        guard !nsText.substring(with: line.range).trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if caret == line.range.upperBound, document.isSoftBreak(after: index, in: nsText) {
            replace(NSRange(location: caret, length: 0), with: "\n", select: NSRange(location: caret + 2, length: 0))
        } else {
            replace(NSRange(location: caret, length: 0), with: "\n\n", select: NSRange(location: caret + 2, length: 0))
        }
        return true
    }

    /// A list item, or a line of text that goes on with one.
    private func isInList(_ line: MarkdownLine) -> Bool {
        switch line.kind {
        case .listItem, .continuation: true
        default: false
        }
    }

    /// Shift-Return in AsciiDoc text: a line break that shows, ` +` at the end of the line, which is AsciiDoc's.
    func insertAsciiDocLineBreak() -> Bool {
        guard syntax == .asciidoc, selection.length == 0, !document.lines.isEmpty else { return false }
        let index = document.lineIndex(containing: selection.location)
        let line = document.lines[index]
        switch line.kind {
        case .paragraph, .admonition, .continuation, .listItem:
            break
        default:
            return false
        }
        let caret = selection.location
        let before = nsText.substring(with: NSRange(location: line.range.location, length: caret - line.range.location))
        guard !before.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let mark = before.hasSuffix(" ") ? "+\n" : " +\n"
        replace(NSRange(location: caret, length: 0), with: mark, select: NSRange(location: caret + (mark as NSString).length, length: 0))
        return true
    }

    /// Return in a table makes a new empty row under the caret's row (under the delimiter row, from the header), with
    /// the caret in its first cell, instead of a line break that would end the table there. At the start of a row the
    /// new one goes above it, as a line goes above a heading, and the caret stays; at the start of the header the line
    /// break goes in above the table. An empty last row ends the table, as an empty item ends a list, with a blank
    /// line under it, which other apps would otherwise take the next line into.
    ///
    /// A delimiter row typed by hand as the first row, under the one Return put in after the header, takes its place.
    /// Tab past the last cell makes a row this way too (`endsOnEmptyRow` false), and an empty row doesn't end the table
    /// then.
    private func insertTableRow(at index: Int, in block: MarkdownBlock, columns: Int, endsOnEmptyRow: Bool = true) -> Bool {
        let text = nsText
        let line = document.lines[index]
        let caret = selection.location
        let units = { (line: MarkdownLine) in Array(text.substring(with: line.range).utf16) }
        let row = units(line)
        let cells = MarkdownParser.tableCells(row, NSRange(location: 0, length: row.count))
        let delimiter = document.lines[block.lines.lowerBound + 1]

        if line.kind == .tableHeader, caret == line.range.location { return false }
        if endsOnEmptyRow, line.kind == .tableRow, index == block.lines.upperBound, cells.allSatisfy({ $0.length == 0 }) {
            replace(line.range, with: "\n", select: NSRange(location: line.range.location + 1, length: 0))
            return true
        }
        if line.kind == .tableRow, index == block.lines.lowerBound + 2, cells.count == columns,
           MarkdownParser.delimiterRow(row, NSRange(location: 0, length: row.count)) != nil {
            let typed = text.substring(with: line.range)
            let empty = Self.emptyTableRow(like: row)
            replace(NSRange(location: delimiter.range.location, length: line.range.upperBound - delimiter.range.location), with: typed + "\n" + empty.row,
                    select: NSRange(location: delimiter.range.location + (typed as NSString).length + 1 + empty.start, length: 0))
            return true
        }

        // The new row is the delimiter row with its cells emptied, so its pipes line up with the table's. (A copy of the
        // row before would grow with every row typed in.)
        let empty = Self.emptyTableRow(like: units(delimiter))
        if line.kind == .tableRow, caret == line.range.location {
            replace(NSRange(location: caret, length: 0), with: empty.row + "\n", select: NSRange(location: caret + (empty.row as NSString).length + 1, length: 0))
            return true
        }
        let after = line.kind == .tableRow ? line : delimiter
        replace(NSRange(location: after.range.upperBound, length: 0), with: "\n" + empty.row,
                select: NSRange(location: after.range.upperBound + 1 + empty.start, length: 0))
        return true
    }

    /// A row like the one given with its cells emptied, so its pipes stay where they are, and where its first cell
    /// starts: after the opening pipe and a space.
    static func emptyTableRow(like units: [UInt16]) -> (row: String, start: Int) {
        var blank = units
        for cell in MarkdownParser.tableCells(units, NSRange(location: 0, length: units.count)) {
            blank.replaceSubrange(cell.location..<cell.upperBound, with: repeatElement(32, count: cell.length))
        }
        var start = units.prefix { $0 == 32 || $0 == 9 }.count
        if start < units.count, units[start] == 124 {
            start += 1
            if start < units.count, units[start] == 32 { start += 1 }
        }
        return (String(utf16CodeUnits: blank, count: blank.count), start)
    }

    /// Return at the end of a line of cells, `| Day | Area |`, typed as a table's first row: the delimiter row under it,
    /// its dashes as wide as the cells, and an empty row with the caret in its first cell. Only for a line of two cells
    /// or more, between pipes, with nothing right under it.
    private func startTable(on index: Int) -> Bool {
        let text = nsText
        let line = document.lines[index]
        let caret = selection.location
        guard line.kind == .paragraph, line.block == nil, selection.length == 0, caret >= line.range.location,
              text.substring(with: NSRange(location: caret, length: line.range.upperBound - caret)).allSatisfy(\.isWhitespace),
              index + 1 == document.lines.count || document.lines[index + 1].kind == .blank else { return false }
        let row = Array(text.substring(with: line.range).utf16)
        let trimmed = text.substring(with: line.range).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), trimmed.count > 2 else { return false }
        let slots = MarkdownParser.tableSlots(row, NSRange(location: 0, length: row.count))
        let cells = MarkdownParser.tableCells(row, NSRange(location: 0, length: row.count))
        guard slots.count >= 2, let first = slots.first else { return false }

        var delimiter = String(utf16CodeUnits: row, count: first.location)
        for (slot, cell) in zip(slots, cells) {
            if cell.length == 0 {
                delimiter += " --- |"
            } else {
                let dashes = String(repeating: "-", count: max(3, cell.length))
                delimiter += String(repeating: " ", count: cell.location - slot.location) + dashes + String(repeating: " ", count: slot.upperBound - cell.upperBound) + "|"
            }
        }
        let empty = Self.emptyTableRow(like: row)
        let end = line.range.upperBound
        replace(NSRange(location: end, length: 0), with: "\n" + delimiter + "\n" + empty.row,
                select: NSRange(location: end + 1 + (delimiter as NSString).length + 1 + empty.start, length: 0))
        return true
    }

    /// Format › Table (⌥⌘T) and the toolbar's Table, as in Notes: a table of two columns, its header and one row, with
    /// the caret in its first cell. An empty line becomes the table; otherwise it goes in under the caret's line, or
    /// under the table, code or quote the caret is in. Empty lines around it end what is above and below, so other apps
    /// read it as a table too. Markdown only: false in an AsciiDoc note, whose tables are typed.
    @discardableResult
    func insertTable() -> Bool {
        guard syntax == .markdown, !isWaitingForText else { return false }
        let table = "|     |     |\n| --- | --- |\n|     |     |"
        let firstCell = 2
        guard !document.lines.isEmpty else {
            return replace(NSRange(location: 0, length: storage.length), with: table, select: NSRange(location: firstCell, length: 0), actionName: "Table")
        }
        var index = document.lineIndex(containing: selection.location)
        if let block = document.lines[index].block { index = document.blocks[block].lines.upperBound }
        let line = document.lines[index]
        let isBlank = { (index: Int) in self.nsText.substring(with: self.document.lines[index].range).allSatisfy(\.isWhitespace) }
        let hasTextBelow = index + 1 < document.lines.count && !isBlank(index + 1)
        if line.block == nil, isBlank(index) {
            let above = index > 0 && !isBlank(index - 1) ? "\n" : ""
            let text = above + table + (hasTextBelow ? "\n" : "")
            let start = line.range.location + (above as NSString).length
            return replace(line.range, with: text, select: NSRange(location: start + firstCell, length: 0), actionName: "Table")
        }
        let end = line.range.upperBound
        let text = "\n\n" + table + (hasTextBelow ? "\n" : "")
        return replace(NSRange(location: end, length: 0), with: text, select: NSRange(location: end + 2 + firstCell, length: 0), actionName: "Table")
    }

    /// Puts the caret back where it was and does something there, from a button of a toolbar: on the iPhone and iPad
    /// the keyboard comes up as it would for a tap in the text. In a note you haven't put the caret in, a checklist
    /// starts on a new line at its end, as in Notes, rather than making its first line a to-do, and a table goes in at
    /// its end.
    func beginEditing(then command: FormatCommand? = nil) {
        if !isFocused {
            if command == .checklist, !hasPlacedCaret {
                startChecklistAtEnd()
                makeTextFirstResponder()
                return
            }
            if command == .table { placeCaretForToolbar() }
            makeTextFirstResponder()
        }
        if let command { perform(command) }
    }

    /// The caret is somewhere you put it, also at the very start, or where Back took you: not just where the note
    /// opened.
    var hasPlacedCaret: Bool { isFocused || caretWasPlaced }

    /// What a toolbar button adds goes at the end of a note you haven't put the caret in, as in Notes: a picture
    /// from Attach, say, rather than above the note's first line.
    func placeCaretForToolbar() {
        guard !hasPlacedCaret, storage.length > 0 else { return }
        setSelection(NSRange(location: storage.length, length: 0))
    }

    /// A new to-do on a line of its own after the note's last line, with the caret in it, as one step of Undo.
    private func startChecklistAtEnd() {
        let end = storage.length
        let endsOnEmptyLine = end == 0 || (text as NSString).substring(from: end - 1) == "\n"
        let added = (endsOnEmptyLine ? "" : "\n") + "- [ ] "
        replace(NSRange(location: end, length: 0), with: added, select: NSRange(location: end + (added as NSString).length, length: 0),
                actionName: "Checklist")
    }

    /// Tab and ⇧Tab in a table go to the next or the previous cell, its text selected, as in Numbers and Notes; from a
    /// row's last cell Tab goes on to the next row, and past the last row it makes a new one. The delimiter row is passed
    /// over. False outside a table, where Tab nests list items.
    func moveToTableCell(by direction: Int) -> Bool {
        let selection = self.selection
        guard !document.lines.isEmpty else { return false }
        let index = document.lineIndex(containing: selection.location)
        let line = document.lines[index]
        if syntax == .asciidoc, let block = line.block, case .table = document.blocks[block].kind {
            return moveToAsciiDocCell(by: direction, in: document.blocks[block])
        }
        guard [.tableHeader, .tableDelimiter, .tableRow].contains(line.kind), selection.upperBound <= line.range.upperBound,
              let block = line.block, case .table(let alignments) = document.blocks[block].kind else { return false }
        let text = nsText
        let rows = document.blocks[block].lines.filter { document.lines[$0].kind != .tableDelimiter }
        func slots(_ row: Int) -> [NSRange] {
            let range = document.lines[rows[row]].range
            let units = Array(text.substring(with: range).utf16)
            return MarkdownParser.tableSlots(units, NSRange(location: 0, length: units.count)).map {
                NSRange(location: $0.location + range.location, length: $0.length)
            }
        }

        // Where the caret is: before the first cell is -1, and the delimiter row is after the header's last cell.
        var row: Int
        var cell: Int
        if line.kind == .tableDelimiter {
            row = 0
            cell = slots(0).count
        } else {
            row = rows.firstIndex(of: index) ?? 0
            let own = slots(row)
            cell = selection.location < (own.first?.location ?? 0) ? -1 : own.firstIndex { selection.location <= $0.upperBound } ?? own.count - 1
        }
        cell += direction
        if cell < 0 {
            guard row > 0 else { return true }
            row -= 1
            cell = slots(row).count - 1
        } else if cell >= slots(row).count {
            guard row + 1 < rows.count else {
                guard direction > 0 else { return true }
                setSelection(NSRange(location: document.lines[rows[row]].range.upperBound, length: 0))
                return insertTableRow(at: rows[row], in: document.blocks[block], columns: alignments.count, endsOnEmptyRow: false)
            }
            row += 1
            cell = 0
        }
        guard let slot = slots(row)[safe: cell] else { return true }
        // The cell's text selected, so what you type takes its place; in an empty cell, the caret after the space.
        var content = slot
        while content.length > 0, [32, 9].contains(text.character(at: content.location)) { content = NSRange(location: content.location + 1, length: content.length - 1) }
        while content.length > 0, [32, 9].contains(text.character(at: content.upperBound - 1)) { content.length -= 1 }
        if content.length == 0 {
            content = NSRange(location: slot.length > 0 && text.character(at: slot.location) == 32 ? slot.location + 1 : slot.location, length: 0)
        }
        setSelection(content)
        return true
    }

    // MARK: - AsciiDoc tables

    /// Return in an AsciiDoc table (`|===`): after the opening delimiter of a table not yet closed, a row and the
    /// closing delimiter; at the end of a row written on one line, a new empty row under it (under the blank line
    /// after the header), the caret in its first cell; on an empty last row, out of the table. In cells written on
    /// lines of their own, a new cell.
    private func insertAsciiDocTableRow(at index: Int, in block: MarkdownBlock) -> Bool {
        let text = nsText
        let line = document.lines[index]
        let caret = selection.location
        guard selection.length == 0 else { return false }
        let delimiters = block.lines.filter { document.lines[$0].kind == .tableDelimiter }
        let columns = { () -> Int in if case .table(let alignments) = block.kind { max(1, alignments.count) } else { 1 } }()
        let emptyRow = "|" + String(repeating: " |", count: columns - 1) + " "
        if line.kind == .tableDelimiter {
            guard index == delimiters.first, delimiters.count == 1, caret == line.range.upperBound else { return false }
            let delimiter = text.substring(with: line.range).trimmingCharacters(in: .whitespaces)
            replace(NSRange(location: caret, length: 0), with: "\n| \n" + delimiter, select: NSRange(location: caret + 3, length: 0))
            return true
        }
        guard caret == line.range.upperBound else { return false }
        let units = Array(text.substring(with: line.range).utf16)
        let separators = units.enumerated().filter { $0.element == 124 && ($0.offset == 0 || units[$0.offset - 1] != 92) }.count
        guard separators >= columns else {
            // A cell of its own on this line: the next one under it.
            replace(NSRange(location: caret, length: 0), with: "\n| ", select: NSRange(location: caret + 3, length: 0))
            return true
        }
        let isEmpty = units.allSatisfy { $0 == 124 || $0 == 32 || $0 == 9 }
        if isEmpty, index + 1 < document.lines.count, document.lines[index + 1].kind == .tableDelimiter {
            // An empty last row: it goes, and the caret goes on under the table.
            let closing = document.lines[index + 1]
            let after = closing.range.upperBound
            replace(NSRange(location: line.range.location, length: after - line.range.location),
                    with: text.substring(with: closing.range) + "\n", select: NSRange(location: line.range.location + closing.range.length + 1, length: 0))
            return true
        }
        // The header keeps the blank line under it, which makes it the header.
        var at = line.range.upperBound
        if line.kind == .tableHeader, index + 1 < document.lines.count, document.lines[index + 1].kind == .blank {
            at = document.lines[index + 1].range.upperBound
        }
        replace(NSRange(location: at, length: 0), with: "\n" + emptyRow, select: NSRange(location: at + 3, length: 0))
        return true
    }

    /// Tab and ⇧Tab in an AsciiDoc table: the next or the previous cell, its text selected; past the last one, a new row.
    private func moveToAsciiDocCell(by direction: Int, in block: MarkdownBlock) -> Bool {
        let units = nsText.units(of: block.lines.map { document.lines[$0] })
        let delimiters = block.lines.filter { document.lines[$0].kind == .tableDelimiter }
        guard let open = delimiters.first else { return false }
        let close = delimiters.count > 1 ? delimiters[delimiters.count - 1] : block.lines.upperBound + 1
        let separator = units[document.lines[open].range.location]
        let columns = { () -> Int? in if case .table(let alignments) = block.kind { alignments.count } else { nil } }()
        let cells = AsciiDocTable.rows(units, lines: document.lines, inner: (open + 1)..<close, separator: separator, columns: columns).flatMap(\.cells).map(\.range)
        guard !cells.isEmpty else { return true }
        let caret = selection.location
        let current = cells.lastIndex { $0.location <= caret } ?? -1
        let next = current + direction
        if next >= cells.count {
            guard direction > 0, let last = cells.last else { return true }
            setSelection(NSRange(location: document.lines[document.lineIndex(containing: last.upperBound)].range.upperBound, length: 0))
            return insertAsciiDocTableRow(at: document.lineIndex(containing: selection.location), in: block)
        }
        guard next >= 0 else { return true }
        setSelection(cells[next])
        return true
    }

    /// Whether a block of code has its closing fence: two of them (AsciiDoc's attributes may come before the first).
    private func isClosed(_ block: Int) -> Bool {
        document.blocks[block].lines.filter { document.lines[$0].kind == .fence }.count > 1
    }

    /// The prefix for the next item: same indent and marker, the next number, an unticked box.
    private func continuation(of item: ListItem, text: NSString) -> String {
        let indent = text.substring(with: item.indentRange)
        var marker: String
        switch item.marker {
        case .bullet(let character): marker = String(character)
        case .ordered(_, _) where item.counted: marker = text.substring(with: item.markerRange)
        case .ordered(let number, let delimiter): marker = "\(number + 1)\(delimiter)"
        }
        marker += " "
        if item.isTask { marker += "[ ] " }
        return indent + marker
    }

    /// Numbers the items of an ordered list one after the other again, from the item at `location` on.
    func renumberList(after location: Int) {
        guard !document.lines.isEmpty else { return }
        let start = document.lineIndex(containing: location)
        // AsciiDoc's `. Item` counts itself.
        guard case .listItem(let first) = document.lines[start].kind, first.isOrdered, !first.counted else { return }
        var expected: Int?
        if start > 0, case .listItem(let previous) = document.lines[start - 1].kind, previous.indent == first.indent,
           case .ordered(let number, _) = previous.marker {
            expected = number + 1
        }
        guard var next = expected else { return }
        var edits: [(NSRange, String)] = []
        var index = start
        while index < document.lines.count, case .listItem(let item) = document.lines[index].kind {
            if item.indent == first.indent, case .ordered(let number, _) = item.marker {
                if number != next { edits.append((NSRange(location: item.markerRange.location, length: item.markerRange.length - 1), "\(next)")) }
                next += 1
            } else if item.indent < first.indent {
                break
            }
            index += 1
        }
        guard !edits.isEmpty else { return }
        let selection = self.selection
        var shift = 0
        for (range, number) in edits.reversed() {
            replace(range, with: number)
            if range.location < selection.location { shift += (number as NSString).length - range.length }
        }
        setSelection(NSRange(location: selection.location + shift, length: selection.length))
    }

    // MARK: - Delete

    func deleteBackward() -> Bool {
        let selection = self.selection
        guard !document.lines.isEmpty, !hasMarkedText else { return false }
        if let handled = deleteInGrid(forward: false) { return handled }
        // A selection that holds one of a style's marks takes the other one too.
        guard selection.length == 0 else { return deleteByRules(forward: false) }
        guard selection.location > 0 else { return deleteBackIntoTitle() }
        let location = selection.location
        let index = document.lineIndex(containing: location)
        let line = document.lines[index]

        // A picture or a link to a note goes as a whole.
        if let span = line.spans.first(where: { isAtomic($0) && $0.range.upperBound == location }) {
            replace(span.range, with: "", select: NSRange(location: span.range.location, length: 0), actionName: "Delete")
            return true
        }
        if let object = blockObjectSpan(in: line), object.upperBound == location {
            replace(object, with: "", select: NSRange(location: object.location, length: 0), actionName: "Delete")
            return true
        }

        // At the start of an item's text: take the bullet away (or move a nested item out a level).
        if let contentStart = atomicPrefixEnd(line), location == contentStart {
            switch line.kind {
            case .listItem(let item):
                if item.level > 0, item.indent > 0 { return indent(by: -1) }
                // In AsciiDoc a line right under an item is its text: the line leaves the list with a blank line.
                if syntax == .asciidoc, index > 0, isInList(document.lines[index - 1]) {
                    replace(item.prefix, with: "\n", select: NSRange(location: item.prefix.location + 1, length: 0))
                    return true
                }
                replace(item.prefix, with: "", select: NSRange(location: item.prefix.location, length: 0))
                return true
            case .quote(_, let prefix):
                replace(prefix, with: "", select: NSRange(location: prefix.location, length: 0))
                return true
            case .heading(_, let marker):
                // At the start of a heading's text: it becomes body text, as in Notes.
                replace(marker, with: "", select: NSRange(location: marker.location, length: 0), actionName: "Format")
                return true
            default:
                break
            }
        }

        // Around a link the address is hidden: deleting takes the link's text, never its punctuation.
        if let link = line.spans.first(where: { if case .link = $0.kind { return true } else { return false } }) {
            if location == link.range.upperBound || (location > link.content.upperBound && location < link.range.upperBound) {
                if link.content.length > 0 {
                    replace(NSRange(location: link.content.upperBound - 1, length: 1), with: "", select: NSRange(location: link.content.upperBound - 1, length: 0), actionName: "Delete")
                } else {
                    replace(link.range, with: "", select: NSRange(location: link.range.location, length: 0), actionName: "Delete")
                }
                return true
            }
            if location == link.content.location {
                guard link.range.location > line.range.location else { return true }
                replace(NSRange(location: link.range.location - 1, length: 1), with: "", select: NSRange(location: link.range.location - 1, length: 0), actionName: "Delete")
                return true
            }
        }

        // At the start of a line under a table, diagram or picture: select it first, as Notes does, instead of
        // pulling the line into it.
        if location == line.range.location, index > 0, line.range.length > 0 {
            let above = document.lines[index - 1]
            if let block = above.block, document.blocks[block].isWhole {
                setSelection(document.blocks[block].range)
                return true
            }
            if let object = blockObjectSpan(in: above) {
                setSelection(object)
                return true
            }
        }
        if deleteBehindHiddenMarks(at: location, in: line, forward: false) { return true }
        // A style's mark goes with one of the other side: bold becomes italics, italics plain text.
        return deleteByRules(forward: false)
    }

    /// On a touch keyboard, where a style's marks don't show, Delete takes the letter you see next to the caret rather
    /// than a mark you don't, and leaves the caret in the style, so what you type next has it; a style that loses its
    /// last letter goes as a whole.
    private func deleteBehindHiddenMarks(at location: Int, in line: MarkdownLine, forward: Bool) -> Bool {
        guard let marks = hiddenStyleMarks(around: location, in: line),
              forward ? marks.location == location : marks.upperBound == location else { return false }
        // The letter on the other side of the marks.
        guard forward ? marks.upperBound < line.range.upperBound : marks.location > line.range.location else { return false }
        var removed = nsText.rangeOfComposedCharacterSequence(at: forward ? marks.upperBound : marks.location - 1)
        // Styles with nothing else in them go with their marks, from the inside out.
        let styles = line.spans.filter(\.isStyle).sorted { $0.range.length < $1.range.length }
        for span in styles where span.content == removed || (span.content.location >= removed.location && span.content.upperBound <= removed.upperBound) {
            removed = NSUnionRange(removed, span.range)
        }
        replace(removed, with: "", select: NSRange(location: removed.location, length: 0), actionName: "Delete")
        return true
    }

    func deleteForward() -> Bool {
        let selection = self.selection
        guard !document.lines.isEmpty, !hasMarkedText else { return false }
        if let handled = deleteInGrid(forward: true) { return handled }
        guard selection.length == 0 else { return deleteByRules(forward: true) }
        guard selection.location < storage.length else { return false }
        let line = document.lines[document.lineIndex(containing: selection.location)]
        if deleteBehindHiddenMarks(at: selection.location, in: line, forward: true) { return true }
        if let span = line.spans.first(where: { isAtomic($0) && $0.range.location == selection.location }) {
            replace(span.range, with: "", select: NSRange(location: span.range.location, length: 0), actionName: "Delete")
            return true
        }
        if let object = blockObjectSpan(in: line), object.location == selection.location {
            replace(object, with: "", select: NSRange(location: object.location, length: 0), actionName: "Delete")
            return true
        }
        // At the end of a link's text, forward delete takes what comes after the link.
        if let link = line.spans.first(where: { if case .link = $0.kind { return $0.content.upperBound == selection.location } else { return false } }) {
            guard link.range.upperBound < line.range.upperBound else { return true }
            replace(NSRange(location: link.range.upperBound, length: 1), with: "", select: NSRange(location: link.content.upperBound, length: 0), actionName: "Delete")
            return true
        }
        return deleteByRules(forward: true)
    }

    // MARK: - Tab

    /// Tab and Shift-Tab: nest or un-nest the list items the selection touches, or indent code.
    @discardableResult
    func indent(by direction: Int) -> Bool {
        let selection = self.selection
        guard !document.lines.isEmpty else { return false }
        let first = document.lineIndex(containing: selection.location)
        let last = document.lineIndex(containing: max(selection.location, selection.upperBound - (selection.length > 0 ? 1 : 0)))
        let lines = Array(first...last)
        let text = nsText

        let listLines = lines.filter { document.lines[$0].kind.isListItem }
        if syntax == .asciidoc, !listLines.isEmpty {
            // AsciiDoc nests an item by its marker: `*` in is `**`.
            _ = perform(direction > 0 ? MarkdownEditing.indent : MarkdownEditing.outdent, actionName: direction > 0 ? "Indent" : "Outdent")
            return true
        }
        if listLines.isEmpty {
            if case .code = document.lines[first].kind {
                if direction > 0 { insert("    ") } else { outdentCode(lines) }
                return true
            }
            return direction < 0
        }

        let range = NSRange(location: document.lines[first].range.location, length: document.lines[last].range.upperBound - document.lines[first].range.location)
        var result = ""
        var shiftAtStart = 0
        var totalShift = 0
        for index in lines {
            let line = document.lines[index]
            var lineText = text.substring(with: line.range)
            if case .listItem(let item) = line.kind {
                if direction > 0 {
                    let unit = String(repeating: " ", count: indentUnit(for: index))
                    lineText = unit + lineText
                    if index == first { shiftAtStart = unit.count }
                    totalShift += unit.count
                } else {
                    let leading = lineText.prefix { $0 == " " || $0 == "\t" }
                    let remove: Int
                    if leading.hasPrefix("\t") {
                        remove = 1
                    } else {
                        remove = min(leading.count, max(1, item.indent - parentIndent(for: index)))
                    }
                    guard item.indent > 0 else { result += lineText + (index == last ? "" : "\n"); continue }
                    lineText = String(lineText.dropFirst(remove))
                    if index == first { shiftAtStart = -remove }
                    totalShift -= remove
                }
            }
            result += lineText + (index == last ? "" : "\n")
        }
        guard result != text.substring(with: range) else { return true }
        let newSelection = NSRange(location: max(range.location, selection.location + shiftAtStart), length: max(0, selection.length + totalShift - shiftAtStart))
        replace(range, with: result, select: newSelection, actionName: direction > 0 ? "Indent" : "Outdent")
        return true
    }

    /// How far to nest an item: under the item above it, to where that item's text starts.
    private func indentUnit(for index: Int) -> Int {
        var above = index - 1
        guard case .listItem(let item) = document.lines[index].kind else { return 2 }
        while above >= 0, case .listItem(let candidate) = document.lines[above].kind {
            if candidate.indent <= item.indent {
                let width = candidate.markerRange.upperBound - candidate.indentRange.upperBound + 1
                return max(2, candidate.indent + width - item.indent)
            }
            above -= 1
        }
        return 2
    }

    private func parentIndent(for index: Int) -> Int {
        guard case .listItem(let item) = document.lines[index].kind else { return 0 }
        var above = index - 1
        while above >= 0, case .listItem(let candidate) = document.lines[above].kind {
            if candidate.indent < item.indent { return candidate.indent }
            above -= 1
        }
        return 0
    }

    private func outdentCode(_ lines: [Int]) {
        let text = nsText
        guard let first = lines.first, let last = lines.last else { return }
        let range = NSRange(location: document.lines[first].range.location, length: document.lines[last].range.upperBound - document.lines[first].range.location)
        let result = lines.map { index -> String in
            let line = text.substring(with: document.lines[index].range)
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(4, spaces)))
        }.joined(separator: "\n")
        replace(range, with: result, select: NSRange(location: range.location, length: (result as NSString).length))
    }

    // MARK: - Typing

    func shouldInsert(_ replacement: String, in range: NSRange) -> Bool {
        guard !isPerformingEdit, !hasMarkedText else { return true }
        // In a table typed in as a grid: a `|` stays in its cell, and nothing typed over several cells takes their pipes.
        if let handled = insertInGrid(replacement, in: range) { return handled }
        let text = nsText
        let selection = self.selection

        // [[ opens link suggestions and closes the brackets.
        if replacement == "[", range.length == 0, range.location > 0, text.character(at: range.location - 1) == 91,
           range.location < 2 || text.character(at: range.location - 2) != 91 {
            replace(range, with: "[]]", select: NSRange(location: range.location + 1, length: 0))
            suggestionAnchor = range.location + 1
            updateSuggestions()
            return false
        }
        // Typing ] in front of the closing brackets steps over them.
        if replacement == "]", range.length == 0, suggestionAnchor != nil, range.location + 2 <= text.length,
           text.substring(with: NSRange(location: range.location, length: 2)) == "]]" {
            closeSuggestions()
            setSelection(NSRange(location: range.location + 2, length: 0))
            return false
        }
        // Typing a marker with text selected wraps it.
        if range.length > 0, ["*", "_", "`", "~", "="].contains(replacement), !text.substring(with: range).contains("\n"), wrap(range, in: replacement) {
            return false
        }
        // "[] " at the start of a line makes a task.
        if replacement == " ", range.length == 0 {
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if ["[]", "[ ]", "- []", "* []"].contains(trimmed) {
                let indent = before.prefix { $0 == " " || $0 == "\t" }
                let task = indent + "- [ ] "
                replace(NSRange(location: lineStart, length: range.location - lineStart), with: String(task), select: NSRange(location: lineStart + (String(task) as NSString).length, length: 0))
                return false
            }
        }
        // A pipe typed in an empty table row, as when writing the row by hand after Return made it: the row is written
        // from there, without the empty cells Return laid out.
        if replacement == "|", range.length == 0, selection == range, !document.lines.isEmpty {
            let line = document.lines[document.lineIndex(containing: range.location)]
            if line.kind == .tableRow, text.substring(with: line.range).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "|" }) {
                replace(line.range, with: "|", select: NSRange(location: line.range.location + 1, length: 0))
                return false
            }
        }
        // A selection deleted (as iOS sends it, and cutting): a style's mark goes with its pair.
        if replacement.isEmpty, range.length > 0, range == selection {
            return !deleteByRules(forward: false)
        }
        // #s typed at the start of a line show until the caret leaves it, also where marks otherwise don't.
        if replacement == "#", range.length == 0 {
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            if before.trimmingCharacters(in: CharacterSet(charactersIn: "#")).allSatisfy({ $0 == " " }) { typedHeading = lineStart }
        }
        // "-" at the start of a line makes a bullet with its space ("->" an arrow), "- []" a checkbox, a closing mark
        // typed where the same one is steps over it, and a star typed at either end of italics or of text that just lost
        // its marks goes on both ends. Text typed right after two or more #s gets the space a heading needs, and so does
        // text they are typed in front of; `**` brings its closing pair.
        let afterHashes = range.location > 0 && text.character(at: range.location - 1) == 35
        if range.length == 0, selection == range, afterHashes || ["-", ">", " ", "]", "#", "*", "_", "~", "`", "="].contains(replacement) {
            return !insertByRules(replacement)
        }
        return true
    }

    // MARK: - Checkboxes

    /// Ticks a task or unticks it, as the Tasks plugin does: a to-do that repeats gets the day it was done, and the
    /// next one is written above it, in one change Undo takes back.
    func toggleCheckbox(line index: Int) {
        guard let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask else { return }
        let source = nsText.substring(with: line.range)
        guard let marked = Todos.markingChanges(in: nsText, document: document, line: index, as: item.checked ? .open : .done, today: .today) else { return }
        // The line clicked stays under the pointer, ticked, as the next one goes in above it.
        guard replace(marked.changes, actionName: item.checked ? "Uncheck" : "Check", anchor: line.range.location, movedTo: line.range.location + marked.above) else { return }
        if !item.checked, let next = marked.next { delegate?.editor(self, tickedRepeatingTodo: source, line: index, next: next) }
    }

    // MARK: - Formatting

    typealias InlineFormat = MarkdownSyntax.Style

    /// ⌘B and friends, in a table or over lines that aren't all prose: takes the formatting off when the selection (or
    /// the caret) is in it, puts it on the words of each line or cell otherwise. Elsewhere `toggle(_:)` goes by the
    /// rules of `MarkdownEditing`.
    func toggleWords(_ format: InlineFormat) {
        let selection = self.selection
        guard !document.lines.isEmpty else { return }
        // Words on several lines that all have the format lose it, each line's.
        let pieces = wordRanges(in: selection)
        if pieces.count > 1 {
            let spans = pieces.compactMap { piece in
                document.lines[document.lineIndex(containing: piece.location)].spans.first {
                    format.matches($0.kind) && $0.range.location <= piece.location && $0.range.upperBound >= piece.upperBound
                }
            }
            if spans.count == pieces.count, let start = spans.first?.range.location, let end = spans.last?.range.upperBound {
                var result = ""
                var location = start
                for span in spans {
                    result += nsText.substring(with: NSRange(location: location, length: span.range.location - location)) + nsText.substring(with: span.content)
                    location = span.range.upperBound
                }
                replace(NSRange(location: start, length: end - start), with: result, select: NSRange(location: start, length: (result as NSString).length), actionName: "Format")
                return
            }
        }
        let line = document.lines[document.lineIndex(containing: selection.location)]
        if let span = line.spans.first(where: { format.matches($0.kind) && $0.range.location <= selection.location && $0.range.upperBound >= selection.upperBound }) {
            let content = nsText.substring(with: span.content)
            let caret = selection.location - (span.content.location - span.range.location)
            replace(span.range, with: content, select: NSRange(location: max(span.range.location, caret), length: selection.length > 0 ? (content as NSString).length : 0), actionName: "Format")
            return
        }
        let marker = format.marker
        let markerLength = (marker as NSString).length
        if selection.length == 0 {
            replace(selection, with: marker + marker, select: NSRange(location: selection.location + markerLength, length: 0), actionName: "Format")
            return
        }
        wrap(selection, in: marker)
    }

    /// Puts a marker around the selected words of each line the selection touches. A line's own punctuation
    /// (`- [ ] `, `## `, `> `) and the spaces around the words stay outside, or no other app would see a list, a
    /// heading or the emphasis any more. Returns false when no words are selected.
    @discardableResult
    func wrap(_ selection: NSRange, in marker: String) -> Bool {
        guard !document.lines.isEmpty, selection.length > 0 else { return false }
        let text = nsText
        let markerLength = (marker as NSString).length
        let pieces = wordRanges(in: selection)
        guard let start = pieces.first?.location, let end = pieces.last?.upperBound else { return false }
        var result = ""
        var location = start
        for piece in pieces {
            result += text.substring(with: NSRange(location: location, length: piece.location - location)) + marker + text.substring(with: piece) + marker
            location = piece.upperBound
        }
        return replace(NSRange(location: start, length: end - start), with: result, select: NSRange(location: start + markerLength, length: end - start + 2 * markerLength * (pieces.count - 1)), actionName: "Format")
    }

    /// The selected words of each line, without the line's own punctuation and the spaces around them; in a table
    /// only words within one cell.
    private func wordRanges(in selection: NSRange) -> [NSRange] {
        guard !document.lines.isEmpty, selection.length > 0 else { return [] }
        let text = nsText
        let first = document.lineIndex(containing: selection.location)
        let last = document.lineIndex(containing: selection.upperBound - 1)
        var pieces: [NSRange] = []
        for index in first...last {
            let line = document.lines[index]
            switch line.kind {
            case .blank, .thematicBreak, .fence, .code, .mathDelimiter, .math, .tableDelimiter, .frontmatterDelimiter, .frontmatter, .markup, .comment: continue
            default: break
            }
            var range = NSIntersectionRange(selection, NSRange(location: line.content.location, length: line.range.upperBound - line.content.location))
            // Half of an emoji is no space.
            func isSpace(_ index: Int) -> Bool { UnicodeScalar(text.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
            while range.length > 0, isSpace(range.location) { range.location += 1; range.length -= 1 }
            while range.length > 0, isSpace(range.upperBound - 1) { range.length -= 1 }
            // In a table, only the words of one cell.
            if line.kind == .tableHeader || line.kind == .tableRow, text.substring(with: range).contains("|") { continue }
            if range.length > 0 { pieces.append(range) }
        }
        return pieces
    }

    enum LineFormat {
        case body, heading(Int), bullets, numbered, checklist, quote
    }

    /// Turns the lines the selection touches into headings, list items, tasks, quotes or plain text.
    func setLineFormat(_ format: LineFormat) {
        let selection = self.selection
        guard !document.lines.isEmpty else { return }
        // Picked rather than typed: the #s of a heading don't show on a touch keyboard.
        typedHeading = nil
        let text = nsText
        let first = document.lineIndex(containing: selection.location)
        let last = document.lineIndex(containing: max(selection.location, selection.upperBound - (selection.length > 0 ? 1 : 0)))
        let range = NSRange(location: document.lines[first].range.location, length: document.lines[last].range.upperBound - document.lines[first].range.location)

        // Applying a list format to lines that all have it already takes it off.
        let all = (first...last).allSatisfy { index -> Bool in
            let kind = document.lines[index].kind
            switch (format, kind) {
            case (.bullets, .listItem(let item)): return !item.isOrdered && !item.isTask
            case (.numbered, .listItem(let item)): return item.isOrdered && !item.isTask
            case (.checklist, .listItem(let item)): return item.isTask
            case (.quote, .quote): return true
            case (.heading(let level), .heading(let existing, _)): return level == existing
            default: return false
            }
        }
        var number = 1
        var lines: [String] = []
        for index in first...last {
            let line = document.lines[index]
            let content = text.substring(with: NSRange(location: line.content.location, length: line.range.upperBound - line.content.location))
            var indent = ""
            if case .listItem(let item) = line.kind { indent = text.substring(with: item.indentRange) }
            if line.kind == .blank, first != last { lines.append(""); continue }
            let prefix: String
            switch all ? .body : format {
            case .body: prefix = ""; indent = ""
            case .heading(let level): prefix = String(repeating: syntax == .asciidoc ? "=" : "#", count: level) + " "; indent = ""
            case .bullets: prefix = syntax == .asciidoc ? "* " : "- "
            case .numbered:
                prefix = syntax == .asciidoc ? ". " : "\(number). "
                number += 1
            case .checklist: prefix = syntax == .asciidoc ? "* [ ] " : "- [ ] "
            case .quote: prefix = "> "; indent = ""
            }
            lines.append(indent + prefix + content)
        }
        let result = lines.joined(separator: "\n")
        let caretOffset = selection.location - document.lines[first].content.location
        let newPrefix = (lines.first.map { ($0 as NSString).length } ?? 0) - (text.substring(with: NSRange(location: document.lines[first].content.location, length: document.lines[first].range.upperBound - document.lines[first].content.location)) as NSString).length
        let caret = range.location + max(0, newPrefix) + max(0, caretOffset)
        replace(range, with: result, select: selection.length > 0 ? NSRange(location: range.location, length: (result as NSString).length) : NSRange(location: min(caret, range.location + (result as NSString).length), length: 0), actionName: "Format")
    }

    /// ⌘⇧U as in Notes: ticks or unticks the tasks the selection touches.
    func toggleChecked() {
        let selection = self.selection
        guard !document.lines.isEmpty else { return }
        let index = document.lineIndex(containing: selection.location)
        toggleCheckbox(line: index)
    }

    func insertLink() {
        let selection = self.selection
        if selection.length > 0, syntax == .asciidoc {
            // `link:#[words]` until the address is typed in the link editor.
            let selected = nsText.substring(with: selection)
            replace(selection, with: "link:#[" + selected + "]", select: NSRange(location: selection.upperBound + 7, length: 0), actionName: "Add Link")
            editLink(at: NSRange(location: selection.location, length: selection.length + 8), isNew: true)
        } else if selection.length > 0 {
            let selected = nsText.substring(with: selection)
            replace(selection, with: "[" + selected + "]()", select: NSRange(location: selection.upperBound + 1, length: 0), actionName: "Add Link")
            // The address goes in with the link editor, as the address itself is never shown in the text.
            editLink(at: NSRange(location: selection.location, length: selection.length + 4), isNew: true)
        } else {
            replace(selection, with: "[[]]", select: NSRange(location: selection.location + 2, length: 0), actionName: "Add Link")
            suggestionAnchor = selection.location + 2
            updateSuggestions()
        }
    }
}

extension MarkdownSyntax.Style {
    /// The marks the editor puts around words of its own accord.
    var marker: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        case .code: "`"
        case .strikethrough: "~~"
        case .highlight: "=="
        }
    }

    func matches(_ kind: InlineSpan.Kind) -> Bool {
        switch (self, kind) {
        case (.bold, .strong), (.italic, .emphasis), (.code, .code), (.strikethrough, .strikethrough), (.highlight, .highlight): true
        default: false
        }
    }
}
