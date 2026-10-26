#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CryptoKit
import Synchronization

/// Earlier versions of notes: plain copies of a note's Markdown, taken now and then as you write (`NoteDocument`),
/// kept for a year and thinned the way Time Machine thins its backups.
///
/// The copies of a note in iCloud go into Notebook's own iCloud folder, outside its `Documents`, so iCloud takes them to
/// your other devices without a Notebook folder showing in iCloud Drive. They go by the note's path from
/// `Mobile Documents` on, which is the same on a Mac, an iPhone and an iPad:
/// `History/com~apple~CloudDocs/Recipes/Weekend.md/2026-10-24 at 15.32.10 +0200 (iPhone).md`. The copies of every
/// other note, and of every note in builds without iCloud (Debug and Release), go into the same layout in Application
/// Support, on this device only. Each copy is a file of its own with a name of its own, so two devices never conflict
/// over them, and any app can open one.
///
/// A note's copies are in a folder named after its file, extension and all: a note and a folder of the same name
/// ("Recipes.md" and "Recipes") keep theirs apart, and a folder's own folder there holds the copies of the notes in it,
/// so renaming or moving a folder takes them all along in one step (`follow`). Next to them, `.Trash` holds the copies of
/// notes thrown away for a year (`trash`), and `.Leftovers` in iCloud those a note left there (`transfer`).
///
/// Everything happens on one background queue, one thing after another, in the order asked for. The main thread only
/// hands over the text.
final class NoteHistory: @unchecked Sendable {
    /// Where the copies of notes in iCloud go.
    enum Cloud: Sendable {
        /// Nowhere in iCloud: every copy stays on this device.
        case none
        /// The `History` folder in Notebook's iCloud folder, the first container in the app's entitlements, looked up
        /// the first time it is needed. Without the entitlement (Debug, Release) or without iCloud there is none.
        case container
        /// A folder standing in for it, for tests.
        case folder(URL)
    }

    /// A copy of a note, as its file's name tells it: when it was taken, and on what.
    struct Version: Hashable, Sendable, Identifiable {
        /// The copy, by its own name, also when iCloud hasn't brought it down yet.
        var url: URL
        var date: Date
        /// "Mac", "iPhone" or "iPad".
        var device: String
        /// Which Mac, iPhone or iPad, as its name says it: a few letters each device has.
        var deviceID: String?
        /// On this device, or still in iCloud only: reading it waits for it to come down.
        var isDownloaded = true
        var id: URL { url }
    }

