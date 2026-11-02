import XCTest
@testable import NotebookKit

/// A note must never lose a change made elsewhere: edits in different places merge, edits in the same place ask, or,
/// once the note was left, keep both. It is saved off the main thread, and nothing it does there waits for the main
/// thread, so the window never waits for the disk, and quitting can wait for the note.
@MainActor
final class NoteDocumentTests: XCTestCase {
    private var folders: [URL] = []
    /// Notes left that couldn't be written, as the app is told about them.
    private var told: [UnsavedNote] = []
    private var unsavedFolder: URL!

    override func setUp() async throws {
        unsavedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-unsaved-\(UUID().uuidString)")
        folders.append(unsavedFolder)
        UnsavedNotes.keep(in: unsavedFolder)
        NoteDocument.retryDelays = [0.2, 0.3]
        NoteDocument.onUnsaved = { [weak self] in self?.told.append($0) }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookSlowWrites")
        await NoteDocument.allWritten()
        NoteDocument.onUnsaved = nil
        NoteDocument.onWrittenAfterAll = nil
        NoteDocument.mayBeEnded = false
        NoteDocument.retryDelays = [1, 3]
        for folder in folders {
            unlock(folder)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func makeNote(_ text: String) -> (NoteDocument, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-notes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let url = folder.appendingPathComponent("Note.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (NoteDocument(url: url), url)
    }

    private func onDisk(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// The notes next to the note, by name, with what they say.
    private func copies(of url: URL) -> [String: String] {
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.filter { $0 != url.lastPathComponent && $0.hasSuffix(".md") }.map {
            ($0, onDisk(folder.appendingPathComponent($0)) ?? "")
        })
    }

    private func slow(writes seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "NotebookSlowWrites")
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Another device's version coming in, as iCloud puts it there: a coordinated write off the main thread, which
    /// holds the file for `holding` seconds first.
    private nonisolated static func writeElsewhere(_ text: String, to url: URL, holding: Double = 0) {
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
            if holding > 0 { Thread.sleep(forTimeInterval: holding) }
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    private func writeElsewhere(_ text: String, to url: URL) async {
        await Task.detached { Self.writeElsewhere(text, to: url) }.value
    }

    // MARK: - Merging and asking

    func testSaveMergesChangeMadeElsewhere() async throws {
        let (note, url) = makeNote("one\ntwo\nthree\n")
        note.update(text: "one, edited here\ntwo\nthree\n")
        try "one\ntwo\nthree\nfour, added elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        await note.saved()
        XCTAssertEqual(onDisk(url), "one, edited here\ntwo\nthree\nfour, added elsewhere\n")
        XCTAssertEqual(note.text, onDisk(url))
        XCTAssertNil(note.conflict)
        note.close()
    }

    func testSameLineChangedBothWaysAsks() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        await note.saved()
        try await until("asked") { note.conflict != nil }
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n", "nothing is written over")
        XCTAssertEqual(note.conflict?.otherText, "one theirs\ntwo\n")
        XCTAssertEqual(note.resolve(.keepBoth), "one mine\ntwo\n")
        await note.saved()
        XCTAssertEqual(onDisk(url), "one mine\ntwo\n")
        XCTAssertEqual(copies(of: url), ["Note (another device).md": "one theirs\ntwo\n"])
        note.close()
    }

    func testDiff3() {
        XCTAssertEqual(Diff3.merge(base: "a\nb\nc", mine: "A\nb\nc", theirs: "a\nb\nC"), "A\nb\nC")
        XCTAssertNil(Diff3.merge(base: "a\nb\nc", mine: "a\nB\nc", theirs: "a\nX\nc"))
    }

    // MARK: - Nothing waits

    /// A slow disk or iCloud: saving returns at once, what is typed meanwhile is saved after, and nothing is written on
    /// the main thread.
    func testSavingDoesNotHoldUpTheMainThread() async throws {
        let (note, url) = makeNote("one\n")
        let writesBefore = FileOperations.mainThreadWrites.withLock { $0 }
        slow(writes: 0.5)
        note.update(text: "one\ntwo\n")
        let start = Date()
        note.saveNow()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "saving waited")
        XCTAssertEqual(onDisk(url), "one\n")
        try await Task.sleep(for: .milliseconds(100))
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        XCTAssertTrue(note.hasUnsavedChanges)
        await note.saved()
        XCTAssertEqual(onDisk(url), "one\ntwo\nthree\n")
        XCTAssertFalse(note.hasUnsavedChanges)
        XCTAssertEqual(FileOperations.mainThreadWrites.withLock { $0 }, writesBefore, "written on the main thread")
        note.close()
    }

    /// Typed back to what was saved while a save of the change runs (a to-do ticked and unticked at once): that is
    /// saved after it too, and the file ends as the note does.
    func testTypingBackDuringASaveIsSavedToo() async throws {
        let (note, url) = makeNote("- [ ] one\n")
        slow(writes: 0.4)
        note.update(text: "- [x] one\n")
        note.saveNow()
        note.update(text: "- [ ] one\n")
        note.saveNow()
        await note.saved()
        XCTAssertEqual(onDisk(url), "- [ ] one\n")
        XCTAssertFalse(note.hasUnsavedChanges)
        note.close()
    }

    /// iCloud putting in another device's version holds the file: the save waits for it off the main thread, which
    /// goes on meanwhile, and then merges what came with what was typed.
    func testAWriterHoldingTheFileDoesNotHoldUpTheWindow() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        let holding = Task.detached { Self.writeElsewhere("one\ntwo\nthree, from the other device\n", to: url, holding: 1) }
        try await Task.sleep(for: .milliseconds(150))
        note.update(text: "one, typed here\ntwo\n")
        let start = Date()
        note.saveNow()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "saving waited for the other writer")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(note.hasUnsavedChanges, "written before the other writer let go")
        await holding.value
        try await until("merged and saved") { onDisk(url) == "one, typed here\ntwo\nthree, from the other device\n" && !note.hasUnsavedChanges }
        XCTAssertEqual(note.text, onDisk(url))
        XCTAssertNil(note.conflict)
        note.close()
    }

