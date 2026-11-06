import Foundation
import Synchronization

/// How Quick Look on the Mac reads what is next to a note in your locations: its pictures, drawings and the notes it
/// links to. Quick Look lets its extension read only the note, while the app may read the locations you added. A plain
/// bookmark, one made without a security scope, carries the access of whoever made it to whoever resolves it, as for
/// passing a file between processes. So the app keeps one to each location's folder, and to the folders it shows from
/// elsewhere (iCloud Drive's Desktop), in the App Group, made afresh whenever it looks at its locations
/// (LocationSurvey). The Quick Look extension resolves the one the note is in, and then reads the note's folder as
/// the app does (NotePreview).
///
/// The bookmarks the app keeps for itself can't do this: they are app-scoped, and resolve only in the app. Tried in
/// #318; no exception to the sandbox is involved.
enum QuickLookAccess {
    static let key = "quickLookFolders"

    /// Plain bookmarks to `folders`, by path; none for a folder that can't be reached. Off the main thread.
    nonisolated static func bookmarks(for folders: [URL]) -> [String: Data] {
        var bookmarks: [String: Data] = [:]
        for folder in folders {
            if let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[folder.standardizedFileURL.path] = bookmark
            }
        }
        return bookmarks
    }

    /// Keeps `bookmarks` for Quick Look, in place of those kept before.
    static func keep(_ bookmarks: [String: Data], in defaults: UserDefaults?) {
        guard let defaults, defaults.dictionary(forKey: key) as? [String: Data] != bookmarks else { return }
        defaults.set(bookmarks, forKey: key)
    }

    /// The folder kept for Quick Look that `note` is in, with access to it started for as long as the extension runs;
    /// nil when the note is in none, or its bookmark no longer finds it. Off the main thread.
    nonisolated static func open(for note: URL, in defaults: UserDefaults?) -> URL? {
        guard let kept = defaults?.dictionary(forKey: key) as? [String: Data] else { return nil }
        let path = HiddenFolders.withoutPrivate(note.standardizedFileURL.path)
        // The innermost folder first: a location can show folders from elsewhere that are inside another location.
        let folders = kept.keys.filter { path.hasPrefix(HiddenFolders.withoutPrivate($0) + "/") }.sorted { $0.count > $1.count }
        for folder in folders {
            if opened.withLock({ $0.contains(folder) }) { return URL(fileURLWithPath: folder, isDirectory: true) }
            var stale = false
            guard let bookmark = kept[folder],
                  let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            // Started once, and never stopped: the extension shows one note after another, often from the same folder.
            _ = url.startAccessingSecurityScopedResource()
            opened.withLock { _ = $0.insert(folder) }
            return url
        }
        return nil
    }

    /// The folders opened so far in this process.
    private static let opened = Mutex<Set<String>>([])
}
