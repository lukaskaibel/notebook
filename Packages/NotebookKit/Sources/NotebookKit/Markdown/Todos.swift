import Foundation

/// When a to-do is due: a day, or a day and a time. It is written after the to-do's text the way Obsidian's Tasks plugin
/// writes a due date (`📅 2026-10-24`) and its Reminder plugin a time (`⏰ 2026-10-24 14:00`): words any app shows, and
/// those plugins understand. The day and the time are the clock's, wherever you are.
public struct TodoDue: Hashable, Sendable, Codable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int?
    public var minute: Int?

    public init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = hour == nil ? nil : minute ?? 0
    }

    /// The day of `date`, with its time to the minute when `time` is set.
    public init(_ date: Date, time: Bool, calendar: Calendar = .current) {
        let parts = calendar.gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1,
                  hour: time ? parts.hour ?? 0 : nil, minute: time ? parts.minute ?? 0 : nil)
    }

    public var hasTime: Bool { hour != nil }

    /// The start of its day, or its time.
    public func date(in calendar: Calendar = .current) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0)
        return calendar.gregorian.date(from: parts) ?? .distantFuture
    }

    /// The hour a to-do due on a day without a time reminds you, as Reminders does with its all-day reminders.
    public static let dayAlertHour = 9

    /// When its notification comes: at its time, or in the morning of its day.
    public func alertDate(in calendar: Calendar = .current) -> Date {
        hasTime ? date(in: calendar) : calendar.date(byAdding: .hour, value: Self.dayAlertHour, to: date(in: calendar)) ?? date(in: calendar)
    }

    /// A time that has passed, or a day before today.
    public func isOverdue(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        hasTime ? date(in: calendar) <= now : date(in: calendar) < calendar.startOfDay(for: now)
    }

    /// The same day at another time, or without one.
    public func at(hour: Int?, minute: Int?) -> TodoDue {
        TodoDue(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// As Notebook writes it: Tasks' `📅` for a day, the Reminder plugin's `⏰` for a time.
    public var markdown: String { markdown(.tasks) }

    /// As it is written in a style.
    public func markdown(_ style: DueStyle) -> String {
        let day = String(format: "%04d-%02d-%02d", year, month, day)
        let time = hour.map { String(format: "%02d:%02d", $0, minute ?? 0) }
        switch style {
        case .tasks: return time.map { "⏰ " + day + " " + $0 } ?? "📅 " + day
        case .dataviewEmoji: return "🗓️" + day + (time.map { "T" + $0 } ?? "")
        case .dataview(let parentheses): return (parentheses ? "(" : "[") + "due:: " + day + (time.map { "T" + $0 } ?? "") + (parentheses ? ")" : "]")
        case .reminder: return "(@" + day + (time.map { " " + $0 } ?? "") + ")"
        case .kanban: return "@{" + day + "}" + (time.map { " @@{" + $0 + "}" } ?? "")
        }
    }
}

extension Calendar {
    /// The Gregorian calendar in this one's time zone: the dates written in notes are in it, as ISO 8601 has them,
    /// whichever calendar your settings show (with the Japanese one, 2026 would be written 0008).
    var gregorian: Calendar {
        guard identifier != .gregorian else { return self }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        gregorian.locale = locale
        gregorian.firstWeekday = firstWeekday
        gregorian.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return gregorian
    }
}

/// Where a to-do reminds you: when you arrive at a place, or when you leave it. Written after the to-do's text as a link
/// to the place in Apple Maps, `📍 [Pharmacy](https://maps.apple.com/?ll=52.52,13.40&q=Pharmacy)`, so any app shows
/// a place you can open, and `📍 Leaving [Home](…)` when it is for leaving.
public struct TodoPlace: Hashable, Sendable, Codable {
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    public var leaving: Bool

    public init(name: String, latitude: Double?, longitude: Double?, leaving: Bool = false) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.leaving = leaving
    }

    /// How near you have to be: about a street's length, as Reminders starts with.
    public static let radius: Double = 150

    public var hasCoordinates: Bool { latitude != nil && longitude != nil }

    /// "Arriving at Pharmacy", "Leaving Home".
    public var phrase: String { (leaving ? "Leaving " : "Arriving at ") + name }

    /// The place in Apple Maps.
    public var mapsURL: String {
        var components = URLComponents(string: "https://maps.apple.com/")!
        var items: [URLQueryItem] = []
        if let latitude, let longitude { items.append(URLQueryItem(name: "ll", value: Self.number(latitude) + "," + Self.number(longitude))) }
        items.append(URLQueryItem(name: "q", value: name))
        components.queryItems = items
        // A link's address ends at a space or a bracket.
        return (components.url?.absoluteString ?? "https://maps.apple.com/")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    public var markdown: String {
        // Brackets would end the link's text early.
        let shown = name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "📍 " + (leaving ? "Leaving " : "") + "[" + shown + "](" + mapsURL + ")"
    }

    /// Six places after the point: about ten centimetres.
    private static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The coordinates in a link to Apple Maps (`ll=` or `coordinate=`), or Google Maps (`q=` or `query=` with numbers).
    static func coordinates(in address: String) -> (Double, Double)? {
        guard let items = URLComponents(string: address)?.queryItems else { return nil }
        for key in ["ll", "coordinate", "sll", "q", "query"] {
            guard let value = items.first(where: { $0.name == key })?.value else { continue }
            let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let latitude = parts[0], let longitude = parts[1], abs(latitude) <= 90, abs(longitude) <= 180 {
                return (latitude, longitude)
            }
        }
        return nil
    }
}

/// How a to-do's due date is written. Notebook writes Tasks' `📅` and the Reminder plugin's `⏰`, and reads what the
/// other plugins write too, keeping their way when the date changes.
public enum DueStyle: Equatable, Sendable {
    /// `📅 2026-10-24`, and `⏰ 2026-10-24 14:00` with a time.
    case tasks
    /// Dataview's shorthand, `🗓️2026-10-24`.
    case dataviewEmoji
    /// Dataview's field, `[due:: 2026-10-24]` or `(due:: 2026-10-24)`.
    case dataview(parentheses: Bool)
    /// The Reminder plugin's own, `(@2026-10-24 14:00)`.
    case reminder
    /// The Kanban plugin's, `@{2026-10-24} @@{14:00}`.
    case kanban
}

/// Another of the fields the Tasks plugin writes after a to-do, as an emoji or as Dataview's `[key:: value]`: when it
/// is scheduled, starts, was made, done or cancelled, how important it is, how it repeats, its name and the to-dos it
/// waits for. Notebook shows them and leaves them as they are.
public struct TodoField: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case scheduled, start, created, done, cancelled, priority, repeats, id, dependsOn, onCompletion
    }

    public var kind: Kind
    /// As written: a day (`2026-10-24`), a priority (`highest`, `high`, `medium`, `low`, `lowest`), a rule
    /// (`every week`), names.
    public var value: String

    public init(_ kind: Kind, _ value: String) {
        self.kind = kind
        self.value = value
    }

    /// The day of a date field.
    var day: TodoDue? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return TodoDue(year: parts[0], month: parts[1], day: parts[2])
    }

    public var symbol: String {
        switch kind {
        case .scheduled: "hourglass"
        case .start: "airplane.departure"
        case .created: "plus.circle"
        case .done: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .priority:
            switch value {
            case "highest": "exclamationmark.3"
            case "high": "exclamationmark.2"
            case "low": "arrow.down"
            case "lowest": "arrow.down.to.line"
            default: "exclamationmark"
            }
        case .repeats: "repeat"
        case .id: "number"
        case .dependsOn: "arrow.turn.down.right"
        case .onCompletion: "flag.checkered"
        }
    }

    /// "Scheduled Friday", "High", "every week".
    public func label(now: Date = .now) -> String {
        func day(_ prefix: String) -> String {
            guard let due = self.day else { return prefix + " " + value }
            return prefix + " " + ReminderText.day(due.date(), now: now)
        }
        switch kind {
        case .scheduled: return day("Scheduled")
        case .start: return day("Starts")
        case .created: return day("Created")
        case .done: return day("Done")
        case .cancelled: return day("Cancelled")
        case .priority: return value.capitalized
        case .repeats, .id, .onCompletion: return value
        case .dependsOn: return "After " + value.replacingOccurrences(of: ",", with: ", ")
        }
    }
}

