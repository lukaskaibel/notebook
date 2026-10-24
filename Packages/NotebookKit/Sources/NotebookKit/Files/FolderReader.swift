import Foundation

/// Reads folders off the main thread, a few at a time, and hands what they hold back to it. Reading a folder in iCloud
/// Drive can take seconds while iCloud asks its server, and nothing on screen waits for that.
@MainActor
final class FolderReader {
    struct Request: Sendable {
        var url: URL
        /// For a location's top: the folders from elsewhere it shows among its own.
        var linked: [LinkedFolder] = []
    }

    /// What one folder holds; nil when it is gone or no longer a folder.
    typealias Result = (path: String, listing: [FileNode.Listing]?)

    /// Folders being opened and changes, a few at once so iCloud isn't asked for everything at the same time.
    private let queue = FolderReader.queue("Notebook folders", width: 4)
    /// Folders read ahead of time, on slots of their own: they never keep one you open waiting.
    private let aheadQueue = FolderReader.queue("Notebook folders ahead", width: 2)
    /// The newest read of each folder, so one that was overtaken by a later read is dropped when it finishes.
    private var newest: [String: Int] = [:]
    /// The read ahead of time waiting for each folder, to read it next instead when the folder is opened.
    private var waiting: [String: (operation: Operation, request: Request, done: ([Result]) -> Void)] = [:]
    private var count = 0
    #if DEBUG
    /// How long each read takes, for a test: in place of `-NotebookSlowFolders`, which every test run on the Mac at the
    /// time shares (they all have the defaults of xctest), so that another one could change it in the middle.
    var delay: TimeInterval?
    #endif

    private static func queue(_ name: String, width: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = width
        return queue
    }

    func isReading(_ url: URL) -> Bool { newest[url.path] != nil }

    var isIdle: Bool { newest.isEmpty }

    /// Reads the folders in order, then calls `done` on the main thread with what each holds, in the same order
    /// (parents before what is in them, when asked for in that order). Folders read again since are left out. Reading
    /// `ahead` (folders nobody opened yet) waits for everything else.
    func read(_ requests: [Request], ahead: Bool = false, then done: @escaping ([Result]) -> Void) {
        guard !requests.isEmpty else { return done([]) }
        count += 1
        let id = count
        let operation = BlockOperation()
        for request in requests {
            newest[request.url.path] = id
            waiting[request.url.path] = nil
        }
        if ahead, requests.count == 1 { waiting[requests[0].url.path] = (operation, requests[0], done) }
        #if DEBUG
        let delay = delay
        #else
        let delay: TimeInterval? = nil
        #endif
        operation.addExecutionBlock {
            let results = requests.map { request -> Result in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: request.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return (request.url.path, nil)
                }
                return (request.url.path, FileNode.list(request.url, linked: request.linked, delay: delay))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let current = results.filter { self.newest[$0.path] == id }
                    for result in current {
                        self.newest[result.path] = nil
                        self.waiting[result.path] = nil
                    }
                    done(current)
                }
            }
        }
        (ahead ? aheadQueue : queue).addOperation(operation)
    }

    /// A folder is read again after something you did in it (`Workspace.readAgain`): the readings of it still under
    /// way began before that and could bring back what was there, so they are dropped.
    func dropReadings(of url: URL) {
        let path = HiddenFolders.withoutPrivate(url.path)
        for key in newest.keys where HiddenFolders.withoutPrivate(key) == path {
            newest[key] = nil
            waiting[key] = nil
        }
    }

    /// A folder you opened that is waiting to be read ahead of time: read it now instead.
    func hurry(_ url: URL) {
        guard let ahead = waiting.removeValue(forKey: url.path), !ahead.operation.isExecuting, !ahead.operation.isFinished else { return }
        ahead.operation.cancel()
        read([ahead.request], then: ahead.done)
    }
}
