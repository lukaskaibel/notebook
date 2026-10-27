import Foundation

/// To-dos in no note: those added in To-dos, until you move them into a note. They are kept as one plain Markdown
/// checklist, `To-dos.md`, in Notebook's own iCloud folder next to the History, outside its `Documents`: iCloud takes it
/// to your other devices as it takes the History, without it showing in iCloud Drive, and Spotlight leaves it out. It
/// is in no location, so the sidebar and search never show it as a note. Without iCloud (Debug and Release builds, or
/// signed out) it is in Application Support, on this device only, in a folder Spotlight leaves out. Any app can open
/// it; To-dos changes it as it changes a note, a line at a time, merged with what is there.
@MainActor
final class LooseTodos {
    /// The file as it was read.
    struct Snapshot: Sendable, Equatable {
        var url: URL
        var text: String
        var modified: Date?
    }

    /// Where the file goes.
    enum Place: Sendable {
        /// In Notebook's iCloud folder, the first container in the app's entitlements, when there is one; else in this
        /// folder. Looked up the first time it is needed, off the main thread, as Apple asks.
        case container(local: URL)
        /// In this folder: tests, and a library given on the command line.
        case folder(URL)
    }

    nonisolated static let fileName = "To-dos.md"

    /// The file, once looked up.
    private(set) var url: URL?
    /// The file as last read; nil until it has been.
    private(set) var snapshot: Snapshot?
    /// Told on the main thread each time the file was read.
    var onRead: ((Snapshot) -> Void)?

    private var place: Place
    private var lookup: Task<URL, Never>?
    private var presenter: Presenter?
    private var isReading = false
    private var readsAgain = false
    private var identityObserver: NSObjectProtocol?

    init(place: Place) {
        self.place = place
    }

