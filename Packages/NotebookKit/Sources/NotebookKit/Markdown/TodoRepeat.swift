import Foundation

/// A day of the calendar, without a time or a time zone: what the dates written after a to-do are.
public struct TodoDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ due: TodoDue) {
        self.init(year: due.year, month: due.month, day: due.day)
    }

    /// The day `date` is on, by the clock of your settings.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public static var today: TodoDay { TodoDay(.now) }

    /// Days since 1 January 1970, by the Gregorian calendar (Howard Hinnant's `days_from_civil`). A day the month
    /// doesn't have counts on into the next: 30 February is 2 March.
    var number: Int {
        let year = month <= 2 ? self.year - 1 : self.year
        let era = (year >= 0 ? year : year - 399) / 400
        let ofEra = year - era * 400
        let ofYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        return era * 146_097 + ofEra * 365 + ofEra / 4 - ofEra / 100 + ofYear - 719_468
    }

    init(number: Int) {
        let shifted = number + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let ofEra = shifted - era * 146_097
        let yearOfEra = (ofEra - ofEra / 1460 + ofEra / 36524 - ofEra / 146_096) / 365
        let ofYear = ofEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * ofYear + 2) / 153
        day = ofYear - (153 * shiftedMonth + 2) / 5 + 1
        month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    /// Monday 0 to Sunday 6, as rrule counts.
    var weekday: Int { ((number + 3) % 7 + 7) % 7 }

    func adding(days: Int) -> TodoDay { TodoDay(number: number + days) }

    /// Not 30 February.
    var exists: Bool { (1...12).contains(month) && day >= 1 && day <= Self.length(of: month, in: year) }

    static func length(of month: Int, in year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// As the Tasks plugin writes it: `2026-10-26`.
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: TodoDay, b: TodoDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// How a to-do repeats, written after it as the Tasks plugin writes it: `🔁 every week`, `🔁 every month on the 1st`,
/// `🔁 every weekday when done`. Read the way Tasks reads it, with the English of the rrule library Tasks uses, word for
/// word, and the next day worked out as Tasks works it out, so that a note goes on the same in Obsidian and in Notebook.
public struct TodoRepeat: Hashable, Sendable {
    /// In rrule's order: the longer periods first.
    enum Frequency: Int, Comparable, Sendable {
        case yearly, monthly, weekly, daily
        static func < (a: Frequency, b: Frequency) -> Bool { a.rawValue < b.rawValue }
    }

    /// A day of the week, Monday 0, and which one of it in the month or year: 1 the first, -1 the last, nil each.
    struct Weekday: Hashable, Sendable {
        var day: Int
        var nth: Int?
    }

    var frequency: Frequency
    var interval = 1
    var weekdays: [Weekday] = []
    /// Days of the month, from the end when below zero: -1 the last.
    var monthDays: [Int] = []
    var months: [Int] = []
    /// `when done`: from the day it is done, not from its date.
    var whenDone = false

    /// The rule written after `🔁`; nil when Tasks wouldn't read one there, or Notebook can't follow it (by the hour,
    /// by week numbers, until a day).
    public init?(_ text: String) {
        // Tags and a block link after the rule aren't part of it, as Tasks takes them off the end of the line first.
        let text = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "(?:[ \\t]+(?:#[^\\s#]+|\\^[A-Za-z0-9-]+))+$", with: "", options: .regularExpression)
        guard let match = Self.rulePattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let rule = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard let parsed = RuleParser.parse(rule) else { return nil }
        self = parsed
        whenDone = match.range(at: 2).location != NSNotFound
    }

    init(frequency: Frequency) {
        self.frequency = frequency
    }

    /// What Tasks takes for a rule: letters, numbers, commas and spaces, and `when done` at the end.
    private static let rulePattern = try! NSRegularExpression(pattern: "^([a-zA-Z0-9, !]+?)( when done)?$", options: [.caseInsensitive])

    /// The day of the next one, after a to-do on `day` (its due date, else when it is scheduled, else when it starts)
    /// done `today`. Nil when there is none, or the day doesn't exist.
    public func next(after day: TodoDay?, doneOn today: TodoDay) -> TodoDay? {
        // From its date even when it's done late; `when done`, or without a date, from today.
        var after = whenDone ? today : day ?? today
        guard after.exists, var next = first(after: after) else { return nil }
        // `every month` from 31 January is 28 February, not 31 March: Tasks steps back a day at a time until the next
        // one is no more months away than the rule says. Not when the rule names the day: `every month on the 31st`
        // goes on to 31 March, as iCalendar has it.
        if correctsMonths {
            for _ in 0..<31 {
                let months = (next.year - after.year) * 12 + next.month - after.month
                guard months > interval else { break }
                after = after.adding(days: -1)
                guard let earlier = first(after: after) else { return nil }
                next = earlier
            }
        }
        // And `every year` from 29 February is 28 February.
        if correctsYears {
            for _ in 0..<366 {
                guard next.year - after.year > interval else { break }
                after = after.adding(days: -1)
                guard let earlier = first(after: after) else { return nil }
                next = earlier
            }
        }
        return next
    }

    /// Where Tasks' rule in words, as rrule writes it back, is `every [n] month(s)` with no `on`.
    private var correctsMonths: Bool {
        frequency == .monthly && !(interval == 1 && !months.isEmpty) && monthDays.isEmpty && weekdays.isEmpty
    }

    /// Where it is `every [n] year(s)`.
    private var correctsYears: Bool {
        frequency == .yearly && !(interval == 1 && !months.isEmpty)
    }

    /// The first day after `start` that the rule makes, counting from `start`, as rrule's `after` does.
    func first(after start: TodoDay) -> TodoDay? {
        var months = self.months
        var monthDays = self.monthDays
        // A day of the week counts as which one of it only in a month or a year.
        var plain = weekdays.filter { $0.nth == nil || frequency > .monthly }.map(\.day)
        let nth = weekdays.filter { $0.nth != nil && frequency <= .monthly }
        // Without a day of the week or of the month, the day it starts from says which: `every month` from the 26th
        // is on the 26th.
        if monthDays.isEmpty, weekdays.isEmpty {
            switch frequency {
            case .yearly:
                if months.isEmpty { months = [start.month] }
                monthDays = [start.day]
            case .monthly: monthDays = [start.day]
            case .weekly: plain = [start.weekday]
            case .daily: break
            }
        }
        func isNth(_ day: TodoDay) -> Bool {
            // Within its month, or for a rule by the year without months, within its year.
            let byYear = frequency == .yearly && self.months.isEmpty
            let first = (byYear ? TodoDay(year: day.year, month: 1, day: 1) : TodoDay(year: day.year, month: day.month, day: 1)).number
            let last = (byYear ? TodoDay(year: day.year, month: 12, day: 31) : TodoDay(year: day.year, month: day.month, day: TodoDay.length(of: day.month, in: day.year))).number
            return nth.contains { weekday in
                guard weekday.day == day.weekday, let n = weekday.nth else { return false }
                var found: Int
                if n < 0 {
                    found = last + (n + 1) * 7
                    found -= ((TodoDay(number: found).weekday - weekday.day) % 7 + 7) % 7
                } else {
                    found = first + (n - 1) * 7
                    found += ((weekday.day - TodoDay(number: found).weekday) % 7 + 7) % 7
                }
                return found >= first && found <= last && found == day.number
            }
        }
        func matches(_ day: TodoDay) -> Bool {
            if !months.isEmpty, !months.contains(day.month) { return false }
            if !plain.isEmpty, !plain.contains(day.weekday) { return false }
            if !nth.isEmpty, !isNth(day) { return false }
            if !monthDays.isEmpty {
                let fromEnd = day.day - TodoDay.length(of: day.month, in: day.year) - 1
                if !monthDays.contains(day.day), !monthDays.contains(fromEnd) { return false }
            }
            return true
        }
        // Period by period, from the one `start` is in: its day, week (from Monday), month or year.
        let periods = frequency == .yearly ? 400 : 1000
        for period in 0..<periods {
            let step = period * interval
            let days: [TodoDay]
            switch frequency {
            case .daily:
                days = [start.adding(days: step)]
            case .weekly:
                let monday = start.number - start.weekday + step * 7
                days = (monday..<monday + 7).map(TodoDay.init(number:))
            case .monthly:
                let index = start.year * 12 + start.month - 1 + step
                let year = Int((Double(index) / 12).rounded(.down)), month = index - year * 12 + 1
                days = (1...TodoDay.length(of: month, in: year)).map { TodoDay(year: year, month: month, day: $0) }
            case .yearly:
                let year = start.year + step
                days = (TodoDay(year: year, month: 1, day: 1).number...TodoDay(year: year, month: 12, day: 31).number).map(TodoDay.init(number:))
            }
            if let found = days.first(where: { $0 > start && matches($0) }) { return found }
        }
        return nil
    }
}

