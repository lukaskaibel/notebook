import AppKit
import XCTest
@testable import NotebookKit

/// How the editor behaves under a person's hands: what shows next to the caret, what a selection takes, what Return,
/// Backspace and Tab do, and that nothing moves while you select.
@MainActor
final class EditorBehaviorTests: XCTestCase {
    // MARK: - Showing Markdown next to the caret

    func testCaretRevealsSpanAndLeavingHidesIt() {
        let h = EditorHarness("Five days in **October** in Kyoto.")
        let bold = h.range(of: "October")
        h.caret(bold.location + 3)
        XCTAssertTrue(h.isVisible(bold.location - 1), "markers show while the caret is in the span")
        h.caret(h.range(of: "Kyoto").location)
        XCTAssertFalse(h.isVisible(bold.location - 1), "markers hide when the caret leaves")
    }

    func testSelectingDoesNotReveal() {
        let h = EditorHarness("Five days in **October** in Kyoto.")
        let bold = h.range(of: "October")
        h.caret(h.range(of: "Kyoto").location)
        h.select(NSRange(location: 0, length: bold.upperBound + 2))
        XCTAssertFalse(h.isVisible(bold.location - 1), "selecting over a span doesn't show its markers")
        XCTAssertTrue(h.editor.revealed.isEmpty)
    }

    func testDragSelectionKeepsLayoutStill() {
        let h = EditorHarness("Five days in **October** in Kyoto and more text after it.\nSecond line")
        // The caret rests in the bold span, so its markers show.
        let bold = h.range(of: "October")
        h.caret(bold.location + 2)
        XCTAssertTrue(h.isVisible(bold.location - 1))
        let kyoto = h.range(of: "Kyoto")
        let start = h.point(of: kyoto.location, fraction: 0.1)
        let end = h.point(of: kyoto.upperBound - 1, fraction: 0.9)
        let x = h.point(of: kyoto.location).x
        h.click(at: start, dragTo: end)
        XCTAssertEqual(h.selection, kyoto, "the drag selects what was under the pointer")
        XCTAssertEqual(h.point(of: kyoto.location).x, x, accuracy: 0.5, "nothing moves when the button comes up")
        h.click(at: h.point(of: h.range(of: "Second").location))
        XCTAssertFalse(h.isVisible(bold.location - 1), "a caret elsewhere hides the markers again")
    }

    func testClickPlacesCaretAndRevealsAfterMouseUp() {
        let h = EditorHarness("Five days in **October** in Kyoto.")
        let bold = h.range(of: "October")
        h.click(at: h.point(of: bold.location + 3, fraction: 0.0))
        XCTAssertEqual(h.selection, NSRange(location: bold.location + 3, length: 0))
        XCTAssertTrue(h.isVisible(bold.location - 1))
    }

    func testRevealDoesNotMoveOtherLines() {
        let h = EditorHarness("A short **bold** line.\nNext line\nThird")
        let next = h.range(of: "Third")
        let before = h.editor.yPosition(of: next.location)
        h.caret(h.range(of: "bold").location + 1)
        let after = h.editor.yPosition(of: next.location)
        XCTAssertEqual(before, after, accuracy: 0.5)
    }

    // MARK: - The caret

    /// The caret AppKit proposes at a place, as tall as the line without its spacing, and the one the editor draws.
    private func caret(_ h: EditorHarness, at index: Int) -> (proposed: NSRect, drawn: NSRect) {
        h.caret(index)
        let glyph = h.editor.layoutManager.glyphIndexForCharacter(at: index)
        let line = h.editor.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let proposed = NSRect(x: 100, y: h.textView.textContainerOrigin.y + line.minY, width: 1, height: line.height)
        return (proposed, h.editor.caretRect(proposed: proposed))
    }

    func testCaretStaysInItsLineAndSitsWhereTextDoes() {
        let h = EditorHarness("# Kick-off\n\nFive days in October.\n\nPlain paragraph.")
        let text = caret(h, at: h.range(of: "days").location)
        let places = [
            "end of a line": caret(h, at: h.range(of: "October.").upperBound),
            "empty line": caret(h, at: h.range(of: "October.").upperBound + 1),
            "empty line under a heading": caret(h, at: h.range(of: "Kick-off").upperBound + 1),
        ]
        for (place, caret) in places {
            // Blinking redraws only the proposed rectangle: any of the caret outside it would stay on screen.
            XCTAssertGreaterThanOrEqual(caret.drawn.minY, caret.proposed.minY, place)
            XCTAssertLessThanOrEqual(caret.drawn.maxY, caret.proposed.maxY, place)
            XCTAssertEqual(caret.drawn.minY - caret.proposed.minY, text.drawn.minY - text.proposed.minY, accuracy: 0.1, place)
            XCTAssertEqual(caret.drawn.height, text.drawn.height, accuracy: 0.1, place)
        }
    }

