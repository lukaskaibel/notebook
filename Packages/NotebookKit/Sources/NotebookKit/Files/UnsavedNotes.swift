import Foundation
import Synchronization

/// What was typed in a note that couldn't be written (a full disk, a disk taken out, a folder Notebook may no longer
/// write to), kept as a note of its own once the note was left and trying again didn't help (`NoteDocument`). On the
/// Mac they are in Notebook's folder in Application Support, next to the versions of notes; on iPhone and iPad in
/// On My iPhone › Notebook, where the Files app shows them. Each is named after its note, and none is written over.
enum UnsavedNotes {
    private static let place = Mutex<URL>(defaultFolder)

    /// Where they are kept.
    static var folder: URL { place.withLock { $0 } }

    static var defaultFolder: URL {
        // Tests never write into the app's own folder.
        if ProcessInfo.isTesting {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Notebook unsaved notes \(UUID().uuidString)", isDirectory: true)
        }
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notebook", isDirectory: true)
            .appendingPathComponent("Unsaved Notes", isDirectory: true)
        #else
        return Workspace.onDeviceFolder.appendingPathComponent("Unsaved Notes", isDirectory: true)
        #endif
    }

    /// Keeps them in `folder` from now on: for a library given on the command line (tests, the sample notes), as its
    /// versions are, and for tests.
    static func keep(in folder: URL) {
        place.withLock { $0 = folder.standardizedFileURL }
    }

    /// Writes `text`, typed in `note`, as a note of its own here. Nil when that couldn't be written either. Off the main
    /// thread.
    static func keep(_ text: String, of note: URL) -> URL? {
        let folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return FileOperations.createNoteWithoutOverwriting(in: folder, title: note.deletingPathExtension().lastPathComponent, text: text)
    }

    /// Where they are, as you would find them: "On My iPhone › Notebook › Unsaved Notes", or, on the Mac, Notebook's
    /// folder Unsaved Notes.
    @MainActor
    static var placeName: String {
        #if os(iOS)
        if FileNode.samePath(folder, defaultFolder) { return "\(Location.onDeviceName) › Notebook › Unsaved Notes" }
        #endif
        return "Notebook’s folder “Unsaved Notes”"
    }
}

/// A note left whose text couldn't be written, for the app to say so (`NoteDocument.onUnsaved`).
@MainActor
struct UnsavedNote: Identifiable {
    let id = UUID()
    /// The note's file.
    var note: URL
    /// The note in Notebook's folder that keeps what was typed. Nil when that couldn't be written either: the note then
    /// waits for an answer (`tryAgain`, `letGo`), and quitting with it.
    var copy: URL?
    /// Why the note couldn't be written, as the system says it, when it did.
    var reason: String?
    /// What was typed: the whole note, as it was left.
    var text: String
    weak var document: NoteDocument?

    var name: String { note.deletingPathExtension().lastPathComponent }

    func tryAgain() { document?.tryAgainToSave() }

    func letGo() { document?.letGoOfUnsaved() }
}