/// rrule's reader of rules in English (`nlp/parsetext.ts` and `nlp/i18n.ts`), as the Tasks plugin uses it: the same
/// words, the same longest-match tokens, the same leniency with words after a rule it has read.
private struct RuleParser {
    private enum Symbol: CaseIterable {
        case skip, number, numberAsText, every, days, weekdays, weeks, hours, minutes, months, years, on, at, the,
             first, second, third, nth, last, `for`, times, until,
             monday, tuesday, wednesday, thursday, friday, saturday, sunday,
             january, february, march, april, may, june, july, august, september, october, november, december,
             comma
    }

    private struct Invalid: Error {}

    /// In rrule's order, which decides between matches of the same length.
    private static let tokens: [(Symbol, NSRegularExpression)] = {
        let patterns: [(Symbol, String, Bool)] = [
            (.skip, "[ \\r\\n\\t]+|\\.$", false), (.number, "[1-9][0-9]*", false), (.numberAsText, "(one|two|three)", true),
            (.every, "every", true), (.days, "days?", true), (.weekdays, "weekdays?", true), (.weeks, "weeks?", true),
            (.hours, "hours?", true), (.minutes, "minutes?", true), (.months, "months?", true), (.years, "years?", true),
            (.on, "(on|in)", true), (.at, "(at)", true), (.the, "the", true), (.first, "first", true), (.second, "second", true),
            (.third, "third", true), (.nth, "([1-9][0-9]*)(\\.|th|nd|rd|st)", true), (.last, "last", true), (.for, "for", true),
            (.times, "times?", true), (.until, "(un)?til", true),
            (.monday, "mo(n(day)?)?", true), (.tuesday, "tu(e(s(day)?)?)?", true), (.wednesday, "we(d(n(esday)?)?)?", true),
            (.thursday, "th(u(r(sday)?)?)?", true), (.friday, "fr(i(day)?)?", true), (.saturday, "sa(t(urday)?)?", true),
            (.sunday, "su(n(day)?)?", true),
            (.january, "jan(uary)?", true), (.february, "feb(ruary)?", true), (.march, "mar(ch)?", true), (.april, "apr(il)?", true),
            (.may, "may", true), (.june, "june?", true), (.july, "july?", true), (.august, "aug(ust)?", true),
            (.september, "sep(t(ember)?)?", true), (.october, "oct(ober)?", true), (.november, "nov(ember)?", true),
            (.december, "dec(ember)?", true), (.comma, "(,\\s*|(and|or)\\s*)+", true),
        ]
        return patterns.map { symbol, pattern, ignoresCase in
            (symbol, try! NSRegularExpression(pattern: pattern, options: ignoresCase ? [.caseInsensitive] : []))
        }
    }()

