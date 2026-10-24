#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Synchronization

/// Creating, renaming, moving and deleting files, coordinated so iCloud and other apps see each change whole. All of it
/// runs off the main thread (`Workspace.changeFiles`): in iCloud Drive a coordinated write can wait for iCloud.
enum FileOperations {
    #if DEBUG
    /// How many changes to files were made on the main thread, for tests to see that nothing they do makes any there.
    static let mainThreadWrites = Mutex(0)
    #endif

    /// A slow iCloud, for trying out that nothing waits for a change to files: in Debug builds, with
    /// `-NotebookSlowWrites <seconds>`, each one waits that long first. One on the main thread isn't slowed down but
    /// logged, to find any that shouldn't be there.
    private static func debugWait(_ what: String, _ url: URL) {
        #if DEBUG
        if Thread.isMainThread {
            mainThreadWrites.withLock { $0 += 1 }
            NSLog("Notebook: %@ %@ on the main thread", what, url.path)
        } else {
            let delay = UserDefaults.standard.double(forKey: "NotebookSlowWrites")
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        #endif
    }

    /// A name that isn't taken in the folder: "Untitled", "Untitled 2", …
    static func uniqueURL(in folder: URL, name: String, extension ext: String?) -> URL {
        func make(_ base: String) -> URL {
            ext.map { folder.appendingPathComponent(base).appendingPathExtension($0) } ?? folder.appendingPathComponent(base, isDirectory: true)
        }
        var candidate = make(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(name) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// A file name from a title: the characters files can't have become dashes.
    static func fileName(from title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for character in ["/", ":", "\\"] { name = name.replacingOccurrences(of: character, with: "-") }
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(200))
    }

    /// A new note, and whether its folder had to be made for it (the Inbox, the first time).
    static func createNote(in folder: URL, title: String = "Untitled", text: String = "") -> (url: URL, madeFolder: Bool)? {
        debugWait("made a note in", folder)
        let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
        if madeFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let url = uniqueURL(in: folder, name: fileName(from: title).isEmpty ? "Untitled" : fileName(from: title), extension: "md")
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
            written = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }
        return written ? (url, madeFolder) : nil
    }

    @discardableResult
    static func createFolder(in parent: URL, name: String = "New Folder") -> URL? {
        debugWait("made a folder in", parent)
        let url = uniqueURL(in: parent, name: name, extension: nil)
        var created = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: nil) { url in
            created = (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil
        }
        return created ? url : nil
    }

    /// Moves a file or folder, coordinated. Returns where it ended up. The open note (`presenter`), when it is the file
    /// or in the folder, isn't told: Notebook follows it itself, while it waits to save.
    @discardableResult
    static func move(_ url: URL, to destination: URL, presenter: NoteDocument? = nil) -> URL? {
        guard url.standardizedFileURL != destination.standardizedFileURL else { return url }
        debugWait("moved", url)
        var moved = false
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
                moved = true
            } catch {
                moved = false
            }
        }
        return moved ? destination : nil
    }

    /// Where renaming a file or folder takes it: the new name with the file's extension. Nil when the name is empty.
    static func destination(renaming url: URL, to name: String, isDirectory: Bool) -> URL? {
        let clean = fileName(from: name)
        guard !clean.isEmpty else { return nil }
        var destination = url.deletingLastPathComponent().appendingPathComponent(clean, isDirectory: isDirectory)
        if !isDirectory, !url.pathExtension.isEmpty { destination = destination.appendingPathExtension(url.pathExtension) }
        return destination
    }

    /// Renames, keeping the extension of a file. Returns the new address, or nil when the name is taken or invalid.
    static func rename(_ url: URL, to name: String, presenter: NoteDocument? = nil) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        // A package (a Pages document) is a folder that keeps its extension like a file.
        let isDirectory = values?.isDirectory == true && values?.isPackage != true
        guard let destination = destination(renaming: url, to: name, isDirectory: isDirectory) else { return nil }
        return rename(url, to: destination, presenter: presenter)
    }

    /// Renames to a file name as it is, extension and all: Undo giving a file back the name it had.
    static func rename(_ url: URL, toFileName fileName: String, presenter: NoteDocument? = nil) -> URL? {
        rename(url, to: url.deletingLastPathComponent().appendingPathComponent(fileName), presenter: presenter)
    }

    private static func rename(_ url: URL, to destination: URL, presenter: NoteDocument?) -> URL? {
        guard destination.path != url.path else { return url }
        // Only the case changed: the file system calls that the same name.
        if destination.path.lowercased() != url.path.lowercased(), FileManager.default.fileExists(atPath: destination.path) { return nil }
        return move(url, to: destination, presenter: presenter)
    }

    static func trash(_ url: URL) -> Bool {
        moveToTrash(url).done
    }

    /// Moves to the Trash, and says where it went there, for Undo to put it back from.
    static func moveToTrash(_ url: URL) -> (done: Bool, place: URL?) {
        debugWait("trashed", url)
        var result: (done: Bool, place: URL?) = (false, nil)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
            var place: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &place)) != nil { result = (true, place as URL?) }
        }
        return result
    }

    #if os(iOS)
    /// Where files deleted for good wait out of sight, for Undo to bring them back while Notebook is open. Emptied at
    /// the next launch (`emptyDeleted`).
    static let deletedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Deleted", isDirectory: true)

    /// Deletes for good: for places without a Recently Deleted, after asking. On this device's own storage the file
    /// only moves out of its folder into `deletedFolder`, which says where, for Undo; anywhere else it goes at once.
    static func delete(_ url: URL) -> (done: Bool, place: URL?) {
        debugWait("deleted", url)
        let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let ours = (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        if let volume, let ours, volume.isEqual(ours) {
            let place = deletedFolder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let moved = move(url, to: place) { return (true, moved) }
        }
        var deleted = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
            deleted = (try? FileManager.default.removeItem(at: url)) != nil
        }
        return (deleted, nil)
    }

    /// What was deleted for good last time Notebook was open goes now.
    static func emptyDeleted() {
        try? FileManager.default.removeItem(at: deletedFolder)
    }
    #endif

    static func duplicate(_ url: URL) -> URL? {
        debugWait("duplicated", url)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
        let destination = uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) copy", extension: ext)
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
            copied = (try? FileManager.default.copyItem(at: from, to: to)) != nil
        }
        return copied ? destination : nil
    }

    // MARK: - Links

    /// Changes the links in a note's file after files were renamed or moved (`LinkUpdate`): `change` gives the new
    /// text from what the file says, or nil. The text written and the links changed, or nil when nothing was written.
    static func rewriteLinks(in url: URL, _ change: (String) -> (text: String, edits: [LinkEdit])?) -> (text: String, edits: [LinkEdit])? {
        debugWait("rewrote the links in", url)
        var edits: [LinkEdit] = []
        let text = rewrite(url) { text in
            guard let changed = change(text) else { return nil }
            edits = changed.edits
            return changed.text
        }
        return text.map { ($0, edits) }
    }

    /// Changes a note's file: `change` gives the new text from what it says, or nil. Read and written in one go, so
    /// nothing written there meanwhile is lost. The text written, or nil.
    @discardableResult
    static func rewrite(_ url: URL, _ change: (String) -> String?) -> String? {
        var written: String?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { url in
            guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data), let changed = change(text) else { return }
            if (try? Data(changed.utf8).write(to: url, options: .atomic)) != nil { written = changed }
        }
        return written
    }

    /// Reads a note, bringing it down from iCloud first, in a coordinated read `coordinator.cancel()` calls off.
    static func read(_ url: URL, coordinator: NSFileCoordinator) -> String? {
        var error: NSError?
        var text: String?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { url in
            text = (try? Data(contentsOf: url)).flatMap(NoteDocument.decode)
        }
        return error == nil ? text : nil
    }

    /// A note moved to another folder takes the pictures and files it uses along into that folder's `.assets`, from
    /// the one of the folder it was in. One whose name another file has there already comes under a name of its own,
    /// which the note then says. Returns their names, for those no note left there uses to go to the Trash
    /// (`cleanUpAssets`), and whether the note's text changed. One that came under another name stays where it was:
    /// whatever the note says after an Undo, it finds its own picture there. So Undo, taking a note back (not
    /// `renaming`), leaves a picture of the name there as it is. Reading the note waits for it to come down when it is
    /// still in iCloud.
    static func copyAssets(of note: URL, from folder: URL, renaming: Bool = true) -> (names: Set<String>, renamed: Bool) {
        #if DEBUG
        // With `-NotebookSlowFiles`, every note is still in iCloud, and comes down first.
        if let delay = FileLoading.debugDelay, !Thread.isMainThread { Thread.sleep(forTimeInterval: delay) }
        #endif
        guard let text = NoteDocument.read(note) else { return ([], false) }
        let assets = assetNames(in: text)
        let source = folder.appendingPathComponent(".assets")
        let target = note.deletingLastPathComponent().appendingPathComponent(".assets")
        var renamed: [String: String] = [:]
        func copy(_ name: String, as newName: String) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(newName)
            guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { return }
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        for name in assets {
            let from = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            var newName = name
            let there = target.appendingPathComponent(name)
            // Another file of its name, not the same one another note there shows too.
            if renaming, FileManager.default.fileExists(atPath: there.path), !FileManager.default.contentsEqual(atPath: from.path, andPath: there.path) {
                newName = freeAssetName(for: name, in: target)
                renamed[name] = newName
            }
            copy(name, as: newName)
            if let strokes = strokesName(of: name), let newStrokes = strokesName(of: newName) { copy(strokes, as: newStrokes) }
        }
        guard !renamed.isEmpty, let expression = try? NSRegularExpression(pattern: "\\.assets/([^)\\s\\]|]+)") else { return (assets, false) }
        let leaving = assets.subtracting(renamed.keys)
        let changed = rewrite(note) { text in
            let string = NSMutableString(string: text)
            for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)).reversed() {
                let raw = string.substring(with: match.range(at: 1))
                if let new = renamed[raw.removingPercentEncoding ?? raw] { string.replaceCharacters(in: match.range(at: 1), with: LinkUpdate.encoded(new)) }
            }
            return string as String == text ? nil : string as String
        }
        return (leaving, changed != nil)
    }

    /// A name for a picture or file in an `.assets` folder that neither it nor, for a drawing, its strokes have there.
    private static func freeAssetName(for name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let taken = [candidate, strokesName(of: candidate)].compactMap { $0 }.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if !taken { return candidate }
            counter += 1
        }
    }

    /// The strokes file next to a drawing's picture.
    private static func strokesName(of name: String) -> String? {
        (name as NSString).pathExtension.lowercased() == "png" ? (name as NSString).deletingPathExtension + "." + DrawingFile.fileExtension : nil
    }

    /// Pictures and files in a folder's `.assets` that no note in the folder uses any more, among `candidates`,
    /// go to the Trash.
    static func cleanUpAssets(in folder: URL, candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let notes = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var used = Set<String>()
        for note in notes where note.pathExtension.lowercased() == "md" {
            guard let text = NoteDocument.read(note) else { continue }
            used.formUnion(assetNames(in: text))
        }
        for name in withDrawingStrokes(candidates).subtracting(withDrawingStrokes(used)) {
            let url = folder.appendingPathComponent(".assets").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { _ = trash(url) }
        }
    }

    /// Asset names with the strokes files of the drawings among them, which go wherever their pictures go.
    static func withDrawingStrokes(_ names: Set<String>) -> Set<String> {
        names.union(names.filter { ($0 as NSString).pathExtension.lowercased() == "png" }.map {
            ($0 as NSString).deletingPathExtension + "." + DrawingFile.fileExtension
        })
    }

    /// The `.assets` files a note's Markdown points at, by file name.
    static func assetNames(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: "\\.assets/([^)\\s\\]|]+)") else { return [] }
        var names = Set<String>()
        for match in expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let raw = (text as NSString).substring(with: match.range(at: 1))
            names.insert(raw.removingPercentEncoding ?? raw)
        }
        return names
    }
}
