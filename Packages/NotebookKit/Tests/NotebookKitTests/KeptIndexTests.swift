import CoreText
import XCTest
@testable import NotebookKit

/// The index is kept between launches: search has everything the moment the app opens, and building the index again
/// reads only the files that changed, takes out those that went, and ignores a kept index it can't trust.
@MainActor
final class KeptIndexTests: XCTestCase {
    private var library: URL!
    private var store: URL!

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-kept-\(UUID().uuidString)").standardizedFileURL
        library = folder.appendingPathComponent("Library")
        store = folder.appendingPathComponent("Search index")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    @discardableResult
    private func write(_ path: String, _ text: String = "", modified: Date? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "waited in vain")
    }

    /// Starts the index as the app does, with the library as a location given on the command line (a new ID every
    /// launch), calls `whileReading` once what was kept is in place and the files are still being read, and keeps the
    /// index when it is done, PDFs and all.
    private func launch(whileReading: ((SearchIndex) -> Void)? = nil) async throws -> SearchIndex {
        let location = Location(id: UUID(), name: "Notes", path: library.path, bookmark: nil)
        let index = SearchIndex()
        index.storeURL = store
        index.onBuilt = { [unowned index] in
            if index.isBuilding { whileReading?(index) }
        }
        index.loadKept(for: [location])
        index.rebuild([location])
        try await waitUntil { !index.isBuilding && !index.isReadingPDFs }
        index.save()
        await index.lastSave?.value
        return index
    }

    private func names(_ hits: [SearchCorpus.TextHit]) -> [String] {
        hits.map(\.item.name)
    }

    func testSearchHasEverythingBeforeTheFilesAreRead() async throws {
        try write("Travel/Kyoto.md", "# Kyoto\n\nTemple gardens in autumn.\n\n## Day trips\n\nNara, with [[Budget]].\n")
        try write("Work/Budget.md", "Quarterly numbers\n")
        try write("Travel/ticket.png")
        try makePDF("Travel/Boarding pass.pdf", "Boarding pass to Osaka, seat 32A")
        let first = try await launch()
        XCTAssertEqual(names(first.textHits("osaka")), ["Boarding pass.pdf"], "the PDF's text was read")

        var texts: [String] = [], headings: [String] = [], files = 0
        var link: URL?
        let index = try await launch { index in
            files = index.count
            texts = self.names(index.textHits("temple gardens")) + self.names(index.textHits("seat 32a"))
            let results = index.currentCorpus().search(SearchCorpus.Query("day trips")!)
            headings = results.headings.map(\.heading.title)
            link = index.resolve("Budget", from: self.library.appendingPathComponent("Travel/Kyoto.md"))
        }
        XCTAssertEqual(files, 6, "two folders and four files, before any was read")
        XCTAssertEqual(texts, ["Kyoto", "Boarding pass.pdf"])
        XCTAssertEqual(headings, ["Day trips"])
        XCTAssertEqual(link?.lastPathComponent, "Budget.md")
        #if DEBUG
        XCTAssertEqual(index.lastBuild.notesRead, 0, "nothing changed")
        XCTAssertEqual(index.lastBuild.pdfs, 0, "nor is the PDF's text read again")
        #endif
    }

    func testARelaunchReadsWhatChangedAndDropsWhatWent() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("A.md", "alpha apples", modified: date)
        try write("Old/B.md", "beta bananas", modified: date)
        try write("C.md", "gamma grapes", modified: date)
        _ = try await launch()

        try write("A.md", "alpha apricots, and more of them", modified: date.addingTimeInterval(60))
        try FileManager.default.removeItem(at: library.appendingPathComponent("Old"))
        // The same size and date: taken for the note as it was, without reading it.
        try write("C.md", "gamma guavas", modified: date)
        try write("New/D.md", "delta dates")
        var before: [String] = []
        let index = try await launch { before = self.names($0.textHits("bananas")) + self.names($0.textHits("apples")) }
        XCTAssertEqual(before, ["B", "A"], "what was kept, while the files are read")
        XCTAssertEqual(names(index.textHits("apricots")), ["A"])
        XCTAssertEqual(names(index.textHits("apples")), [])
        XCTAssertEqual(names(index.textHits("bananas")), [])
        XCTAssertNil(index.entry(for: library.appendingPathComponent("Old/B.md")))
        XCTAssertNil(index.entry(for: library.appendingPathComponent("Old")))
        XCTAssertFalse(index.allFolders().contains { $0.name == "Old" })
        XCTAssertEqual(names(index.textHits("dates")), ["D"])
        XCTAssertEqual(index.resolve("D", from: nil)?.lastPathComponent, "D.md")
        XCTAssertEqual(names(index.textHits("grapes")), ["C"])
        #if DEBUG
        XCTAssertEqual(index.lastBuild.notesRead, 2, "A and D")
        #endif

        // What the second launch found is kept too.
        let third = try await launch()
        XCTAssertEqual(names(third.textHits("dates")), ["D"])
        XCTAssertNil(third.entry(for: library.appendingPathComponent("Old/B.md")))
    }

    func testAKeptIndexThatCantBeTrustedIsIgnored() async throws {
        try write("Note.md", "words to find")
        _ = try await launch()
        let good = try Data(contentsOf: store)
        let locations = [(id: UUID(), path: library.path)]
        XCTAssertEqual(KeptIndex.read(store, locations: locations)?.map(\.name).sorted(), ["Note"])
        XCTAssertEqual(KeptIndex.read(store, locations: [])?.count, 0, "nothing in a location that is gone")

        var older = good
        older[4] = 0
        var damaged = good
        damaged[good.count - 3] ^= 0xFF
        for (data, kind) in [(Data("not an index".utf8), "something else"), (good.prefix(good.count - 10), "cut short"),
                             (older, "of another version"), (damaged, "damaged"), (Data(), "empty")] {
            try data.write(to: store)
            XCTAssertNil(KeptIndex.read(store, locations: locations), kind)
            var during: [String]?
            let index = try await launch { during = self.names($0.textHits("words")) }
            XCTAssertNil(during, "nothing put in place for one \(kind)")
            XCTAssertEqual(names(index.textHits("words to find")), ["Note"], kind)
            XCTAssertEqual(KeptIndex.read(store, locations: locations)?.count, 1, "kept anew after one \(kind)")
        }
    }

    /// Everything an entry is made of comes back as it was.
    func testEntriesComeBackAsTheyWere() async throws {
        try write("Trips/Japan/Kyoto.md", "---\ntitle: x\n---\n# Kyoto ##\n\n![](.assets/map.png)\n\n### **Day** two\n")
        try write("Trips/Japan/.assets/map.png")
        try write("Trips/Ünïcödé 日本.txt", "")
        let first = try await launch()
        let location = Location(id: UUID(), name: "Notes", path: library.path, bookmark: nil)
        let kept = try XCTUnwrap(KeptIndex.read(store, locations: [(location.id, location.url.path)]))
        XCTAssertEqual(kept.count, first.count)
        for entry in kept {
            let original = try XCTUnwrap(first.entry(for: entry.url), entry.path)
            XCTAssertEqual(entry.url, original.url)
            XCTAssertEqual(entry.name, original.name)
            XCTAssertEqual(entry.kind, original.kind)
            XCTAssertEqual(entry.place, original.place)
            XCTAssertEqual(entry.locationID, location.id)
            XCTAssertEqual(entry.modified, original.modified)
            XCTAssertEqual(entry.size, original.size)
            XCTAssertEqual(entry.isInCloud, original.isInCloud)
            XCTAssertEqual(entry.text, original.text)
            XCTAssertEqual(entry.folded, original.folded)
            XCTAssertEqual(entry.foldedName, original.foldedName)
            XCTAssertEqual(entry.foldedFileName, original.foldedFileName)
            XCTAssertEqual(entry.path, original.path)
            XCTAssertEqual(entry.folder, original.folder)
            XCTAssertEqual(entry.headings, original.headings)
            XCTAssertEqual(entry.assets, original.assets)
            XCTAssertEqual(entry.pagesWithoutText, original.pagesWithoutText)
        }
        let note = try XCTUnwrap(kept.first { $0.name == "Kyoto" })
        XCTAssertEqual(note.place, "Notes › Trips › Japan")
        XCTAssertEqual(note.headings.map(\.title), ["Kyoto", "Day two"])
        XCTAssertEqual(note.assets, ["map.png"])
    }

    /// A PDF with a line of text on its one page.
    private func makePDF(_ path: String, _ text: String) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data as Data).write(to: url)
    }
}
