import XCTest
@testable import NotebookKit

/// Links, search and Move To answer without going through every file, which took seconds for a whole iCloud Drive,
/// and stay right as files come, go and turn into folders.
@MainActor
final class SearchIndexTests: XCTestCase {
    private var library: URL!

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-index-\(UUID().uuidString)").standardizedFileURL
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

    private func makeIndex() async throws -> (index: SearchIndex, location: Location) {
        let location = Location(id: UUID(), name: "Notes", path: library.path, bookmark: nil)
        let index = SearchIndex()
        index.rebuild([location])
        try await waitUntil { !index.isBuilding }
        return (index, location)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "waited in vain")
    }

    func testLinksFollowFilesThatComeGoAndTurnIntoFolders() async throws {
        let other = try write("A/Other.md")
        try write("A/Plan.md")
        try write("B/Plan.md")
        try write("Pictures/photo.png")
        let (index, location) = try await makeIndex()
        XCTAssertEqual(index.resolve("Plan", from: other)?.path, library.appendingPathComponent("A/Plan.md").path, "the nearest first")
        XCTAssertEqual(index.resolve("plan.md#Today", from: other)?.path, library.appendingPathComponent("A/Plan.md").path)
        XCTAssertEqual(index.resolve("B/Plan", from: other)?.path, library.appendingPathComponent("B/Plan.md").path)
        XCTAssertEqual(index.resolve("photo.png", from: other)?.lastPathComponent, "photo.png")
        XCTAssertNil(index.resolve("photo", from: other), "only a note goes without its extension")
        XCTAssertNil(index.resolve("A", from: other), "folders aren't linked to")

        try FileManager.default.removeItem(at: library.appendingPathComponent("A/Plan.md"))
        let picture = library.appendingPathComponent("Pictures/photo.png")
        try FileManager.default.removeItem(at: picture)
        try FileManager.default.createDirectory(at: picture, withIntermediateDirectories: false)
        let folders = index.folderVersion
        index.refresh(folders: [library.appendingPathComponent("A"), library.appendingPathComponent("Pictures")], locations: [location])
        try await waitUntil { index.folderVersion != folders }
        XCTAssertEqual(index.resolve("Plan", from: other)?.path, library.appendingPathComponent("B/Plan.md").path)
        XCTAssertNil(index.resolve("photo.png", from: other), "a folder now")
        XCTAssertTrue(index.allFolders().contains { $0.path == picture.path })
    }

    func testSearchListsTheBestAsSortingThemAllWould() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let names = ["plan", "Plan B", "trip plan", "planets", "the-plan", "airplane", "p l a n", "pan", "Plum and nuts", "explain"]
        for (number, name) in names.enumerated() {
            try write("Folder \(number % 3)/\(name).md", "about \(name)\n", modified: start.addingTimeInterval(Double(number) * 60))
            try write("Folder \(number % 3)/\(name).txt", modified: start.addingTimeInterval(Double(number) * 30))
        }
        let (index, _) = try await makeIndex()
        for query in ["pl", "plan", "p", "an", "pln", "xyz"] {
            let q = SearchIndex.fold(query)
            let all = index.entries.filter { $0.kind != .folder }.compactMap { entry -> (Int, SearchIndex.Entry)? in
                // Names only a bit like it aren't among the files.
                SearchIndex.score(entry.foldedName, q).flatMap { $0 >= FuzzyMatch.goodScore ? ($0 + (entry.kind == .note ? 5 : 0), entry) : nil }
            }
            let sorted = all.sorted { a, b in
                if a.0 != b.0 { return a.0 > b.0 }
                if a.1.modified != b.1.modified { return (a.1.modified ?? .distantPast) > (b.1.modified ?? .distantPast) }
                return a.1.path < b.1.path
            }
            XCTAssertEqual(index.files(matching: query, limit: 6).map(\.path), sorted.prefix(6).map(\.1.path), query)
        }
        XCTAssertEqual(index.textHits("about p", limit: 3).map(\.item.name), ["Plum and nuts", "pan", "p l a n"], "newest first")
        XCTAssertEqual(index.linkSuggestions("", from: nil).map(\.title), ["explain", "Plum and nuts", "pan", "p l a n", "airplane", "the-plan"])
    }

    func testScores() {
        XCTAssertEqual(SearchIndex.score("trip plan", "trip plan"), 100)
        XCTAssertEqual(SearchIndex.score("trip plan", "trip"), 80)
        XCTAssertEqual(SearchIndex.score("trip plan", ""), 80)
        XCTAssertEqual(SearchIndex.score("my trip", "trip"), 60)
        XCTAssertEqual(SearchIndex.score("my-trip", "trip"), 60)
        XCTAssertEqual(SearchIndex.score("mytrip", "trip"), 40)
        XCTAssertEqual(SearchIndex.score("ütrip", "trip"), 40, "after a letter of two bytes")
        XCTAssertLessThan(SearchIndex.score("telematics ws24", "tlmtcs") ?? 99, 30, "the letters in order, below a name with it in it")
        XCTAssertGreaterThanOrEqual(SearchIndex.score("trip plan", "tp") ?? 0, FuzzyMatch.goodScore, "at the starts of its words")
        XCTAssertGreaterThanOrEqual(SearchIndex.score("trip", "trips") ?? 0, FuzzyMatch.goodScore, "a letter too many")
        XCTAssertNil(SearchIndex.score("trip", "tro"), "none wrong in a word of three")
        XCTAssertNil(SearchIndex.score("plan", "nalp"))
        XCTAssertEqual(SearchIndex.score(SearchIndex.fold("Äußere Wendung"), SearchIndex.fold("äuß")), 80)
        XCTAssertEqual(SearchIndex.score(SearchIndex.fold("Notizen für Montag"), SearchIndex.fold("FÜR")), 60)
        XCTAssertEqual(SearchIndex.score("日本語のノート", "ノート"), 40)
        XCTAssertNotNil(SearchIndex.score("日本語のノート", "日ノ"))
    }

    /// A link is looked up by its name, not by going through every file: thousands of files make no difference.
    func testLinksResolveAtOnceAmongThousandsOfFiles() async throws {
        for folder in 0..<100 {
            for file in 0..<100 { try write("Folder \(folder)/File \(folder)-\(file).md") }
        }
        let (index, _) = try await makeIndex()
        XCTAssertGreaterThan(index.count, 10_000)
        let note = library.appendingPathComponent("Folder 0/File 0-0.md")
        let start = Date()
        for number in 0..<200 {
            XCTAssertNotNil(index.resolve("File \(number % 100)-\(number / 2)", from: note))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "200 links")
    }

    /// Move To lists a folder made after the index was built, once it has been sorted in.
    func testMoveToFollowsNewFolders() async throws {
        let note = try write("Inbox/Note.md")
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        func folders() -> [String] { workspace.moveTargets(for: note).flatMap { $0.folders.dropFirst().map(\.name) } }
        try await waitUntil { folders() == ["Inbox"] }
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Inbox/Later"), withIntermediateDirectories: false)
        workspace.readAgain([library.appendingPathComponent("Inbox")])
        try await waitUntil { folders() == ["Inbox", "Later"] }
        XCTAssertEqual(workspace.moveTargets(for: note).first?.folders.map(\.depth), [-1, 0, 1])
    }
}
