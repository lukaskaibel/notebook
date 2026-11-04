import XCTest
@testable import NotebookKit

final class AsciiDocParserTests: XCTestCase {
    private func parse(_ text: String) -> MarkdownDocument {
        MarkdownParser.parse(text, syntax: .asciidoc)
    }

    private func kinds(_ text: String) -> [LineKind] {
        parse(text).lines.map(\.kind)
    }

    private func spans(_ text: String) -> [(InlineSpan.Kind, String)] {
        let ns = text as NSString
        return parse(text).lines.flatMap(\.spans).map { ($0.kind, ns.substring(with: $0.content)) }
    }

    private func block(of line: Int, in text: String) -> MarkdownBlock? {
        let document = parse(text)
        return document.lines[line].block.map { document.blocks[$0] }
    }

    // MARK: - Header and sections

    func testTitleHeaderAndSections() {
        let text = """
        = Backup concept
        :author: PIA Architecture
        :toc: left
        :sectnums:

        == Goals

        === Scope
        Text
        """
        let lines = parse(text).lines
        guard case .heading(1, _) = lines[0].kind else { return XCTFail("\(lines[0].kind)") }
        XCTAssertEqual(lines[1].kind, .frontmatter)
        XCTAssertEqual(lines[3].kind, .frontmatter)
        guard case .heading(2, let marker) = lines[5].kind else { return XCTFail("\(lines[5].kind)") }
        XCTAssertEqual(marker.length, 3)
        guard case .heading(3, _) = lines[7].kind else { return XCTFail() }
        XCTAssertEqual(lines[8].kind, .paragraph)
        XCTAssertEqual(block(of: 1, in: text)?.kind, .frontmatter)
        XCTAssertEqual(block(of: 1, in: text)?.lines, 1...3)
    }

    func testMarkdownHeadingsAndExampleDelimiterAreNotConfused() {
        let lines = parse("## Markdown style\n====\ninside\n====").lines
        guard case .heading(2, _) = lines[0].kind else { return XCTFail() }
        XCTAssertEqual(lines[1].kind, .markup)
        XCTAssertEqual(lines[2].kind, .paragraph)
    }

    // MARK: - Lists

    func testNestedListsByMarker() {
        let lines = parse("* one\n** two\n*** three\n* four\n- dash").lines
        let levels = lines.compactMap { line -> Int? in if case .listItem(let item) = line.kind { item.level } else { nil } }
        XCTAssertEqual(levels, [0, 1, 2, 0, 1])
    }

    func testCountedNumbers() {
        let lines = parse(". first\n. second\n.. inner\n. third").lines
        let numbers = lines.compactMap { line -> Int? in
            if case .listItem(let item) = line.kind, case .ordered(let number, _) = item.marker, item.counted { number } else { nil }
        }
        XCTAssertEqual(numbers, [1, 2, 1, 3])
    }

    func testChecklist() {
        let lines = parse("* [ ] open\n* [x] done\n* [*] also done").lines
        let states = lines.compactMap { line -> Bool? in if case .listItem(let item) = line.kind, item.isTask { item.checked } else { nil } }
        XCTAssertEqual(states, [false, true, true])
    }

    func testBoldAtLineStartIsNoListItem() {
        guard case .paragraph = kinds("*Kurzfassung.* Text")[0] else { return XCTFail() }
        XCTAssertEqual(spans("*Kurzfassung.* Text").first?.0, .strong)
    }

    func testWrappedItemTextGoesOnWithTheItem() {
        let lines = parse("* first line\n  goes on\n\nNew paragraph").lines
        guard case .continuation(0, let indent) = lines[1].kind else { return XCTFail("\(lines[1].kind)") }
        XCTAssertEqual(indent.length, 2)
        XCTAssertEqual(lines[3].kind, .paragraph)
    }

    func testAttachedBlockAfterPlus() {
        let lines = parse("* item\n+\nattached paragraph").lines
        XCTAssertEqual(lines[1].kind, .markup)
        guard case .continuation(0, _) = lines[2].kind else { return XCTFail("\(lines[2].kind)") }
    }

