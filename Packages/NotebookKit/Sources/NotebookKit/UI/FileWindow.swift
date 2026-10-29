#if os(macOS)
import AppKit
import SwiftUI

/// A Markdown file opened on its own (from the Finder, File › Open, dropped on the Dock icon, or double-clicked in the
/// sidebar): just the note in a plain window, no sidebar, no toolbar, the way Lettera opens a single file. Windows of
/// this kind join the system's window tabs. Folders opened the same ways go to the main window's sidebar.
@MainActor
public final class FileWindows {
    public static let shared = FileWindows()
    private var controllers: [String: FileWindowController] = [:]

    private init() {
        // The File and Edit menus and Revert To act on the note of the window you are working in: AppKit's main window,
        // which a sheet over it, or a panel such as Spelling, leaves as it is.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { Self.becameMain(window) }
        }
    }

    static func becameMain(_ window: NSWindow) {
        var window = window
        while let below = window.sheetParent ?? window.parent { window = below }
        let workspace = Workspace.shared
        let controller = window.windowController as? FileWindowController
        workspace.keyFileWindow = controller
        if workspace.keyFileNote !== controller?.noteDocument { workspace.keyFileNote = controller?.noteDocument }
        // Settings, say: no note to act on.
        let other = controller == nil && !workspace.isMainWindow(window)
        if workspace.isOtherWindowInFront != other { workspace.isOtherWindowInFront = other }
        // What was kept for Undo while the main window was closed, if it couldn't go there as it opened.
        if workspace.isMainWindow(window) { workspace.moveUndoToMainWindow() }
    }

    /// The notes at or inside a file or folder that are open in windows of their own.
    func urls(atOrInside url: URL) -> [URL] {
        controllers.values.map(\.url).filter { FileNode.isSameOrInside($0, url) }
    }

    /// Closes the windows of the notes at or inside a file or folder going to the Trash; what was typed in them is
    /// saved first, where they are.
    func close(atOrInside url: URL) {
        for controller in controllers.values where FileNode.isSameOrInside(controller.url, url) { controller.close() }
    }

    public func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = controllers[url.path] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = FileWindowController(url: url)
        controller.onClose = { [weak self] in self?.controllers[controller.url.path] = nil }
        controllers[url.path] = controller
        controller.showWindow(nil)
    }

    /// File › Open: any Markdown file, anywhere, or a folder such as iCloud Drive to show in the sidebar.
    public func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if Self.isFolder(url) { Workspace.shared.openFolder(url) } else { open(url) }
        }
    }

    /// Folders and notes from the Finder or the Dock icon.
    public func open(_ urls: [URL]) {
        for url in urls {
            if Self.isFolder(url) {
                Workspace.shared.openFolder(url)
            } else if FileKind(url: url, isDirectory: false) == .note {
                open(url)
            }
        }
    }

    /// A folder, not a package such as an app or a .textbundle.
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    var windows: [NSWindow] { controllers.values.compactMap(\.window) }

    /// Saves what was typed in every window now: Notebook goes to the background or quits, and a window left open as it
    /// quits isn't closed first, but its note is left.
    func saveAll(quitting: Bool) {
        for controller in controllers.values { controller.save(quitting: quitting) }
    }

    func refreshLinks() {
        for controller in controllers.values { controller.editor.refreshLinks() }
    }

    /// The editor of the window that shows a note, once its text is in.
    func editor(showing url: URL) -> EditorController? {
        // File events and the index can name "/tmp/…" "/private/tmp/…".
        guard let controller = controllers.values.first(where: { FileNode.samePath($0.url, url) }), controller.isLoaded else { return nil }
        return controller.editor
    }

    /// The notes the windows show with their text in, which may not have been saved yet.
    func notesShown() -> [(url: URL, text: String)] {
        controllers.values.filter(\.isLoaded).map { ($0.url, $0.editor.text) }
    }

    /// Writes the note a window shows, now.
    func save(showing url: URL) {
        controllers.values.first { FileNode.samePath($0.url, url) }?.save(quitting: false)
    }

    /// The pills of to-dos in every window: their times turn red when they pass.
    func refreshTodoPills() {
        for controller in controllers.values { controller.editor.refreshTodoPills() }
    }
}

@MainActor
final class FileWindowController: NSWindowController, NSWindowDelegate, EditorControllerDelegate {
    private(set) var url: URL
    private let note: NoteDocument
    var isLoaded: Bool { note.isLoaded }
    /// The note, for Revert To.
    var noteDocument: NoteDocument { note }
    let editor = EditorController()
    var onClose: (() -> Void)?

