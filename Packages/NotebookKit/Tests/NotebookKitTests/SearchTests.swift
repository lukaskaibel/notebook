import AppKit
import XCTest
@testable import NotebookKit

/// Search finds every kind of thing (files, folders, headings, words in notes, PDFs and pictures), in the background,
/// and opens a note or PDF where it found the words.
@MainActor
final class SearchTests: XCTestCase {
    private var library: URL!

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-search-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: library)
    }

    @discardableResult
    private func write(_ path: String, _ text: String = "", modified: Date? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func makeIndex() async throws -> SearchIndex {
        let index = SearchIndex()
        index.rebuild([Location(id: UUID(), name: "Notes", path: library.path, bookmark: nil)])
        try await waitUntil { !index.isBuilding }
        return index
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "waited in vain")
    }

    private func search(_ index: SearchIndex, _ text: String) throws -> SearchCorpus.Results {
        try index.currentCorpus().search(XCTUnwrap(SearchCorpus.Query(text)))
    }

    func testWordsAreFoundInAnyOrderTogetherFirst() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try write("Apart.md", "The budget for the trip is in the quarterly plan.\n", modified: start.addingTimeInterval(120))
        try write("Together.md", "Our quarterly budget is done.\n", modified: start)
        try write("One word.md", "Only the budget here.\n", modified: start.addingTimeInterval(240))
        let index = try await makeIndex()
        let results = try search(index, "Quarterly Budget")
        XCTAssertEqual(results.texts.map(\.item.name), ["Together", "Apart"], "the words together first, though older")
        XCTAssertEqual(results.textCount, 2)
        let apart = try XCTUnwrap(results.texts.last)
        XCTAssertEqual(apart.matches.map { String(apart.snippet[$0]) }, ["budget", "quarterly"], "each word marked")
        XCTAssertEqual(try search(index, "budget quarterly").texts.map(\.item.name), ["Apart", "Together"], "in the order typed, together comes first")
    }

    func testFoldersHeadingsAndNamesAreFound() async throws {
        try write("Travel/Kyoto trip.md", "# Kyoto trip\n\n## Packing list\n- passport\n\n```\n# not a heading\n```\n")
        try write("Travel/Kyoto/photo.png")
        try write("Work/Packing boxes.md", "Boxes.\n")
        let index = try await makeIndex()
        var results = try search(index, "kyoto")
        XCTAssertEqual(results.files.map(\.name), ["Kyoto trip"])
        XCTAssertEqual(results.folders.map(\.name), ["Kyoto"])
        XCTAssertTrue(results.headings.isEmpty, "the note's name as its first heading is found as the note")
        results = try search(index, "packing")
        XCTAssertEqual(results.files.map(\.name), ["Packing boxes"])
        XCTAssertEqual(results.headings.map(\.heading.title), ["Packing list"])
        XCTAssertEqual(results.headings.first?.item.name, "Kyoto trip")
        XCTAssertTrue(try search(index, "not a heading").headings.isEmpty, "code blocks have no headings")
        XCTAssertEqual(try search(index, "kytr").files.map(\.name), ["Kyoto trip"], "the letters in order")
        XCTAssertEqual(try search(index, "trip kyoto").files.map(\.name), ["Kyoto trip"], "every word, in any order")
    }

    /// A name that is exactly what was typed comes first wherever it is in the corpus, the last one included.
    func testTheLastNameMatchesWhole() throws {
        func entry(_ name: String, modified: TimeInterval) -> SearchIndex.Entry {
            let url = URL(fileURLWithPath: "/Notes/\(name).md")
            return SearchIndex.Entry(url: url, name: name, kind: .note, place: "Notes", locationID: UUID(),
                                     modified: Date(timeIntervalSince1970: modified), isInCloud: false, text: nil, folded: nil,
                                     foldedName: SearchIndex.fold(name), foldedFileName: SearchIndex.fold(name + ".md"),
                                     path: url.path, folder: "/Notes")
        }
        let corpus = SearchCorpus(version: 0, entries: [entry("Plan B", modified: 200), entry("Plan", modified: 100)], hidden: [], recognized: [:])
        let found = corpus.matchNames(try XCTUnwrap(SearchCorpus.Query("plan")), files: 2, folders: 0).files
        XCTAssertEqual(found.map { corpus.items[$0].name }, ["Plan", "Plan B"], "the whole name before a newer one that starts with it")
        let headings = SearchCorpus(version: 0, entries: [{ var note = entry("Trip", modified: 0); note.headings = [.init(level: 2, title: "Plan")]; return note }()],
                                    hidden: [], recognized: [:])
        XCTAssertEqual(headings.search(try XCTUnwrap(SearchCorpus.Query("plan"))).headings.map(\.heading.title), ["Plan"])
    }

    func testHeadingsAreReadWithoutTheirMarkdown() {
        let text = """
        ---
        # comment: not a heading
        tags: [a]
        ---
        # **Plan** for [[Kyoto|the trip]]
        ## Costs ##
        #hashtag
           ### [Booking](https://example.com) `code`
        ~~~
        ## fenced
        ~~~
        ####### seven
        """
        XCTAssertEqual(SearchIndex.headings(in: text), [
            SearchIndex.Heading(level: 1, title: "Plan for the trip"),
            SearchIndex.Heading(level: 2, title: "Costs"),
            SearchIndex.Heading(level: 3, title: "Booking code"),
        ])
    }

    func testTextReadInPicturesIsFoundAsTheNotesThatShowThem() async throws {
        let note = try write("Trip/Kyoto.md", "Tickets:\n\n![](.assets/ticket%201.png)\n\n![Drawing](.assets/Sketch.png)\n")
        let index = try await makeIndex()
        let folder = note.deletingLastPathComponent().path
        index.recognized = [
            folder + "/.assets/ticket 1.png": PictureText("SHINKANSEN NOZOMI 225\nKyoto 14:09", isHandwriting: false),
            folder + "/.assets/Sketch.png": PictureText("ryokan by the river", isHandwriting: true),
        ]
        var results = try search(index, "nozomi")
        XCTAssertEqual(results.pictures.map(\.item.name), ["Kyoto"])
        XCTAssertEqual(results.pictures.first?.source, .picture(asset: "ticket 1.png"))
        XCTAssertEqual(results.pictures.first?.snippet, "SHINKANSEN NOZOMI 225")
        results = try search(index, "river")
        XCTAssertEqual(results.pictures.first?.source, .drawing(asset: "Sketch.png"))
        XCTAssertTrue(results.texts.isEmpty, "not in the note's own text")
    }

    func testAPDFsHitSaysItsPage() throws {
        let text = "Cover page\u{0C}Contents\nFlights\u{0C}Return flight on Sunday, seat 32A"
        let snippet = SearchCorpus.snippet(of: text, try XCTUnwrap(SearchCorpus.Query("seat 32a")))
        XCTAssertEqual(snippet.page, 3)
        XCTAssertEqual(snippet.text, "Return flight on Sunday, seat 32A")
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["seat 32A"])
    }

    /// A search for what was typed before never shows over a newer one, however long it takes.
    func testOnlyTheLastSearchShows() async throws {
        for number in 0..<300 { try write("Notes/Note \(number).md", "about the moon and the sea, number n\(number)z\n") }
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        try await waitUntil { !workspace.index.isBuilding && workspace.index.corpus.items.count > 300 }
        let session = SearchSession(workspace: workspace)
        var shown: [String] = []
        session.onResults = { sections in shown.append(sections.first?.items.first?.title ?? "") }
        for typed in ["m", "mo", "moo", "moon", "moon n", "moon n7", "moon n7z"] { session.update(typed) }
        try await waitUntil { !session.isSearching }
        XCTAssertEqual(session.query, "moon n7z")
        XCTAssertEqual(session.sections.first { $0.title == "In Notes and PDFs" }?.items.first?.title, "Note 7")
        XCTAssertLessThanOrEqual(shown.count, 2, "the searches before were dropped: \(shown)")
    }

    func testANoteOpensAtTheWordsAndHeadingsSearchFound() async throws {
        let lines = (1...80).map { "Line \($0) of the note." }.joined(separator: "\n")
        let url = try write("Long.md", "\(lines)\n## Return flight\nSeat 32A, window.\n\(lines)\n")
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        workspace.editor.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = workspace.editor.scrollView
        workspace.open(.text(url, words: "window seat", page: nil))
        try await waitUntil { workspace.note?.isLoaded == true }
        let text = workspace.editor.text as NSString
        XCTAssertEqual(workspace.editor.textView.selectedRange(), text.range(of: "window"), "the longest word, as they aren't together")
        XCTAssertGreaterThan(workspace.editor.scrollView.contentView.bounds.minY, 300, "scrolled down to it")
        workspace.open(.heading(url, title: "Return flight"))
        let heading = text.range(of: "## Return flight")
        XCTAssertEqual(workspace.editor.textView.selectedRange(), NSRange(location: heading.upperBound, length: 0))
    }

    /// ⌘K's commands are found by a few letters, or by other words for them.
    func testCommandsAreFoundLoosely() {
        XCTAssertNotNil(fuzzyScore("nf", "New Folder"))
        XCTAssertNil(fuzzyScore("fn", "New Folder"))
        XCTAssertGreaterThan(fuzzyScore("new", "New Note") ?? 0, fuzzyScore("new", "Show Only Notes, Not Files") ?? 0)
        let command = PaletteCommand(id: "trash", title: "Move to Trash", symbol: "trash", section: "", keywords: ["delete"]) {}
        XCTAssertNotNil(command.score("dele"))
    }
}
