import AppKit
import XCTest
@testable import NotebookKit

/// The typing rules of `MarkdownEditing` in an AsciiDoc note: the same rules with AsciiDoc's marks.
final class AsciiDocTypingRulesTests: XCTestCase {
    private func state(_ text: String, caret: Int? = nil, selection: NSRange? = nil) -> MarkdownEditing.State {
        MarkdownEditing.State(text, selection: selection ?? NSRange(location: caret ?? (text as NSString).length, length: 0), syntax: .asciidoc)
    }

    func testBoldWrapsAWordWithSingleStarsAndDoublesInsideOne() {
        XCTAssertEqual(MarkdownEditing.toggle(.bold, in: state("buy milk", caret: 6)).state.text, "buy *milk*")
        XCTAssertEqual(MarkdownEditing.toggle(.bold, in: state("buy milk", selection: NSRange(location: 4, length: 2))).state.text, "buy **mi**lk")
        XCTAssertEqual(MarkdownEditing.toggle(.italic, in: state("buy milk", caret: 6)).state.text, "buy _milk_")
        XCTAssertEqual(MarkdownEditing.toggle(.highlight, in: state("buy milk", caret: 6)).state.text, "buy #milk#")
        XCTAssertEqual(MarkdownEditing.toggle(.strikethrough, in: state("buy milk", caret: 6)).state.text, "buy [.line-through]#milk#")
    }

    func testBoldUnwrapsWhatItWrapped() {
        let bold = MarkdownEditing.toggle(.bold, in: state("buy milk", caret: 6)).state
        XCTAssertEqual(MarkdownEditing.toggle(.bold, in: bold).state.text, "buy milk")
        let struck = MarkdownEditing.toggle(.strikethrough, in: state("buy milk", caret: 6)).state
        XCTAssertEqual(MarkdownEditing.toggle(.strikethrough, in: struck).state.text, "buy milk")
    }

    func testReturnContinuesListsWithTheirMarkers() {
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("* one"))?.text, "* one\n* ")
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("** two"))?.text, "** two\n** ")
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state(". first"))?.text, ". first\n. ")
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("1. first"))?.text, "1. first\n2. ")
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("* [x] done"))?.text, "* [x] done\n* [ ] ")
    }

    func testReturnOnAnEmptyNestedItemTakesItOut() {
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("* one\n** "))?.text, "* one\n* ")
        XCTAssertEqual(MarkdownEditing.insertNewline(in: state("* one\n* "))?.text, "* one\n\n", "a blank line ends the list")
    }

    func testTabNestsByMarker() {
        let nested = MarkdownEditing.indent(in: state("* one\n* two"))
        XCTAssertEqual(nested?.text, "* one\n** two")
        XCTAssertEqual(MarkdownEditing.outdent(in: nested!)?.text, "* one\n* two")
        XCTAssertEqual(MarkdownEditing.indent(in: state(". one\n. two"))?.text, ". one\n.. two")
        XCTAssertNil(MarkdownEditing.outdent(in: state("* one")))
        XCTAssertTrue(MarkdownEditing.context(in: state("* one\n* two")).canIndent)
        XCTAssertTrue(MarkdownEditing.context(in: state("* one\n** two")).canOutdent)
    }

    func testCheckboxesAndHeadings() {
        XCTAssertEqual(MarkdownEditing.insert("]", in: state("* ["))?.text, "* [ ] ")
        XCTAssertEqual(MarkdownEditing.insert("G", in: state("=="))?.text, "== G")
        XCTAssertEqual(MarkdownEditing.toggle(.checklist, in: state("buy milk")).text, "* [ ] buy milk")
        XCTAssertEqual(MarkdownEditing.toggle(.bullet, in: state("buy milk")).text, "* buy milk")
        XCTAssertEqual(MarkdownEditing.toggle(.ordered, in: state("buy milk")).text, ". buy milk")
    }

    func testDoubledMarksPairAndStepOver() {
        let paired = MarkdownEditing.insert("*", in: state("buy *"))
        XCTAssertEqual(paired?.text, "buy ****")
        XCTAssertEqual(paired?.selection.location, 6)
        XCTAssertEqual(MarkdownEditing.insert("*", in: state("buy *milk*", caret: 9))?.selection.location, 10, "the closing star is stepped over")
    }

    func testNothingIsTypedAsMarksInAListingBlock() {
        XCTAssertNil(MarkdownEditing.insert("]", in: state("----\n* [")))
        XCTAssertTrue(MarkdownEditing.context(in: state("----\n*a* b\n----", caret: 6)).styles.isEmpty)
    }
}

