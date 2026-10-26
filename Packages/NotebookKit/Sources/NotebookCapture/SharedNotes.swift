import Foundation

/// Something shared to Notebook from another app: text, a link, pictures and files, for a new note in the default
/// folder or for the end of the note opened last. The share extension can't write in the user's folders (the Mac
/// app's bookmarks work only in the app, and On My iPhone is in the app's own container), so it leaves what was shared
/// in the App Group's container, and the app writes it into the note with its own saving as soon as it runs
/// (`QuickCapture` in NotebookKit).
public struct SharedNote: Codable, Equatable, Sendable {
    public enum Destination: Codable, Equatable, Sendable {
        case newNote
        /// The end of the note at this path, the one opened last in Notebook when it was shared.
        case endOf(path: String)
    }

    public var id: UUID
    public var date: Date
    public var destination: Destination
    /// The new note's name, from the link's page or the text's first line; nil for "Untitled".
    public var title: String?
    /// The text, with the link in it as Markdown.
    public var text: String
    /// The pictures and files, by their names among the note's files, in the order they were shared.
    public var files: [String]

    public init(id: UUID = UUID(), date: Date = Date(), destination: Destination, title: String?, text: String, files: [String]) {
        self.id = id
        self.date = date
        self.destination = destination
        self.title = title
        self.text = text
        self.files = files
    }
}

/// The notes shared to Notebook that it hasn't written yet, each in a folder of its own with its files.
public enum SharedNotes {
    /// Where they wait, in the App Group's container; nil in a build without the App Group. Tests set one of theirs.
    nonisolated(unsafe) public static var folder: URL? = AppGroup.folder("Shared Notes")

    private static let partial = ".partial"
    private static let manifest = "note.json"

    /// Leaves a note for the app, moving its files there under the names it gives them: they are copies of the
    /// extension's own, and moved they take no time and no room twice. Whole or not at all: it is written under a
    /// name the app passes over and then renamed. Not on the main thread: a file on another volume is copied.
    public static func add(_ note: SharedNote, moving files: [(url: URL, name: String)]) throws {
        guard let folder else { throw CocoaError(.featureUnsupported) }
        let manager = FileManager.default
        let writing = folder.appendingPathComponent(note.id.uuidString + partial, isDirectory: true)
        try manager.createDirectory(at: writing, withIntermediateDirectories: true)
        do {
            for file in files {
                try manager.moveItem(at: file.url, to: writing.appendingPathComponent(file.name))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(note).write(to: writing.appendingPathComponent(manifest), options: .atomic)
            try manager.moveItem(at: writing, to: folder.appendingPathComponent(note.id.uuidString, isDirectory: true))
        } catch {
            try? manager.removeItem(at: writing)
            throw error
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification), nil, nil, true)
    }

    /// The notes waiting, oldest first, with the folder their files are in.
    public static func waiting() -> [(note: SharedNote, files: URL)] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let decoder = decoder
        return names.filter { !$0.hasSuffix(partial) && !$0.hasPrefix(".") }.compactMap { name in
            let files = folder.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: files.appendingPathComponent(manifest)),
                  let note = try? decoder.decode(SharedNote.self, from: data) else { return nil }
            return (note, files)
        }.sorted { $0.note.date < $1.note.date }
    }

    /// What a share extension stopped while leaving (a `.partial` folder an hour old) or what can't be read (a day
    /// old, in case it is still being written by something newer): what is left in the folder is deleted, as
    /// everything shared is once written.
    public static func removeLeftovers(now: Date = .now) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let manager = FileManager.default
        for name in names where !name.hasPrefix(".") {
            let item = folder.appendingPathComponent(name, isDirectory: true)
            let made = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            let manifest = item.appendingPathComponent(manifest)
            let readable = (try? Data(contentsOf: manifest)).map { (try? decoder.decode(SharedNote.self, from: $0)) != nil } ?? false
            if name.hasSuffix(partial) ? made < now.addingTimeInterval(-3600) : !readable && made < now.addingTimeInterval(-86400) {
                try? manager.removeItem(at: item)
            }
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Forgets a note once the app has written it.
    public static func remove(_ note: SharedNote) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(note.id.uuidString, isDirectory: true))
    }

    /// Posted to every process when a note is left, for the app to write it at once if it runs.
    public static let notification = "com.lukaskbl.Notebook.sharedNote" as CFString

    // MARK: - Where a note can go

    /// What the share extension offers: the default folder, by the name the app shows it under, and the note opened
    /// last. The app keeps them up to date whenever it goes to the background.
    public struct Places: Codable, Equatable, Sendable {
        public var defaultFolder: String
        public var lastNote: String?

        public init(defaultFolder: String, lastNote: String?) {
            self.defaultFolder = defaultFolder
            self.lastNote = lastNote
        }

        /// The note's name, as its title shows it.
        public var lastNoteTitle: String? {
            lastNote.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        }
    }

    /// The App Group's settings, which both read. Tests set their own.
    nonisolated(unsafe) public static var defaults: UserDefaults? = AppGroup.defaults

    public static var places: Places? {
        get { defaults?.data(forKey: "places").flatMap { try? JSONDecoder().decode(Places.self, from: $0) } }
        set { defaults?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "places") }
    }
}
