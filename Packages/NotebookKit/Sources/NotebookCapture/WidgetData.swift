import Foundation

/// What the widgets show, kept by the app in the App Group: the extension can't read the user's folders. The app
/// writes it when the to-dos or a note shown in a widget change, and reloads the widgets then (`Workspace+Widgets` in
/// NotebookKit). The widgets only read it, except for the to-dos ticked in them, which go to the app as shared notes
/// do and are written into the notes by it.
public enum WidgetData {
    /// Where it is; nil in a build without the App Group. Tests set one of theirs.
    nonisolated(unsafe) public static var folder: URL? = AppGroup.folder("Widgets")

    /// The kinds of the widgets, for reloading them.
    public static let todosKind = "Todos"
    public static let noteKind = "Note"

    // MARK: - To-dos

    /// The to-dos that are overdue or due in the coming week (for the widget to move on at midnight by itself), with
    /// the notes that remind you then, as To-dos shows them.
    public struct Todos: Codable, Equatable, Sendable {
        public var rows: [TodoRow]
        /// False until the app has read every note once.
        public var isComplete: Bool
        /// How many overdue ones there are beyond those in `rows`, the oldest kept: they count, but aren't listed.
        public var overdueLeftOut: Int?

        public init(rows: [TodoRow], isComplete: Bool, overdueLeftOut: Int? = nil) {
            self.rows = rows
            self.isComplete = isComplete
            self.overdueLeftOut = overdueLeftOut
        }
    }

    public struct TodoRow: Codable, Hashable, Identifiable, Sendable {
        /// A to-do of a note, which can be ticked, or a note with a reminder.
        public enum Kind: String, Codable, Sendable { case todo, note }

        public var kind: Kind
        /// The words you read.
        public var text: String
        /// The note it is in, and its name.
        public var path: String
        public var note: String
        /// For a to-do, its line then and what the line said, to find it again.
        public var line: Int
        public var source: String
        /// When it is due: its day's start or its time.
        public var due: Date
        public var hasTime: Bool
        /// When the note was last changed as the app read it (seconds since 2001, to the nanosecond), to tell whether
        /// it changed since.
        public var modified: Double?
        /// The names of the to-do's notifications, which a tick in the widget takes back at once.
        public var notifications: [String]?

        public var id: String { path + "\u{0}\(line)\u{0}" + source }

        public init(kind: Kind, text: String, path: String, note: String, line: Int, source: String, due: Date, hasTime: Bool,
                    modified: Double? = nil, notifications: [String]? = nil) {
            self.kind = kind
            self.text = text
            self.path = path
            self.note = note
            self.line = line
            self.source = source
            self.due = due
            self.hasTime = hasTime
            self.modified = modified
            self.notifications = notifications
        }

        /// Overdue at `now`: a time that passed, or a day before today.
        public func isOverdue(at now: Date, calendar: Calendar = .current) -> Bool {
            hasTime ? due <= now : due < calendar.startOfDay(for: now)
        }

        /// Overdue or due today at `now`.
        public func isShown(at now: Date, calendar: Calendar = .current) -> Bool {
            due < calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? .distantFuture
        }
    }

    public static var todos: Todos? {
        get { read(Todos.self, "todos.json") }
        set { write(newValue, "todos.json") }
    }

    // MARK: - Ticking

    /// A to-do ticked in a widget, on its way to the app, which writes it into its note; until then the widget shows it
    /// ticked. With the notifications taken back for it, to give them back if it is unticked before that.
    public struct Tick: Codable, Equatable, Sendable {
        public var row: TodoRow
        /// The notifications that were waiting, archived (`UNNotificationRequest`).
        public var withdrawn: Data?

        public init(row: TodoRow, withdrawn: Data? = nil) {
            self.row = row
            self.withdrawn = withdrawn
        }
    }