    /// In Application Support, in a folder whose name ends in `.noindex`, which Spotlight leaves out.
    static var defaultLocalFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notebook", isDirectory: true)
            .appendingPathComponent("To-dos.noindex", isDirectory: true)
    }

    /// Where the app keeps them; tests keep theirs apart.
    static var defaultPlace: Place {
        if isTesting {
            return .folder(FileManager.default.temporaryDirectory.appendingPathComponent("Notebook to-dos \(UUID().uuidString)", isDirectory: true))
        }
        return .container(local: defaultLocalFolder)
    }

    /// Keeps them in `folder` from now on, on this device: for a library given on the command line (the sample notes,
    /// UI tests), whose to-dos have no business among your own. Before `start`. Unit tests keep each workspace's apart.
    func keepOnDevice(in folder: URL) {
        guard !Self.isTesting else { return }
        place = .folder(folder)
    }

    /// In unit tests. `swift test` doesn't say so in the environment, as Xcode does: XCTest is loaded, though.
    nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// Looks the file up and reads it, once; again when iCloud's account changes.
    func start() {
        guard lookup == nil else { return }
        let place = place
        let task = Task.detached(priority: .utility) { Self.lookUp(place) }
        lookup = task
        Task {
            let url = await task.value
            guard lookup == task else { return }
            self.url = url
            watch(url)
            read()
        }
        if identityObserver == nil, case .container = place {
            // Signing out of iCloud or into another account: the file is looked up again.
            identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lookup = nil
                    self?.start()
                }
            }
        }
    }

    /// The file, waiting for it to be looked up.
    func fileURL() async -> URL {
        if let url { return url }
        start()
        return await lookup?.value ?? Self.lookUp(place)
    }

    /// Reads the file again, in the background: after Notebook changed it, when it changed on another device, and
    /// when the app comes to the front. One reading at a time, and after a burst of changes one for all of them.
    func read() {
        guard let url else { return }
        guard !isReading else { return readsAgain = true }
        isReading = true
        Task {
            let read = await Self.read(url)
            isReading = false
            // Not read now (iCloud couldn't bring it down): what was read before stays.
            if let read, read.url == self.url {
                snapshot = read
                onRead?(read)
            }
            if readsAgain {
                readsAgain = false
                self.read()
            }
        }
    }

    // MARK: - The file

    /// The file: in Notebook's iCloud folder when there is one, and then with any kept on this device before there was
    /// added to it.
    nonisolated static func lookUp(_ place: Place) -> URL {
        let manager = FileManager.default
        switch place {
        case .folder(let folder):
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent(fileName)
        case .container(let local):
            let here = local.appendingPathComponent(fileName)
            guard let cloud = manager.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("To-dos", isDirectory: true) else {
                try? manager.createDirectory(at: local, withIntermediateDirectories: true)
                return here
            }
            try? manager.createDirectory(at: cloud, withIntermediateDirectories: true)
            let there = cloud.appendingPathComponent(fileName)
            moveIn(here, to: there)
            return there
        }
    }

    /// To-dos added on this device before there was iCloud go to the end of those in iCloud.
    nonisolated private static func moveIn(_ local: URL, to cloud: URL) {
        guard let text = NoteDocument.read(local) else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.isEmpty || append(lines, to: cloud) != nil { try? FileManager.default.removeItem(at: local) }
    }

    /// The file's text and date, in a coordinated read that brings it down from iCloud first, without holding a thread
    /// while it waits. Empty when there is no file yet; nil when it couldn't be read.
    nonisolated static func read(_ url: URL) async -> Snapshot? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return await withCheckedContinuation { continuation in
            let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
            NSFileCoordinator().coordinate(with: [intent], queue: readQueue) { error in
                guard error == nil else { return continuation.resume(returning: nil) }
                guard FileManager.default.fileExists(atPath: intent.url.path) else {
                    return continuation.resume(returning: Snapshot(url: url, text: "", modified: nil))
                }
                guard let data = try? Data(contentsOf: intent.url), let text = NoteDocument.decode(data) else { return continuation.resume(returning: nil) }
                continuation.resume(returning: Snapshot(url: url, text: text, modified: NoteDocument.modificationDate(intent.url)))
            }
        }
    }

    nonisolated private static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Notebook to-dos reads"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Adds lines at the end of the file, which is made, with its folder, when it isn't there yet. The number of the
    /// line the first of them is on, or nil when the file couldn't be written.
    nonisolated static func append(_ lines: [String], to url: URL) -> Int? {
        var line: Int?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { url in
            let manager = FileManager.default
            let old: String
            if manager.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return }
                old = text
            } else {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                old = ""
            }
            let adding = adding(lines, to: old)
            if FileOperations.write(Data((old + adding.text).utf8), to: url) { line = adding.line }
        }
        return line
    }

    /// What goes at the end of a file's text for these lines to be its last, in the file's line endings, and the number
    /// of the line the first of them is on then.
    nonisolated static func adding(_ lines: [String], to text: String) -> (text: String, line: Int) {
        let string = text as NSString
        let document = MarkdownParser.parse(string)
        guard let last = document.lines.last, !text.isEmpty else { return (lines.map { $0 + "\n" }.joined(), 0) }
        let ending = Todos.lineEnding(in: string, line: last)
        // The last line ends without a line ending: one goes in first. An empty last line is where they go.
        let isEmptyLast = last.range.length == 0 && last.breakLength == 0
        let before = last.breakLength == 0 && !isEmptyLast ? ending : ""
        let first = isEmptyLast ? document.lines.count - 1 : document.lines.count
        return (before + lines.map { $0 + ending }.joined(), first)
    }

    // MARK: - Watching

    /// Tells about changes to the file made somewhere else: by iCloud, from another device, or another app.
    private func watch(_ url: URL) {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        let presenter = Presenter(folder: url.deletingLastPathComponent()) { [weak self] in
            Task { @MainActor in self?.read() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        private let changed: @Sendable () -> Void

        init(folder: URL, changed: @escaping @Sendable () -> Void) {
            presentedItemURL = folder
            self.changed = changed
        }

        func presentedSubitemDidChange(at url: URL) {
            if url.lastPathComponent == LooseTodos.fileName || url.lastPathComponent.hasSuffix(".icloud") { changed() }
        }

        func presentedItemDidChange() { changed() }
    }
}