    private var text: NSString = ""
    private var symbol: Symbol?
    /// What the symbol matched, and its first group.
    private var value: (text: String, group: String?)?
    private var done = true
    private var rule = TodoRepeat(frequency: .daily)
    private var isHourly = false
    private var hasUntil = false
    private var hasWeekNumbers = false

    static func parse(_ text: String) -> TodoRepeat? {
        var parser = RuleParser()
        guard parser.start(text) else { return nil }
        do {
            try parser.rules()
        } catch {
            return nil
        }
        // Rules by the hour, by week numbers or until a day Notebook doesn't follow.
        guard !parser.isHourly, !parser.hasUntil, !parser.hasWeekNumbers else { return nil }
        return parser.rule
    }

    // MARK: - Reading symbols

    private mutating func start(_ text: String) -> Bool {
        self.text = text as NSString
        done = false
        return nextSymbol()
    }

    private var isDone: Bool { done && symbol == nil }

    @discardableResult
    private mutating func nextSymbol() -> Bool {
        symbol = nil
        value = nil
        while true {
            if done { return false }
            var best: (Symbol, NSTextCheckingResult)?
            let whole = NSRange(location: 0, length: text.length)
            for (name, expression) in Self.tokens {
                guard let match = expression.firstMatch(in: text as String, options: [.anchored], range: whole), match.range.length > 0 else { continue }
                if best == nil || match.range.length > best!.1.range.length { best = (name, match) }
            }
            guard let (name, match) = best else {
                done = true
                return false
            }
            let matched = text.substring(with: match.range)
            let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? text.substring(with: match.range(at: 1)) : nil
            text = text.substring(from: match.range.length) as NSString
            if text.length == 0 { done = true }
            if name == .skip { continue }
            symbol = name
            value = (matched, group)
            return true
        }
    }

    private mutating func accept(_ name: Symbol) -> (text: String, group: String?)? {
        guard symbol == name, let value else { return nil }
        nextSymbol()
        return value
    }

    private mutating func acceptNumber() -> Int? {
        accept(.number).flatMap { Int($0.text) }
    }

    private mutating func expect(_ name: Symbol) throws {
        guard accept(name) != nil else { throw Invalid() }
    }

    // MARK: - The grammar