/// A due date, a place or another field written after a to-do's text.
public struct TodoMark: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case due(TodoDue)
        case place(TodoPlace)
        case field(TodoField)
    }

    public var kind: Kind
    /// From its symbol to its end.
    public var range: NSRange
    /// How a due date is written.
    public var style: DueStyle = .tasks

    public var isField: Bool { field != nil }
    public var field: TodoField? { if case .field(let field) = kind { field } else { nil } }
}

/// Reads and writes the marks after a to-do's text.
public enum TodoMarks {
    private static func expression(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A day, and maybe a time after it: groups for the year, month, day, hour and minute.
    private static let day = "(\\d{4})-(\\d{2})-(\\d{2})"
    private static let time = "(?:[ T](\\d{1,2}):(\\d{2}))?"
    /// The ways a due date is written, each with how.
    private static let dueExpressions: [(NSRegularExpression, (NSTextCheckingResult, NSString) -> DueStyle)] = [
        (expression("(📅|⏰|🗓)\u{FE0F}?[ \\t]*" + day + time + "(?![\\d:])"), { match, text in
            text.substring(with: match.range(at: 1)) == "🗓" ? .dataviewEmoji : .tasks
        }),
        (expression("()\\[due::[ \\t]*" + day + time + "[ \\t]*\\]"), { _, _ in .dataview(parentheses: false) }),
        (expression("()\\(due::[ \\t]*" + day + time + "[ \\t]*\\)"), { _, _ in .dataview(parentheses: true) }),
        (expression("()\\(@" + day + time + "\\)"), { _, _ in .reminder }),
        (expression("()@(?:\\{|\\[\\[)" + day + "(?:\\}|\\]\\])(?:[ \\t]*@@\\{(\\d{1,2}):(\\d{2})\\})?"), { _, _ in .kanban }),
    ]
    private static let placeExpression = expression(
        "📍\u{FE0F}?[ \\t]*(?:(Arriving|Leaving)[ \\t]+)?\\[([^\\]\\n]*)\\]\\(([^)\\s]*)\\)", [.caseInsensitive])
    /// Where a repeat rule ends: at the next field, or the end of the line.
    private static let nextField = "(?=[ \\t]*(?:📅|⏰|🗓|⏳|🛫|➕|✅|❌|🔺|⏫|🔼|🔽|⏬|🔁|🆔|⛔|🏁|📍|\\(@|@\\{|@\\[\\[|[\\[(]\\w+::)|[ \\t]*$)"
    private static let emojiFields: [(NSRegularExpression, (String, String) -> TodoField?)] = [
        (expression("(⏳|🛫|➕|✅|❌)\u{FE0F}?[ \\t]*(\\d{4}-\\d{2}-\\d{2})"), { symbol, value in
            let kinds: [String: TodoField.Kind] = ["⏳": .scheduled, "🛫": .start, "➕": .created, "✅": .done, "❌": .cancelled]
            return kinds[symbol].map { TodoField($0, value) }
        }),
        (expression("(🔺|⏫|🔼|🔽|⏬)\u{FE0F}?()"), { symbol, _ in
            let names = ["🔺": "highest", "⏫": "high", "🔼": "medium", "🔽": "low", "⏬": "lowest"]
            return names[symbol].map { TodoField(.priority, $0) }
        }),
        (expression("(🔁)\u{FE0F}?[ \\t]*([^\\n]+?)" + nextField), { _, value in TodoField(.repeats, value) }),
        (expression("(🆔)\u{FE0F}?[ \\t]*([\\w-]+)"), { _, value in TodoField(.id, value) }),
        (expression("(⛔)\u{FE0F}?[ \\t]*([\\w-]+(?:[ \\t]*,[ \\t]*[\\w-]+)*)"), { _, value in TodoField(.dependsOn, value.replacingOccurrences(of: " ", with: "")) }),
        (expression("(🏁)\u{FE0F}?[ \\t]*(keep|delete)", [.caseInsensitive]), { _, value in TodoField(.onCompletion, value.lowercased()) }),
    ]
    /// Dataview's fields for the same, in brackets or in parentheses.
    private static let dataviewField = expression(
        "(?:\\[(scheduled|start|created|completion|cancelled|priority|repeat|id|dependsOn|onCompletion)::[ \\t]*([^\\]\\n]*?)[ \\t]*\\]"
            + "|\\((scheduled|start|created|completion|cancelled|priority|repeat|id|dependsOn|onCompletion)::[ \\t]*([^)\\n]*?)[ \\t]*\\))")
    private static let dataviewKinds: [String: TodoField.Kind] = [
        "scheduled": .scheduled, "start": .start, "created": .created, "completion": .done, "cancelled": .cancelled,
        "priority": .priority, "repeat": .repeats, "id": .id, "dependsOn": .dependsOn, "onCompletion": .onCompletion,
    ]
    /// What a line has to hold for any mark to be in it.
    private static let signs = ["📅", "⏰", "📍", "🗓", "⏳", "🛫", "➕", "✅", "❌", "🔺", "⏫", "🔼", "🔽", "⏬", "🔁", "🆔", "⛔", "🏁", "(@", "@{", "@[[", "::"]

    /// The marks in `range` of `text`, in order. A mark counts right after a word too: typing in front of a pill puts
    /// letters there.
    public static func find(in text: NSString, range: NSRange) -> [TodoMark] {
        guard range.length > 0, text.length >= range.upperBound else { return [] }
        // A quick look first: most to-dos have none.
        guard signs.contains(where: { text.range(of: $0, options: .literal, range: range).location != NSNotFound }) else { return [] }
        var marks: [TodoMark] = []
        let string = text as String
        for (expression, style) in dueExpressions {
            for match in expression.matches(in: string, range: range) {
                func number(_ group: Int) -> Int? {
                    let found = match.range(at: group)
                    return found.location == NSNotFound ? nil : Int(text.substring(with: found))
                }
                guard let year = number(2), let month = number(3), let day = number(4), (1...12).contains(month), (1...31).contains(day) else { continue }
                let hour = number(5), minute = number(6)
                if let hour, !(0...23).contains(hour) { continue }
                if let minute, !(0...59).contains(minute) { continue }
                marks.append(TodoMark(kind: .due(TodoDue(year: year, month: month, day: day, hour: hour, minute: minute)), range: match.range, style: style(match, text)))
            }
        }
        for match in placeExpression.matches(in: string, range: range) {
            let way = match.range(at: 1)
            let leaving = way.location != NSNotFound && text.substring(with: way).lowercased() == "leaving"
            let name = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let coordinates = TodoPlace.coordinates(in: text.substring(with: match.range(at: 3)))
            marks.append(TodoMark(kind: .place(TodoPlace(name: name, latitude: coordinates?.0, longitude: coordinates?.1, leaving: leaving)), range: match.range))
        }
        for (expression, field) in emojiFields {
            for match in expression.matches(in: string, range: range) {
                let value = match.range(at: 2).location == NSNotFound ? "" : text.substring(with: match.range(at: 2))
                if let found = field(text.substring(with: match.range(at: 1)), value.trimmingCharacters(in: .whitespaces)) {
                    marks.append(TodoMark(kind: .field(found), range: match.range))
                }
            }
        }
        for match in dataviewField.matches(in: string, range: range) {
            let bracketed = match.range(at: 1).location != NSNotFound
            let key = text.substring(with: match.range(at: bracketed ? 1 : 3))
            let value = text.substring(with: match.range(at: bracketed ? 2 : 4))
            guard let kind = dataviewKinds[key], !value.isEmpty else { continue }
            marks.append(TodoMark(kind: .field(TodoField(kind, kind == .priority ? value.lowercased() : value)), range: match.range))
        }
        // A date written inside a place's name is part of the place.
        var kept: [TodoMark] = []
        for mark in marks.sorted(by: { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length })
        where !kept.contains(where: { NSIntersectionRange($0.range, mark.range).length > 0 }) {
            kept.append(mark)
        }
        return kept
    }

    /// The marks in a line being parsed, as spans: there are any only if one of their signs is there.
    static func spans(in u: [UInt16], range: NSRange) -> [InlineSpan] {
        var index = range.location
        var found = false
        while index < range.upperBound, !found {
            let unit = u[index]
            let next = index + 1 < range.upperBound ? u[index + 1] : 0
            switch unit {
            // ⏰ ⏳ ➕ ✅ ❌ ⏫ ⏬ ⛔
            case 0x23F0, 0x23F3, 0x2795, 0x2705, 0x274C, 0x23EB, 0x23EC, 0x26D4: found = true
            // 📅 📍 🗓 🛫 🔺 🔼 🔽 🔁
            case 0xD83D: found = [0xDCC5, 0xDCCD, 0xDDD3, 0xDEEB, 0xDD3A, 0xDD3C, 0xDD3D, 0xDD01].contains(next)
            // 🆔 🏁
            case 0xD83C: found = next == 0xDD94 || next == 0xDFC1
            // (@, @{, @[, ::
            case 40: found = next == 64
            case 64: found = next == 123 || next == 91
            case 58: found = next == 58
            default: break
            }
            index += 1
        }
        guard found else { return [] }
        let text = u[range.location..<range.upperBound].withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: range.length) }
        return find(in: text, range: NSRange(location: 0, length: range.length)).map { mark in
            let shifted = mark.range.shifted(by: range.location)
            return InlineSpan(kind: .todoMark(mark.kind), range: shifted, markers: [], content: shifted)
        }
    }

    /// The first due date and the first place among marks.
    public static func schedule(of marks: [TodoMark]) -> (due: TodoDue?, place: TodoPlace?) {
        schedule(of: marks.map(\.kind))
    }

    /// The first due date and the first place on a parsed line.
    public static func schedule(of line: MarkdownLine) -> (due: TodoDue?, place: TodoPlace?) {
        schedule(of: kinds(on: line))
    }

    /// The marks of a parsed line.
    static func kinds(on line: MarkdownLine) -> [TodoMark.Kind] {
        line.spans.compactMap { if case .todoMark(let kind) = $0.kind { kind } else { nil } }
    }

    /// The other fields of a parsed line, in order.
    public static func fields(of line: MarkdownLine) -> [TodoField] {
        kinds(on: line).compactMap { if case .field(let field) = $0 { field } else { nil } }
    }

    /// With a day (📅, Tasks' due date) and a time (⏰, the Reminder plugin's) on one line, the time is when it reminds.
    private static func schedule(of kinds: [TodoMark.Kind]) -> (due: TodoDue?, place: TodoPlace?) {
        var due: TodoDue?, place: TodoPlace?
        for kind in kinds {
            switch kind {
            case .due(let value): if due == nil || (due?.hasTime == false && value.hasTime) { due = value }
            case .place(let value): if place == nil { place = value }
            case .field: break
            }
        }
        return (due, place)
    }

    /// The change that gives a to-do these marks in place of the ones it has: the range of `text` to replace and what
    /// goes there. The to-do's words and its other fields stay as they are; the date and the place go at the end, the
    /// date first, written the way the date it had was. A to-do that had both a day (📅) and a time (⏰), for the two
    /// Obsidian plugins, keeps both, on the new day. Nil when nothing changes.
    public static func change(in text: NSString, content: NSRange, due: TodoDue?, place: TodoPlace?) -> (range: NSRange, replacement: String)? {
        let current = text.substring(with: content) as NSString
        let found = find(in: text, range: content).filter { !$0.isField }
        let marks = found.map { $0.range.shifted(by: -content.location) }
        let dues = found.filter { if case .due = $0.kind { true } else { false } }
        let style = dues.first?.style ?? .tasks
        let keepsDay = style == .tasks && dues.contains { if case .due(let due) = $0.kind { !due.hasTime } else { false } }
            && dues.contains { if case .due(let due) = $0.kind { due.hasTime } else { false } }
        // The words, without the marks and the spaces in front of them.
        let words = NSMutableString(string: current)
        for range in marks.reversed() {
            var start = range.location
            while start > 0, [32, 9].contains(words.character(at: start - 1)) { start -= 1 }
            words.deleteCharacters(in: NSRange(location: start, length: range.upperBound - start))
        }
        var wanted = (words as String).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let day = due.flatMap { keepsDay && $0.hasTime ? $0.at(hour: nil, minute: nil).markdown : nil }
        for mark in [day, due?.markdown(style), place?.markdown].compactMap({ $0 }) {
            wanted += (wanted.isEmpty ? "" : " ") + mark
        }
        return Todos.smallestChange(from: current as String, to: wanted, at: content.location)
    }

    /// A to-do's words without its marks, as Markdown, and its marks as written, in order: what the words are edited
    /// apart from.
    public static func split(_ text: NSString, content: NSRange) -> (words: String, marks: [String]) {
        let found = find(in: text, range: content)
        let words = NSMutableString(string: text.substring(with: content))
        for mark in found.reversed() {
            let range = mark.range.shifted(by: -content.location)
            var start = range.location
            while start > 0, [32, 9].contains(words.character(at: start - 1)) { start -= 1 }
            words.deleteCharacters(in: NSRange(location: start, length: range.upperBound - start))
        }
        return ((words as String).trimmingCharacters(in: .whitespaces), found.map { text.substring(with: $0.range) })
    }
}

