#if os(macOS)
import CoreServices
import Foundation

/// Tells about changes under some folders (made by Notebook, the Finder, iCloud or anything else), a few at a time, on
/// the main thread. Starting to watch opens every folder, which in iCloud Drive can take seconds, so that happens on a
/// queue of its own.
final class FileWatcher {
    private let stream: Stream

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        stream = Stream(handler: handler)
        guard !paths.isEmpty else { return }
        let stream = stream
        Stream.queue.async { stream.start(paths) }
    }

    deinit {
        let stream = stream
        stream.isStoppedOnMain = true
        Stream.queue.async { stream.stop() }
    }

    /// Calls `done` on the main queue once every watcher made so far is watching: what changes from then on is told
    /// about. For tests, which change files elsewhere as soon as the locations have been read.
    static func whenWatching(_ done: @escaping @Sendable () -> Void) {
        Stream.queue.async { DispatchQueue.main.async(execute: done) }
    }

    /// The event stream, only touched on `queue`, where it is started, stopped and tells about changes.
    private final class Stream: @unchecked Sendable {
        static let queue = DispatchQueue(label: "Notebook file events", qos: .utility)
        private var ref: FSEventStreamRef?
        private var isStopped = false
        private let handler: ([String]) -> Void

        init(handler: @escaping ([String]) -> Void) {
            self.handler = handler
        }

        func start(_ paths: [String]) {
            guard !isStopped else { return }
            // Not retained: it lives until `stop`, which runs on this queue, after which no change comes in any more.
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let changed = Array(array.prefix(count))
                DispatchQueue.main.async { if !stream.isStoppedOnMain { stream.handler(changed) } }
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            ref = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
            if let ref {
                FSEventStreamSetDispatchQueue(ref, Self.queue)
                FSEventStreamStart(ref)
            }
        }

        func stop() {
            isStopped = true
            guard let ref else { return }
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
            self.ref = nil
        }

        /// Set on the main thread when the watcher goes, so changes already on their way there are dropped.
        var isStoppedOnMain = false
    }
}
#else
import Foundation

/// Tells about changes under some folders, a few at a time. iOS has no FSEvents: every folder is presented to the
/// file coordinator, which reports what other apps, the Files app and iCloud change through it.
final class FileWatcher {
    private let presenters: [FolderPresenter]

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        let batch = ChangeBatch(handler: handler)
        presenters = paths.map { FolderPresenter(url: URL(fileURLWithPath: $0, isDirectory: true), batch: batch) }
        presenters.forEach(NSFileCoordinator.addFilePresenter)
    }

    deinit {
        presenters.forEach(NSFileCoordinator.removeFilePresenter)
    }
}

/// Collects the changed paths for a quarter of a second, as FSEvents does on the Mac.
private final class ChangeBatch: @unchecked Sendable {
    private let handler: ([String]) -> Void
    private var paths: [String] = []

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    /// Called on the main queue.
    func add(_ urls: [URL]) {
        let wasEmpty = paths.isEmpty
        paths += urls.map(\.path)
        guard wasEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let changed = paths
            paths = []
            handler(changed)
        }
    }
}

private final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let batch: ChangeBatch

    init(url: URL, batch: ChangeBatch) {
        presentedItemURL = url
        self.batch = batch
    }

    func presentedSubitemDidChange(at url: URL) { batch.add([url]) }
    func presentedSubitemDidAppear(at url: URL) { batch.add([url]) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { batch.add([oldURL, newURL]) }
    func presentedItemDidChange() { presentedItemURL.map { batch.add([$0]) } }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        DispatchQueue.main.async { [batch] in batch.add([url]) }
    }
}
#endif
