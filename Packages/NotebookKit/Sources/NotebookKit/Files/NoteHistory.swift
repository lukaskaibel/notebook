#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CryptoKit

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
/// so renaming or moving a folder takes them all along in one step (`follow`).
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
        /// Which Mac, iPhone or iPad, as its name says it: a few random letters each device picks once.
        var deviceID: String?
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
        "Mac " + deviceID
        #else
        (UIDevice.current.userInterfaceIdiom == .pad ? "iPad " : "iPhone ") + deviceID
        #endif
    }

    /// Picked at random the first time, and kept. It says nothing about the device.
    @MainActor
    static var deviceID: String {
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
        var copies = Self.copies(in: folder)
        let digest = SHA256.hash(data: Data(text.utf8))
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

    /// Thins the copies of every note, also of those not written in for a long time and of those thrown away, which
    /// keep theirs for Undo and Put Back: what is a year old goes. In the background, at most once a day; a day written
    /// down by a clock set ahead doesn't hold it up. `device` is this device's name in copies.
    @MainActor
    func tidyUp(defaults: UserDefaults = .standard, device: String? = nil) {
        let key = "historyTidiedUp"
        let now = Date()
        if let last = defaults.object(forKey: key) as? Date, last <= now, now.timeIntervalSince(last) < 86400 { return }
        defaults.set(now, forKey: key)
        let device = device ?? Self.thisDevice
        queue.async { [self] in
            for root in roots() { tidyUp(root, root: root, now: Date(), device: device) }
        }
    }

    /// Thins each note's copies under a folder and takes away the folders left empty. True when it is empty itself.
    /// This device's copies are thinned as when it writes them. Another device's go only once their note is gone too and
    /// they are a year old: that device thins its own, and a clock here set wrong can't take them away.
    @discardableResult
    private func tidyUp(_ folder: URL, root: URL, now: Date, device: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var copies: [Version] = []
        var left = names.count
        for name in names {
            let url = folder.appendingPathComponent(name)
            if let copy = Self.version(named: name, in: folder) {
                copies.append(copy)
            } else if Self.isFolder(url), tidyUp(url, root: root, now: now, device: device) {
                try? FileManager.default.removeItem(at: url)
                left -= 1
            }
        }
        guard !copies.isEmpty else { return left == 0 }
        let isGone = !noteExists(for: folder, in: root)
        let own = copies.filter { Self.isTaken($0, by: device) }
        var removed = thin(own, now: now, keepsNewest: !isGone)
        if isGone, let year = Self.calendar.date(byAdding: Self.keptFor.negated, to: now) {
            for copy in copies where !Self.isTaken(copy, by: device) && copy.date < year {
                Self.remove(copy.url)
                removed += 1
            }
        }
        return left - removed == 0
    }

    /// Whether the note whose copies are in a folder is still where they say: one thrown away, or renamed outside
    /// Notebook, is not.
    private func noteExists(for folder: URL, in root: URL) -> Bool {
        let relative = String(folder.path.dropFirst(root.path.count).drop { $0 == "/" })
        var path = "/" + relative
        if let cloud = cloudRoot(), root.path == cloud.path {
            path = (iCloudDrive as NSString).deletingLastPathComponent + path
        } else {
            #if os(iOS)
            if relative == "Notebook" || relative.hasPrefix("Notebook/") {
                path = NSHomeDirectory() + relative.dropFirst("Notebook".count)
            }
            #endif
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The History folders there are: in iCloud and on this device.
    private func roots() -> [URL] {
        [cloudRoot(), local].compactMap { $0 }
    }

    // MARK: - Following notes

    /// A note or folder Notebook renamed or moved: its copies go along, to the right store for where it went. Copies
    /// there already, of a note thrown away before whose name it takes now, are set aside, apart from them, and come
    /// back when the name is free again, for Put Back to find.
    func follow(from old: URL, to new: URL) {
        let old = old.standardizedFileURL
        let new = new.standardizedFileURL
        queue.async { [self] in
            let target = folders(for: new).write
            let sources = folders(for: old).all.filter { $0.path != target.path && FileManager.default.fileExists(atPath: $0.path) }
            if !sources.isEmpty, FileManager.default.fileExists(atPath: target.path), !sources.contains(where: { Self.isSameItem($0, target) }) {
                setAside(target)
            }
            for source in sources {
                if isInICloud(source) == isInICloud(target) { move(source, to: target) } else { transfer(source, to: target) }
                bringBack(source)
                removeEmptyFolders(from: source.deletingLastPathComponent())
            }
            newest = [:]
        }
    }

    /// Copies of another note, thrown away, that had the name a note now takes: they go beside it as ".Name.md 1234",
    /// which lists no versions and is thinned on its own.
    private func setAside(_ folder: URL) {
        let parent = folder.deletingLastPathComponent()
        let aside = parent.appendingPathComponent(".\(folder.lastPathComponent) \(Int(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        move(folder, to: aside)
    }

    /// Copies set aside where a note's name is free again: the newest set back under it.
    private func bringBack(_ folder: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else { return }
        let parent = folder.deletingLastPathComponent()
        let prefix = ".\(folder.lastPathComponent) "
        let aside = ((try? manager.contentsOfDirectory(atPath: parent.path)) ?? []).filter {
            $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count)) != nil
        }
        guard let newest = aside.max(by: { Int($0.dropFirst(prefix.count))! < Int($1.dropFirst(prefix.count))! }) else { return }
        move(parent.appendingPathComponent(newest), to: folder)
    }

    private func isInICloud(_ url: URL) -> Bool {
        guard let cloud = cloudRoot() else { return false }
        return url.path == cloud.path || url.path.hasPrefix(cloud.path + "/")
    }

    /// Takes copies from iCloud to this device's store or the other way, one by one: a copy is written there, then
    /// removed here. One iCloud hasn't brought down yet would only take its placeholder along, and iCloud would then
    /// remove the copy everywhere: it stays where it is and is asked for, and goes after a year.
    private func transfer(_ source: URL, to target: URL) {
        let manager = FileManager.default
        if Self.isFolder(source) {
            for name in (try? manager.contentsOfDirectory(atPath: source.path)) ?? [] {
                if Self.realName(of: name) != name {
                    try? manager.startDownloadingUbiquitousItem(at: source.appendingPathComponent(Self.realName(of: name)))
                    continue
                }
                transfer(source.appendingPathComponent(name), to: target.appendingPathComponent(name))
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

    /// A note's copies, newest first, from their names alone: nothing is read or brought down from iCloud.
    func versions(of note: URL) async -> [Version] {
        let note = note.standardizedFileURL
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let copies = folders(for: note).all.flatMap(Self.copies(in:))
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
