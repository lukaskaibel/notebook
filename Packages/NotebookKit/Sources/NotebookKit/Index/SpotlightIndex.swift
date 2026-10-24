import CoreSpotlight
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// The notes in Spotlight, on the Mac and in the search of iPhone and iPad: each note in the locations is an item of
/// Notebook's there, with its name, its first lines and its folder, and found by any word in it. Picking one opens it in
/// Notebook (`Workspace.openSpotlightItem`).
///
/// Spotlight is fed from what search knows of every note (`SearchIndex`), never by reading the files again. A moment
/// after the index changed, the notes whose name, folder, date or size changed since Spotlight last had them are given
/// to it again, and those that went (to the Trash, out of a location, into a hidden folder, with a location you
/// removed) are taken out of it. All of it in the background, a few notes at a time.
///
/// What Spotlight has is written down in Application Support (`Record`), with the number of the last batch, which
/// Spotlight keeps with its items too: a launch gives it only what changed since. When the two numbers differ
/// (Spotlight's index was made again, the record lost, the app stopped between a batch and writing it down), Spotlight
/// gets every note again.
@MainActor
final class SpotlightIndex {
    /// A note as Spotlight has it.
    struct Item: Sendable, Equatable {
        var id: String
        /// The ID of the location it is in.
        var domain: String
        var title: String
        /// Its first lines.
        var snippet: String
        /// The folder it is in.
        var folder: String
        /// Everything in it, for Spotlight to find it by; nil for a note that is only in iCloud.
        var text: String?
        var modified: Date?
    }

    /// Changes Spotlight takes in whole or not at all.
    struct Batch: Sendable, Equatable {
        var items: [Item] = []
        var deleted: [String] = []
    }

    /// What Spotlight has: each note's identifier with the `fingerprint` of what it was given, and the number of the
    /// last batch.
    struct Record: Codable, Equatable, Sendable {
        var state = 0
        var items: [String: Int64] = [:]
    }

    /// What search knows, when an update starts.
    struct Snapshot: Sendable {
        var entries: [String: SearchIndex.Entry]
        /// Every hidden folder, shown in the sidebar for now or not.
        var hidden: [String]
        var locations: [Location]
    }

    /// The notes to give Spotlight, newest first, and the identifiers of those to take out.
    struct Plan: Sendable {
        var changed: [(id: String, fingerprint: Int64, entry: SearchIndex.Entry, domain: String)] = []
        var gone: [String] = []
    }

    /// Goes up whenever what an item has changes (how the snippet is made, which attributes it sets): every note is
    /// given to Spotlight again.
    nonisolated static let version = 1
    /// About what one batch holds.
    nonisolated static let batchItems = 100
    nonisolated static let batchBytes = 2_000_000
    nonisolated static let batchDeletions = 1000

    private let store: any SpotlightStore
    /// Where the record is kept between launches; nil to keep it for this run only.
    private let recordURL: URL?
    /// What Spotlight has, once the first update since launch has read it.
    private var record: Record?
    /// What search knows now: asked for when an update starts, nil while the index is being built.
    var source: (() -> Snapshot?)?
    /// How long an update waits for more changes, so a burst of them (typing, iCloud syncing) is one.
    var delay: Duration = .seconds(2)
    private var isWanted = false
    private var task: Task<Void, Never>?
    /// Notes Spotlight showed that aren't there any more, to take out with the next update.
    private var stale = Set<String>()
    /// How many notes the last update gave Spotlight and took out, for tests and the debug remote.
    private(set) var lastUpdate = (given: 0, taken: 0, failed: false)
    private(set) var updates = 0
    /// How long the last update took, from its plan to its last batch, in seconds.
    private(set) var lastDuration = 0.0

    init(store: any SpotlightStore, recordURL: URL?) {
        self.store = store
        self.recordURL = recordURL
    }

    /// An update is wanted or under way.
    var isUpdating: Bool { isWanted || task != nil }

    /// What Spotlight has now, as far as this run knows.
    var donated: [String: Int64] { record?.items ?? [:] }

    /// Something changed: Spotlight gets it a moment later, one update at a time.
    func setNeedsUpdate() {
        isWanted = true
        guard task == nil else { return }
        startNext()
    }

