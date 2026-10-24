import XCTest
@testable import NotebookKit

/// A note must never lose a change made elsewhere: edits in different places merge, edits in the same place ask.
@MainActor
final class NoteDocumentTests: XCTestCase {
    private func makeNote(_ text: String) -> (NoteDocument, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-notes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Note.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (NoteDocument(url: url), url)
    }

    func testSaveMergesChangeMadeElsewhere() async throws {
        let (note, url) = makeNote("one\ntwo\nthree\n")
        note.update(text: "one, edited here\ntwo\nthree\n")
        try "one\ntwo\nthree\nfour, added elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        await note.save()
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(saved, "one, edited here\ntwo\nthree\nfour, added elsewhere\n")
        XCTAssertNil(note.conflict)
        note.close()
    }

    func testSameLineChangedBothWaysAsks() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        await note.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one theirs\ntwo\n", "nothing is written over")
        XCTAssertEqual(note.conflict?.otherText, "one theirs\ntwo\n")
        XCTAssertEqual(note.resolve(.keepBoth), "one mine\ntwo\n")
        await note.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one mine\ntwo\n")
        let copies = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(copies.contains { $0.hasPrefix("Note (") }, "\(copies)")
        note.close()
    }

    // MARK: - Saving off the main thread

    /// Each save waits this long off the main thread, as when iCloud holds the file.
    private func slowSaves(_ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "NotebookSlowWrites")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "NotebookSlowWrites") }
    }

    func testSavingDoesNotWaitAndWhatIsTypedMeanwhileIsSavedAfter() async throws {
        let (note, url) = makeNote("one\n")
        slowSaves(0.4)
        note.update(text: "one\ntwo\n")
        let start = Date()
        note.saveNow()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "saved off the main thread")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\n")
        // Typed on while it is being written: written after it, not raced.
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        await note.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\nthree\n")
        XCTAssertFalse(note.hasUnsavedChanges)
        note.close()
    }

    func testAChangeElsewhereWhileSavingIsMergedIn() async throws {
        let (note, url) = makeNote("one\ntwo\nthree\n")
        slowSaves(0.4)
        var shown: [String] = []
        note.onExternalChange = { shown.append($0) }
        note.update(text: "one, here\ntwo\nthree\n")
        note.saveNow()
        // Another app writes while the save waits, and more is typed here meanwhile.
        try "one\ntwo\nthree\nfour, elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        note.update(text: "one, here\ntwo, here too\nthree\n")
        await note.save()
        let both = "one, here\ntwo, here too\nthree\nfour, elsewhere\n"
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), both)
        XCTAssertEqual(note.text, both)
        XCTAssertEqual(shown.last, both, "the editor shows it")
        XCTAssertNil(note.conflict)
        note.close()
    }

    func testQuittingWaitsForASaveUnderWay() throws {
        let (note, url) = makeNote("one\n")
        slowSaves(0.3)
        note.update(text: "one\ntwo\n")
        note.saveNow()
        note.update(text: "one\ntwo\nthree\n")
        note.saveWaiting()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\nthree\n")
        XCTAssertFalse(note.hasUnsavedChanges)
        note.close()
    }

    /// Another app, or Notebook itself, reading the file to change it first has what was typed written.
    func testAnotherWriterGetsWhatWasTyped() async throws {
        let (note, url) = makeNote("one\n")
        note.update(text: "one\ntyped\n")
        let read = await Task.detached { () -> String? in
            var text: String?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: nil) { url in
                text = try? String(contentsOf: url, encoding: .utf8)
            }
            return text
        }.value
        XCTAssertEqual(read, "one\ntyped\n")
        note.close()
    }

    func testDiff3() {
        XCTAssertEqual(Diff3.merge(base: "a\nb\nc", mine: "A\nb\nc", theirs: "a\nb\nC"), "A\nb\nC")
        XCTAssertNil(Diff3.merge(base: "a\nb\nc", mine: "a\nB\nc", theirs: "a\nX\nc"))
    }
}
