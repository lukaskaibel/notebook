import XCTest
@testable import NotebookKit

/// Reminders of notes: kept outside the notes, named as hidden folders are, carried along when Notebook renames, moves
/// or throws a note away, found again after a move in the Finder, and shown with the note's first points.
@MainActor
final class ReminderTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var library: URL { base.appendingPathComponent("Library") }
    private var questions: URL { library.appendingPathComponent("Personal/Questions for Dr. Weber.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-reminders-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Personal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Health"), withIntermediateDirectories: true)
        try "- [ ] Knee\n".write(to: questions, atomically: true, encoding: .utf8)
        try "Plain\n".write(to: library.appendingPathComponent("Personal/Other.md"), atomically: true, encoding: .utf8)
        defaults = UserDefaults(suiteName: "notebook-reminder-tests")
        defaults.removePersistentDomain(forName: "notebook-reminder-tests")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        defaults.removePersistentDomain(forName: "notebook-reminder-tests")
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - The store

    func testRemindersAreKeptAndFollowMoves() throws {
        let store = Reminders(defaults: defaults, cloud: nil)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = store.set(note: "com~apple~CloudDocs/Health/Questions.md", date: date)
        store.set(note: "com~apple~CloudDocs/Health/Questions.md", date: date + 60)
        store.set(note: "com~apple~CloudDocs/Healthy/Food.md", date: date - 60)
        XCTAssertEqual(store.all.count, 2, "a note has one reminder")
        XCTAssertEqual(store.reminder(for: "com~apple~CloudDocs/Health/Questions.md")?.id, first.id)
        XCTAssertEqual(store.all.map(\.note), ["com~apple~CloudDocs/Healthy/Food.md", "com~apple~CloudDocs/Health/Questions.md"], "soonest first")

        let again = Reminders(defaults: defaults, cloud: nil)
        XCTAssertEqual(again.all, store.all)
        XCTAssertEqual(again.reminder(first.id)?.date, date + 60)
        XCTAssertEqual(again.reminder(first.id)?.name, "Questions")

        // A note renamed, then its folder, which leaves a folder with a longer name alone.
        store.move("com~apple~CloudDocs/Health/Questions.md", to: "com~apple~CloudDocs/Health/Doctor.md")
        store.move("com~apple~CloudDocs/Health", to: "com~apple~CloudDocs/Doctors")
        XCTAssertEqual(Reminders(defaults: defaults, cloud: nil).all.map(\.note), ["com~apple~CloudDocs/Healthy/Food.md", "com~apple~CloudDocs/Doctors/Doctor.md"])
        XCTAssertEqual(store.reminder(for: "com~apple~CloudDocs/Doctors/Doctor.md")?.id, first.id, "the same reminder, so its notification is replaced")

        store.forget("com~apple~CloudDocs/Doctors")
        store.remove(store.all[0].id)
        XCTAssertTrue(Reminders(defaults: defaults, cloud: nil).all.isEmpty)
    }

    /// Tests run without the iCloud entitlement, as a build without a team does: the store refuses, the settings keep them.
    func testWithoutICloudTheSettingsKeepThem() {
        let store = Reminders(defaults: defaults, cloud: .default)
        XCTAssertFalse(store.isInICloud)
        store.set(note: "/Users/someone/Notes/Plan.md", date: .now + 3600)
        XCTAssertEqual(Reminders(defaults: defaults, cloud: .default).all.map(\.note), ["/Users/someone/Notes/Plan.md"])
    }

    func testCloudKeysFitTheStore() {
        XCTAssertLessThanOrEqual(Reminders.cloudKey(UUID()).utf8.count, 64)
    }

    // MARK: - In the app

    private func makeWorkspace() async throws -> Workspace {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        for _ in 0..<100 where workspace.index.isBuilding || workspace.index.entry(for: questions) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        return workspace
    }

    func testRemindersFollowNotesRenamedMovedAndTrashedInNotebook() async throws {
        let workspace = try await makeWorkspace()
        let date = Date.now + 3600
        workspace.setReminder(for: questions, at: date)
        let id = try XCTUnwrap(workspace.reminder(for: questions)?.id)
        XCTAssertEqual(workspace.reminders.all.first?.note, HiddenFolders.withoutPrivate(questions.path), "named by its path outside iCloud")
        XCTAssertNil(workspace.reminder(for: library.appendingPathComponent("Personal/Other.md")))

        let renaming = await workspace.rename(questions, to: "Doctor").value
        let renamed = try XCTUnwrap(renaming)
        XCTAssertNil(workspace.reminder(for: questions))
        XCTAssertEqual(workspace.reminder(for: renamed)?.id, id)

        _ = await workspace.move(renamed, into: library.appendingPathComponent("Health")).value
        let moved = library.appendingPathComponent("Health/Doctor.md")
        XCTAssertEqual(workspace.reminder(for: moved)?.id, id)
        XCTAssertEqual(workspace.reminder(for: moved)?.date, date)

        let renamingFolder = await workspace.rename(library.appendingPathComponent("Health"), to: "Appointments").value
        let folder = try XCTUnwrap(renamingFolder)
        let inFolder = folder.appendingPathComponent("Doctor.md")
        XCTAssertEqual(workspace.reminder(for: inFolder)?.id, id)
        XCTAssertEqual(workspace.url(for: try XCTUnwrap(workspace.reminders.reminder(id))), inFolder)

        _ = await workspace.trash(inFolder).value
        XCTAssertTrue(workspace.reminders.all.isEmpty)
    }

    func testANoteMovedInTheFinderIsFoundByItsName() async throws {
        let workspace = try await makeWorkspace()
        workspace.setReminder(for: questions, at: .now + 3600)
        let reminder = try XCTUnwrap(workspace.reminder(for: questions))
        let moved = library.appendingPathComponent("Health/Questions for Dr. Weber.md")
        try FileManager.default.moveItem(at: questions, to: moved)
        workspace.readAgain([library.appendingPathComponent("Personal"), library.appendingPathComponent("Health")])
        for _ in 0..<100 where workspace.index.entry(for: moved) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(workspace.url(for: reminder, searching: false))
        XCTAssertEqual(workspace.url(for: reminder), moved)
        XCTAssertEqual(workspace.reminder(for: moved)?.id, reminder.id, "the reminder follows it")

        // Gone from every location here: nothing to open, and the reminder stays for the devices that have it.
        try FileManager.default.removeItem(at: moved)
        await workspace.readAgain(library.appendingPathComponent("Health"))
        XCTAssertNil(workspace.url(for: try XCTUnwrap(workspace.reminders.reminder(reminder.id))))
        XCTAssertEqual(workspace.reminders.all.count, 1)
        let elsewhere = Reminder(id: UUID(), note: "com~apple~CloudDocs/Elsewhere/Questions for Dr. Weber.md", date: .now)
        XCTAssertNil(workspace.url(for: elsewhere), "a note of a location this device doesn't show isn't looked for")
    }

    // MARK: - What it shows

    func testTheNotesPointsAreWhatIsStillToDoFirst() {
        let note = """
        ---
        tags: [health]
        ---
        Check-up at 9:30. Bring the **insurance card**, see [the practice](https://example.com) and [[Medication|my list]].

        ![Knee](.assets/knee.png)

        ## Questions
        - Ask about the scan
        - [ ] Is the knee pain from running?
        - [x] Blood test results
          - [ ] Do I still need *vitamin D*?
        1. Referral

        ```swift
        let ignored = true
        ```

        > [!tip] Good to know
        > Parking behind the house.
        """
        XCTAssertEqual(NotePoints.text(of: note), """
        ○ Is the knee pain from running?
        ○ Do I still need vitamin D?
        Check-up at 9:30. Bring the insurance card, see the practice and my list.
        • Ask about the scan
        1. Referral
        Good to know
        Parking behind the house.
        """)
        XCTAssertEqual(NotePoints.text(of: ""), "")
        XCTAssertEqual(NotePoints.text(of: "![](.assets/a.png)\n- [x] Done\n"), "", "nothing left to say")
        let long = (1...30).map { "- [ ] Point \($0)" }.joined(separator: "\n")
        XCTAssertEqual(NotePoints.text(of: long).split(separator: "\n").count, NotePoints.maximumLines)
        XCTAssertLessThanOrEqual(NotePoints.text(of: String(repeating: "word ", count: 400)).count, NotePoints.maximumLength)
    }

    func testTimesReadAsInReminders() throws {
        let calendar = Calendar.current
        let now = Date.now
        let today = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now))
        XCTAssertTrue(Workspace.reminderText(today).hasPrefix("Today "))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertTrue(Workspace.reminderText(tomorrow).hasPrefix("Tomorrow "))
        let inThreeDays = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))
        XCTAssertTrue(Workspace.reminderText(inThreeDays).hasPrefix(inThreeDays.formatted(.dateTime.weekday(.wide))))
    }

    func testQuickChoices() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 13, minute: 10)))
        let hours = { (date: Date) in calendar.dateComponents([.day, .hour, .minute], from: date) }
        let choices = ReminderForm.choices(after: afternoon, calendar: calendar)
        XCTAssertEqual(choices.map(\.title), ["Later Today", "This Evening", "Tomorrow"])
        XCTAssertEqual(hours(choices[0].date), DateComponents(day: 16, hour: 16, minute: 0))
        XCTAssertEqual(hours(choices[1].date), DateComponents(day: 16, hour: 18, minute: 0))
        XCTAssertEqual(hours(choices[2].date), DateComponents(day: 17, hour: 9, minute: 0))

        // Later Today would be the evening's time: once is enough.
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 30)))
        XCTAssertEqual(ReminderForm.choices(after: later, calendar: calendar).map(\.title), ["This Evening", "Tomorrow"])
        let night = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 20, minute: 30)))
        XCTAssertEqual(ReminderForm.choices(after: night, calendar: calendar).map(\.title), ["Tomorrow"])
    }
}
