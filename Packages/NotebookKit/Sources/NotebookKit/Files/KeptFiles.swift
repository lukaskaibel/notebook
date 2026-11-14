import Foundation

/// A file Notebook shows on its own, outside every folder you opened: one chosen with Open File, or one another app
/// handed over. Some apps give other apps only single files, never their folders (Nextcloud on iPhone and iPad), so this
/// is the only way to keep their notes at hand. iOS gives access to the file alone, and the bookmark made when it came is
/// what opens it again in later runs.
public struct KeptFile: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data?) {
        self.path = path
        self.bookmark = bookmark
    }

    /// Standardized, as every address in the app is.
    public var url: URL { URL(fileURLWithPath: path).standardizedFileURL }
}

/// The kept files, in the app's settings, with their bookmarks. Making a bookmark and finding where one points can wait
/// on the app the file comes from, so both happen off the main thread, as for locations (`LocationStore`).
@MainActor
enum KeptFileStore {
    private static let key = "keptFiles"

    static func load() -> [KeptFile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KeptFile].self, from: data)) ?? []
    }

    static func save(_ files: [KeptFile]) {
        if let data = try? JSONEncoder().encode(files) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Where the files are now, by their bookmarks, with access to each started and a fresh bookmark for one that
    /// moved. A file whose bookmark doesn't lead anywhere now (its app signed out, say) stays where it was, to be found
    /// again next time. Off the main thread.
    nonisolated static func resolve(_ files: [KeptFile]) -> [KeptFile] {
        files.map { file in
            guard let bookmark = file.bookmark, let found = LocationStore.resolve(bookmark) else { return file }
            return KeptFile(path: found.url.path, bookmark: found.fresh ?? bookmark)
        }
    }
}