    /// Another version put in place with a replacing write, which tells everyone else the file is deleted: the note
    /// stays open, what was typed meanwhile waits, and then both are kept.
    func testAVersionPutInPlaceIsAChangeNotADeletion() async throws {
        let (note, url) = makeNote("one\ntwo\nthree\n")
        var deleted = false
        note.onDelete = { deleted = true }
        note.update(text: "one\ntwo\nthree, typed here\n")
        await writeElsewhere("one, from the other device\ntwo\nthree\n", to: url)
        note.saveNow()
        try await until("merged and saved") { onDisk(url) == "one, from the other device\ntwo\nthree, typed here\n" && !note.hasUnsavedChanges }
        XCTAssertEqual(note.text, onDisk(url))
        XCTAssertFalse(deleted, "closed as if deleted")
        note.close()
    }

    /// Opening a note again while what was typed in it last is still being written doesn't wait for the write on the
    /// main thread: its text comes when it is written.
    func testOpeningANoteWhileItIsWrittenDoesNotWait() async throws {
        let (note, url) = makeNote("one\n")
        slow(writes: 0.5)
        note.update(text: "one\ntwo\n")
        note.close()
        let start = Date()
        let again = NoteDocument(url: url)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "opening waited for the write")
        XCTAssertEqual(again.pending, .reading)
        try await until("its text") { again.isLoaded }
        XCTAssertEqual(again.text, "one\ntwo\n")
        again.close()
    }

    /// Another app (or Notebook's own link and to-do rewrites) reading or changing the file gets what was typed first.
    func testAnotherWriterGetsWhatWasTyped() async throws {
        let (note, url) = makeNote("one\n")
        note.update(text: "one\ntyped\n")
        let written = await Task.detached { FileOperations.rewrite(url) { $0 + "added\n" } }.value
        XCTAssertEqual(written, "one\ntyped\nadded\n")
        try await until("taken in") { note.text == "one\ntyped\nadded\n" }
        XCTAssertFalse(note.hasUnsavedChanges)
        note.close()
    }

    // MARK: - The same note twice

    /// The note open in the main window and in a window of its own: each save is a change to the other, never a
    /// deletion, so neither window closes or drops what was typed in it.
    func testTwoNotesOnOneFileHearEachOther() async throws {
        let (first, url) = makeNote("one\ntwo\n")
        let second = NoteDocument(url: url)
        var deleted: [String] = []
        first.onDelete = { deleted.append("first") }
        second.onDelete = { deleted.append("second") }
        var shown: [String] = []
        second.onExternalChange = { shown.append($0) }

        first.update(text: "one, in the first\ntwo\n")
        first.saveNow()
        await first.saved()
        try await until("the second took it in") { second.text == "one, in the first\ntwo\n" }
        XCTAssertEqual(shown, ["one, in the first\ntwo\n"])

        second.update(text: second.text + "three, in the second\n")
        second.saveNow()
        await second.saved()
        try await until("the first took it in") { first.text == "one, in the first\ntwo\nthree, in the second\n" }
        XCTAssertEqual(onDisk(url), first.text)
        XCTAssertEqual(deleted, [])
        XCTAssertNil(first.conflict)
        XCTAssertNil(second.conflict)
        first.close()
        second.close()
    }

    /// Typing in both at once, in different lines, with a slow disk: both are kept, in both and on disk.
    func testTypingInBothAtOnceKeepsBoth() async throws {
        let (first, url) = makeNote("one\ntwo\nthree\n")
        let second = NoteDocument(url: url)
        var deleted = false
        first.onDelete = { deleted = true }
        second.onDelete = { deleted = true }
        slow(writes: 0.3)
        first.update(text: "one, in the first\ntwo\nthree\n")
        second.update(text: "one\ntwo\nthree, in the second\n")
        first.saveNow()
        second.saveNow()
        let both = "one, in the first\ntwo\nthree, in the second\n"
        try await until("both kept", seconds: 8) { first.text == both && second.text == both && onDisk(url) == both }
        await first.saved()
        await second.saved()
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertFalse(second.hasUnsavedChanges)
        XCTAssertFalse(deleted)
        first.close()
        second.close()
    }

    // MARK: - Quitting

    /// A note left a moment before quitting is still being written: quitting waits for it.
    func testQuittingWaitsForANoteLeftWhileItIsWritten() async throws {
        let (note, url) = makeNote("one\n")
        slow(writes: 0.4)
        note.update(text: "one\ntyped just before leaving\n")
        note.close()
        XCTAssertTrue(NoteDocument.isWriting)
        var quit = false
        NoteDocument.whenAllWritten { quit = true }
        XCTAssertFalse(quit)
        try await until("quit") { quit }
        XCTAssertEqual(onDisk(url), "one\ntyped just before leaving\n")
    }

    /// Quitting leaves the note in the main window and in its own window, both with typing not yet written, on a slow
    /// disk: the app quits, with both kept.
    func testQuittingWithTheNoteOpenTwiceKeepsBothAndQuits() async throws {
        let (first, url) = makeNote("one\ntwo\nthree\n")
        let second = NoteDocument(url: url)
        var deleted = false
        first.onDelete = { deleted = true }
        second.onDelete = { deleted = true }
        first.update(text: "one, in the first\ntwo\nthree\n")
        second.update(text: "one\ntwo\nthree, in the second\n")
        slow(writes: 0.3)
        first.close()
        second.close()
        var quit = false
        NoteDocument.whenAllWritten { quit = true }
        try await until("quit", seconds: 8) { quit }
        XCTAssertEqual(onDisk(url), "one, in the first\ntwo\nthree, in the second\n")
        XCTAssertEqual(copies(of: url), [:])
        XCTAssertFalse(deleted)
    }

    // MARK: - A conflict met once the note was left (#137)

    /// Left with typing not yet written, while another device changed the same line: both are kept without asking.
    /// What was typed here goes into a copy next to the note, named after this device; the note keeps the other.
    func testANoteLeftThatMeetsAConflictKeepsBoth() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.close()
        XCTAssertNil(note.conflict)
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n")
        let copies = copies(of: url)
        XCTAssertEqual(Array(copies.values), ["one mine\ntwo\n"])
        XCTAssertTrue(copies.keys.first?.hasPrefix("Note (") == true, "\(copies.keys)")
        XCTAssertNil(note.conflict)
    }

    /// A conflict still asked about as the note is left (the app quits with the alert up): kept both the same way.
    func testAConflictNotAnsweredKeepsBothAsTheNoteIsLeft() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        await writeElsewhere("one theirs\ntwo\n", to: url)
        try await until("asked") { note.conflict != nil }
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n")
        XCTAssertEqual(Array(copies(of: url).values), ["one mine\ntwo\n"])
    }

    /// The note open twice, both with typing on the line another device changed, both left at once (the app quits): a
    /// copy each, neither written over the other.
    func testTwoNotesLeftAtOnceKeepACopyEach() async throws {
        let (first, url) = makeNote("one\ntwo\n")
        let second = NoteDocument(url: url)
        first.update(text: "one, in the first\ntwo\n")
        second.update(text: "one, in the second\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        first.close()
        second.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n")
        XCTAssertEqual(Set(copies(of: url).values), ["one, in the first\ntwo\n", "one, in the second\ntwo\n"])
    }

    /// Asked about a conflict, then put in the Trash elsewhere, then left: the copy goes where the note was, not after it
    /// into the Trash.
    func testAConflictLeftAfterTheNoteWentToTheTrashKeepsTheCopyWhereItWas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let url = folder.appendingPathComponent("Trashed \(UUID().uuidString.prefix(8)).md")
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        let note = NoteDocument(url: url)
        var deleted = false
        note.onDelete = { deleted = true }
        note.update(text: "one mine\ntwo\n")
        await writeElsewhere("one theirs\ntwo\n", to: url)
        try await until("asked") { note.conflict != nil }
        let trashed = await Task.detached { FileOperations.moveToTrash(url) }.value
        let place = try XCTUnwrap(trashed.place)
        let trash = place.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: place)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] where name.hasPrefix(base + " (") {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }
        try await until("told it went") { deleted }
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(Array(copies(of: url).values), ["one mine\ntwo\n"])
        let inTrash = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).filter { $0.hasPrefix(base + " (") }
        XCTAssertEqual(inTrash, [], "a copy went into the Trash")
    }

    /// Copies of one note made at the same moment each take a name of their own.
    func testCopiesMadeAtOnceTakeANameEach() throws {
        let (note, url) = makeNote("")
        note.close()
        let folder = url.deletingLastPathComponent()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            _ = FileOperations.createNoteWithoutOverwriting(in: folder, title: "Note (Mac)", text: "copy \(index)")
        }
        XCTAssertEqual(Set(copies(of: url).values), Set((0..<8).map { "copy \($0)" }))
    }

    /// Deleted elsewhere while a conflict was still asked about, then left: what was typed is kept as a copy where the
    /// note was, not dropped.
    func testAConflictLeftAfterTheNoteWasDeletedKeepsTheCopy() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        var deleted = false
        note.onDelete = { deleted = true }
        note.update(text: "one mine\ntwo\n")
        await writeElsewhere("one theirs\ntwo\n", to: url)
        try await until("asked") { note.conflict != nil }
        await Task.detached {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }.value
        try await until("told it went") { deleted }
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(Array(copies(of: url).values), ["one mine\ntwo\n"])
    }

    /// Left with nothing typed that wasn't written: no copy.
    func testANoteLeftWithNothingNewMakesNoCopy() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        note.saveNow()
        await note.saved()
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n")
        XCTAssertEqual(copies(of: url), [:])
    }

    // MARK: - Deleted, trashed, moved

    /// Deleted elsewhere while typing went on here: the note isn't written there again.
    func testANoteDeletedElsewhereIsNotWrittenAgain() async throws {
        let (note, url) = makeNote("one\n")
        var deleted = false
        note.onDelete = { deleted = true }
        note.update(text: "one\ntwo\n")
        await Task.detached {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }.value
        try await until("told") { deleted }
        note.close()
        await NoteDocument.allWritten()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "written again")
    }

    /// Put in the Trash by another app (or Notebook's sidebar), with coordination: the file is moved into the Trash, and
    /// the note hears of that move, but it went all the same. The note's own window closes, as in 1.0, and what is typed
    /// in it is never written into the Trash or back where it was.
    func testANoteTrashedElsewhereIsGoneNotReplaced() async throws {
        let (note, url) = makeNote("one\n")
        var deleted = false
        note.onDelete = { deleted = true }
        note.update(text: "one\ntwo\n")
        let trashed = await Task.detached { FileOperations.moveToTrash(url) }.value
        XCTAssertTrue(trashed.done)
        defer { trashed.place.map { try? FileManager.default.removeItem(at: $0) } }
        try await until("told it went") { deleted }
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(trashed.place.flatMap(onDisk), "one\n", "written into the Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "written back")
    }

    /// Replaces the file with one that can't be read, as another app saving it would.
    private func replaceWithUnreadable(_ text: String, at url: URL) async {
        await Task.detached {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
                try? Data(text.utf8).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
            }
        }.value
    }

    private func makeReadable(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// The note open twice, renamed by its case only ("groceries" to "Groceries"), as from the sidebar: the rename's
    /// write is a deletion notice to the other note, as the disk takes both names for one file. That note stays open,
    /// and what is typed in it meanwhile is written under the new name.
    func testACaseOnlyRenameKeepsTheOtherNoteOpen() async throws {
        let (first, old) = makeNote("one\n")
        let second = NoteDocument(url: old)
        var deleted = false
        first.onDelete = { deleted = true }
        second.onDelete = { deleted = true }
        slow(writes: 0.3)
        let documents = await NoteDocument.beginMoving(old)
        second.update(text: "one\ntyped during the rename\n")
        let renamed = await Task.detached { FileOperations.rename(old, to: "note", presenter: first) }.value
        let new = try XCTUnwrap(renamed)
        XCTAssertEqual(new.lastPathComponent, "note.md")
        NoteDocument.endMoving(documents, from: old, to: new)
        try await Task.sleep(for: .milliseconds(1500))
        await NoteDocument.allWritten()
        XCTAssertFalse(deleted, "closed as if deleted")
        XCTAssertEqual(onDisk(new), "one\ntyped during the rename\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: new.deletingLastPathComponent().path).filter { $0.hasSuffix(".md") }, ["note.md"])
        first.close()
        second.close()
    }

    /// A file replaced by one that can't be read: still there, so no deletion, and not written over while it can't be
    /// read to see what it says. Once it can, saving goes on.
    func testAnUnreadableFileIsNotWrittenOver() async throws {
        let (note, url) = makeNote("one\n")
        var deleted = false
        note.onDelete = { deleted = true }
        await replaceWithUnreadable("one\n", at: url)
        defer { makeReadable(url) }
        try await Task.sleep(for: .milliseconds(300))
        await note.saved()
        XCTAssertFalse(deleted)
        note.update(text: "one\ntwo\n")
        note.saveNow()
        await note.saved()
        makeReadable(url)
        XCTAssertEqual(onDisk(url), "one\n", "written over unseen")
        XCTAssertTrue(note.hasUnsavedChanges)
        note.saveNow()
        await note.saved()
        XCTAssertEqual(onDisk(url), "one\ntwo\n")
        note.close()
    }

    /// Left while its file can't be read: what was typed is kept as a copy, and the file stays as it is.
    func testANoteLeftWhileItsFileCantBeReadKeepsACopy() async throws {
        let (note, url) = makeNote("one\n")
        await replaceWithUnreadable("theirs\n", at: url)
        defer { makeReadable(url) }
        try await Task.sleep(for: .milliseconds(300))
        await note.saved()
        note.update(text: "one\nmine\n")
        note.close()
        await NoteDocument.allWritten()
        makeReadable(url)
        XCTAssertEqual(onDisk(url), "theirs\n")
        XCTAssertEqual(Array(copies(of: url).values), ["one\nmine\n"])
    }

    // MARK: - A note that can't be written (#165)

    /// Makes `folder` one that can't be written in, as on a read-only disk or in a folder Notebook may no longer write
    /// to: a note there can't be saved, as it is written next to itself first and then put in place.
    private func lock(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    }

    private func unlock(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    /// The notes kept in Notebook's folder, by name, with what they say.
    private func kept() -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: unsavedFolder.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, onDisk(unsavedFolder.appendingPathComponent($0)) ?? "") })
    }

    /// Left as its folder can't be written for a moment: the note stays among those being written, quitting waits for
    /// it, and it is written when tried again. Nothing is kept elsewhere, and nothing is said.
    func testANoteLeftThatCantBeWrittenIsTriedAgain() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        note.update(text: "one\ntyped as the disk filled up\n")
        note.close()
        try await until("failed") { note.failedWrites == 1 }
        XCTAssertTrue(NoteDocument.isWriting)
        unlock(folder)
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one\ntyped as the disk filled up\n")
        XCTAssertEqual(note.failedWrites, 0)
        XCTAssertTrue(told.isEmpty)
        XCTAssertEqual(kept(), [:])
    }

    /// Left, and still not written when tried again: what was typed is kept as a note in Notebook's folder, named after
    /// it, the app is told where and why, and only then does quitting go on. The note stays as it was last saved.
    func testANoteLeftThatStillCantBeWrittenIsKeptInNotebooksFolder() async throws {
        let (note, url) = makeNote("one\n")
        lock(url.deletingLastPathComponent())
        note.update(text: "one\ntyped on a read-only disk\n")
        note.close()
        var events: [String] = []
        NoteDocument.onUnsaved = { [weak self] in
            self?.told.append($0)
            events.append("told")
        }
        NoteDocument.whenAllWritten { events.append("quit") }
        try await until("quit") { events.contains("quit") }
        XCTAssertEqual(events, ["told", "quit"])
        XCTAssertEqual(note.failedWrites, 3, "written once and tried twice more")
        XCTAssertEqual(kept(), ["Note.md": "one\ntyped on a read-only disk\n"])
        let unsaved = try XCTUnwrap(told.first)
        XCTAssertEqual(unsaved.copy?.lastPathComponent, "Note.md")
        XCTAssertEqual(unsaved.name, "Note")
        XCTAssertNotNil(unsaved.reason)
        XCTAssertEqual(onDisk(url), "one\n")
    }

    /// Two notes of the same name kept: neither copy is written over.
    func testNotesKeptInNotebooksFolderTakeANameEach() async throws {
        let (first, url) = makeNote("one\n")
        let (second, other) = makeNote("two\n")
        lock(url.deletingLastPathComponent())
        lock(other.deletingLastPathComponent())
        first.update(text: "one, typed\n")
        second.update(text: "two, typed\n")
        first.close()
        second.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(Set(kept().keys), ["Note.md", "Note 2.md"])
        XCTAssertEqual(Set(kept().values), ["one, typed\n", "two, typed\n"])
        XCTAssertEqual(told.count, 2)
    }

    /// Not written, and Notebook's folder can't be written either: the app is asked, with what was typed, and the note
    /// waits for the answer, quitting with it. Try Again tries all of it again: asked again while it still fails, then
    /// written once the folder can be written.
    func testANoteThatCantBeWrittenNorKeptWaitsForAnAnswer() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        lock(unsavedFolder)
        note.update(text: "one\ntyped with a full disk\n")
        note.close()
        try await until("asked") { told.count == 1 }
        XCTAssertNil(told[0].copy)
        XCTAssertEqual(told[0].text, "one\ntyped with a full disk\n")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(NoteDocument.isWriting, "quitting goes on without it")
        told[0].tryAgain()
        try await until("asked again") { told.count == 2 }
        XCTAssertTrue(NoteDocument.isWriting)
        unlock(folder)
        told[1].tryAgain()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one\ntyped with a full disk\n")
        XCTAssertEqual(told.count, 2)
        XCTAssertEqual(kept(), [:])
    }

    /// Asked, and the text went elsewhere (Copy Text): the note is let go, as it was last saved.
    func testANoteNotKeptIsLetGoOnceAnswered() async throws {
        let (note, url) = makeNote("one\n")
        lock(url.deletingLastPathComponent())
        lock(unsavedFolder)
        note.update(text: "one\ntyped\n")
        note.close()
        try await until("asked") { told.count == 1 }
        told[0].letGo()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one\n")
        XCTAssertEqual(told.count, 1)
    }

    /// Left with a conflict, in a folder that can't be written: the copy that keeps both can't go next to the note, so
    /// it goes into Notebook's folder. The note keeps the other device's text.
    func testAConflictCopyThatCantBeWrittenIsKeptInNotebooksFolder() async throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        lock(url.deletingLastPathComponent())
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one theirs\ntwo\n")
        XCTAssertEqual(copies(of: url), [:])
        XCTAssertEqual(kept(), ["Note.md": "one mine\ntwo\n"])
        XCTAssertEqual(told.count, 1)
    }

    /// A note still open that can't be written is tried again by itself, without more typing, and written once it can.
    func testAnOpenNoteThatCantBeWrittenIsTriedAgain() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        note.update(text: "one\ntwo\n")
        note.saveNow()
        try await until("failed") { note.failedWrites == 1 }
        unlock(folder)
        try await until("written") { onDisk(url) == "one\ntwo\n" }
        XCTAssertTrue(told.isEmpty)
        note.close()
    }

    /// A note still open keeps what was typed on screen once trying again is over: nothing is kept elsewhere, and
    /// quitting doesn't wait for it, until it is left. Then it is kept at once, without trying again for as long.
    func testAnOpenNoteThatCantBeWrittenIsKeptOnceLeft() async throws {
        let (note, url) = makeNote("one\n")
        lock(url.deletingLastPathComponent())
        note.update(text: "one\ntwo\n")
        note.saveNow()
        try await until("tried again") { note.failedWrites == 3 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(NoteDocument.isWriting)
        XCTAssertTrue(told.isEmpty)
        XCTAssertEqual(kept(), [:])
        note.update(text: "one\ntwo\nthree\n")
        note.close()
        try await until("kept") { told.count == 1 }
        XCTAssertEqual(note.failedWrites, 4, "tried again after it was left")
        await NoteDocument.allWritten()
        XCTAssertEqual(kept(), ["Note.md": "one\ntwo\nthree\n"])
        XCTAssertEqual(onDisk(url), "one\n")
    }

    // MARK: - Out of sight on iPhone and iPad (#273)

    /// Switching apps with a note open that can't be written: iOS may end Notebook once it is suspended, or you may swipe
    /// it away, before trying again is over. So what was typed is kept in Notebook's folder after the first failed write,
    /// once, and only for the next launch to say; trying again goes on, and the note stays as it was last saved.
    func testAnOpenNoteThatCantBeWrittenOutOfSightIsKeptAtOnce() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        NoteDocument.mayBeEnded = true
        note.update(text: "one\ntyped, then switched apps\n")
        note.saveNow()
        try await until("kept") { told.count == 1 }
        XCTAssertEqual(note.failedWrites, 1, "kept before it is tried again")
        XCTAssertTrue(told[0].mayStillBeWritten)
        XCTAssertEqual(told[0].copy?.lastPathComponent, "Note.md")
        XCTAssertNotNil(told[0].reason)
        XCTAssertEqual(kept(), ["Note.md": "one\ntyped, then switched apps\n"])
        XCTAssertTrue(NoteDocument.isWriting, "tried again")
        await NoteDocument.allWritten()
        XCTAssertEqual(note.failedWrites, 3)
        XCTAssertEqual(told.count, 1, "kept once")
        XCTAssertEqual(kept(), ["Note.md": "one\ntyped, then switched apps\n"])
        XCTAssertEqual(onDisk(url), "one\n")
        unlock(folder)
        note.close()
    }

    /// The usual way on the iPhone: typing in a note that can't be written, which says nothing while it is open, then
    /// switching apps. As Notebook goes out of sight its save fails again, and what was typed is kept then.
    func testANoteTriedAgainInFrontIsKeptAsNotebookGoesOutOfSight() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        note.update(text: "one\ntwo\n")
        note.saveNow()
        await NoteDocument.allWritten()
        XCTAssertEqual(note.failedWrites, 3)
        XCTAssertTrue(told.isEmpty)
        NoteDocument.mayBeEnded = true
        // What `Workspace.saveAll` does.
        note.saveNow()
        try await until("kept") { told.count == 1 }
        XCTAssertEqual(kept(), ["Note.md": "one\ntwo\n"])
        XCTAssertFalse(NoteDocument.isWriting, "Notebook can be suspended")
        unlock(folder)
        note.close()
    }

    /// Back in front, more is typed, and out of sight again the note still can't be written: the copy is written over,
    /// not a second one made. Once the note is written, the copy goes again, and the app hears so: nothing is said about
    /// it at the next launch.
    func testACopyKeptOutOfSightFollowsTheNoteAndGoesOnceItIsWritten() async throws {
        var writtenAfterAll: [URL] = []
        NoteDocument.onWrittenAfterAll = { writtenAfterAll.append($0) }
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        NoteDocument.mayBeEnded = true
        note.update(text: "one\ntwo\n")
        note.saveNow()
        await NoteDocument.allWritten()
        NoteDocument.mayBeEnded = false
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        await NoteDocument.allWritten()
        XCTAssertEqual(told.count, 1, "nothing more kept in front")
        NoteDocument.mayBeEnded = true
        note.saveNow()
        try await until("kept again") { told.count == 2 }
        XCTAssertEqual(told[1].copy, told[0].copy)
        XCTAssertTrue(told[1].mayStillBeWritten)
        XCTAssertEqual(kept(), ["Note.md": "one\ntwo\nthree\n"])
        NoteDocument.mayBeEnded = false
        unlock(folder)
        note.saveNow()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one\ntwo\nthree\n")
        XCTAssertEqual(kept(), [:])
        XCTAssertEqual(writtenAfterAll, told[0].copy.map { [$0] })
        note.close()
    }

    /// Kept out of sight, then left in front while it still can't be written: once trying again is over, the copy is
    /// written over with what was typed since, and said now.
    func testACopyKeptOutOfSightIsKeptOverAndSaidOnceTheNoteIsLeft() async throws {
        let (note, url) = makeNote("one\n")
        lock(url.deletingLastPathComponent())
        NoteDocument.mayBeEnded = true
        note.update(text: "one\ntwo\n")
        note.saveNow()
        try await until("kept") { told.count == 1 }
        NoteDocument.mayBeEnded = false
        note.update(text: "one\ntwo\nthree\n")
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(told.count, 2)
        XCTAssertFalse(told[1].mayStillBeWritten)
        XCTAssertEqual(told[1].copy, told[0].copy)
        XCTAssertEqual(kept(), ["Note.md": "one\ntwo\nthree\n"])
        XCTAssertEqual(onDisk(url), "one\n")
    }

    /// Left as Notebook goes out of sight: kept at once all the same, and said once trying again is over, as one copy.
    func testANoteLeftOutOfSightIsKeptAtOnceAndSaidOnceTriedAgain() async throws {
        let (note, url) = makeNote("one\n")
        lock(url.deletingLastPathComponent())
        NoteDocument.mayBeEnded = true
        note.update(text: "one\ntwo\n")
        note.close()
        try await until("kept") { told.count == 1 }
        XCTAssertTrue(told[0].mayStillBeWritten)
        XCTAssertEqual(note.failedWrites, 1)
        await NoteDocument.allWritten()
        XCTAssertEqual(told.count, 2)
        XCTAssertFalse(told[1].mayStillBeWritten)
        XCTAssertEqual(told[1].copy, told[0].copy)
        XCTAssertEqual(kept(), ["Note.md": "one\ntwo\n"])
    }

    /// A copy changed in Notebook's folder since it was kept, as in the Files app, is someone's own now: what is typed
    /// after it goes into a new one, and it stays when the note is written.
    func testACopyChangedInNotebooksFolderIsLeftAlone() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        lock(folder)
        NoteDocument.mayBeEnded = true
        note.update(text: "one\ntwo\n")
        note.saveNow()
        await NoteDocument.allWritten()
        try "changed in Files\n".write(to: unsavedFolder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        await NoteDocument.allWritten()
        XCTAssertEqual(kept(), ["Note.md": "changed in Files\n", "Note 2.md": "one\ntwo\nthree\n"])
        NoteDocument.mayBeEnded = false
        unlock(folder)
        note.close()
        await NoteDocument.allWritten()
        XCTAssertEqual(onDisk(url), "one\ntwo\nthree\n")
        XCTAssertEqual(kept(), ["Note.md": "changed in Files\n"])
    }

    /// A note left while it is still written, then put in the Trash: what was typed goes along, and the note doesn't
    /// come back where it was.
    func testANoteLeftWhileItIsWrittenGoesToTheTrashWithWhatWasTyped() async throws {
        let (note, url) = makeNote("one\n")
        slow(writes: 0.4)
        note.update(text: "one\ntyped\n")
        note.close()
        await NoteDocument.save(atOrInside: url.deletingLastPathComponent())
        UserDefaults.standard.removeObject(forKey: "NotebookSlowWrites")
        let trashed = await Task.detached { FileOperations.moveToTrash(url) }.value
        XCTAssertTrue(trashed.done)
        defer { trashed.place.map { try? FileManager.default.removeItem(at: $0) } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "came back")
        XCTAssertEqual(trashed.place.flatMap(onDisk), "one\ntyped\n")
    }

    /// A note being written while its folder is renamed: what was typed is written under the old name first, what
    /// is typed during the rename under the new one, and nothing is left under the old name.
    func testWhatIsTypedDuringAMoveIsWrittenWhereTheNoteWent() async throws {
        let (note, url) = makeNote("one\n")
        let folder = url.deletingLastPathComponent()
        let renamed = folder.deletingLastPathComponent().appendingPathComponent("notebook-renamed-\(UUID().uuidString)")
        folders.append(renamed)
        slow(writes: 0.3)
        note.update(text: "one\ntwo\n")
        let documents = await NoteDocument.beginMoving(folder)
        XCTAssertEqual(documents, [note])
        XCTAssertEqual(onDisk(url), "one\ntwo\n", "written before the move")
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        let moved = await Task.detached { FileOperations.move(folder, to: renamed) }.value
        XCTAssertNotNil(moved)
        NoteDocument.endMoving(documents, from: folder, to: renamed)
        await note.saved()
        XCTAssertEqual(onDisk(renamed.appendingPathComponent("Note.md")), "one\ntwo\nthree\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "written again where it was")
        note.close()
    }

    // MARK: - Pictures nothing uses any more

    /// Pictures stay when a note next to them is still in iCloud: finding out whether it uses them would bring it down.
    func testPicturesStayWhileANoteThereIsInICloud() throws {
        let (note, url) = makeNote("No pictures.\n")
        note.close()
        let folder = url.deletingLastPathComponent()
        let assets = folder.appendingPathComponent(".assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([1]).write(to: assets.appendingPathComponent("photo.png"))
        try Data().write(to: folder.appendingPathComponent(".Other.md.icloud"))
        FileOperations.cleanUpAssets(in: folder, candidates: ["photo.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("photo.png").path))
    }

    /// A link whose case changed (Make Upper Case on the whole note) still uses its picture, which the Mac's disk finds
    /// whatever the case: it isn't thrown away as the note is left. One no note uses still goes.
    func testPicturesStayWhenTheirLinksChangeCase() throws {
        XCTAssertEqual(FileOperations.assetNames(in: "![](.ASSETS/PHOTO.PNG) [scan](.Assets/Scan%201.pdf)"), ["PHOTO.PNG", "Scan 1.pdf"])
        let (note, url) = makeNote("![](.ASSETS/PHOTO.PNG)\n")
        note.close()
        let assets = url.deletingLastPathComponent().appendingPathComponent(".assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for name in ["photo.png", "photo.drawing", "unused.png"] { try Data([1]).write(to: assets.appendingPathComponent(name)) }
        FileOperations.cleanUpAssets(in: url.deletingLastPathComponent(), candidates: ["photo.png", "unused.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("photo.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("photo.drawing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.appendingPathComponent("unused.png").path))
    }

    /// A note moved next to another picture of its picture's name takes its own along under a new name, and its link
    /// follows, whatever the link's case.
    func testAMovedNotesLinkInAnotherCaseFollowsItsRenamedPicture() throws {
        let (note, url) = makeNote("![](.ASSETS/photo.png)\n")
        note.close()
        let from = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: from.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try Data([1]).write(to: from.appendingPathComponent(".assets/photo.png"))
        let (other, there) = makeNote("")
        other.close()
        let target = there.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: target.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try Data([2]).write(to: target.appendingPathComponent(".assets/photo.png"))
        let moved = target.appendingPathComponent("Moved.md")
        try FileManager.default.moveItem(at: url, to: moved)
        let copied = FileOperations.copyAssets(of: moved, from: from)
        XCTAssertTrue(copied.renamed)
        XCTAssertEqual(onDisk(moved), "![](.ASSETS/photo%202.png)\n")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(".assets/photo 2.png")), Data([1]))
    }
}
