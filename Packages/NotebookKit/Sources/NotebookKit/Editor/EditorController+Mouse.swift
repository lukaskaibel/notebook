#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Clicks on the things drawn in place of Markdown: a checkbox ticks, a link opens, a picture is selected like a
/// character, a table or diagram opens for editing right where you clicked.
extension EditorController {
    enum Hit: Equatable {
        case checkbox(line: Int)
        case link(LinkTarget.Kind)
        case picture(range: NSRange, url: URL?)
        case block(index: Int, caret: Int)
        case editLink(range: NSRange)
        case headingLevel(line: Int)
        case todo(line: Int, part: TodoPart)
        /// A table's handle, or a + along its edge.
        case table(TableControl)
    }

    func hitTest(_ point: NSPoint) -> Hit? {
        guard storage.length > 0 else { return nil }
        #if os(macOS)
        if let control = tableControl(at: point, slop: 3) { return .table(control) }
        #else
        if let control = tableControl(at: point, slop: 12) { return .table(control) }
        #endif
        let origin = textOrigin
        // The level tag in the margin next to the heading the caret is on.
        if point.x < origin.x, let (_, marker) = headingMarkLevel,
           let rect = layoutManager.headingMarkRect(at: marker.location, origin: origin), rect.insetBy(dx: -4, dy: -4).contains(point) {
            return .headingLevel(line: document.lineIndex(containing: marker.location))
        }
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -1, dy: -2).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)

        if layoutManager.propertyForGlyph(at: glyph) == .controlCharacter, let object = layoutManager.object(at: index) {
            let range = object.range(at: index)
            switch object.kind {
            case .checkbox:
                return .checkbox(line: document.lineIndex(containing: index))
            case .image(let url, _, _):
                return .picture(range: range, url: url)
            case .drawing(let url):
                return .picture(range: range, url: url)
            case .fileCard(let url, _):
                return .picture(range: range, url: url)
            case .noteEmbed(let target, _):
                return .link(.note(target))
            case .table(let model):
                guard let blockIndex = document.line(containing: index)?.block else { return nil }
                let objectRect = layoutManager.blockObjectRect(at: index, origin: origin).map { NSRect(x: $0.minX, y: $0.minY, width: $0.width - 1, height: $0.height) }
                    ?? rect.offsetBy(dx: origin.x, dy: origin.y)
                return .block(index: blockIndex, caret: tableCaret(at: point, block: blockIndex, model: model, objectRect: objectRect))
            case .mermaid, .mathBlock, .frontmatter:
                guard let blockIndex = document.line(containing: index)?.block else { return nil }
                let block = document.blocks[blockIndex]
                let line = block.lines.count > 1 ? document.lines[block.lines.lowerBound + 1] : document.lines[block.lines.lowerBound]
                return .block(index: blockIndex, caret: line.range.upperBound)
            case .linkEdit:
                return .editLink(range: range)
            case .todoPill(let pill):
                // With To-dos off, a date is only words.
                return pill.isField || !NotebookSettings.shared.showsTodos ? nil : .todo(line: document.lineIndex(containing: index), part: pill.isPlace ? .place : .date)
            case .chipLead, .chipTrail:
                if let link = storage.attribute(.notebookLink, at: index, effectiveRange: nil) as? LinkTarget { return .link(link.kind) }
                return nil
            default:
                return nil
            }
        }
        if let link = storage.attribute(.notebookLink, at: index, effectiveRange: nil) as? LinkTarget {
            // A link you are editing (its Markdown showing) takes clicks as text.
            if case .note = link.kind { return .link(link.kind) }
            if !isRevealed(index) { return .link(link.kind) }
        }
        return nil
    }

    /// Puts the caret into a table or diagram where it was clicked, keeping the line with the caret under the pointer
    /// as the block opens up.
    func openBlock(caret: Int, at point: NSPoint) {
        let clickOffset = point.y - scrollTop
        makeTextFirstResponder()
        // A table typed in as a grid keeps its size: nothing moves.
        if gridTable(at: caret) != nil {
            setSelection(NSRange(location: caret, length: 0))
            return
        }
        setSelection(NSRange(location: caret, length: 0))
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, caret + 1)))
        let lineTop = yPosition(of: caret)
        let lineHeight = EditorStyle.codeLineHeight
        let target = lineTop + lineHeight / 2 - clickOffset
        setScrollTop(min(max(-topInset, target), maxScrollTop))
    }

    #if os(macOS)
    /// Handles the click itself when it lands on something that isn't text; returns false to let AppKit place the
    /// caret or start a selection.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard let hit = hitTest(point) else { return false }
        // Clicks with a modifier key are the text view's, but for Option-dragging a picture, which copies it.
        var allowed: NSEvent.ModifierFlags = []
        if case .picture = hit { allowed = .option }
        if case .block(_, let caret) = hit, gridTable(at: caret) != nil { allowed = .shift }
        if !modifiers.subtracting(allowed).isEmpty { return false }
        switch hit {
        case .checkbox(let line):
            // A double-click ticks once.
            if event.clickCount == 1 { toggleCheckbox(line: line) }
            return true
        case .link(let kind):
            closeSuggestions()
            follow(kind)
            return true
        case .picture(let range, let url):
            // Pressed in text selected around it: the text view drags the selection, as it drags any selected text.
            let selected = selection
            if event.clickCount == 1, selected.length > range.length, NSIntersectionRange(selected, range) == range { return false }
            textView.window?.makeFirstResponder(textView)
            setSelection(range)
            // A double-click opens a drawing for drawing, and any other picture in Quick Look.
            if event.clickCount >= 2, let drawing = drawing(at: range) {
                beginDrawing(in: drawing)
            } else if event.clickCount >= 2, let url {
                delegate?.editor(self, quickLook: url)
            } else {
                dragObjectIfMoved(range, from: event)
            }
            return true
        case .editLink(let range):
            editLink(at: range)
            return true
        case .headingLevel:
            showHeadingMenu(at: point)
            return true
        case .todo(let line, let part):
            showTodoReminder(line: line, part: part)
            return true
        case .block(_, let caret):
            if let grid = gridTable(at: caret) {
                selectInGrid(grid, from: caret, with: event)
            } else {
                openBlock(caret: caret, at: point)
            }
            return true
        case .table(let control):
            useTableControl(control)
            return true
        }
    }

    /// A click in a cell of a table typed in as a grid: the caret at the letter clicked; a drag selects in the cell, a
    /// double-click a word, a triple-click the cell's text.
    private func selectInGrid(_ grid: GridTable, from caret: Int, with event: NSEvent) {
        textView.window?.makeFirstResponder(textView)
        guard let (row, column) = grid.cell(at: caret) else { return }
        let content = grid.contents[row][column]
        if event.modifierFlags.contains(.shift), selection.location >= content.location, selection.location <= max(content.upperBound, grid.slots[row][column].upperBound) {
            let anchor = selection.location
            setSelection(NSRange(location: min(anchor, caret), length: abs(caret - anchor)))
            return
        }
        switch event.clickCount {
        case 2:
            let word = textView.selectionRange(forProposedRange: NSRange(location: caret, length: 0), granularity: .selectByWord)
            setSelection(NSIntersectionRange(word, content).length > 0 ? NSIntersectionRange(word, content) : NSRange(location: caret, length: 0))
            return
        case 3...:
            setSelection(content)
            return
        default:
            setSelection(NSRange(location: caret, length: 0))
        }
        // Dragging: the selection grows from the click, within its cell.
        textView.isTrackingMouse = true
        defer {
            textView.isTrackingMouse = false
            mouseTrackingEnded()
        }
        while let next = textView.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = textView.convert(next.locationInWindow, from: nil)
            textView.autoscroll(with: next)
            guard let table = gridTable(at: caret), let index = gridIndex(at: point, in: table, cell: (row, column)) else { continue }
            setSelection(NSRange(location: min(caret, index), length: abs(index - caret)))
        }
    }

    /// A table's handle opens its menu, the row or column it is for picked while it is open; a + adds at the edge.
    private func useTableControl(_ control: TableControl) {
        switch control {
        case .columnHandle(let block, let column):
            guard let start = document.blocks[safe: block]?.range.location, let grid = gridTable(at: start), let drawn = gridDrawing(grid),
                  let handle = drawn.model.columnHandleRect(in: drawn.rect) else { return }
            showTableBand(.column(column), block: block)
            GlassMenu.show(tableColumnEntries(column: column), at: handle, in: textView) { [weak self] in self?.showTableBand(nil, block: nil) }
        case .rowHandle(let block, let row):
            guard let start = document.blocks[safe: block]?.range.location, let grid = gridTable(at: start), let drawn = gridDrawing(grid),
                  let handle = drawn.model.rowHandleRect(in: drawn.rect) else { return }
            showTableBand(.row(row), block: block)
            GlassMenu.show(tableRowEntries(row: row), at: handle, in: textView) { [weak self] in self?.showTableBand(nil, block: nil) }
        case .addColumn(let block):
            addAtEdge(of: block, column: true)
        case .addRow(let block):
            addAtEdge(of: block, column: false)
        }
    }

    func updateCursor(for event: NSEvent) {
        let point = textView.convert(event.locationInWindow, from: nil)
        if isDrawing, canvas(at: point) != nil { return NSCursor.crosshair.set() }
        if !textView.copyButton.isHidden, textView.copyButton.frame.contains(point) { return NSCursor.arrow.set() }
        if !textView.todoBell.isHidden, textView.todoBell.frame.contains(point) { return NSCursor.arrow.set() }
        switch hitTest(point) {
        case .checkbox, .link, .editLink, .headingLevel, .todo: NSCursor.pointingHand.set()
        case .table: NSCursor.arrow.set()
        case .picture: NSCursor.arrow.set()
        case .block(_, let caret): if gridTable(at: caret) != nil { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
        case nil: break
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        // ⇧Return breaks an AsciiDoc line with ` +`, as ⌃Return does: macOS has no command of its own for it and would
        // send Return.
        if syntax == .asciidoc, [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift,
           !textView.hasMarkedText(), insertAsciiDocLineBreak() {
            return true
        }
        // Space on a selected picture opens Quick Look, as in the Finder.
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            let selection = self.selection
            if selection.length > 0, let object = layoutManager.object(at: selection.location), object.range(at: selection.location) == selection {
                switch object.kind {
                case .image(let url, _, _), .fileCard(let url, _):
                    if let url { delegate?.editor(self, quickLook: url) }
                    return true
                case .drawing(let url):
                    delegate?.editor(self, quickLook: url)
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    func contextMenu(for event: NSEvent, base: NSMenu?) -> NSMenu? {
        let point = textView.convert(event.locationInWindow, from: nil)
        if case .picture(let range, let url) = hitTest(point) {
            setSelection(range)
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector, _ symbol: String, _ object: Any? = nil) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.representedObject = object
                menu.addItem(item)
            }
            if let drawing = drawing(at: range) {
                add("Edit Drawing", #selector(MarkdownTextView.editDrawing(_:)), "pencil.tip.crop.circle", drawing)
            }
            if let url {
                add("Quick Look", #selector(MarkdownTextView.quickLookSelection(_:)), "eye", url)
                add("Show in Finder", #selector(MarkdownTextView.revealSelection(_:)), "folder", url)
                menu.addItem(.separator())
            }
            add("Cut", #selector(NSText.cut(_:)), "scissors")
            add("Copy", #selector(NSText.copy(_:)), "doc.on.doc")
            add("Delete", #selector(NSText.delete(_:)), "trash")
            if let delete = menu.items.last {
                delete.attributedTitle = NSAttributedString(string: delete.title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
            }
            return menu
        }
        if let base {
            addCopyCode(to: base, at: point)
            addTodoReminder(to: base, at: point)
            addTableItems(to: base, at: point)
        }
        return base
    }

    /// Right-clicked in a cell of a table typed in as a grid: the caret goes there, and the table's menu comes after the
    /// rest.
    private func addTableItems(to menu: NSMenu, at point: NSPoint) {
        guard case .block(_, let caret) = hitTest(point), gridTable(at: caret) != nil else { return }
        if !NSLocationInRange(caret, NSRange(location: selection.location, length: selection.length + 1)) { setSelection(NSRange(location: caret, length: 0)) }
        let table = NSMenu(title: "Table")
        for entry in tableEntries() {
            switch entry.kind {
            case .divider:
                table.addItem(.separator())
            case .action(let action):
                let item = ClosureMenuItem(title: entry.title) { action() }
                if case .symbol(let name) = entry.icon { item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
                item.isDestructive = entry.isDestructive
                table.addItem(item)
            default:
                break
            }
        }
        let item = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        item.submenu = table
        menu.addItem(.separator())
        menu.addItem(item)
    }
    #endif
}

#if os(macOS)
extension EditorController {
    /// The text view's right-click menu as glass entries: the system's own items, Cut, Copy and Paste with their keys,
    /// and Format after them, as the Aa menu has it.
    func glassEntries(from menu: NSMenu) -> [MenuEntry] {
        let keys: [Selector: String] = [
            #selector(NSText.cut(_:)): "⌘X",
            #selector(NSText.copy(_:)): "⌘C",
            #selector(NSText.paste(_:)): "⌘V",
            #selector(NSText.selectAll(_:)): "⌘A",
        ]
        menu.update()
        var entries: [MenuEntry] = []
        var formatGoesNext = false
        for item in menu.items {
            if formatGoesNext, item.isSeparatorItem || item === menu.items.last {
                formatGoesNext = false
                if item === menu.items.last, let entry = GlassMenu.entry(item) { entries.append(entry) }
                entries.append(.divider)
                entries.append(.submenu("Format", "textformat") { [weak self] in
                    guard let self else { return [] }
                    return SharedMenus.format(self, styleSize: MenuMetrics.mac.fontSize)
                })
                if item === menu.items.last { continue }
            }
            // Not what a note needs: its quotes and dashes are Markdown's, and it is never written top to bottom.
            if let submenu = item.submenu, submenu.items.contains(where: { [#selector(NSTextView.changeLayoutOrientation(_:)), #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))].contains($0.action) }) {
                continue
            }
            guard var entry = GlassMenu.entry(item) else { continue }
            if let action = item.action, let key = keys[action], entry.keys == nil { entry.keys = key }
            entries.append(entry)
            if item.action == #selector(NSText.paste(_:)), syntax == .markdown, textView.isEditable { formatGoesNext = true }
        }
        return entries
    }
}

extension MarkdownTextView {
    @objc func quickLookSelection(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let controller else { return }
        controller.delegate?.editor(controller, quickLook: url)
    }

    @objc func editDrawing(_ sender: NSMenuItem) {
        guard let picture = sender.representedObject as? URL else { return }
        controller?.beginDrawing(in: picture)
    }

    @objc func revealSelection(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Formatting, sent by the menus to whatever text view has the focus.
    @objc func toggleBoldface(_ sender: Any?) { controller?.toggle(.bold) }
    @objc func toggleItalics(_ sender: Any?) { controller?.toggle(.italic) }
    @objc func toggleInlineCode(_ sender: Any?) { controller?.toggle(.code) }
    @objc func toggleStrikethrough(_ sender: Any?) { controller?.toggle(.strikethrough) }
    @objc func toggleHighlight(_ sender: Any?) { controller?.toggle(.highlight) }
    @objc func makeTitle(_ sender: Any?) { controller?.setLineFormat(.heading(1)) }
    @objc func makeHeading(_ sender: Any?) { controller?.setLineFormat(.heading(2)) }
    @objc func makeSubheading(_ sender: Any?) { controller?.setLineFormat(.heading(3)) }
    @objc func makeBody(_ sender: Any?) { controller?.setLineFormat(.body) }
    @objc func makeBulletedList(_ sender: Any?) { controller?.setLineFormat(.bullets) }
    @objc func makeNumberedList(_ sender: Any?) { controller?.setLineFormat(.numbered) }
    @objc func makeChecklist(_ sender: Any?) { controller?.setLineFormat(.checklist) }
    @objc func makeQuote(_ sender: Any?) { controller?.setLineFormat(.quote) }
    @objc func insertTable(_ sender: Any?) { controller?.insertTable() }
    @objc func addTableRowAbove(_ sender: Any?) { controller?.editTable(.addRow(above: true)) }
    @objc func addTableRowBelow(_ sender: Any?) { controller?.editTable(.addRow(above: false)) }
    @objc func addTableColumnLeft(_ sender: Any?) { controller?.editTable(.addColumn(left: true)) }
    @objc func addTableColumnRight(_ sender: Any?) { controller?.editTable(.addColumn(left: false)) }
    @objc func deleteTableRow(_ sender: Any?) { controller?.editTable(.deleteRow) }
    @objc func deleteTableColumn(_ sender: Any?) { controller?.editTable(.deleteColumn) }
    @objc func deleteTable(_ sender: Any?) { controller?.editTable(.deleteTable) }
    @objc func markChecked(_ sender: Any?) { controller?.toggleChecked() }
    @objc func addLink(_ sender: Any?) { controller?.insertLink() }
    @objc func indentLines(_ sender: Any?) { controller?.indent(by: 1) }
    @objc func outdentLines(_ sender: Any?) { controller?.indent(by: -1) }

    // Spelling and Grammar in the context menu sets it for every note, as the Edit menu does.
    override func toggleContinuousSpellChecking(_ sender: Any?) { NotebookSettings.shared.checksSpelling.toggle() }
    override func toggleGrammarChecking(_ sender: Any?) { NotebookSettings.shared.checksGrammar.toggle() }
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) { NotebookSettings.shared.correctsSpelling.toggle() }
}
#endif
