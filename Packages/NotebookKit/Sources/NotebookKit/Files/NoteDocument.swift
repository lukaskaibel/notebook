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
    /// Where earlier versions of the note are kept, as you write (`keepCopy`).
    @ObservationIgnored let history: NoteHistory?
    /// The text when the note was opened: File › Revert To › Last Opened.
    public private(set) var openedText: String?
    /// The text is no longer what it was when the note was opened. Set only when that changes, so the menu that asks
    /// isn't made again with every letter typed.
    public private(set) var isChangedSinceOpening = false

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
    /// Copies of the text are kept at most this often while you write: every ten minutes.
    @ObservationIgnored var copyInterval: TimeInterval = 600
    @ObservationIgnored private var lastCopy: Date?
    /// The text was changed here since the last copy: typed, or merged with a change from elsewhere.
    @ObservationIgnored private var changedSinceCopy = false
    @ObservationIgnored private var hasBeenTypedIn = false
    /// Copies asked for while the file is being renamed or moved, kept under its new name once that is done.
    @ObservationIgnored private var heldCopies: [(text: String, date: Date)] = []
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

    init(url: URL, history: NoteHistory? = .shared) {
        self.url = url
        self.history = history
        presentedURL = Mutex(url)
        let pending = Self.wait(for: url)
        let loaded = pending == nil ? Self.read(url) ?? "" : ""
        text = loaded
        savedText = loaded
        self.pending = pending
        modified = Self.modificationDate(url)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        if isLoaded {
            opened()
            checkForConflictVersions()
        } else {
            readInBackground()
        }
    }

    func close() {
        isClosed = true
        reader?.cancel()
        reader = nil
        saveNow()
        saveTimer?.invalidate()
        keepCopyOfChanges()
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
        opened()
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
        // The note as it was before you started changing it, once each time it is opened.
        if !hasBeenTypedIn {
            hasBeenTypedIn = true
            keepCopy(text)
        }
        text = newText
        changedSinceCopy = true
        noteWhetherChangedSinceOpening()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isLoaded, moves == 0, text != savedText, conflict == nil else { return }
        // Never write over a change made elsewhere since the last save: merge it in, or ask.
        if let disk = Self.read(url), disk != savedText {
            if disk == text {
                savedText = disk
                return
            }
            guard let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) else {
                conflict = Conflict(otherText: disk, source: "another device", date: Self.modificationDate(url))
                return
            }
            // Both texts, before they become one.
            keepBoth(theirs: disk)
            savedText = disk
            text = merged
            noteWhetherChangedSinceOpening()
            changedSinceCopy = true
            onExternalChange?(merged)
            guard merged != disk else { return }
        }
        let data = Data(text.utf8)
        var error: NSError?
        var written = false
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            written = FileOperations.write(data, to: url)
        }
        if written {
            savedText = text
            modified = Self.modificationDate(url)
            onSave?()
            // While you write, now and then.
            if changedSinceCopy, let lastCopy, Date().timeIntervalSince(lastCopy) >= copyInterval { keepCopy(text) }
        }
    }

    var hasUnsavedChanges: Bool { text != savedText }

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
        guard moves == 0 else { return }
        for copy in heldCopies { history?.keep(copy.text, of: url, at: copy.date) }
        heldCopies = []
        if hasUnsavedChanges { saveNow() }
    }

    // MARK: - Version history

    /// The note's text is in: one changed by another app while Notebook was closed differs from its newest copy, and
    /// is kept as it is now.
    private func opened() {
        openedText = text
        noteWhetherChangedSinceOpening()
        history?.keep(text, of: url, onlyIfChanged: true)
    }

    private func noteWhetherChangedSinceOpening() {
        let changed = openedText.map { $0 != text } ?? false
        if changed != isChangedSinceOpening { isChangedSinceOpening = changed }
    }

    /// Hands a copy of the text to the history, which writes it in the background unless the newest copy says the same.
    /// While the file is being renamed or moved, it waits to go where the file went.
    private func keepCopy(_ copy: String) {
        guard let history else { return }
        lastCopy = Date()
        if copy == text { changedSinceCopy = false }
        if moves > 0 {
            heldCopies.append((copy, Date()))
        } else {
            history.keep(copy, of: url)
        }
    }

    /// Keeps the other text, then this one, before a change from elsewhere is merged in or a conflict is settled: what
    /// you had is the newest version, and either can be brought back.
    private func keepBoth(theirs: String) {
        keepCopy(theirs)
        keepCopy(text)
    }

    /// Keeps a copy of what changed since the last one: as you stop, the note closing or the app going away.
    func keepCopyOfChanges() {
        guard isLoaded, changedSinceCopy else { return }
        keepCopy(text)
    }

    /// Keeps the text there is now, before a version is restored over it.
    func keepCopyBeforeRestoring() {
        guard isLoaded else { return }
        keepCopy(text)
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

    /// Settles a conflict; returns the text to show.
    func resolve(_ resolution: Resolution) -> String {
        guard let conflict else { return text }
        // Use Other, or Keep This, can be taken back from the versions, even after a relaunch.
        keepBoth(theirs: conflict.otherText)
        switch resolution {
        case .keepThis:
            break
        case .takeOther:
            text = conflict.otherText
            noteWhetherChangedSinceOpening()
        case .keepBoth:
            let base = url.deletingPathExtension().lastPathComponent
            let copy = FileOperations.uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) (\(conflict.source))", extension: "md")
            try? Data(conflict.otherText.utf8).write(to: copy, options: .atomic)
        }
        self.conflict = nil
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) {
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        // The choice is made: what is on disk now is the base, and this note's text goes over it.
        savedText = Self.read(url) ?? ""
        saveNow()
        return text
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

    nonisolated public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated { saveNow() }
        completionHandler(nil)
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
        guard let disk = Self.read(url), disk != savedText else { return }
        modified = Self.modificationDate(url)
        if text == savedText {
            // What you wrote here since the last copy is kept with what replaces it. A change from elsewhere alone is
            // that device's or app's to keep; another app's is kept when the note opens next (`opened`).
            if changedSinceCopy { keepBoth(theirs: disk) }
            text = disk
            noteWhetherChangedSinceOpening()
            savedText = disk
            changedSinceCopy = false
            onExternalChange?(disk)
        } else if let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) {
            // Edits here and there touched different lines: keep both.
            keepBoth(theirs: disk)
            savedText = disk
            text = merged
            noteWhetherChangedSinceOpening()
            changedSinceCopy = true
            onExternalChange?(merged)
            if merged != disk { saveNow() }
        } else {
            conflict = Conflict(otherText: disk, source: "another device", date: modified)
        }
        checkForConflictVersions()
    }
}