/// An open to-do in a note: a checkbox with its words, its due date and place, and the lines indented under it, which
/// are its notes, as a reminder's notes are in Reminders, and its sub-to-dos.
public struct Todo: Hashable, Sendable {
    /// Its line in the note, from 0, and that line as it was, to find it again after the note changed.
    public var line: Int
    public var source: String
    /// The words you read, without Markdown or marks.
    public var text: String
    /// Every line indented under it, as written.
    public var lines: [TodoLine] = []
    public var due: TodoDue?
    public var place: TodoPlace?
    /// What its brackets hold: to do, in progress, or another of Obsidian's marks.
    public var mark: TaskMark = .open
    /// The Tasks plugin's other fields: how important it is, how it repeats, when it is scheduled.
    public var fields: [TodoField] = []

    public var hasReminder: Bool { due != nil || place != nil }

    /// The lines under it as plain text, as a notification shows them: "• " before a point, "○ " before an open
    /// to-do, "✓ " before a done one; at most `Todos.maximumNotes`.
    public var notes: [String] {
        var notes: [String] = []
        for line in lines where !line.text.isEmpty {
            switch line.kind {
            case .todo(let mark): notes.append((mark.isClosed ? "✓ " : "○ ") + line.text)
            case .ordered(let marker): notes.append(marker + " " + line.text)
            case .bullet: notes.append("• " + line.text)
            case .text: notes.append(line.text)
            case .blank, .other: continue
            }
            if notes.count == Todos.maximumNotes { break }
        }
        return notes
    }
}