/// An AsciiDoc note in the editor: what shows, what typing does, where links go.
@MainActor
final class AsciiDocEditorTests: XCTestCase {
    func testTypingAListAndALeavingIt() {
        let h = EditorHarness("", syntax: .asciidoc)
        h.type("* one\ntwo\n\nafter")
        XCTAssertEqual(h.text, "* one\n* two\n\nafter", "a blank line ends the list, as AsciiDoc needs")
    }

    func testTypingAfterCodeOnTheLine() {
        // Code's pattern has no group of its own: reading one threw, and every key after code on its line was lost.
        let h = EditorHarness("", syntax: .asciidoc)
        h.type("Run `make` and *watch* it.")
        XCTAssertEqual(h.text, "Run `make` and *watch* it.")
        h.caret(6)
        XCTAssertTrue(MarkdownEditing.context(in: MarkdownEditing.State(h.text, selection: h.selection, syntax: .asciidoc)).styles.contains(.code))
    }

    func testReturnAfterAListingDelimiterClosesTheBlock() {
        let h = EditorHarness("[source,swift]\n----", syntax: .asciidoc)
        h.caret((h.text as NSString).length)
        h.type("\n")
        XCTAssertEqual(h.text, "[source,swift]\n----\n\n----")
        XCTAssertEqual(h.selection.location, 20)
    }

    func testAttributesFoldAwayUntilTheCaretIsInTheBlock() {
        let h = EditorHarness("Intro\n\n[source,python]\n----\nprint(1)\n----\n\nAfter", syntax: .asciidoc)
        let attributes = h.range(of: "[source,python]")
        h.caret(0)
        h.settle(0.2)
        XCTAssertFalse(h.isVisible(attributes.location + 1), "folded away")
        h.caret(h.range(of: "print").location)
        h.settle(0.2)
        XCTAssertTrue(h.isVisible(attributes.location + 1), "shown while the caret is in the block")
    }

    func testAdmonitionIsACalloutWithItsCodeBoxes() {
        let h = EditorHarness("Intro\n\n[NOTE]\n====\nUse `make deploy` here.\n====\n\nAfter", syntax: .asciidoc)
        h.caret(0)
        h.settle(0.2)
        let note = h.range(of: "[NOTE]").location
        let object = h.editor.storage.attribute(.notebookObject, at: note, effectiveRange: nil) as? EditorObject
        guard case .callout(let type, let label) = object?.kind else { return XCTFail("no callout label") }
        XCTAssertEqual(type, "note")
        XCTAssertEqual(label, "Note")
        let code = h.range(of: "make deploy").location
        let box = h.editor.storage.attribute(.notebookBlockDecoration, at: code, effectiveRange: nil) as? Decoration
        XCTAssertEqual(box?.kind, .callout(type: "note"))
        let inline = h.editor.storage.attribute(.notebookDecoration, at: code, effectiveRange: nil) as? Decoration
        XCTAssertEqual(inline?.kind, .inlineCode, "the code in the callout keeps its own box")
    }

    func testCountedItemsShowTheirNumbers() {
        let h = EditorHarness(". first\n. second", syntax: .asciidoc)
        h.caret(0)
        let second = h.range(of: ". second").location
        let object = h.editor.storage.attribute(.notebookObject, at: second, effectiveRange: nil) as? EditorObject
        guard case .listNumber(let label) = object?.kind else { return XCTFail("no number") }
        XCTAssertEqual(label, "2.")
    }

    func testNestedItemsShowOneBulletEach() {
        // The bullet went on every star of `**`, and each star drew one.
        let h = EditorHarness("* one\n** two\n*** three", syntax: .asciidoc)
        h.caret(0)
        for (marker, level) in [("** ", 1), ("*** ", 2)] {
            var bullets: [Int] = []
            let range = h.range(of: marker)
            for index in range.location..<range.upperBound {
                if case .bullet(let found)? = (h.editor.storage.attribute(.notebookObject, at: index, effectiveRange: nil) as? EditorObject)?.kind { bullets.append(found) }
            }
            XCTAssertEqual(bullets, [level], marker)
        }
    }

    func testReturnAndTabInATable() {
        let h = EditorHarness("|===\n| a | b\n|===", syntax: .asciidoc)
        h.caret(h.range(of: "| b").upperBound)
        h.type("\n")
        XCTAssertEqual(h.text, "|===\n| a | b\n| | \n|===")
        XCTAssertEqual(h.selection.location, h.range(of: "| | ").location + 2)
        h.caret(h.range(of: "a").location)
        h.command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(h.selection, h.range(of: "b"), "Tab goes to the next cell, its text selected")
        h.type("\n")
    }

