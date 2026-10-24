#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Synchronization

/// A folder Notebook shows in the sidebar: iCloud Drive or any folder you add. In the sandboxed build the app can only
/// reach it through the security-scoped bookmark made when you picked it.
public struct Location: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    /// Folders shown in the location that are somewhere else on disk, looked up again every launch.
    public var linked: [LinkedFolder] = []

    private enum CodingKeys: String, CodingKey { case id, name, path, bookmark }

    public init(id: UUID, name: String, path: String, bookmark: Data?) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }

    /// Standardized, as every address in the app is, so "/private/tmp" and "/tmp" compare equal.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }

    public var isICloudDrive: Bool { path == Location.iCloudDrivePath || Location.isICloudDriveRoot(url) }

    /// iCloud Drive's own folder, wherever the system keeps it (on iOS it isn't in the app's home).
    static func isICloudDriveRoot(_ url: URL) -> Bool {
        url.lastPathComponent == "com~apple~CloudDocs" && url.deletingLastPathComponent().lastPathComponent == "Mobile Documents"
    }

    /// Where iCloud Drive is, worked out from the real home folder (the sandbox gives the app another one).
    public static var iCloudDrivePath: String {
        #if DEBUG
        // A stand-in iCloud Drive, for tests.
        if let path = UserDefaults.standard.string(forKey: "NotebookICloudDrive") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        #endif
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    /// The folder a file is under in this location, the location's own or a linked one, with the place the sidebar
    /// gives it ("iCloud Drive › Desktop").
    func folder(containing path: String) -> (url: URL, place: String, linked: LinkedFolder?)? {
        folders.first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }

    /// The location's own folder, then the linked ones.
    var folders: [(url: URL, place: String, linked: LinkedFolder?)] {
        [(url, name, nil)] + linked.map { ($0.url, name + " › " + $0.name, $0) }
    }

    #if os(iOS)
    /// Where the folder is, as the Files app names the places: "iCloud Drive › Notes", "On My iPhone › Notebook".
    @MainActor
    var place: String {
        let path = url.path
        if let range = path.range(of: "/Mobile Documents/com~apple~CloudDocs") {
            return (["iCloud Drive"] + path[range.upperBound...].split(separator: "/").map(String.init)).joined(separator: " › ")
        }
        let documents = Workspace.onDeviceFolder.standardizedFileURL.path
        if path == documents || path.hasPrefix(documents + "/") {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
            return ([device, "Notebook"] + path.dropFirst(documents.count).split(separator: "/").map(String.init)).joined(separator: " › ")
        }
        return url.pathComponents.suffix(2).joined(separator: " › ")
    }
    #endif

    func contains(_ url: URL) -> Bool {
        folder(containing: url.standardizedFileURL.path) != nil
    }

    func isLinkedFolder(_ url: URL) -> Bool {
        linked.contains { $0.url.path == url.standardizedFileURL.path }
    }

    /// Looks up the linked folders again: iCloud Drive's, for now.
    mutating func findLinkedFolders() {
        linked = isICloudDrive ? Self.iCloudDriveLinks(in: url) : []
    }

    /// What the Finder shows in iCloud Drive without it being in iCloud Drive's folder: Desktop and Documents when
    /// they are kept in iCloud (hidden links to the real folders), and the iCloud folders of apps that share theirs,
    /// such as Pages or Obsidian. Those sit next to iCloud Drive, and the system hides the ones of every other app.
    static func iCloudDriveLinks(in drive: URL) -> [LinkedFolder] {
        let files = FileManager.default
        var found: [LinkedFolder] = []
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isHiddenKey]
        for item in (try? files.contentsOfDirectory(at: drive, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard let values = try? item.resourceValues(forKeys: keys), values.isSymbolicLink == true, values.isHidden == true else { continue }
            let target = item.resolvingSymlinksInPath().standardizedFileURL
            if isReadableFolder(target) { found.append(LinkedFolder(name: item.lastPathComponent, url: target, alias: item.standardizedFileURL)) }
        }
        let containers = drive.deletingLastPathComponent()
        for container in (try? files.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isHiddenKey, .localizedNameKey])) ?? [] {
            let values = try? container.resourceValues(forKeys: [.isHiddenKey, .localizedNameKey])
            guard container.standardizedFileURL.path != drive.path, values?.isHidden == false else { continue }
            let documents = container.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
            guard isReadableFolder(documents) else { continue }
            var name = values?.localizedName ?? container.lastPathComponent
            if name == container.lastPathComponent {
                // Without a name from iCloud, the app's from the container's: "iCloud~md~obsidian" is Obsidian.
                let last = container.lastPathComponent.split(separator: "~").last.map(String.init) ?? name
                name = last.prefix(1).uppercased() + last.dropFirst()
            }
            found.append(LinkedFolder(name: name, url: documents, alias: documents))
        }
        return found
    }

    /// In the sandboxed build iCloud Drive's bookmark doesn't reach these, and folders the app can't read stay out.
    private static func isReadableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }
}