    /// The rows of part of the text view with ink on them, from the top of the first to the bottom of the last.
    private func ink(_ h: EditorHarness, in rect: NSRect) -> ClosedRange<CGFloat>? {
        h.settle(0)
        guard let bitmap = h.textView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        h.textView.cacheDisplay(in: rect, to: bitmap)
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.alphaComponent > 0.5 && color.brightnessComponent < 0.5
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        let scale = CGFloat(bitmap.pixelsHigh) / rect.height
        return rect.minY + CGFloat(first) / scale...rect.minY + CGFloat(last + 1) / scale
    }

    func testCaretReachesFromAboveTheTextToBelowIt() throws {
        let h = EditorHarness("Hy there\n\n## Hy there")
        for start in [0, h.range(of: "## Hy").location + 3] {
            let caret = caret(h, at: start + 1)
            let font = try XCTUnwrap(h.editor.storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)
            func glyph(_ offset: Int) throws -> ClosedRange<CGFloat> {
                let glyphs = h.editor.layoutManager.glyphRange(forCharacterRange: NSRange(location: start + offset, length: 1), actualCharacterRange: nil)
                let rect = h.editor.layoutManager.boundingRect(forGlyphRange: glyphs, in: h.editor.container)
                return try XCTUnwrap(ink(h, in: NSRect(x: rect.minX + h.textView.textContainerOrigin.x, y: caret.proposed.minY, width: rect.width, height: caret.proposed.height)))
            }
            // The H stands on the baseline; the caret reaches a point past the font's ascender above it and its
            // descender below, so past the tail of the y.
            let capital = try glyph(0), descender = try glyph(1)
            XCTAssertEqual(caret.drawn.maxY, capital.upperBound - font.descender + 1, accuracy: 0.75, font.description)
            XCTAssertEqual(caret.drawn.minY, capital.upperBound - font.ascender - 1, accuracy: 0.75, font.description)
            XCTAssertGreaterThan(caret.drawn.maxY, descender.upperBound, font.description)
        }
    }

    // MARK: - Selections take things whole

