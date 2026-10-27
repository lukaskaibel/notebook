import Foundation

/// What looking at a location found, off the main thread: where its folder is, the folders it shows from elsewhere
/// (iCloud Drive's Desktop), and what is at its top and in the folders that were open. All of it can take seconds in
/// iCloud Drive; the sidebar shows the location's name meanwhile and its files once this is done.
struct LocationSurvey: Sendable {
    struct Job: Sendable {
        var id: UUID
        var url: URL
        /// The saved bookmark, to find the folder by when it may have moved: the first time after launch.
        var bookmark: Data?
        /// A folder just chosen, whose bookmark and name are still to be made.
        var isNew = false
        /// What the location shows now: the folders from elsewhere, and whether its top has been read.
        var linked: [LinkedFolder]
        var isRead: Bool
        /// Folders to read along with the top when it hasn't been read: those open in the sidebar last time, and those
        /// down to the file that is open. Only the ones in this location are read.
        var folders: [String]
    }

    var id: UUID
    var url: URL
    /// A bookmark to keep instead of the saved one: for a new location, or when the old one was stale.
    var bookmark: Data?
    /// The name the Finder gives a new location's folder.
    var name: String?
    var linked: [LinkedFolder]
    /// The location's top, when it had to be read (again).
    var top: [FileNode.Listing]?
    /// The other folders read, parents first.
    var folders: [(path: String, listing: [FileNode.Listing])] = []

    static func run(_ job: Job) -> LocationSurvey {
        var url = job.url
        var survey = LocationSurvey(id: job.id, url: url, linked: [])
        if let saved = job.bookmark, let resolved = LocationStore.resolve(saved) {
            url = resolved.url
            survey.url = url
            survey.bookmark = resolved.fresh
        }
        if job.isNew {
            let made = LocationStore.bookmark(for: url)
            survey.bookmark = made.bookmark
            survey.name = made.name
        }
        let isICloudDrive = Location(id: job.id, name: "", path: url.path, bookmark: nil).isICloudDrive
        survey.linked = isICloudDrive ? Location.iCloudDriveLinks(in: url) : []
        let moved = url.path != job.url.path
        if !job.isRead || moved || survey.linked != job.linked {
            survey.top = FileNode.list(url, linked: survey.linked)
        }
        guard !job.isRead || moved else { return survey }
        let places = [url.path] + survey.linked.map(\.url.path)
        let inside = Set(job.folders).filter { path in
            path != url.path && places.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        for path in inside.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            survey.folders.append((path, FileNode.list(URL(fileURLWithPath: path, isDirectory: true))))
        }
        return survey
    }
}