    /// `every [n] …`
    private mutating func rules() throws {
        try expect(.every)
        if let n = acceptNumber() { rule.interval = n }
        if isDone { throw Invalid() }
        switch symbol {
        case .days:
            rule.frequency = .daily
            if nextSymbol() {
                try at()
                try ending()
            }
        case .weekdays:
            rule.frequency = .weekly
            rule.weekdays = (0...4).map { TodoRepeat.Weekday(day: $0) }
            nextSymbol()
            try at()
            try ending()
        case .weeks:
            rule.frequency = .weekly
            if nextSymbol() {
                try on()
                try at()
                try ending()
            }
        case .hours, .minutes:
            isHourly = true
        case .months:
            rule.frequency = .monthly
            if nextSymbol() {
                try on()
                try ending()
            }
        case .years:
            rule.frequency = .yearly
            if nextSymbol() {
                try on()
                try ending()
            }
        case let name? where weekday(name) != nil:
            rule.frequency = .weekly
            rule.weekdays = [TodoRepeat.Weekday(day: weekday(name)!)]
            guard nextSymbol() else { return }
            while accept(.comma) != nil {
                if isDone { throw Invalid() }
                guard let day = symbol.flatMap(weekday) else { throw Invalid() }
                rule.weekdays.append(TodoRepeat.Weekday(day: day))
                nextSymbol()
            }
            try at()
            try monthDays()
            try ending()
        case let name? where month(name) != nil:
            rule.frequency = .yearly
            rule.months = [month(name)!]
            guard nextSymbol() else { return }
            while accept(.comma) != nil {
                if isDone { throw Invalid() }
                guard let month = symbol.flatMap(month) else { throw Invalid() }
                rule.months.append(month)
                nextSymbol()
            }
            try on()
            try ending()
        default:
            throw Invalid()
        }
    }

    /// `on the 1st and the 15th`, `on Tuesday, Friday`, `on the last Friday`, `in January`, `on weekdays`.
    private mutating func on() throws {
        let on = accept(.on) != nil
        let the = accept(.the) != nil
        guard on || the else { return }
        repeat {
            let nth = try self.nth()
            let weekday = symbol.flatMap(weekday)
            let month = symbol.flatMap(month)
            if let nth {
                if let weekday {
                    nextSymbol()
                    rule.weekdays.append(TodoRepeat.Weekday(day: weekday, nth: nth))
                } else {
                    rule.monthDays.append(nth)
                    _ = accept(.days)
                }
            } else if let weekday {
                nextSymbol()
                rule.weekdays.append(TodoRepeat.Weekday(day: weekday))
            } else if symbol == .weekdays {
                nextSymbol()
                if rule.weekdays.isEmpty { rule.weekdays = (0...4).map { TodoRepeat.Weekday(day: $0) } }
            } else if symbol == .weeks {
                nextSymbol()
                guard acceptNumber() != nil else { throw Invalid() }
                while accept(.comma) != nil {
                    guard acceptNumber() != nil else { throw Invalid() }
                }
                hasWeekNumbers = true
            } else if let month {
                nextSymbol()
                rule.months.append(month)
            } else {
                return
            }
        } while accept(.comma) != nil || accept(.the) != nil || accept(.on) != nil
    }

    /// `at 9`, which a rule by the day doesn't need.
    private mutating func at() throws {
        guard accept(.at) != nil else { return }
        repeat {
            guard acceptNumber() != nil else { throw Invalid() }
            while accept(.comma) != nil {
                guard acceptNumber() != nil else { throw Invalid() }
            }
        } while accept(.comma) != nil || accept(.at) != nil
    }

    /// After days of the week: `on the 13th`.
    private mutating func monthDays() throws {
        _ = accept(.on)
        _ = accept(.the)
        guard let nth = try nth() else { return }
        rule.monthDays = [nth]
        // rrule moves on a symbol more here than it read.
        nextSymbol()
        while accept(.comma) != nil {
            guard let nth = try self.nth() else { throw Invalid() }
            rule.monthDays.append(nth)
            nextSymbol()
        }
    }

    /// `until …` and `for 3 times`: Tasks doesn't keep count, and ends early with `until`.
    private mutating func ending() throws {
        if symbol == .until {
            hasUntil = true
        } else if accept(.for) != nil {
            try expect(.number)
        }
    }

    /// `last`, `first`, `2nd`, `2nd last`: which one, from the end when below zero.
    private mutating func nth() throws -> Int? {
        switch symbol {
        case .last:
            nextSymbol()
            return -1
        case .first:
            nextSymbol()
            return 1
        case .second:
            nextSymbol()
            return accept(.last) != nil ? -2 : 2
        case .third:
            nextSymbol()
            return accept(.last) != nil ? -3 : 3
        case .nth:
            guard let value = value?.group.flatMap({ Int($0) }), value <= 366 else { throw Invalid() }
            nextSymbol()
            return accept(.last) != nil ? -value : value
        default:
            return nil
        }
    }

    private func weekday(_ symbol: Symbol) -> Int? {
        [Symbol.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday].firstIndex(of: symbol)
    }

    private func month(_ symbol: Symbol) -> Int? {
        [Symbol.january, .february, .march, .april, .may, .june, .july, .august, .september, .october, .november, .december]
            .firstIndex(of: symbol).map { $0 + 1 }
    }
}
