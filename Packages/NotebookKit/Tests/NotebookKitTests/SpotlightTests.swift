import Synchronization
import XCTest
@testable import NotebookKit

/// The notes in Spotlight: every note in the locations, with its name, first lines and folder, given from what search
/// knows and following the files as they change, hidden folders and removed locations left out; only what changed is
/// given again after a relaunch, and a note picked in Spotlight opens. Spotlight itself is a stand-in here.
@MainActor
final class SpotlightTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    private var trip: URL { library.appendingPathComponent("Travel/Kyoto trip.md") }
    private var doctor: URL { library.appendingPathComponent("Personal/Doctor.md") }
    private var old: URL { library.appendingPathComponent("Archive/Old flat.md") }
    private var record: URL { base.appendingPathComponent("Spotlight") }
    private let spotlight = StandInSpotlight()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-spotlight-\(UUID().uuidString)").standardizedFileURL
        for folder in ["Travel", "Personal", "Archive"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "# Kyoto trip\n\nTwo weeks in **October**, with a day in [[Nara]].\n\n- [ ] Pack the adapter\n".write(to: trip, atomically: true, encoding: .utf8)
        try "Questions for Dr. Weber\n".write(to: doctor, atomically: true, encoding: .utf8)
        try "The old flat\n".write(to: old, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: library.appendingPathComponent("Travel/Tickets.pdf"))
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    /// A workspace on the library, as after a launch, with Spotlight given what it gets.
    private func makeWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        let index = SpotlightIndex(store: spotlight, recordURL: record)
        index.delay = .zero
        workspace.spotlight = index
        workspace.start()
        try await until("Spotlight has the notes") { workspace.index.hasBuilt && !workspace.index.isBuilding && index.updates > 0 && !index.isUpdating }
        return workspace
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    /// Waits for Spotlight to have been updated since `updates`.
    private func updated(_ workspace: Workspace, since updates: Int) async throws {
        let index = try XCTUnwrap(workspace.spotlight)
        try await until("Spotlight was updated") { index.updates > updates && !index.isUpdating }
    }

    private var titles: Set<String> { Set(spotlight.items.values.map(\.title)) }

    func testEveryNoteGoesIntoSpotlight() async throws {
        let workspace = try await makeWorkspace()
        let location = try XCTUnwrap(workspace.locations.first)
        XCTAssertEqual(titles, ["Kyoto trip", "Doctor", "Old flat"], "notes only, not the PDF")
        let item = try XCTUnwrap(spotlight.items[location.id.uuidString + "/Travel/Kyoto trip.md"])
        XCTAssertEqual(item.snippet, "Two weeks in October, with a day in Nara.\nPack the adapter", "the first lines, without the title")
        XCTAssertEqual(item.folder, "Travel")
        XCTAssertEqual(item.domain, location.id.uuidString)
        XCTAssertTrue(item.text?.contains("Pack the adapter") == true)
        XCTAssertEqual(spotlight.batches.count, 1, "the notes go in together")
    }

    func testSpotlightFollowsTheFiles() async throws {
        let workspace = try await makeWorkspace()
        let index = try XCTUnwrap(workspace.spotlight)
        let id = try XCTUnwrap(workspace.locations.first).id.uuidString

        // A note changed elsewhere goes in again, alone.
        var updates = index.updates
        try "Questions for Dr. Weber\n\nAsk about the results\n".write(to: doctor, atomically: true, encoding: .utf8)
        workspace.readAgain([doctor.deletingLastPathComponent()])
        try await updated(workspace, since: updates)
        XCTAssertEqual(spotlight.batches.last?.items.map(\.title), ["Doctor"])
        XCTAssertEqual(spotlight.items[id + "/Personal/Doctor.md"]?.snippet, "Questions for Dr. Weber\nAsk about the results")

        // Renamed and moved in Notebook: the old item goes, the new one comes.
        updates = index.updates
        let moved = await workspace.move(doctor, into: library.appendingPathComponent("Archive")).value
        XCTAssertNotNil(moved)
        try await until("the moved note is in Spotlight") { self.spotlight.items[id + "/Archive/Doctor.md"] != nil }
        XCTAssertNil(spotlight.items[id + "/Personal/Doctor.md"])

        // Thrown away, it goes from Spotlight.
        let trashed = await workspace.trash(library.appendingPathComponent("Archive/Doctor.md")).value
        XCTAssertTrue(trashed)
        try await until("the trashed note left Spotlight") { self.spotlight.items[id + "/Archive/Doctor.md"] == nil }

        // A hidden folder's notes go, even while its location shows hidden folders, and come back when it's shown.
        let archive = library.appendingPathComponent("Archive")
        workspace.setHidden(archive, true)
        try await until("the hidden note left Spotlight") { !self.titles.contains("Old flat") }
        let location = try XCTUnwrap(workspace.locations.first)
        workspace.showHiddenFolders(true, in: location)
        updates = index.updates
        workspace.readAgain([archive])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(titles.contains("Old flat"), "shown for now, still hidden")
        workspace.setHidden(archive, false)
        try await until("the note is back in Spotlight") { self.titles.contains("Old flat") }

        // A note moved out of the location in the Finder goes too.
        try FileManager.default.moveItem(at: trip, to: base.appendingPathComponent("Kyoto trip.md"))
        workspace.readAgain([trip.deletingLastPathComponent()])
        try await until("the note moved away left Spotlight") { !self.titles.contains("Kyoto trip") }

        // With its location removed, all of its notes go.
        workspace.removeLocation(location.id)
        try await until("the location's notes left Spotlight") { self.spotlight.items.isEmpty }
    }

    /// A launch gives Spotlight only what changed since the last; when Spotlight doesn't have what was written down,
    /// everything goes in again.
    func testARelaunchGivesOnlyWhatChanged() async throws {
        _ = try await makeWorkspace()
        var batches = spotlight.batches.count
        _ = try await makeWorkspace()
        XCTAssertEqual(spotlight.batches.count, batches, "nothing changed")

        try "The old flat, sold\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: trip)
        _ = try await makeWorkspace()
        XCTAssertEqual(spotlight.batches.last?.items.map(\.title), ["Old flat"])
        XCTAssertEqual(spotlight.batches.last?.deleted.count, 1)
        XCTAssertEqual(titles, ["Doctor", "Old flat"])

        // Spotlight's index was made again: every note goes in again.
        spotlight.reset()
        batches = spotlight.batches.count
        _ = try await makeWorkspace()
        XCTAssertEqual(titles, ["Doctor", "Old flat"])
        XCTAssertEqual(spotlight.batches.count, batches + 1)

        // The record was lost: every note goes in again, in place of what Spotlight has, which isn't emptied first.
        try FileManager.default.removeItem(at: record)
        batches = spotlight.batches.count
        _ = try await makeWorkspace()
        XCTAssertEqual(spotlight.batches.last?.items.count, 2)
        XCTAssertEqual(spotlight.batches.count, batches + 1)
        XCTAssertEqual(spotlight.deletions, 0)
        XCTAssertEqual(titles, ["Doctor", "Old flat"])
        // And from then on, only what changed.
        batches = spotlight.batches.count
        _ = try await makeWorkspace()
        XCTAssertEqual(spotlight.batches.count, batches)
    }

    /// A batch Spotlight doesn't take is given again.
    func testABatchThatFailedIsGivenAgain() async throws {
        spotlight.failures = 1
        let workspace = try await makeWorkspace()
        XCTAssertTrue(spotlight.items.isEmpty)
        XCTAssertTrue(try XCTUnwrap(workspace.spotlight).lastUpdate.failed)
        try "Questions for Dr. Weber, again\n".write(to: doctor, atomically: true, encoding: .utf8)
        workspace.readAgain([doctor.deletingLastPathComponent()])
        try await until("every note is in Spotlight") { self.titles == ["Kyoto trip", "Doctor", "Old flat"] }
    }

    // MARK: - Opening

    func testANotePickedInSpotlightOpens() async throws {
        let workspace = try await makeWorkspace()
        let id = try XCTUnwrap(workspace.locations.first).id.uuidString
        workspace.openSpotlightItem(id + "/Travel/Kyoto trip.md")
        XCTAssertEqual(workspace.currentURL?.path, trip.path)

        // Moved since Spotlight heard of it: found by its name.
        let moved = library.appendingPathComponent("Personal/Kyoto trip.md")
        try FileManager.default.moveItem(at: trip, to: moved)
        workspace.readAgain([library.appendingPathComponent("Travel"), library.appendingPathComponent("Personal")])
        try await until("the index has the moved note") { workspace.index.entry(for: moved) != nil }
        workspace.open(doctor)
        workspace.openSpotlightItem(id + "/Travel/Kyoto trip.md")
        XCTAssertEqual(workspace.currentURL?.path, moved.path)

        // Not there at all: nothing opens, and Spotlight lets go of it.
        let index = try XCTUnwrap(workspace.spotlight)
        let updates = index.updates
        spotlight.add(id + "/Travel/Gone.md")
        workspace.openSpotlightItem(id + "/Travel/Gone.md")
        XCTAssertEqual(workspace.currentURL?.path, moved.path)
        try await updated(workspace, since: updates)
        XCTAssertNil(spotlight.items[id + "/Travel/Gone.md"])

        // Nothing outside a location opens, whatever the identifier says.
        workspace.openSpotlightItem(id + "/../../etc/hosts")
        workspace.openSpotlightItem(UUID().uuidString + "/Travel/Kyoto trip.md")
        XCTAssertEqual(workspace.currentURL?.path, moved.path)
    }

    func testSearchInAppSearchesInThePalette() async throws {
        let workspace = try await makeWorkspace()
        workspace.searchFromSpotlight("kyoto")
        XCTAssertEqual(workspace.palette, .search)
        XCTAssertEqual(workspace.paletteStart?.query, "kyoto")
    }

    // MARK: - Identifiers

    /// An identifier names a note by its location and its place there, through a linked folder's link, and is found
    /// again wherever the location's folder is now.
    func testIdentifiersAreFoundAgainThroughTheLocations() throws {
        let drive = "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs"
        var location = Location(id: UUID(), name: "iCloud Drive", path: drive, bookmark: nil)
        location.linked = [
            LinkedFolder(name: "Desktop", url: URL(fileURLWithPath: "/Users/someone/Desktop"), alias: URL(fileURLWithPath: drive + "/Desktop")),
            LinkedFolder(name: "Obsidian", url: URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/iCloud~md~obsidian/Documents"),
                         alias: URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/iCloud~md~obsidian/Documents")),
        ]
        let id = location.id.uuidString
        let cases = [
            (drive + "/Notes/Plan.md", id + "/Notes/Plan.md"),
            ("/Users/someone/Desktop/Trip/Plan.md", id + "/Desktop/Trip/Plan.md"),
            ("/Users/someone/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Idea.md", id + "/../iCloud~md~obsidian/Documents/Vault/Idea.md"),
        ]
        for (path, identifier) in cases {
            XCTAssertEqual(SpotlightIndex.identifier(of: path, in: location), identifier)
            XCTAssertEqual(SpotlightIndex.path(of: identifier, in: [location]), path)
        }
        XCTAssertNil(SpotlightIndex.identifier(of: "/Users/someone/Documents/Plan.md", in: location), "not in the location")

        // The location's folder moved: the same identifier finds the note there.
        var notes = Location(id: UUID(), name: "Notes", path: "/private/tmp/Notes", bookmark: nil)
        let identifier = try XCTUnwrap(SpotlightIndex.identifier(of: "/private/tmp/Notes/Plan.md", in: notes))
        XCTAssertEqual(SpotlightIndex.identifier(of: "/tmp/Notes/Plan.md", in: notes), identifier, "/private/tmp is /tmp")
        notes.path = "/Users/someone/Notes"
        XCTAssertEqual(SpotlightIndex.path(of: identifier, in: [notes]), "/Users/someone/Notes/Plan.md")

        for wrong in [notes.id.uuidString + "/../Other/Plan.md", notes.id.uuidString + "/a/../../Plan.md", notes.id.uuidString + "/", "Plan.md",
                      UUID().uuidString + "/Plan.md"] {
            XCTAssertNil(SpotlightIndex.path(of: wrong, in: [notes]), wrong)
        }
    }

    /// The same folder on the command line gets the same location ID at every launch.
    func testAFolderGivenOnTheCommandLineKeepsItsID() {
        XCTAssertEqual(Location.id(for: "/tmp/Notes"), Location.id(for: "/tmp/Notes"))
        XCTAssertNotEqual(Location.id(for: "/tmp/Notes"), Location.id(for: "/tmp/Other"))
        XCTAssertEqual(Location.id(for: "/private/tmp/Notes"), Location.id(for: "/tmp/Notes"), "before and after the folder is made")
    }

    func testTheSnippetIsTheNotesFirstLines() {
        let note = "---\ntags: [trip]\n---\n# Kyoto\n\n![Map](.assets/map.png)\n\n```\ncode\n```\n\n## Days\n\n1. Arrive at **Kansai**\n- [x] Book the ryokan 📅 2026-10-02\n"
        XCTAssertEqual(NotePoints.beginning(of: note, title: "Kyoto"), "Days\nArrive at Kansai\nBook the ryokan")
        let long = String(repeating: "word ", count: 200)
        let snippet = NotePoints.beginning(of: long, title: "Long")
        XCTAssertEqual(snippet.count, 300)
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertEqual(NotePoints.beginning(of: "", title: "Empty"), "")
    }
}

/// Spotlight, as far as Notebook can tell: the items it has, the number of its last batch, and batches it refuses
/// when that isn't the one expected.
final class StandInSpotlight: SpotlightStore {
    private struct Contents {
        var items: [String: SpotlightIndex.Item] = [:]
        var state = 0
        var batches: [SpotlightIndex.Batch] = []
        var deletions = 0
        var failures = 0
    }

    private struct Refused: Error {}

    private let contents = Mutex(Contents())

    var items: [String: SpotlightIndex.Item] { contents.withLock { $0.items } }
    var batches: [SpotlightIndex.Batch] { contents.withLock { $0.batches } }
    var deletions: Int { contents.withLock { $0.deletions } }
    var failures: Int {
        get { contents.withLock { $0.failures } }
        set { contents.withLock { $0.failures = newValue } }
    }

    var isAvailable: Bool { true }

    func apply(_ batch: SpotlightIndex.Batch, expected: Int?, state: Int) async throws {
        try contents.withLock { contents in
            if contents.failures > 0 {
                contents.failures -= 1
                throw Refused()
            }
            if let expected, expected != contents.state { throw SpotlightMismatch.state }
            for id in batch.deleted { contents.items[id] = nil }
            for item in batch.items { contents.items[item.id] = item }
            contents.state = state
            // The empty batch of a launch, which only checks the number, gives nothing.
            if !batch.items.isEmpty || !batch.deleted.isEmpty { contents.batches.append(batch) }
        }
    }

    func deleteAll() async throws {
        contents.withLock { contents in
            contents.items = [:]
            contents.state = 0
            contents.deletions += 1
        }
    }

    /// As when Spotlight's own index is made again.
    func reset() {
        contents.withLock { contents in
            contents.items = [:]
            contents.state = 0
        }
    }

    /// An item Notebook doesn't know of.
    func add(_ id: String) {
        contents.withLock { $0.items[id] = SpotlightIndex.Item(id: id, domain: "", title: "", snippet: "", folder: "") }
    }
}
