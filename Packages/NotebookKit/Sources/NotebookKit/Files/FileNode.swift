#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import Synchronization
import UniformTypeIdentifiers

/// What a file is, for its icon and for what opening it does.
public enum FileKind: String, Sendable {
    case folder, note, pdf, image, video, audio, other

    /// The kinds of files, in the order Settings lists them for their colours.
    static let files: [FileKind] = [.note, .pdf, .image, .video, .audio, .other]

    init(url: URL, isDirectory: Bool) {
        self.init(pathExtension: isDirectory ? nil : url.pathExtension)
    }

    /// From a file's name, as from its address, without making one.
    init(name: String, isDirectory: Bool) {
        let dot = name.lastIndex(of: ".")
        self.init(pathExtension: isDirectory ? nil : dot.map { $0 == name.startIndex ? "" : String(name[name.index(after: $0)...]) } ?? "")
    }

    /// A file's name without its extension, as `URL.deletingPathExtension` leaves it.
    static func withoutExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// A folder for nil.
    private init(pathExtension: String?) {
        guard let pathExtension else { self = .folder; return }
        switch pathExtension.lowercased() {
        case "md", "markdown": self = .note
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "dng": self = .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": self = .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac": self = .audio
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .note: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    /// What Settings calls files of this kind.
    var pluralName: String {
        switch self {
        case .folder: "Folders"
        case .note: "Notes"
        case .pdf: "PDFs"
        case .image: "Pictures"
        case .video: "Videos"
        case .audio: "Audio"
        case .other: "Other files"
        }
    }

    /// The colour of its icon: the one you chose for its kind in Settings, else the accent colour, every kind alike, as
    /// the Finder's sidebar has them. A folder's own colour (Customize Folder) goes before this.
    @MainActor var tint: NSColor {
        NotebookSettings.shared.fileColors[self]?.platformColor ?? Theme.accent
    }
}

/// A file or folder in the sidebar's tree. Folders read their contents only when opened.
@MainActor
public final class FileNode: NSObject, Observable {
    public let url: URL
    public private(set) var name: String
    public let kind: FileKind
    /// In iCloud but not on this Mac yet.
    public private(set) var isInCloud: Bool
    public private(set) var modified: Date?
    public private(set) var created: Date?
    /// A folder's symbol or emoji and colour, as the Finder keeps them; nil for the plain folder. Observed: the lists on
    /// iPhone and iPad redraw a row when what is in its folder changes, and its look alone changes nothing there.
    public private(set) var icon: FolderIcon? {
        get {
            looks.access(self, keyPath: \.icon)
            return storedIcon
        }
        set {
            guard newValue != storedIcon else { return }
            looks.withMutation(of: self, keyPath: \.icon) { storedIcon = newValue }
        }
    }
    private var storedIcon: FolderIcon?
    private let looks = ObservationRegistrar()
    weak var parent: FileNode?
    /// What the folder holds, as reading it lists them: folders first, each by name.
    private(set) var children: [FileNode]? {
        didSet { arranged = nil }
    }
    /// The files as last shown, kept until what the folder holds or how it is shown changes.
    private var arranged: (arrangement: Arrangement, nodes: [FileNode])?
    /// A folder from somewhere else shown in a location (iCloud Drive's Desktop), which can't be renamed or moved.
    public let isLinked: Bool
    /// For a location's top: the folders from elsewhere it shows next to its own files.
    var linked: [LinkedFolder] = []

    init(url: URL, kind: FileKind, isInCloud: Bool = false, modified: Date? = nil, created: Date? = nil, icon: FolderIcon? = nil, parent: FileNode?,
         linkedAs name: String? = nil) {
        self.url = url
        self.kind = kind
        self.isInCloud = isInCloud
        self.modified = modified
        self.created = created
        storedIcon = icon
        self.parent = parent
        self.isLinked = name != nil
        self.name = name ?? (kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
    }

    public var isFolder: Bool { kind == .folder }

    /// What the sidebar sorts by: the file's name with its extension, a linked folder's own name.
    var sortName: String { isLinked ? name : url.lastPathComponent }

    /// The folder's contents, read from disk now if they haven't been yet. Only for what you just did yourself (a note
    /// you made, a folder you renamed): everything else reads folders off the main thread, with `apply`.
    func loadedChildren() -> [FileNode] {
        if let children { return children }
        apply(Self.list(url, linked: linked))
        return children ?? []
    }

    var hasLoadedChildren: Bool { children != nil }

    /// The folder's contents as the sidebar and the lists show them: only notes and folders if you chose so, in the
    /// order you chose, folders on top or sorted in with the files. Nothing until the folder has been read. Sorted
    /// once for each change, not each time a list asks.
    func visibleChildren() -> [FileNode] {
        let settings = NotebookSettings.shared
        let arrangement = Arrangement(order: settings.fileOrders.order(of: url), foldersFirst: settings.foldersFirst, onlyNotes: settings.showsOnlyNotes)
        if let arranged, arranged.arrangement == arrangement { return arranged.nodes }
        guard let children else { return [] }
        let nodes = arrangement.apply(to: children)
        arranged = (arrangement, nodes)
        return nodes
    }

    /// How a folder's files are shown: which of them and in what order.
    struct Arrangement: Equatable {
        var order: FileOrder
        var foldersFirst: Bool
        var onlyNotes = false

        /// The files in this order, from `nodes` as reading their folder lists them: folders first, each by name.
        @MainActor
        func apply(to nodes: [FileNode]) -> [FileNode] {
            let nodes = onlyNotes ? nodes.filter { $0.isFolder || $0.kind == .note } : nodes
            switch order {
            case .name:
                return foldersFirst ? nodes : Self.merged(nodes)
            case .dateEdited, .dateCreated:
                // Newest first, as in the Finder and Notes; a file without a date last, files of one date by name.
                let dates = nodes.map { ((order == .dateEdited ? $0.modified : $0.created)?.timeIntervalSinceReferenceDate) ?? -.infinity }
                let folders = nodes.map { foldersFirst && $0.isFolder }
                let sorted = nodes.indices.sorted { a, b in
                    if folders[a] != folders[b] { return folders[a] }
                    if dates[a] != dates[b] { return dates[a] > dates[b] }
                    return a < b
                }
                return sorted.map { nodes[$0] }
            }
        }

        /// Folders and files sorted together by name: the two lists are each in that order already, so they are
        /// only woven together, without sorting everything again.
        @MainActor
        private static func merged(_ nodes: [FileNode]) -> [FileNode] {
            let folders = nodes.filter(\.isFolder)
            let files = nodes.filter { !$0.isFolder }
            guard !folders.isEmpty, !files.isEmpty else { return nodes }
            var result: [FileNode] = []
            result.reserveCapacity(nodes.count)
            var i = 0, j = 0
            while i < folders.count, j < files.count {
                if files[j].sortName.localizedStandardCompare(folders[i].sortName) == .orderedAscending {
                    result.append(files[j])
                    j += 1
                } else {
                    result.append(folders[i])
                    i += 1
                }
            }
            result += folders[i...]
            result += files[j...]
            return result
        }
    }

    /// Takes in what reading the folder found, keeping the nodes of files that are still there. Says whether anything
    /// changed, which a folder read for the first time always has.
    @discardableResult
    func apply(_ listing: [Listing]) -> Bool {
        guard let old = children else {
            children = listing.map { FileNode($0, parent: self) }
            return true
        }
        var byPath: [String: FileNode] = [:]
        for node in old { byPath[node.url.path] = node }
        var changed = listing.count != old.count
        let merged = listing.map { item -> FileNode in
            let name = item.linkedName ?? Self.name(of: item.url, kind: item.kind)
            if let existing = byPath[item.url.path], existing.kind == item.kind, existing.name == name {
                if existing.isInCloud != item.isInCloud || existing.modified != item.modified || existing.created != item.created || existing.icon != item.icon {
                    changed = true
                }
                existing.isInCloud = item.isInCloud
                existing.modified = item.modified
                existing.created = item.created
                existing.icon = item.icon
                return existing
            }
            changed = true
            return FileNode(item, parent: self)
        }
        if !changed { changed = zip(merged, old).contains { $0 !== $1 } }
        children = merged
        return changed
    }

    /// Takes in a folder you just made in this one, so it shows before the folder has been read again. Says whether
    /// it wasn't there yet.
    @discardableResult
    func insertFolder(_ url: URL) -> Bool {
        guard let children, !children.contains(where: { Self.samePath($0.url, url) }) else { return false }
        return update(adding: [Listing(url: url, kind: .folder)])
    }

    /// Takes in what you just did in this folder, so it shows before the folder has been read again: the files that
    /// went from it (renamed, moved, thrown away) and those that came (made, renamed, moved in). The others keep their
    /// nodes. Says whether anything changed; nothing does in a folder not read yet.
    @discardableResult
    func update(removing: [URL] = [], adding: [Listing] = []) -> Bool {
        guard let children else { return false }
        let replaced = Set((removing + adding.map(\.url)).map { HiddenFolders.withoutPrivate($0.path) })
        let kept = children.filter { !replaced.contains(HiddenFolders.withoutPrivate($0.url.path)) }
        let items = kept.map { ($0.listing, $0.sortName) } + adding.map { ($0, $0.linkedName ?? $0.url.lastPathComponent) }
        return apply(Self.inOrder(items))
    }

    /// A folder renamed or moved keeps what it held, as read before, under its new address: it can show open at once,
    /// with the folders open in it.
    func takeContents(of old: FileNode) {
        guard isFolder, children == nil, let contents = old.children else { return }
        children = contents.map { child in
            let node = FileNode(url: url.appendingPathComponent(child.url.lastPathComponent, isDirectory: child.isFolder), kind: child.kind,
                                isInCloud: child.isInCloud, modified: child.modified, created: child.created, icon: child.icon, parent: self,
                                linkedAs: child.isLinked ? child.name : nil)
            node.takeContents(of: child)
            return node
        }
    }

    /// The node as reading its folder found it.
    var listing: Listing {
        Listing(url: url, kind: kind, isInCloud: isInCloud, modified: modified, created: created, icon: icon, linkedName: isLinked ? name : nil)
    }

    /// Shows a look you just chose, before the folder it is in has been read again.
    func show(_ icon: FolderIcon?) {
        self.icon = icon
    }

    /// "/private/var/…" (what reading a temporary folder names what is in it) and "/var/…" are one place.
    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        HiddenFolders.withoutPrivate(a.path) == HiddenFolders.withoutPrivate(b.path)
    }

    /// Whether a file is `folder` itself or somewhere in it.
    nonisolated static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let path = HiddenFolders.withoutPrivate(url.path)
        let folder = HiddenFolders.withoutPrivate(folder.path)
        return path == folder || path.hasPrefix(folder + "/")
    }

    private convenience init(_ item: Listing, parent: FileNode) {
        self.init(url: item.url, kind: item.kind, isInCloud: item.isInCloud, modified: item.modified, created: item.created, icon: item.icon, parent: parent,
                  linkedAs: item.linkedName)
    }

    private static func name(of url: URL, kind: FileKind) -> String {
        kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    func child(named name: String) -> FileNode? {
        loadedChildren().first { !$0.isLinked && $0.url.lastPathComponent == name }
    }

    // MARK: - Reading folders

    /// One file as reading its folder found it: what a node is made from, on the main thread, afterwards.
    struct Listing: Sendable, Equatable {
        var url: URL
        var kind: FileKind
        var isInCloud = false
        /// When the file was last edited and when it was made, read with the rest, for sorting by them.
        var modified: Date?
        var created: Date?
        var icon: FolderIcon?
        /// For a folder from elsewhere shown in a location: its name there.
        var linkedName: String?
    }

    #if DEBUG
    /// How many folders were read on the main thread, for tests to see that nothing they do reads any there.
    nonisolated static let mainThreadReads = Mutex(0)
    #endif

    /// What reading a folder asks about each file, all in the one pass: sorting by date needs no look at a file of its own.
    nonisolated static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey,
                                                     .creationDateKey]

    /// Reads a folder: its files and folders in the sidebar's order, with `linked` among them. This can take a while
    /// (iCloud Drive may have to ask the server first), so apart from what you just did yourself it runs off the main
    /// thread. `delay` stands in for `-NotebookSlowFolders` in Debug builds.
    nonisolated static func list(_ folder: URL, linked: [LinkedFolder] = [], delay: TimeInterval? = nil) -> [Listing] {
        #if DEBUG
        // A slow disk or a slow iCloud, for trying out that nothing waits for it. Reads on the main thread (what you
        // just did yourself) aren't slowed down but logged, to find any that shouldn't be there.
        let delay = delay ?? UserDefaults.standard.double(forKey: "NotebookSlowFolders")
        if Thread.isMainThread { mainThreadReads.withLock { $0 += 1 } }
        if delay > 0 {
            if Thread.isMainThread { NSLog("Notebook: read %@ on the main thread", folder.path) } else { Thread.sleep(forTimeInterval: delay) }
        }
        #endif
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        var items: [(listing: Listing, sortName: String)] = []
        for item in contents {
            guard let listing = listing(of: item, in: folder) else { continue }
            items.append((listing, listing.url.lastPathComponent))
        }
        for folder in linked {
            // Through a URL of its own: the linked folder's is kept, and a URL keeps what it read about its file.
            let values = try? URL(fileURLWithPath: folder.url.path).resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            items.append((Listing(url: folder.url, kind: .folder, modified: values?.contentModificationDate, created: values?.creationDate, linkedName: folder.name),
                          folder.name))
        }
        return inOrder(items)
    }

    /// One file as reading its folder finds it; nil for one the sidebar doesn't show. Also for a file you just made,
    /// renamed or moved, to show it before its folder has been read again.
    nonisolated static func listing(of item: URL, in folder: URL? = nil) -> Listing? {
        let folder = folder ?? item.deletingLastPathComponent()
        var url = item
        var name = item.lastPathComponent
        var inCloud = false
        // Older iCloud Drive placeholders: ".Name.pdf.icloud".
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(7))
            url = folder.appendingPathComponent(name)
            inCloud = true
        } else if name.hasPrefix(".") {
            return nil
        }
        let values = try? item.resourceValues(forKeys: Set(keys))
        if values?.isHidden == true, !inCloud { return nil }
        let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        if let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded { inCloud = true }
        let kind = FileKind(url: url, isDirectory: isDirectory)
        return Listing(url: url, kind: kind, isInCloud: inCloud, modified: values?.contentModificationDate, created: values?.creationDate,
                       icon: kind == .folder ? FolderIcons.read(url) : nil)
    }

    /// The order folders are read in: folders first, then by name as the Finder sorts. The order you chose is made from
    /// it (`Arrangement`).
    nonisolated private static func inOrder(_ items: [(listing: Listing, sortName: String)]) -> [Listing] {
        items.sorted { a, b in
            if (a.listing.kind == .folder) != (b.listing.kind == .folder) { return a.listing.kind == .folder }
            return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
        }.map(\.listing)
    }
}
