import Foundation

/// Every open to-do in the locations, for the To-dos list and their notifications. Read off the main thread from the
/// text search already keeps of every note, after it changed; a note that didn't change since isn't read again.
/// Folders you hide leave their to-dos out, as they leave search. After them, the to-dos in no note (`LooseTodos`).
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
        /// In no note: added in To-dos (`LooseTodos`).
        var isLoose = false

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
    /// What to read next: the notes search knows and the folders hidden, and the to-dos in no note.
    @ObservationIgnored private var entries: [String: SearchIndex.Entry] = [:]
    @ObservationIgnored private var hidden: [String] = []
    @ObservationIgnored private var loose: LooseTodos.Snapshot?
    /// The to-dos in no note as `items` has them: the reading of them last finished.
    @ObservationIgnored private var shownLoose: LooseTodos.Snapshot?
    @ObservationIgnored private var isWanted = false
    /// The to-dos in no note are read too: ready only once they have been.
    @ObservationIgnored var waitsForLoose = false

    private struct Cached: Sendable {
        var modified: Date?
        var size: Int?
        var todos: [Todo]
    }

    /// Reads the to-dos again from what search knows now. Called whenever it changed: one reading at a time, and after
    /// a burst of changes one for all of them.
    func update(entries: [String: SearchIndex.Entry], hidden: [String], built: Bool) {
        self.entries = entries
        self.hidden = hidden
        if built { buildDone = true }
        isWanted = true
        guard task == nil else { return }
        readNext()
    }

    /// The to-dos in no note were read again.
    func update(loose: LooseTodos.Snapshot) {
        self.loose = loose
        isWanted = true
        guard task == nil else { return }
        readNext()
    }

    @ObservationIgnored private var buildDone = false

    private func readNext() {
        guard isWanted else { return }
        isWanted = false
        let cache = self.cache
        let ready = buildDone && (!waitsForLoose || loose != nil)
        let entries = entries, hidden = hidden, loose = loose
        task = Task.detached(priority: .utility) { [weak self] in
            let (items, fresh) = Self.read(entries, hidden: hidden, loose: loose, cache: cache)
            await self?.finished(items, cache: fresh, ready: ready, loose: loose)
        }
    }

    private func finished(_ fresh: [Item], cache: [String: Cached], ready: Bool, loose: LooseTodos.Snapshot?) {
        task = nil
        self.cache = cache
        shownLoose = loose
        var fresh = fresh
        applyPatches(to: &fresh, read: true)
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
        /// A to-do Notebook just added: shown until its note is read again, also when the list doesn't have it yet.
        var added: Item?
    }

    @ObservationIgnored private var patches: [Patch] = []

    /// Shows a change to a to-do at once, before its note is read again: what its line says now, and the lines under it
    /// when they changed too; without a line, the to-do was deleted.
    func patch(_ todo: TodoReference, to source: String?, under: [String]?) {
        guard let index = Self.index(of: todo.source, in: todo.url, near: todo.line, among: items) else { return }
        let old = items[index].todo
        let changed = source.flatMap { Self.todo([$0] + (under ?? old.lines.map(\.source)), line: old.line) }
        // One just added and not read yet stays added, as it is now.
        // Another just added can say the same: it keeps its own.
        func isThis(_ patch: Patch) -> Bool {
            FileNode.samePath(patch.url, todo.url) && patch.source == todo.source && (patch.added == nil || patch.line == old.line)
        }
        var added = patches.first(where: isThis)?.added
        added?.todo = changed ?? old
        patches.removeAll(where: isThis)
        patches.append(Patch(url: todo.url, source: todo.source, line: old.line, modified: items[index].modified,
                             todo: changed, until: .now.addingTimeInterval(10), added: changed == nil ? nil : added))
        show()
    }

    /// Shows a to-do Notebook just added at once, before its note is read again: after the others of its note. It goes
    /// once a reading of the note after the one shown now has it.
    func add(_ item: Item) {
        var item = item
        item.modified = item.isLoose ? shownLoose?.modified : items.first { FileNode.samePath($0.url, item.url) }?.modified ?? item.modified
        patches.removeAll { FileNode.samePath($0.url, item.url) && $0.source == item.todo.source && $0.line == item.todo.line }
        patches.append(Patch(url: item.url, source: item.todo.source, line: item.todo.line, modified: item.modified, todo: item.todo,
                             until: .now.addingTimeInterval(10), added: item))
        show()
    }

    private func show() {
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
    /// `read`: `items` is what a reading of the notes found, not what shows.
    private func applyPatches(to items: inout [Item], read: Bool = false) {
        let loose = shownLoose
        patches.removeAll { patch in
            if patch.until < .now { return true }
            // One just added goes once a reading has it as it is now: a reading begun before its line was written is
            // of a note changed since, without it.
            if let added = patch.added {
                guard read, let todo = patch.todo else { return false }
                return items.contains { FileNode.samePath($0.url, added.url) && $0.todo.source == todo.source }
            }
            // Read again since the change: the note says what it says now.
            return items.contains { FileNode.samePath($0.url, patch.url) && $0.modified != patch.modified }
                || loose.map { FileNode.samePath($0.url, patch.url) && $0.modified != patch.modified } == true
        }
        for patch in patches {
            // One just added is where it was added: two added a moment apart can say the same, without words yet.
            let found = patch.added == nil ? Self.index(of: patch.source, in: patch.url, near: patch.line, among: items)
                : items.firstIndex { FileNode.samePath($0.url, patch.url) && $0.todo.source == patch.source && $0.todo.line == patch.line }
            guard let index = found else {
                if var added = patch.added, let todo = patch.todo {
                    added.todo = todo
                    let after = items.lastIndex { FileNode.samePath($0.url, added.url) }.map { $0 + 1 }
                    items.insert(added, at: after ?? (added.isLoose ? items.endIndex : 0))
                }
                continue
            }
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

    nonisolated private static func read(_ entries: [String: SearchIndex.Entry], hidden: [String], loose: LooseTodos.Snapshot?,
                                         cache: [String: Cached]) -> ([Item], [String: Cached]) {
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
        var items = notes.flatMap { note in
            note.todos.map { Item(url: note.entry.url, note: note.entry.name, modified: note.entry.modified, todo: $0) }
        }
        // Those in no note after them, in the order they were added.
        if let loose {
            let key = "\u{0}loose\u{0}" + loose.url.path
            let todos: [Todo]
            if let kept = cache[key], kept.modified == loose.modified, kept.size == loose.text.utf8.count {
                todos = kept.todos
            } else {
                todos = Todos.open(in: loose.text)
            }
            fresh[key] = Cached(modified: loose.modified, size: loose.text.utf8.count, todos: todos)
            items += todos.map { Item(url: loose.url, note: "", modified: loose.modified, todo: $0, isLoose: true) }
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