/// A folder that shows inside a location without being in its folder, such as iCloud Drive's Desktop.
public struct LinkedFolder: Equatable, Sendable {
    public var name: String
    public var url: URL
    /// Where it is in iCloud: the link to it in iCloud Drive (Desktop), or the folder itself (an app's).
    public var alias: URL
}

/// The locations, kept in the app's settings, with their bookmarks. Making a bookmark and finding where one points
/// can wait on iCloud for seconds, so both happen off the main thread, after the location is already shown.
@MainActor
enum LocationStore {
    private static let key = "locations"
    nonisolated private static let accessing = Mutex<Set<String>>([])

    #if os(macOS)
    nonisolated private static let resolving: URL.BookmarkResolutionOptions = [.withSecurityScope]
    nonisolated private static let creating: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    // On iOS a bookmark made from a URL the document picker gave carries its access along.
    nonisolated private static let resolving: URL.BookmarkResolutionOptions = []
    nonisolated private static let creating: URL.BookmarkCreationOptions = []
    #endif

    /// The saved locations, where they were last time; `resolve` finds where they are now.
    static func load() -> [Location] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let locations = try? JSONDecoder().decode([Location].self, from: data) else { return [] }
        return locations
    }

    static func save(_ locations: [Location]) {
        if let data = try? JSONEncoder().encode(locations) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// A location for a folder you just chose, to show at once: its bookmark comes from `bookmark(for:)`.
    static func make(for url: URL) -> Location {
        startAccessing(url)
        let name = url.path == Location.iCloudDrivePath || Location.isICloudDriveRoot(url) ? "iCloud Drive" : url.lastPathComponent
        return Location(id: UUID(), name: name, path: url.standardizedFileURL.path, bookmark: nil)
    }

    /// The bookmark that finds the folder again next time, and the name the Finder gives it ("Dokumente" for
    /// Documents in German). Off the main thread.
    nonisolated static func bookmark(for url: URL) -> (bookmark: Data?, name: String) {
        let bookmark = try? url.bookmarkData(options: creating, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.path == Location.iCloudDrivePath || Location.isICloudDriveRoot(url) ? "iCloud Drive" : FileManager.default.displayName(atPath: url.path)
        return (bookmark, name)
    }

    /// Where a saved location's folder is now, with a fresh bookmark when the old one is stale, and access to it
    /// started. Off the main thread.
    nonisolated static func resolve(_ bookmark: Data) -> (url: URL, fresh: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolving, bookmarkDataIsStale: &stale) else { return nil }
        startAccessing(url)
        let fresh = stale ? try? url.bookmarkData(options: creating, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (url.standardizedFileURL, fresh)
    }

    nonisolated static func startAccessing(_ url: URL) {
        accessing.withLock { accessing in
            guard !accessing.contains(url.path) else { return }
            if url.startAccessingSecurityScopedResource() { accessing.insert(url.path) }
        }
    }

    #if os(macOS)
    /// Asks for a folder, starting in iCloud Drive or wherever `directory` says.
    static func choose(startingIn directory: URL? = nil, message: String? = nil, prompt: String = "Open") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message ?? "Choose a folder with your notes. Notebook shows everything in it."
        panel.directoryURL = directory ?? URL(fileURLWithPath: Location.iCloudDrivePath, isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif
}
