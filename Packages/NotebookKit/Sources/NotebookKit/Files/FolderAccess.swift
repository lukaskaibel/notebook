#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// The folders of notes opened from outside your locations: from the Finder on the Mac, from the Files app or a share
/// on iPhone and iPad. The sandbox gives the app only the file it was handed, but renaming the note and keeping its
/// pictures and drawings in `.assets` next to it need the folder. So Notebook asks for that folder once, the first
/// time it is needed, and keeps a bookmark of it. Mac builds outside the App Store have no sandbox and never ask;
/// iPhone and iPad always have one.
@MainActor
enum FolderAccess {
    private static let key = "folderAccess"
    private static var accessing: Set<String> = []

    #if os(macOS)
    /// In the sandbox, the app's home is its container.
    private static let isSandboxed = NSHomeDirectory().contains("/Library/Containers/")
    private static let resolving: URL.BookmarkResolutionOptions = [.withSecurityScope]
    private static let creating: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    // As for locations: a bookmark made from a URL the document picker gave carries its access along.
    private static let resolving: URL.BookmarkResolutionOptions = []
    private static let creating: URL.BookmarkCreationOptions = []
    private static var isAsking = false
    /// The folder picker's delegate, while it is up.
    private static var picking: FolderPick?
    #endif

    #if os(macOS)
    /// Whether Notebook may write in `folder`, asking for it when it may not yet. `why` ends the sentence
    /// "Notebook needs the folder “…” to …".
    static func ensure(_ folder: URL, to why: String) -> Bool {
        let folder = folder.standardizedFileURL
        guard isSandboxed, Workspace.shared.location(containing: folder) == nil, !accessing.contains(id(folder)) else { return true }
        if resume(folder) { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "Notebook needs the folder “\(folder.lastPathComponent)” to \(why). Click Allow to let it."
        guard panel.runModal() == .OK, let chosen = panel.url, FileNode.samePath(chosen, folder) else { return false }
        keep(chosen, for: folder)
        return true
    }
    #else
    /// Whether Notebook may write in `folder` now: a folder in a location or in Notebook's own, or one it was given.
    static func mayWrite(in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        return Workspace.shared.location(containing: folder) != nil || FileNode.isSameOrInside(folder, URL(fileURLWithPath: NSHomeDirectory()))
            || accessing.contains(id(folder)) || resume(folder)
    }

    /// Asks for `folder` when Notebook may not write in it yet: an alert that says why, then the folder picker open
    /// at it. `why` ends the sentence "Notebook needs the folder “…” to …". True once it may.
    static func ask(for folder: URL, to why: String) async -> Bool {
        let folder = folder.standardizedFileURL
        if mayWrite(in: folder) { return true }
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let name = folder.lastPathComponent
        let goesOn = await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Allow Access to “\(name)”?",
                                          message: "Notebook needs the folder “\(name)” to \(why). Tap Open on the next screen to let it.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in continuation.resume(returning: false) })
            let allow = UIAlertAction(title: "Continue", style: .default) { _ in continuation.resume(returning: true) }
            alert.addAction(allow)
            alert.preferredAction = allow
            guard let presenter else { return continuation.resume(returning: false) }
            presenter.present(alert, animated: true)
        }
        guard goesOn else { return false }
        let chosen: URL? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = folder
            let pick = FolderPick { continuation.resume(returning: $0) }
            picker.delegate = pick
            picking = pick
            guard let presenter else { return pick.finish(nil) }
            presenter.present(picker, animated: true)
        }
        picking = nil
        guard let chosen, FileNode.samePath(chosen, folder) else { return false }
        keep(chosen, for: folder)
        return true
    }

    /// What is in front, to put the alert and the picker over.
    private static var presenter: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first?.topmostPresented
    }
    #endif

    /// Starts using a folder you just gave, and keeps a bookmark of it for the next runs.
    private static func keep(_ chosen: URL, for folder: URL) {
        #if os(macOS)
        if chosen.startAccessingSecurityScopedResource() { accessing.insert(id(folder)) }
        #else
        // Given now, it counts for this run even where the system reports no access to start: asking again wouldn't
        // change that.
        _ = chosen.startAccessingSecurityScopedResource()
        accessing.insert(id(folder))
        #endif
        if let bookmark = try? chosen.bookmarkData(options: creating, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[id(folder)] = bookmark
            UserDefaults.standard.set(kept, forKey: key)
        }
    }

    /// Opens a folder allowed in an earlier run again, from its bookmark.
    private static func resume(_ folder: URL) -> Bool {
        guard let bookmark = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[id(folder)] else { return false }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolving, bookmarkDataIsStale: &isStale),
              FileNode.samePath(url, folder), url.startAccessingSecurityScopedResource() else { return false }
        accessing.insert(id(folder))
        if isStale, let fresh = try? url.bookmarkData(options: creating, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[id(folder)] = fresh
            UserDefaults.standard.set(kept, forKey: key)
        }
        return true
    }

    /// "/private/var/…" and "/var/…" are one folder.
    private static func id(_ folder: URL) -> String {
        HiddenFolders.withoutPrivate(folder.standardizedFileURL.path)
    }
}

#if os(iOS)
/// The folder picker's answer, for `FolderAccess.ask`: the folder chosen, or nil.
@MainActor
private final class FolderPick: NSObject, UIDocumentPickerDelegate {
    private var done: ((URL?) -> Void)?

    init(_ done: @escaping (URL?) -> Void) {
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    func finish(_ url: URL?) {
        done?(url)
        done = nil
    }
}
#endif
