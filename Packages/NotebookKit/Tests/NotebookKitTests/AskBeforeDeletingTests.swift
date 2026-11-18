import AppKit
import PDFKit
import PencilKit
import XCTest
@testable import NotebookKit

/// Deleting a note with something in it asks first, in a sheet here, and nothing happens until you answer. An empty note
/// goes right away, and so does every note once Settings say not to ask.
@MainActor
final class AskBeforeDeletingTests: XCTestCase {
    private var library: URL!
    private var papers: URL { library.appendingPathComponent("Papers") }
    private var trip: URL { papers.appendingPathComponent("Trip.md") }
    private var blank: URL { papers.appendingPathComponent("Blank.md") }
    private var spaces: URL { papers.appendingPathComponent("Spaces.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-ask-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "Five days in October.\n".write(to: trip, atomically: true, encoding: .utf8)
        try "".write(to: blank, atomically: true, encoding: .utf8)
        try "  \n\t\n\n".write(to: spaces, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        NotebookSettings.shared.asksBeforeDeletingNotes = true
        // Left in place, so that what a test opens stays what it opened.
        NotebookSettings.shared.deletesEmptyNotes = false
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "asksBeforeDeletingNotes", "deletesEmptyNewNotes"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotebookSettings.shared.asksBeforeDeletingNotes = true
        NotebookSettings.shared.deletesEmptyNotes = true
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        window?.close()
        // Written while the folder is still there: otherwise what a test typed is kept as an unsaved note, for the tests
        // after it to find.
        NoteDocument.documents(atOrInside: library).forEach { $0.close() }
        await NoteDocument.allWritten()
        try? FileManager.default.removeItem(at: library)
    }

    private func makeWorkspace() async throws -> (Workspace, UndoManager) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView!.addSubview(sidebar.scrollView)
        workspace.editor.view.frame = NSRect(x: 260, y: 0, width: 640, height: 600)
        window.contentView!.addSubview(workspace.editor.view)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        await withCheckedContinuation { done in workspace.readFolders(to: papers, including: true) { done.resume() } }
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private var sheetViews: [NSView] { window?.attachedSheet?.contentView.map(views) ?? [] }

    private var sheetTexts: [String] { sheetViews.compactMap { ($0 as? NSTextField)?.stringValue } }

    private func press(_ title: String) throws {
        let button = sheetViews.compactMap { $0 as? NSButton }.first { $0.title == title }
        try XCTUnwrap(button, "no \(title) in the sheet").performClick(nil)
    }

    private func waitForSheet() async throws {
        try await until("the question") { window?.attachedSheet != nil }
    }

    private func waitForNoSheet() async throws {
        try await until("the sheet went") { window?.attachedSheet == nil }
    }

    // MARK: - Asking

    func testANoteWithTextStaysUntilYouSaySo() async throws {
        let (workspace, manager) = try await makeWorkspace()
        workspace.trashAfterAsking(trip)
        try await waitForSheet()
        XCTAssertTrue(sheetTexts.contains("Move “Trip” to the Trash?"), "\(sheetTexts)")
        XCTAssertTrue(exists(trip))
        XCTAssertFalse(manager.canUndo, "nothing has happened yet")
        let buttons = sheetViews.compactMap { $0 as? NSButton }
        // AppKit gives a destructive button no Return, so a key pressed out of habit can't answer for you.
        XCTAssertEqual(buttons.first { $0.title == "Move to Trash" }?.keyEquivalent, "", "Return doesn't delete")
        XCTAssertEqual(buttons.first { $0.title == "Cancel" }?.keyEquivalent, "\u{1B}", "Escape cancels")

        try press("Cancel")
        try await waitForNoSheet()
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(exists(trip), "Cancel keeps it")
        XCTAssertFalse(manager.canUndo)

        workspace.trashAfterAsking(trip)
        try await waitForSheet()
        try press("Move to Trash")
        try await until("it went") { !exists(trip) }
        await workspace.changeFiles { _ in }.value
        try await until("the group closed") { manager.groupingLevel == 0 }
        XCTAssertEqual(manager.undoActionName, "Move to Trash")
        manager.undo()
        await workspace.changeFiles { _ in }.value
        try await until("it came back") { exists(trip) }
        XCTAssertNil(window?.attachedSheet, "Undo and what it brings back ask nothing")
    }

    func testAnEmptyNoteGoesWithoutAsking() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.trashAfterAsking(blank)
        try await until("the empty note went") { !exists(blank) }
        workspace.trashAfterAsking(spaces)
        try await until("the note of spaces went") { !exists(spaces) }
        XCTAssertNil(window?.attachedSheet)
    }

    func testSettingsTurnTheQuestionOff() async throws {
        NotebookSettings.shared.asksBeforeDeletingNotes = false
        let (workspace, _) = try await makeWorkspace()
        workspace.trashAfterAsking(trip)
        try await until("it went") { !exists(trip) }
        XCTAssertNil(window?.attachedSheet)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "asksBeforeDeletingNotes") as? Bool, false)
    }

    func testAskedTwiceItAsksOnce() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.trashAfterAsking(trip)
        workspace.trashAfterAsking(trip)
        try await waitForSheet()
        workspace.trashAfterAsking(trip)
        try press("Cancel")
        try await waitForNoSheet()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(window?.attachedSheet, "no second question behind the first")
        XCTAssertTrue(exists(trip))
    }

    /// What is in the open note counts as it is now, not as it was last saved.
    func testWhatWasJustTypedCounts() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(blank)
        try await until("the note was read") { workspace.note?.isLoaded == true }
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.insertText("A first line", replacementRange: NSRange(location: 0, length: 0))
        let asks = await workspace.asksBeforeTrashing(blank)
        XCTAssertTrue(asks, "typed and not saved yet")
    }

    func testWhatWasJustTakenOutCounts() async throws {
        let (workspace, _) = try await makeWorkspace()
        workspace.open(trip)
        try await until("the note was read") { workspace.note?.isLoaded == true }
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.insertText("", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        let asks = await workspace.asksBeforeTrashing(trip)
        XCTAssertFalse(asks, "emptied, with the text still in the file")
    }

    func testOtherFilesAndFoldersGoWithoutAsking() async throws {
        let picture = papers.appendingPathComponent("Photo.png")
        try Data([1, 2, 3]).write(to: picture)
        let (workspace, _) = try await makeWorkspace()
        XCTAssertFalse(workspace.mayAskBeforeTrashing(picture))
        XCTAssertFalse(workspace.mayAskBeforeTrashing(papers, isFolder: true))
        workspace.trashAfterAsking(picture)
        try await until("the picture went") { !exists(picture) }
        XCTAssertNil(window?.attachedSheet)
    }

    // MARK: - What counts as something

    func testWhatIsInATypedNote() throws {
        XCTAssertTrue(NoteContents.hasContent(trip))
        XCTAssertFalse(NoteContents.hasContent(blank))
        XCTAssertFalse(NoteContents.hasContent(spaces))
        XCTAssertFalse(NoteContents.hasContent(papers.appendingPathComponent("Gone.md")))
        let long = papers.appendingPathComponent("Long.md")
        try String(repeating: "A line of a long note.\n", count: 1000).write(to: long, atomically: true, encoding: .utf8)
        XCTAssertTrue(NoteContents.hasContent(long))
        let folder = papers.appendingPathComponent("Folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(NoteContents.hasContent(folder))
    }

    /// Written as Notebook writes them.
    func testWhatIsInAHandwrittenNote() throws {
        let size = PaperSize.a4.size
        let made = try XCTUnwrap(FileOperations.createHandwrittenNote(in: papers, paper: .lined, size: size)).url
        XCTAssertFalse(NoteContents.hasContent(made), "only its paper")
        let base = try Data(contentsOf: made)

        let point = PKStrokePoint(location: CGPoint(x: 60, y: 100), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let next = PKStrokePoint(location: CGPoint(x: 160, y: 120), timeOffset: 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, next], creationDate: Date()))
        let written = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: size, content: PageContent(drawing: PKDrawing(strokes: [stroke]))),
        ]), base: base)
        try written.write(to: made)
        XCTAssertTrue(NoteContents.hasContent(made), "written on")

        let erased = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: size, content: PageContent(drawing: PKDrawing())),
        ]), base: written)
        try erased.write(to: made)
        XCTAssertFalse(NoteContents.hasContent(made), "all of it erased")

        let longer = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: size),
            PDFPlan.Slot(origin: .new, paper: .dotted, size: size),
        ]), base: base)
        try longer.write(to: made)
        XCTAssertTrue(NoteContents.hasContent(made), "a page added")
    }

    func testAPDFThatIsNoNoteCountsAsAFile() throws {
        let pdf = papers.appendingPathComponent("Paper.pdf")
        try XCTUnwrap(PDFDocument(data: NotebookPaper.pageData(.lined, size: PaperSize.a4.size))).write(to: pdf)
        XCTAssertFalse(NoteContents.hasContent(pdf))
    }

    // MARK: - On iPhone and iPad

    /// "Delete?" takes its turn with "Delete immediately?": that one comes once the alert before it has gone, for a note
    /// that couldn't go to the Trash after you agreed.
    func testTheQuestionsTakeTurns() {
        var questions = DeleteQuestions()
        questions.ask(trip, confirming: true)
        XCTAssertEqual(questions.asking, trip)
        XCTAssertTrue(questions.isConfirming)
        questions.answered(trip)
        XCTAssertFalse(questions.isConfirming)
        questions.ask(trip)
        XCTAssertNil(questions.asking, "the alert is still going away")
        questions.gone()
        XCTAssertEqual(questions.asking, trip)
        XCTAssertFalse(questions.isConfirming, "now whether to delete it for good")
    }
}
