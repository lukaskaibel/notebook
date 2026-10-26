import AppKit
import XCTest
@testable import NotebookKit

/// A note still in iCloud opens at once: its title shows, its text comes when iCloud has brought it down, and until
/// then nothing is typed or saved. The debug delay stands in for iCloud, which tests can't make wait.
@MainActor
final class NoteLoadingTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-loading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        FileLoading.debugDelay = nil
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func onDisk(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Runs the main queue until `condition` holds, for at most `timeout` seconds.
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: - The note

    func testANoteOnThisDeviceIsReadAtOnce() throws {
        let url = try write("one\ntwo\n", to: "Here.md")
        let note = NoteDocument(url: url)
        XCTAssertTrue(note.isLoaded)
        XCTAssertNil(note.pending)
        XCTAssertEqual(note.text, "one\ntwo\n")
        XCTAssertNil(NoteDocument.wait(for: url), "a file outside iCloud never waits")
        note.close()
    }

    func testOpeningDoesNotWaitAndNothingIsSavedBeforeTheTextIsIn() throws {
        let url = try write("one\ntwo\n", to: "Cloud.md")
        FileLoading.debugDelay = 1
        let start = Date()
        let note = NoteDocument(url: url)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "the read happens off the main thread")
        XCTAssertFalse(note.isLoaded)
        XCTAssertEqual(note.pending, .reading)
        XCTAssertEqual(note.text, "")
        var loaded: [String] = []
        note.onLoad = { loaded.append($0) }

        // Whatever happens before the text is in, the file is left as it is.
        note.update(text: "typed into nothing")
        note.saveNow()
        XCTAssertFalse(note.hasUnsavedChanges)
        XCTAssertEqual(try onDisk(url), "one\ntwo\n")

        waitUntil { note.isLoaded }
        XCTAssertEqual(loaded, ["one\ntwo\n"])
        XCTAssertEqual(note.text, "one\ntwo\n")
        XCTAssertNotNil(note.modified)

        // From then on it is a note like any other.
        note.update(text: "one\ntwo\nthree\n")
        note.saveNow()
        waitUntil { (try? self.onDisk(url)) == "one\ntwo\nthree\n" }
        XCTAssertEqual(try onDisk(url), "one\ntwo\nthree\n")
        note.close()
    }

    func testANoteClosedBeforeItsTextCameIsLeftAlone() throws {
        let url = try write("kept\n", to: "Left.md")
        FileLoading.debugDelay = 0.3
        let note = NoteDocument(url: url)
        var loaded = false
        note.onLoad = { _ in loaded = true }
        note.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(loaded)
        XCTAssertFalse(note.isLoaded)
        XCTAssertEqual(try onDisk(url), "kept\n")
    }

    func testAChangeWhileReadingIsTakenIn() throws {
        let url = try write("old\n", to: "Changing.md")
        FileLoading.debugDelay = 0.3
        let note = NoteDocument(url: url)
        // Another device saves while this one is still reading: in a coordinated write, as iCloud does.
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
                try? Data("new\n".utf8).write(to: url, options: .atomic)
            }
        }
        waitUntil { note.text == "new\n" }
        XCTAssertTrue(note.isLoaded)
        XCTAssertEqual(note.text, "new\n")
        XCTAssertFalse(note.hasUnsavedChanges)
        note.close()
    }

    // MARK: - The editor and Back and Forward

    /// A workspace on the folder (for this run only), its editor in a window as on screen.
    private func makeWorkspace() -> (Workspace, NSWindow) {
        _ = NSApplication.shared
        UserDefaults.standard.set(folder.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        workspace.editor.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = workspace.editor.scrollView
        return (workspace, window)
    }

    func testTheTitleShowsAtOnceAndNothingCanBeTypedUntilTheTextComes() throws {
        let url = try write("# Kyoto\nFlights booked\n", to: "Trip.md")
        let (workspace, window) = makeWorkspace()
        defer { window.orderOut(nil) }
        FileLoading.debugDelay = 0.5
        workspace.open(url)
        let editor = workspace.editor
        XCTAssertEqual(workspace.currentURL, url.standardizedFileURL)
        XCTAssertEqual(editor.titleText, "Trip")
        XCTAssertEqual(editor.text, "")
        XCTAssertTrue(editor.isWaitingForText)
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertFalse(editor.textView.titleField.isEditable)

        editor.insert("lost")
        XCTAssertEqual(editor.text, "", "nothing is typed into a note whose text hasn't come")

        waitUntil { editor.text == "# Kyoto\nFlights booked\n" }
        XCTAssertFalse(editor.isWaitingForText)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertTrue(editor.textView.titleField.isEditable)
        XCTAssertEqual(editor.titleText, "Trip")
        XCTAssertEqual(workspace.outline.map(\.title), ["Kyoto"])

        editor.insert("Typed. ")
        workspace.saveAll()
        waitUntil { (try? self.onDisk(url)) == "Typed. # Kyoto\nFlights booked\n" }
        XCTAssertEqual(try onDisk(url), "Typed. # Kyoto\nFlights booked\n")
    }

    func testLeavingANoteBeforeItsTextCameWritesNothing() throws {
        let url = try write("kept\n", to: "Slow.md")
        let other = try write("other\n", to: "Other.md")
        let (workspace, window) = makeWorkspace()
        defer { window.orderOut(nil) }
        FileLoading.debugDelay = 0.3
        workspace.open(url)
        FileLoading.debugDelay = nil
        workspace.open(other)
        XCTAssertEqual(workspace.editor.text, "other\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(workspace.editor.text, "other\n", "the text that came late stays out of the note on screen")
        XCTAssertEqual(try onDisk(url), "kept\n")
        XCTAssertEqual(try onDisk(other), "other\n")
    }

    func testBackComesToTheSamePlaceOnceTheTextIsIn() throws {
        let long = (1...200).map { "Line \($0) of a long note" }.joined(separator: "\n")
        let first = try write(long, to: "Long.md")
        let second = try write("short\n", to: "Short.md")
        let (workspace, window) = makeWorkspace()
        defer { window.orderOut(nil) }
        let editor = workspace.editor
        workspace.open(first)
        let place = NSRange(location: (long as NSString).range(of: "Line 150").location, length: 0)
        editor.restore(EditorController.Place(top: 2000, selection: place))
        workspace.open(second)

        // Back to a note whose text takes a while, and on before it came: the place is kept, not taken from the
        // empty note.
        FileLoading.debugDelay = 0.3
        workspace.goBack()
        XCTAssertTrue(editor.isWaitingForText)
        workspace.goForward()
        waitUntil { !editor.isWaitingForText }
        workspace.goBack()
        XCTAssertTrue(editor.isWaitingForText)
        waitUntil { editor.text == long }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(editor.selection, place)
        XCTAssertGreaterThan(editor.scrollTop, 1000)
    }
}