    func testReturnOnAnEmptyLastRowLeavesTheTable() {
        let h = EditorHarness("|===\n| a | b\n| | \n|===", syntax: .asciidoc)
        h.caret(h.range(of: "| | ").upperBound)
        h.type("\n")
        XCTAssertEqual(h.text, "|===\n| a | b\n|===\n")
    }

    func testCrossReferenceScrollsToItsSection() {
        let h = EditorHarness("See <<scope,Scope>>.\n\n" + String(repeating: "Line\n\n", count: 80) + "[[scope]]\n== Im Scope\n\nText", syntax: .asciidoc)
        XCTAssertEqual(h.editor.anchorLocation("scope"), h.range(of: "== Im Scope").location)
        XCTAssertEqual(h.editor.anchorLocation("_im_scope"), h.range(of: "== Im Scope").location, "Asciidoctor's own id of the section")
    }

    func testLinesOfAParagraphAreLaidOutAsOne() {
        let h = EditorHarness("Die Produktion hatte keine Sicherung,\nobwohl dort alle Daten liegen.\n\nNext +\nline\n\n* item\n  goes on", syntax: .asciidoc)
        h.caret(0)
        h.settle(0.1)
        let layout = h.editor.layoutManager
        let first = h.range(of: "obwohl").location - 1
        XCTAssertTrue(layout.isSoftBreak(first), "a break in a paragraph")
        XCTAssertEqual(layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 0), effectiveRange: nil).minY,
                       layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: first + 1), effectiveRange: nil).minY, "on one line")
        XCTAssertFalse(layout.isSoftBreak(h.range(of: "Next +").upperBound), "not after a line break")
        XCTAssertTrue(layout.isSoftBreak(h.range(of: "* item").upperBound), "an item's text goes on")
    }

    func testReturnStartsAParagraphAndShiftReturnBreaksTheLine() {
        let h = EditorHarness("First line\nsecond line", syntax: .asciidoc)
        h.caret(h.range(of: "First line").upperBound)
        h.type("\n")
        XCTAssertEqual(h.text, "First line\n\nsecond line", "the break inside the paragraph and Return make a blank line")
        XCTAssertEqual(h.selection.location, h.range(of: "second").location)
        h.caret(h.range(of: "second line").upperBound)
        h.command(#selector(NSResponder.insertLineBreak(_:)))
        XCTAssertEqual(h.text, "First line\n\nsecond line +\n")
        // ⇧Return, which macOS sends as Return.
        h.type("third")
        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        h.textView.keyDown(with: shiftReturn)
        XCTAssertEqual(h.text, "First line\n\nsecond line +\nthird +\n")
    }

    func testPastedLinkAndPictureAreAsciiDoc() {
        let h = EditorHarness("Read the docs", syntax: .asciidoc)
        h.select(h.range(of: "docs"))
        h.editor.pasteText("https://asciidoc.org", at: h.selection)
        XCTAssertEqual(h.text, "Read the https://asciidoc.org[docs]")
        XCTAssertEqual(NoteMarkup.picture(".assets/a.png", syntax: .asciidoc), "image::.assets/a.png[]")
        XCTAssertEqual(NoteMarkup.noteLink(name: "Plan", path: "../Plan.adoc", syntax: .asciidoc), "xref:../Plan.adoc[Plan]")
    }
}