    func testDefinitionList() {
        let text = "CPU:: the processor\nRAM::\n  the memory"
        let lines = parse(text).lines
        guard case .definition(let term, let marker) = lines[0].kind else { return XCTFail() }
        XCTAssertEqual((text as NSString).substring(with: term), "CPU")
        XCTAssertEqual((text as NSString).substring(with: marker), ":: ")
        guard case .definition = lines[1].kind else { return XCTFail() }
        guard case .continuation(1, _) = lines[2].kind else { return XCTFail("\(lines[2].kind)") }
    }

    func testURLsAndScopeAreNoTerms() {
        guard case .paragraph = kinds("See https://example.com for more")[0] else { return XCTFail() }
        guard case .paragraph = kinds("Use std::vector here")[0] else { return XCTFail() }
    }

    // MARK: - Blocks

    func testSourceBlockWithAttributes() {
        let text = "[source,python]\n----\nprint(1)\n----\nafter"
        let lines = parse(text).lines
        XCTAssertEqual(lines.map(\.kind), [.markup, .fence, .code, .fence, .paragraph])
        let found = block(of: 2, in: text)
        XCTAssertEqual(found?.kind, .code(language: "python"))
        XCTAssertEqual(found?.lines, 0...3)
        XCTAssertEqual(found?.opens, true)
    }

    func testListingLiteralAndDiagrams() {
        XCTAssertEqual(block(of: 1, in: "----\nls\n----")?.kind, .code(language: ""))
        XCTAssertEqual(block(of: 1, in: "....\nliteral\n....")?.kind, .code(language: ""))
        XCTAssertEqual(block(of: 2, in: "[plantuml, overview, format=svg]\n----\n@startuml\n----")?.kind, .code(language: "plantuml"))
        XCTAssertEqual(block(of: 2, in: "[mermaid]\n----\ngraph TD\n----")?.kind, .mermaid)
        XCTAssertEqual(block(of: 1, in: "```swift\nlet a = 1\n```")?.kind, .code(language: "swift"))
    }

    func testAdmonitions() {
        let text = "NOTE: Keep it short.\nIt goes on.\n\n[WARNING]\n====\nCareful.\n====\n"
        let document = parse(text)
        guard case .admonition(let marker) = document.lines[0].kind else { return XCTFail() }
        XCTAssertEqual((text as NSString).substring(with: marker), "NOTE: ")
        XCTAssertEqual(document.lines[0].block.map { document.blocks[$0].kind }, .callout(type: "note"))
        XCTAssertEqual(document.lines[1].block.map { document.blocks[$0].kind }, .callout(type: "note"))
        let warning = document.lines[5].block.map { document.blocks[$0] }
        XCTAssertEqual(warning?.kind, .callout(type: "warning"))
        XCTAssertEqual(warning?.lines, 3...6)
        XCTAssertEqual(document.lines[5].kind, .paragraph)
    }

    func testExampleWithTitleAndListInside() {
        let text = ".Steps\n====\n* one\n* two\n===="
        let document = parse(text)
        let found = document.lines[2].block.map { document.blocks[$0] }
        XCTAssertEqual(found?.kind, .callout(type: "example"))
        XCTAssertEqual(found?.lines, 0...4)
        guard case .listItem = document.lines[3].kind else { return XCTFail() }
    }

    func testStandaloneAttributesFoldAway() {
        let text = "[[goals]]\n== Goals\n\n[.lead]\nLead text"
        let document = parse(text)
        XCTAssertEqual(document.lines[0].kind, .markup)
        XCTAssertEqual(document.lines[0].block.map { document.blocks[$0].kind }, .markup)
        XCTAssertEqual(document.lines[3].block.map { document.blocks[$0].kind }, .markup)
        XCTAssertEqual(document.lines[4].kind, .paragraph)
        XCTAssertTrue(document.blocks[document.lines[0].block!].isSwappable)
    }

    func testCommentsAndBreaks() {
        XCTAssertEqual(kinds("// a note to self\n////\nhidden\n////\n'''\n<<<"), [.comment, .comment, .comment, .comment, .thematicBreak, .thematicBreak])
    }

    func testCodeInsideAnExampleKeepsItsOwnBlock() {
        let text = "====\n----\ncode\n----\ntext\n===="
        let document = parse(text)
        XCTAssertEqual(document.lines[2].block.map { document.blocks[$0].kind }, .code(language: ""))
        XCTAssertEqual(document.lines[4].block.map { document.blocks[$0].kind }, .callout(type: "example"))
    }

