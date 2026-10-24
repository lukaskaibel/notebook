#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Synchronization

/// An open note: its text, saved shortly after you stop typing, and kept in step with the file when something else
/// (iCloud, another app) changes it. A note that is on this device in full is read at once; one still in iCloud is read
/// in the background, and until its text is in, nothing is taken in or saved, so nothing is written over.
@MainActor
@Observable
public final class NoteDocument: NSObject, NSFilePresenter {
    public private(set) var url: URL {
        didSet { presentedURL.withLock { $0 = url } }
    }
    /// The address for the file coordinator, which asks for it from other threads.
    @ObservationIgnored private let presentedURL: Mutex<URL>
    public private(set) var text: String
    private(set) var savedText: String
    /// Made with ⌘N and not given a title yet; thrown away if left without text too, even text typed and taken out again.
    var isNew = false
    public private(set) var modified: Date?
    /// Why the text isn't there yet; nil once it is.
    public private(set) var pending: Pending?
    /// The file changed elsewhere while there were unsaved edits here (or iCloud has another version).
    var conflict: Conflict?
    /// Called when the file changed on disk and the new text was taken in.
    @ObservationIgnored var onExternalChange: ((String) -> Void)?
    @ObservationIgnored var onMove: ((URL) -> Void)?
    @ObservationIgnored var onDelete: (() -> Void)?
    /// Called when the text came in, read in the background.
    @ObservationIgnored var onLoad: ((String) -> Void)?
    /// Called after the text was written to the file.
    @ObservationIgnored var onSave: (() -> Void)?