    init(url: URL) {
        self.url = url
        note = NoteDocument(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "NotebookFile"
        window.minSize = NSSize(width: 420, height: 320)
        window.backgroundColor = Theme.panel
        super.init(window: window)
        window.delegate = self
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.contentView = editor.view
        window.setFrameAutosaveName("NotebookFile")
        if window.frame.origin == .zero { window.center() }
        editor.delegate = self
        note.onExternalChange = { [weak self] text in self?.editor.reload(text: text) }
        note.onMove = { [weak self] url in self?.moved(to: url) }
        note.onDelete = { [weak self] in self?.window?.close() }
        // A note still in iCloud: its title now, its text once it has come down, and the wait in between.
        note.onLoad = { [weak self] text in
            guard let self else { return }
            self.editor.load(text: text, folder: self.url.deletingLastPathComponent(), title: self.url.deletingPathExtension().lastPathComponent, meta: "")
            self.window?.makeFirstResponder(self.editor.textView)
        }
        editor.load(text: note.isLoaded ? note.text : nil, folder: url.deletingLastPathComponent(), title: window.title, meta: "")
        let waiting = PassThroughHostingView(rootView: NoteWaitingView(note: note))
        waiting.sizingOptions = []
        waiting.frame = editor.scrollView.bounds
        waiting.autoresizingMask = [.width, .height]
        editor.scrollView.addSubview(waiting, positioned: .above, relativeTo: editor.scrollView.contentView)
        watchConflicts()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor.textView)
    }

    func windowWillClose(_ notification: Notification) {
        if Workspace.shared.keyFileNote === note {
            Workspace.shared.keyFileNote = nil
            Workspace.shared.keyFileWindow = nil
        }
        VersionsWindow.close(over: window)
        editor.endDrawing()
        note.update(text: editor.text)
        // Saved off the main thread; a conflict met then keeps both, as no one can be asked.
        note.close()
        onClose?()
    }

    func save(quitting: Bool) {
        editor.saveDrawingsNow(waiting: quitting)
        note.update(text: editor.text)
        note.keepCopyOfChanges()
        if quitting { note.close() } else { note.saveNow() }
    }

    /// The main window's workspace, for a note in one of its locations: links reach every note there, and a new title
    /// renames the note as the sidebar does, with links to it following. A note from elsewhere knows only the notes
    /// next to it.
    private var library: Workspace? {
        Workspace.shared.location(containing: url) != nil ? Workspace.shared : nil
    }

    private func moved(to url: URL) {
        self.url = url
        window?.title = url.deletingPathExtension().lastPathComponent
        window?.representedURL = url
        editor.setTitle(url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Conflicts

    private func watchConflicts() {
        withObservationTracking {
            _ = note.conflict
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.showConflict()
                self?.watchConflicts()
            }
        }
    }

    private func showConflict() {
        guard let conflict = note.conflict, let window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(window.title)” was changed somewhere else."
        alert.informativeText = "It changed on \(conflict.source) while you were editing it here. Keep both to have the other version as a copy next to it."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Keep This Version")
        alert.addButton(withTitle: "Use the Other Version")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let resolution: NoteDocument.Resolution = switch response {
            case .alertSecondButtonReturn: .keepThis
            case .alertThirdButtonReturn: .takeOther
            default: .keepBoth
            }
            self.editor.reload(text: self.note.resolve(resolution))
        }
    }

    // MARK: - EditorControllerDelegate

    func editorTextDidChange(_ editor: EditorController) {
        note.update(text: editor.text)
    }

    func editor(_ editor: EditorController, open target: LinkTarget.Kind) {
        switch target {
        case .url(let string):
            if let url = URL(string: string), url.scheme != nil { NSWorkspace.shared.open(url) }
        case .file(let url):
            if FileKind(url: url, isDirectory: false) == .note { FileWindows.shared.open(url) } else { NSWorkspace.shared.open(url) }
        case .note(let name):
            if let url = self.editor(editor, resolve: name) { FileWindows.shared.open(url) } else { NSSound.beep() }
        }
    }

    func editor(_ editor: EditorController, showTodoReminderOnLine line: Int, part: TodoPart) {
        Workspace.shared.askForTodoReminder(in: editor, url: url, line: line, part: part)
    }

    func editor(_ editor: EditorController, tickedRepeatingTodo source: String, line: Int, next: String) {
        Workspace.shared.repeatingTodoTicked(in: url, line: line, source: source, next: next)
    }

    func editor(_ editor: EditorController, quickLook url: URL) {
        QuickLookPanel.shared.show(url)
    }

