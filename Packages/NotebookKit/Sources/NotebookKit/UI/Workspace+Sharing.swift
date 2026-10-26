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
        let waiting = await Task.detached(priority: .userInitiated) { SharedNotes.waiting() }.value
        for shared in waiting where await write(shared.note, files: shared.files) {
            await Task.detached(priority: .utility) { SharedNotes.remove(shared.note) }.value
        }
    }

    /// The places the share extension offers, as they are now: the default folder and the note opened last.
    func publishSharePlaces() {
        guard let folder = defaultFolder else {
            SharedNotes.places = nil
            return
        }
        let last = currentURL.flatMap { $0.pathExtension == "md" ? $0 : nil } ?? recents.first.map { URL(fileURLWithPath: $0) }
        SharedNotes.places = SharedNotes.Places(defaultFolder: folder.lastPathComponent, lastNote: last?.path)
    }

    private func write(_ note: SharedNote, files: URL) async -> Bool {
        if case .endOf(let path) = note.destination {
            let url = URL(fileURLWithPath: path)
            let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
            // Gone since, or no longer in a location: a note of its own instead.
            if exists, location(containing: url) != nil { return await append(note, files: files, to: url) }
        }
        return await newNote(note, files: files)
    }

    /// A new note in the default folder, or in the Inbox when the folder chosen for it is gone from the disk, as New
    /// Note does. It shows in the sidebar and isn't opened: whatever is open stays.
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
                let embeds = Self.storeShared(note.files, from: files, in: folder)
                guard let made = FileOperations.createNote(in: folder, title: note.title ?? "Untitled",
                                                           text: Self.sharedMarkdown(note.text, embeds) + "\n") else { return nil }
                return (made.url, folder, FileNode.listing(of: made.url), madeFolder)
            }.value
        }.value
        guard let made else { return false }
        let parent = made.folder.deletingLastPathComponent()
        showChanges(in: made.madeFolder ? [parent, made.folder] : [made.folder],
                    adding: (made.listing.map { [$0] } ?? []) + (made.madeFolder ? [FileNode.Listing(url: made.folder, kind: .folder)] : []))
        return true
    }

    /// At the end of a note, after a blank line. Open in an editor, the text goes in there as one step of Undo and is
    /// saved with what was typed; otherwise into the file, read and written in one go.
    private func append(_ note: SharedNote, files: URL, to url: URL) async -> Bool {
        let folder = url.deletingLastPathComponent()
        if let editor = editorShowing(url) {
            let embeds = await Task.detached(priority: .userInitiated) { Self.storeShared(note.files, from: files, in: folder) }.value
            guard editor.appendAtEnd(Self.sharedMarkdown(note.text, embeds), actionName: "Add Shared") else { return false }
            saveNote(showing: url)
            return true
        }
        let written = await changeFiles { follow -> Bool in
            let url = follow(url)
            return await Task.detached(priority: .userInitiated) {
                let embeds = Self.storeShared(note.files, from: files, in: url.deletingLastPathComponent())
                let addition = Self.sharedMarkdown(note.text, embeds)
                return FileOperations.rewrite(url) { text in
                    let end = Self.sharedEnd(addition, after: text as NSString)
                    return (text as NSString).replacingCharacters(in: NSRange(location: end.kept, length: (text as NSString).length - end.kept), with: end.tail)
                } != nil
            }.value
        }.value
        if written { readAgain([folder]) }
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
    /// Markdown: a picture shows, any other file is its card.
    nonisolated static func storeShared(_ names: [String], from source: URL, in folder: URL) -> [String] {
        names.compactMap { name in
            let file = source.appendingPathComponent(name)
            guard let stored = FileOperations.storeAsset(copying: file, in: folder) else { return nil }
            return MarkdownStyler.isImageFile(file) ? "![](\(stored))" : "![\(name)](\(stored))"
        }
    }
}