    func testSelectingBoldTextTakesItsMarkers() {
        let h = EditorHarness("keep **this** word")
        let content = h.range(of: "this")
        h.select(content)
        XCTAssertEqual(h.selection, NSRange(location: content.location - 2, length: content.length + 4))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "keep  word")
    }

    func testPartOfBoldKeepsMarkers() {
        let h = EditorHarness("keep **this** word")
        let content = h.range(of: "this")
        h.select(NSRange(location: content.location, length: 2))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "keep **is** word")
    }

    func testSelectionAcrossPictureTakesItWhole() {
        let h = EditorHarness("Before\n![](.assets/torii.png)\nAfter")
        let image = h.range(of: "![](.assets/torii.png)")
        // A selection ending in the middle of the picture's Markdown grows to take all of it.
        h.select(NSRange(location: 2, length: image.location + 5 - 2))
        XCTAssertEqual(h.selection.upperBound, image.upperBound)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Be\nAfter")
    }

    func testClickOnPictureSelectsIt() {
        let h = EditorHarness("Before\n![](.assets/torii.png)\nAfter")
        let image = h.range(of: "![](.assets/torii.png)")
        let rect = h.editor.layoutManager.rect(forObjectAt: image.location, origin: h.textView.textContainerOrigin)!
        h.click(at: NSPoint(x: rect.minX + 30, y: h.editor.yPosition(of: image.location) + 40))
        XCTAssertEqual(h.selection, image)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Before\n\nAfter")
    }

    func testBackspaceAfterLinkDeletesWholeLink() {
        let h = EditorHarness("see [[Budget]] now")
        let link = h.range(of: "[[Budget]]")
        h.caret(link.upperBound)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "see  now")
    }

    func testCaretStepsOverLink() {
        let h = EditorHarness("see [[Budget]] now")
        let link = h.range(of: "[[Budget]]")
        h.caret(link.location)
        h.command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(h.selection.location, link.upperBound)
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(h.selection.location, link.location)
    }

    func testCopyGivesMarkdown() {
        let h = EditorHarness("keep **this** word")
        h.select(h.range(of: "this"))
        h.textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "**this**")
    }

    // MARK: - Lists

    func testCaretStepsAroundBullets() {
        let h = EditorHarness("Intro\n- [ ] Task")
        let task = h.range(of: "Task")
        h.caret(h.range(of: "Intro").upperBound)
        h.command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(h.selection.location, task.location, "right from the end of the line above lands in the item's text")
        h.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(h.selection.location, h.range(of: "Intro").upperBound, "left from the item's text goes back up")
    }

    func testReturnContinuesAndEndsLists() {
        let h = EditorHarness("- [x] Passport")
        h.caret(h.text.utf16.count)
        h.type("\nAdapter")
        XCTAssertEqual(h.text, "- [x] Passport\n- [ ] Adapter")
        h.type("\n")
        XCTAssertEqual(h.text, "- [x] Passport\n- [ ] Adapter\n- [ ] ")
        h.type("\n")
        XCTAssertEqual(h.text, "- [x] Passport\n- [ ] Adapter\n", "Return on an empty item ends the list")
    }

    func testNumberedListsCount() {
        let h = EditorHarness("1. First")
        h.caret(h.text.utf16.count)
        h.type("\nSecond\nThird")
        XCTAssertEqual(h.text, "1. First\n2. Second\n3. Third")
    }

    func testBackspaceAtItemStartRemovesBullet() {
        let h = EditorHarness("- Item")
        h.caret(h.range(of: "Item").location)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Item")
    }

    func testTabNestsAndShiftTabUnnests() {
        let h = EditorHarness("- One\n- Two")
        h.caret(h.range(of: "Two").location + 1)
        h.command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(h.text, "- One\n  - Two")
        XCTAssertEqual(h.selection.location, h.range(of: "Two").location + 1, "the caret stays in the text")
        h.command(#selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(h.text, "- One\n- Two")
    }

    func testCheckboxClickToggles() {
        let h = EditorHarness("- [ ] Task")
        let rect = h.editor.layoutManager.rect(forObjectAt: 2, origin: h.textView.textContainerOrigin)!
        h.click(at: NSPoint(x: rect.minX + 8, y: rect.midY))
        XCTAssertEqual(h.text, "- [x] Task")
        h.click(at: NSPoint(x: rect.minX + 8, y: rect.midY))
        XCTAssertEqual(h.text, "- [ ] Task")
    }

    func testTypingBracketsMakesTask() {
        let h = EditorHarness("")
        h.type("[] Buy milk")
        XCTAssertEqual(h.text, "- [ ] Buy milk")
    }

    // MARK: - Links

    func testDoubleBracketCompletes() {
        let h = EditorHarness("see ")
        h.caret(4)
        h.type("[[")
        XCTAssertEqual(h.text, "see [[]]")
        XCTAssertEqual(h.selection.location, 6)
        h.type("Bud")
        XCTAssertTrue(h.editor.suggestions.isVisible)
        XCTAssertEqual(h.editor.suggestions.selected?.title, "Budget")
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "see [[Budget]]")
        XCTAssertEqual(h.selection.location, h.text.utf16.count)
        XCTAssertFalse(h.editor.suggestions.isVisible)
    }

    func testClickOnLinkOpensIt() {
        let h = EditorHarness("see [[Budget]] now")
        h.click(at: h.point(of: h.range(of: "Budget").location + 2))
        XCTAssertEqual(h.opened, [.note("Budget")])
    }

    // MARK: - Blocks

    func testClickInTableOpensItAtTheCell() {
        let h = EditorHarness("Intro\n\n| A | B |\n| --- | --- |\n| one | two |\n\nAfter")
        let table = h.range(of: "| A |")
        let rect = h.editor.layoutManager.rect(forObjectAt: table.location, origin: h.textView.textContainerOrigin)
            ?? NSRect(x: h.textView.textContainerOrigin.x, y: h.editor.yPosition(of: table.location), width: 200, height: 100)
        // The second row, second column.
        h.click(at: NSPoint(x: rect.minX + 90, y: h.editor.yPosition(of: table.location) + 8 + 50))
        XCTAssertNotNil(h.editor.activeBlock)
        let two = h.range(of: "two")
        XCTAssertEqual(h.selection.location, two.upperBound)
    }

    func testATableTypedShowsItsSourceAfterTheCaretComesBack() {
        EditorHarness.withTablesAsMarkdown { tableTypedShowsItsSourceAfterTheCaretComesBack() }
    }

    private func tableTypedShowsItsSourceAfterTheCaretComesBack() {
        let h = EditorHarness("Steps")
        h.caret(h.text.utf16.count)
        h.type("\n\n| Key | Does |\n|---|---|\n| Up | Moves |")
        XCTAssertNotNil(h.editor.activeBlock, "the table being typed is open")
        XCTAssertEqual(h.text, "Steps\n\n| Key | Does |\n|---|---|\n| Up | Moves |", "a row typed by hand replaces the empty one Return made")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Up | Moves |")), "| Up | Moves |")
        // Return makes an empty row, and Return in it leaves the table.
        h.type("\n\nmore")
        XCTAssertNil(h.editor.activeBlock)
        XCTAssertFalse(h.isVisible(h.range(of: "| Up").location + 2), "left, it is drawn")
        for _ in 0..<6 { h.command(#selector(NSResponder.deleteBackward(_:))) }
        XCTAssertNotNil(h.editor.activeBlock, "back in it, it is open again")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Up | Moves |")), "| Up | Moves |", "and its source shows")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Key | Does |")), "| Key | Does |")
    }

    func testReturnInATableAddsARowInsteadOfBreakingIt() {
        let header = "| Week | Date   | Topic  |\n| ---- | ------ | ------ |\n"
        let empty = "|      |        |        |"
        let tables = { (h: EditorHarness) in h.editor.document.blocks.filter { if case .table = $0.kind { true } else { false } } }

        // At the end of a row in the middle of the table, as a tester did: an empty row under it, its pipes lined up
        // with the row's, the caret in its first cell, and still one table.
        var h = EditorHarness(header + "| 1    | 12.10. | Graphs |\n|      | 13.10. | Trees  |\n\nAfter")
        h.caret(h.range(of: "Graphs |").upperBound)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, header + "| 1    | 12.10. | Graphs |\n\(empty)\n|      | 13.10. | Trees  |\n\nAfter")
        XCTAssertEqual(h.selection.location, h.range(of: "Graphs |\n").upperBound + 2)
        h.type("2")
        XCTAssertEqual(tables(h).count, 1)
        XCTAssertEqual(tables(h).first?.lines, 0...4, "the typed row is one of its rows")
        XCTAssertNotNil(h.editor.activeBlock, "and the table stays open")

        // In the middle of a cell, the same; from the header or the delimiter row, the new row goes first.
        h = EditorHarness(header + "| 1    | 12.10. | Graphs |")
        h.caret(h.range(of: "Graphs").location + 3)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, header + "| 1    | 12.10. | Graphs |\n" + empty)
        h = EditorHarness(header + "| 1    | 12.10. | Graphs |")
        h.caret(h.range(of: "Week").upperBound)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, header + empty + "\n| 1    | 12.10. | Graphs |")
        XCTAssertEqual(h.selection.location, (header as NSString).length + 2)

        // At the start of a row, the new one goes above it and the caret stays with the row; at the start of the
        // header, a line goes in above the table. Only where the table shows its Markdown: in the grid the caret is
        // always in a cell.
        NotebookSettings.shared.editsTablesAsMarkdown = true
        defer { NotebookSettings.shared.editsTablesAsMarkdown = false }
        h = EditorHarness(header + "| 1    | 12.10. | Graphs |")
        h.caret((header as NSString).length)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, header + empty + "\n| 1    | 12.10. | Graphs |")
        XCTAssertEqual(h.selection.location, h.range(of: "| 1 ").location)
        h.caret(0)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "\n" + header + empty + "\n| 1    | 12.10. | Graphs |")
        XCTAssertEqual(tables(h).count, 1)
    }

    func testReturnInAnEmptyLastRowEndsTheTable() {
        let h = EditorHarness("| A | B |\n| --- | --- |\n| one | two |\n\nAfter")
        h.caret(h.range(of: "two |").upperBound)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n|     |     |\n\nAfter")
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n\n\n\nAfter", "a blank line under the table, so other apps end it there too")
        XCTAssertEqual(h.selection.location, h.range(of: "two |").upperBound + 2)
        XCTAssertNil(h.editor.activeBlock)
        h.type("Next")
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n\nNext\n\nAfter")
    }

    /// Format › Table and the toolbar's Table, as in Notes: two columns, a header and a row, the caret in the first cell;
    /// on an empty line or under the caret's line, with empty lines around it; one step of Undo.
    func testInsertTableMakesOneToTypeIn() {
        let table = "|     |     |\n| --- | --- |\n|     |     |"
        let tables = { (h: EditorHarness) in h.editor.document.blocks.filter { if case .table = $0.kind { true } else { false } } }

        // Under the line the caret is in, with an empty line before what follows.
        var h = EditorHarness("Plan\nAfter")
        h.caret(2)
        XCTAssertTrue(h.editor.insertTable())
        XCTAssertEqual(h.text, "Plan\n\n" + table + "\n\nAfter")
        XCTAssertEqual(h.selection.location, ("Plan\n\n| " as NSString).length, "in the first cell")
        XCTAssertEqual(tables(h).count, 1)
        XCTAssertNotNil(h.editor.activeBlock, "open, to type in")
        h.type("Day")
        XCTAssertTrue(h.text.hasPrefix("Plan\n\n| Day    |     |\n| --- | --- |\n"), h.text)
        XCTAssertEqual(tables(h).count, 1)

        // An empty line becomes the table.
        h = EditorHarness("Plan\n\nAfter")
        h.caret(5)
        h.editor.insertTable()
        XCTAssertEqual(h.text, "Plan\n\n" + table + "\n\nAfter")
        XCTAssertEqual(h.selection.location, ("Plan\n\n| " as NSString).length)

        // In a table, under it.
        h = EditorHarness("| A | B |\n| --- | --- |\n| one | two |")
        h.caret(h.range(of: "one").location)
        h.editor.insertTable()
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n\n" + table)
        XCTAssertEqual(tables(h).count, 2)

        // An empty note, and Undo.
        h = EditorHarness("")
        h.editor.insertTable()
        XCTAssertEqual(h.text, table)
        XCTAssertEqual(h.selection.location, 2)
        h = EditorHarness("Plan")
        h.caret(4)
        h.editor.insertTable()
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "Plan")

        // Not in an AsciiDoc note.
        h = EditorHarness("Plan", syntax: .asciidoc)
        h.caret(4)
        XCTAssertFalse(h.editor.insertTable())
        XCTAssertEqual(h.text, "Plan")
    }

    func testUndoAfterReturnInATable() {
        let h = EditorHarness("| A | B |\n| --- | --- |\n| one | two |")
        h.caret(h.text.utf16.count)
        h.type("\n")
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n|     |     |")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |")
    }

    func testTabGoesFromCellToCell() {
        let tab = #selector(NSResponder.insertTab(_:)), backtab = #selector(NSResponder.insertBacktab(_:))
        let h = EditorHarness("| A | B |\n| --- | --- |\n| one | two |\n\nAfter")
        h.caret(h.range(of: "A").location)
        h.command(tab)
        XCTAssertEqual(h.selection, h.range(of: "B"), "the next cell's text is selected")
        h.command(tab)
        XCTAssertEqual(h.selection, h.range(of: "one"), "past the delimiter row, into the next row")
        h.command(tab)
        XCTAssertEqual(h.selection, h.range(of: "two"))
        h.command(tab)
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n|     |     |\n\nAfter", "past the last cell, a new row")
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "two |\n").upperBound + 2, length: 0), "the caret in its first cell")
        h.command(tab)
        XCTAssertEqual(h.selection, NSRange(location: h.range(of: "two |\n").upperBound + 8, length: 0), "an empty cell gets the caret after its space")
        h.command(tab)
        XCTAssertEqual(h.text, "| A | B |\n| --- | --- |\n| one | two |\n|     |     |\n|     |     |\n\nAfter", "an empty row doesn't end the table")

        h.command(backtab)
        h.command(backtab)
        h.command(backtab)
        XCTAssertEqual(h.selection, h.range(of: "two"), "⇧Tab goes back, row by row")
        for _ in 0..<3 { h.command(backtab) }
        XCTAssertEqual(h.selection, h.range(of: "A"))
        h.command(backtab)
        XCTAssertEqual(h.selection, h.range(of: "A"), "and stays in the first cell")
        XCTAssertFalse(h.text.contains("\t"), "no tab typed")

        // From the delimiter row, where the table shows its Markdown: on into the first row, or back to the header's
        // last cell.
        NotebookSettings.shared.editsTablesAsMarkdown = true
        defer { NotebookSettings.shared.editsTablesAsMarkdown = false }
        h.caret(h.range(of: "| --- |").location + 3)
        h.command(tab)
        XCTAssertEqual(h.selection, h.range(of: "one"))
        h.caret(h.range(of: "| --- |").location + 3)
        h.command(backtab)
        XCTAssertEqual(h.selection, h.range(of: "B"))

        // Outside a table, Tab still nests list items.
        let list = EditorHarness("- One\n- Two")
        list.caret(list.range(of: "Two").location)
        list.command(tab)
        XCTAssertEqual(list.text, "- One\n  - Two")
    }

    func testReturnAfterATypedHeaderStartsTheTable() {
        let h = EditorHarness("Rooms\n\n| Day | Area |")
        h.caret(h.text.utf16.count)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "Rooms\n\n| Day | Area |\n| --- | ---- |\n|     |      |", "the delimiter row as wide as the cells, and an empty row")
        XCTAssertEqual(h.selection.location, h.range(of: "|     |").location + 2)
        XCTAssertNotNil(h.editor.activeBlock, "a table, open")
        h.type("Mon")
        h.command(#selector(NSResponder.insertTab(_:)))
        h.type("Kitchen")
        XCTAssertEqual(h.text, "Rooms\n\n| Day | Area |\n| --- | ---- |\n| Mon    | Kitchen     |")
        h.command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(h.text, "Rooms\n\n| Day | Area |\n| --- | ---- |\n| Mon    | Kitchen     |\n|     |      |",
                       "a new row lines up with the delimiter row, not with the row typed in above it")

        // Compact cells get three dashes, an empty one too.
        let compact = EditorHarness("|a|b||")
        compact.caret(compact.text.utf16.count)
        compact.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(compact.text, "|a|b||\n|---|---| --- |\n| | ||")

        // Not for a single cell, a line that doesn't end in a pipe, or with a line right under it.
        for (text, caret) in [("| Name |", 8), ("a | b", 5), ("| a | b |\nmore", 9), ("| a | b \\|", 10)] {
            let other = EditorHarness(text)
            other.caret(caret)
            other.command(#selector(NSResponder.insertNewline(_:)))
            XCTAssertFalse(other.text.contains("---"), text)
        }
    }

    func testADelimiterRowTypedByHandTakesThePlaceOfTheOneReturnMade() {
        let h = EditorHarness("| Key | Does |")
        h.caret(h.text.utf16.count)
        h.type("\n|:--|--:|\n| Up | Moves |")
        XCTAssertEqual(h.text, "| Key | Does |\n|:--|--:|\n| Up | Moves |", "as typed, alignment kept")
        guard case .table(let alignments) = h.editor.document.blocks.first?.kind else { return XCTFail("no table") }
        XCTAssertEqual(alignments, [.leading, .trailing])
    }

    func testReturnInATableRowWithOtherCellsOrNoOuterPipes() {
        // A row with fewer cells than the table makes a row with all of them, from the delimiter row.
        var h = EditorHarness("| A | B | C |\n|---|:-:|---|\n| one |")
        h.caret(h.text.utf16.count)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "| A | B | C |\n|---|:-:|---|\n| one |\n|   |   |   |")
        XCTAssertEqual(h.selection.location, h.text.utf16.count - 12, "after the opening pipe")

        // Without pipes at the ends, the caret goes to the start of the new row.
        h = EditorHarness("A | B\n--|--\n1 | 2")
        h.caret(h.text.utf16.count)
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "A | B\n--|--\n1 | 2\n  |  ")
        XCTAssertEqual(h.selection.location, h.text.utf16.count - 5)
    }

    func testABlockAtTheEndKeepsItsBoxAndRoom() {
        let box = { (h: EditorHarness, at: String) in h.editor.layoutManager.blockBox(at: h.range(of: at).location, origin: .zero)?.height }
        let table = "Steps\n\n| Key | Does |\n|---|---|\n| Up | Moves |"
        let endingTable = EditorHarness(table, height: 200)
        let followedTable = EditorHarness(table + "\n", height: 200)
        for h in [endingTable, followedTable] { h.caret(h.range(of: "Moves").location) }
        XCTAssertEqual(box(endingTable, "| Up"), box(followedTable, "| Up"), "the box goes round the last row, at the end of the note too")

        // A formula being edited shows what it makes under its source, in room below the last line.
        let formula = "Area\n\n$$\nE = mc^2\n$$"
        let endingFormula = EditorHarness(formula, height: 200)
        let followedFormula = EditorHarness(formula + "\n", height: 200)
        for h in [endingFormula, followedFormula] { h.caret(h.range(of: "mc").location) }
        XCTAssertNotNil(box(endingFormula, "E ="))
        XCTAssertEqual(box(endingFormula, "E ="), box(followedFormula, "E ="))
        XCTAssertGreaterThanOrEqual(endingFormula.textView.frame.height + 1, followedFormula.textView.frame.height - EditorStyle.lineHeight, "and room for its preview")
    }

    // MARK: - Formatting

    func testCommandBTogglesBold() {
        let h = EditorHarness("make this bold")
        h.select(h.range(of: "this"))
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "make **this** bold")
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "make this bold")
    }

    func testTypingMarkerWrapsSelection() {
        let h = EditorHarness("make this italic")
        h.select(h.range(of: "this"))
        h.type("*")
        XCTAssertEqual(h.text, "make *this* italic")
    }

    func testBoldOverWholeLinesLeavesTheirPunctuationOutside() {
        let h = EditorHarness("- [ ] Milk\n- [x] Eggs\n\n## Later")
        h.select(NSRange(location: 0, length: h.text.utf16.count))
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "- [ ] **Milk**\n- [x] **Eggs**\n\n## **Later**")
        XCTAssertEqual(h.editor.nsText.substring(with: h.selection), "**Milk**\n- [x] **Eggs**\n\n## **Later**", "a selection takes bold whole")
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "- [ ] Milk\n- [x] Eggs\n\n## Later", "and pressed again, it comes off every line")
        XCTAssertEqual(h.editor.nsText.substring(with: h.selection), "Milk\n- [x] Eggs\n\n## Later")
    }

    func testFormattingSkipsCodeAndRules() {
        let h = EditorHarness("Run\n\n```\nmake\n```\n\n---\n\nDone")
        h.select(NSRange(location: 0, length: h.text.utf16.count))
        h.textView.toggleItalics(nil)
        XCTAssertEqual(h.text, "*Run*\n\n```\nmake\n```\n\n---\n\n*Done*")
    }

    func testBoldKeepsAnEmojiAtTheSelectionsEdgeWhole() {
        let h = EditorHarness("Party 🎉")
        h.select(NSRange(location: 0, length: h.text.utf16.count))
        h.textView.toggleBoldface(nil)
        XCTAssertEqual(h.text, "**Party 🎉**")
    }

    func testTypingAMarkerOverAWholeLineWrapsItsWords() {
        let h = EditorHarness("> Quoted words ")
        h.select(NSRange(location: 0, length: h.text.utf16.count))
        h.type("_")
        XCTAssertEqual(h.text, "> _Quoted words_ ")
        let cell = EditorHarness("| A | B |\n| --- | --- |\n| one | two |")
        cell.select(cell.range(of: "| one | two |"))
        cell.type("*")
        XCTAssertEqual(cell.text, "| A | B |\n| --- | --- |\n| * |  |", "across cells of the grid the marker goes into the first, the others are emptied")
    }

    func testTypingAMarkerOverATableRowsMarkdownTypesIt() {
        EditorHarness.withTablesAsMarkdown {
            let cell = EditorHarness("| A | B |\n| --- | --- |\n| one | two |")
            cell.caret(cell.range(of: "one").location)
            cell.select(cell.range(of: "| one | two |"))
            cell.type("*")
            XCTAssertEqual(cell.text, "| A | B |\n| --- | --- |\n*", "across cells of the Markdown the marker is typed, as anywhere else")
        }
    }

    func testUndoAfterListContinuation() {
        let h = EditorHarness("- One")
        h.caret(5)
        h.type("\n")
        XCTAssertEqual(h.text, "- One\n- ")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "- One")
    }

    func testCharactersTheTypefaceHasntShowWhenANoteOpens() {
        // Styled after the text's own fixing, they had the typeface's font, which has no glyph for them.
        for syntax in [NoteSyntax.markdown, .asciidoc] {
            let h = EditorHarness("Menu ⋯ check ✅ arrow ⇄ CJK 日本", syntax: syntax)
            let layout = h.editor.layoutManager
            for character in ["⋯", "✅", "⇄", "日"] {
                let index = h.range(of: character).location
                XCTAssertNotEqual(layout.cgGlyph(at: layout.glyphIndexForCharacter(at: index)), 0, "\(character) in \(syntax)")
            }
        }
    }

    func testUndoOfAWrappedMarkPutsItBack() {
        // Undo put the selected `*` back through the typing rules, which wrapped it again: `=*=*=*=*`.
        for syntax in [NoteSyntax.markdown, .asciidoc] {
            let h = EditorHarness("Read **this** first", syntax: syntax)
            h.select(NSRange(location: 5, length: 1))
            h.type("==")
            XCTAssertEqual(h.text, "Read ==*==*this** first")
            h.settle(0.05)
            while h.textView.undoManager?.canUndo == true { h.textView.undoManager?.undo() }
            XCTAssertEqual(h.text, "Read **this** first", "\(syntax)")
            while h.textView.undoManager?.canRedo == true { h.textView.undoManager?.redo() }
            XCTAssertEqual(h.text, "Read ==*==*this** first", "\(syntax)")

            // A letter typed over a selected `*`: Undo wrapped the letter in it.
            let letter = EditorHarness("Read **this** first", syntax: syntax)
            letter.select(NSRange(location: 5, length: 1))
            letter.type("x")
            XCTAssertEqual(letter.text, "Read x*this** first")
            letter.settle(0.05)
            letter.textView.undoManager?.undo()
            XCTAssertEqual(letter.text, "Read **this** first", "\(syntax)")
        }
    }

    // MARK: - Pasting pictures

    func testPastingPictureStoresItInAssets() {
        let h = EditorHarness("Text")
        h.caret(4)
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        XCTAssertTrue(h.editor.paste(from: pasteboard, at: nil))
        XCTAssertTrue(h.text.hasPrefix("Text\n![](.assets/Kyoto%20trip%20"), h.text)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.folder.appendingPathComponent(".assets").path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("Kyoto trip ") && $0.hasSuffix(".png") }, "\(files)")
    }
}

