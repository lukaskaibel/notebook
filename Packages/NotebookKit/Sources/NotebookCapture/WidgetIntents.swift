import AppIntents
import Foundation
import UserNotifications

/// Ticks a to-do in the To-dos widget, as Reminders' widget does, or unticks one ticked by mistake. The widget's
/// extension can't write in the user's folders, so the tick goes to the app (`WidgetData.toggleTick`), which writes it
/// into the note the way To-dos does, merged with what is there, the next time it runs; until then the widget shows
/// the to-do ticked. Its notifications go at once, and come back if it is unticked before the app wrote it.
public struct TickTodoIntent: AppIntent {
    public static let title: LocalizedStringResource = "Tick To-do"
    public static let isDiscoverable = false

    @Parameter(title: "To-do") public var row: String

    public init() {}

    public init(_ row: WidgetData.TodoRow) {
        self.row = (try? String(data: JSONEncoder().encode(row), encoding: .utf8)) ?? ""
    }

    public func perform() async throws -> some IntentResult {
        guard let data = row.data(using: .utf8), let row = try? JSONDecoder().decode(WidgetData.TodoRow.self, from: data) else { return .result() }
        let toggled = WidgetData.toggleTick(row)
        let names = (row.notifications ?? []).flatMap { [$0, $0 + ".place"] }
        guard !names.isEmpty else { return .result() }
        // The extension's notification center is the app's: the ones waiting are kept, to give back on an untick.
        let center = UNUserNotificationCenter.current()
        if toggled.ticked {
            let waiting = await center.pendingNotificationRequests().filter { names.contains($0.identifier) }
            center.removePendingNotificationRequests(withIdentifiers: names)
            center.removeDeliveredNotifications(withIdentifiers: names)
            if !waiting.isEmpty, let kept = Self.archived(waiting) { WidgetData.keepWithdrawn(kept, for: row.id) }
        } else if let kept = toggled.withdrawn {
            for request in Self.requests(from: kept) where Self.isToCome(request) { try? await center.add(request) }
        }
        return .result()
    }

    static func archived(_ requests: [UNNotificationRequest]) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: requests, requiringSecureCoding: true)
    }

    /// The notifications archived. Not with `unarchivedArrayOfObjects(ofClass:)`: on these it raises, which ends the
    /// extension.
    static func requests(from data: Data) -> [UNNotificationRequest] {
        (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: data)) as? [UNNotificationRequest] ?? []
    }

    /// Whether a notification given back would still come: a time that hasn't passed, or a place.
    private static func isToCome(_ request: UNNotificationRequest) -> Bool {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return request.trigger != nil }
        return trigger.nextTriggerDate() != nil
    }
}

/// A note to show in a widget, picked in Edit Widget from the notes the app lists for it (`WidgetData.catalog`). Its ID
/// says when the note was made and its path when it was picked (`WidgetData.noteID`); the app follows the note from
/// there when it is renamed or moved.
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
        let catalog = Dictionary(WidgetData.catalog.map { ($0.id, $0) }) { first, _ in first }
        return identifiers.map { id in
            if let note = notes[id] {
                switch note.missing {
                case nil: return NoteEntity(id: id, title: note.title, place: note.place)
                // Not even its name, in a folder you hid.
                case .hidden: return NoteEntity(id: id, title: "Hidden Note", place: "")
                case .gone: break
                }
            }
            if let entry = catalog[id] { return NoteEntity(id: id, title: entry.title, place: entry.place) }
            return NoteEntity(id: id, title: URL(fileURLWithPath: WidgetData.notePath(id: id)).deletingPathExtension().lastPathComponent, place: "")
        }
    }

    /// The notes opened last and the favourites first, as the app lists them.
    public func suggestedEntities() async throws -> [NoteEntity] {
        WidgetData.catalog.prefix(50).map { NoteEntity(id: $0.id, title: $0.title, place: $0.place) }
    }

    /// Notes whose names have the words typed, in the app's order.
    public func entities(matching string: String) async throws -> [NoteEntity] {
        let words = string.split(separator: " ").map(String.init)
        return WidgetData.catalog
            .filter { entry in words.allSatisfy { entry.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .prefix(50)
            .map { NoteEntity(id: $0.id, title: $0.title, place: $0.place) }
    }
}

/// The Note widget's settings: which note it shows.
public struct NoteWidgetIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Note"
    public static let description = IntentDescription("Shows a note of your choice.")

    @Parameter(title: "Note") public var note: NoteEntity?

    public init() {}
}