    /// Takes every note out of Spotlight, and forgets what it had: for the debug remote, after a run on the sample notes.
    func clear() async {
        let store = store, recordURL = recordURL
        try? await store.deleteAll()
        if let recordURL { try? FileManager.default.removeItem(at: recordURL) }
        record = nil
    }

    /// Takes out a note Spotlight showed that isn't there any more.
    func remove(_ identifier: String) {
        stale.insert(identifier)
        setNeedsUpdate()
    }

    private func startNext() {
        guard isWanted else { return }
        let delay = delay
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.run()
        }
    }

    private func run() async {
        isWanted = false
        defer {
            task = nil
            startNext()
        }
        let store = store, recordURL = recordURL
        if record == nil {
            record = await Task.detached(priority: .utility) { await Self.startingRecord(store: store, url: recordURL) }.value
        }
        guard let record else { return }
        let started = ContinuousClock.now
        let plan: Plan
        // The snapshot goes as soon as the plan is made: the index changing meanwhile would copy all of it.
        do {
            guard let snapshot = source?() else { return }
            let stale = stale
            self.stale = []
            let donated = record.items
            plan = await Task.detached(priority: .utility) { Self.plan(snapshot, donated: donated, stale: stale) }.value
        }
        guard !plan.changed.isEmpty || !plan.gone.isEmpty else {
            updates += 1
            lastUpdate = (0, 0, false)
            lastDuration = (ContinuousClock.now - started) / .seconds(1)
            return
        }
        let outcome = await Task.detached(priority: .utility) { await Self.apply(plan, to: record, store: store, recordURL: recordURL) }.value
        // After a batch Spotlight didn't take, the next update starts again from what Spotlight and the kept record say.
        self.record = outcome.failed ? nil : outcome.record
        updates += 1
        lastUpdate = (outcome.given, outcome.taken, outcome.failed)
        lastDuration = (ContinuousClock.now - started) / .seconds(1)
        if outcome.failed {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.setNeedsUpdate()
            }
        }
    }

    // MARK: - Working out what changed

    /// What Spotlight has at the first update since launch: the record kept last time, if Spotlight has all of it, and
    /// else nothing, for every note to go in again, in place of what Spotlight has of it. Spotlight tells by taking an
    /// empty batch only if the last it kept carried the record's number. Nil when it can't be asked now.
    ///
    /// Spotlight isn't emptied first: on iOS 27 in the Simulator, taking everything out never finishes, and holds up
    /// everything asked after it. Spotlight's own index made again is empty anyway; a note gone while the record was
    /// lost stays until it is picked (`remove`).
    nonisolated static func startingRecord(store: any SpotlightStore, url: URL?) async -> Record? {
        guard store.isAvailable else { return nil }
        guard var kept = url.flatMap(read), kept.state != 0 else { return Record() }
        do {
            try await store.apply(Batch(), expected: kept.state, state: kept.state + 1)
        } catch SpotlightMismatch.state {
            return Record()
        } catch {
            return nil
        }
        kept.state += 1
        if let url { write(kept, to: url) }
        return kept
    }

    /// The notes that are new or changed since Spotlight last had them, newest first, and those that went: in a
    /// hidden folder, outside the locations, or no longer there at all; with `stale`, which Spotlight showed and
    /// aren't there.
    nonisolated static func plan(_ snapshot: Snapshot, donated: [String: Int64], stale: Set<String> = []) -> Plan {
        var locations: [UUID: Location] = [:]
        for location in snapshot.locations { locations[location.id] = location }
        var plan = Plan()
        var seen = Set<String>()
        for entry in snapshot.entries.values where entry.kind == .note {
            guard let location = locations[entry.locationID], !SearchIndex.isHidden(entry.path, in: snapshot.hidden),
                  let id = identifier(of: entry.path, in: location), seen.insert(id).inserted else { continue }
            let fingerprint = fingerprint(of: entry)
            if donated[id] != fingerprint { plan.changed.append((id, fingerprint, entry, location.id.uuidString)) }
        }
        plan.changed.sort { ($0.entry.modified ?? .distantPast) > ($1.entry.modified ?? .distantPast) }
        plan.gone = donated.keys.filter { !seen.contains($0) } + stale.filter { !seen.contains($0) && donated[$0] == nil }
        return plan
    }

    /// What Spotlight shows and finds of a note, as a number: when it changes, the note is given to Spotlight again.
    nonisolated static func fingerprint(of entry: SearchIndex.Entry) -> Int64 {
        let modified = entry.modified?.timeIntervalSinceReferenceDate ?? 0
        let parts = "\(version)\u{0}\(entry.name)\u{0}\(entry.place)\u{0}\(modified)\u{0}\(entry.size ?? -1)\u{0}\(entry.text != nil)"
        return Int64(bitPattern: SearchIndex.stableHash(parts))
    }

    nonisolated static func item(for entry: SearchIndex.Entry, id: String, domain: String) -> Item {
        Item(id: id, domain: domain, title: entry.name, snippet: entry.text.map { NotePoints.beginning(of: $0, title: entry.name) } ?? "",
             folder: entry.place.components(separatedBy: " › ").last ?? entry.place, text: entry.text, modified: entry.modified)
    }

    /// Gives Spotlight the plan in batches, each carrying the number after the last, and writes down what it has after
    /// each. Stops at the first batch Spotlight doesn't take.
    nonisolated static func apply(_ plan: Plan, to record: Record, store: any SpotlightStore, recordURL: URL?) async -> (record: Record, given: Int, taken: Int, failed: Bool) {
        var record = record
        var gone = plan.gone[...]
        var changed = plan.changed[...]
        var given = 0, taken = 0
        while !gone.isEmpty || !changed.isEmpty {
            var batch = Batch(deleted: Array(gone.prefix(batchDeletions)))
            gone = gone.dropFirst(batchDeletions)
            var fingerprints: [(String, Int64)] = []
            var bytes = 0
            while let next = changed.first, batch.items.count < batchItems, bytes < batchBytes {
                changed = changed.dropFirst()
                let item = item(for: next.entry, id: next.id, domain: next.domain)
                bytes += item.text?.utf8.count ?? 0
                batch.items.append(item)
                fingerprints.append((next.id, next.fingerprint))
            }
            let state = record.state + 1
            do {
                try await store.apply(batch, expected: record.state == 0 ? nil : record.state, state: state)
            } catch {
                return (record, given, taken, true)
            }
            record.state = state
            for id in batch.deleted { record.items[id] = nil }
            for (id, fingerprint) in fingerprints { record.items[id] = fingerprint }
            if let recordURL { write(record, to: recordURL) }
            given += batch.items.count
            taken += batch.deleted.count
        }
        return (record, given, taken, false)
    }

    // MARK: - Identifiers

    /// A note's identifier in Spotlight: its location's ID and its path in the location's folder, as
    /// "<ID>/Travel/Kyoto trip.md". It stays the same from launch to launch and when the location's folder moves, and is
    /// found again through the locations (`path(of:in:)`), whose bookmarks reach the folder. A note in a linked folder
    /// goes by the link to it: iCloud Drive's Desktop is "<ID>/Desktop/…", an app's folder next to iCloud Drive
    /// "<ID>/../iCloud~md~obsidian/Documents/…".
    nonisolated static func identifier(of path: String, in location: Location) -> String? {
        let path = HiddenFolders.withoutPrivate(path)
        var inLocation = path
        if let linked = location.linked.first(where: { isInside(path, HiddenFolders.withoutPrivate($0.url.path)) }) {
            inLocation = HiddenFolders.withoutPrivate(linked.alias.path) + path.dropFirst(HiddenFolders.withoutPrivate(linked.url.path).count)
        }
        let top = HiddenFolders.withoutPrivate(location.url.path)
        if inLocation.hasPrefix(top + "/") { return location.id.uuidString + "/" + inLocation.dropFirst(top.count + 1) }
        let above = (top as NSString).deletingLastPathComponent
        if above != "/", inLocation.hasPrefix(above + "/") { return location.id.uuidString + "/../" + inLocation.dropFirst(above.count + 1) }
        return nil
    }

    /// Where the note an identifier names is, through its location as it is now; nil when no location has it.
    nonisolated static func path(of identifier: String, in locations: [Location]) -> String? {
        guard let slash = identifier.firstIndex(of: "/"), let id = UUID(uuidString: String(identifier[..<slash])),
              let location = locations.first(where: { $0.id == id }) else { return nil }
        var relative = identifier[identifier.index(after: slash)...]
        var base = location.url.path
        if relative.hasPrefix("../") {
            base = (base as NSString).deletingLastPathComponent
            relative = relative.dropFirst(3)
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        var path = base + "/" + relative
        // Through the link, to where the linked folder is.
        if let linked = location.linked.first(where: { isInside(path, $0.alias.path) }) {
            path = linked.url.path + path.dropFirst(linked.alias.path.count)
        }
        return location.folder(containing: path) == nil ? nil : path
    }

    nonisolated private static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder + "/")
    }

    // MARK: - Kept between launches

    nonisolated static func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Record.self, from: data)
    }

    nonisolated static func write(_ record: Record, to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Where the notes go: Spotlight, or a stand-in in tests.
protocol SpotlightStore: Sendable {
    /// Whether Spotlight takes items on this device.
    var isAvailable: Bool { get }
    /// One batch, which Spotlight keeps with `state`, if the last it kept carried `expected` (nil: whatever it was);
    /// else it throws `SpotlightMismatch.state`.
    func apply(_ batch: SpotlightIndex.Batch, expected: Int?, state: Int) async throws
    /// Takes every note out.
    func deleteAll() async throws
}

enum SpotlightMismatch: Error {
    /// Spotlight's last batch carried another number than the one expected.
    case state
    /// Spotlight didn't answer.
    case timeout
}

/// Spotlight itself, through an index of Notebook's own: only one with a name keeps the number of a batch. (Asking
/// Spotlight for that number, `fetchLastClientState`, never answers on iOS 27 in the Simulator; a batch that expects
/// it does.)
final class CoreSpotlightStore: SpotlightStore, @unchecked Sendable {
    /// Used by one update at a time (`SpotlightIndex`), as batches need.
    private let index: CSSearchableIndex
    private static let markdown = UTType("net.daringfireball.markdown") ?? .plainText

    init(name: String) {
        index = CSSearchableIndex(name: name)
    }

    var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    func apply(_ batch: SpotlightIndex.Batch, expected: Int?, state: Int) async throws {
        begin(batch)
        let new = Data(String(state).utf8)
        try await answer { done in
            if let expected {
                index.endIndexBatch(expectedClientState: Data(String(expected).utf8), newClientState: new) { error in
                    let mismatched = (error as? CSIndexError)?.code == .mismatchedClientState
                    done(mismatched ? SpotlightMismatch.state : error)
                }
            } else {
                index.endBatch(withClientState: new, completionHandler: done)
            }
        }
    }

    func deleteAll() async throws {
        try await answer { index.deleteAllSearchableItems(completionHandler: $0) }
    }

    /// What Spotlight answers, or `SpotlightMismatch.timeout` after two minutes without an answer: an update then
    /// ends, and the next tries again.
    private func answer(_ ask: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waiting = Waiting(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { waiting.resume(SpotlightMismatch.timeout) }
            ask { waiting.resume($0) }
        }
    }

    /// Goes on once, with whichever comes first: Spotlight's answer or the end of the wait.
    private final class Waiting: Sendable {
        private let continuation: Mutex<CheckedContinuation<Void, Error>?>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ error: Error?) {
            guard let continuation = continuation.withLock({ $0.take() }) else { return }
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    /// The changes of a batch, which Spotlight takes when it ends: nothing to wait for before.
    private func begin(_ batch: SpotlightIndex.Batch) {
        index.beginBatch()
        if !batch.items.isEmpty { index.indexSearchableItems(batch.items.map(Self.searchableItem), completionHandler: nil) }
        if !batch.deleted.isEmpty { index.deleteSearchableItems(withIdentifiers: batch.deleted, completionHandler: nil) }
    }

    static func searchableItem(_ item: SpotlightIndex.Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: markdown)
        attributes.title = item.title
        attributes.displayName = item.title
        attributes.contentDescription = item.snippet.isEmpty ? nil : item.snippet
        attributes.textContent = item.text
        attributes.containerTitle = item.folder
        attributes.containerDisplayName = item.folder
        attributes.contentModificationDate = item.modified
        // No `contentURL`: with one, iOS asks the File Provider about each note's file, one at a time, as it takes
        // the batch (and in the Simulator never hears back).
        let searchable = CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: item.domain, attributeSet: attributes)
        // For as long as the note is there, not the month Spotlight keeps items otherwise.
        searchable.expirationDate = .distantFuture
        return searchable
    }
}
