#if os(macOS)
import AppKit
import SystemConfiguration
#else
import UIKit
#endif
import Synchronization

/// An open note: its text, saved shortly after you stop typing, and kept in step with the file when something else
/// (iCloud, another app, the same note in another window) changes it. A note that is on this device in full is read at
/// once; one still in iCloud is read in the background, and until its text is in, nothing is taken in or saved, so
/// nothing is written over.
///
/// Saving, reading the file again after a change made elsewhere and settling a conflict happen off the main thread, one
/// at a time, so the window never waits for the disk or for iCloud. A note left while it is still writing is kept until
/// it is done, and quitting, the Trash, renames and moves wait for it.
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
    /// Called after the text was written to the file, also once the note was left.
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
    @ObservationIgnored private(set) var isClosed = false
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
    /// A save, a read of what changed elsewhere, or a conflict being settled, under way off the main thread. One at a
    /// time: what is asked for meanwhile (`wantsSave`, `wantsRead`, `settling`) comes after it, and so does whatever
    /// waits for the note to be written (`whenIdle`).
    @ObservationIgnored private var isWorking = false
    @ObservationIgnored private var wantsSave = false
    @ObservationIgnored private var wantsRead = false
    @ObservationIgnored private var wantsDeletionCheck = false
    @ObservationIgnored private var settling: Settling?
    @ObservationIgnored private var whenIdle: [() -> Void] = []
    /// The file was deleted or put in the Trash, or is about to be replaced and it isn't known yet which: nothing is
    /// written there. Read off the main thread, where it is written.
    @ObservationIgnored private let isDeleted = Mutex(false)
    /// Where the file was when it was said to be deleted: what `checkDeletion` looks at.
    @ObservationIgnored private var noticedAt: URL?
    /// Where the file was before it went (into the Trash, say), for a copy kept after that.
    @ObservationIgnored private var deletedFrom: URL?
    @ObservationIgnored private var isPresenting = true
    /// Where notes are read and written. The coordinated reads and writes wait for iCloud without holding a thread.
    private nonisolated static let fileQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Notebook notes"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public enum Pending: Equatable, Sendable {
        /// Being read in the background (the debug delay, after it couldn't be read, or while it is being written).
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
        // A note on this device is read at once, unless a note open on it, or just left, is writing it: that read would
        // wait for the write.
        let pending = Self.isBeingWritten(url) ? .reading : Self.wait(for: url)
        let loaded = pending == nil ? Self.read(url) ?? "" : ""
        text = loaded
        savedText = loaded
        self.pending = pending
        modified = Self.modificationDate(url)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        Self.all.add(self)
        if isLoaded {
            opened()
            checkForConflictVersions()
        } else {
            readInBackground()
        }
    }

    /// The note is left: what was typed is saved, and the note is kept until it is written. A conflict no one can be
    /// asked about any more keeps both (`keepBoth`).
    func close() {
        guard !isClosed else { return }
        // What was typed is kept as a version as you stop.
        keepCopyOfChanges()
        isClosed = true
        reader?.cancel()
        reader = nil
        saveTimer?.invalidate()
        saveTimer = nil
        if conflict != nil {
            conflict = nil
            // With nothing typed here, the other version stays in iCloud and is asked about next time.
            if hasUnsavedChanges { keepBoth() }
        }
        wantsSave = true
        next()
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
        coordinator.coordinate(with: [intent], queue: Self.fileQueue) { error in
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
        guard isLoaded, !isClosed, newText != text else { return }
        // The note as it was before you started changing it, once each time it is opened.
        if !hasBeenTypedIn {
            hasBeenTypedIn = true
            keepCopy(text)
        }
        text = newText
        changedSinceCopy = true
        noteWhetherChangedSinceOpening()
        // Held during a move, it is written once the move is done, and quitting waits for that.
        if moves > 0 { updateWriting() }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// Saves what was typed, off the main thread, after whatever is under way there.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        // Whether there is anything to save is known once what is being written is: typed back to what was saved
        // before, the text differs from what is being written.
        guard isWorking || canSave else { return }
        wantsSave = true
        next()
    }

    var hasUnsavedChanges: Bool { text != savedText }

    private var canSave: Bool {
        isLoaded && moves == 0 && conflict == nil && text != savedText && !isDeleted.withLock { $0 }
    }

    /// Waits until what the note is writing, and whatever was asked for meanwhile, is done: written, or held for now (a
    /// conflict to settle, a move under way).
    func saved() async {
        guard isWorking else { return }
        await withCheckedContinuation { continuation in whenIdle.append { continuation.resume() } }
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
        if moves == 0 {
            for copy in heldCopies { history?.keep(copy.text, of: url, at: copy.date) }
            heldCopies = []
        }
        if moves == 0, hasUnsavedChanges { saveNow() }
        updateWriting()
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
    private func keepVersions(theirs: String) {
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

    // MARK: - Off the main thread

    private enum Outcome: Sendable {
        /// This text was written.
        case written(String, modified: Date?)
        /// It changed elsewhere since it was last read here, to this, and wasn't written over.
        case changed(String, modified: Date?)
        /// What it says, read after it changed elsewhere.
        case read(String, modified: Date?)
        /// It is still where it was when it was said to be deleted (at `at`): replaced, and says this now (nil when it
        /// can't be read).
        case replaced(String?, modified: Date?, at: URL)
        /// It was deleted from here, or put in the Trash.
        case deleted(from: URL)
        /// It is there but can't be read, so it isn't written over.
        case unreadable
        /// A conflict was settled: what it says now, the base this note's text goes over.
        case settled(String)
        /// What was typed here went into a copy next to the note, which says this.
        case keptBoth(String)
        case failed
    }

    private enum Settling: Sendable {
        /// Chosen in the alert: the other version kept as a copy next to the note (Keep Both) or not, iCloud's other
        /// versions let go of.
        case resolved(copying: Conflict?)
        /// No one left to ask: this text goes into a copy named after this device, and the note stays as it is.
        case keepingBoth(String, device: String)
    }

    /// Starts what was asked for, unless something is under way: then it comes after that.
    private func next() {
        guard !isWorking else { return }
        if wantsDeletionCheck {
            wantsDeletionCheck = false
            return checkDeletion()
        }
        if let settling {
            self.settling = nil
            return settle(settling)
        }
        if wantsSave, canSave {
            // It reads what changed elsewhere too.
            wantsSave = false
            wantsRead = false
            return save()
        }
        wantsSave = false
        // A note left reads nothing more: what it still has to write is checked against the file as it is written.
        if wantsRead, isLoaded, !isClosed {
            wantsRead = false
            return readChanges()
        }
        wantsRead = false
        let waiting = whenIdle
        whenIdle = []
        updateWriting()
        for action in waiting { action() }
    }

    /// Runs `body` off the main thread, which hands over what it found: that is taken in on the main thread, and what
    /// was asked for meanwhile started.
    private func work(_ body: (@escaping @Sendable (Outcome) -> Void) -> Void) {
        isWorking = true
        updateWriting()
        body { outcome in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(outcome) } }
        }
    }

    private func finish(_ outcome: Outcome) {
        isWorking = false
        switch outcome {
        case .written(let written, let modified):
            savedText = written
            if let modified { self.modified = modified }
            onSave?()
            // While you write, now and then: the text as it was written.
            if changedSinceCopy, let lastCopy, Date().timeIntervalSince(lastCopy) >= copyInterval { keepCopy(written) }
        case .changed(let disk, let modified):
            takeIn(disk, modified: modified)
        case .read(let disk, let modified):
            takeIn(disk, modified: modified)
            if !isClosed { checkForConflictVersions() }
        case .replaced(_, _, let original) where !Self.sameFile(url, original):
            // Moved away as it went, as into the Trash.
            deletedFrom = original
            if !isClosed { onDelete?() }
        case .replaced(let disk, let modified, _):
            isDeleted.withLock { $0 = false }
            if let disk, isLoaded { takeIn(disk, modified: modified) }
            // What was typed here meanwhile, held until it was known, is written now.
            if hasUnsavedChanges { wantsSave = true }
        case .deleted(let original):
            deletedFrom = original
            if !isClosed { onDelete?() }
        case .unreadable:
            // Kept until the file can be read again, or as a copy once no one can wait for that.
            if isClosed { keepBoth() }
        case .settled(let disk):
            // The choice is made: what is on disk now is the base, and this note's text goes over it.
            savedText = disk
            wantsSave = true
        case .keptBoth(let disk):
            text = disk
            savedText = disk
            noteWhetherChangedSinceOpening()
        case .failed:
            break
        }
        next()
    }

    /// Writes what was typed in a coordinated write, which waits for iCloud or another app holding the file without the
    /// window waiting. The text being saved is kept as it is until it is written; what is typed meanwhile is saved after
    /// it. The file is read in the same go: changed elsewhere since it was last read here, it isn't written over, and
    /// what it says is taken in first (`takeIn`).
    ///
    /// Neither asks anything of another note open on the file, which is told things on the main thread: the read doesn't
    /// ask it to save first (`.withoutChanges`), and a plain write, unlike one `.forReplacing`, is no deletion to it. So
    /// nothing here waits for the main thread. The read makes iCloud bring down a newer version first.
    private func save() {
        let (base, mine) = (savedText, text)
        let read = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        let write = NSFileAccessIntent.writingIntent(with: url, options: [])
        work { finish in
            NSFileCoordinator(filePresenter: self).coordinate(with: [read, write], queue: Self.fileQueue) { error in
                finish(error == nil ? self.write(mine, over: base, at: write.url) : .failed)
            }
        }
    }

    nonisolated private func write(_ mine: String, over base: String, at url: URL) -> Outcome {
        FileOperations.debugWait("saved", url)
        guard !isDeleted.withLock({ $0 }) else { return .failed }
        // Never written over a change made elsewhere, nor over what can't be read to see. (Gone without a word, it is
        // written again.)
        if let disk = (try? Data(contentsOf: url)).flatMap(Self.decode) {
            if disk != base { return .changed(disk, modified: Self.modificationDate(url)) }
        } else if FileManager.default.fileExists(atPath: url.path) {
            return .unreadable
        }
        guard FileOperations.write(Data(mine.utf8), to: url) else { return .failed }
        return .written(mine, modified: Self.modificationDate(url))
    }

    /// Reads the file after it changed elsewhere, without asking another note open on it to save first: it has changed
    /// already.
    private func readChanges() {
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        work { finish in
            NSFileCoordinator(filePresenter: self).coordinate(with: [intent], queue: Self.fileQueue) { error in
                let disk = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(Self.decode) : nil
                finish(disk.map { .read($0, modified: Self.modificationDate(intent.url)) } ?? .failed)
            }
        }
    }

    /// Finds out whether the file went or was replaced (a `.forReplacing` write is a deletion to everyone else), once
    /// the writer that said so is done: with a coordinator of its own, which waits for that writer, where this note's
    /// own would be let through before it. It looks where the file was when the notice came, not where the coordinator
    /// followed it: put in the Trash, a file is moved there and found, but it went all the same.
    private func checkDeletion() {
        let original = noticedAt ?? url
        noticedAt = nil
        let intent = NSFileAccessIntent.readingIntent(with: original, options: .withoutChanges)
        work { finish in
            // Even when the coordinator fails, the file itself says whether it is still there.
            NSFileCoordinator().coordinate(with: [intent], queue: Self.fileQueue) { _ in
                guard FileManager.default.fileExists(atPath: original.path) else { return finish(.deleted(from: original)) }
                let disk = (try? Data(contentsOf: original)).flatMap(Self.decode)
                finish(.replaced(disk, modified: Self.modificationDate(original), at: original))
            }
        }
    }

    /// Where a change made elsewhere meets what was typed here. Taken as it is when nothing typed here is unsaved,
    /// merged when the two touched different lines (and the merge saved), else asked about, or, with no one left to ask,
    /// both kept (`keepBoth`).
    private func takeIn(_ disk: String, modified: Date?) {
        guard disk != savedText else { return }
        if let modified { self.modified = modified }
        if disk == text {
            savedText = disk
        } else if text == savedText {
            // What you wrote here since the last copy is kept with what replaces it. A change from elsewhere alone is
            // that device's or app's to keep; another app's is kept when the note opens next (`opened`).
            if changedSinceCopy { keepVersions(theirs: disk) }
            text = disk
            savedText = disk
            changedSinceCopy = false
            noteWhetherChangedSinceOpening()
            if !isClosed { onExternalChange?(disk) }
        } else if let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) {
            // Edits here and there touched different lines: keep both, and the two texts as versions first.
            keepVersions(theirs: disk)
            savedText = disk
            text = merged
            changedSinceCopy = true
            noteWhetherChangedSinceOpening()
            if !isClosed { onExternalChange?(merged) }
            if merged != disk { wantsSave = true }
        } else if isClosed {
            keepBoth()
        } else {
            conflict = Conflict(otherText: disk, source: "another device", date: self.modified)
        }
    }

    /// A conflict met once the note was left (or as the app quits), when no one can be asked: what was typed here is
    /// written as a copy next to the note, named after this device, the way Keep Both keeps the other version, and the
    /// note stays as it is on disk.
    private func keepBoth() {
        settling = .keepingBoth(text, device: Self.deviceName)
    }

    /// Settles a conflict off the main thread: the copy written next to the note, iCloud told, and what is on disk then
    /// read. Nothing is saved before that.
    private func settle(_ settling: Settling) {
        let url = url
        // Where it was, when it was said to be deleted before now: a copy goes there, not after the file into the Trash.
        let origin = deletedFrom ?? noticedAt
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        work { finish in
            if case .resolved(let copying) = settling {
                Self.fileQueue.addOperation {
                    if let copying { Self.writeCopy(of: url, from: copying.source, text: copying.otherText) }
                    if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) {
                        for version in versions { version.isResolved = true }
                        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
                    }
                    NSFileCoordinator(filePresenter: self).coordinate(with: [intent], queue: Self.fileQueue) { error in
                        let disk = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(Self.decode) : nil
                        finish(.settled(disk ?? ""))
                    }
                }
            } else if case .keepingBoth(let mine, let device) = settling {
                NSFileCoordinator(filePresenter: self).coordinate(with: [intent], queue: Self.fileQueue) { error in
                    let disk = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(Self.decode) : nil
                    // Next to where the note is now, or, said to be deleted (and maybe moved into the Trash), where it was.
                    let note = origin ?? (self.isDeleted.withLock { $0 } ? url : intent.url)
                    // Written once the note is let go of.
                    Self.fileQueue.addOperation {
                        guard disk != mine else { return finish(.keptBoth(mine)) }
                        let kept = Self.writeCopy(of: note, from: device, text: mine)
                        finish(kept ? .keptBoth(disk ?? mine) : .failed)
                    }
                }
            }
        }
    }

    /// A copy of a note next to it, named after where its text comes from: "Groceries (Lukas’s iPhone)". Two made at
    /// once (the note open in two windows, left as the app quits) take a name each. Not written when the folder is gone.
    @discardableResult
    nonisolated private static func writeCopy(of url: URL, from source: String, text: String) -> Bool {
        let name = "\(url.deletingPathExtension().lastPathComponent) (\(source))"
        return FileOperations.createNoteWithoutOverwriting(in: url.deletingLastPathComponent(), title: name, text: text) != nil
    }

    /// This Mac's or device's name, as the Finder and the Files app say it.
    private static var deviceName: String {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
        #else
        UIDevice.current.name
        #endif
    }

    // MARK: - Conflicts

    /// Asks iCloud for versions of the file from other devices that it couldn't put together with this one. That asks
    /// another process and can take a while, so it is done off the main thread.
    private func checkForConflictVersions() {
        let url = url
        Self.fileQueue.addOperation {
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

    /// Settles a conflict; returns the text to show. The rest is done off the main thread (`settle`), and then this
    /// note's text is saved over what is on disk.
    func resolve(_ resolution: Resolution) -> String {
        guard let conflict else { return text }
        // Use the Other, or Keep This, can be taken back from the versions, even after a relaunch.
        keepVersions(theirs: conflict.otherText)
        if resolution == .takeOther {
            text = conflict.otherText
            noteWhetherChangedSinceOpening()
        }
        self.conflict = nil
        settling = .resolved(copying: resolution == .keepBoth ? conflict : nil)
        next()
        return text
    }

    // MARK: - Notes being written

    /// Every note open now, and those left that are still writing: renames, moves and the Trash look for them here.
    private static let all = NSHashTable<NoteDocument>.weakObjects()
    /// The notes with something to write, left ones too, which are kept here until it is written.
    private static var writing: [NoteDocument] = []
    private static var whenNothingWriting: [() -> Void] = []
    #if os(iOS)
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    /// Whether a note, open or left, still has something to write: quitting waits for it.
    static var isWriting: Bool { !writing.isEmpty }

    /// Calls `then` once no note has anything left to write.
    static func whenAllWritten(_ then: @escaping () -> Void) {
        if writing.isEmpty { then() } else { whenNothingWriting.append(then) }
    }

    static func allWritten() async {
        await withCheckedContinuation { continuation in whenAllWritten { continuation.resume() } }
    }

    /// The notes open on `url` or in it (a folder), and those left there that are still writing.
    static func documents(atOrInside url: URL) -> [NoteDocument] {
        all.allObjects.filter { (!$0.isClosed || writing.contains($0)) && FileNode.isSameOrInside($0.url, url) }
    }

    /// What was typed in the notes at `url` or in it is written: before it goes to the Trash, so it goes along.
    static func save(atOrInside url: URL) async {
        let documents = documents(atOrInside: url)
        for document in documents { document.saveNow() }
        for document in documents { await document.saved() }
    }

    /// Notebook is about to rename or move `url`, a note or a folder, off the main thread: the notes on it or in it save
    /// what was typed and hold what is typed meanwhile (`beginMove`). Returns them once that is written, where they are
    /// still, for `endMoving`.
    static func beginMoving(_ url: URL) async -> [NoteDocument] {
        let documents = documents(atOrInside: url)
        for document in documents { document.beginMove() }
        for document in documents { await document.saved() }
        return documents
    }

    /// The rename or move of `url` is done, to `new` (nil when it couldn't be): each note follows its file there and
    /// saves what was typed meanwhile.
    static func endMoving(_ documents: [NoteDocument], from url: URL, to new: URL?) {
        for document in documents {
            document.endMove(to: new.map { Workspace.relocated(document.url, from: url, to: $0) })
        }
    }

    /// The same file by path, as the Mac's disks take it: "groceries.md" and "Groceries.md" are one file.
    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        HiddenFolders.withoutPrivate(a.standardizedFileURL.path).compare(HiddenFolders.withoutPrivate(b.standardizedFileURL.path), options: .caseInsensitive) == .orderedSame
    }

    private static func isBeingWritten(_ url: URL) -> Bool {
        writing.contains { FileNode.samePath($0.url, url) }
    }

    /// Keeps the note among those quitting waits for while it is writing, or holds what was typed during a move. A note
    /// left stops hearing about its file once it is done.
    private func updateWriting() {
        if isWorking || (moves > 0 && hasUnsavedChanges) {
            guard !Self.writing.contains(self) else { return }
            Self.writing.append(self)
            #if os(iOS)
            // Going to the background, the app is suspended a moment later: it stays awake until the notes are written.
            if Self.backgroundTask == .invalid {
                Self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Saving notes") {
                    MainActor.assumeIsolated { Self.endBackgroundTask() }
                }
            }
            #endif
        } else {
            if isClosed, isPresenting {
                isPresenting = false
                NSFileCoordinator.removeFilePresenter(self)
            }
            guard let index = Self.writing.firstIndex(of: self) else { return }
            Self.writing.remove(at: index)
            guard Self.writing.isEmpty else { return }
            #if os(iOS)
            Self.endBackgroundTask()
            #endif
            let waiting = Self.whenNothingWriting
            Self.whenNothingWriting = []
            for action in waiting { action() }
        }
    }

    #if os(iOS)
    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

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
            if !isClosed { onMove?(newURL) }
        }
    }

    /// The file is about to be deleted, or replaced by another version of it: nothing is written until the writer is
    /// done and it is known which (`checkDeletion`).
    nonisolated public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        isDeleted.withLock { $0 = true }
        completionHandler(nil)
        MainActor.assumeIsolated {
            saveTimer?.invalidate()
            if noticedAt == nil { noticedAt = url }
            wantsDeletionCheck = true
            next()
        }
    }

    nonisolated public func presentedItemDidGain(_ version: NSFileVersion) {
        MainActor.assumeIsolated {
            if isLoaded, !isClosed { checkForConflictVersions() }
        }
    }

    /// Another app, or Notebook itself, is about to read or change the file: it waits until what was typed is written.
    /// (The coordinator lets this note's own write through meanwhile.)
    nonisolated public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            saveNow()
            if isWorking { whenIdle.append { completionHandler(nil) } } else { completionHandler(nil) }
        }
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
        wantsRead = true
        next()
    }
}