    func editor(_ editor: EditorController, commitTitle title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.deletingPathExtension().lastPathComponent else { return }
        guard library != nil || FolderAccess.ensure(url.deletingLastPathComponent(), to: "rename this note") else {
            editor.setTitle(url.deletingPathExtension().lastPathComponent)
            return
        }
        // Off the main thread, as in the main window: in iCloud Drive the write can wait for iCloud. The note saves
        // what is typed meanwhile once it is done, under the new name.
        let (url, note, library) = (url, note, library)
        note.beginMove()
        Task {
            var next: LinkTargets?
            let renamed: URL?
            if let library {
                // As from the sidebar, which says so itself when the name is taken. Links to it follow there.
                renamed = await library.rename(url, to: name).value
            } else {
                // What the note, here and in any other window, is writing is written under the old name first.
                let documents = await NoteDocument.beginMoving(url)
                // The notes next to it, which are what its links and theirs find, as they are before it is renamed.
                (renamed, next) = await Task.detached(priority: .userInitiated) {
                    let targets = LinkTargets.reading(url.deletingLastPathComponent(), deep: false)
                    let renamed = FileOperations.rename(url, to: name, presenter: note)
                    if let renamed { NoteHistory.shared.follow(from: url, to: renamed) }
                    return (renamed, targets)
                }.value
                NoteDocument.endMoving(documents, from: url, to: renamed)
            }
            note.endMove(to: renamed)
            guard let renamed else {
                if library == nil { NSSound.beep() }
                editor.setTitle(url.deletingPathExtension().lastPathComponent)
                return
            }
            moved(to: renamed)
            // Links to it in the notes next to it follow it.
            if let next { Workspace.shared.followLinks(LinkUpdate.Move(from: url, to: renamed), from: Workspace.LinkSnapshot(targets: next)) }
        }
    }

    func editor(_ editor: EditorController, mayWriteIn folder: URL) -> Bool {
        library != nil || FolderAccess.ensure(folder, to: "keep this note's pictures and drawings next to it")
    }

    /// Notes next to this one, for `[[`, or every note of its location.
    func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] {
        if let library { return library.index.linkSuggestions(query, from: url) }
        let folder = url.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".md") && $0 != url.lastPathComponent }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(7)
        return names.map { LinkSuggestion(kind: .note, title: $0, detail: folder.lastPathComponent, insert: $0) }
    }

    func editor(_ editor: EditorController, resolve target: String) -> URL? {
        if let library { return library.index.resolve(target, from: url) }
        let folder = url.deletingLastPathComponent()
        let name = target.split(separator: "#").first.map(String.init) ?? target
        for candidate in [name, name + ".md"] {
            let file = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    func editorNoteName(_ editor: EditorController) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// SwiftUI over AppKit that clicks and scrolling go through.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Files opened from the Finder or dropped on the Dock icon open in windows of their own, folders in the sidebar, and notes
/// picked in Spotlight in the main window.
public final class NotebookAppDelegate: NSObject, NSApplicationDelegate {
    /// Before a click on a reminder's notification, which can be what started the app, reaches it.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ReminderNotifications.activate()
        }
    }

    /// Quitting waits for notes still being written, off the main thread, which keeps going meanwhile: a note open in
    /// two windows hears there when the other one wrote it. So it does for changes to to-dos, such as Move to Note….
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let workspace = Workspace.shared
            workspace.saveAll(quitting: true)
            PDFDrawingSession.saveAll()
            guard NoteDocument.isWriting || workspace.isWritingTodos || PDFInk.isWriting else { return .terminateNow }
            // The to-dos and PDFs are waited for ten seconds at most: quitting never gets stuck.
            let reply = QuitReply()
            Task { @MainActor in
                await workspace.todosWritten()
                await withCheckedContinuation { done in PDFInk.whenWritten { done.resume() } }
                reply.send()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                reply.send()
            }
            return .terminateLater
        }
    }

    /// Notes are written as you switch to another app, whichever of Notebook's windows are open.
    public func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { Workspace.shared.saveAll() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Workspace.shared.saveAll(quitting: true) }
    }

    /// Closing the window leaves Notebook running, as Notes does: the Dock icon and Window › Notebook bring it back,
    /// and SwiftUI would otherwise quit an app whose one window is closed.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // A tap in a widget: New Note, To-dos, a to-do or a note.
            let files = urls.filter { !QuickCapture.open($0) }
            if !files.isEmpty { FileWindows.shared.open(files) }
        }
    }

    /// A note picked in Spotlight, or its Search in App, also when that is what started the app.
    public func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        MainActor.assumeIsolated {
            Workspace.shared.continueActivity(userActivity)
        }
    }
}

/// Lets quitting go on once, when the to-dos are written or the wait for them is over, and the notes are written.
@MainActor
private final class QuitReply {
    private var isSent = false

    func send() {
        guard !isSent else { return }
        isSent = true
        NoteDocument.whenAllWritten { NSApp.reply(toApplicationShouldTerminate: true) }
    }
}
#endif
