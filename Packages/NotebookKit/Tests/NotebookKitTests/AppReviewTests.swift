import XCTest
@testable import NotebookKit

/// Notebook asks for a rating on the App Store once it was used on three days, as you finish something, at most once a
/// version and two months apart; leaving a note you wrote in is such a moment, leaving it for a new note isn't.
@MainActor
final class AppReviewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var library: URL!
    private var draft: URL { library.appendingPathComponent("Draft.md") }
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }
    private var window: NSWindow?
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    override func setUp() async throws {
        suiteName = "notebook-review-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookAsksForReview"] { UserDefaults.standard.removeObject(forKey: key) }
        AppReview.shared.prompt = { false }
        AppReview.shared.delay = 1
        window?.close()
        if let library { try? FileManager.default.removeItem(at: library) }
    }

    private func day(_ number: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: number, hour: hour))!
    }

    /// Lets the main queue run what was put on it, as the prompt is, without a delay in tests.
    private func settle() async {
        await withCheckedContinuation { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.resume() } }
    }

    // MARK: - When

    func testAsksOnlyOnceUsedOnThreeDays() {
        var record = ReviewRecord()
        XCTAssertTrue(record.use(on: day(1), calendar: calendar))
        XCTAssertFalse(record.use(on: day(1, hour: 20), calendar: calendar), "the same day counted twice")
        XCTAssertTrue(record.use(on: day(2), calendar: calendar))
        XCTAssertFalse(record.isDue(version: "1.3.0", at: day(2)))
        XCTAssertTrue(record.use(on: day(9), calendar: calendar))
        XCTAssertTrue(record.isDue(version: "1.3.0", at: day(9)))
        XCTAssertEqual(record.daysUsed, ["2026-11-01", "2026-11-02", "2026-11-09"])
    }

    func testAsksOnceAVersionAndTwoMonthsApart() {
        var record = ReviewRecord(daysUsed: ["2026-11-01", "2026-11-02", "2026-11-03"])
        record.asked(version: "1.3.0", at: day(3))
        XCTAssertFalse(record.isDue(version: "1.3.0", at: day(3).addingTimeInterval(200 * 24 * 3600)), "twice in a version")
        XCTAssertFalse(record.isDue(version: "1.4.0", at: day(20)), "another version three weeks later")
        XCTAssertTrue(record.isDue(version: "1.4.0", at: day(3).addingTimeInterval(61 * 24 * 3600)))
    }

    func testKeepsOnlyTheLastDays() {
        var record = ReviewRecord()
        for number in 1...14 { _ = record.use(on: day(number), calendar: calendar) }
        XCTAssertEqual(record.daysUsed.count, 10)
        XCTAssertEqual(record.daysUsed.last, "2026-11-14")
    }

    // MARK: - Asking

    func testAsksOnceTheTimeHasComeAndRemembersIt() async {
        let review = AppReview(defaults: defaults, version: "1.3.0", mayAsk: true)
        var prompts = 0
        review.prompt = { prompts += 1; return true }
        review.delay = 0
        review.start()
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 0, "asked on the first day")
        review.used(on: Date().addingTimeInterval(-2 * 24 * 3600))
        review.used(on: Date().addingTimeInterval(-24 * 3600))
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 1)
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 1, "asked twice in a version")
        let again = AppReview(defaults: defaults, version: "1.3.0", mayAsk: true)
        XCTAssertEqual(again.record.askedVersion, "1.3.0", "not remembered")
        XCTAssertEqual(again.record.daysUsed.count, 3)
    }

    func testNotWhenItNoLongerFits() async {
        defaults.set(["2026-11-01", "2026-11-02", "2026-11-03"], forKey: "reviewDaysUsed")
        let review = AppReview(defaults: defaults, version: "1.3.0", mayAsk: true)
        var prompts = 0
        review.prompt = { prompts += 1; return true }
        review.delay = 0
        review.start()
        review.finishedSomething { false }
        await settle()
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(review.record.askedVersion, "remembered as asked")
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 1)
    }

    /// Debug builds, where the system shows its prompt every time, ask only when told to, and then every time.
    func testDebugBuildsAskOnlyWhenTold() async {
        defaults.set(["2026-11-01", "2026-11-02", "2026-11-03"], forKey: "reviewDaysUsed")
        let review = AppReview(defaults: defaults, version: "1.3.0", mayAsk: false)
        var prompts = 0
        review.prompt = { prompts += 1; return true }
        review.delay = 0
        review.start()
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 0)
        defaults.set(true, forKey: "NotebookAsksForReview")
        review.finishedSomething()
        await settle()
        review.finishedSomething()
        await settle()
        XCTAssertEqual(prompts, 2)
        XCTAssertNil(review.record.askedVersion)
    }

    // MARK: - The moments

    /// The library read, with the editor in a window, as in NewNoteTests; every moment shows the prompt.
    private func makeWorkspace(counting prompts: @escaping () -> Void) async throws -> Workspace {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-review-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "# Draft\n\nSome text.\n".write(to: draft, atomically: true, encoding: .utf8)
        try "Milk, eggs.\n".write(to: groceries, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.set(true, forKey: "NotebookAsksForReview")
        AppReview.shared.prompt = { prompts(); return true }
        AppReview.shared.delay = 0
        let workspace = Workspace()
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = workspace.editor.view
        let end = Date().addingTimeInterval(TestRun.patience)
        while !(workspace.hasReadLocations && workspace.reader.isIdle) {
            guard Date() < end else { XCTFail("the library was never read"); break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return workspace
    }

    private func openAndWait(_ url: URL, in workspace: Workspace) async throws {
        workspace.open(url)
        let end = Date().addingTimeInterval(TestRun.patience)
        while workspace.note?.isLoaded != true {
            guard Date() < end else { return XCTFail("\(url.lastPathComponent) never loaded") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func type(_ text: String, in workspace: Workspace) {
        let textView = workspace.editor.textView
        window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func testLeavingANoteYouWroteInIsAMoment() async throws {
        var prompts = 0
        let workspace = try await makeWorkspace { prompts += 1 }
        try await openAndWait(draft, in: workspace)
        type(" More.", in: workspace)
        try await openAndWait(groceries, in: workspace)
        await settle()
        XCTAssertEqual(prompts, 1)
        await NoteDocument.allWritten()
    }

    /// Writing in the next note before the prompt came: it waits for the next time.
    func testNotOnceYouWriteInTheNextNote() async throws {
        var prompts = 0
        let workspace = try await makeWorkspace { prompts += 1 }
        AppReview.shared.delay = 0.3
        try await openAndWait(draft, in: workspace)
        type(" More.", in: workspace)
        try await openAndWait(groceries, in: workspace)
        type(" Bread.", in: workspace)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(prompts, 0)
        await NoteDocument.allWritten()
    }

    func testLeavingANoteYouOnlyReadIsNot() async throws {
        var prompts = 0
        let workspace = try await makeWorkspace { prompts += 1 }
        try await openAndWait(draft, in: workspace)
        try await openAndWait(groceries, in: workspace)
        workspace.showTodos()
        await settle()
        XCTAssertEqual(prompts, 0)
    }

    /// A new note is typed in at once: the prompt would come over its title.
    func testLeavingANoteForANewOneIsNot() async throws {
        var prompts = 0
        let workspace = try await makeWorkspace { prompts += 1 }
        try await openAndWait(draft, in: workspace)
        type(" More.", in: workspace)
        _ = await workspace.newNote(in: library).value
        await settle()
        XCTAssertEqual(prompts, 0)
        await NoteDocument.allWritten()
    }
}