    /// The ticks the app hasn't written yet, oldest first. A tick stays until the app has written it, or found there
    /// was nothing to write: one that couldn't be written waits for the next time.
    public static var ticks: [Tick] {
        guard let url = folder?.appendingPathComponent(ticksName) else { return [] }
        var ticks: [Tick] = []
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
            ticks = decoded([Tick].self, from: url) ?? []
        }
        return ticks
    }

    /// Ticks a to-do, or unticks one ticked by mistake that the app hasn't written yet, and tells the app if it runs,
    /// as the share extension does. Whether it is ticked now; unticked, what was taken back for it. Read and written
    /// in one coordinated go, as the app takes ticks away in the same way.
    @discardableResult
    public static func toggleTick(_ row: TodoRow) -> (ticked: Bool, withdrawn: Data?) {
        var result: (ticked: Bool, withdrawn: Data?) = (false, nil)
        changeTicks { ticks in
            if let index = ticks.firstIndex(where: { $0.row.id == row.id }) {
                result = (false, ticks.remove(at: index).withdrawn)
            } else {
                ticks.append(Tick(row: row))
                result = (true, nil)
            }
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification), nil, nil, true)
        return result
    }

    /// Keeps the notifications taken back for a tick.
    public static func keepWithdrawn(_ withdrawn: Data, for id: String) {
        changeTicks { ticks in
            if let index = ticks.firstIndex(where: { $0.row.id == id }) { ticks[index].withdrawn = withdrawn }
        }
    }

    /// Forgets a tick the app is done with, and says whether it was still there: not, when it was unticked meanwhile.
    public static func removeTick(_ id: String) -> Bool {
        var wasThere = false
        changeTicks { ticks in
            wasThere = ticks.contains { $0.row.id == id }
            ticks.removeAll { $0.row.id == id }
        }
        return wasThere
    }

    private static let ticksName = "ticked.json"

    private static func changeTicks(_ change: (inout [Tick]) -> Void) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(ticksName), options: .forMerging, error: nil) { url in
            var ticks = decoded([Tick].self, from: url) ?? []
            let before = ticks
            change(&ticks)
            guard ticks != before else { return }
            encoded(ticks, to: url)
        }
    }

    /// Posted when a to-do was ticked in a widget.
    public static let notification = "com.lukaskbl.Notebook.widgetTick" as CFString

    // MARK: - Notes

    /// A note as a widget shows it: its name, where it is, and its lines with their styles, read by the app.
    public struct Note: Codable, Hashable, Sendable {
        /// Why a widget doesn't show a note it was chosen for: thrown away or outside the locations, or in a folder
        /// you hid. It shows again once it is back.
        public enum Missing: String, Codable, Sendable { case gone, hidden }

        public var path: String
        public var title: String
        /// Where it is, as the sidebar leads to it: "iCloud Drive › Travel".
        public var place: String
        public var blocks: [Block]
        /// More of the note than the blocks hold.
        public var isCut: Bool
        /// Nil while it is shown; then its title, place and blocks are empty.
        public var missing: Missing?

        public init(path: String, title: String, place: String, blocks: [Block], isCut: Bool, missing: Missing? = nil) {
            self.path = path
            self.title = title
            self.place = place
            self.blocks = blocks
            self.isCut = isCut
            self.missing = missing
        }

        /// The note at a path, no longer shown, and why.
        public static func missing(_ why: Missing, path: String) -> Note {
            Note(path: path, title: "", place: "", blocks: [], isCut: false, missing: why)
        }
    }

    /// A line of a note: a heading, a point, a to-do, a quote or words, and its words in runs of one style each.
    public struct Block: Codable, Hashable, Sendable {
        public enum Kind: Codable, Hashable, Sendable {
            case heading(Int)
            case bullet
            case ordered(String)
            case todo(done: Bool)
            case quote
            case text
        }

        public var kind: Kind
        /// How deep a point sits in its list, from 0.
        public var depth: Int
        public var runs: [Run]

        public init(kind: Kind, depth: Int = 0, runs: [Run]) {
            self.kind = kind
            self.depth = depth
            self.runs = runs
        }
    }

    public struct Run: Codable, Hashable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var struck = false
        public var code = false
        public var highlight = false
        public var link = false

        public init(_ text: String, bold: Bool = false, italic: Bool = false, struck: Bool = false, code: Bool = false,
                    highlight: Bool = false, link: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.struck = struck
            self.code = code
            self.highlight = highlight
            self.link = link
        }
    }

    /// The notes chosen in widgets, by the ID each was chosen by (`noteID`), with where it is now and what it says.
    /// The app follows them when they are renamed or moved.
    public static var notes: [String: Note] {
        get { read([String: Note].self, "notes.json") ?? [:] }
        set { write(newValue, "notes.json") }
    }

    /// The ID a note is chosen by: when it was made, and its path then. Its own, unlike its path, which another note
    /// can have later, once it moved.
    public static func noteID(path: String, created: Date?) -> String {
        "\(Int(created?.timeIntervalSince1970 ?? 0))|" + path
    }

    /// When the note chosen by an ID was made, to the second; nil when the ID doesn't say.
    public static func noteCreated(id: String) -> Int? {
        guard let bar = id.firstIndex(of: "|"), let seconds = Int(id[..<bar]), seconds != 0 else { return nil }
        return seconds
    }

    /// The path a note had when it was chosen.
    public static func notePath(id: String) -> String {
        // An ID from before it said when the note was made is its path.
        guard let bar = id.firstIndex(of: "|"), Int(id[..<bar]) != nil else { return id }
        return String(id[id.index(after: bar)...])
    }

    /// Notes to choose from in Edit Widget: the ones opened last, the favourites, then the ones changed last.
    public struct CatalogEntry: Codable, Hashable, Sendable {
        /// What it is chosen by (`noteID`).
        public var id: String
        public var path: String
        public var title: String
        public var place: String

        public init(id: String, path: String, title: String, place: String) {
            self.id = id
            self.path = path
            self.title = title
            self.place = place
        }
    }

    public static var catalog: [CatalogEntry] {
        get { read([CatalogEntry].self, "catalog.json") ?? [] }
        set { write(newValue, "catalog.json") }
    }

    // MARK: - Opening the app

    /// What a tap in a widget opens: To-dos, a to-do in its note, or a note chosen in a widget.
    public static let todosURL = URL(string: "notebook-widget:todos")!

    public static func url(todo row: TodoRow) -> URL {
        url("todo", ["path": row.path, "line": String(row.line), "source": row.source])
    }

    public static func url(note id: String) -> URL { url("note", ["id": id]) }

    private static func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "notebook-widget"
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    // MARK: - Files

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        folder.flatMap { decoded(type, from: $0.appendingPathComponent(name)) }
    }

    /// Whole or not at all, so a widget never reads half of it.
    private static func write<T: Encodable>(_ value: T?, _ name: String) {
        guard let folder else { return }
        let url = folder.appendingPathComponent(name)
        guard let value else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        encoded(value, to: url)
    }

    private static func decoded<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func encoded<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: url, options: .atomic)
    }
}
