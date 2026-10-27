import XCTest
@testable import NotebookKit

/// To-dos with reminders: the date, time and place written after a to-do's text, read back, changed, and the open
/// to-dos of a note with the lines indented under them as their notes.
final class TodoTests: XCTestCase {
    private func marks(_ line: String) -> [TodoMark] {
        let text = line as NSString
        return TodoMarks.find(in: text, range: NSRange(location: 0, length: text.length))
    }

    // MARK: - Marks

    func testMarksAreRead() throws {
        XCTAssertEqual(marks("Call Dr. Weber ⏰ 2026-10-24 14:00").first?.kind, .due(TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0)))
        XCTAssertEqual(marks("Pay rent 📅 2026-11-01").first?.kind, .due(TodoDue(year: 2026, month: 11, day: 1)))
        XCTAssertEqual(marks("Pay rent 📅 2026-11-01 9:30").first?.kind, .due(TodoDue(year: 2026, month: 11, day: 1, hour: 9, minute: 30)), "a time after a day counts too")
        XCTAssertEqual(marks("Alarm ⏰️ 2026-11-01 07:05").first?.kind, .due(TodoDue(year: 2026, month: 11, day: 1, hour: 7, minute: 5)), "with the emoji's variation selector")
        XCTAssertTrue(marks("Buy a 📅2026-13-01").isEmpty, "no thirteenth month")
        XCTAssertEqual(marks("Buy a📅 2026-10-01").count, 1, "letters typed in front of a pill keep it")
        XCTAssertTrue(marks("Plain to-do").isEmpty)

        let place = try XCTUnwrap(marks("Buy plasters 📍 [Pharmacy](https://maps.apple.com/?ll=52.520008,13.404954&q=Pharmacy)").first)
        XCTAssertEqual(place.kind, .place(TodoPlace(name: "Pharmacy", latitude: 52.520008, longitude: 13.404954)))
        XCTAssertEqual(place.range.location, ("Buy plasters " as NSString).length)
        XCTAssertEqual(marks("Lock up 📍 Leaving [Home](https://maps.apple.com/place?coordinate=48.1,11.5&name=Home)").first?.kind,
                       .place(TodoPlace(name: "Home", latitude: 48.1, longitude: 11.5, leaving: true)))
        XCTAssertEqual(marks("Lock up 📍 [Home](https://example.com)").first?.kind, .place(TodoPlace(name: "Home", latitude: nil, longitude: nil)),
                       "a place without coordinates still shows, it can't remind")