/// A line indented under a to-do: a sub-to-do, a point, words, or something else kept as it is.
public struct TodoLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A to-do of its own, which is part of the one above: what its brackets hold.
        case todo(TaskMark)
        case bullet
        /// A numbered point, with its number: "2." or "2)".
        case ordered(String)
        /// Words, or a quote.
        case text
        case blank
        /// Code, a table, a heading, a picture: kept as written.
        case other
    }

    /// The line as it is written.
    public var source: String
    public var kind: Kind
    /// How deep it is under the to-do, from 1.
    public var depth: Int
    /// The words you read.
    public var text: String
    /// What it starts with before its words: the indent, a list marker, a checkbox.
    public var prefix: String

    /// Its words as Markdown, after what it starts with.
    public var words: String { String(source.utf16.dropFirst(prefix.utf16.count)) ?? "" }
    /// The indent it starts with.
    public var indent: String { String(source.prefix { $0 == " " || $0 == "\t" }) }

    public var isTodo: Bool { if case .todo = kind { true } else { false } }
}

/// Finds the open to-dos in a note.
public enum Todos {
    /// The to-dos not yet done: each open checkbox, except one indented under another to-do, which is part of that
    /// one's notes, unless it has a date or a place of its own.
    public static func open(in markdown: String) -> [Todo] {
        guard mayHaveOpen(markdown) else { return [] }
        let document = MarkdownParser.parse(markdown)
        let string = markdown as NSString
        var todos: [Todo] = []
        /// The indent of the to-do whose notes the lines are in, while they are.
        var parentIndent: Int?
        for (index, line) in document.lines.enumerated() {
            let indent = Self.indent(of: line, in: string)
            if let parent = parentIndent, line.kind != .blank, indent <= parent { parentIndent = nil }
            guard case .listItem(let item) = line.kind, item.isTask else { continue }
            // What is indented under a to-do, done or not, is its notes.
            let isNested = parentIndent != nil
            if !isNested { parentIndent = item.indent }
            guard !item.checked else { continue }
            let schedule = TodoMarks.schedule(of: line)
            if isNested, schedule.due == nil, schedule.place == nil { continue }
            let text = NotePoints.plain(line, in: string)
            todos.append(Todo(line: index, source: string.substring(with: line.range), text: text,
                              lines: lines(under: index, in: document, string: string), due: schedule.due, place: schedule.place,
                              mark: item.mark, fields: TodoMarks.fields(of: line)))
        }
        return todos
    }

