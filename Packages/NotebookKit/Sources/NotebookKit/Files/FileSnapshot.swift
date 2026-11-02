import Foundation

/// What a file or folder was like on the disk, to tell later whether it changed: a file by its size and when it was
/// last written, a folder by every file and folder in it. Undo of a file Notebook made deletes it for good, where a place
/// has no Recently Deleted, only while it is as it was made (`FileChange.made`). Read with `FileManager`'s attributes,
/// which are read anew each time, where `URL.resourceValues` may give what it read before.
struct FileSnapshot: Sendable {
    private struct Entry: Equatable, Sendable {
        var isFolder: Bool
        var size: UInt64
        var modified: Date?

        init(_ attributes: [FileAttributeKey: Any]) {
            isFolder = attributes[.type] as? FileAttributeType == .typeDirectory
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
        }

        /// A folder by being one: it changes with what is in it, which is counted on its own. A file by its size and
        /// date, unless it had nothing in it and has nothing now: written again or not, nothing would be lost with it.
        func isUnchanged(in later: Entry) -> Bool {
            guard isFolder == later.isFolder else { return false }
            if isFolder || (size == 0 && later.size == 0) { return true }
            return size == later.size && modified == later.modified
        }
    }

    /// By the path inside, "" for the file or folder itself.
    private let entries: [String: Entry]

    /// Nil when there is nothing at `url`. Off the main thread: every file in a folder is looked at.
    init?(of url: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
        let root = Entry(attributes)
        var entries = ["": root]
        if root.isFolder, let inside = manager.enumerator(atPath: url.path) {
            while let path = inside.nextObject() as? String {
                guard let attributes = inside.fileAttributes else { continue }
                entries[path] = Entry(attributes)
            }
        }
        self.entries = entries
    }

    /// Whether what is at `url` now is as it was: the same files and folders, each file the same size and last written
    /// at the same time. Off the main thread.
    func matches(_ url: URL) -> Bool {
        guard let now = FileSnapshot(of: url), now.entries.count == entries.count else { return false }
        return entries.allSatisfy { path, entry in now.entries[path].map(entry.isUnchanged) ?? false }
    }
}
