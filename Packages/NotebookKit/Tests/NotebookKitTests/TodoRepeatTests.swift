import XCTest
@testable import NotebookKit

/// To-dos that repeat, as the Tasks plugin has them: the rule after `🔁` read as Tasks reads it, the next day as Tasks
/// works it out, and the lines written when one is ticked, character for character.
final class TodoRepeatTests: XCTestCase {
    private func day(_ text: String) -> TodoDay {
        let parts = text.split(separator: "-").map { Int($0)! }
        return TodoDay(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The next day of `rule` after a to-do on `from`, done on `done` (the same day unless said).
    private func next(_ rule: String, from: String?, done: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let parsed = TodoRepeat(rule) else {
            XCTFail("“\(rule)” isn't read as a rule", file: file, line: line)
            return nil
        }
        return parsed.next(after: from.map(day), doneOn: day(done ?? from ?? "2026-10-26"))?.description
    }

    // MARK: - Days

    func testDaysAreCountedLikeTheCalendar() {
        XCTAssertEqual(day("1970-01-01").number, 0)
        XCTAssertEqual(day("2026-10-26").weekday, 0, "a Monday")
        XCTAssertEqual(day("2024-02-29").adding(days: 1), day("2024-03-01"))
        XCTAssertEqual(day("2000-02-28").adding(days: 1), day("2000-02-29"), "2000 was a leap year")
        XCTAssertEqual(day("2100-02-28").adding(days: 1), day("2100-03-01"), "2100 won't be")
        XCTAssertEqual(TodoDay(number: day("1969-12-31").number), day("1969-12-31"))
        XCTAssertFalse(day("2026-02-29").exists)
        XCTAssertEqual(day("2026-01-05").description, "2026-01-05")
    }

    // MARK: - Rules

    func testByTheDayAndTheWeek() {
        XCTAssertEqual(next("every day", from: "2026-10-26"), "2026-10-27")
        XCTAssertEqual(next("every 3 days", from: "2026-12-30"), "2027-01-02")
        XCTAssertEqual(next("every week", from: "2026-10-26"), "2026-11-02")
        XCTAssertEqual(next("every 2 weeks", from: "2026-10-28"), "2026-11-11")
        // Tasks' own example: taking out the trash every Sunday.
        XCTAssertEqual(next("every Sunday", from: "2021-04-25"), "2021-05-02")
        XCTAssertEqual(next("every Monday", from: "2026-10-28"), "2026-11-02", "the next Monday after a Wednesday")
        XCTAssertEqual(next("every week on Tuesday, Friday", from: "2026-10-27"), "2026-10-30")
        XCTAssertEqual(next("every week on Tuesday, Friday", from: "2026-10-30"), "2026-11-03")
        XCTAssertEqual(next("every Tuesday and Thursday", from: "2026-10-29"), "2026-11-03")
        XCTAssertEqual(next("every mon, wed", from: "2026-10-26"), "2026-10-28", "short names, as rrule reads them")
        // rrule counts the weeks from the one the date is in, Monday first.
        XCTAssertEqual(next("every 3 weeks on Friday", from: "2026-10-28"), "2026-10-30", "that week's Friday is still to come")
        XCTAssertEqual(next("every 3 weeks on Friday", from: "2026-10-30"), "2026-11-20")
        XCTAssertEqual(next("Every Week", from: "2026-10-26"), "2026-11-02", "in any case")
    }

    func testWeekdays() {
        XCTAssertEqual(next("every weekday", from: "2026-10-26"), "2026-10-27", "Monday to Tuesday")
        XCTAssertEqual(next("every weekday", from: "2026-10-30"), "2026-11-02", "Friday to Monday")
        XCTAssertEqual(next("every weekday", from: "2026-10-31"), "2026-11-02", "Saturday to Monday")
        XCTAssertEqual(next("every month on weekdays", from: "2026-10-30"), "2026-11-02")
    }

    func testMonthsAndTheirEnds() {
        XCTAssertEqual(next("every month", from: "2026-10-26"), "2026-11-26")
        // A day the next month doesn't have: its last day, and from then on that day (Tasks' documentation).
        XCTAssertEqual(next("every month", from: "2021-10-31"), "2021-11-30")
        XCTAssertEqual(next("every month", from: "2021-11-30"), "2021-12-30")
        XCTAssertEqual(next("every month", from: "2026-01-31"), "2026-02-28")
        XCTAssertEqual(next("every month", from: "2024-01-31"), "2024-02-29", "February in a leap year")
        XCTAssertEqual(next("every 3 months", from: "2022-01-31"), "2022-04-30")
        XCTAssertEqual(next("every 3 months", from: "2022-04-30"), "2022-07-30")
        XCTAssertEqual(next("every month", from: "2026-12-15"), "2027-01-15", "into the next year")
        // A day written in the rule: months without it are left out, as iCalendar has it.
        XCTAssertEqual(next("every month on the 31st", from: "2022-01-31"), "2022-03-31")
        XCTAssertEqual(next("every month on the last", from: "2022-01-31"), "2022-02-28")
        XCTAssertEqual(next("every month on the last", from: "2022-02-28"), "2022-03-31")
        XCTAssertEqual(next("every month on the 1st", from: "2026-10-26"), "2026-11-01")
        XCTAssertEqual(next("every month on the 1st", from: "2026-11-01"), "2026-12-01")
        XCTAssertEqual(next("every month on the 1st and 15th", from: "2026-11-01"), "2026-11-15")
        XCTAssertEqual(next("every month on the 1st and the 15th", from: "2026-11-01"), "2026-12-01", "rrule reads no further after “and the”")
        XCTAssertEqual(next("every 2 months", from: "2026-12-31"), "2027-02-28")
    }

    func testWhichWeekdayOfTheMonth() {
        XCTAssertEqual(next("every month on the last Friday", from: "2026-10-26"), "2026-10-30")
        XCTAssertEqual(next("every month on the last Friday", from: "2026-10-30"), "2026-11-27")
        XCTAssertEqual(next("every month on the 2nd last Friday", from: "2026-10-01"), "2026-10-23")
        XCTAssertEqual(next("every month on the first Monday", from: "2026-10-26"), "2026-11-02")
        XCTAssertEqual(next("every month on the second Tuesday", from: "2026-11-02"), "2026-11-10")
        XCTAssertEqual(next("every 6 months on the 2nd Wednesday", from: "2026-10-26"), "2027-04-14")
        XCTAssertEqual(next("every Friday on the 13th", from: "2026-10-26"), "2026-11-13")
    }

    func testYearsAndLeapDays() {
        XCTAssertEqual(next("every year", from: "2026-10-26"), "2027-10-26")
        XCTAssertEqual(next("every year", from: "2024-02-29"), "2025-02-28", "a leap day goes to the last of February")
        XCTAssertEqual(next("every 2 years", from: "2024-02-29"), "2026-02-28")
        XCTAssertEqual(next("every 4 years", from: "2024-02-29"), "2028-02-29")
        XCTAssertEqual(next("every January on the 15th", from: "2026-10-26"), "2027-01-15")
        XCTAssertEqual(next("every February on the last", from: "2026-10-26"), "2027-02-28")
        XCTAssertEqual(next("every February on the last", from: "2027-02-28"), "2028-02-29")
        XCTAssertEqual(next("every April and December on the 1st and 24th", from: "2026-10-26"), "2026-12-01")
        XCTAssertEqual(next("every April and December on the 1st and 24th", from: "2026-12-01"), "2026-12-24")
        XCTAssertEqual(next("every April and December on the 1st and 24th", from: "2026-12-24"), "2027-04-01")
        XCTAssertEqual(next("every March", from: "2026-10-26"), "2027-03-26", "on the day of the date")
    }

    func testWhenDone() {
        // Tasks' example: scheduled for 6 February 2021, done a year late.
        XCTAssertEqual(next("every week", from: "2021-02-06", done: "2022-02-13"), "2021-02-13", "from the date, however late")
        XCTAssertEqual(next("every week when done", from: "2021-02-06", done: "2022-02-13"), "2022-02-20", "from the day it was done")
        XCTAssertEqual(next("every 10 days when done", from: "2026-10-01", done: "2026-10-26"), "2026-11-05")
        XCTAssertEqual(next("every Monday when done", from: "2026-10-01", done: "2026-10-26"), "2026-11-02")
        XCTAssertEqual(next("every month when done", from: "2026-09-15", done: "2027-01-31"), "2027-02-28")
        XCTAssertEqual(next("every week WHEN DONE", from: nil, done: "2026-10-26"), "2026-11-02")
        XCTAssertEqual(next("every day", from: nil, done: "2026-10-26"), "2026-10-27", "without a date, from today")
    }

    func testWhatIsNoRule() {
        for text in ["", "weekly", "every", "every 2", "every other week", "every two weeks", "every hour", "every 30 minutes",
                     "every week until December", "every year on week 10", "every 3rd", "every day 📅"] {
            XCTAssertNil(TodoRepeat(text), "“\(text)”")
        }
        // Words rrule doesn't know after a rule it has read are left, as Tasks leaves them.
        XCTAssertEqual(next("every week please", from: "2026-10-26"), "2026-11-02")
        XCTAssertEqual(next("every week #chores", from: "2026-10-26"), "2026-11-02", "a tag after it isn't part of it")
        XCTAssertEqual(next("every day for 3 times", from: "2026-10-26"), "2026-10-27", "Tasks keeps no count")
        XCTAssertNil(TodoRepeat("every month on the 30th")?.next(after: day("2026-02-30"), doneOn: day("2026-02-28")), "a day that doesn't exist has no next")
        XCTAssertNil(TodoRepeat("every February on the 30th")?.next(after: day("2026-10-26"), doneOn: day("2026-10-26")), "nor a rule without one")
    }

    // MARK: - The lines written

    private func ticked(_ line: String, on today: String = "2026-10-26") -> [String]? {
        guard let marked = Todos.marking(line, as: .done, today: day(today)) else { return nil }
        return [marked.next, marked.line].compactMap { $0 }
    }

    func testTickingWritesTheNextOneAboveTheDoneOne() {
        // Tasks' own example, character for character.
        XCTAssertEqual(ticked("- [ ] take out the trash 🔁 every Sunday 📅 2021-04-25", on: "2021-04-24"),
                       ["- [ ] take out the trash 🔁 every Sunday 📅 2021-05-02", "- [x] take out the trash 🔁 every Sunday 📅 2021-04-25 ✅ 2021-04-24"])
        XCTAssertEqual(ticked("- [/] Water the plants 🔁 every week 📅 2026-10-26"),
                       ["- [ ] Water the plants 🔁 every week 📅 2026-11-02", "- [x] Water the plants 🔁 every week 📅 2026-10-26 ✅ 2026-10-26"],
                       "the next one starts again to do")
        XCTAssertEqual(ticked("    * [ ] Feed the cat 🔁 every day 📅 2026-10-26"),
                       ["    * [ ] Feed the cat 🔁 every day 📅 2026-10-27", "    * [x] Feed the cat 🔁 every day 📅 2026-10-26 ✅ 2026-10-26"], "indented")
        XCTAssertEqual(ticked("- [ ] Pay rent 📅 2026-10-26"), ["- [x] Pay rent 📅 2026-10-26"], "one that doesn't repeat is only ticked")
    }

    func testTheDatesKeepTheirDistances() {
        // Tasks' documentation: scheduled two days before it is due, every two weeks.
        XCTAssertEqual(ticked("- [ ] Review ⏳ 2021-10-28 📅 2021-10-30 🔁 every 2 weeks")?.first, "- [ ] Review ⏳ 2021-11-11 📅 2021-11-13 🔁 every 2 weeks")
        XCTAssertEqual(ticked("- [ ] Invoice 🔁 every month 🛫 2026-10-20 📅 2026-10-31")?.first, "- [ ] Invoice 🔁 every month 🛫 2026-11-19 📅 2026-11-30",
                       "the start eleven days before the end of the month")
        XCTAssertEqual(ticked("- [ ] Plan the week 🔁 every week ⏳ 2026-10-26")?.first, "- [ ] Plan the week 🔁 every week ⏳ 2026-11-02", "scheduled only")
        XCTAssertEqual(ticked("- [ ] Stretch 🔁 every week 🛫 2026-10-26")?.first, "- [ ] Stretch 🔁 every week 🛫 2026-11-02", "starting only")
        XCTAssertEqual(ticked("- [ ] Back up 🔁 every week when done ⏳ 2026-10-01", on: "2026-10-26")?.first, "- [ ] Back up 🔁 every week when done ⏳ 2026-11-02")
    }

    func testATimeMovesWithItsDay() {
        XCTAssertEqual(ticked("- [ ] Call mum 🔁 every week ⏰ 2026-10-26 18:00")?.first, "- [ ] Call mum 🔁 every week ⏰ 2026-11-02 18:00")
        XCTAssertEqual(ticked("- [ ] Stand-up 🔁 every weekday 📅 2026-10-30 ⏰ 2026-10-30 09:15")?.first,
                       "- [ ] Stand-up 🔁 every weekday 📅 2026-11-02 ⏰ 2026-11-02 09:15", "the day for Tasks and the time for the Reminder plugin")
        let place = TodoPlace(name: "Gym", latitude: 1, longitude: 2).markdown
        XCTAssertEqual(ticked("- [ ] Swim 🔁 every Monday 📅 2026-10-26 " + place)?.first, "- [ ] Swim 🔁 every Monday 📅 2026-11-02 " + place, "the place stays")
    }

    func testWhatTheNextOneLeavesBehind() {
        // Made today, if it says when it was made; no day it was done or cancelled, no name and nothing it waits for,
        // as Tasks has it, and no block link. The done one isn't cancelled either.
        XCTAssertEqual(ticked("- [ ] Water 🆔 abc123 ⛔ xyz 🔁 every week ➕ 2026-01-01 📅 2026-10-26 ❌ 2026-10-20 ^water"),
                       ["- [ ] Water 🔁 every week ➕ 2026-10-26 📅 2026-11-02",
                        "- [x] Water 🆔 abc123 ⛔ xyz 🔁 every week ➕ 2026-01-01 📅 2026-10-26 ✅ 2026-10-26 ^water"])
        XCTAssertEqual(ticked("- [ ] Stretch 🔁 every day ⏫"), ["- [ ] Stretch 🔁 every day ⏫", "- [x] Stretch 🔁 every day ⏫ ✅ 2026-10-26"],
                       "without a date the next one is the same")
        XCTAssertEqual(ticked("- [ ] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-19"),
                       ["- [ ] Water 🔁 every week 📅 2026-11-02", "- [x] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-26"], "a day it was done before is today")
        XCTAssertEqual(ticked("- [ ] Line break 🔁 every day 📅 2026-10-26  "),
                       ["- [ ] Line break 🔁 every day 📅 2026-10-27  ", "- [x] Line break 🔁 every day 📅 2026-10-26 ✅ 2026-10-26  "])
    }

    func testDataviewsWayIsKept() {
        XCTAssertEqual(ticked("- [ ] Water [repeat:: every week] [due:: 2026-10-26]"),
                       ["- [ ] Water [repeat:: every week] [due:: 2026-11-02]", "- [x] Water [repeat:: every week] [due:: 2026-10-26] [completion:: 2026-10-26]"])
        XCTAssertEqual(ticked("- [ ] Water (repeat:: every week) (scheduled:: 2026-10-26)"),
                       ["- [ ] Water (repeat:: every week) (scheduled:: 2026-11-02)", "- [x] Water (repeat:: every week) (scheduled:: 2026-10-26) (completion:: 2026-10-26)"])
    }

    func testARuleTasksDoesntReadOnlyTicks() {
        XCTAssertEqual(ticked("- [ ] Water 🔁 every other week 📅 2026-10-26"), ["- [x] Water 🔁 every other week 📅 2026-10-26 ✅ 2026-10-26"])
        XCTAssertEqual(ticked("- [ ] Water 🔁 every month 📅 2026-02-30"), ["- [x] Water 🔁 every month 📅 2026-02-30 ✅ 2026-10-26"], "a date that doesn't exist")
    }

    func testUntickingTakesTheDayItWasDone() {
        let today = day("2026-10-27")
        XCTAssertEqual(Todos.marking("- [x] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-26", as: .open, today: today)?.line, "- [ ] Water 🔁 every week 📅 2026-10-26")
        XCTAssertNil(Todos.marking("- [x] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-26", as: .open, today: today)?.next, "and makes no next one")
        XCTAssertEqual(Todos.marking("- [-] Sell the bike ❌ 2026-10-20", as: .inProgress, today: today)?.line, "- [/] Sell the bike")
        XCTAssertEqual(Todos.marking("- [x] Book [completion:: 2026-10-20]", as: .open, today: today)?.line, "- [ ] Book")
        XCTAssertEqual(Todos.marking("- [x] Water 🔁 every week ✅ 2026-10-26", as: .cancelled, today: today)?.line, "- [-] Water 🔁 every week",
                       "cancelled isn't done")
        XCTAssertEqual(Todos.marking("- [-] Water ❌ 2026-10-20", as: .done, today: today)?.line, "- [x] Water", "nor done cancelled")
        XCTAssertNil(Todos.marking("- [x] Done", as: .done, today: today), "nothing to change")
    }

    // MARK: - In the note

    private func apply(_ text: String, line: Int, _ mark: TaskMark, today: String = "2026-10-26") -> String {
        let string = text as NSString
        guard let change = Todos.marking(in: string, document: MarkdownParser.parse(string), line: line, as: mark, today: day(today)) else { return text }
        return string.replacingCharacters(in: change.range, with: change.replacement)
    }

    func testTickingUntickingAndTickingAgainMakesOneNextOne() {
        let note = "# Home\n- [ ] Water the plants 🔁 every week 📅 2026-10-26\n    - the fern too\n- [ ] Call mum"
        let ticked = apply(note, line: 1, .done)
        XCTAssertEqual(ticked, "# Home\n- [ ] Water the plants 🔁 every week 📅 2026-11-02\n- [x] Water the plants 🔁 every week 📅 2026-10-26 ✅ 2026-10-26\n    - the fern too\n- [ ] Call mum",
                       "the lines under it stay with the done one, as in Tasks")
        let unticked = apply(ticked, line: 2, .open)
        XCTAssertEqual(unticked, "# Home\n- [ ] Water the plants 🔁 every week 📅 2026-11-02\n- [ ] Water the plants 🔁 every week 📅 2026-10-26\n    - the fern too\n- [ ] Call mum",
                       "unticking makes no next one, and leaves the one there")
        XCTAssertEqual(apply(unticked, line: 2, .done), ticked, "ticked again: the next one is there already")
        // In Obsidian with the next one below, set in Tasks' settings.
        let below = "- [ ] Water 🔁 every week 📅 2026-10-26\n- [ ] Water 🔁 every week 📅 2026-11-02"
        XCTAssertEqual(apply(below, line: 0, .done), "- [x] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-26\n- [ ] Water 🔁 every week 📅 2026-11-02")
    }

    func testTheChangeIsSmall() throws {
        let text = "- [ ] Water the plants 🔁 every week 📅 2026-10-26" as NSString
        let change = try XCTUnwrap(Todos.marking(in: text, document: MarkdownParser.parse(text), line: 0, as: .done, today: day("2026-10-26")))
        XCTAssertGreaterThan(change.range.location, ("- [ ] Water the plants" as NSString).length, "the words before the date aren't touched")
        // Never between the halves of an emoji.
        let emoji = try XCTUnwrap(Todos.smallestChange(from: "a 📅 b", to: "a 📍 b", at: 0))
        XCTAssertEqual(emoji.range, NSRange(location: 2, length: 2))
        XCTAssertEqual(emoji.replacement, "📍")
    }

    func testTakingBackATick() {
        let note = "- [ ] Water 🔁 every week 📅 2026-11-02\n- [x] Water 🔁 every week 📅 2026-10-26 ✅ 2026-10-26\n- [ ] Call mum" as NSString
        func takeBack(next: String?) -> String {
            let change = Todos.takingBack(in: note, document: MarkdownParser.parse(note), line: 1, to: "- [ ] Water 🔁 every week 📅 2026-10-26", next: next)!
            return note.replacingCharacters(in: change.range, with: change.replacement)
        }
        XCTAssertEqual(takeBack(next: "- [ ] Water 🔁 every week 📅 2026-11-02"), "- [ ] Water 🔁 every week 📅 2026-10-26\n- [ ] Call mum")
        XCTAssertEqual(takeBack(next: "- [ ] Water 🔁 every week 📅 2026-11-09"), "- [ ] Water 🔁 every week 📅 2026-11-02\n- [ ] Water 🔁 every week 📅 2026-10-26\n- [ ] Call mum",
                       "a line above that isn't the one written stays")
        XCTAssertEqual(takeBack(next: nil), "- [ ] Water 🔁 every week 📅 2026-11-02\n- [ ] Water 🔁 every week 📅 2026-10-26\n- [ ] Call mum",
                       "the next one was there before: it stays")
    }
}