    /// Whether a note may have an open to-do: brackets around a mark that is neither done nor cancelled. Most notes
    /// have none, and this runs over every note there is, so it only looks at bytes.
    static func mayHaveOpen(_ markdown: String) -> Bool {
        var markdown = markdown
        return markdown.withUTF8 { bytes in
            let count = bytes.count
            var index = 0
            while index + 2 < count {
                defer { index += 1 }
                guard bytes[index] == 0x5B else { continue }
                let mark = bytes[index + 1]
                if mark < 0x80 {
                    if bytes[index + 2] == 0x5D, let found = TaskMark(UInt16(mark)), !found.isClosed { return true }
                } else {
                    // A character of several bytes, then the closing bracket.
                    var end = index + 2
                    while end < count, end <= index + 4, bytes[end] & 0xC0 == 0x80 { end += 1 }
                    if end < count, bytes[end] == 0x5D { return true }
                }
            }
            return false
        }
    }

    /// How long the checkbox a line's text starts with is, with the space after it: `[ ] `, `[x] `, `[/] `.
    static func checkboxLength(_ text: Substring) -> Int? {
        let units = Array(text.utf16.prefix(4))
        guard units.count >= 3, units[0] == 91, units[2] == 93, TaskMark(units[1]) != nil else { return nil }
        if units.count == 3 { return 3 }
        return units[3] == 32 ? 4 : nil
    }

    /// The line of a to-do once ticked: `[x]` in its brackets.
    static func ticked(_ source: String) -> String {
        guard mark(of: source)?.isClosed == false else { return source }
        return marked(source, .done)
    }

    /// The line of a to-do with another mark in its brackets.
    static func marked(_ source: String, _ mark: TaskMark) -> String {
        line(source) { _, line in
            guard case .listItem(let item) = line.kind, let box = item.checkbox, item.mark != mark else { return nil }
            return (box, "[" + String(mark.character) + "]")
        } ?? source
    }

    // MARK: - Ticking, as the Tasks plugin ticks