    static let shared: NoteHistory = {
        // Tests never write into the app's own history.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return NoteHistory(local: FileManager.default.temporaryDirectory.appendingPathComponent("Notebook history \(UUID().uuidString)", isDirectory: true))
        }
        return NoteHistory(local: defaultLocalFolder, cloud: .container)
    }()

    /// The copies of notes outside iCloud, in Application Support. Spotlight reads Application Support, and would show
    /// every old copy among the notes: it leaves out a folder whose name ends in `.noindex`.
    static var defaultLocalFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notebook", isDirectory: true)
            .appendingPathComponent("History.noindex", isDirectory: true)
    }

    /// How long a copy is kept.
    static let keptFor = DateComponents(year: 1)

    /// What thinning counts hours, days and weeks in: the same on every device, whatever its time zone and the day its
    /// weeks start, as every device thins the copies they share. In its own, a Mac on UTC and an iPhone on UTC+2 would
    /// together keep no copy of some days.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Everything happens here, one after another.
    private let queue = DispatchQueue(label: "Notebook history", qos: .utility)
    /// Where versions are read: a coordinated read waits there for iCloud to bring one down without holding a thread.
    private static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Notebook history reads"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // Only touched on `queue`.
    private var local: URL
    private var cloud: Cloud
    /// The History folder in iCloud once looked up, or nil for none.
    private var cloudFolder: URL??
    private let iCloudDrive: String
    /// The newest copy written of each note, by its folder, and a digest of its text: a copy the same as it isn't
    /// written again, without reading it back.
    private var newest: [String: (name: String, digest: SHA256.Digest)] = [:]

    init(local: URL, cloud: Cloud = .none, iCloudDrive: String = Location.iCloudDrivePath) {
        self.local = local.standardizedFileURL
        self.cloud = cloud
        self.iCloudDrive = HiddenFolders.withoutPrivate(iCloudDrive)
        // Signing out of iCloud or into another account: iCloud's folder is looked up again.
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.cloudFolder = nil }
        }
    }

    /// Keeps every copy on this device from now on, in `folder`: for a library given on the command line (tests, the
    /// sample notes), whose copies have no business in iCloud or among those of your own notes.
    func keepOnDevice(in folder: URL) {
        queue.async { [self] in
            local = folder.standardizedFileURL
            cloud = .none
            cloudFolder = nil
            newest = [:]
        }
    }

    // MARK: - Keeping copies

    /// Keeps a copy of a note's text, unless it is the same as the newest copy there is. Written in the background.
    /// `onlyIfChanged`: only when the note has copies, and the newest one, on this device, says something else. A note
    /// opening checks with it that no other app changed it meanwhile. `device` is what the copy's name says it was taken
    /// on: this device unless said otherwise (the sample notes').
    @MainActor
    func keep(_ text: String, of note: URL, at date: Date = Date(), device: String? = nil, onlyIfChanged: Bool = false) {
        let device = device ?? Self.thisDevice
        let note = note.standardizedFileURL
        queue.async { [self] in write(text, of: note, at: date, device: device, onlyIfChanged: onlyIfChanged) }
    }

    /// What this device is called in the names of its copies: "Mac 3f9a2c". The letters tell two Macs apart, so two
    /// never write a copy of the same name, and they say which copies are this device's to thin.
    @MainActor
    static var thisDevice: String {
        #if os(macOS)
        let name = "Mac " + deviceID
        #else
        let name = (UIDevice.current.userInterfaceIdiom == .pad ? "iPad " : "iPhone ") + deviceID
        #endif
        known.withLock { $0 = name }
        return name
    }

    /// This device's name, for what the history does by itself (`setAside`), away from the main thread: known once it
    /// was asked for there, as the app does when it starts.
    private static let known = Mutex<String?>(nil)

    /// Made from the identifier iPhone and iPad give the app on each device, which a backup brings along to no other
    /// device; on a Mac, picked at random the first time and kept. It says nothing about the device.
    @MainActor
    static var deviceID: String {
        #if os(iOS)
        if let vendor = UIDevice.current.identifierForVendor {
            return SHA256.hash(data: Data(vendor.uuidString.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        }
        #endif
        let key = "historyDeviceID"
        if let id = UserDefaults.standard.string(forKey: key), id.count == 6 { return id }
        let id = String(format: "%06x", UInt32.random(in: 0..<0x1000000))
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Waits until everything asked for so far is written, at most `timeout`: as the app quits.
    @discardableResult
    func waitUntilWritten(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Everything asked for so far is done, for tests.
    func written() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func write(_ text: String, of note: URL, at date: Date, device: String, onlyIfChanged: Bool) {
        // An empty note has nothing to bring back: a new one, before you typed.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let folder = folders(for: note).write
        let digest = SHA256.hash(data: Data(text.utf8))
        if onlyIfChanged, Self.copies(in: folder).isEmpty { bringBack(note, saying: digest, to: folder) }
        var copies = Self.copies(in: folder)
        let latest = copies.max { $0.date < $1.date }
        if onlyIfChanged, latest.map({ !Self.isDownloaded($0.url) }) ?? true { return }
        if let latest, isSame(latest, in: folder, as: text, digest: digest) { return }
        // Two copies in one second (both sides of a merge): the second gets the next second, so they stay in order.
        var when = date
        var name = Self.name(for: when, device: device)
        while copies.contains(where: { $0.url.lastPathComponent == name }) {
            when += 1
            name = Self.name(for: when, device: device)
        }
        let url = folder.appendingPathComponent(name)
        var written = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            written = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }
        guard written else { return }
        newest[folder.path] = (name, digest)
        if let made = Self.version(named: name, in: folder) { copies.append(made) }
        // Each device thins the copies it took itself: one whose clock is set wrong can't take away the others'. Its
        // time is the copy's, when that is later.
        thin(copies.filter { Self.isTaken($0, by: device) }, now: max(when, Date()))
    }

    /// A copy's device as its name says it: "iPhone 3f9a2c", or "iPhone" in a name without letters.
    static func label(of copy: Version) -> String {
        copy.deviceID.map { "\(copy.device) \($0)" } ?? copy.device
    }

    /// Whether a copy's name says it was taken on `device` ("Mac 3f9a2c").
    static func isTaken(_ copy: Version, by device: String) -> Bool {
        realName(of: copy.url.lastPathComponent).hasSuffix(" (\(device)).md")
    }

    /// Whether the newest copy says the same: known from writing it, or read when it is on this device. One iCloud
    /// hasn't brought down yet would have to come first, and a copy too many costs less than waiting for it.
    private func isSame(_ copy: Version, in folder: URL, as text: String, digest: SHA256.Digest) -> Bool {
        if let known = newest[folder.path], known.name == copy.url.lastPathComponent { return known.digest == digest }
        guard Self.isDownloaded(copy.url), let data = try? Data(contentsOf: copy.url) else { return false }
        let found = SHA256.hash(data: data)
        newest[folder.path] = (copy.url.lastPathComponent, found)
        return found == digest
    }

    nonisolated static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
        return values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
    }

    // MARK: - Thinning

    /// Thins a note's copies, right after one was added: every copy from the last hour, then the newest of each hour for
    /// a day, of each day for a month and of each week for a year. Older ones go, but never the newest, unless
    /// `keepsNewest` is false. They are removed outright, not moved to the Trash: they are Notebook's, not yours.
    /// Says how many went.
    @discardableResult
    private func thin(_ copies: [Version], now: Date, keepsNewest: Bool = true) -> Int {
        let removed = Self.thinning(copies.map(\.date), now: now, keepsNewest: keepsNewest)
        for index in removed { Self.remove(copies[index].url) }
        return removed.count
    }

    /// Which copies thinning removes, by their dates: their indices. The newest of each hour, day or week stays, so a
    /// copy kept at one step is the one kept at the next, and nothing thinned away comes back. The newest of all stays
    /// too (`keepsNewest`): a clock set years ahead would find every copy a year old.
    static func thinning(_ dates: [Date], now: Date, calendar: Calendar = NoteHistory.calendar, keepsNewest: Bool = true) -> [Int] {
        guard let month = calendar.date(byAdding: .month, value: -1, to: now),
              let year = calendar.date(byAdding: keptFor.negated, to: now) else { return [] }
        let hour = now.addingTimeInterval(-3600)
        let day = now.addingTimeInterval(-86400)
        struct Bucket: Hashable {
            var unit: Calendar.Component
            var start: Date
        }
        var seen = Set<Bucket>()
        var removed: [Int] = []
        let sorted = dates.indices.sorted(by: { dates[$0] > dates[$1] })
        for (position, index) in sorted.enumerated() {
            let date = dates[index]
            let stays = keepsNewest && position == 0
            let unit: Calendar.Component
            if date >= hour {
                continue
            } else if date >= day {
                unit = .hour
            } else if date >= month {
                unit = .day
            } else if date >= year {
                unit = .weekOfYear
            } else {
                if !stays { removed.append(index) }
                continue
            }
            let start = calendar.dateInterval(of: unit, for: date)?.start ?? date
            if !seen.insert(Bucket(unit: unit, start: start)).inserted, !stays { removed.append(index) }
        }
        return removed
    }

    /// Thins the copies of every note, also of those not written in for a long time and of those thrown away: what is a
    /// year old goes. In the background, at most once a day; a day written down by a clock set ahead doesn't hold it up.
    /// `device` is this device's name in copies, `now` what its clock says.
    @MainActor
    func tidyUp(defaults: UserDefaults = .standard, device: String? = nil, now: Date = Date()) {
        let key = "historyTidiedUp"
        if let last = defaults.object(forKey: key) as? Date, last <= now, now.timeIntervalSince(last) < 86400 { return }
        defaults.set(now, forKey: key)
        let device = device ?? Self.thisDevice
        queue.async { [self] in
            for root in roots() { tidyUp(root, now: now, device: device) }
        }
    }

    /// Thins each note's copies under a folder and takes away the folders left empty. True when it is empty itself.
    /// - This device's copies are thinned as when it writes them.
    /// - Another device's go when they are a year older than its newest copy of the note. That device thins the rest
    ///   itself, and this device's clock has no say: set years ahead, it would find them all a year old. A device not
    ///   used any more, or set up again, leaves a year of copies of each note, thinned when it wrote them last.
    /// - The History's own Trash is emptied of what went there a year ago (`emptyTrash`).
    @discardableResult
    private func tidyUp(_ folder: URL, now: Date, device: String) -> Bool {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        let isRoot = roots().contains { $0.path == folder.path }
        var copies: [Version] = []
        var left = names.count
        for name in names {
            let url = folder.appendingPathComponent(name)
            if let copy = Self.version(named: name, in: folder) {
                copies.append(copy)
            } else if name == Self.leftoversName {
                // What stayed in iCloud and has gone since isn't looked for any more.
                if !keepLeftovers(listedIn: folder) { left -= 1 }
            } else if isRoot, name == Self.trashName {
                if emptyTrash(url, now: now, device: device) {
                    try? manager.removeItem(at: url)
                    left -= 1
                }
            } else if Self.isFolder(url), tidyUp(url, now: now, device: device) {
                try? manager.removeItem(at: url)
                left -= 1
            }
        }
        guard !copies.isEmpty else { return left == 0 }
        var removed = thin(copies.filter { Self.isTaken($0, by: device) }, now: now)
        let others = Dictionary(grouping: copies.filter { !Self.isTaken($0, by: device) }) { Self.label(of: $0) }
        for theirs in others.values {
            guard let newest = theirs.map(\.date).max(),
                  let year = Self.calendar.date(byAdding: Self.keptFor.negated, to: newest) else { continue }
            for copy in theirs where copy.date < year {
                Self.remove(copy.url)
                removed += 1
            }
        }
        return left - removed == 0
    }

    /// Empties the History's Trash of what went there a year ago, all of a note's copies at once: what this device threw
    /// away by its own clock, what another did by the newest it threw away, so a clock here set ahead can't take that.
    /// Everything on this device is its own. True when the Trash is empty.
    private func emptyTrash(_ trash: URL, now: Date, device: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        let entries = names.compactMap { name in Self.trashed(name).map { (name: name, date: $0.date, device: $0.device ?? "") } }
        let isOwn = trash.deletingLastPathComponent().path == local.path
        let newest = Dictionary(grouping: entries, by: \.device).mapValues { $0.map(\.date).max() ?? now }
        var left = names.count
        for entry in entries {
            let since = isOwn || entry.device == device ? now : newest[entry.device] ?? now
            guard let year = Self.calendar.date(byAdding: Self.keptFor.negated, to: since), entry.date < year else { continue }
            Self.remove(trash.appendingPathComponent(entry.name))
            left -= 1
        }
        return left == 0
    }

    /// The History folders there are: in iCloud and on this device.
    private func roots() -> [URL] {
        [cloudRoot(), local].compactMap { $0 }
    }

    // MARK: - Following notes

    /// A note or folder Notebook renamed or moved: its copies go along, to the right store for where it went. Copies
    /// already there are another note's, gone without Notebook, and go to the Trash first (`setAside`): never in with
    /// these.
    func follow(from old: URL, to new: URL) {
        let old = old.standardizedFileURL
        let new = new.standardizedFileURL
        queue.async { [self] in
            let sources = folders(for: old).all.filter { FileManager.default.fileExists(atPath: $0.path) }
            setAside(new, keeping: sources)
            let target = folders(for: new).write
            for source in sources where source.path != target.path {
                carry(source, to: target)
                removeEmptyFolders(from: source.deletingLastPathComponent())
            }
            newest = [:]
        }
    }

    /// A note or folder Notebook made (a new note, a copy): copies at its place are of another note, gone without
    /// Notebook, thrown away in the Finder or on a device without it. They go to the Trash, and it starts without them.
    func made(_ url: URL) {
        let url = url.standardizedFileURL
        queue.async { [self] in setAside(url) }
    }

    /// Where the copies of notes thrown away wait, for a year: `.Trash/<name> <place>` in the store they are in.
    static let trashName = ".Trash"

    /// A name for the copies of a note going to the Trash, under which Undo or Put Back brings them back: when, and on
    /// what, which says whose they are to empty (`emptyTrash`). "1793012345 1A2B3C4D (Mac 3f9a2c)"
    @MainActor
    static func trashedName() -> String {
        trashedName(device: thisDevice)
    }

    static func trashedName(device: String?) -> String {
        "\(Int(Date().timeIntervalSince1970)) \(UUID().uuidString.prefix(8))" + (device.map { " (\($0))" } ?? "")
    }

    private static let trashedPattern = try? NSRegularExpression(pattern: #"^(\d+) [0-9A-Fa-f]{8}(?: \((.+)\))?(?: [0-9a-f]{8})?$"#)

    /// When copies went to the Trash and on what, from their folder's name there.
    static func trashed(_ name: String) -> (date: Date, device: String?)? {
        guard let match = trashedPattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let seconds = Range(match.range(at: 1), in: name).flatMap({ TimeInterval(name[$0]) }) else { return nil }
        return (Date(timeIntervalSince1970: seconds), Range(match.range(at: 2), in: name).map { String(name[$0]) })
    }

    /// A note's place, in a few letters: in its copies' folder name in the Trash, for a note that comes back from the
    /// Trash without Notebook to find them (`bringBack`).
    static func placeMark(_ place: String) -> String {
        SHA256.hash(data: Data(place.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A note or folder Notebook put in the Trash: its copies go into the History's own Trash, under `name`
    /// (`trashedName`). There they wait for Undo or Put Back (`putBack`), or for it to come back from the Trash in the
    /// Finder (`bringBack`), and go a year later. A note made later under its name starts without them.
    func trash(_ url: URL, as name: String) {
        let url = url.standardizedFileURL
        queue.async { [self] in toTrash(folders(for: url).all, of: url, as: name) }
    }

    /// The copies of a note or folder put back from the Trash, to where it is now: its own name, or another.
    func putBack(_ name: String, to url: URL) {
        let url = url.standardizedFileURL
        queue.async { [self] in
            let entries = roots().compactMap { root -> URL? in
                let trash = root.appendingPathComponent(Self.trashName, isDirectory: true)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
                return names.first { $0 == name || $0.hasPrefix(name + " ") }.map { trash.appendingPathComponent($0, isDirectory: true) }
            }
            guard !entries.isEmpty else { return }
            setAside(url)
            let target = folders(for: url).write
            for entry in entries {
                carry(entry, to: target)
                removeEmptyFolders(from: entry.deletingLastPathComponent())
            }
            newest = [:]
        }
    }

    /// Copies at a note's place that aren't of this note go to the Trash: all there are, but those it brings along.
    private func setAside(_ url: URL, keeping sources: [URL] = []) {
        let found = folders(for: url).all.filter { folder in
            FileManager.default.fileExists(atPath: folder.path) && !sources.contains { $0.path == folder.path || Self.isSameItem($0, folder) }
        }
        guard !found.isEmpty else { return }
        toTrash(found, of: url, as: Self.trashedName(device: Self.known.withLock { $0 }))
    }

    /// Moves folders of a note's copies to the History's Trash, each in its store, and what it left in iCloud
    /// (`leftoversName`) along with them: nothing waits at a place another note may take.
    private func toTrash(_ folders: [URL], of note: URL, as name: String) {
        let entry = name + " " + Self.placeMark(Self.place(of: note, iCloudDrive: iCloudDrive).path)
        func trashed(in root: URL) -> URL {
            root.appendingPathComponent(Self.trashName, isDirectory: true).appendingPathComponent(entry, isDirectory: true)
        }
        for source in folders where FileManager.default.fileExists(atPath: source.path) {
            move(source, to: trashed(in: isInICloud(source) ? cloudRoot() ?? local : local))
            removeEmptyFolders(from: source.deletingLastPathComponent())
        }
        if let cloud = cloudRoot() { gatherLeftovers(in: trashed(in: local), into: trashed(in: cloud)) }
        newest = [:]
    }

    /// Moves what the lists of leftovers in a folder name into `target`, and the lists go.
    private func gatherLeftovers(in folder: URL, into target: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            if name == Self.leftoversName {
                for leftovers in leftovers(listedIn: folder) {
                    move(leftovers, to: target)
                    removeEmptyFolders(from: leftovers.deletingLastPathComponent())
                }
                try? FileManager.default.removeItem(at: url)
            } else if Self.isFolder(url) {
                gatherLeftovers(in: url, into: target.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// A note without copies, as one put back from the Trash in the Finder comes: copies in the History's Trash from
    /// its place, or from the folder it was in, come back to it when their newest says what it does. A note made under
    /// the name of one thrown away says something else.
    private func bringBack(_ note: URL, saying digest: SHA256.Digest, to folder: URL) {
        let parts = Self.place(of: note, iCloudDrive: iCloudDrive).path.split(separator: "/")
        guard !parts.isEmpty else { return }
        // Its place and the folders' it is in, by their marks: what is below each.
        var below: [String: String] = [:]
        for count in 1...parts.count {
            below[Self.placeMark(parts.prefix(count).joined(separator: "/"))] = parts.dropFirst(count).joined(separator: "/")
        }
        var found: [String: [URL]] = [:]
        for root in roots() {
            let trash = root.appendingPathComponent(Self.trashName, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] {
                guard let mark = name.split(separator: " ").last, let rest = below[String(mark)] else { continue }
                let copies = rest.isEmpty ? trash.appendingPathComponent(name) : trash.appendingPathComponent(name).appendingPathComponent(rest)
                if FileManager.default.fileExists(atPath: copies.path) { found[name, default: []].append(copies) }
            }
        }
        // The note thrown away last first.
        let newestFirst = found.sorted { (Self.trashed($0.key)?.date ?? .distantPast) > (Self.trashed($1.key)?.date ?? .distantPast) }
        for (_, folders) in newestFirst {
            guard let latest = folders.flatMap(Self.copies(in:)).max(by: { $0.date < $1.date }), Self.isDownloaded(latest.url),
                  let data = try? Data(contentsOf: latest.url), SHA256.hash(data: data) == digest else { continue }
            for source in folders {
                carry(source, to: folder)
                removeEmptyFolders(from: source.deletingLastPathComponent())
            }
            newest = [:]
            return
        }
    }

    /// Moves copies to another place in their store, or takes them to the other.
    private func carry(_ source: URL, to target: URL) {
        if isInICloud(source) == isInICloud(target) { move(source, to: target) } else { transfer(source, to: target) }
    }

    private func isInICloud(_ url: URL) -> Bool {
        guard let cloud = cloudRoot() else { return false }
        return url.path == cloud.path || url.path.hasPrefix(cloud.path + "/")
    }

    /// The file in a note's folder on this device that says where in iCloud copies of it stayed, which iCloud hadn't
    /// brought down when the note left iCloud: a path a line, from the History folder there on. Its versions are looked
    /// for there too, and they join the rest when the note goes back into iCloud.
    static let leftoversName = ".in iCloud"

    /// Where in iCloud those copies wait: out of the note's place there, which another note may take.
    static let leftoversFolderName = ".Leftovers"

    /// Takes copies from iCloud to this device's store or the other way, one by one: a copy is written there, then
    /// removed here. One iCloud hasn't brought down yet would only take its placeholder along, and iCloud would then
    /// remove the copy everywhere: it stays in iCloud (`leftoversFolderName`), is asked for, and the note's folder says
    /// where.
    private func transfer(_ source: URL, to target: URL) {
        let manager = FileManager.default
        if Self.isFolder(source) {
            for name in (try? manager.contentsOfDirectory(atPath: source.path)) ?? [] {
                if name == Self.leftoversName {
                    // Back into iCloud: what stayed there joins the rest.
                    for leftovers in leftovers(listedIn: source) where leftovers.path != target.path { move(leftovers, to: target) }
                    try? manager.removeItem(at: source.appendingPathComponent(name))
                } else if Self.realName(of: name) != name {
                    try? manager.startDownloadingUbiquitousItem(at: source.appendingPathComponent(Self.realName(of: name)))
                } else {
                    transfer(source.appendingPathComponent(name), to: target.appendingPathComponent(name))
                }
            }
            if isInICloud(source), !isInICloud(target), !Self.copies(in: source).isEmpty, let cloud = cloudRoot() {
                let aside = cloud.appendingPathComponent(Self.leftoversFolderName, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                move(source, to: aside)
                list(aside, asLeftoversIn: target)
            }
            if ((try? manager.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty { try? manager.removeItem(at: source) }
            return
        }
        guard Self.isDownloaded(source) else {
            try? manager.startDownloadingUbiquitousItem(at: source)
            return
        }
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: nil) { url in data = try? Data(contentsOf: url) }
        guard let data else { return }
        var written = manager.fileExists(atPath: target.path)
        if !written {
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: nil) { url in
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                written = (try? data.write(to: url, options: .atomic)) != nil
            }
        }
        if written { Self.remove(source) }
    }

    /// The folders in iCloud a note's folder here says copies of it stayed in.
    private func leftovers(listedIn folder: URL) -> [URL] {
        guard let cloud = cloudRoot(),
              let text = try? String(contentsOf: folder.appendingPathComponent(Self.leftoversName), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { cloud.appendingPathComponent(String($0), isDirectory: true) }
    }

    private func list(_ leftovers: URL, asLeftoversIn folder: URL) {
        guard let cloud = cloudRoot() else { return }
        let path = String(leftovers.path.dropFirst(cloud.path.count).drop { $0 == "/" })
        var paths = self.leftovers(listedIn: folder).map { String($0.path.dropFirst(cloud.path.count).drop { $0 == "/" }) }
        guard !paths.contains(path) else { return }
        paths.append(path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? paths.joined(separator: "\n").write(to: folder.appendingPathComponent(Self.leftoversName), atomically: true, encoding: .utf8)
    }

    /// Keeps only the lines of a folder's leftovers list whose folders are still there; false when none is.
    private func keepLeftovers(listedIn folder: URL) -> Bool {
        let file = folder.appendingPathComponent(Self.leftoversName)
        let there = leftovers(listedIn: folder).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard there.isEmpty else { return true }
        // Without iCloud the list can't be checked, and stays.
        guard cloudRoot() != nil else { return true }
        try? FileManager.default.removeItem(at: file)
        return false
    }

    /// Moves a folder of copies, or one copy, within one store, and puts it together with one there already.
    private func move(_ source: URL, to target: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        // Only the case of a name changed: the file system calls both the same, and it is a rename.
        guard manager.fileExists(atPath: target.path), !Self.isSameItem(source, target) else {
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: nil) { from, to in
                coordinator.item(at: from, willMoveTo: to)
                if (try? manager.moveItem(at: from, to: to)) != nil { coordinator.item(at: from, didMoveTo: to) }
            }
            return
        }
        guard Self.isFolder(source), Self.isFolder(target) else {
            if source.lastPathComponent == Self.leftoversName {
                // Two lists of what stayed in iCloud: one with the lines of both.
                for leftovers in leftovers(listedIn: source.deletingLastPathComponent()) { list(leftovers, asLeftoversIn: target.deletingLastPathComponent()) }
            }
            // A copy of the same name there is the same copy: taken in the same second on the same device.
            Self.remove(source)
            return
        }
        for name in (try? manager.contentsOfDirectory(atPath: source.path)) ?? [] {
            // A copy iCloud hasn't brought down yet, on iPhone and iPad, goes by its own name when it can.
            let real = Self.realName(of: name)
            let named = manager.fileExists(atPath: source.appendingPathComponent(real).path) ? real : name
            move(source.appendingPathComponent(named), to: target.appendingPathComponent(named))
        }
        if ((try? manager.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty { try? manager.removeItem(at: source) }
    }

    /// Takes away folders emptied by a move, up to the History folder.
    private func removeEmptyFolders(from folder: URL) {
        var folder = folder
        let roots = roots().map(\.path)
        while !roots.contains(folder.path), roots.contains(where: { folder.path.hasPrefix($0 + "/") }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), names.isEmpty {
            try? FileManager.default.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }

    // MARK: - Versions

    /// A note's copies, newest first, from their names alone: nothing is read or brought down from iCloud. Those that
    /// stayed in iCloud when it left are among them.
    func versions(of note: URL) async -> [Version] {
        let note = note.standardizedFileURL
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let folders = folders(for: note).all
                let copies = (folders + folders.flatMap(leftovers(listedIn:))).flatMap(Self.copies(in:)).map { copy in
                    var copy = copy
                    copy.isDownloaded = Self.isDownloaded(copy.url)
                    return copy
                }
                continuation.resume(returning: copies.sorted { $0.date > $1.date })
            }
        }
    }

    /// The text of a copy, read in the background. One iCloud hasn't brought down yet is asked for and waited for.
    /// Nil when it can't be read.
    func text(of version: Version) async -> String? {
        let url = version.url
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return await withCheckedContinuation { continuation in
            let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
            NSFileCoordinator().coordinate(with: [intent], queue: Self.readQueue) { error in
                #if DEBUG
                if let delay = FileLoading.debugDelay { Thread.sleep(forTimeInterval: delay) }
                #endif
                let text = error == nil ? (try? Data(contentsOf: intent.url)).flatMap(NoteDocument.decode) : nil
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - Places

    /// Where a note's copies are written, and every folder they may be in: in iCloud for a note in iCloud, when there
    /// is iCloud, and on this device, where they are for any other note and were for one in iCloud before there was.
    private func folders(for note: URL) -> (write: URL, all: [URL]) {
        let place = Self.place(of: note, iCloudDrive: iCloudDrive)
        let here = local.appendingPathComponent(place.path, isDirectory: true)
        guard place.isInICloud, let cloud = cloudRoot() else { return (here, [here]) }
        let there = cloud.appendingPathComponent(place.path, isDirectory: true)
        return (there, [there, here])
    }

    /// Where a note or folder is in the History folders: its path from `Mobile Documents` on for one in iCloud, which is
    /// the same on every device, and its path for any other.
    static func place(of url: URL, iCloudDrive: String) -> (isInICloud: Bool, path: String) {
        let path = HiddenFolders.withoutPrivate(url.standardizedFileURL.path)
        if let range = path.range(of: "/Mobile Documents/") { return (true, String(path[range.upperBound...])) }
        // A Mac that keeps Desktop and Documents in iCloud has them in the home folder, with links to them in iCloud Drive.
        for name in ["Desktop", "Documents"] {
            let link = iCloudDrive + "/" + name
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { continue }
            let folder = HiddenFolders.withoutPrivate(URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: iCloudDrive, isDirectory: true)).standardizedFileURL.path)
            guard path == folder || path.hasPrefix(folder + "/"), let range = link.range(of: "/Mobile Documents/") else { continue }
            return (true, String(link[range.upperBound...]) + path.dropFirst(folder.count))
        }
        #if os(iOS)
        // The app's own folder, On My iPhone › Notebook, is somewhere else after an update.
        let home = HiddenFolders.withoutPrivate(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
        if path == home || path.hasPrefix(home + "/") { return (false, "Notebook" + path.dropFirst(home.count)) }
        #endif
        return (false, String(path.drop { $0 == "/" }))
    }

    /// The History folder in Notebook's iCloud folder, looked up once: Apple asks for that to be off the main thread,
    /// as it can take a while the first time.
    private func cloudRoot() -> URL? {
        if let cloudFolder { return cloudFolder }
        let found: URL?
        switch cloud {
        case .none: found = nil
        case .folder(let url): found = url.standardizedFileURL
        case .container:
            found = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("History", isDirectory: true).standardizedFileURL
        }
        cloudFolder = .some(found)
        return found
    }

    // MARK: - Names

    /// A copy's name: when it was taken, in the time of the device, which the time zone makes exact everywhere, and on
    /// what. "2026-10-24 at 15.32.10 +0200 (iPhone).md"
    static func name(for date: Date, device: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date) / 60
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let zone = (offset < 0 ? "-" : "+") + two(abs(offset) / 60) + two(abs(offset) % 60)
        return "\(String(format: "%04d", parts.year ?? 0))-\(two(parts.month))-\(two(parts.day)) at \(two(parts.hour)).\(two(parts.minute)).\(two(parts.second)) \(zone) (\(device)).md"
    }

    private static let pattern = try? NSRegularExpression(pattern: #"^(\d{4})-(\d\d)-(\d\d) at (\d\d)\.(\d\d)\.(\d\d)(?: ([+-])(\d\d)(\d\d))? \((.+?)(?: ([0-9a-f]{6}))?\)\.md$"#)

    /// When a copy was taken and on what, from its name: "Mac", and which Mac when the name says. A name without a time
    /// zone is in this device's time.
    static func parse(_ name: String) -> (date: Date, device: String, deviceID: String?)? {
        let name = realName(of: name)
        let whole = NSRange(name.startIndex..., in: name)
        guard let match = pattern?.firstMatch(in: name, range: whole) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: name).map { String(name[$0]) }
        }
        func number(_ index: Int) -> Int { group(index).flatMap { Int($0) } ?? 0 }
        var parts = DateComponents(year: number(1), month: number(2), day: number(3), hour: number(4), minute: number(5), second: number(6))
        if let sign = group(7) {
            let minutes = number(8) * 60 + number(9)
            parts.timeZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * minutes * 60)
        }
        guard let date = Calendar(identifier: .gregorian).date(from: parts), let device = group(10) else { return nil }
        return (date, device, group(11))
    }

    /// iCloud on iPhone and iPad shows a file it hasn't brought down as ".name.icloud": its own name.
    static func realName(of name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private static func version(named name: String, in folder: URL) -> Version? {
        guard let parsed = parse(name) else { return nil }
        return Version(url: folder.appendingPathComponent(realName(of: name)), date: parsed.date, device: parsed.device, deviceID: parsed.deviceID)
    }

    /// The copies in a note's folder, by their names.
    private static func copies(in folder: URL) -> [Version] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var seen = Set<String>()
        return names.compactMap { name in
            guard let version = version(named: name, in: folder), seen.insert(version.url.lastPathComponent).inserted else { return nil }
            return version
        }
    }

    /// Removes a copy, or a folder of them, coordinated. One iCloud hasn't brought down, on iPhone and iPad, may only
    /// be there as ".name.icloud".
    private static func remove(_ url: URL) {
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
            if (try? FileManager.default.removeItem(at: url)) == nil {
                let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
                try? FileManager.default.removeItem(at: placeholder)
            }
        }
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let first = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        let second = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        guard let first, let second else { return false }
        return first.isEqual(second)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private extension DateComponents {
    /// The same time the other way: a year back.
    var negated: DateComponents {
        var parts = DateComponents()
        parts.year = year.map { -$0 }
        parts.month = month.map { -$0 }
        parts.day = day.map { -$0 }
        return parts
    }
}
