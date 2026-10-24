#if os(macOS)
import AppKit

/// The folders of notes opened from the Finder, outside your locations. The App Store build is sandboxed and gets only
/// the file it was handed, but renaming the note and keeping its pictures and drawings in `.assets` next to it need
/// the folder. So it asks for that folder once, the first time it is needed, and keeps a bookmark of it. Other builds
/// have no sandbox and never ask.
@MainActor
enum FolderAccess {
    private static let key = "folderAccess"
    private static var accessing: Set<String> = []

    /// In the sandbox, the app's home is its container.
    private static let isSandboxed = NSHomeDirectory().contains("/Library/Containers/")

    /// Whether Notebook may write in `folder`, asking for it when it may not yet. `why` ends the sentence
    /// "Notebook needs the folder “…” to …".
    static func ensure(_ folder: URL, to why: String) -> Bool {
        let folder = folder.standardizedFileURL
        guard isSandboxed, Workspace.shared.location(containing: folder) == nil, !accessing.contains(folder.path) else { return true }
        if resume(folder) { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "Notebook needs the folder “\(folder.lastPathComponent)” to \(why). Click Allow to let it."
        guard panel.runModal() == .OK, let chosen = panel.url, FileNode.samePath(chosen, folder) else { return false }
        if let bookmark = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[folder.path] = bookmark
            UserDefaults.standard.set(kept, forKey: key)
        }
        if chosen.startAccessingSecurityScopedResource() { accessing.insert(folder.path) }
        return true
    }

    /// Opens a folder allowed in an earlier run again, from its bookmark.
    private static func resume(_ folder: URL) -> Bool {
        guard let bookmark = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[folder.path] else { return false }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
              FileNode.samePath(url, folder), url.startAccessingSecurityScopedResource() else { return false }
        accessing.insert(folder.path)
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[folder.path] = fresh
            UserDefaults.standard.set(kept, forKey: key)
        }
        return true
    }
}
#endif