    /// A to-do's line with another mark in its brackets, changed as the Tasks plugin changes it. Ticked, a to-do that
    /// repeats (`🔁 every week`) gets the day it was done, `✅ 2026-10-26`, and comes with the line of the next one:
    /// open, its dates moved on, which goes above it. A to-do loses the day it was done when it isn't done any more,
    /// and the day it was cancelled likewise. Nil when its brackets hold that mark already.
    public static func marking(_ source: String, as mark: TaskMark, today: TodoDay) -> (line: String, next: String?)? {
        guard let marked = markingEdits(source, as: mark, today: today) else { return nil }
        return (applying(marked.edits, to: source as NSString), marked.next)
    }

    /// The edits `marking` makes to a to-do's line, in it as written, and the line of the next one.
    private static func markingEdits(_ source: String, as mark: TaskMark, today: TodoDay) -> (edits: [(range: NSRange, text: String)], next: String?)? {
        let (indent, document, string) = alone(source)
        guard let line = document.lines.first, case .listItem(let item) = line.kind, let box = item.checkbox, item.mark != mark else { return nil }
        let marks = TodoMarks.find(in: string, range: line.content)
        var edits = [(range: box, text: "[" + String(mark.character) + "]")]
        var next: String?
        if mark == .done, !item.mark.isClosed, let repeats = marks.first(where: { $0.field?.kind == .repeats }) {
            next = nextLine(string, box: box, marks: marks, rule: TodoRepeat(repeats.field!.value), today: today).map { indent + $0 }
            if let done = marks.first(where: { $0.field?.kind == .done }) {
                edits.append(dateEdit(in: string, mark: done, day: today))
            } else {
                // Dataview's way when the rule is written its way.
                let written = string.substring(with: repeats.range)
                let field = written.hasPrefix("[") ? "[completion:: \(today)]" : written.hasPrefix("(") ? "(completion:: \(today))" : "✅ \(today)"
                edits.append((NSRange(location: endOfFields(string), length: 0), " " + field))
            }
        }
        // The day it was done goes unless it is done, and the day it was cancelled unless it is cancelled.
        edits += marks.filter { ($0.field?.kind == .done && mark != .done) || ($0.field?.kind == .cancelled && mark != .cancelled) }
            .map { removal(in: string, of: $0.range) }
        let shift = (indent as NSString).length
        let changes = edits.filter { $0.range.length > 0 || !$0.text.isEmpty }
        return (changes.map { (NSRange(location: $0.range.location + shift, length: $0.range.length), $0.text) }, next)
    }

    /// The changes `marking` makes to the to-do on line `index` of a note, each where it is: in its line, and when it
    /// repeats the next one going in above it, with the note's own line ending, unless that is next to it already
    /// (ticked before and unticked: no second one). With how long what goes in above it is, and the next one's line.
    public static func markingChanges(in text: NSString, document: MarkdownDocument, line index: Int, as mark: TaskMark, today: TodoDay)
        -> (changes: [(range: NSRange, replacement: String)], above: Int, next: String?)? {
        guard let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask,
              let marked = markingEdits(text.substring(with: line.range), as: mark, today: today) else { return nil }
        var changes = marked.edits.map { (range: $0.range.shifted(by: line.range.location), replacement: $0.text) }
        var above = 0
        if let next = marked.next, ![index - 1, index + 1].compactMap({ document.lines[safe: $0] }).contains(where: { text.substring(with: $0.range) == next }) {
            let inserted = next + lineEnding(in: text, line: line)
            changes.append((NSRange(location: line.range.location, length: 0), inserted))
            above = (inserted as NSString).length
        }
        return (changes, above, marked.next)
    }

    /// The same as one change: only what differs.
    public static func marking(in text: NSString, document: MarkdownDocument, line index: Int, as mark: TaskMark, today: TodoDay) -> (range: NSRange, replacement: String)? {
        guard let line = document.lines[safe: index], let marked = markingChanges(in: text, document: document, line: index, as: mark, today: today) else { return nil }
        let source = text.substring(with: line.range)
        let edits = marked.changes.map { (range: $0.range.shifted(by: -line.range.location), text: $0.replacement) }
        return smallestChange(from: source, to: applying(edits, to: source as NSString), at: line.range.location)
    }

    /// The line ending a note uses at a line: what ends it, else what ends the line before it; a line feed when there
    /// is neither.
    static func lineEnding(in text: NSString, line: MarkdownLine) -> String {
        let end = line.range.upperBound
        if end < text.length { return text.character(at: end) == 13 ? "\r\n" : "\n" }
        let start = line.range.location
        return start >= 2 && text.character(at: start - 2) == 13 && text.character(at: start - 1) == 10 ? "\r\n" : "\n"
    }

    /// Takes back ticking the to-do on line `index`: it says `original` again, and `next`, the line written above it
    /// for it, goes when it is still there as it was written.
    public static func takingBack(in text: NSString, document: MarkdownDocument, line index: Int, to original: String, next: String?) -> (range: NSRange, replacement: String)? {
        guard let line = document.lines[safe: index] else { return nil }
        var range = line.range
        if let next, let above = document.lines[safe: index - 1], text.substring(with: above.range) == next {
            range = NSRange(location: above.range.location, length: line.range.upperBound - above.range.location)
        }
        return smallestChange(from: text.substring(with: range), to: original, at: range.location)
    }

