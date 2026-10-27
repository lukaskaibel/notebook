import XCTest
@testable import NotebookKit

/// Remind Me's typed times, read on Thursday 22 October 2026 at 14:10 in Berlin.
final class ReminderTimeParserTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private var now: Date { at(22, 10, 14, 10) }

    private func at(_ day: Int, _ month: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// With plain spaces where the system writes narrow ones, as before "PM".
    private func read(_ text: String) -> [ReminderTimeParser.Suggestion] {
        ReminderTimeParser.suggestions(for: text, now: now, calendar: calendar).map { suggestion in
            var suggestion = suggestion
            suggestion.title = suggestion.title.replacingOccurrences(of: "\u{202F}", with: " ")
            suggestion.detail = suggestion.detail.replacingOccurrences(of: "\u{202F}", with: " ")
            return suggestion
        }
    }

    private func first(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> ReminderTimeParser.Suggestion {
        try XCTUnwrap(read(text).first, "nothing for “\(text)”", file: file, line: line)
    }

    func testDayAndTimeOfDay() throws {
        for text in ["thursday evening", "Thursday Evening", "thu eve", "thurs e", "evening on thursday", "thursday at 6pm", "thursday 18:00"] {
            XCTAssertEqual(try first(text).date, at(29, 10, 18), text)
        }
        XCTAssertEqual(try first("thursday evening").title, "Thursday Evening")
        XCTAssertEqual(try first("tomorrow morning").title, "Tomorrow Morning")
        XCTAssertEqual(try first("tomorrow morning").date, at(23, 10, 9))
        XCTAssertEqual(try first("fri noon").title, "Friday at Noon")
        XCTAssertEqual(try first("friday in the evening").date, at(23, 10, 18))
        XCTAssertEqual(try first("friday at night").title, "Friday Night")
        XCTAssertEqual(try first("next tuesday afternoon").date, at(27, 10, 15))
        XCTAssertEqual(try first("next tuesday afternoon").title, "Next Tuesday Afternoon")
    }

    func testTimesOfToday() throws {
        XCTAssertEqual(try first("evening").title, "This Evening")
        XCTAssertEqual(try first("evening").date, at(22, 10, 18))
        XCTAssertEqual(try first("this afternoon").date, at(22, 10, 15))
        XCTAssertEqual(try first("tonight").title, "Tonight")
        XCTAssertEqual(try first("tonight").date, at(22, 10, 21))
        // The morning is over: tomorrow's.
        XCTAssertEqual(try first("morning").title, "Tomorrow Morning")
        XCTAssertEqual(try first("morning").date, at(23, 10, 9))
        // Today alone is about three hours on, as Later Today is.
        XCTAssertEqual(try first("today").date, at(22, 10, 17))
    }

    func testClockTimes() throws {
        XCTAssertEqual(read("tomorrow at 9").map(\.date), [at(23, 10, 9), at(23, 10, 21)])
        XCTAssertEqual(try first("tomorrow at 9").title, "Tomorrow at 9:00 AM")
        XCTAssertEqual(try first("fri 3pm").date, at(23, 10, 15))
        XCTAssertEqual(try first("3pm fri").date, at(23, 10, 15))
        XCTAssertEqual(try first("fri 3:30 pm").date, at(23, 10, 15, 30))
        XCTAssertEqual(try first("fri @ 21.45").date, at(23, 10, 21, 45))
        XCTAssertEqual(try first("12am").date, at(23, 10, 0))
        // A 9 that could be either: the next one first. 4 o'clock in the morning has passed, 4 in the afternoon not.
        XCTAssertEqual(read("9").prefix(2).map(\.date), [at(22, 10, 21), at(23, 10, 9)])
        XCTAssertEqual(read("4").prefix(2).map(\.date), [at(22, 10, 16), at(23, 10, 4)])
        // The ninth of the month comes after the times.
        XCTAssertEqual(read("9").dropFirst(2).first?.date, at(9, 11, 9))
        // As you type the minutes.
        XCTAssertEqual(try first("tomorrow 9:3").date, at(23, 10, 9, 30))
        XCTAssertTrue(read("25:00").isEmpty)
    }

    func testCountsFromNow() throws {
        XCTAssertEqual(try first("in 3 weeks").date, at(12, 11, 9))
        XCTAssertEqual(try first("in 3 weeks").title, "In 3 Weeks")
        XCTAssertEqual(try first("3w").date, at(12, 11, 9))
        XCTAssertEqual(try first("in 2 days").date, at(24, 10, 9))
        XCTAssertEqual(try first("in a month").date, at(22, 11, 9))
        XCTAssertEqual(try first("in 2 hours").date, at(22, 10, 16, 10))
        XCTAssertEqual(try first("in 2 hours").title, "In 2 Hours")
        XCTAssertEqual(try first("in an hour").date, at(22, 10, 15, 10))
        XCTAssertEqual(try first("in an hour").title, "In 1 Hour")
        XCTAssertEqual(try first("30 min").date, at(22, 10, 14, 40))
        XCTAssertEqual(try first("in half an hour").date, at(22, 10, 14, 40))
        XCTAssertEqual(try first("in 2 days at 5pm").date, at(24, 10, 17))
        // Without a unit yet, every one.
        XCTAssertEqual(read("in 3").map(\.title), ["In 3 Minutes", "In 3 Hours", "In 3 Days", "In 3 Weeks", "In 3 Months", "In 3 Years"])
    }

    func testDaysByName() throws {
        // Weekdays are the coming ones, from tomorrow; today's is next week's.
        XCTAssertEqual(try first("friday").date, at(23, 10, 9))
        XCTAssertEqual(try first("friday").title, "Friday")
        XCTAssertEqual(try first("thursday").date, at(29, 10, 9))
        XCTAssertEqual(try first("next week").date, at(26, 10, 9))
        XCTAssertEqual(try first("next month").date, at(22, 11, 9))
        XCTAssertEqual(try first("weekend").date, at(24, 10, 9))
        XCTAssertEqual(try first("end of month").date, at(31, 10, 9))
        XCTAssertEqual(try first("day after tomorrow").title, "Saturday")
        XCTAssertEqual(try first("tom").title, "Tomorrow")
        // A day alone, as you type it, comes also in the afternoon and the evening.
        XCTAssertEqual(read("fri").map(\.title), ["Friday", "Friday Afternoon", "Friday Evening"])
        XCTAssertEqual(read("next mo").map(\.title).prefix(2), ["Next Month", "Next Monday"])
        XCTAssertEqual(try first("this friday").date, at(23, 10, 9))
        // A phrase of several words comes once its first word is there.
        XCTAssertEqual(read("t").map(\.title).prefix(4), ["Today", "Tomorrow", "Tuesday", "Thursday"])
        XCTAssertEqual(try first("e").title, "This Evening")
        XCTAssertEqual(try first("next").title, "Next Week")
    }

    func testDatesTypedOut() throws {
        for text in ["12.11.", "12.11.2026", "11/12", "nov 12", "12 november", "November 12th", "the 12th", "on the 12th", "2026-11-12"] {
            XCTAssertEqual(try first(text).date, at(12, 11, 9), text)
        }
        XCTAssertEqual(try first("12.11.").title, "Thursday, November 12")
        XCTAssertEqual(try first("12.11.").detail, "9:00 AM")
        XCTAssertEqual(try first("12.11. 14:30").date, at(12, 11, 14, 30))
        XCTAssertEqual(try first("nov 12 2pm").date, at(12, 11, 14))
        // Gone this year: next year's.
        XCTAssertEqual(try first("1.10.").date, at(1, 10, 9, year: 2027))
        XCTAssertEqual(try first("1.10.").title, "Friday, October 1, 2027")
        XCTAssertTrue(read("31.2.").isEmpty)
    }

    func testDetails() throws {
        XCTAssertEqual(try first("evening").detail, "6:00 PM")
        XCTAssertEqual(try first("tomorrow evening").detail, "Fri 6:00 PM")
        XCTAssertEqual(try first("in 3 weeks").detail, "Thu, Nov 12 at 9:00 AM")
        XCTAssertEqual(try first("evening").symbol, "moon")
        XCTAssertEqual(try first("tomorrow").symbol, "sunrise")
        XCTAssertEqual(try first("in 3 weeks").symbol, "calendar")
        XCTAssertEqual(try first("in 2 hours").symbol, "clock")
    }

    func testNothingToRead() {
        for text in ["", "  ", "xyz", "hello world", "at", "in", "31.13."] {
            XCTAssertTrue(read(text).isEmpty, text)
        }
        // Only what is still to come.
        XCTAssertTrue(read("this morning").allSatisfy { $0.date > now })
    }

    func testWeekdayInWeeksToCome() throws {
        // Thursday 22 October: three weeks on is Thursday 12 November, in the week of Sunday 8 November.
        for text in ["thursday in 3 weeks", "thu in 3 weeks", "in 3 weeks on thursday", "in 3 weeks thursday", "thursday in 3w"] {
            XCTAssertEqual(try first(text).date, at(12, 11, 9), text)
        }
        XCTAssertEqual(try first("thursday in 3 weeks").title, "Thursday in 3 Weeks")
        XCTAssertEqual(try first("monday in 2 weeks").date, at(2, 11, 9))
        XCTAssertEqual(try first("saturday in 2 weeks evening").date, at(7, 11, 18))
        // As you type the unit.
        XCTAssertEqual(try first("fri in 2 we").date, at(6, 11, 9))
        // Next week's: next Thursday, Thursday 29 October.
        for text in ["next week on thursday", "next week thursday", "thursday next week", "thu next week", "next week on thu", "thursday next we"] {
            XCTAssertEqual(try first(text).date, at(29, 10, 9), text)
            XCTAssertEqual(try first(text).title, "Next Thursday", text)
        }
        XCTAssertEqual(try day("next week on monday").date, at(26, 10, 0))
        XCTAssertEqual(try first("next week on friday evening").date, at(30, 10, 18))
    }

    /// A to-do's date: a day stays a day, today too, and a time makes it a time.
    private func day(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> ReminderTimeParser.Suggestion {
        try XCTUnwrap(ReminderTimeParser.suggestions(for: text, now: now, calendar: calendar, days: true).first, "nothing for “\(text)”", file: file, line: line)
    }

    func testTypedDatesAreGregorianWhicheverCalendarShows() throws {
        for identifier in [Calendar.Identifier.japanese, .buddhist] {
            var shown = Calendar(identifier: identifier)
            shown.timeZone = calendar.timeZone
            shown.locale = calendar.locale
            for text in ["1 November 2026", "1.11.2026", "1 nov"] {
                let found = try XCTUnwrap(ReminderTimeParser.suggestions(for: text, now: now, calendar: shown, days: true).first, "\(identifier) “\(text)”")
                XCTAssertEqual(found.date, at(1, 11, 0), "\(identifier) “\(text)”")
            }
        }
    }

    func testDaysForToDos() throws {
        XCTAssertEqual(try day("friday").date, at(23, 10, 0))
        XCTAssertFalse(try day("friday").hasTime)
        XCTAssertEqual(try day("friday").detail, "Fri, Oct 23")
        XCTAssertEqual(try day("today").date, at(22, 10, 0))
        XCTAssertEqual(try day("today").symbol, "star")
        XCTAssertEqual(try day("thursday in 3 weeks").date, at(12, 11, 0))
        XCTAssertEqual(try day("12.11.").title, "Thursday, November 12")
        XCTAssertEqual(try day("12.11.").detail, "In 21 Days")
        // A number is a day of the month first.
        XCTAssertEqual(try day("12").date, at(12, 11, 0))
        // No afternoon or evening of a day alone.
        XCTAssertEqual(ReminderTimeParser.suggestions(for: "fri", now: now, calendar: calendar, days: true).map(\.title), ["Friday"])
        XCTAssertEqual(try day("friday 3pm").date, at(23, 10, 15))
        XCTAssertTrue(try day("friday 3pm").hasTime)
    }

    func testTimesWithoutADay() {
        XCTAssertEqual(ReminderTimeParser.times(for: "9").map(\.hour), [9, 21])
        XCTAssertEqual(ReminderTimeParser.times(for: "eve").map(\.hour), [18])
        XCTAssertEqual(ReminderTimeParser.times(for: "3:30pm").map { [$0.hour, $0.minute] }, [[15, 30]])
        XCTAssertTrue(ReminderTimeParser.times(for: "friday").isEmpty)
        XCTAssertEqual(ReminderTimeParser.times(for: "930").map { [$0.hour, $0.minute] }, [[9, 30], [21, 30]])
        XCTAssertEqual(ReminderTimeParser.times(for: "1430").map { [$0.hour, $0.minute] }, [[14, 30]])
        XCTAssertEqual(ReminderTimeParser.times(for: "745pm").map { [$0.hour, $0.minute] }, [[19, 45]])
    }

    func testTwentyFourHours() throws {
        calendar.locale = Locale(identifier: "de_DE")
        XCTAssertEqual(try first("18:30").date, at(22, 10, 18, 30))
        XCTAssertEqual(try first("18:30").title, "Today at 18:30")
        // Days are written day first in Germany.
        XCTAssertEqual(try first("12/11").date, at(12, 11, 9))
    }
}
