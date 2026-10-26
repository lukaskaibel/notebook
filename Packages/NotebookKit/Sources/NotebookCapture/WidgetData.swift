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

        public init(rows: [TodoRow], isComplete: Bool) {
            self.rows = rows
            self.isComplete = isComplete
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

        public var id: String { path + "\u{0}\(line)\u{0}" + source }

        public init(kind: Kind, text: String, path: String, note: String, line: Int, source: String, due: Date, hasTime: Bool) {
            self.kind = kind
            self.text = text
            self.path = path
            self.note = note
            self.line = line
            self.source = source
            self.due = due
            self.hasTime = hasTime
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

    /// To-dos ticked in a widget, by their row's ID, for the app to write into their notes; until it has, the widget
    /// shows them ticked.
    public static var ticked: [TodoRow] {
        get { read([TodoRow].self, "ticked.json") ?? [] }
        set { write(newValue, "ticked.json") }
    }

    /// Hands a tick to the app, and tells it if it runs, as the share extension does.
    public static func tick(_ row: TodoRow) {
        var ticked = ticked
        guard !ticked.contains(where: { $0.id == row.id }) else { return }
        ticked.append(row)
        self.ticked = ticked
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification), nil, nil, true)
    }

    /// Posted when a to-do was ticked in a widget.
    public static let notification = "com.lukaskbl.Notebook.widgetTick" as CFString

    // MARK: - Notes

    /// A note as a widget shows it: its name, where it is, and its lines with their styles, read by the app.
    public struct Note: Codable, Hashable, Sendable {
        public var path: String
        public var title: String
        /// Where it is, as the sidebar leads to it: "iCloud Drive › Travel".
        public var place: String
        public var blocks: [Block]
        /// More of the note than the blocks hold.
        public var isCut: Bool

        public init(path: String, title: String, place: String, blocks: [Block], isCut: Bool) {
            self.path = path
            self.title = title
            self.place = place
            self.blocks = blocks
            self.isCut = isCut
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

    /// The notes chosen in widgets, by the ID each was chosen by (its path then), with where it is now and what it
    /// says. The app follows them when they are renamed or moved.
    public static var notes: [String: Note] {
        get { read([String: Note].self, "notes.json") ?? [:] }
        set { write(newValue, "notes.json") }
    }

    /// Notes to choose from in Edit Widget: the ones opened last, the favourites, then the ones changed last.
    public struct CatalogEntry: Codable, Hashable, Sendable {
        public var path: String
        public var title: String
        public var place: String

        public init(path: String, title: String, place: String) {
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
        guard let url = folder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: url, options: .atomic)
    }
}
