import AppKit
import XCTest
@testable import NotebookKit

/// After an edit, a note is read again only from the block above the edit to where its lines read as before
/// (`MarkdownParser.update`). Whatever the edit, the result is what reading the whole note gives.
final class IncrementalParsingTests: XCTestCase {
    // MARK: - Notes

    static let markdownNotes = [
        """
        ---
        title: Kyoto
        tags: [trip, japan]
        ---
        # Kyoto

        Some **bold** and *italics*, a [[Budget]] link, `code` and $x^2$ inline.
        A second line of the same paragraph.

        - one
          - two
            - three
        - [ ] book the ryokan 📅 2026-11-10
        - [x] flights
        \t- tabbed

        1. first
        2) second

        > [!note] A callout
        > with more lines
        >> nested

        > a plain quote

        | Day | Plan |
        | --- | :-: |
        | 1 | Fushimi |
        | 2 | Arashiyama |
        not a row

        ```swift
        let x = 1
        ```

        ~~~
        tilde code
        ~~~

        $$
        \\int_0^1 x\\,dx
        $$

        $$ e^{i\\pi} = -1 $$

        Text with a note[^1].

        [^1]: The footnote.

        ***
        ****
        ## The end
        """,
        // Blocks left open: a fence and math that nothing closes, frontmatter that isn't closed.
        """
        ---
        not frontmatter yet

        $$
        unclosed math

        ```
        code to the end
        - not a list
        """,
        // Lists that nest by indent, broken by paragraphs and headings.
        """
        - a
          - b
            - c
          - d
        - e
            - f
        Paragraph
        - g
           - h
         - i
        # Heading
          - j
        - k
              - l

          indented paragraph
        - m
        """,
        "",
        "One line",
        "# Title\r\nSome text\r\n\r\n- item\r\n  - nested\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n",
    ]

    static let asciidocNotes = [
        """
        = Kyoto Trip
        Lukas Kaibel
        v1.0, 2026-10-01
        :toc:
        :imagesdir: images
        :name: value

        == Plans

        A paragraph with *bold*, _italics_ and {name}.
        Its second line.

        * one
        ** two
        *** three
        * [ ] book the ryokan
        * [x] flights
        +
        attached paragraph

        . first
        . second
        .. inner

        Term:: description
        Another term::
          more text

        NOTE: Bring cash.

        [source,python]
        .Example
        ----
        print("hi")
        ----

        ====
        An example
        ====

        ****
        A sidebar
        ****

        ____
        A quote
        ____

        --
        An open block
        --

        [cols="1,1",options="header"]
        |===
        | A | B
        | 1 | 2
        |===

        // a comment
        ////
        a block comment
        ////

        [[anchor]]
        [.lead]
        A lead paragraph.

        > a Markdown quote

        '''

        image::photo.png[]

        [TIP]
        ====
        Inside a tip.
        ====
        """,
        // No title, blocks left open, attributes further down.
        """
        Some text first.

        = Not a title

        :late: attribute

        [source]
        ----
        open listing to the end

        ====
        open example
        """,
        """
        // only a comment
        [[top]]
        = Title After Markup

        a. alpha
        b. beta
        i) roman
        ii) two

        CAUTION: Hot.
          literal paragraph
        """,
        "",
    ]

    // MARK: - Tests

    func testRandomEditsInMarkdownReadAsAWhole() {
        for typing in [false, true] {
            for (index, note) in Self.markdownNotes.enumerated() {
                editRandomly(note, syntax: .markdown, typing: typing, seed: UInt64(index + 1), snippets: Self.markdownSnippets)
            }
        }
    }

    func testRandomEditsInAsciiDocReadAsAWhole() {
        for typing in [false, true] {
            for (index, note) in Self.asciidocNotes.enumerated() {
                editRandomly(note, syntax: .asciidoc, typing: typing, seed: UInt64(index + 101), snippets: Self.asciidocSnippets)
            }
        }
    }

