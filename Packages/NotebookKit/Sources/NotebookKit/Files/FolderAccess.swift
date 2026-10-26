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
    /// The folders given, by their address. On iPhone and iPad one covers the folders in it too.
    private static var accessing: Set<String> = []

    #if os(macOS)
    /// In the sandbox, the app's home is its container.
    private static let isSandboxed = NSHomeDirectory().contains("/Library/Containers/")

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
        if chosen.startAccessingSecurityScopedResource() { accessing.insert(id(folder)) }
        if let bookmark = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[id(folder)] = bookmark
            UserDefaults.standard.set(kept, forKey: key)
        }
        return true
    }

    /// Opens a folder allowed in an earlier run again, from its bookmark.
    private static func resume(_ folder: URL) -> Bool {
        guard let bookmark = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[id(folder)] else { return false }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
              FileNode.samePath(url, folder), url.startAccessingSecurityScopedResource() else { return false }
        accessing.insert(id(folder))
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[id(folder)] = fresh
            UserDefaults.standard.set(kept, forKey: key)
        }
        return true
    }
    #else
    private static var isAsking = false
    /// The folder picker's delegate, while it is up.
    private static var picking: FolderPick?
    /// The folders given in earlier runs being opened again, off the main thread, once a run: `ask` waits for it.
    private static var resuming: Task<Void, Never>?

    /// Whether Notebook may write in `folder` now: a folder in a location or in Notebook's own, or in one it was given.
    /// Quick enough for every picture: the bookmarks of earlier runs are opened in the background.
    static func mayWrite(in folder: URL) -> Bool {
        resumeKept()
        let folder = folder.standardizedFileURL
        return Workspace.shared.location(containing: folder) != nil || FileNode.isSameOrInside(folder, URL(fileURLWithPath: NSHomeDirectory()))
            || accessing.contains { FileNode.isSameOrInside(folder, URL(fileURLWithPath: $0)) }
    }

    /// Asks for `folder` when Notebook may not write in it yet: an alert that says why, then the folder picker open
    /// at it. `why` ends the sentence "Notebook needs the folder “…” to …". True once it may.
    static func ask(for folder: URL, to why: String) async -> Bool {
        let folder = folder.standardizedFileURL
        resumeKept()
        await resuming?.value
        if mayWrite(in: folder) { return true }
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let name = folder.lastPathComponent
        let allow = UIAlertController(title: "Allow Access to “\(name)”?",
                                      message: "Notebook needs the folder “\(name)” to \(why). Tap Open on the next screen to let it.",
                                      preferredStyle: .alert)
        guard await answer(allow, cancel: "Not Now", go: "Continue") else { return false }
        while let chosen = await pickFolder(at: folder) {
            // The folder itself, or one it is in.
            if FileNode.isSameOrInside(folder, chosen) {
                keep(chosen)
                return true
            }
            let other = UIAlertController(title: "Choose “\(name)”",
                                          message: "Notebook needs the folder “\(name)”, or a folder it is in, to \(why). “\(chosen.lastPathComponent)” is somewhere else.",
                                          preferredStyle: .alert)
            guard await answer(other, cancel: "Cancel", go: "Choose Again") else { return false }
        }
        return false
    }

    /// Opens the folders given in earlier runs again from their bookmarks, off the main thread. One that doesn't open
    /// any more isn't tried again until the next run.
    private static func resumeKept() {
        guard resuming == nil else { return }
        let kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        resuming = Task {
            // As for locations: a bookmark made from a URL the document picker gave carries its access along.
            let opened = await Task.detached(priority: .userInitiated) { () -> [(key: String, url: URL, fresh: Data?)] in
                kept.compactMap { key, bookmark in
                    var isStale = false
                    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &isStale),
                          url.startAccessingSecurityScopedResource() else { return nil }
                    return (key, url, isStale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil)
                }
            }.value
            var fresh = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            for folder in opened {
                accessing.insert(id(folder.url))
                if let bookmark = folder.fresh { fresh[folder.key] = bookmark }
            }
            if opened.contains(where: { $0.fresh != nil }) { UserDefaults.standard.set(fresh, forKey: key) }
        }
    }

    /// Starts using a folder you just gave, and keeps a bookmark of it, made off the main thread, for the next runs.
    private static func keep(_ chosen: URL) {
        // Given now, it counts for this run even where the system reports no access to start: asking again wouldn't
        // change that.
        _ = chosen.startAccessingSecurityScopedResource()
        let chosenKey = id(chosen)
        accessing.insert(chosenKey)
        Task {
            guard let bookmark = await Task.detached(priority: .utility, operation: {
                try? chosen.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }).value else { return }
            var kept = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            kept[chosenKey] = bookmark
            UserDefaults.standard.set(kept, forKey: key)
        }
    }

    /// Shows an alert with two buttons and waits for one: true for `go`. False when it couldn't be shown.
    private static func answer(_ alert: UIAlertController, cancel: String, go: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in reply.give(false) })
            let action = UIAlertAction(title: go, style: .default) { _ in reply.give(true) }
            alert.addAction(action)
            alert.preferredAction = action
            Task {
                if await !present(alert) { reply.give(false) }
            }
        }
    }

    /// The folder picker, open at `folder`, and the folder chosen in it: nil for Cancel.
    private static func pickFolder(at folder: URL) async -> URL? {
        defer { picking = nil }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = folder
        let chosen: URL? = await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let pick = FolderPick { reply.give($0) }
            picker.delegate = pick
            picking = pick
            Task {
                if await !present(picker) { reply.give(nil) }
            }
        }
        // It answers before it closes, and what is put over it meanwhile would close with it.
        for _ in 0..<100 where picker.presentingViewController != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return chosen
    }

    /// Puts `controller` in front once nothing is on its way in or out: a picker closed a moment ago, the camera's or
    /// Photos', is still leaving, and UIKit drops what is put over it meanwhile. True once it is in front; false when
    /// it can't be shown.
    private static func present(_ controller: UIViewController) async -> Bool {
        for _ in 0..<100 {
            guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                return false
            }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            if !top.isBeingDismissed, !top.isBeingPresented, top.transitionCoordinator == nil {
                return await withCheckedContinuation { continuation in
                    let reply = Reply(continuation)
                    top.present(controller, animated: true) { reply.give(true) }
                    // An alert is on its way at once unless UIKit won't show it. The folder picker fetches its view first
                    // and comes a few seconds later; one that never does gives up in the end.
                    if controller is UIAlertController, controller.presentingViewController == nil { reply.give(false) }
                    Task {
                        try? await Task.sleep(for: .seconds(60))
                        reply.give(false)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    #endif

    /// "/private/var/…" and "/var/…" are one folder.
    private static func id(_ folder: URL) -> String {
        HiddenFolders.withoutPrivate(folder.standardizedFileURL.path)
    }
}

#if os(iOS)
/// Resumes a continuation once: with the answer given, or with what says it couldn't be asked.
@MainActor
private final class Reply<Value> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func give(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The folder picker's answer, for `FolderAccess.ask`: the folder chosen, or nil.
@MainActor
private final class FolderPick: NSObject, UIDocumentPickerDelegate {
    private let done: (URL?) -> Void

    init(_ done: @escaping (URL?) -> Void) {
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        done(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        done(nil)
    }
}
#endif