    /// The line of the next one of a to-do that repeats, as Tasks writes it: open, its due, scheduled and start dates
    /// moved on as far from the next day as they were from the first of them, and without the day it was done or
    /// cancelled, its name, what it waited for and its block link. Nil when the rule has no next day.
    private static func nextLine(_ string: NSString, box: NSRange, marks: [TodoMark], rule: TodoRepeat?, today: TodoDay) -> String? {
        guard let rule else { return nil }
        func day(of mark: TodoMark) -> TodoDay? {
            switch mark.kind {
            case .due(let due): TodoDay(due)
            case .field(let field) where [.scheduled, .start].contains(field.kind): field.day.map(TodoDay.init)
            default: nil
            }
        }
        // The date the others go by: when it is due (Tasks' 📅 first, a time Notebook writes with ⏰ is one too), when
        // it is scheduled, when it starts.
        let dues = marks.filter { if case .due = $0.kind { true } else { false } }
        let due = dues.first { if case .due(let due) = $0.kind { $0.style == .tasks && !due.hasTime } else { false } } ?? dues.first
        let reference = [due, marks.first { $0.field?.kind == .scheduled }, marks.first { $0.field?.kind == .start }]
            .lazy.compactMap { $0.flatMap(day(of:)) }.first
        guard let next = rule.next(after: reference, doneOn: today) else { return nil }
        var edits = [(range: box, text: "[ ]")]
        for mark in marks {
            if let reference, let old = day(of: mark) {
                edits.append(dateEdit(in: string, mark: mark, day: next.adding(days: old.number - reference.number)))
                continue
            }
            switch mark.field?.kind {
            case .created: edits.append(dateEdit(in: string, mark: mark, day: today))
            case .done, .cancelled, .id, .dependsOn: edits.append(removal(in: string, of: mark.range))
            default: break
            }
        }
        if let link = blockLink(in: string) { edits.append((link, "")) }
        return applying(edits, to: string)
    }