    /// Typing a block character by character, all over a note, and deleting it again: on the way it opens blocks that
    /// run to the end of the note, closes them, turns lines above into a table's header. Notes are typed in as they are
    /// read for typing; the random edits read them both ways.
    func testTypingBlocksInMarkdownReadsAsAWhole() {
        let blocks = ["```swift\nlet x = 1\n```\n", "$$\nx^2\n$$\n", "| a | b |\n| --- | --- |\n| 1 | 2 |\n", "---\ntitle: x\n---\n",
                      "> [!tip] Tip\n> more\n", "  - [ ] nested task\n", "~~~\ncode\n"]
        for note in Self.markdownNotes {
            for block in blocks { typeAndDelete(block, in: note, syntax: .markdown, typing: true) }
        }
    }

    func testTypingBlocksInAsciiDocReadsAsAWhole() {
        let blocks = ["----\ncode\n----\n", "====\nexample\n====\n", "[source,ruby]\n----\nputs 1\n----\n", "|===\n| a | b\n|===\n",
                      ":name: other\n", "* item\n+\nmore\n", "////\ncomment\n////\n", "= Title\nAuthor\n\n", "[NOTE]\n.Title\nText\n", "--\nopen\n--\n"]
        for note in Self.asciidocNotes {
            for block in blocks { typeAndDelete(block, in: note, syntax: .asciidoc, typing: true) }
        }
    }

    /// A keystroke in a long note reads a few lines around it, not the note.
    func testKeystrokeReadsOnlyLinesAroundIt() {
        var markdown = ""
        for index in 0..<150 {
            markdown += "## Section \(index)\nSome **bold** text in paragraph \(index).\n- [ ] A task\n  - nested\n> A quote\n\n"
            markdown += "| A | B |\n| --- | --- |\n| \(index) | two |\n\n```swift\nlet value = \(index)\n```\n\n"
        }
        var list = ""
        for index in 0..<500 { list += String(repeating: "  ", count: index % 4) + "- [ ] item \(index)\n" }
        var asciidoc = "= Long\n\n"
        for index in 0..<150 {
            asciidoc += "== Section \(index)\n\nSome *bold* text in paragraph \(index).\n\n* item\n** nested\n\n----\ncode \(index)\n----\n\n"
        }
        for (text, syntax, target) in [(markdown, NoteSyntax.markdown, "paragraph 75"), (list, .markdown, "item 250"), (asciidoc, .asciidoc, "paragraph 75")] {
            let string = NSMutableString(string: text)
            let old = MarkdownParser.parse(string, typing: true, syntax: syntax)
            let location = string.range(of: target).location
            string.replaceCharacters(in: NSRange(location: location, length: 0), with: "a")
            let update = MarkdownParser.update(old, string, edited: NSRange(location: location, length: 1), changeInLength: 1, typing: true, syntax: syntax)
            assertSame(update.document, MarkdownParser.parse(string, typing: true, syntax: syntax), "typing in \(target), \(syntax)")
            XCTAssertLessThanOrEqual(update.end - update.start, 6, "\(syntax): read lines \(update.start)..<\(update.end) of \(update.document.lines.count)")
            XCTAssertEqual(update.document.lines.count - update.end, old.lines.count - update.oldEnd)
        }
    }

