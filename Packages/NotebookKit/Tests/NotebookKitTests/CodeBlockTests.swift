import AppKit
import XCTest
@testable import NotebookKit

/// The box around code, diagrams and formulas being edited, and copying a code block.
@MainActor
final class CodeBlockTests: XCTestCase {
    private let code = "Intro\n\n```swift\nlet a = 1\n\nprint(a)\n```\n\nAfter"
    private let diagram = "Intro\n\n```mermaid\ngraph LR\n  A --> B\n```\n\nAfter"

    // MARK: - The box

    func testABlockStyledAgainInPartKeepsOneBox() {
        // Each styling made a box of its own for the lines it styled, and the block was drawn in pieces.
        for (syntax, text) in [(NoteSyntax.markdown, code), (.asciidoc, "Intro\n\n[source,swift]\n----\nlet a = 1\n\nprint(a)\n----\n\nAfter")] {
            let h = EditorHarness(text, syntax: syntax)
            h.caret(0)
            let middle = h.editor.document.lineIndex(containing: h.range(of: "print").location)
            h.editor.restyle(lines: [middle])
            var boxes: [NSRange] = []
            h.editor.storage.enumerateAttribute(.notebookBlockDecoration, in: NSRange(location: 0, length: h.editor.storage.length)) { value, range, _ in
                if value != nil { boxes.append(range) }
            }
            XCTAssertEqual(boxes.count, 1, "\(syntax): \(boxes)")
        }
    }

    func testTwoBlocksNextToEachOtherKeepTheirOwnBoxes() {
        let h = EditorHarness("```\none\n```\n```\ntwo\n```")
        h.caret(0)
        h.editor.restyle(lines: Array(h.editor.document.lines.indices))
        let first = h.editor.storage.attribute(.notebookBlockDecoration, at: h.range(of: "one").location, effectiveRange: nil) as? Decoration
        let second = h.editor.storage.attribute(.notebookBlockDecoration, at: h.range(of: "two").location, effectiveRange: nil) as? Decoration
        XCTAssertNotNil(first)
        XCTAssertFalse(first === second, "a box each")
    }

    func testBoxGoesRoundTheClosingFenceOfADiagramBeingEdited() throws {
        let h = EditorHarness(diagram)
        h.caret(h.range(of: "A --> B").location)
        h.settle(0.3)
        XCTAssertNotNil(h.editor.activeBlock)
        let layout = h.editor.layoutManager
        let origin = h.textView.textContainerOrigin
        let closing = h.range(of: "```\n\nAfter").location
        let box = try XCTUnwrap(layout.blockBox(at: h.range(of: "graph").location, origin: origin))
        XCTAssertEqual(layout.blockBox(at: closing, origin: origin), box, "the closing fence is in the same box")
        XCTAssertTrue(box.contains(h.point(of: closing)), "the box goes round the closing fence")
        XCTAssertTrue(box.contains(h.point(of: h.range(of: "```mermaid").location)), "and the opening one")
        let decoration = h.editor.storage.attribute(.notebookBlockDecoration, at: closing, effectiveRange: nil) as? Decoration
        XCTAssertEqual(decoration?.kind, .codeBlock(language: "mermaid", active: true, preview: .diagram(source: "graph LR\n  A --> B")),
                       "the preview under the box draws the diagram's source")
        h.snapshot("diagram-being-edited")
    }

    func testBoxGoesRoundTheClosingDollarsOfAFormulaBeingEdited() throws {
        let h = EditorHarness("Intro\n\n$$\nx^2\n$$\n\nAfter")
        h.caret(h.range(of: "x^2").location)
        h.settle(0.3)
        let layout = h.editor.layoutManager
        let origin = h.textView.textContainerOrigin
        let closing = h.range(of: "$$\n\nAfter").location
        let box = try XCTUnwrap(layout.blockBox(at: h.range(of: "x^2").location, origin: origin))
        XCTAssertTrue(box.contains(h.point(of: closing)), "the box goes round the closing $$")
        let decoration = h.editor.storage.attribute(.notebookBlockDecoration, at: closing, effectiveRange: nil) as? Decoration
        XCTAssertEqual(decoration?.kind, .codeBlock(language: "tex", active: true, preview: .math(tex: "x^2")))
    }

