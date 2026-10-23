import Foundation

/// Reads the time of a reminder typed in a few words, as Issues reads due dates: "thursday evening", "tomorrow at 9",
/// "fri 3pm", "in 3 weeks", "in 2 hours", "next monday", "the 12th", "12.11. 14:30" or "nov 12". The last word may be
/// cut short as you type ("thu eve", "next mo"). A day without a time is at nine in the morning, as Tomorrow is, and
/// today in about three hours, as Later Today is; a time without a day is the next time it comes round. The words are
/// English, as the app is; months are also read in the language of the calendar.
enum ReminderTimeParser {
    struct Suggestion: Hashable {
        /// "Thursday Evening", "In 3 Weeks", "Thursday, 12 November".
        var title: String
        /// When it is, as far as the title doesn't say: "6:00 PM", "Thu 6:00 PM", "Thu, Nov 12 at 9:00 AM".
        var detail: String
        var symbol: String
        var date: Date
    }

    /// The hours of the times of day. Nine is also a day's time when none is typed.
    static let morning = 9, noon = 12, afternoon = 15, evening = 18, night = 21

    /// What the text could mean, best first, and only times still to come. Empty when it reads as no time at all.
    static func suggestions(for query: String, now: Date, calendar: Calendar = .current, limit: Int = 6) -> [Suggestion] {
        var words = fold(query)
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        // "friday at", while the time is still to come.
        while let last = words.last, ["at", "@", "on"].contains(last) { words.removeLast() }
        guard !words.isEmpty else { return [] }
        let reader = Reader(now: now, calendar: calendar)
        var found = reader.countdowns(words)
        // The whole text as a day or a time. A number is more likely a time ("9") than a day of the month.
        let days = reader.days(words, isLast: true).compactMap { reader.suggestion($0, nil) }
        let times = reader.times(words, isLast: true).compactMap { reader.suggestion(nil, $0) }.sorted { $0.date < $1.date }
        found += words[0].first?.isNumber == true ? times + days : days + times
        // A day and a time, in either order: "thursday evening", "tomorrow at 9", "9am tomorrow".
        for split in words.indices.dropFirst() {
            let head = Array(words[..<split]), tail = Array(words[split...])
            for day in reader.days(head, isLast: false) {
                found += reader.times(tail, isLast: true).compactMap { reader.suggestion(day, $0) }
            }
            for time in reader.times(head, isLast: false) {
                // "9pm 12" is no way to write a date.
                found += reader.days(tail, isLast: true).filter { $0.title != nil }.compactMap { reader.suggestion($0, time) }
            }
        }
        // A weekday alone at the end, as you type it, also in the afternoon and the evening.
        found += reader.days(words, isLast: true).filter(\.isNamed).flatMap { day in
            [Reader.afternoon, Reader.evening].compactMap { reader.suggestion(day, $0) }
        }
        var seen = Set<Date>()
        return Array(found.filter { seen.insert($0.date).inserted }.prefix(limit))
    }

    /// Lower case and without accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Reading

    /// A day the text names: its start, and what to call it.
    struct Day {
        /// "Thursday", "In 3 Weeks"; nil for a date typed out, which is shown as the date.
        var title: String?
        var start: Date
        /// Today, tomorrow or a weekday, which go with the time of day in a few words: "Thursday Evening".
        var isNamed = false
    }

    /// A time of day the text names.
    struct Time {
        var hour: Int
        var minute = 0
        /// What follows a day's name: "Evening", "at Noon". Nil for a time on the clock.
        var words: String?
    }

    struct Reader {
        var now: Date
        var calendar: Calendar

        static let morning = Time(hour: ReminderTimeParser.morning, words: "Morning")
        static let noon = Time(hour: ReminderTimeParser.noon, words: "at Noon")
        static let afternoon = Time(hour: ReminderTimeParser.afternoon, words: "Afternoon")
        static let evening = Time(hour: ReminderTimeParser.evening, words: "Evening")
        static let night = Time(hour: ReminderTimeParser.night, words: "Night")

        private var today: Date { calendar.startOfDay(for: now) }

        // MARK: Days

        /// The days the words could name. With `isLast`, the last word may be the start of one.
        func days(_ words: [String], isLast: Bool) -> [Day] {
            var words = words
            // "on the 12th", "this friday".
            while let first = words.first, ["on", "the"].contains(first) || first == "this" && words.count > 1 { words.removeFirst() }
            guard !words.isEmpty else { return [] }
            let text = words.joined(separator: " ")
            return named(text, isLast: isLast) + counted(text, isLast: isLast)
                + typedOut(text, isLast: isLast).map { Day(start: $0) }
        }

