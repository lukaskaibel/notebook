#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A change to files Notebook made, which Edit › Undo (⌘Z) takes back and Redo (⇧⌘Z) makes again, as in the Finder:
/// a file moved to the Trash comes back, a renamed or moved one goes back where it was, a new one goes to the Trash.
@MainActor
final class FileChange {
    enum Kind {
        /// Moved to the Trash: `before` is where it was, `after` its place in the Trash.
        case trash
        /// Renamed or moved, from `before` to `after`.
        case move
        /// Made (a note, a folder, a copy): at `after`, and while undone in the Trash, at `before`.
        case make
    }

    let kind: Kind
    /// What Edit › Undo says: Undo Move to Trash, Undo Rename, …
    let name: String
    /// Where the file is with the change undone and done, kept up to date as each is written.
    var before: URL?
    var after: URL?
    /// A rename whose links follow: not a new note getting its first name. Links always follow a move.
    var updatesLinks = false
    /// The links the rename or move rewrote, which Undo puts back.
    var links: LinkFollowing?
    /// What Notebook knew about a file it put in the Trash, for the file to come back with.
    var remembered: Remembered?
    /// The undo manager it is kept in.
    weak var manager: UndoManager?
    /// When it was done or undone last, counted with the changes to the note's text (`UndoOrder`).
    var order = 0
    /// Files changed with it, which Undo and Redo take back and bring again with it: all an import added besides the
    /// first.
    var parts: [FileChange] = []

    init(_ kind: Kind, _ name: String, from url: URL? = nil) {
        self.kind = kind
        self.name = name
        before = url
    }

    struct Remembered {
        /// The file's key and path then, which the keys of what was in it start with.
        var key: String
        var path: String
        /// The file that was open: it, or a note in the folder.
        var openFile: URL?
        var isFavorite: Bool
        var reminders: [Reminder]
        var hiddenFolders: [String]
    }
}

/// Counts the changes to the note's text and to files together, for an Undo that has both to take back the newest
/// first.
@MainActor
enum UndoOrder {
    private static var last = 0

    static func next() -> Int {
        last += 1
        return last
    }
}

/// The changes to files in the order Undo and Redo take them, for the note's own Undo on iPhone and iPad to tell
/// whether one came after its last change to the text (`EditorUndoManager`). On the Mac the text's changes are in the
/// same undo manager, which keeps them in order by itself.
@MainActor
final class FileUndoLog {
    private var done: [FileChange] = []
    private var undone: [FileChange] = []

    /// The change Undo takes back next, and the one Redo makes again.
    var nextUndo: FileChange? { done.last }
    var nextRedo: FileChange? { undone.last }

    func kept(_ change: FileChange) {
        change.order = UndoOrder.next()
        done.append(change)
        // A new change leaves nothing to redo, in the undo manager too.
        undone.removeAll()
    }

    func undid(_ change: FileChange) {
        done.removeAll { $0 === change }
        change.order = UndoOrder.next()
        undone.append(change)
    }

    func redid(_ change: FileChange) {
        undone.removeAll { $0 === change }
        change.order = UndoOrder.next()
        done.append(change)
    }

    func dropped(_ change: FileChange) {
        done.removeAll { $0 === change }
        undone.removeAll { $0 === change }
    }
}

extension Workspace {
    /// Where changes to files are kept for Undo: the window's undo manager, which Edit › Undo and ⌘Z use wherever the
    /// focus is. On the Mac the note's text keeps its changes there too, so Undo after Undo takes back the newest
    /// first, whichever it is. Without a window (tests), Notebook's own.
    var fileUndoManager: UndoManager {
        #if os(macOS)
        let window = sidebar?.outline.window ?? editor.textView.window
        #else
        let window = editor.textView.window ?? UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        #endif
        return window?.undoManager ?? ownUndoManager
    }

