import Foundation

/// Every open to-do in the locations, for the To-dos list and their notifications. Read off the main thread from the
/// text search already keeps of every note, after it changed; a note that didn't change since isn't read again.
/// Folders you hide leave their to-dos out, as they leave search.
@MainActor
@Observable
final class TodoList {
    /// An open to-do and the note it is in.
    struct Item: Identifiable, Hashable, Sendable {
        var url: URL
        /// The note's name, without ".md".
        var note: String
        /// When the note was last changed, to put the to-dos of the notes you work on first.
        var modified: Date?
        var todo: Todo

        var id: String { url.path + "\u{0}\(todo.line)\u{0}" + todo.source }
        var reference: TodoReference { TodoReference(url: url, line: todo.line, source: todo.source) }
    }

    /// Every open to-do, by note (most recently changed first) and in each note in order.
    private(set) var items: [Item] = []
    /// True once the to-dos of every note search knows have been read.
    private(set) var isReady = false
    /// Called after the to-dos changed: their notifications are scheduled again.
    @ObservationIgnored var onChange: (() -> Void)?

    /// What each note had, by its address, with the date and size it had then.
    @ObservationIgnored private var cache: [String: Cached] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wanted: (entries: [String: SearchIndex.Entry], hidden: [String])?

    private struct Cached: Sendable {
        var modified: Date?
        var size: Int?
        var todos: [Todo]
    }

    /// Reads the to-dos again from what search knows now. Called whenever it changed: one reading at a time, and after
    /// a burst of changes one for all of them.
    func update(entries: [String: SearchIndex.Entry], hidden: [String], built: Bool) {
        wanted = (entries, hidden)
        if built { buildDone = true }
        guard task == nil else { return }
        readNext()
    }

    @ObservationIgnored private var buildDone = false

    private func readNext() {
        guard let (entries, hidden) = wanted else { return }
        wanted = nil
        let cache = self.cache
        let ready = buildDone
        task = Task.detached(priority: .utility) { [weak self] in
            let (items, fresh) = Self.read(entries, hidden: hidden, cache: cache)
            await self?.finished(items, cache: fresh, ready: ready)
        }
    }

    private func finished(_ fresh: [Item], cache: [String: Cached], ready: Bool) {
        task = nil
        self.cache = cache
        var fresh = fresh
        applyPatches(to: &fresh)
        let changed = fresh != items
        if changed { items = fresh }
        let becameReady = ready && !isReady
        if becameReady { isReady = true }
        if changed || becameReady { onChange?() }
        readNext()
    }

    // MARK: - Changes not yet read

    /// A change Notebook just made to a to-do, shown until its note has been read again.
    private struct Patch {
        var url: URL
        /// The to-do's line before the change.
        var source: String
        var line: Int
        /// When the note had last changed, as read then: a reading with another date has the change, or a later one.
        var modified: Date?
        /// The to-do after the change; nil once it is done or deleted.
        var todo: Todo?
        var until: Date
    }

    @ObservationIgnored private var patches: [Patch] = []

    /// Shows a change to a to-do at once, before its note is read again: what its line says now, and the lines under it
    /// when they changed too; without a line, the to-do was deleted.
    func patch(_ todo: TodoReference, to source: String?, under: [String]?) {
        guard let index = Self.index(of: todo.source, in: todo.url, near: todo.line, among: items) else { return }
        let old = items[index].todo
        patches.removeAll { FileNode.samePath($0.url, todo.url) && $0.source == todo.source }
        patches.append(Patch(url: todo.url, source: todo.source, line: old.line, modified: items[index].modified,
                             todo: source.flatMap { Self.todo([$0] + (under ?? old.lines.map(\.source)), line: old.line) },
                             until: .now.addingTimeInterval(10)))
        var changed = items
        applyPatches(to: &changed)
        guard changed != items else { return }
        items = changed
        onChange?()
    }

