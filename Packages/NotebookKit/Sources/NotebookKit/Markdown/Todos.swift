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
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1,
                  hour: time ? parts.hour ?? 0 : nil, minute: time ? parts.minute ?? 0 : nil)
    }

    public var hasTime: Bool { hour != nil }

    /// The start of its day, or its time.
    public func date(in calendar: Calendar = .current) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0)
        return calendar.date(from: parts) ?? .distantFuture
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

    /// As it is written in the note.
    public var markdown: String {
        let day = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour else { return "📅 " + day }
        return "⏰ " + day + String(format: " %02d:%02d", hour, minute ?? 0)
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

/// A due date or a place written after a to-do's text.
public struct TodoMark: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case due(TodoDue)
        case place(TodoPlace)
    }

    public var kind: Kind
    /// From its symbol to its end.
    public var range: NSRange
}

/// Reads and writes the marks after a to-do's text.
public enum TodoMarks {
    private static let dueExpression = try! NSRegularExpression(
        pattern: "(?:📅|⏰\u{FE0F}?)[ \\t]*(\\d{4})-(\\d{2})-(\\d{2})(?:[ T](\\d{1,2}):(\\d{2}))?(?![\\d:])")
    private static let placeExpression = try! NSRegularExpression(
        pattern: "📍\u{FE0F}?[ \\t]*(?:(Arriving|Leaving)[ \\t]+)?\\[([^\\]\\n]*)\\]\\(([^)\\s]*)\\)", options: [.caseInsensitive])

    /// The marks in `range` of `text`, in order. A mark counts right after a word too: typing in front of a pill puts
    /// letters there.
    public static func find(in text: NSString, range: NSRange) -> [TodoMark] {
        guard range.length > 0, text.length >= range.upperBound else { return [] }
        // A quick look first: most to-dos have none.
        guard ["📅", "⏰", "📍"].contains(where: { text.range(of: $0, options: .literal, range: range).location != NSNotFound }) else { return [] }
        var marks: [TodoMark] = []
        let string = text as String
        for match in dueExpression.matches(in: string, range: range) {
            func number(_ group: Int) -> Int? {
                let found = match.range(at: group)
                return found.location == NSNotFound ? nil : Int(text.substring(with: found))
            }
            guard let year = number(1), let month = number(2), let day = number(3), (1...12).contains(month), (1...31).contains(day) else { continue }
            let hour = number(4), minute = number(5)
            if let hour, !(0...23).contains(hour) { continue }
            if let minute, !(0...59).contains(minute) { continue }
            marks.append(TodoMark(kind: .due(TodoDue(year: year, month: month, day: day, hour: hour, minute: minute)), range: match.range))
        }
        for match in placeExpression.matches(in: string, range: range) {
            let way = match.range(at: 1)
            let leaving = way.location != NSNotFound && text.substring(with: way).lowercased() == "leaving"
            let name = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let coordinates = TodoPlace.coordinates(in: text.substring(with: match.range(at: 3)))
            marks.append(TodoMark(kind: .place(TodoPlace(name: name, latitude: coordinates?.0, longitude: coordinates?.1, leaving: leaving)), range: match.range))
        }
        return marks.sorted { $0.range.location < $1.range.location }
    }

