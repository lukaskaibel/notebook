import Foundation

/// Files kept on their own, outside every location: chosen with Open File on iPhone and iPad, or handed over by another
/// app. They show under Files below the folders, in Recent, in Favorites and in search, links find them, and they open
/// again in later runs from the bookmark each keeps. What needs the file's folder (Rename, Move To, Duplicate, Delete, a
/// new note next to it) isn't offered for them: Notebook has the file, not its folder.
extension Workspace {
    /// The kept files that are there to open, by name: not those in a location now (a folder you opened since has
    /// them), gone, or on their way to the Trash.
    var keptFileURLs: [URL] {
        keptFiles.map(\.url)
            .filter { location(containing: $0) == nil && FileManager.default.fileExists(atPath: $0.path) && !isLeaving($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The kept files search reads: those in no location, which reads them itself.
    var indexedKeptFiles: [URL] {
        keptFiles.map(\.url).filter { location(containing: $0) == nil }
    }

    /// A file kept on its own, and not in a location.
    func isKept(_ url: URL) -> Bool {
        guard !keptFiles.isEmpty else { return false }
        let url = url.standardizedFileURL
        return keptFiles.contains { FileNode.samePath($0.url, url) } && location(containing: url) == nil
    }

    /// Keeps a file that is in no location, with access to it started for this run, and a bookmark, made off the main
    /// thread, for the next ones. One in a location, or kept already, stays as it is.
    func keep(_ url: URL) {
        let url = url.standardizedFileURL
        guard location(containing: url) == nil, !keptFiles.contains(where: { FileNode.samePath($0.url, url) }) else { return }
        LocationStore.startAccessing(url)
        keptFiles.append(KeptFile(path: url.path, bookmark: nil))
        saveKeptFiles()
        Task {
            let bookmark = await Task.detached(priority: .utility) { LocationStore.bookmark(for: url).bookmark }.value
            guard let bookmark, let index = keptFiles.firstIndex(where: { FileNode.samePath($0.url, url) }) else { return }
            keptFiles[index].bookmark = bookmark
            saveKeptFiles()
        }
    }

    /// Takes a file off Files. The file itself stays where it is.
    func removeKeptFile(_ url: URL) {
        keptFiles.removeAll { FileNode.samePath($0.url, url) }
        saveKeptFiles()
    }

    /// What you chose with Open File: each file is kept on its own unless a location has it, and the first opens; a
    /// folder becomes a location, as with Open Folder. Looked at off the main thread, as the app a file comes from can
    /// take a moment. `done` says what opened, for tests.
    func openChosen(_ urls: [URL], then done: ((URL?) -> Void)? = nil) {
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                urls.map { url -> (url: URL, found: Location.Found) in
                    LocationStore.startAccessing(url)
                    return (url.standardizedFileURL, Location.found(at: url))
                }
            }.value
            var first: URL?
            for item in found {
                switch item.found {
                case .folder:
                    if location(containing: item.url) == nil { addLocation(item.url) }
                case .file:
                    keep(item.url)
                    if first == nil { first = item.url }
                case .nothing:
                    report("Notebook can’t open “\(item.url.lastPathComponent)”.", "The file isn’t there any more, or the app it comes from doesn’t give it now.")
                }
            }
            if let first { open(first) }
            done?(first)
        }
    }

    /// Finds the kept files again by their bookmarks, off the main thread, with access to each started: where one
    /// moved, Recent, Favorites and the rest follow it. `last`, the file open when Notebook last quit, opens then,
    /// unless you opened another meanwhile.
    func resolveKeptFiles(thenOpen last: URL?) {
        let files = keptFiles
        guard !files.isEmpty else { return }
        Task {
            let resolved = await Task.detached(priority: .userInitiated) { KeptFileStore.resolve(files) }.value
            var moved: [(from: URL, to: URL)] = []
            for (old, new) in zip(files, resolved) {
                guard let index = keptFiles.firstIndex(where: { $0.path == old.path }) else { continue }
                if !FileNode.samePath(old.url, new.url) { moved.append((old.url, new.url)) }
                keptFiles[index] = new
            }
            for move in moved { replacePath(move.from, with: move.to) }
            saveKeptFiles()
            // Search reads them now that it may: before, the first build may have found them out of reach.
            index.refreshFiles()
            guard let last, currentURL == nil else { return }
            let url = moved.first { FileNode.samePath($0.from, last) }?.to ?? last
            if FileManager.default.fileExists(atPath: url.path) { open(url) }
        }
    }

    /// A kept file renamed or moved by Notebook, or found elsewhere by its bookmark.
    func keptFileMoved(from old: URL, to new: URL) {
        guard let index = keptFiles.firstIndex(where: { FileNode.samePath($0.url, old) }), !FileNode.samePath(old, new) else { return }
        keptFiles[index].path = new.standardizedFileURL.path
        saveKeptFiles()
    }

    private func saveKeptFiles() {
        if !temporaryLocations { KeptFileStore.save(keptFiles) }
    }
}