@MainActor
final class EditorListLinkTests: XCTestCase {
    func testLinksInListItemsResolve() {
        let h = EditorHarness("- see [[Budget]]\n- and [[Nowhere]]")
        let found = h.range(of: "[[Budget]]")
        let missing = h.range(of: "[[Nowhere]]")
        let decoration = { (index: Int) -> Decoration? in h.editor.storage.attribute(.notebookDecoration, at: index, effectiveRange: nil) as? Decoration }
        XCTAssertEqual(decoration(found.location + 3)?.kind, .chip(resolved: true))
        XCTAssertEqual(decoration(missing.location + 3)?.kind, .chip(resolved: false))
    }

    func testLinkBeingTypedIsPlainText() {
        let h = EditorHarness("- see ")
        h.caret(6)
        h.type("[[Bu")
        let link = h.range(of: "[[Bu]]")
        XCTAssertNil(h.editor.layoutManager.object(at: link.location), "no chip while typing")
        XCTAssertTrue(h.isVisible(link.location), "the brackets show while typing")
        h.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.text, "- see [[Budget]]")
        XCTAssertNotNil(h.editor.layoutManager.object(at: h.range(of: "[[Budget]]").location), "a chip once it is finished")
    }
}

@MainActor
final class EditorPasteTests: XCTestCase {
    func testDroppedFileIsCopiedIntoAssets() throws {
        let h = EditorHarness("Text")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook drop \(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: outside)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([outside as NSURL])
        XCTAssertTrue(h.editor.paste(from: pasteboard, at: 4))
        let name = outside.lastPathComponent
        XCTAssertTrue(h.text.contains("![\(name)](.assets/"), h.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.folder.appendingPathComponent(".assets/\(name)").path))
    }

    func testPictureCopiedToNoteInOtherFolderComesAlong() throws {
        let source = EditorHarness("Before\n![](.assets/torii.png)\nAfter")
        source.select(source.range(of: "![](.assets/torii.png)"))
        source.textView.copy(nil)
        let target = EditorHarness("Other note\n")
        try FileManager.default.removeItem(at: target.folder.appendingPathComponent(".assets/torii.png"))
        target.caret(target.text.utf16.count)
        target.textView.paste(nil)
        XCTAssertTrue(target.text.contains("![](.assets/torii.png)"), target.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.folder.appendingPathComponent(".assets/torii.png").path), "the picture was copied")
    }
}