    // MARK: - Copying

    func testHoveringACodeBlockShowsACopyButtonThatCopiesTheCode() throws {
        let h = EditorHarness(code)
        let button = h.textView.copyButton
        XCTAssertTrue(button.isHidden)
        let first = h.range(of: "let a").location
        h.editor.updateCopyButton(at: h.point(of: first))
        XCTAssertFalse(button.isHidden)
        let box = try XCTUnwrap(h.editor.layoutManager.blockBox(at: first, origin: h.textView.textContainerOrigin))
        XCTAssertTrue(box.contains(button.frame), "the button is inside the box")
        XCTAssertLessThan(button.frame.maxY, h.point(of: first).y, "on the line of the hidden opening fence, above the code")
        XCTAssertEqual(h.editor.layoutManager.copyButtonBlock, h.range(of: "```swift").location, "the language label makes way")
        h.snapshot("code-copy-button")

        NSPasteboard.general.clearContents()
        button.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let a = 1\n\nprint(a)", "the code without its fences")
        XCTAssertEqual(h.text, code, "copying leaves the note alone")

        h.editor.updateCopyButton(at: h.point(of: h.range(of: "After").location))
        XCTAssertTrue(button.isHidden, "it goes when the pointer leaves the block")
        XCTAssertNil(h.editor.layoutManager.copyButtonBlock)
    }

    func testTypingHidesTheCopyButton() {
        let h = EditorHarness(code)
        h.editor.updateCopyButton(at: h.point(of: h.range(of: "print").location))
        XCTAssertFalse(h.textView.copyButton.isHidden)
        h.caret(h.range(of: "After").upperBound)
        h.type("!")
        XCTAssertTrue(h.textView.copyButton.isHidden)
    }

    func testDiagramsHaveNoCopyButton() throws {
        let h = EditorHarness(diagram)
        let button = h.textView.copyButton
        let start = h.range(of: "```mermaid").location
        let object = try XCTUnwrap(h.editor.layoutManager.rect(forObjectAt: start, origin: h.textView.textContainerOrigin))
        h.editor.updateCopyButton(at: NSPoint(x: object.midX, y: object.midY))
        XCTAssertTrue(button.isHidden, "not on the drawn diagram")
        h.caret(h.range(of: "A --> B").location)
        h.settle(0.3)
        h.editor.updateCopyButton(at: h.point(of: h.range(of: "graph").location))
        XCTAssertTrue(button.isHidden, "nor on its source while you edit it")
    }

    func testContextMenuOfACodeBlockCopiesTheCode() throws {
        let h = EditorHarness(code)
        let point = h.textView.convert(h.point(of: h.range(of: "print").location), to: nil)
        // A right-click opens the menu in glass; the AppKit menu it is made from is what VoiceOver's Show Menu gets, here
        // asked for by a click of another button.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(h.textView.menu(for: click))
        XCTAssertTrue(Dropdown.isOpen, "a right-click opens the glass menu")
        Dropdown.close()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .otherMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(h.textView.menu(for: event))
        let entries = h.editor.glassEntries(from: menu)
        XCTAssertEqual(entries.first?.title, "Copy Code", "the glass menu has it first too")
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(item.title, "Copy Code")
        NSPasteboard.general.clearContents()
        h.textView.copyCodeBlock(item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let a = 1\n\nprint(a)")

        let outside = h.textView.convert(h.point(of: h.range(of: "After").location), to: nil)
        let plain = try XCTUnwrap(NSEvent.mouseEvent(with: .otherMouseDown, location: outside, modifierFlags: [], timestamp: 0,
                                                     windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNotEqual(h.textView.menu(for: plain)?.items.first?.title, "Copy Code")
    }
}
