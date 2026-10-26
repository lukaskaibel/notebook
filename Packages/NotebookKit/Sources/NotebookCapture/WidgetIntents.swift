import AppIntents
import Foundation

/// Ticks a to-do in the To-dos widget, as Reminders' widget does. The widget's extension can't write in the user's
/// folders, so the tick goes to the app (`WidgetData.tick`), which writes it into the note the way To-dos does, merged
/// with what is there; until then the widget shows the to-do ticked.
public struct TickTodoIntent: AppIntent {
    public static let title: LocalizedStringResource = "Tick To-do"
    public static let isDiscoverable = false

    @Parameter(title: "To-do") public var row: String

    public init() {}

    public init(_ row: WidgetData.TodoRow) {
        self.row = (try? String(data: JSONEncoder().encode(row), encoding: .utf8)) ?? ""
    }

    public func perform() async throws -> some IntentResult {
        if let data = row.data(using: .utf8), let row = try? JSONDecoder().decode(WidgetData.TodoRow.self, from: data) {
            WidgetData.tick(row)
        }
        return .result()
    }
}

/// A note to show in a widget, picked in Edit Widget from the notes the app lists for it (`WidgetData.catalog`). Its ID
/// is its path when it was picked; the app follows the note from there when it is renamed or moved.
public struct NoteEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    public static let defaultQuery = NoteQuery()

    public var id: String
    public var title: String
    public var place: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(place)", image: .init(systemName: "doc.text"))
    }

    public init(id: String, title: String, place: String) {
        self.id = id
        self.title = title
        self.place = place
    }
}

public struct NoteQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        let notes = WidgetData.notes
        let catalog = Dictionary(WidgetData.catalog.map { ($0.path, $0) }) { first, _ in first }
        return identifiers.map { id in
            if let note = notes[id] { return NoteEntity(id: id, title: note.title, place: note.place) }
            if let entry = catalog[id] { return NoteEntity(id: id, title: entry.title, place: entry.place) }
            return NoteEntity(id: id, title: URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent, place: "")
        }
    }

    /// The notes opened last and the favourites first, as the app lists them.
    public func suggestedEntities() async throws -> [NoteEntity] {
        WidgetData.catalog.prefix(50).map { NoteEntity(id: $0.path, title: $0.title, place: $0.place) }
    }

    /// Notes whose names have the words typed, in the app's order.
    public func entities(matching string: String) async throws -> [NoteEntity] {
        let words = string.split(separator: " ").map(String.init)
        return WidgetData.catalog
            .filter { entry in words.allSatisfy { entry.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .prefix(50)
            .map { NoteEntity(id: $0.path, title: $0.title, place: $0.place) }
    }
}

/// The Note widget's settings: which note it shows.
public struct NoteWidgetIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Note"
    public static let description = IntentDescription("Shows a note of your choice.")

    @Parameter(title: "Note") public var note: NoteEntity?

    public init() {}
}