    /// A change that couldn't be written: the note, read again, shows what is there.
    func unpatch(_ todo: TodoReference) {
        patches.removeAll { FileNode.samePath($0.url, todo.url) && $0.source == todo.source }
    }

    /// The changes in `items` that a reading may not have caught up with yet.
    private func applyPatches(to items: inout [Item]) {
        // Read again since the change: the note says what it says now.
        patches.removeAll { patch in
            patch.until < .now || items.contains { FileNode.samePath($0.url, patch.url) && $0.modified != patch.modified }
        }
        for patch in patches {
            guard let index = Self.index(of: patch.source, in: patch.url, near: patch.line, among: items) else { continue }
            if let todo = patch.todo { items[index].todo = todo } else { items.remove(at: index) }
        }
    }

    private static func index(of source: String, in url: URL, near line: Int, among items: [Item]) -> Int? {
        items.indices.filter { FileNode.samePath(items[$0].url, url) && items[$0].todo.source == source }
            .min { abs(items[$0].todo.line - line) < abs(items[$1].todo.line - line) }
    }

    /// An open to-do made of its line and the lines under it, read on their own: nil once it is done.
    nonisolated static func todo(_ lines: [String], line: Int) -> Todo? {
        guard let first = lines.first else { return nil }
        // Without the to-do's indent, which on its own would make it code.
        let indent = String(first.prefix { $0 == " " || $0 == "\t" })
        let alone = lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0.trimmingCharacters(in: .whitespaces) }
        guard var todo = Todos.open(in: alone.joined(separator: "\n")).first, todo.line == 0 else { return nil }
        todo.line = line
        todo.source = first
        for index in todo.lines.indices where index + 1 < lines.count {
            let original = lines[index + 1]
            let removed = original.count - alone[index + 1].count
            todo.lines[index].source = original
            todo.lines[index].prefix = String(original.prefix(removed)) + todo.lines[index].prefix
        }
        return todo
    }

    nonisolated private static func read(_ entries: [String: SearchIndex.Entry], hidden: [String], cache: [String: Cached]) -> ([Item], [String: Cached]) {
        var fresh: [String: Cached] = [:]
        var notes: [(entry: SearchIndex.Entry, todos: [Todo])] = []
        for (path, entry) in entries where entry.kind == .note {
            guard let text = entry.text, !SearchIndex.isHidden(path, in: hidden) else { continue }
            let todos: [Todo]
            if let kept = cache[path], kept.modified == entry.modified, kept.size == entry.size {
                todos = kept.todos
            } else {
                todos = Todos.open(in: text)
            }
            fresh[path] = Cached(modified: entry.modified, size: entry.size, todos: todos)
            if !todos.isEmpty { notes.append((entry, todos)) }
        }
        notes.sort { a, b in
            let aDate = a.entry.modified ?? .distantPast, bDate = b.entry.modified ?? .distantPast
            return aDate != bDate ? aDate > bDate : a.entry.path < b.entry.path
        }
        let items = notes.flatMap { note in
            note.todos.map { Item(url: note.entry.url, note: note.entry.name, modified: note.entry.modified, todo: $0) }
        }
        return (items, fresh)
    }
}

/// A to-do somewhere in a note: the note, its line then, and what that line said, to find it again after the note changed.
struct TodoReference: Hashable, Identifiable, Sendable {
    var url: URL
    var line: Int
    var source: String

    var id: String { url.path + "\u{0}\(line)\u{0}" + source }
}

/// A note with a reminder, as To-dos shows it among the to-dos.
struct NoteReminderRow: Hashable {
    var reminder: Reminder
    var url: URL?
    var name: String
}

/// A row of To-dos: an open to-do, or a note with a reminder.
enum TodoRow: Identifiable, Hashable {
    case todo(TodoList.Item)
    case note(NoteReminderRow)

    var id: String {
        switch self {
        case .todo(let item): item.id
        case .note(let note): "note\u{0}" + note.reminder.id.uuidString
        }
    }

    /// When it is due: a to-do's day (its start) or time, a note's time.
    var date: Date? {
        switch self {
        case .todo(let item): item.todo.due?.date()
        case .note(let note): note.reminder.date
        }
    }