        private func named(_ text: String, isLast: Bool) -> [Day] {
            var phrases: [(names: [String], day: Day)] = []
            func add(_ names: [String], _ title: String, _ offset: Int, isNamed: Bool = true) {
                phrases.append((names, Day(title: title, start: day(offset), isNamed: isNamed)))
            }
            // "tonight 9" is today; alone, tonight is a time.
            add(isLast ? ["today"] : ["today", "tonight"], "Today", 0)
            add(["tomorrow", "tmrw", "tmr", "tom"], "Tomorrow", 1)
            add(["day after tomorrow"], weekday(day(2)), 2)
            // The coming weekdays in order, starting tomorrow.
            let weekdays = Self.weekdayNames
            for offset in 1...7 {
                add(weekdays[calendar.component(.weekday, from: day(offset)) - 1], weekday(day(offset)), offset)
            }
            let monday = nextWeek
            phrases.append((["next week"], Day(title: "Next Week", start: monday)))
            if let month = calendar.date(byAdding: .month, value: 1, to: today) {
                phrases.append((["next month"], Day(title: "Next Month", start: month)))
            }
            for offset in 0..<7 {
                let start = day(offset, from: monday)
                let names = weekdays[calendar.component(.weekday, from: start) - 1].map { "next " + $0 }
                phrases.append((names, Day(title: "Next " + weekday(start), start: start, isNamed: true)))
            }
            let saturday = (1...7).first { calendar.component(.weekday, from: day($0)) == 7 } ?? 1
            add(["weekend", "this weekend"], "This Weekend", saturday, isNamed: false)
            let friday = (0...6).first { calendar.component(.weekday, from: day($0)) == 6 } ?? 0
            add(["end of week", "end of the week"], "End of Week", friday, isNamed: false)
            if let month = calendar.dateInterval(of: .month, for: now), let last = calendar.date(byAdding: .day, value: -1, to: month.end) {
                phrases.append((["end of month", "end of the month"], Day(title: "End of Month", start: calendar.startOfDay(for: last))))
            }
            return phrases
                .filter { Self.matches($0.names, text, isLast: isLast) }
                .map(\.day)
        }

        /// "in 3 days", "3 weeks", "2w", "+3d", "in a month": a count of days, weeks, months or years from today.
        /// Without a unit, after "in", every unit is offered.
        private func counted(_ text: String, isLast: Bool) -> [Day] {
            guard let (count, unit) = Self.count(text) else { return [] }
            let units: [(names: [String], component: Calendar.Component, title: String)] = [
                (["days", "day", "d"], .day, "Day"),
                (["weeks", "week", "wks", "wk", "w"], .weekOfYear, "Week"),
                (["months", "month", "mos", "mo"], .month, "Month"),
                (["years", "year", "yrs", "yr", "y"], .year, "Year"),
            ]
            return units
                .filter { option in unit.isEmpty ? isLast : option.names.contains { $0 == unit || isLast && $0.hasPrefix(unit) } }
                .compactMap { option in
                    calendar.date(byAdding: option.component, value: count, to: today).map {
                        Day(title: "In \(count) \(option.title)\(count == 1 ? "" : "s")", start: $0)
                    }
                }
        }

        // MARK: Times

        /// The times of day the words could name: "evening", "noon", "9", "9:30pm", "21:30". With `isLast`, the last
        /// word may be the start of one.
        func times(_ words: [String], isLast: Bool) -> [Time] {
            var words = words
            if let first = words.first, first.hasPrefix("@") { words[0] = String(first.dropFirst()) }
            while let first = words.first, ["", "at", "around", "in", "the"].contains(first) {
                // "in" only as in "in the evening": "in 3" is a count.
                if first == "in", words.dropFirst().first != "the" { break }
                words.removeFirst()
            }
            guard !words.isEmpty else { return [] }
            let text = words.joined(separator: " ")
            let named: [(names: [String], time: Time)] = [
                (["morning", "morn", "this morning"], Self.morning),
                (["noon", "midday", "lunch", "lunchtime"], Self.noon),
                (["afternoon", "this afternoon"], Self.afternoon),
                (["evening", "eve", "this evening"], Self.evening),
                (["night", "tonight", "tonite"], Self.night),
            ]
            let found = named
                .filter { Self.matches($0.names, text, isLast: isLast) }
                .map(\.time)
            return found + clock(text, isLast: isLast)
        }

