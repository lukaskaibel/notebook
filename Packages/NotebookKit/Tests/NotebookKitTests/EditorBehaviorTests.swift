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
        let h = EditorHarness("Steps")
        h.caret(h.text.utf16.count)
        h.type("\n\n| Key | Does |\n|---|---|\n| Up | Moves |")
        XCTAssertNotNil(h.editor.activeBlock, "the table being typed is open")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Up | Moves |")), "| Up | Moves |")
        h.type("\nmore")
        XCTAssertNil(h.editor.activeBlock)
        XCTAssertFalse(h.isVisible(h.range(of: "| Up").location + 2), "left, it is drawn")
        for _ in 0..<5 { h.command(#selector(NSResponder.deleteBackward(_:))) }
        XCTAssertNotNil(h.editor.activeBlock, "back in it, it is open again")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Up | Moves |")), "| Up | Moves |", "and its source shows")
        XCTAssertEqual(h.visibleText(in: h.range(of: "| Key | Does |")), "| Key | Does |")
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
        XCTAssertEqual(cell.text, "| A | B |\n| --- | --- |\n*", "across cells the marker is typed, as anywhere else")
    }

    func testUndoAfterListContinuation() {
        let h = EditorHarness("- One")
        h.caret(5)
        h.type("\n")
        XCTAssertEqual(h.text, "- One\n- ")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "- One")
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