    var hasTime: Bool {
        switch self {
        case .todo(let item): item.todo.due?.hasTime ?? false
        case .note(let note): note.reminder.date != nil
        }
    }

    var isOverdue: Bool {
        switch self {
        case .todo(let item): item.todo.due?.isOverdue() ?? false
        case .note(let note): note.reminder.isOverdue
        }
    }

    var place: TodoPlace? {
        switch self {
        case .todo(let item): item.todo.place
        case .note(let note): note.reminder.place
        }
    }
}

/// A group of To-dos: what is overdue, today's, tomorrow's, the rest of the coming week's, later ones, and those
/// without a date.
struct TodoSection: Identifiable, Hashable {
    enum Kind: Int, CaseIterable, Hashable {
        case overdue, today, tomorrow, week, later, someday
    }

    var kind: Kind
    var rows: [TodoRow]
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .week: "Next 7 Days"
        case .later: "Later"
        case .someday: "No Date"
        }
    }

    /// The day a to-do dragged into the group gets: today, tomorrow, the first day after tomorrow, a week and a day
    /// from now; none for No Date. Nil for Overdue, where nothing can go.
    static func day(for kind: Kind, now: Date = .now, calendar: Calendar = .current) -> Date?? {
        let today = calendar.startOfDay(for: now)
        func inDays(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }
        switch kind {
        case .overdue: return nil
        case .today: return .some(today)
        case .tomorrow: return .some(inDays(1))
        case .week: return .some(inDays(2))
        case .later: return .some(inDays(8))
        case .someday: return .some(nil)
        }
    }
}

enum TodoGroups {
    /// The groups that have something in them, in order. Dated rows go by their time (a day without a time first on
    /// its day), the rest by note, as the notes were last changed.
    static func sections(todos: [TodoList.Item], notes: [NoteReminderRow], now: Date = .now, calendar: Calendar = .current) -> [TodoSection] {
        var groups: [TodoSection.Kind: [TodoRow]] = [:]
        for row in notes.map(TodoRow.note) + todos.map(TodoRow.todo) {
            groups[kind(of: row, now: now, calendar: calendar), default: []].append(row)
        }
        return TodoSection.Kind.allCases.compactMap { kind in
            guard var rows = groups[kind] else { return nil }
            if kind != .someday {
                // Stable: rows at the same time keep the order of their notes.
                rows = rows.enumerated().sorted { a, b in
                    let aDay = calendar.startOfDay(for: a.element.date ?? now), bDay = calendar.startOfDay(for: b.element.date ?? now)
                    if aDay != bDay { return aDay < bDay }
                    if a.element.hasTime != b.element.hasTime { return !a.element.hasTime }
                    if a.element.date != b.element.date { return (a.element.date ?? now) < (b.element.date ?? now) }
                    return a.offset < b.offset
                }.map(\.element)
            }
            return TodoSection(kind: kind, rows: rows)
        }
    }

    /// A row ticked a moment ago, which its group no longer has, back in it where it was while it shows ticked: after
    /// the nearest row that was above it then (`order`) and is still there, or first.
    static func keep(_ row: TodoRow, in rows: inout [TodoRow], order: [String]) {
        let ids = rows.map(\.id)
        let index = order.prefix { $0 != row.id }.reversed().lazy.compactMap { ids.firstIndex(of: $0) }.first.map { $0 + 1 } ?? 0
        rows.insert(row, at: index)
    }

    static func kind(of row: TodoRow, now: Date, calendar: Calendar) -> TodoSection.Kind {
        guard let date = row.date else { return .someday }
        let overdue: Bool = switch row {
        case .todo(let item): item.todo.due?.isOverdue(at: now, calendar: calendar) ?? false
        case .note(let note): (note.reminder.date ?? .distantFuture) <= now
        }
        if overdue { return .overdue }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        case 2...7: return .week
        default: return .later
        }
    }
}