        /// "9", "9pm", "9 a", "9:30", "21:30", "21.30": both 9 and 21 for a 9 that could be either.
        private func clock(_ text: String, isLast: Bool) -> [Time] {
            guard let match = text.wholeMatch(of: #/(\d{1,2})(?:(:|\.)(\d{0,2}))?\s?(a|am|a\.m\.?|p|pm|p\.m\.?)?/#),
                  let hour = Int(match.output.1) else { return [] }
            var minute = 0
            if let digits = match.output.3 {
                // Two digits. As you type after a colon, the first one alone stands for the tens; after a dot it
                // could as well be a date ("12.1" on the way to "12.10.").
                let complete = digits.count == 2
                guard complete || isLast && match.output.2 == ":" else { return [] }
                minute = (Int(digits) ?? 0) * (complete ? 1 : 10)
                guard minute < 60 else { return [] }
            }
            if let half = match.output.4 {
                guard (1...12).contains(hour) else { return [] }
                let evening = half.hasPrefix("p")
                return [Time(hour: hour % 12 + (evening ? 12 : 0), minute: minute)]
            }
            switch hour {
            case 1...11: return [Time(hour: hour, minute: minute), Time(hour: hour + 12, minute: minute)]
            case 0, 12...23: return [Time(hour: hour, minute: minute)]
            default: return []
            }
        }

        /// "in 2 hours", "30 min", "2h", "in an hour", "in half an hour": a count of minutes or hours from now.
        func countdowns(_ words: [String]) -> [Suggestion] {
            let text = words.joined(separator: " ")
            let half = ["in half an hour", "half an hour", "half hour"].contains { $0.hasPrefix(text) && text.count >= 6 }
            guard let (count, unit) = half ? (30, "minutes") : Self.count(text) else { return [] }
            let units: [(names: [String], minutes: Int, title: String)] = [
                (["minutes", "minute", "mins", "min"], 1, "Minute"),
                (["hours", "hour", "hrs", "hr", "h"], 60, "Hour"),
            ]
            guard let start = calendar.dateInterval(of: .minute, for: now)?.start else { return [] }
            return units
                .filter { option in unit.isEmpty || option.names.contains { $0.hasPrefix(unit) } }
                .map { option in
                    let date = start.addingTimeInterval(TimeInterval(count * option.minutes * 60))
                    return Suggestion(title: "In \(count) \(option.title)\(count == 1 ? "" : "s")", detail: detail(date), symbol: "clock", date: date)
                }
        }

        /// A count and its unit as typed so far: "in 3 days" is 3 and "days", "2w" 2 and "w", "in a" 1 and "". Nil
        /// for a number alone, which is more likely a day of the month or a time.
        static func count(_ text: String) -> (Int, String)? {
            var rest = Substring(text)
            var isCount = false
            if rest.hasPrefix("in ") { rest = rest.dropFirst(3); isCount = true }
            if rest.hasPrefix("+") { rest = rest.dropFirst(); isCount = true }
            let count: Int
            if let article = ["an ", "a "].first(where: { rest.hasPrefix($0) }) ?? (isCount && ["a", "an"].contains(rest) ? String(rest) : nil) {
                count = 1
                rest = rest.dropFirst(article.count)
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard let value = Int(digits), value > 0, value < 1000 else { return nil }
                count = value
                rest = rest.dropFirst(digits.count)
            }
            let unit = rest.trimmingCharacters(in: .whitespaces)
            guard isCount || !unit.isEmpty, unit.allSatisfy(\.isLetter) else { return nil }
            return (count, unit)
        }

        // MARK: Dates typed out

        /// "2026-11-12", "12.11.", "12.11.2026", "11/12" (in the order of this device's dates), "nov 12", "12 nov",
        /// "12th", "12": the start of the day, the next time it comes round when there is no year.
        private func typedOut(_ text: String, isLast: Bool) -> [Date] {
            func numbers(_ string: String, separator: Character) -> [Int]? {
                let parts = string.split(separator: separator, omittingEmptySubsequences: false)
                var values: [Int] = []
                for (index, part) in parts.enumerated() {
                    // "12.11." ends in a separator.
                    if part.isEmpty, index == parts.count - 1, index > 0 { continue }
                    guard let value = Int(part) else { return nil }
                    values.append(value)
                }
                return values
            }
            if let parts = numbers(text, separator: "-"), parts.count == 3, parts[0] > 999 {
                return date(year: parts[0], month: parts[1], day: parts[2]).map { [$0] } ?? []
            }
            // Day first, as in most of Europe.
            if text.contains("."), let parts = numbers(text, separator: "."), (2...3).contains(parts.count) {
                return dated(day: parts[0], month: parts[1], year: parts.count == 3 ? parts[2] : nil)
            }
            if text.contains("/"), let parts = numbers(text, separator: "/"), (2...3).contains(parts.count) {
                let monthFirst = Self.monthComesFirst(calendar.locale ?? .current)
                return dated(day: monthFirst ? parts[1] : parts[0], month: monthFirst ? parts[0] : parts[1], year: parts.count == 3 ? parts[2] : nil)
            }
            // 12, 12th, and 12t as you type it: the next 12th.
            if let day = Self.dayOfMonth(text, isLast: isLast) {
                return nextDayOfMonth(day)
            }
            // nov 12, 12 november, 12. nov 2027, november 12th
            let words = text.replacingOccurrences(of: ".", with: " ").split(separator: " ").map(String.init)
            guard (2...3).contains(words.count) else { return [] }
            let numbers = words.compactMap { Self.dayOfMonth($0, isLast: false) ?? Int($0) }
            let names = words.filter { Self.dayOfMonth($0, isLast: false) == nil && Int($0) == nil }
            guard names.count == 1, numbers.count == words.count - 1,
                  let month = month(named: names[0]), let day = numbers.first else { return [] }
            return dated(day: day, month: month, year: numbers.count == 2 ? numbers[1] : nil)
        }

        /// "12", "12th", "1st", and while typing "12t".
        private static func dayOfMonth(_ text: String, isLast: Bool) -> Int? {
            guard let match = text.wholeMatch(of: #/(\d{1,2})(st|nd|rd|th|s|n|r|t)?/#), let day = Int(match.output.1),
                  (1...31).contains(day) else { return nil }
            if let suffix = match.output.2, suffix.count == 1, !isLast { return nil }
            return day
        }

        private func nextDayOfMonth(_ day: Int) -> [Date] {
            let parts = calendar.dateComponents([.year, .month], from: today)
            for months in 0...2 {
                guard let first = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)),
                      let month = calendar.date(byAdding: .month, value: months, to: first) else { continue }
                let shown = calendar.dateComponents([.year, .month], from: month)
                if let candidate = date(year: shown.year ?? 0, month: shown.month ?? 0, day: day), candidate >= today {
                    return [candidate]
                }
            }
            return []
        }