    /// Keeps a change to files for Undo as it is asked for, before it is written: Undo pressed at once waits for it
    /// (`changeFiles`). It is a step of its own, unless a group is open for it (`undoTogether`).
    @discardableResult
    func keepForUndo(_ change: FileChange) -> FileChange {
        let manager = fileUndoManager
        change.manager = manager
        // The undo manager closes the group of an event once the event is handled, and one opened outside an event
        // (a note made for a link, from a task) only after the next, which would take that event's changes in.
        let opens = manager.groupingLevel == 0
        if opens { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: change) { [weak self] change in self?.undo(change) }
        manager.setActionName(change.name)
        if opens { manager.endUndoGrouping() }
        fileUndoLog.kept(change)
        // What is typed next is a change of its own, after this one.
        #if os(macOS)
        editor.textView.breakUndoCoalescing()
        #else
        editor.openStep = nil
        // Once the swipe or menu that asked is done, and a note it closed has gone.
        DispatchQueue.main.async { [weak self] in self?.fileUndoView?.takeFocusIfFree() }
        #endif
        return change
    }

    /// A change to files was written: where the file went, or nil when it couldn't be (or needn't be: a move to where
    /// it is), which leaves nothing to undo.
    func changeDone(_ change: FileChange, from url: URL? = nil, to result: URL?) {
        if let url { change.before = url }
        change.after = result
        guard let result else { return dropFromUndo(change) }
        if change.kind == .move, let before = change.before, FileNode.samePath(before, result) { dropFromUndo(change) }
    }

    /// Changes to files asked for together, taken back by one Undo.
    func undoTogether(_ changes: () -> Void) {
        let manager = fileUndoManager
        manager.beginUndoGrouping()
        changes()
        manager.endUndoGrouping()
    }

    func dropFromUndo(_ change: FileChange) {
        change.manager?.removeAllActions(withTarget: change)
        fileUndoLog.dropped(change)
    }

    // MARK: - Undo and Redo

    #if os(iOS)
    /// Edit › Undo and ⌘Z on iPhone and iPad. UIKit sends them to what has the focus, whose window asks its undo
    /// manager; with nothing focused it asks none, and the changes to files would never be taken back. So they come
    /// here: to what has the focus when it has something to take back (the note's text takes the files' changes back
    /// too), else to the changes to files.
    func undo() {
        if UIApplication.shared.sendAction(Selector(("undo:")), to: nil, from: nil, for: nil) { return }
        if fileUndoManager.canUndo { fileUndoManager.undo() }
    }

    func redo() {
        if UIApplication.shared.sendAction(Selector(("redo:")), to: nil, from: nil, for: nil) { return }
        if fileUndoManager.canRedo { fileUndoManager.redo() }
    }
    #endif

    /// Undo of a change: Redo is kept at once, as the undo manager expects; the files change once the changes asked
    /// for before have been written.
    private func undo(_ change: FileChange) {
        guard let manager = change.manager else { return }
        manager.registerUndo(withTarget: change) { [weak self] change in self?.redo(change) }
        manager.setActionName(change.name)
        fileUndoLog.undid(change)
        takeBack(change, undoing: true)
    }

    private func redo(_ change: FileChange) {
        guard let manager = change.manager else { return }
        manager.registerUndo(withTarget: change) { [weak self] change in self?.undo(change) }
        manager.setActionName(change.name)
        fileUndoLog.redid(change)
        takeBack(change, undoing: false)
    }

    /// Takes a file from where the change left it to where it was (`undoing`), or the other way: by the Trash for a
    /// file made or thrown away, else by renaming or moving it.
    private func takeBack(_ change: FileChange, undoing: Bool) {
        changeFiles { [self] follow in
            for part in change.parts { _ = await takeBackNow(part, undoing: undoing, follow: follow) }
            // Couldn't: what Undo or Redo would do with it next can't be done either.
            if await !takeBackNow(change, undoing: undoing, follow: follow) { dropFromUndo(change) }
        }
    }

    /// Takes one file back, or brings it again: whether that could be done.
    private func takeBackNow(_ change: FileChange, undoing: Bool, follow: (URL) -> URL) async -> Bool {
        guard let source = (undoing ? change.after : change.before).map(follow) else { return true }
        let target = (undoing ? change.before : change.after).map(follow)
        var result: URL?
        if change.kind == (undoing ? .make : .trash) {
            change.remembered = remembered(source)
            result = await throwAwayNow(source)
        } else if let target, change.kind == (undoing ? .trash : .make) {
            result = await putBackNow(source, to: target, remembered: change.remembered)
        } else if let target {
            result = await relocateNow(source, to: target, change: change, undoing: undoing)
        }
        guard let result else { return false }
        if undoing { change.before = result } else { change.after = result }
        return true
    }

