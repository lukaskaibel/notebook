#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Clicks on the things drawn in place of Markdown: a checkbox ticks, a link opens, a picture is selected like a
/// character, a table or diagram opens for editing right where you clicked.
extension EditorController {
    enum Hit {
        case checkbox(line: Int)
        case link(LinkTarget.Kind)
        case picture(range: NSRange, url: URL?)
        case block(index: Int, caret: Int)
        case editLink(range: NSRange)
        case headingLevel(line: Int)
        case todo(line: Int, part: TodoPart)
    }

    func hitTest(_ point: NSPoint) -> Hit? {
        guard storage.length > 0 else { return nil }
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
                let objectRect = rect.offsetBy(dx: origin.x, dy: origin.y)
                var caret = document.blocks[blockIndex].range.location
                if let cell = model.cell(at: point, in: objectRect), let ranges = model.cellRanges[safe: cell.row] {
                    caret = ranges[safe: cell.column]?.upperBound ?? ranges.last?.upperBound ?? caret
                }
                return .block(index: blockIndex, caret: caret)
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
        if !event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty { return false }
        guard let hit = hitTest(point) else { return false }
        switch hit {
        case .checkbox(let line):
            toggleCheckbox(line: line)
            return true
        case .link(let kind):
            closeSuggestions()
            delegate?.editor(self, open: kind)
            return true
        case .picture(let range, let url):
            textView.window?.makeFirstResponder(textView)
            setSelection(range)
            // A double-click opens a drawing for drawing, and any other picture in Quick Look.
            if event.clickCount >= 2, let drawing = drawing(at: range) {
                beginDrawing(in: drawing)
            } else if event.clickCount >= 2, let url {
                delegate?.editor(self, quickLook: url)
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
            openBlock(caret: caret, at: point)
            return true
        }
    }

    func updateCursor(for event: NSEvent) {
        let point = textView.convert(event.locationInWindow, from: nil)
        if isDrawing, canvas(at: point) != nil { return NSCursor.crosshair.set() }
        if !textView.copyButton.isHidden, textView.copyButton.frame.contains(point) { return NSCursor.arrow.set() }
        if !textView.todoBell.isHidden, textView.todoBell.frame.contains(point) { return NSCursor.arrow.set() }
        switch hitTest(point) {
        case .checkbox, .link, .editLink, .headingLevel, .todo: NSCursor.pointingHand.set()
        case .picture, .block: NSCursor.arrow.set()
        case nil: break
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
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
            return menu
        }
        if let base {
            addCopyCode(to: base, at: point)
            addTodoReminder(to: base, at: point)
        }
        return base
    }
    #endif
}

#if os(macOS)
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
    @objc func markChecked(_ sender: Any?) { controller?.toggleChecked() }
    @objc func addLink(_ sender: Any?) { controller?.insertLink() }
    @objc func indentLines(_ sender: Any?) { controller?.indent(by: 1) }
    @objc func outdentLines(_ sender: Any?) { controller?.indent(by: -1) }
}
#endif