    /// A mark with another day in place of the one written in it, the rest as it is.
    private static func dateEdit(in string: NSString, mark: TodoMark, day: TodoDay) -> (range: NSRange, text: String) {
        let found = string.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression, range: mark.range)
        return (found.location == NSNotFound ? NSRange(location: mark.range.upperBound, length: 0) : found, found.location == NSNotFound ? "" : day.description)
    }

    /// A mark taken out, with the spaces in front of it.
    private static func removal(in string: NSString, of range: NSRange) -> (range: NSRange, text: String) {
        var start = range.location
        while start > 0, [32, 9].contains(string.character(at: start - 1)) { start -= 1 }
        return (NSRange(location: start, length: range.upperBound - start), "")
    }

    /// A block link at the end of a line, ` ^name`, with the spaces in front of it.
    private static func blockLink(in string: NSString) -> NSRange? {
        let found = string.range(of: "[ \\t]+\\^[A-Za-z0-9-]+[ \\t]*$", options: .regularExpression)
        return found.location == NSNotFound ? nil : found
    }

    /// Where a field written last goes, as Tasks writes the day it was done last: at the end, before a block link and
    /// the spaces of a line break.
    private static func endOfFields(_ string: NSString) -> Int {
        var end = blockLink(in: string)?.location ?? string.length
        while end > 0, [32, 9].contains(string.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// Edits that don't overlap, made from the last.
    private static func applying(_ edits: [(range: NSRange, text: String)], to string: NSString) -> String {
        let result = NSMutableString(string: string)
        var limit = Int.max
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where edit.range.upperBound <= limit {
            result.replaceCharacters(in: edit.range, with: edit.text)
            limit = edit.range.location
        }
        return result as String
    }

    /// The part of `old`, at `location` in the text, that has to change to make it `new`, and what goes there: only
    /// what differs, so the caret and an undo touch as little as they can. Nil when they are the same.
    static func smallestChange(from old: String, to new: String, at location: Int) -> (range: NSRange, replacement: String)? {
        let old = old as NSString, new = new as NSString
        guard !old.isEqual(to: new as String) else { return nil }
        var prefix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        // Not between the two halves of an emoji.
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
        return (NSRange(location: location + prefix, length: old.length - prefix - suffix),
                new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }

    /// The lines indented under the to-do on line `index`, up to the first that isn't; blank lines between them count.
    public static func noteLines(under index: Int, in document: MarkdownDocument, string: NSString) -> Range<Int> {
        guard case .listItem(let item) = document.lines[index].kind else { return (index + 1)..<(index + 1) }
        var end = index + 1
        var line = index + 1
        while line < document.lines.count {
            let next = document.lines[line]
            if next.kind == .blank {
                line += 1
                continue
            }
            guard indent(of: next, in: string) > item.indent else { break }
            line += 1
            end = line
        }
        return (index + 1)..<end
    }

    /// At most this many lines of notes are in a to-do's notification.
    static let maximumNotes = 8

    /// The lines indented under the to-do on line `index`, as they are written and what they are.
    static func lines(under index: Int, in document: MarkdownDocument, string: NSString) -> [TodoLine] {
        guard case .listItem(let todo) = document.lines[index].kind else { return [] }
        var result: [TodoLine] = []
        /// The list items above in the block, with their indent and depth, for the depth of the words under them.
        var items: [(indent: Int, depth: Int)] = []
        for lineIndex in noteLines(under: index, in: document, string: string) {
            let line = document.lines[lineIndex]
            let source = string.substring(with: line.range)
            let indent = Self.indent(of: line, in: string)
            let leading = String(source.prefix { $0 == " " || $0 == "\t" })
            func under() -> Int { (items.last { $0.indent < indent }?.depth ?? 0) + 1 }
            switch line.kind {
            case .listItem(let item):
                let depth = max(1, item.level - todo.level)
                while let last = items.last, last.indent >= item.indent { items.removeLast() }
                items.append((item.indent, depth))
                let kind: TodoLine.Kind
                if item.isTask {
                    kind = .todo(item.mark)
                } else if case .ordered(let number, let delimiter) = item.marker {
                    kind = .ordered("\(number)\(delimiter)")
                } else {
                    kind = .bullet
                }
                let prefix = string.substring(with: NSRange(location: line.range.location, length: line.content.location - line.range.location))
                result.append(TodoLine(source: source, kind: kind, depth: depth, text: NotePoints.plain(line, in: string), prefix: prefix))
            case .paragraph, .quote:
                let prefix = line.content.location > line.range.location
                    ? string.substring(with: NSRange(location: line.range.location, length: line.content.location - line.range.location)) : leading
                result.append(TodoLine(source: source, kind: .text, depth: under(), text: NotePoints.plain(line, in: string), prefix: prefix))
            case .blank:
                result.append(TodoLine(source: source, kind: .blank, depth: 1, text: "", prefix: source))
            default:
                result.append(TodoLine(source: source, kind: .other, depth: under(), text: source.trimmingCharacters(in: .whitespaces), prefix: leading))
            }
        }
        return result
    }

    /// How far a line is indented: a list item's indent, or a line's spaces (a tab counts as four).
    static func indent(of line: MarkdownLine, in string: NSString) -> Int {
        if case .listItem(let item) = line.kind { return item.indent }
        var columns = 0
        var index = line.range.location
        while index < line.range.upperBound {
            switch string.character(at: index) {
            case 32: columns += 1
            case 9: columns += 4 - columns % 4
            default: return columns
            }
            index += 1
        }
        return columns
    }

    /// A to-do's line on its own: its words, date and place, and whether it is done.
    public static func line(_ source: String) -> (text: String, due: TodoDue?, place: TodoPlace?, done: Bool)? {
        let (_, document, string) = alone(source)
        guard let line = document.lines.first, case .listItem(let item) = line.kind, item.isTask else { return nil }
        let schedule = TodoMarks.schedule(of: line)
        return (NotePoints.plain(line, in: string), schedule.due, schedule.place, item.checked)
    }

    /// What a to-do's brackets hold, on its line on its own.
    public static func mark(of source: String) -> TaskMark? {
        let (_, document, _) = alone(source)
        guard let line = document.lines.first, case .listItem(let item) = line.kind, item.isTask else { return nil }
        return item.mark
    }

    /// A to-do's line on its own taken apart: what it starts with (indent, marker, checkbox), its words as Markdown,
    /// and its marks as written, which the words are edited apart from.
    public static func parts(of source: String) -> (prefix: String, words: String, marks: [String])? {
        let (indent, document, string) = alone(source)
        guard let line = document.lines.first, case .listItem(let item) = line.kind, item.isTask else { return nil }
        let split = TodoMarks.split(string, content: line.content)
        return (indent + string.substring(with: NSRange(location: 0, length: line.content.location)), split.words, split.marks)
    }

    /// A to-do's line with other words, its marks kept after them. The line as it is when the words are the same.
    public static func replacingWords(in source: String, with words: String) -> String {
        guard let parts = parts(of: source), parts.words != words else { return source }
        let body = ([words.trimmingCharacters(in: .whitespaces)] + parts.marks).filter { !$0.isEmpty }.joined(separator: " ")
        // `- [ ]` with nothing after it yet has no space after its box.
        return parts.prefix + (body.isEmpty || parts.prefix.last?.isWhitespace == true ? "" : " ") + body
    }

    /// What a to-do's line says after an edit, worked out on the line alone.
    public static func line(_ source: String, after edit: (NSString, MarkdownLine) -> (range: NSRange, replacement: String)?) -> String? {
        let (indent, document, string) = alone(source)
        guard let line = document.lines.first, let change = edit(string, line) else { return nil }
        return indent + string.replacingCharacters(in: change.range, with: change.replacement)
    }

    /// A line parsed on its own, without its indent, which on its own would make it code.
    static func alone(_ source: String) -> (indent: String, document: MarkdownDocument, string: NSString) {
        let indent = String(source.prefix { $0 == " " || $0 == "\t" })
        let string = String(source.dropFirst(indent.count)) as NSString
        return (indent, MarkdownParser.parse(string), string)
    }

    /// The line a to-do is on now, in a note that may have changed since it was found: the same line if it still says
    /// the same, else the nearest line that does.
    public static func find(_ source: String, near line: Int, in document: MarkdownDocument, string: NSString) -> Int? {
        func matches(_ index: Int) -> Bool {
            let candidate = document.lines[index]
            guard case .listItem(let item) = candidate.kind, item.isTask else { return false }
            return string.substring(with: candidate.range) == source
        }
        if line < document.lines.count, matches(line) { return line }
        let candidates = document.lines.indices.filter(matches)
        return candidates.min { abs($0 - line) < abs($1 - line) }
    }
}

/// When a reminder is, in words: "Today 14:00", "Tomorrow", "Friday 9:00", "24 Oct", in the words and the clock of
/// your settings.
public enum ReminderText {
    public static func text(_ date: Date, time: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let day = day(date, now: now, calendar: calendar)
        return time ? day + " " + date.formatted(date: .omitted, time: .shortened) : day
    }

    /// "Today", "Tomorrow", "Yesterday", a weekday in the coming week, "24 Oct", or "24 Oct 2027" in another year.
    public static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2..<7: return date.formatted(.dateTime.weekday(.wide))
        default:
            if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