    // MARK: - Tables

    func testTableWithColsAndHeader() {
        let text = """
        [cols="1,2,7", options="header"]
        |===
        | ID | Typ | Anforderung

        | F-1 | funktional | Alle Datenbanken
        | F-2 | funktional | Dateien
        |===
        """
        let document = parse(text)
        let found = document.lines[1].block.map { document.blocks[$0] }
        XCTAssertEqual(found?.kind, .table(alignments: [.leading, .leading, .leading]))
        XCTAssertEqual(found?.lines, 0...6)
        XCTAssertEqual(document.lines[2].kind, .tableHeader)
        XCTAssertEqual(document.lines[4].kind, .tableRow)
        let rows = AsciiDocTable.rows(Array(text.utf16), lines: document.lines, inner: 2..<6, separator: 124, columns: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].cells.map { (text as NSString).substring(with: $0.range) }, ["F-1", "funktional", "Alle Datenbanken"])
    }

    func testCellsOnLinesOfTheirOwn() {
        let text = """
        [cols="2,5,2"]
        |===
        | Baustein | Aufgabe | Neu?

        | `pia-backup.sh`
        | Sichert alle Datenbanken
        und Volumes.
        | neu

        2+| zwei Spalten
        | eins
        |===
        """
        let document = parse(text)
        let rows = AsciiDocTable.rows(Array(text.utf16), lines: document.lines, inner: 2..<11, separator: 124, columns: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].cells.map { (text as NSString).substring(with: $0.range) }, ["`pia-backup.sh`", "Sichert alle Datenbanken\nund Volumes.", "neu"])
        XCTAssertEqual(rows[1].lines, [4, 5, 6, 7])
        XCTAssertEqual(rows[2].cells.first?.span, 2)
        XCTAssertEqual(document.lines[2].kind, .tableHeader, "a single line with a blank line under it is the header")
    }

    func testColumnSpec() {
        let spec = AsciiDocTable.Spec(attributes: [#"cols="^1,3*2,>1a", options="header""#])
        XCTAssertEqual(spec.columns, 5)
        XCTAssertEqual(spec.alignments, [.center, .leading, .leading, .leading, .trailing])
        XCTAssertEqual(spec.weights, [1, 2, 2, 2, 1])
        XCTAssertEqual(spec.header, true)
        XCTAssertEqual(AsciiDocTable.Spec(attributes: ["%header,cols=3"]).columns, 3)
        XCTAssertEqual(AsciiDocTable.Spec(attributes: ["%header,cols=3"]).header, true)
    }

    // MARK: - Inline

    func testConstrainedAndUnconstrainedMarks() {
        let result = spans("a *bold* and _it_ and `code` and **un**constrained and #mark#")
        XCTAssertTrue(result.contains { $0.0 == .strong && $0.1 == "bold" })
        XCTAssertTrue(result.contains { $0.0 == .emphasis && $0.1 == "it" })
        XCTAssertTrue(result.contains { $0.0 == .code && $0.1 == "code" })
        XCTAssertTrue(result.contains { $0.0 == .strong && $0.1 == "un" })
        XCTAssertTrue(result.contains { $0.0 == .highlight && $0.1 == "mark" })
    }

    func testMarksInsideWordsDontCount() {
        XCTAssertTrue(spans("snake_case_name and 2*3*4 and a#b#c").isEmpty)
    }

    func testLinks() {
        let text = "See https://example.com[the site], link:docs/a.pdf[the PDF], xref:other.adoc#goals[Goals], <<scope,Scope>> and https://bare.dev."
        let result = spans(text)
        XCTAssertTrue(result.contains { $0.0 == .link(destination: "https://example.com") && $0.1 == "the site" })
        XCTAssertTrue(result.contains { $0.0 == .link(destination: "docs/a.pdf") && $0.1 == "the PDF" })
        XCTAssertTrue(result.contains { $0.0 == .link(destination: "other.adoc#goals") && $0.1 == "Goals" })
        XCTAssertTrue(result.contains { $0.0 == .link(destination: "#scope") && $0.1 == "Scope" })
        XCTAssertTrue(result.contains { $0.0 == .autolink(url: "https://bare.dev") && $0.1 == "https://bare.dev" })
    }

    func testImagesIncludesAndImagesDir() {
        let text = ":imagesdir: images\n\nimage::overview.png[Overview]\n\ninclude::sections/01_intro.adoc[]"
        let result = spans(text)
        XCTAssertTrue(result.contains { $0.0 == .image(source: "images/overview.png", alt: "Overview") })
        XCTAssertTrue(result.contains { $0.0 == .embed(target: "sections/01_intro.adoc") })
    }

    func testRolesSuperscriptAndBreaks() {
        let result = spans("[.line-through]#gone# and E=mc^2^ and H~2~O +")
        XCTAssertTrue(result.contains { $0.0 == .strikethrough && $0.1 == "gone" })
        XCTAssertTrue(result.contains { $0.0 == .superscript && $0.1 == "2" })
        XCTAssertTrue(result.contains { $0.0 == .subscript && $0.1 == "2" })
        XCTAssertTrue(result.contains { $0.0 == .escape && $0.1 == "" })
    }

    func testEveryCharacterKeepsItsPlace() {
        let text = "= T\n:a: b\n\n* x\n----\ny\n----"
        let document = parse(text)
        XCTAssertEqual(document.length, (text as NSString).length)
        XCTAssertEqual(document.lines.count, 7)
        XCTAssertEqual(document.syntax, .asciidoc)
    }

    /// Every AsciiDoc file in a folder (`NOTEBOOK_ADOC_CORPUS`) reads without a crash, every line in at most one block
    /// that holds it.
    func testCorpus() throws {
        guard let folder = ProcessInfo.processInfo.environment["NOTEBOOK_ADOC_CORPUS"] else { throw XCTSkip("NOTEBOOK_ADOC_CORPUS not set") }
        let files = FileManager.default.enumerator(atPath: folder)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".adoc") && !$0.contains("/.claude/") && !$0.contains("node_modules") } ?? []
        var counts: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOfFile: folder + "/" + file, encoding: .utf8)
            let document = parse(text)
            for (index, line) in document.lines.enumerated() {
                counts[String("\(line.kind)".prefix { $0 != "(" }), default: 0] += 1
                if let block = line.block { XCTAssertTrue(document.blocks[block].lines.contains(index), file) }
            }
        }
        print("asciidoc corpus: \(files.count) files", counts.sorted { $0.value > $1.value })
    }
}