        private func dated(day: Int, month: Int, year: Int?) -> [Date] {
            if var year {
                if year < 100 { year += 2000 }
                return date(year: year, month: month, day: day).map { [$0] } ?? []
            }
            // Without a year, the next time that day comes round.
            let thisYear = calendar.component(.year, from: today)
            for year in [thisYear, thisYear + 1] {
                if let candidate = date(year: year, month: month, day: day), candidate >= today {
                    return [candidate]
                }
            }
            return []
        }

        /// The start of a day that exists, so 31 February is turned down.
        private func date(year: Int, month: Int, day: Int) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day) else { return nil }
            return date
        }

        /// "nov", "november", "sept": three letters or more of a month's name.
        private func month(named word: String) -> Int? {
            guard word.count >= 3 else { return nil }
            var english = Calendar(identifier: .gregorian)
            english.locale = Locale(identifier: "en_US_POSIX")
            for names in [english.monthSymbols, calendar.monthSymbols, calendar.shortMonthSymbols] {
                if let index = names.firstIndex(where: { ReminderTimeParser.fold($0).replacingOccurrences(of: ".", with: "").hasPrefix(word) }) {
                    return index + 1
                }
            }
            return nil
        }

        private static func monthComesFirst(_ locale: Locale) -> Bool {
            let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? "M/d"
            guard let month = format.firstIndex(of: "M"), let day = format.firstIndex(of: "d") else { return true }
            return month < day
        }

        // MARK: Together

        /// The reminder for a day at a time, or nil when that has passed. Without a day, the next time it comes
        /// round; without a time, a day's morning, or today in about three hours.
        func suggestion(_ day: Day?, _ time: Time?) -> Suggestion? {
            let date: Date
            var day = day
            if let day, let time {
                guard let found = at(time, on: day.start) else { return nil }
                date = found
            } else if let time {
                let isToday = at(time, on: today).map { $0 > now } ?? false
                let start = isToday ? today : self.day(1)
                guard let found = at(time, on: start) else { return nil }
                date = found
                day = Day(title: isToday ? "Today" : "Tomorrow", start: start, isNamed: true)
            } else if let day {
                if day.start == today {
                    // As Later Today: on the hour, about three hours on, or the next hour late in the day.
                    let later = ReminderForm.nextHour(after: now.addingTimeInterval(2 * 60 * 60), calendar: calendar)
                    let soon = ReminderForm.nextHour(after: now, calendar: calendar)
                    guard let found = [later, soon].first(where: { calendar.isDate($0, inSameDayAs: now) }) else { return nil }
                    date = found
                } else {
                    guard let found = at(Self.morning, on: day.start) else { return nil }
                    date = found
                }
            } else {
                return nil
            }
            guard date > now, let day else { return nil }
            return Suggestion(title: title(day, time, date), detail: detail(date, typedOut: day.title == nil), symbol: symbol(date), date: date)
        }

        private func at(_ time: Time, on day: Date) -> Date? {
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
        }

        private func title(_ day: Day, _ time: Time?, _ date: Date) -> String {
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let name = day.title ?? date.formatted(sameYear ? style.weekday(.wide).day().month(.wide) : style.weekday(.wide).day().month(.wide).year())
            guard let time else { return name }
            guard let words = time.words, day.isNamed else { return "\(name) at \(clock(date))" }
            if day.start == today {
                switch time.hour {
                case Self.morning.hour: return "This Morning"
                case Self.afternoon.hour: return "This Afternoon"
                case Self.evening.hour: return "This Evening"
                case Self.night.hour: return "Tonight"
                default: break
                }
            }
            return "\(name) \(words)"
        }

        /// The time, with the weekday for another day in the coming week and the date for one further off.
        func detail(_ date: Date, typedOut: Bool = false) -> String {
            let clock = clock(date)
            if typedOut || calendar.isDate(date, inSameDayAs: now) { return clock }
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            if days < 7 { return date.formatted(style.weekday(.abbreviated)) + " " + clock }
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let dated = style.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            return date.formatted(sameYear ? dated : dated.year())
        }

        /// The sunrise in the morning, the sun by day, the moon in the evening, and a calendar for a day further
        /// than a week off.
        private func symbol(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            if days >= 7 { return "calendar" }
            let hour = calendar.component(.hour, from: date)
            return hour < 12 ? "sunrise" : hour < 17 ? "sun.max" : "moon"
        }

        // MARK: Helpers

        /// Whether the text is one of the names, or with `isLast` the start of one. A name of several words only once
        /// its first is typed out: "t" isn't yet "this evening", nor "e" "end of week".
        static func matches(_ names: [String], _ text: String, isLast: Bool) -> Bool {
            names.contains { name in
                name == text || isLast && name.hasPrefix(text) && (!name.contains(" ") || text.contains(" ") || name.hasPrefix(text + " "))
            }
        }

        private var style: Date.FormatStyle {
            Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        }

        private func clock(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone))
        }

        /// "Friday", as a choice in a list.
        private func weekday(_ date: Date) -> String {
            var style = style.weekday(.wide)
            style.capitalizationContext = .listItem
            return date.formatted(style)
        }

        private func day(_ offset: Int, from start: Date? = nil) -> Date {
            calendar.date(byAdding: .day, value: offset, to: start ?? today) ?? today
        }

        /// The Monday after this week.
        private var nextWeek: Date {
            let weekday = calendar.component(.weekday, from: today)
            let toMonday = (9 - weekday) % 7
            return day(toMonday == 0 ? 7 : toMonday)
        }

        /// By weekday, Sunday first: the full and short English names, and other ways of cutting them short.
        static let weekdayNames: [[String]] = {
            var english = Calendar(identifier: .gregorian)
            english.locale = Locale(identifier: "en_US_POSIX")
            let more: [Int: [String]] = [3: ["tues"], 4: ["weds"], 5: ["thur", "thurs"]]
            return (0..<7).map { index in
                [english.weekdaySymbols[index], english.shortWeekdaySymbols[index]].map(ReminderTimeParser.fold) + (more[index + 1] ?? [])
            }
        }()
    }
}