        let both = marks("Ask about the knee ⏰ 2026-10-24 14:00 📍 [Praxis](https://maps.apple.com/?ll=1,2&q=Praxis)")
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(TodoMarks.schedule(of: both).due?.hour, 14)
        XCTAssertEqual(TodoMarks.schedule(of: both).place?.name, "Praxis")
    }

    func testSampleTimesStayLaterToday() throws {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute)))
        }
        XCTAssertEqual(DemoLibrary.later(by: 2, latest: (23, 0), now: try at(14, 10)), "⏰ 2026-10-27 16:30")
        XCTAssertEqual(DemoLibrary.later(by: 2, latest: (23, 0), now: try at(21, 0)), "⏰ 2026-10-27 23:00")
        XCTAssertEqual(DemoLibrary.later(by: 2, latest: (23, 0), now: try at(21, 1)), "📅 2026-10-27",
                       "too late for a time: due today, so not overdue before the day is over")
        XCTAssertEqual(DemoLibrary.later(by: 3, latest: (23, 30), now: try at(23, 40)), "📅 2026-10-27")
    }

    func testMarksAreWrittenAsOtherAppsReadThem() {
        XCTAssertEqual(TodoDue(year: 2026, month: 10, day: 24, hour: 9, minute: 5).markdown, "⏰ 2026-10-24 09:05")
        XCTAssertEqual(TodoDue(year: 2026, month: 1, day: 2).markdown, "📅 2026-01-02")
        let place = TodoPlace(name: "Café [Mitte]", latitude: 52.5200081, longitude: 13.4, leaving: true)
        XCTAssertEqual(place.markdown, "📍 Leaving [Café (Mitte)](https://maps.apple.com/?ll=52.520008,13.4&q=Caf%C3%A9%20%5BMitte%5D)")
        // What is written is read back the same.
        let line = "Coffee " + place.markdown
        XCTAssertEqual(marks(line).first?.kind, .place(TodoPlace(name: "Café (Mitte)", latitude: 52.520008, longitude: 13.4, leaving: true)))
    }

    func testChangingMarksLeavesTheWords() throws {
        func apply(_ line: String, due: TodoDue?, place: TodoPlace?) -> String {
            let text = line as NSString
            guard let change = TodoMarks.change(in: text, content: NSRange(location: 0, length: text.length), due: due, place: place) else { return line }
            return text.replacingCharacters(in: change.range, with: change.replacement)
        }
        let due = TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0)
        let pharmacy = TodoPlace(name: "Pharmacy", latitude: 1, longitude: 2)
        XCTAssertEqual(apply("Call Dr. Weber", due: due, place: nil), "Call Dr. Weber ⏰ 2026-10-24 14:00")
        XCTAssertEqual(apply("Call Dr. Weber  ", due: due, place: nil), "Call Dr. Weber ⏰ 2026-10-24 14:00", "trailing spaces go")
        XCTAssertEqual(apply("Call Dr. Weber ⏰ 2026-10-24 14:00", due: due.at(hour: nil, minute: nil), place: nil), "Call Dr. Weber 📅 2026-10-24")
        XCTAssertEqual(apply("Call ⏰ 2026-10-24 14:00 Dr. Weber", due: nil, place: nil), "Call Dr. Weber", "a mark in the middle goes too")
        XCTAssertEqual(apply("Call Dr. Weber ⏰ 2026-10-24 14:00", due: due, place: pharmacy), "Call Dr. Weber ⏰ 2026-10-24 14:00 " + pharmacy.markdown)
        XCTAssertEqual(apply("Call Dr. Weber " + pharmacy.markdown + " ⏰ 2026-10-24 14:00", due: due, place: pharmacy), "Call Dr. Weber ⏰ 2026-10-24 14:00 " + pharmacy.markdown, "the date first")
        XCTAssertEqual(apply("", due: due, place: nil), "⏰ 2026-10-24 14:00")

        // Only what differs is replaced.
        let text = "Call ⏰ 2026-10-24 14:00" as NSString
        let change = try XCTUnwrap(TodoMarks.change(in: text, content: NSRange(location: 0, length: text.length), due: due.at(hour: 15, minute: 0), place: nil))
        XCTAssertEqual(change.replacement, "5")
        XCTAssertNil(TodoMarks.change(in: text, content: NSRange(location: 0, length: text.length), due: due, place: nil), "nothing to change")
    }

    func testADayAndATimeTogetherKeepBoth() {
        let line = "Call 📅 2026-10-24 ⏰ 2026-10-24 14:00" as NSString
        XCTAssertEqual(TodoMarks.schedule(of: marks(line as String)).due, TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0), "the time is when it reminds")
        let change = TodoMarks.change(in: line, content: NSRange(location: 0, length: line.length), due: TodoDue(year: 2026, month: 10, day: 25, hour: 9, minute: 0), place: nil)
        XCTAssertEqual(change.map { line.replacingCharacters(in: $0.range, with: $0.replacement) }, "Call 📅 2026-10-25 ⏰ 2026-10-25 09:00", "both plugins' marks move along")
    }

    func testADateInsideAPlacesNameIsPartOfThePlace() throws {
        let line = "Go 📍 [a ⏰ 2026-10-24 14:00](https://maps.apple.com/?q=a)" as NSString
        let found = TodoMarks.find(in: line, range: NSRange(location: 0, length: line.length))
        XCTAssertEqual(found.count, 1)
        let change = try XCTUnwrap(TodoMarks.change(in: line, content: NSRange(location: 0, length: line.length), due: nil, place: nil))
        XCTAssertEqual(line.replacingCharacters(in: change.range, with: change.replacement), "Go")
    }

    func testDueDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        XCTAssertTrue(TodoDue(year: 2026, month: 10, day: 23, hour: 11, minute: 59).isOverdue(at: now, calendar: calendar))
        XCTAssertFalse(TodoDue(year: 2026, month: 10, day: 23, hour: 12, minute: 1).isOverdue(at: now, calendar: calendar))
        XCTAssertFalse(TodoDue(year: 2026, month: 10, day: 23).isOverdue(at: now, calendar: calendar), "today's to-do isn't overdue until tomorrow")
        XCTAssertTrue(TodoDue(year: 2026, month: 10, day: 22).isOverdue(at: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: TodoDue(year: 2026, month: 10, day: 24).alertDate(in: calendar)), TodoDue.dayAlertHour)
        XCTAssertEqual(TodoDue(now, time: true, calendar: calendar), TodoDue(year: 2026, month: 10, day: 23, hour: 12, minute: 0))
        XCTAssertEqual(TodoDue(now, time: false, calendar: calendar), TodoDue(year: 2026, month: 10, day: 23))
    }

    // MARK: - A note's to-dos

    func testOpenTodosWithTheirNotes() {
        let note = """
        # Doctor

        - [ ] Call Dr. Weber ⏰ 2026-10-24 14:00
            - ask about the **results**
            - [ ] bring the letter
            - [x] book the taxi

            Second paragraph of notes
        - [x] Done already
            - [ ] under a done one
        - [ ] Buy plasters 📍 [Pharmacy](https://maps.apple.com/?ll=1,2&q=Pharmacy)
        - Shopping
            - [ ] Milk
                - [ ] Nested with a date 📅 2026-10-25
        ```
        - [ ] in code
        ```
        > - [ ] in a quote
        """
        let todos = Todos.open(in: note)
        XCTAssertEqual(todos.map(\.text), ["Call Dr. Weber", "Buy plasters", "Milk", "Nested with a date"])
        XCTAssertEqual(todos[0].notes, ["• ask about the results", "○ bring the letter", "✓ book the taxi", "Second paragraph of notes"])
        XCTAssertEqual(todos[0].due, TodoDue(year: 2026, month: 10, day: 24, hour: 14, minute: 0))
        XCTAssertEqual(todos[0].line, 2)
        XCTAssertEqual(todos[0].source, "- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00")
        XCTAssertEqual(todos[1].place?.name, "Pharmacy")
        XCTAssertTrue(todos[1].notes.isEmpty)
        XCTAssertEqual(todos[2].notes, ["○ Nested with a date"], "a to-do under a plain point is a to-do of its own")
        XCTAssertEqual(todos[3].due, TodoDue(year: 2026, month: 10, day: 25), "nested, but with a date of its own")
        XCTAssertTrue(Todos.open(in: "Nothing to do\n- [x] done").isEmpty)
    }

    func testATodoIsFoundAgainAfterTheNoteChanged() {
        let before = "- [ ] One\n- [ ] Two\n"
        let after = "Intro\n\n- [ ] One\n- [ ] Two\n- [ ] Two\n"
        let todo = Todos.open(in: before)[1]
        let document = MarkdownParser.parse(after)
        XCTAssertEqual(Todos.find(todo.source, near: todo.line, in: document, string: after as NSString), 3, "the nearest line that says the same")
        XCTAssertNil(Todos.find("- [ ] Three", near: 0, in: document, string: after as NSString))
    }

    // MARK: - Obsidian's checkboxes and the plugins' marks

    func testEveryMarkObsidianDrawsIsACheckbox() throws {
        func item(_ line: String) -> ListItem? {
            if case .listItem(let item) = MarkdownParser.parse(line).lines.first?.kind, item.isTask { return item }
            return nil
        }
        XCTAssertEqual(item("- [ ] To do")?.mark, .open)
        XCTAssertEqual(item("- [x] Done")?.mark, .done)
        XCTAssertEqual(item("- [X] Done")?.mark, .done)
        XCTAssertEqual(item("- [/] Half done")?.mark, .inProgress)
        XCTAssertEqual(item("- [-] Dropped")?.mark, .cancelled)
        XCTAssertEqual(item("* [!] Important")?.mark, .other("!"))
        XCTAssertEqual(item("1. [?] Question")?.mark, .other("?"))
        XCTAssertEqual(item("- [>] Moved on")?.mark, .other(">"))
        XCTAssertEqual(item("- [“] Quote")?.mark, .other("“"))
        XCTAssertEqual(item("- [/]")?.mark, .inProgress, "an empty one too")
        XCTAssertNil(item("- [1] Smith, 2020"), "a number starts a reference")
        XCTAssertNil(item("- [a](https://example.com) a link"))
        XCTAssertNil(item("- [[Note]] a link to a note"))
        XCTAssertNil(item("- [ab] two letters"))
        XCTAssertEqual(item("- [x] Done")?.checked, true)
        XCTAssertEqual(item("- [-] Dropped")?.checked, true, "cancelled is no longer to do")
        XCTAssertEqual(item("- [/] Half done")?.checked, false)
        XCTAssertEqual(item("- [!] Important")?.checked, false)
    }

    func testAllButDoneAndCancelledAreStillToDo() {
        let note = "- [ ] Open\n- [/] Started\n- [!] Urgent\n- [x] Done\n- [-] Dropped\n- [?] Ask\n"
        XCTAssertEqual(Todos.open(in: note).map(\.text), ["Open", "Started", "Urgent", "Ask"])
        XCTAssertEqual(Todos.open(in: "- [/] Only this").map(\.text), ["Only this"], "found without an empty box in the note")
        XCTAssertTrue(Todos.open(in: "- [x] done\n- [-] dropped\n[a](b) [1]").isEmpty)
        XCTAssertEqual(Todos.ticked("- [/] Started 📅 2026-10-24"), "- [x] Started 📅 2026-10-24")
        XCTAssertEqual(NotePoints.text(of: "- [/] Started\n- [-] Dropped\n- Point"), "○ Started\n• Point")
    }

    func testTheOtherPluginsDatesAreRead() {
        let day = TodoDue(year: 2026, month: 10, day: 24)
        let time = day.at(hour: 14, minute: 0)
        XCTAssertEqual(marks("Call (@2026-10-24 14:00)").first?.kind, .due(time), "the Reminder plugin")
        XCTAssertEqual(marks("Call (@2026-10-24)").first?.kind, .due(day))
        XCTAssertEqual(marks("Call @{2026-10-24} @@{14:00}").first?.kind, .due(time), "the Kanban plugin")
        XCTAssertEqual(marks("Call @[[2026-10-24]]").first?.kind, .due(day))
        XCTAssertEqual(marks("Call [due:: 2026-10-24]").first?.kind, .due(day), "Dataview")
        XCTAssertEqual(marks("Call (due:: 2026-10-24T14:00)").first?.kind, .due(time))
        XCTAssertEqual(marks("Call 🗓️2026-10-24").first?.kind, .due(day), "Dataview's shorthand")
        XCTAssertEqual(marks("Call @{2026-10-24} @@{14:00}").first?.range.length, ("@{2026-10-24} @@{14:00}" as NSString).length, "the time is part of it")
        XCTAssertTrue(marks("Mail me at a@b.com (@ home)").isEmpty)
    }

    func testADateKeepsTheWayItWasWritten() {
        func apply(_ line: String, due: TodoDue?) -> String {
            let text = line as NSString
            guard let change = TodoMarks.change(in: text, content: NSRange(location: 0, length: text.length), due: due, place: nil) else { return line }
            return text.replacingCharacters(in: change.range, with: change.replacement)
        }
        let day = TodoDue(year: 2026, month: 10, day: 25)
        let time = day.at(hour: 9, minute: 30)
        XCTAssertEqual(apply("Call (@2026-10-24)", due: time), "Call (@2026-10-25 09:30)")
        XCTAssertEqual(apply("Call @{2026-10-24} @@{14:00}", due: day), "Call @{2026-10-25}")
        XCTAssertEqual(apply("Call [due:: 2026-10-24]", due: time), "Call [due:: 2026-10-25T09:30]")
        XCTAssertEqual(apply("Call (due:: 2026-10-24)", due: day), "Call (due:: 2026-10-25)")
        XCTAssertEqual(apply("Call 🗓️2026-10-24", due: day), "Call 🗓️2026-10-25")
        XCTAssertEqual(apply("Call", due: day), "Call 📅 2026-10-25", "Tasks' when there was none")
    }

    func testTheTasksPluginsOtherFieldsShowAndStay() throws {
        let line = "Water the plants ⏫ 🔁 every week on Monday ⏳ 2026-10-26 📅 2026-10-27 ➕ 2026-10-01 🆔 abc ⛔ x1, y2 🏁 delete"
        let found = marks(line)
        let fields = found.compactMap { if case .field(let field) = $0.kind { field } else { nil } }
        XCTAssertEqual(fields, [TodoField(.priority, "high"), TodoField(.repeats, "every week on Monday"), TodoField(.scheduled, "2026-10-26"),
                                TodoField(.created, "2026-10-01"), TodoField(.id, "abc"), TodoField(.dependsOn, "x1,y2"), TodoField(.onCompletion, "delete")])
        XCTAssertEqual(TodoMarks.schedule(of: found).due, TodoDue(year: 2026, month: 10, day: 27))
        XCTAssertEqual(marks("Plan [priority:: High] [repeat:: every day] (scheduled:: 2026-10-26)").map(\.kind),
                       [.field(TodoField(.priority, "high")), .field(TodoField(.repeats, "every day")), .field(TodoField(.scheduled, "2026-10-26"))])

        // The words read without them, and a new date leaves them where they are.
        let todo = try XCTUnwrap(Todos.open(in: "- [ ] " + line).first)
        XCTAssertEqual(todo.text, "Water the plants")
        let text = line as NSString
        let change = try XCTUnwrap(TodoMarks.change(in: text, content: NSRange(location: 0, length: text.length), due: TodoDue(year: 2026, month: 11, day: 3), place: nil))
        XCTAssertEqual(text.replacingCharacters(in: change.range, with: change.replacement),
                       "Water the plants ⏫ 🔁 every week on Monday ⏳ 2026-10-26 ➕ 2026-10-01 🆔 abc ⛔ x1, y2 🏁 delete 📅 2026-11-03")
        XCTAssertEqual(TodoField(.priority, "high").label(), "High")
        XCTAssertEqual(TodoField(.dependsOn, "x1,y2").label(), "After x1, y2")
    }

    func testNotificationPointsLeaveMarksOut() {
        XCTAssertEqual(NotePoints.text(of: "- [ ] Call ⏰ 2026-10-24 14:00\n- Point"), "○ Call\n• Point")
    }

    // MARK: - Deleting

    /// Deletes the to-do whose line says `todo` and puts it back, as Undo does: the note says what it said again.
    private func delete(_ todo: String, in note: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let text = note as NSString
        let document = MarkdownParser.parse(text)
        let index = try XCTUnwrap(document.lines.firstIndex { text.substring(with: $0.range) == todo }, file: file, line: line)
        let deleting = try XCTUnwrap(Todos.deleting(in: text, document: document, line: index), file: file, line: line)
        let deleted = text.replacingCharacters(in: deleting.range, with: "") as NSString
        let back = Todos.restoring(deleting.removal, in: deleted, document: MarkdownParser.parse(deleted))
        XCTAssertEqual(deleted.replacingCharacters(in: back.range, with: back.replacement), note, "Undo", file: file, line: line)
        return deleted as String
    }

    func testDeletingATodoTakesTheLinesUnderIt() throws {
        let note = "# Doctor\n\n- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00\n    - ask about the results\n\n    - [ ] bring the letter\n- [x] Book the taxi\n"
        XCTAssertEqual(try delete("- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00", in: note), "# Doctor\n\n- [x] Book the taxi\n")
        // A sub-to-do with a date of its own, listed on its own, goes alone.
        XCTAssertEqual(try delete("    - [ ] bring the letter", in: note),
                       "# Doctor\n\n- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00\n    - ask about the results\n\n- [x] Book the taxi\n")
        // Not a to-do: nothing.
        let text = note as NSString
        XCTAssertNil(Todos.deleting(in: text, document: MarkdownParser.parse(text), line: 0))
    }

    func testDeletingATodoLeavesNoBlankLinesBehind() throws {
        // Between blank lines, one of them goes with it; at the start, the blank line after it.
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "Shopping\n\n- [ ] Buy milk\n\nLater"), "Shopping\n\nLater")
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Buy milk\n\nLater"), "Later")
        // At the end, with the line ending before it, and the blank line before that.
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Bread\n- [ ] Buy milk"), "- [ ] Bread")
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "Shopping\n\n- [ ] Buy milk\n"), "Shopping\n")
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Buy milk"), "")
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Buy milk\n"), "")
        // Windows line endings stay as they are.
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Bread\r\n- [ ] Buy milk\r\n- [ ] Eggs\r\n"), "- [ ] Bread\r\n- [ ] Eggs\r\n")
        XCTAssertEqual(try delete("- [ ] Buy milk", in: "- [ ] Bread\r\n- [ ] Buy milk"), "- [ ] Bread")
    }

    func testADeletedTodoGoesBackAfterTheLineAboveIt() throws {
        let note = "Shopping\n- [ ] Buy milk\n    - oat\n- [ ] Eggs\n" as NSString
        let deleting = try XCTUnwrap(Todos.deleting(in: note, document: MarkdownParser.parse(note), line: 1))
        // Lines added above meanwhile: it goes back under the line that was above it.
        var changed = "Intro\n\nShopping\n- [ ] Eggs\n" as NSString
        var back = Todos.restoring(deleting.removal, in: changed, document: MarkdownParser.parse(changed))
        XCTAssertEqual(changed.replacingCharacters(in: back.range, with: back.replacement), "Intro\n\nShopping\n- [ ] Buy milk\n    - oat\n- [ ] Eggs\n")
        // That line now the last, without a line ending: one goes before it.
        changed = "Shopping"
        back = Todos.restoring(deleting.removal, in: changed, document: MarkdownParser.parse(changed))
        XCTAssertEqual(changed.replacingCharacters(in: back.range, with: back.replacement), "Shopping\n- [ ] Buy milk\n    - oat")
        // That line gone: where it was.
        changed = "Other\n- [ ] Eggs\n"
        back = Todos.restoring(deleting.removal, in: changed, document: MarkdownParser.parse(changed))
        XCTAssertEqual(changed.replacingCharacters(in: back.range, with: back.replacement), "Other\n- [ ] Buy milk\n    - oat\n- [ ] Eggs\n")
    }

    // MARK: - To-dos in no note

    /// Moves `lines` into `note` as Move to Note does, and says what the note says then and the line the to-do is on.
    private func move(_ lines: [String], into note: String) -> (text: String, line: Int, source: String) {
        let text = note as NSString
        let inserting = Todos.inserting(lines, in: text, document: MarkdownParser.parse(text))
        let result = text.replacingCharacters(in: inserting.range, with: inserting.replacement)
        XCTAssertEqual(result.components(separatedBy: "\n")[safe: inserting.line]?.replacingOccurrences(of: "\r", with: ""), inserting.source)
        return (result, inserting.line, inserting.source)
    }

    func testAnEmptyTodoIsATodo() throws {
        let empty = try XCTUnwrap(Todos.open(in: "- [ ]").first)
        XCTAssertEqual(empty.text, "")
        let dated = try XCTUnwrap(Todos.open(in: "- [ ] 📅 2026-10-28").first)
        XCTAssertEqual(dated.text, "")
        XCTAssertEqual(dated.due, TodoDue(year: 2026, month: 10, day: 28))
        XCTAssertEqual(Todos.replacingWords(in: "- [ ] 📅 2026-10-28", with: "Call the plumber"), "- [ ] Call the plumber 📅 2026-10-28")
    }

    func testATodoMovedIntoANoteGoesAfterItsLastChecklist() {
        let butter = ["- [ ] Butter", "    - the salted one"]
        // After the last to-do of the last checklist, with the lines under that one.
        XCTAssertEqual(move(butter, into: "# Shop\n\n- [ ] Bread\n    - wholemeal\n\nNotes.\n").text,
                       "# Shop\n\n- [ ] Bread\n    - wholemeal\n- [ ] Butter\n    - the salted one\n\nNotes.\n")
        XCTAssertEqual(move(butter, into: "- [ ] A\n\nText\n\n- [x] B").text, "- [ ] A\n\nText\n\n- [x] B\n- [ ] Butter\n    - the salted one")
        // A sub-to-do isn't a checklist of its own.
        XCTAssertEqual(move(["- [ ] C"], into: "- [ ] A\n    - [ ] a\n").text, "- [ ] A\n    - [ ] a\n- [ ] C\n")
        // With the checklist's bullet and the note's line endings.
        XCTAssertEqual(move(["- [ ] C"], into: "* [ ] A\r\n* [ ] B\r\n").text, "* [ ] A\r\n* [ ] B\r\n* [ ] C\r\n")
        XCTAssertEqual(move(["- [ ] C"], into: "* [ ] A\r\n").source, "* [ ] C")
    }

    func testATodoMovedIntoANoteWithoutAChecklistGoesAtItsEnd() {
        XCTAssertEqual(move(["- [ ] C"], into: "# Plans\n\nSome words.\n").text, "# Plans\n\nSome words.\n\n- [ ] C\n")
        XCTAssertEqual(move(["- [ ] C"], into: "# Plans\n\nSome words.\n\n").text, "# Plans\n\nSome words.\n\n- [ ] C\n")
        XCTAssertEqual(move(["- [ ] C"], into: "Some words.").text, "Some words.\n\n- [ ] C")
        XCTAssertEqual(move(["- [ ] C"], into: "Some words.").line, 2)
        XCTAssertEqual(move(["- [ ] C"], into: "").text, "- [ ] C\n")
        XCTAssertEqual(move(["- [ ] C"], into: "1. [ ] Numbered\n").text, "1. [ ] Numbered\n- [ ] C\n")
    }

    func testLinesAddedAtTheEndOfAFile() {
        func add(_ lines: [String], to text: String) -> (String, Int) {
            let adding = LooseTodos.adding(lines, to: text)
            return (text + adding.text, adding.line)
        }
        XCTAssertTrue(add(["- [ ] A"], to: "") == ("- [ ] A\n", 0))
        XCTAssertTrue(add(["- [ ] B"], to: "- [ ] A\n") == ("- [ ] A\n- [ ] B\n", 1))
        XCTAssertTrue(add(["- [ ] B"], to: "- [ ] A") == ("- [ ] A\n- [ ] B\n", 1))
        XCTAssertTrue(add(["- [ ] B"], to: "- [ ] A\r\n") == ("- [ ] A\r\n- [ ] B\r\n", 1))
        XCTAssertTrue(add(["- [ ] C"], to: "- [ ] A\n\n") == ("- [ ] A\n\n- [ ] C\n", 2))
    }
}
