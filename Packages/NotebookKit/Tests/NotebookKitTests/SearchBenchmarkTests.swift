import XCTest
@testable import NotebookKit

/// Times search on a big library: `NOTEBOOK_BENCH_LIBRARY=<folder> swift test --filter SearchBenchmarkTests`.
@MainActor
final class SearchBenchmarkTests: XCTestCase {
    func testTypingIntoSearch() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_BENCH_LIBRARY"] else { throw XCTSkip("no library") }
        let location = Location(id: UUID(), name: "iCloud Drive", path: path, bookmark: nil)
        let index = SearchIndex()
        var start = CACurrentMediaTime()
        index.rebuild([location])
        while index.isBuilding { try await Task.sleep(for: .milliseconds(20)) }
        print(String(format: "built %d entries in %.0f ms", index.count, (CACurrentMediaTime() - start) * 1000))
        start = CACurrentMediaTime()
        let corpus = index.currentCorpus()
        print(String(format: "corpus of %d files and %d texts in %.0f ms", corpus.items.count, corpus.documents.count, (CACurrentMediaTime() - start) * 1000))
        for word in ["meeting", "photosynthesis", "zebra", "quarterly budget"] {
            var line = "\(word):"
            for end in 1...word.count {
                guard let query = SearchCorpus.Query(String(word.prefix(end))) else { continue }
                start = CACurrentMediaTime()
                let results = corpus.search(query)
                line += String(format: " %@=%.1f(%d/%d)", query.text, (CACurrentMediaTime() - start) * 1000, results.files.count, results.texts.count)
            }
            print(line)
        }
    }

    /// The index kept between launches: how soon search has every file after a relaunch, and how long checking the
    /// files then takes. `NOTEBOOK_BENCH_LIBRARY=<folder> swift test --filter SearchBenchmarkTests/testRelaunching`.
    func testRelaunching() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_BENCH_LIBRARY"] else { throw XCTSkip("no library") }
        let location = Location(id: UUID(), name: "iCloud Drive", path: path, bookmark: nil)
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        func since(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }
        func notesRead() -> Int {
            #if DEBUG
            SearchIndex.notesRead.load(ordering: .relaxed)
            #else
            0
            #endif
        }

        let first = SearchIndex()
        first.storeURL = store
        var start = CACurrentMediaTime()
        var read = notesRead()
        first.rebuild([location])
        while first.isBuilding { try await Task.sleep(for: .milliseconds(10)) }
        print(String(format: "first launch: built %d files in %.0f ms, reading %d notes", first.count, since(start), notesRead() - read))
        while first.isReadingPDFs { try await Task.sleep(for: .milliseconds(10)) }
        print(String(format: "first launch: PDFs read at %.0f ms", since(start)))
        await first.lastSave?.value
        start = CACurrentMediaTime()
        first.save()
        await first.lastSave?.value
        let size = try store.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print(String(format: "kept in %.0f ms: %.1f MB", since(start), Double(size) / 1_000_000))

        start = CACurrentMediaTime()
        let entries = try XCTUnwrap(KeptIndex.read(store, locations: [(location.id, location.url.path)]))
        print(String(format: "read %d kept files in %.0f ms", entries.count, since(start)))

        let index = SearchIndex()
        index.storeURL = store
        start = CACurrentMediaTime()
        read = notesRead()
        index.loadKept(for: [location])
        index.rebuild([location])
        while index.corpus.items.count < first.count, index.isBuilding { try await Task.sleep(for: .milliseconds(5)) }
        print(String(format: "relaunch: search has %d files at %.0f ms", index.corpus.items.count, since(start)))
        while index.isBuilding { try await Task.sleep(for: .milliseconds(10)) }
        print(String(format: "relaunch: files checked at %.0f ms, reading %d notes", since(start), notesRead() - read))
        XCTAssertEqual(index.count, first.count)
    }

    /// What Spotlight's updates cost, Spotlight itself left out: working out what changed with nothing given yet, with
    /// everything given, and with one note changed, and making the items of every note.
    /// `NOTEBOOK_BENCH_LIBRARY=<folder> swift test --filter SearchBenchmarkTests/testSpotlight`.
    func testSpotlight() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_BENCH_LIBRARY"] else { throw XCTSkip("no library") }
        let location = Location(id: UUID(), name: "iCloud Drive", path: path, bookmark: nil)
        func since(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }
        let index = SearchIndex()
        index.rebuild([location])
        while index.isBuilding { try await Task.sleep(for: .milliseconds(20)) }
        let snapshot = SpotlightIndex.Snapshot(entries: index.byPathSnapshot, hidden: [], locations: [location])

        var start = CACurrentMediaTime()
        let first = SpotlightIndex.plan(snapshot, donated: [:])
        print(String(format: "plan with nothing given: %d notes of %d files in %.0f ms", first.changed.count, index.count, since(start)))
        start = CACurrentMediaTime()
        let store = StandInSpotlight()
        let outcome = await SpotlightIndex.apply(first, to: SpotlightIndex.Record(), store: store, recordURL: nil)
        print(String(format: "every item made and handed over in %.0f ms, %d batches", since(start), store.batches.count))
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-bench-spotlight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: record) }
        start = CACurrentMediaTime()
        SpotlightIndex.write(outcome.record, to: record)
        let size = try record.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print(String(format: "record written in %.0f ms: %.0f KB; read in", since(start), Double(size) / 1000), terminator: "")
        start = CACurrentMediaTime()
        XCTAssertEqual(SpotlightIndex.read(record), outcome.record)
        print(String(format: " %.0f ms", since(start)))

        start = CACurrentMediaTime()
        let unchanged = SpotlightIndex.plan(snapshot, donated: outcome.record.items)
        print(String(format: "plan with everything given: %d changed in %.0f ms", unchanged.changed.count, since(start)))
        XCTAssertTrue(unchanged.changed.isEmpty && unchanged.gone.isEmpty)
        var entries = snapshot.entries
        let note = try XCTUnwrap(entries.values.first { $0.kind == .note })
        entries[note.path]?.modified = Date()
        start = CACurrentMediaTime()
        let one = SpotlightIndex.plan(SpotlightIndex.Snapshot(entries: entries, hidden: [], locations: [location]), donated: outcome.record.items)
        print(String(format: "plan with one note changed: %d changed in %.0f ms", one.changed.count, since(start)))
        XCTAssertEqual(one.changed.count, 1)
    }
}