    @ObservationIgnored private var saveTimer: Timer?
    static let saveDelay: TimeInterval = 0.6
    /// The read in the background, to call off when the note is closed first.
    @ObservationIgnored private var reader: NSFileCoordinator?
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var changedWhileReading = false
    @ObservationIgnored private var isClosed = false
    /// Notebook is renaming or moving the file (or its folder) off the main thread: saving waits until it is done, as a
    /// save meanwhile would write the note again where it was.
    @ObservationIgnored private var moves = 0
    /// The save, or the look at what changed on disk, under way off the main thread. One at a time: what is asked for
    /// meanwhile comes after it (`wantsSave`, `wantsRead`), as does whatever waits for the note to be saved.
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var wantsSave = false
    @ObservationIgnored private var wantsRead = false
    @ObservationIgnored private var whenSaved: [() -> Void] = []
    /// A conflict was settled, and what is on disk now is being read, to save over: nothing is saved until it is in.
    @ObservationIgnored private var isSettling = false
    @ObservationIgnored private var settleNext: (() -> Void)?
    /// The file was deleted on purpose: it isn't written again. Read where it is written, off the main thread.
    @ObservationIgnored private let wasDeleted = Mutex(false)
    /// Where notes are read in the background. The coordinated read waits for iCloud without holding a thread.
    private nonisolated static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Notebook notes"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public enum Pending: Equatable, Sendable {
        /// Being read in the background (the debug delay, or after it couldn't be read).
        case reading
        /// Coming down from iCloud: the file isn't on this device yet, or iCloud has a newer version of it.
        case downloading
        /// It couldn't be read. It is tried again when the file changes.
        case unreadable
    }

    public var isLoaded: Bool { pending == nil }

    struct Conflict: Equatable {
        var otherText: String
        var source: String
        var date: Date?
    }

    init(url: URL) {
        self.url = url
        presentedURL = Mutex(url)
        let pending = Self.wait(for: url)
        let loaded = pending == nil ? Self.read(url) ?? "" : ""
        text = loaded
        savedText = loaded
        self.pending = pending
        modified = Self.modificationDate(url)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        if isLoaded { checkForConflictVersions() } else { readInBackground() }
    }

    func close() {
        isClosed = true
        reader?.cancel()
        reader = nil
        saveNow()
        saveTimer?.invalidate()
        NSFileCoordinator.removeFilePresenter(self)
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Reading and writing

    /// Reads a note in a coordinated read, which waits for iCloud to bring it down: only for a note on this device.
    nonisolated static func read(_ url: URL) -> String? {
        var result: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = (try? Data(contentsOf: url)).flatMap(decode)
        }
        return result
    }

    nonisolated static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// What reading a note would wait for: iCloud bringing it down (or a newer version of it), or in Debug builds the
    /// delay of `-NotebookSlowFiles`. Nil when the note is on this device in full, and is read at once as always.
    nonisolated static func wait(for url: URL) -> Pending? {
        #if DEBUG
        if FileLoading.debugDelay != nil { return .reading }
        #endif
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return nil }
        return status == .current ? nil : .downloading
    }

    /// Reads the text off the main thread and takes it in when it comes. The coordinated read asks iCloud for the file
    /// and waits for it without keeping a thread waiting.
    private func readInBackground() {
        reads += 1
        let attempt = reads
        let coordinator = NSFileCoordinator()
        reader = coordinator
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        coordinator.coordinate(with: [intent], queue: Self.readQueue) { error in
            #if DEBUG
            if let delay = FileLoading.debugDelay { Thread.sleep(forTimeInterval: delay) }
            #endif
            let text = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(Self.decode) : nil
            let modified = Self.modificationDate(intent.url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishReading(attempt, text: text, modified: modified) }
            }
        }
    }

    private func finishReading(_ attempt: Int, text loaded: String?, modified: Date?) {
        guard attempt == reads, !isClosed, !isLoaded else { return }
        reader = nil
        guard let loaded else {
            pending = .unreadable
            return
        }
        text = loaded
        savedText = loaded
        if let modified { self.modified = modified }
        pending = nil
        onLoad?(loaded)
        checkForConflictVersions()
        // It changed while it was being read: take in what it is now.
        if changedWhileReading {
            changedWhileReading = false
            fileChangedOnDisk()
        }
    }

    /// Takes in what is typed and saves it a moment later. Nothing is, before the note's own text is in.
    func update(text newText: String) {
        guard isLoaded, newText != text else { return }
        text = newText
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// Saves what was typed, off the main thread. A save under way is finished first, and this one comes after it.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard canSave else { return }
        guard job == nil else {
            wantsSave = true
            return
        }
        write()
    }

    /// Saves what was typed and calls `then` once it is written, or can't be for now (a conflict, a move under way).
    func save(then: @escaping () -> Void) {
        saveNow()
        if job == nil { then() } else { whenSaved.append(then) }
    }

    func save() async {
        await withCheckedContinuation { continuation in save { continuation.resume() } }
    }

    /// Saves what was typed and waits until it is on disk: the app is quitting, and wouldn't wait otherwise. What is
    /// done off the main thread never needs the main thread, so it can wait here.
    func saveWaiting() {
        saveNow()
        while let job {
            job.done.wait()
            finish(job)
            if case .failed = job.outcome { break }
        }
    }

    var hasUnsavedChanges: Bool { text != savedText }

    private var canSave: Bool { isLoaded && moves == 0 && conflict == nil && !isSettling && text != savedText }

    /// A save or a read off the main thread. What it found is taken in on the main thread, or at once when quitting
    /// waits for it (`saveWaiting`).
    private final class Job: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        /// Set once, before `done` is signalled, and read after.
        private(set) var outcome: Outcome = .failed
        #if os(iOS)
        var endBackgroundTask: (() -> Void)?
        #endif

        func finish(_ outcome: Outcome) {
            self.outcome = outcome
            done.signal()
        }
    }

    private enum Outcome: Sendable {
        /// This text was written.
        case written(String, modified: Date?)
        /// It changed elsewhere since the last save, to this, and wasn't written: what it says is merged in first.
        case changed(String, modified: Date?)
        /// What it says, read after it changed elsewhere.
        case read(String, modified: Date?)
        /// What it says once a conflict was settled (nil when it couldn't be read).
        case settled(String?)
        case failed
    }

    /// Writes the text in a coordinated write off the main thread, which waits for iCloud or another app holding the
    /// file without the window waiting. What is typed meanwhile is saved after. The file is read in the same write:
    /// changed elsewhere since the last save, it isn't written over, but what it says is merged in, or asked about.
    /// (Replacing, not merging, asks no other note open on the file to save first, which would need the main thread.)
    private func write() {
        let (base, mine) = (savedText, text)
        let intent = NSFileAccessIntent.writingIntent(with: url, options: .forReplacing)
        start { job in
            NSFileCoordinator(filePresenter: self).coordinate(with: [intent], queue: Self.readQueue) { error in
                job.finish(error == nil ? Self.write(mine, over: base, at: intent.url, unless: self.wasDeleted) : .failed)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(job) } }
            }
        }
    }

    nonisolated private static func write(_ mine: String, over base: String, at url: URL, unless deleted: borrowing Mutex<Bool>) -> Outcome {
        FileOperations.debugWait("saved", url)
        guard !deleted.withLock({ $0 }) else { return .failed }
        let disk = (try? Data(contentsOf: url)).flatMap(decode)
        // Never written over a change made elsewhere since the last save. (Gone, it is written again.)
        if let disk, disk != base { return .changed(disk, modified: modificationDate(url)) }
        guard FileOperations.write(Data(mine.utf8), to: url) else { return .failed }
        return .written(mine, modified: modificationDate(url))
    }

    /// Reads the file after it changed elsewhere, off the main thread, and takes in what it says.
    private func readChanges() {
        // Without asking other notes open on it to save first: it has been changed already.
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        start { job in
            NSFileCoordinator(filePresenter: self).coordinate(with: [intent], queue: Self.readQueue) { error in
                let disk = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(Self.decode) : nil
                job.finish(disk.map { .read($0, modified: Self.modificationDate(intent.url)) } ?? .failed)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(job) } }
            }
        }
    }

    private func start(_ work: (Job) -> Void) {
        let job = Job()
        self.job = job
        #if os(iOS)
        // Going to the background, the app is suspended a moment later: it stays awake until the note is written.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Saving a note")
        job.endBackgroundTask = { UIApplication.shared.endBackgroundTask(task) }
        #endif
        work(job)
    }

    /// Takes in what a save or read found, then does what was asked for meanwhile.
    private func finish(_ job: Job) {
        // Taken in already, as quitting waited for it.
        guard self.job === job else { return }
        self.job = nil
        #if os(iOS)
        job.endBackgroundTask?()
        #endif
        switch job.outcome {
        case .written(let written, let modified):
            savedText = written
            if let modified { self.modified = modified }
            onSave?()
        case .changed(let disk, let modified):
            takeIn(disk, modified: modified)
        case .read(let disk, let modified):
            takeIn(disk, modified: modified)
            checkForConflictVersions()
        case .settled(let disk):
            // The choice is made: what is on disk now is the base, and this note's text goes over it.
            savedText = disk ?? ""
            isSettling = false
            wantsSave = true
        case .failed:
            break
        }
        if let settle = settleNext {
            // What was asked for meanwhile comes after it.
            settleNext = nil
            return settle()
        }
        let (save, read) = (wantsSave || !whenSaved.isEmpty, wantsRead)
        wantsSave = false
        wantsRead = false
        if save, canSave {
            // It reads what changed elsewhere too.
            write()
        } else if read {
            readChanges()
        }
        guard self.job == nil else { return }
        let waiting = whenSaved
        whenSaved = []
        for action in waiting { action() }
    }

    /// What the file says after it changed elsewhere: taken as it is when nothing is typed here that isn't saved, merged
    /// with what is when the changes touch different lines (and the merge saved), else asked about.
    private func takeIn(_ disk: String, modified: Date?) {
        guard disk != savedText else { return }
        if let modified { self.modified = modified }
        if disk == text {
            savedText = disk
        } else if text == savedText {
            text = disk
            savedText = disk
            if !isClosed { onExternalChange?(disk) }
        } else if let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) {
            // Edits here and there touched different lines: keep both.
            savedText = disk
            text = merged
            if !isClosed { onExternalChange?(merged) }
            if merged != disk { wantsSave = true }
        } else {
            conflict = Conflict(otherText: disk, source: "another device", date: self.modified)
        }
    }

    /// Notebook moved or renamed the file itself: follow it right away instead of waiting for the coordinator to say so.
    func moved(to newURL: URL) {
        url = newURL.standardizedFileURL
        modified = Self.modificationDate(newURL)
    }

    /// Notebook is about to rename or move the file, or the folder it is in, off the main thread: what was typed is
    /// saved first, and what is typed meanwhile once it is done (`endMove`).
    func beginMove() {
        saveNow()
        moves += 1
    }

    /// The rename or move is done: the note follows the file to `newURL` (nil when it stayed where it was) and saves
    /// what was typed meanwhile there, even when it was closed in between.
    func endMove(to newURL: URL?) {
        moves = max(moves - 1, 0)
        if let newURL { moved(to: newURL) }
        if moves == 0, hasUnsavedChanges { saveNow() }
    }

    // MARK: - Conflicts

    /// Asks iCloud for versions of the file from other devices that it couldn't put together with this one. That asks
    /// another process and can take a while, so it is done off the main thread.
    private func checkForConflictVersions() {
        let url = url
        Self.readQueue.addOperation {
            guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), let other = versions.first,
                  let otherText = Self.read(other.url) else { return }
            let found = Conflict(otherText: otherText, source: other.localizedNameOfSavingComputer ?? "another device", date: other.modificationDate)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.isClosed, self.url == url, self.conflict == nil, found.otherText != self.text else { return }
                    self.conflict = found
                }
            }
        }
    }

    enum Resolution { case keepThis, takeOther, keepBoth }

    /// Settles a conflict; returns the text to show. The rest is done off the main thread: the other version written
    /// next to the note (Keep Both), iCloud told, and what is on disk then read, as the base this note's text goes over.
    /// Nothing is saved before that.
    func resolve(_ resolution: Resolution) -> String {
        guard let conflict else { return text }
        if resolution == .takeOther { text = conflict.otherText }
        self.conflict = nil
        isSettling = true
        let (url, copy) = (url, resolution == .keepBoth ? conflict : nil)
        let settle = { [self] in
            start { job in
                Self.readQueue.addOperation {
                    job.finish(Self.settle(url, keeping: copy, presenter: self))
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(job) } }
                }
            }
        }
        if job == nil { settle() } else { settleNext = settle }
        return text
    }

    nonisolated private static func settle(_ url: URL, keeping copy: Conflict?, presenter: NSFilePresenter) -> Outcome {
        if let copy {
            let name = "\(url.deletingPathExtension().lastPathComponent) (\(copy.source))"
            FileOperations.createNote(in: url.deletingLastPathComponent(), title: name, text: copy.otherText)
        }
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) {
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        var disk: String?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: .withoutChanges, error: nil) { url in
            disk = (try? Data(contentsOf: url)).flatMap(decode)
        }
        return .settled(disk)
    }

    // MARK: - NSFilePresenter

    nonisolated public var presentedItemURL: URL? {
        presentedURL.withLock { $0 }
    }

    nonisolated public var presentedItemOperationQueue: OperationQueue { .main }

    nonisolated public func presentedItemDidChange() {
        MainActor.assumeIsolated { fileChangedOnDisk() }
    }

    nonisolated public func presentedItemDidMove(to newURL: URL) {
        MainActor.assumeIsolated {
            url = newURL
            onMove?(newURL)
        }
    }

    nonisolated public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        wasDeleted.withLock { $0 = true }
        MainActor.assumeIsolated {
            saveTimer?.invalidate()
            onDelete?()
        }
        completionHandler(nil)
    }

    nonisolated public func presentedItemDidGain(_ version: NSFileVersion) {
        MainActor.assumeIsolated {
            if isLoaded { checkForConflictVersions() }
        }
    }

    /// Another app or Notebook itself is about to read or change the file: it waits until what was typed is written.
    nonisolated public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated { save { completionHandler(nil) } }
    }

    private func fileChangedOnDisk() {
        switch pending {
        case nil:
            break
        case .unreadable:
            // iCloud may have it now.
            pending = .reading
            readInBackground()
            return
        case .reading, .downloading:
            changedWhileReading = true
            return
        }
        guard job == nil else {
            wantsRead = true
            return
        }
        readChanges()
    }
}