    /// The editor keeps its document and the lines' signatures as reading the whole note would make them, while
    /// typing in paragraphs, into a table that opens for it, and blocks that open and close; and an AsciiDoc note
    /// opened after a Markdown one is read as AsciiDoc.
    @MainActor
    func testEditorKeepsDocumentAndSignatures() {
        let h = EditorHarness(Self.markdownNotes[0])
        func check(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            let full = MarkdownParser.parse(h.editor.storage.mutableString, typing: h.editor.document.typing, syntax: h.editor.syntax)
            assertSame(h.editor.document, full, what, file: file, line: line)
            XCTAssertEqual(h.editor.lineSignatures, h.editor.computeSignatures(), what, file: file, line: line)
        }
        h.caret(h.range(of: "inline.").upperBound)
        h.type(" More words")
        check("typing in a paragraph")
        h.caret(h.range(of: "| 1 | Fushimi |").location + 3)
        XCTAssertNotNil(h.editor.activeBlock, "the table opens")
        h.type("23")
        check("typing in a table")
        h.caret(h.range(of: "## The end").location)
        h.type("```\n")
        check("a fence that runs to the end")
        h.command(#selector(NSResponder.deleteBackward(_:)))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        check("deleting it again")

        h.editor.load(text: Self.asciidocNotes[0], folder: h.folder, title: "Kyoto", meta: "", syntax: .asciidoc)
        h.settle()
        XCTAssertEqual(h.editor.document.syntax, .asciidoc)
        check("opening an AsciiDoc note")
        h.caret(h.range(of: "Its second line.").location)
        h.type("And ")
        check("typing in an AsciiDoc paragraph")
        h.caret(h.range(of: "print(").location)
        h.type("x")
        check("typing in a listing")
    }

    // MARK: - Editing

    static let markdownSnippets = ["\n", "\n\n", "x", "a b", "```", "```swift\n", "~~~", "$$", "$$\n", "\n$$\n", "| a | b |", "\n| --- | --- |",
                                   "|", "> ", "> [!tip] ", "- ", "  - ", "    - [ ] ", "1. ", "# ", "## ", "---", "\n---\n", "...", "***", "****",
                                   "**bold**", "*", "`", "[[Budget]]", "[^1]: ", "\t", "    ", "\r\n", "📅 2026-11-10", "$x$", "\\", "[x] "]

    static let asciidocSnippets = ["\n", "\n\n", "x", "= Title\n", "== ", "=== ", "* ", "** ", ". ", ".. ", "1. ", "a. ", "+\n", "+", "Term:: ",
                                   "NOTE: ", "TIP: ", "[source,python]\n", "[NOTE]\n", "[[id]]\n", ".Title\n", "----", "\n----\n", "....", "====",
                                   "****", "____", "--", "++++", "|===", "\n|===\n", "| a | b", "// ", "////", "\n////\n", ":name: other",
                                   ":toc:\n", "{name}", "*bold*", "_it_", "'''", "> ", "image::x.png[]", "toc::[]", "  ", "\r\n", "Author Name"]

    private func editRandomly(_ note: String, syntax: NoteSyntax, typing: Bool, seed: UInt64, snippets: [String], steps: Int = 400) {
        var random = SeededRandom(seed: seed)
        let text = NSMutableString(string: note)
        var document = MarkdownParser.parse(text, typing: typing, syntax: syntax)
        for step in 0..<steps {
            let length = text.length
            let location = Int(random.next() % UInt64(length + 1))
            let deleting = length > 0 && random.next() % (length > 2_000 ? 2 : 3) == 0
            let removed = deleting ? 1 + Int(random.next() % UInt64(min(30, length - location) + 1)) : 0
            let range = NSRange(location: location, length: min(removed, length - location))
            let inserted = random.next() % 4 == 0 && deleting ? "" : snippets[Int(random.next() % UInt64(snippets.count))]
            let before = text.substring(with: range)
            text.replaceCharacters(in: range, with: inserted)
            var edited = NSRange(location: location, length: (inserted as NSString).length)
            // An edit's range may take in more than what changed, as it does when attributes changed around it.
            if random.next() % 5 == 0 {
                let start = max(0, edited.location - Int(random.next() % 8))
                edited = NSRange(location: start, length: min(text.length, edited.upperBound + Int(random.next() % 8)) - start)
            }
            let delta = (inserted as NSString).length - range.length
            document = MarkdownParser.update(document, text, edited: edited, changeInLength: delta, typing: typing, syntax: syntax).document
            let full = MarkdownParser.parse(text, typing: typing, syntax: syntax)
            let what = "\(syntax) note \(seed), typing \(typing), step \(step): \(before.debugDescription) at \(location) → \(inserted.debugDescription)"
            guard assertSame(document, full, what) else { return }
        }
    }

    /// Types `block` a character at a time at the start of the first two lines and every fifth after, in the middle
    /// of a line and at the end, then deletes it a character at a time, checking the note after every key.
    private func typeAndDelete(_ block: String, in note: String, syntax: NoteSyntax, typing: Bool) {
        let starts = MarkdownParser.parse(note).lines.map(\.range.location)
        var places = Set(starts.enumerated().filter { $0.offset % 5 == 0 || $0.offset == 1 }.map(\.element))
        places.insert((note as NSString).length)
        if let middle = MarkdownParser.parse(note).lines.first(where: { $0.range.length > 6 }) { places.insert(middle.range.location + 3) }
        for place in places.sorted() {
            let text = NSMutableString(string: note)
            var document = MarkdownParser.parse(text, typing: typing, syntax: syntax)
            var caret = place
            func check(_ what: String) -> Bool {
                assertSame(document, MarkdownParser.parse(text, typing: typing, syntax: syntax),
                           "\(syntax), typing \(typing): \(what) \(block.debugDescription) at \(place), caret \(caret)")
            }
            for unit in Array(block.utf16) {
                let character = String(utf16CodeUnits: [unit], count: 1)
                text.replaceCharacters(in: NSRange(location: caret, length: 0), with: character)
                document = MarkdownParser.update(document, text, edited: NSRange(location: caret, length: 1), changeInLength: 1, typing: typing, syntax: syntax).document
                caret += 1
                guard check("typing") else { return }
            }
            while caret > place {
                caret -= 1
                text.replaceCharacters(in: NSRange(location: caret, length: 1), with: "")
                document = MarkdownParser.update(document, text, edited: NSRange(location: caret, length: 0), changeInLength: -1, typing: typing, syntax: syntax).document
                guard check("deleting") else { return }
            }
        }
    }

    // MARK: - Comparing

    @discardableResult
    private func assertSame(_ document: MarkdownDocument, _ full: MarkdownDocument, _ what: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if document.lines == full.lines, document.blocks == full.blocks, document.resumePoints == full.resumePoints,
           document.attributes == full.attributes, document.length == full.length, document.syntax == full.syntax,
           document.typing == full.typing {
            return true
        }
        var message = what()
        if let index = (0..<min(document.lines.count, full.lines.count)).first(where: { document.lines[$0] != full.lines[$0] }) {
            message += "\nline \(index):\n  read again: \(document.lines[index])\n  read whole: \(full.lines[index])"
        } else if document.lines.count != full.lines.count {
            message += "\n\(document.lines.count) lines, reading the whole note gives \(full.lines.count)"
        } else if let index = (0..<min(document.blocks.count, full.blocks.count)).first(where: { document.blocks[$0] != full.blocks[$0] }) {
            message += "\nblock \(index):\n  read again: \(document.blocks[index])\n  read whole: \(full.blocks[index])"
        } else if document.blocks.count != full.blocks.count {
            message += "\n\(document.blocks.count) blocks, reading the whole note gives \(full.blocks.count)"
        } else if document.resumePoints != full.resumePoints {
            let index = (0..<min(document.resumePoints.count, full.resumePoints.count)).first { document.resumePoints[$0] != full.resumePoints[$0] }
            message += "\nresume points differ at \(index.map(String.init) ?? "the end"): \(document.resumePoints.count) against \(full.resumePoints.count)"
        } else {
            message += "\nattributes \(document.attributes) against \(full.attributes)"
        }
        XCTFail(message, file: file, line: line)
        return false
    }
}

/// SplitMix64: the same edits on every run.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
