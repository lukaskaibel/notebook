import Foundation

/// Hiding folders from the sidebar, and showing them again for a while, dimmed, as the Finder shows hidden files.
/// Hidden folders also stay out of search and Move To; links to the notes in them still work.
extension Workspace {
    /// A folder's files and folders as the sidebar and the lists on iPhone and iPad show them: hidden folders left
    /// out, unless their location shows them.
    func shownChildren(of node: FileNode, in location: Location?) -> [FileNode] {
        let children = node.visibleChildren()
        guard !hidden.keys.isEmpty, let location, !showsHiddenFolders(in: location) else { return children }
        return children.filter { !($0.isFolder && isHidden($0.url)) }
    }

    func isHidden(_ url: URL) -> Bool {
        !hidden.keys.isEmpty && hidden.keys.contains(hiddenKey(for: url))
    }

    /// Any folder but a location's own top: iCloud Drive's Desktop or an app's folder too.
    func canHide(_ url: URL) -> Bool {
        location(containing: url) != nil && !locations.contains { $0.url.path == url.standardizedFileURL.path }
    }

    func setHidden(_ url: URL, _ isHidden: Bool) {
        hidden.set(hiddenKey(for: url), hidden: isHidden)
        hiddenFoldersChanged()
    }

    func hasHiddenFolders(in location: Location) -> Bool {
        hiddenFolderURLs(in: location).contains { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    func showsHiddenFolders(in location: Location) -> Bool {
        hidden.shownIn.contains(location.id)
    }

    func showHiddenFolders(_ shows: Bool, in location: Location) {
        hidden.show(shows, in: location.id)
        hiddenFoldersChanged()
    }

    /// For View › Show Hidden Folders, which shows or hides those of every location.
    var hasHiddenFolders: Bool { locations.contains(where: hasHiddenFolders(in:)) }

    var showsAllHiddenFolders: Bool {
        let withHidden = locations.filter(hasHiddenFolders(in:))
        return !withHidden.isEmpty && withHidden.allSatisfy(showsHiddenFolders(in:))
    }

    func toggleAllHiddenFolders() {
        let shows = !showsAllHiddenFolders
        for location in locations { hidden.show(shows && hasHiddenFolders(in: location), in: location.id) }
        hiddenFoldersChanged()
    }

    /// After hiding or showing, here or on another device.
    func hiddenFoldersChanged() {
        // With its last hidden folder shown again, a location stops showing hidden folders.
        for location in locations where showsHiddenFolders(in: location) && !hasHiddenFolders(in: location) {
            hidden.show(false, in: location.id)
        }
        updateHiddenPaths()
        sidebarReloadAll()
        spotlight?.setNeedsUpdate()
    }

    /// Where the hidden folders are on this device, for search and Move To to leave out.
    func updateHiddenPaths() {
        index.hiddenPaths = locations.filter { !showsHiddenFolders(in: $0) }.flatMap { hiddenFolderURLs(in: $0).map(\.path) }
    }

    /// Every hidden folder on this device, whether its location shows hidden folders for now or not: Spotlight leaves
    /// them all out.
    var allHiddenFolderPaths: [String] {
        locations.flatMap { hiddenFolderURLs(in: $0).map(\.path) }
    }

    /// A folder renamed or moved in Notebook stays hidden; one thrown away is forgotten.
    func hiddenFolderMoved(from old: URL, to new: URL?) {
        guard !hidden.keys.isEmpty else { return }
        if let new { hidden.move(hiddenKey(for: old), to: hiddenKey(for: new)) } else { hidden.forget(hiddenKey(for: old)) }
        updateHiddenPaths()
    }

    func hiddenKey(for url: URL) -> String {
        HiddenFolders.key(for: url, links: locations.flatMap(\.linked))
    }

    /// The hidden folders in a location, as paths on this device, whether they are there or not. A folder inside a
    /// linked one can be reached two ways, through iCloud Drive's link to Desktop and in ~/Desktop, and is listed
    /// both ways.
    private func hiddenFolderURLs(in location: Location) -> [URL] {
        guard !hidden.keys.isEmpty else { return [] }
        let top = hiddenKey(for: location.url)
        return location.folders.flatMap { folder -> [URL] in
            let base = hiddenKey(for: folder.url)
            return hidden.keys.compactMap { key in
                guard key != top else { return nil }
                if key == base { return folder.url }
                guard key.hasPrefix(base + "/") else { return nil }
                return folder.url.appendingPathComponent(String(key.dropFirst(base.count + 1)), isDirectory: true).standardizedFileURL
            }
        }
    }
}