final class AsciiDocSpeedTests: XCTestCase {
    /// How long reading a long AsciiDoc file takes (`NOTEBOOK_ADOC_FILE`), next to the same text read as Markdown:
    /// the editor reads the whole note again with every keystroke.
    func testSpeed() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_ADOC_FILE"] else { throw XCTSkip("NOTEBOOK_ADOC_FILE not set") }
        let text = try String(contentsOfFile: path, encoding: .utf8) as NSString
        func time(_ syntax: NoteSyntax) -> Double {
            let start = Date()
            for _ in 0..<20 { _ = MarkdownParser.parse(text, typing: true, syntax: syntax) }
            return Date().timeIntervalSince(start) / 20 * 1000
        }
        _ = time(.asciidoc)
        print(String(format: "asciidoc speed: %d characters, AsciiDoc %.2f ms, Markdown %.2f ms", text.length, time(.asciidoc), time(.markdown)))
    }
}

final class AsciiDocReplacementTests: XCTestCase {
    private func replacements(_ text: String) -> [String] {
        MarkdownParser.parse(text, syntax: .asciidoc).lines.flatMap(\.spans).compactMap { if case .replacement(let shown) = $0.kind { shown } else { nil } }
    }

    func testDashesArrowsAndSigns() {
        XCTAssertEqual(replacements("PIA -- Target, A->B, B<-A, x=>y, (C) 2026 and so on..."), ["—", "→", "←", "⇒", "©", "…"])
        XCTAssertEqual(replacements("well--known"), ["—"])
    }

    func testNotInLongerRunsOrCode() {
        XCTAssertTrue(replacements("a --> b and <=> and ---- and `a -- b`").isEmpty)
        XCTAssertTrue(replacements("--").isEmpty, "an open block's delimiter")
    }
}