    /// To the Trash, or on iPhone and iPad, where a place has no Recently Deleted, deleted for good (as it was when
    /// you deleted it, or made a moment ago), waiting for Undo out of sight. Where it went.
    private func throwAwayNow(_ url: URL) async -> URL? {
        let trashed = await trashNow(url)
        if trashed.done {
            if trashed.place == nil { beep() }
            return trashed.place
        }
        #if os(iOS)
        if let place = await deleteNow(url).place { return place }
        #endif
        beep()
        return nil
    }

    /// Puts a file back from the Trash where it was, or next to that with a number when its name is taken now, with
    /// what Notebook knew about it. The file that was open opens again.
    private func putBackNow(_ place: URL, to original: URL, remembered: FileChange.Remembered?) async -> URL? {
        let folder = original.deletingLastPathComponent()
        let result = await Task.detached(priority: .userInitiated) { () -> (url: URL, listing: FileNode.Listing?)? in
            let name = original.lastPathComponent as NSString
            let destination = FileOperations.uniqueURL(in: folder, name: name.deletingPathExtension, extension: name.pathExtension.isEmpty ? nil : name.pathExtension)
            guard let back = FileOperations.move(place, to: destination) else { return nil }
            return (back, FileNode.listing(of: back))
        }.value
        guard let result else {
            beep()
            return nil
        }
        showChanges(in: [folder], adding: result.listing.map { [$0] } ?? [])
        if let remembered { restore(remembered, at: result.url) }
        if remembered?.openFile == nil { reveal(result.url, select: false) }
        return result.url
    }

    /// Takes a renamed or moved file back to its name and folder, with the links it rewrote, or there again, with the
    /// links following it again.
    private func relocateNow(_ url: URL, to target: URL, change: FileChange, undoing: Bool) async -> URL? {
        let folder = target.deletingLastPathComponent()
        if FileNode.samePath(url.deletingLastPathComponent(), folder) {
            return await renameNow(url, to: target.lastPathComponent, fileName: true, updatingLinks: change.updatesLinks, change: change, undoing: undoing)
        }
        return await moveNow(url, into: folder, fileName: target.lastPathComponent, change: change, undoing: undoing)
    }

    // MARK: - What comes back from the Trash

    /// What Notebook knows about a file and what is in it, which it forgets when the file goes to the Trash.
    func remembered(_ url: URL) -> FileChange.Remembered {
        let key = hiddenKey(for: url)
        func isIn(_ other: String) -> Bool { other == key || other.hasPrefix(key + "/") }
        return FileChange.Remembered(
            key: key,
            path: url.path,
            openFile: currentURL.flatMap { FileNode.isSameOrInside($0, url) ? $0 : nil },
            isFavorite: isFavorite(url),
            reminders: reminders.all.filter { isIn($0.note) },
            hiddenFolders: hidden.keys.filter(isIn)
        )
    }

    private func restore(_ remembered: FileChange.Remembered, at url: URL) {
        let key = hiddenKey(for: url)
        func here(_ old: String) -> String { key + old.dropFirst(remembered.key.count) }
        if remembered.isFavorite, !isFavorite(url) { toggleFavorite(url) }
        if !remembered.hiddenFolders.isEmpty {
            for folder in remembered.hiddenFolders { hidden.set(here(folder), hidden: true) }
            hiddenFoldersChanged()
        }
        if !remembered.reminders.isEmpty {
            for var reminder in remembered.reminders {
                reminder.note = here(reminder.note)
                reminders.set(reminder)
            }
            remindersChanged(scheduling: Set(remembered.reminders.map(\.id)))
        }
        if let file = remembered.openFile {
            open(Self.relocated(file, from: URL(fileURLWithPath: remembered.path), to: url))
        }
    }
}
