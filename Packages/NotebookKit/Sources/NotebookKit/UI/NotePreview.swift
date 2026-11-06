#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os

/// A note as Quick Look shows it, in the Finder, the Files app and wherever else Space or a tap looks at one: in
/// Notebook's own editor, as Notebook shows it, with its title and when it was last changed on top, but read only. Its
/// text can still be selected and copied. Used by the Quick Look extension (NotebookQuickLook).
///
/// Nothing here draws a note: whatever changes in how the editor shows notes shows in Quick Look too. Only what Quick
/// Look can't do is left out: the editor doesn't change the note, and doesn't look for pictures and links beyond the
/// note's folder.
///
/// Quick Look lets the extension read only the note, on the Mac as on iPhone and iPad (Config/QuickLook.xcconfig), so
/// its pictures show by their names and its links as links. On the Mac a note in one of Notebook's locations is the
/// exception: the app leaves a bookmark to each location's folders for Quick Look (QuickLookAccess), which opens the
/// note's folder. Where the folder can be read, so also in the iOS Simulator, which has no sandbox, what is next to the
/// note is read in the background, and a folder slow to read doesn't hold the note up: it shows meanwhile and gets its
/// pictures once the folder is read.
///
/// A thumbnail (NoteThumbnail) shows the note the same way, but only its top and never what is next to it.
@MainActor
public final class NotePreview: EditorControllerDelegate {
    public let editor: EditorController
    /// For a thumbnail: the Finder asks for them as you browse, so only the note is read, never its folder, even where
    /// it could be. Without the folder, its pictures show by their names and links as links
    /// (EditorController.isFolderOutOfReach).
    let isThumbnail: Bool
    /// The note's folder once what is in it could be read; nil before, and when it can't be.
    private var folder: URL?
    /// What is in the note's folder and its `.assets`, by path in lower case.
    private var files: [String: String] = [:]

    public convenience init() { self.init(thumbnail: false) }

    init(thumbnail: Bool) {
        isThumbnail = thumbnail
        // The typeface and heading marks set in Notebook now, before the editor takes them.
        NotebookSettings.shared.followAppLook()
        editor = EditorController()
        editor.delegate = self
        editor.isReadOnly = true
        editor.layoutManager.hidesEditingControls = true
        editor.layoutManager.picturesOutOfReach = true
        #if os(iOS)
        // Quick Look puts the note below its bar, yet tells it how much room the bar takes: the text view would blur
        // as much of the note's top, title and all, as if the bar were over it.
        editor.textView.topEdgeEffect.isHidden = true
        editor.textView.bottomEdgeEffect.isHidden = true
        #endif
    }

    #if os(macOS)
    public var view: NSView { editor.view }
    #else
    public var view: UIView { editor.view }
    #endif

    /// Reads the note at `url` in the background and shows it. Throws when it can't be read.
    public func show(_ url: URL) async throws {
        let (text, modified) = try await Task.detached(priority: .userInitiated) {
            guard let text = NoteDocument.decode(try Data(contentsOf: url)) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return (text, NoteDocument.modificationDate(url))
        }.value
        let title = url.deletingPathExtension().lastPathComponent
        let meta = Workspace.meta(modified: modified)
        if isThumbnail { return show(NoteThumbnail.top(of: text), title: title, meta: meta, files: nil, from: url) }
        let group = NotebookSettings.groupDefaults
        let reading = Task.detached(priority: .userInitiated) { () -> [String: String]? in
            #if os(macOS)
            // In one of Notebook's locations, the app's bookmark to it opens the note's folder.
            _ = QuickLookAccess.open(for: url, in: group)
            #endif
            return Self.files(nextTo: url)
        }
        // Most folders are read at once, and the note shows with everything in it. Otherwise it shows without them.
        if let files = await Self.value(of: reading, within: .milliseconds(400)) {
            show(text, title: title, meta: meta, files: files, from: url)
        } else {
            show(text, title: title, meta: meta, files: nil, from: url)
            Task { [weak self] in
                guard let files = await reading.value else { return }
                self?.show(text, title: title, meta: meta, files: files, from: url)
            }
        }
        // The app's Quick Look tip has done its work (QuickLookTip).
        if !Self.hasShownNote { NotebookSettings.groupDefaults?.set(true, forKey: Self.shownKey) }
    }

    private func show(_ text: String, title: String, meta: String, files: [String: String]?, from url: URL) {
        let shown = editor.storage.length > 0
        self.files = files ?? [:]
        folder = files == nil ? nil : url.deletingLastPathComponent()
        if shown {
            editor.load(text: text, folder: folder, title: title, meta: meta, syntax: NoteSyntax(url: url)) { $0 }
        } else {
            editor.load(text: text, folder: folder, title: title, meta: meta, syntax: NoteSyntax(url: url))
        }
    }

    /// How long reading the note's folder takes in tests, as for a slow one.
    nonisolated(unsafe) static var readingDelay: TimeInterval = 0

    /// The names of what is next to the note and in its `.assets`, or nil when the folder can't be read.
    nonisolated private static func files(nextTo url: URL) -> [String: String]? {
        if readingDelay > 0 { Thread.sleep(forTimeInterval: readingDelay) }
        let folder = url.deletingLastPathComponent()
        guard let here = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let assets = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".assets").path)) ?? []
        var files: [String: String] = [:]
        for name in here + assets.map({ ".assets/" + $0 }) { files[name.lowercased()] = name }
        return files
    }

    /// `task`'s value if it comes within `limit`; nil if it doesn't.
    nonisolated private static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let finish: @Sendable (T?) -> Void = { value in
                waiting.withLock { waiting in
                    defer { waiting = nil }
                    return waiting
                }?.resume(returning: value)
            }
            Task { finish(await task.value) }
            Task { try? await Task.sleep(for: limit); finish(nil) }
        }
    }

    private static let shownKey = "quickLookShowedNote"

    /// Quick Look has shown a note with this preview, rather than another app's, as the App Group remembers.
    static var hasShownNote: Bool { NotebookSettings.groupDefaults?.bool(forKey: shownKey) ?? false }

    public func editorTextDidChange(_ editor: EditorController) {}
    public func editor(_ editor: EditorController, open target: LinkTarget.Kind) {}
    public func editor(_ editor: EditorController, quickLook url: URL) {}
    public func editor(_ editor: EditorController, commitTitle title: String) {}
    public func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] { [] }
    public func editorNoteName(_ editor: EditorController) -> String { "" }
    public func editor(_ editor: EditorController, mayWriteIn folder: URL) -> Bool { false }

    /// `![[Kyoto.jpg]]` and `[[Plan]]` find what is next to the note or in its `.assets`: Quick Look doesn't have the
    /// rest of the library to look in.
    public func editor(_ editor: EditorController, resolve target: String) -> URL? {
        guard let folder, !target.isEmpty else { return nil }
        let name = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let names = (name as NSString).pathExtension.isEmpty ? NoteSyntax.noteExtensions.sorted().map { name + "." + $0 } + [name] : [name]
        for base in ["", ".assets/"] {
            for name in names {
                // A name with a folder in it isn't in the list, but the folder can be read by now.
                if let found = files[(base + name).lowercased()] { return folder.appendingPathComponent(found) }
                let url = folder.appendingPathComponent(base + name)
                if name.contains("/"), FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