    /// The marks in a line being parsed, as spans: there are any only if one of the symbols is there.
    static func spans(in u: [UInt16], range: NSRange) -> [InlineSpan] {
        var index = range.location
        var found = false
        while index < range.upperBound, !found {
            let unit = u[index]
            // ⏰, or 📅 and 📍 (D83D DCC5, D83D DCCD).
            found = unit == 0x23F0 || (unit == 0xD83D && index + 1 < range.upperBound && (u[index + 1] == 0xDCC5 || u[index + 1] == 0xDCCD))
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
        schedule(of: line.spans.compactMap { if case .todoMark(let kind) = $0.kind { kind } else { nil } })
    }

    private static func schedule(of kinds: [TodoMark.Kind]) -> (due: TodoDue?, place: TodoPlace?) {
        var due: TodoDue?, place: TodoPlace?
        for kind in kinds {
            switch kind {
            case .due(let value): if due == nil { due = value }
            case .place(let value): if place == nil { place = value }
            }
        }
        return (due, place)
    }

    /// The change that gives a to-do these marks in place of the ones it has: the range of `text` to replace and what
    /// goes there. The to-do's words stay as they are; the marks go at their end, the date first. Nil when nothing
    /// changes.
    public static func change(in text: NSString, content: NSRange, due: TodoDue?, place: TodoPlace?) -> (range: NSRange, replacement: String)? {
        let current = text.substring(with: content) as NSString
        let marks = find(in: text, range: content).map { $0.range.shifted(by: -content.location) }
        // The words, without the marks and the spaces in front of them.
        let words = NSMutableString(string: current)
        for range in marks.reversed() {
            var start = range.location
            while start > 0, [32, 9].contains(words.character(at: start - 1)) { start -= 1 }
            words.deleteCharacters(in: NSRange(location: start, length: range.upperBound - start))
        }
        var wanted = (words as String).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        for mark in [due?.markdown, place?.markdown].compactMap({ $0 }) {
            wanted += (wanted.isEmpty ? "" : " ") + mark
        }
        let new = wanted as NSString
        guard !new.isEqual(to: current as String) else { return nil }
        // Only what differs, so the caret and an undo touch as little as they can.
        var prefix = 0
        while prefix < min(current.length, new.length), current.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(current.length, new.length) - prefix,
              current.character(at: current.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: content.location + prefix, length: current.length - prefix - suffix)
        return (range, new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }
}

/// An open to-do in a note: a checkbox with its words, its due date and place, and the lines indented under it, which
/// are its notes, as a reminder's notes are in Reminders.
public struct Todo: Hashable, Sendable {
    /// Its line in the note, from 0, and that line as it was, to find it again after the note changed.
    public var line: Int
    public var source: String
    /// The words you read, without Markdown or marks.
    public var text: String
    /// The lines indented under it, as plain text: "• " before a point, "○ " before an open to-do, "✓ " before a done one.
    public var notes: [String]
    public var due: TodoDue?
    public var place: TodoPlace?

    public var hasReminder: Bool { due != nil || place != nil }
}

/// Finds the open to-dos in a note.
public enum Todos {
    /// The to-dos not yet done: each open checkbox, except one indented under another to-do, which is part of that
    /// one's notes, unless it has a date or a place of its own.
    public static func open(in markdown: String) -> [Todo] {
        // Most notes have none, and this runs over every note there is.
        guard markdown.contains("[ ]") else { return [] }
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
                              notes: notes(under: index, in: document, string: string), due: schedule.due, place: schedule.place))
        }
        return todos
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

    /// At most this many lines of notes are kept with a to-do: what a row and a notification show.
    static let maximumNotes = 8

    private static func notes(under index: Int, in document: MarkdownDocument, string: NSString) -> [String] {
        var notes: [String] = []
        for lineIndex in noteLines(under: index, in: document, string: string) {
            let line = document.lines[lineIndex]
            let text: String
            switch line.kind {
            case .listItem(let item):
                let words = NotePoints.plain(line, in: string)
                guard !words.isEmpty else { continue }
                if item.isTask {
                    text = (item.checked ? "✓ " : "○ ") + words
                } else if case .ordered(let number, let delimiter) = item.marker {
                    text = "\(number)\(delimiter) " + words
                } else {
                    text = "• " + words
                }
            case .paragraph, .quote:
                text = NotePoints.plain(line, in: string)
                guard !text.isEmpty else { continue }
            default:
                continue
            }
            notes.append(text)
            if notes.count == maximumNotes { break }
        }
        return notes
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

    /// What a to-do's line says after an edit, worked out on the line alone.
    public static func line(_ source: String, after edit: (NSString, MarkdownLine) -> (range: NSRange, replacement: String)?) -> String? {
        let (indent, document, string) = alone(source)
        guard let line = document.lines.first, let change = edit(string, line) else { return nil }
        return indent + string.replacingCharacters(in: change.range, with: change.replacement)
    }

    /// A line parsed on its own, without its indent, which on its own would make it code.
    private static func alone(_ source: String) -> (indent: String, document: MarkdownDocument, string: NSString) {
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
