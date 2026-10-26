import Foundation
import NotebookCapture

/// Notes shared from other apps through the share extension (`SharedNotes`), written here: a new note in the default
/// folder, or the end of the note opened last, with the pictures and files in the note's `.assets`, as the editor puts
/// them in.
extension Workspace {
    /// Writes the notes waiting, oldest first, once the locations have been looked up: their bookmarks are what lets
    /// Notebook write in them. A note is forgotten only once it is written; one that can't be, without a location
    /// say, waits for the next time.
    func takeSharedNotes() async {
        start()
        await surveyed()
        guard !locations.isEmpty else { return }
        let waiting = await Task.detached(priority: .userInitiated) {
            SharedNotes.removeLeftovers()
            return SharedNotes.waiting()
        }.value
        for shared in waiting where await write(shared.note, files: shared.files) {
            await Task.detached(priority: .utility) { SharedNotes.remove(shared.note) }.value
        }
    }

    /// The places the share extension offers, as they are now: the default folder and the note opened last. Only a
    /// note: text added to the end of a PDF or a picture would ruin it.
    func publishSharePlaces() {
        guard let folder = defaultFolder else {
            SharedNotes.places = nil
            return
        }
        let last = ([currentURL].compactMap { $0 } + recents.map { URL(fileURLWithPath: $0) }).first(where: Self.isNote)
        SharedNotes.places = SharedNotes.Places(defaultFolder: folder.lastPathComponent, lastNote: last?.path)
    }

    nonisolated static func isNote(_ url: URL) -> Bool {
        FileKind(url: url, isDirectory: false) == .note
    }

    private func write(_ note: SharedNote, files: URL) async -> Bool {
        if case .endOf(let path) = note.destination {
            let url = URL(fileURLWithPath: path)
            let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
            // Gone since, no longer in a location, or not a note at all: a note of its own instead.
            if exists, Self.isNote(url), location(containing: url) != nil { return await append(note, files: files, to: url) }
        }
        return await newNote(note, files: files)
    }

    /// A new note in the default folder, or in the Inbox when the folder chosen for it is gone from the disk, as New
    /// Note does. It shows in the sidebar and isn't opened: whatever is open stays. All or nothing: without every one of
    /// its files, or when the note can't be made, nothing stays behind and it waits for the next time.
    private func newNote(_ note: SharedNote, files: URL) async -> Bool {
        guard let chosen = defaultFolder else { return false }
        let inbox = inboxFolder
        let made = await changeFiles { follow -> (url: URL, folder: URL, listing: FileNode.Listing?, madeFolder: Bool)? in
            let chosen = follow(chosen)
            let inbox = inbox.map(follow)
            return await Task.detached(priority: .userInitiated) {
                let manager = FileManager.default
                let folder = inbox.flatMap { manager.fileExists(atPath: chosen.path) ? nil : $0 } ?? chosen
                let madeFolder = !manager.fileExists(atPath: folder.path)
                if madeFolder { try? manager.createDirectory(at: folder, withIntermediateDirectories: true) }
                func undo(_ stored: [URL]) -> (url: URL, folder: URL, listing: FileNode.Listing?, madeFolder: Bool)? {
                    FileOperations.removeStoredAssets(stored)
                    if madeFolder, (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? manager.removeItem(at: folder) }
                    return nil
                }
                guard let stored = Self.storeShared(note.files, from: files, in: folder) else { return undo([]) }
                guard let made = FileOperations.createNote(in: folder, title: note.title ?? "Untitled",
                                                           text: Self.sharedMarkdown(note.text, stored.markdown) + "\n") else { return undo(stored.urls) }
                return (made.url, folder, FileNode.listing(of: made.url), madeFolder)
            }.value
        }.value
        guard let made else { return false }
        let parent = made.folder.deletingLastPathComponent()
        showChanges(in: made.madeFolder ? [parent, made.folder] : [made.folder],
                    adding: (made.listing.map { [$0] } ?? []) + (made.madeFolder ? [FileNode.Listing(url: made.folder, kind: .folder)] : []))
        return true
    }

    /// At the end of a note, after a blank line. Its files are copied first, off the main thread, as in iCloud that
    /// can take a while; only then is the note looked for in an editor, since meanwhile another may have been opened
    /// in its place or its window closed. Open, the text goes in there as one step of Undo and is saved at once;
    /// otherwise into the file, read and written in one go. All or nothing, as for a new note.
    private func append(_ note: SharedNote, files: URL, to url: URL) async -> Bool {
        let written = await changeFiles { [self] follow -> Bool in
            let url = follow(url)
            let folder = url.deletingLastPathComponent()
            guard let stored = await Task.detached(priority: .userInitiated, operation: { Self.storeShared(note.files, from: files, in: folder) }).value else {
                return false
            }
            let addition = Self.sharedMarkdown(note.text, stored.markdown)
            if let editor = editorShowing(url) {
                if editor.appendAtEnd(addition, actionName: "Add Shared") {
                    saveNote(showing: url)
                    return true
                }
            } else {
                let rewritten = await Task.detached(priority: .userInitiated) {
                    FileOperations.rewrite(url) { text in
                        let end = Self.sharedEnd(addition, after: text as NSString)
                        return (text as NSString).replacingCharacters(in: NSRange(location: end.kept, length: (text as NSString).length - end.kept), with: end.tail)
                    } != nil
                }.value
                if rewritten {
                    readAgain([folder])
                    return true
                }
            }
            await Task.detached(priority: .utility) { FileOperations.removeStoredAssets(stored.urls) }.value
            return false
        }.value
        return written
    }

    /// The text shared, then its pictures and files, each on a line of its own.
    nonisolated static func sharedMarkdown(_ text: String, _ embeds: [String]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = (text.isEmpty ? [] : [text]) + (embeds.isEmpty ? [] : [embeds.joined(separator: "\n")])
        return blocks.joined(separator: "\n\n")
    }

    /// Where shared text goes in a note: after its last line and a blank one. How much of the note stays as it is,
    /// up to its last character that isn't a line break, and what comes after it.
    nonisolated static func sharedEnd(_ addition: String, after text: NSString) -> (kept: Int, tail: String) {
        var kept = text.length
        while kept > 0, [10, 13].contains(text.character(at: kept - 1)) { kept -= 1 }
        return (kept, (kept == 0 ? "" : "\n\n") + addition + "\n")
    }

    /// Copies the files shared into the folder's `.assets` under names not taken there, and gives each one's
    /// Markdown (a picture shows, any other file is its card) and where it went. Every one or none: when one can't be
    /// copied, those copied already are taken back.
    nonisolated static func storeShared(_ names: [String], from source: URL, in folder: URL) -> (markdown: [String], urls: [URL])? {
        var markdown: [String] = []
        var urls: [URL] = []
        for name in names {
            let file = source.appendingPathComponent(name)
            guard let stored = FileOperations.storeAsset(copying: file, in: folder) else {
                FileOperations.removeStoredAssets(urls)
                return nil
            }
            let path = FileOperations.markdownPath(stored.lastPathComponent)
            markdown.append(MarkdownStyler.isImageFile(file) ? "![](\(path))" : "![\(name)](\(path))")
            urls.append(stored)
        }
        return (markdown, urls)
    }
}