/// AsciiDoc notes among the files: what makes one, what keeps its pictures, how its links follow, what search reads.
final class AsciiDocFilesTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("adoc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".assets"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAsciiDocFilesAreNotes() {
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/Plan.adoc"), isDirectory: false), .note)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/Plan.asciidoc"), isDirectory: false), .note)
        XCTAssertEqual(NoteSyntax(url: URL(fileURLWithPath: "/a/Plan.adoc")), .asciidoc)
        XCTAssertEqual(NoteSyntax(url: URL(fileURLWithPath: "/a/Plan.md")), .markdown)
    }

    func testANewNoteIsWrittenInWhatItsFolderHolds() throws {
        XCTAssertEqual(FileOperations.syntaxForNewNote(in: folder), .markdown)
        try "= A".write(to: folder.appendingPathComponent("a.adoc"), atomically: true, encoding: .utf8)
        try "= B".write(to: folder.appendingPathComponent("b.adoc"), atomically: true, encoding: .utf8)
        try "# C".write(to: folder.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(FileOperations.syntaxForNewNote(in: folder), .asciidoc)
        let made = FileOperations.createNote(in: folder, title: "Plan", syntax: .asciidoc)
        XCTAssertEqual(made?.url.lastPathComponent, "Plan.adoc")
    }

    func testPicturesAnAsciiDocNoteShowsAreKept() throws {
        XCTAssertEqual(FileOperations.assetNames(in: "image::.assets/flow.png[Flow]\nimage:.assets/icon.png[]"), ["flow.png", "icon.png"])
        for name in ["flow.png", "old.png"] {
            try Data([1]).write(to: folder.appendingPathComponent(".assets/\(name)"))
        }
        try "image::.assets/flow.png[Flow]".write(to: folder.appendingPathComponent("Concept.adoc"), atomically: true, encoding: .utf8)
        FileOperations.cleanUpAssets(in: folder, candidates: ["flow.png", "old.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".assets/flow.png").path), "an .adoc note still shows it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".assets/old.png").path))
    }

    func testLinksInAnAsciiDocNoteAreFound() {
        let text = "See xref:sections/goals.adoc#scope[Scope], link:../Offer.pdf[the offer], <<intro>> and https://asciidoc.org[AsciiDoc].\n\ninclude::sections/intro.adoc[]\n\nimage::pictures/flow.png[Flow]" as NSString
        let addresses = LinkUpdate.links(in: text, syntax: .asciidoc).map { text.substring(with: $0.address) }
        XCTAssertEqual(addresses, ["sections/goals.adoc#scope", "../Offer.pdf", "https://asciidoc.org", "sections/intro.adoc", "pictures/flow.png"])
        XCTAssertEqual(LinkUpdate.linkedNames(in: "see xref:sections/goals.adoc[goals]", syntax: .asciidoc), ["goals.adoc"])
    }

    func testMovingAFileRewritesTheWaysToIt() throws {
        let docs = folder.appendingPathComponent("Docs/sections", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let concept = folder.appendingPathComponent("Docs/concept.adoc").standardizedFileURL
        try "See xref:sections/goals.adoc#scope[Goals].\n\ninclude::sections/goals.adoc[]\n".write(to: concept, atomically: true, encoding: .utf8)
        try "== Goals".write(to: docs.appendingPathComponent("goals.adoc"), atomically: true, encoding: .utf8)
        let before = LinkTargets.reading(folder.standardizedFileURL, deep: true)
        let from = docs.appendingPathComponent("goals.adoc").standardizedFileURL
        let to = folder.appendingPathComponent("Docs/aims.adoc").standardizedFileURL
        try FileManager.default.moveItem(at: from, to: to)
        let update = LinkUpdate(before: before, moves: [LinkUpdate.Move(from: from, to: to)])
        XCTAssertEqual(update.notesToChange().changing.map(\.lastPathComponent), ["concept.adoc"])
        let text = try String(contentsOf: concept, encoding: .utf8)
        XCTAssertEqual(update.rewrite(text, of: concept)?.text, "See xref:aims.adoc#scope[Goals].\n\ninclude::aims.adoc[]\n")
    }

    func testToDosInAnAsciiDocNote() {
        let text = "= Plan\n\n* [ ] Book the hotel\n** [ ] Ask about late arrival\n* [x] Flights\n\n----\n* [ ] not a to-do\n----"
        let todos = Todos.open(in: text, syntax: .asciidoc)
        XCTAssertEqual(todos.map(\.text), ["Book the hotel"])
        XCTAssertEqual(todos.first?.lines.map(\.text), ["Ask about late arrival"], "the nested one is its notes")
        XCTAssertEqual(Todos.mark(of: "** [ ] Ask about late arrival"), .open)
        XCTAssertEqual(Todos.marking("** [ ] Ask", as: .done, today: .today)?.line.hasPrefix("** [x] Ask"), true)
    }

    func testSearchReadsAsciiDoc() {
        let headings = SearchIndex.headings(in: "= Concept\n:toc:\n\n== *Goals* and scope\n\n----\n== not a heading\n----\n\n=== Scope", syntax: .asciidoc)
        XCTAssertEqual(headings.map(\.title), ["Concept", "Goals and scope", "Scope"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(SearchIndex.plainAsciiDoc("*Plan* for xref:kyoto.adoc[Kyoto]"), "Plan for Kyoto")
        XCTAssertEqual(NotePoints.beginning(of: "= Concept\n:toc: left\n\n[.lead]\n*Short:* it works.\n\nNOTE: Read this.", title: "concept", syntax: .asciidoc),
                       "Short: it works.\nRead this.", "without a title that says the note's name")
    }

    func testSharedLinksBecomeAsciiDoc() {
        XCTAssertEqual(Workspace.sharedText("A page\n\n[Swift](https://swift.org) and <https://apple.com>", syntax: .asciidoc),
                       "A page\n\nhttps://swift.org[Swift] and https://apple.com")
    }
}
