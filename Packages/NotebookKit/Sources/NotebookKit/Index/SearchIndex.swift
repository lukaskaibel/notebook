#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit
import Synchronization

/// Every file in the locations, with the text of every note (and of PDFs), for search, `[[` and resolving links. Built in
/// the background when the app starts and kept up to date as files change. It is kept between launches
/// (`KeptIndex`): search has everything at once, and building it reads only what changed since.
@MainActor
@Observable
public final class SearchIndex {
    public struct Entry: Sendable {
        public var url: URL
        /// The name shown: a note without ".md".
        public var name: String
        public var kind: FileKind
        /// Where it is, as "Location › Folder › Folder".
        public var place: String
        public var locationID: UUID
        public var modified: Date?
        /// In bytes, with `modified` what tells whether a file changed since it was read; nil for folders.
        public var size: Int?
        public var isInCloud: Bool
        /// The text, for notes and PDFs; nil for other files.
        public var text: String?
        var folded: String?
        var foldedName: String
        /// The file's name with its extension, folded: what a link to a file other than a note gives.
        var foldedFileName: String
        /// Its address and its folder's, as keys.
        var path: String
        var folder: String
        /// A note's headings, for search to find a section by.
        var headings: [Heading] = []
        /// The pictures and files a note shows from its `.assets` folder, by name: the text read in them is found as
        /// the note's.
        var assets: [String] = []
        /// A PDF's pages without text of their own, such as scanned ones, counted from 0: their text is read from
        /// their pictures.
        var pagesWithoutText: [Int] = []

        /// Whether this entry is still right for a file of this kind, date and size: then reading the file again would
        /// give the same, except a note's text that couldn't be read before (only in iCloud then, now here).
        func isCurrent(kind: FileKind, modified: Date?, size: Int?, inCloud: Bool) -> Bool {
            guard kind == self.kind, let modified, modified == self.modified, size == self.size else { return false }
            if kind == .note, text == nil, !inCloud, (size ?? 0) < SearchIndex.largestNote { return false }
            return true
        }

        /// The same file as it was: what search, links and Move To show of it is the same.
        func isSame(as other: Entry) -> Bool {
            kind == other.kind && modified == other.modified && size == other.size && isInCloud == other.isInCloud
                && (text == nil) == (other.text == nil) && locationID == other.locationID && place == other.place
        }
    }

    public struct Heading: Sendable, Equatable {
        public var level: Int
        public var title: String
    }

    /// Every file, by its address. Only the main thread changes it, and only by the few files that changed: everything
    /// that takes time (reading folders, the text of notes and PDFs) happens in the background first.
    @ObservationIgnored private var byPath: [String: Entry] = [:]
    /// The addresses of the files in each folder, so a folder read again is merged in without going through the rest.
    @ObservationIgnored private var byFolder: [String: Set<String>] = [:]
    /// The addresses of the files by their folded names (a note's with and without ".md"), so a link finds its file at
    /// once, without going through every file there is.
    @ObservationIgnored private var byName: [String: Set<String>] = [:]
    /// The addresses of every folder, for Move To.
    @ObservationIgnored private var folderPaths: Set<String> = []
    /// Counts changes, for what shows the index to update.
    private(set) var version = 0
    /// What search goes through: made again in the background after changes, so it can be a moment behind.
    @ObservationIgnored private(set) var corpus = SearchCorpus.empty
    @ObservationIgnored private var corpusTask: Task<Void, Never>?
    @ObservationIgnored private var corpusWanted = false
    /// Searches showing their results, to be run again on a new corpus.
    @ObservationIgnored private var corpusObservers: [WeakSearch] = []
    /// The text read in pictures, scans and drawings, by the file's address (for a picture in a note,
    /// `folder/.assets/name`).
    @ObservationIgnored var recognized: [String: PictureText] = [:] {
        didSet { changed(notes: false) }
    }
    /// Counts the times folders came or went, which is far less often than files change.
    private(set) var folderVersion = 0
    /// Called when folders came or went.
    @ObservationIgnored var onFoldersChanged: (() -> Void)?
    public private(set) var isBuilding = false
    /// Called when the index has been built: links in a note opened before resolve now.
    @ObservationIgnored var onBuilt: (() -> Void)?
    /// Called when folders have been read again: links to what changed in them resolve now.
    @ObservationIgnored var onRefreshed: (() -> Void)?
    /// Folders hidden from the sidebar: what is in them stays out of search, `[[` and Move To, but links still find it.
    @ObservationIgnored var hiddenPaths: [String] = [] {
        didSet { if hiddenPaths != oldValue { changed() } }
    }
    @ObservationIgnored private var generation = 0
    /// Folders that changed while the index was being built, read again once it is.
    @ObservationIgnored private var changedWhileBuilding = Set<URL>()
    @ObservationIgnored private var locations: [Location] = []
    /// The newest reading of each folder, so an older one finishing later doesn't undo it.
    @ObservationIgnored private var newestRefresh: [String: Int] = [:]
    @ObservationIgnored private var refreshes = 0
    /// A folder went while folders were merged in (one replacing it keeps their number the same).
    @ObservationIgnored private var foldersChanged = false
    /// Whether the files have been read since launch: until then, the index kept from the last run stands in.
    @ObservationIgnored private(set) var hasBuilt = false
    /// Notes larger than this aren't read: a log or a dump, not something written.
    nonisolated static let largestNote = 4_000_000

    public var count: Int {
        _ = version
        return byPath.count
    }

    /// Every file by its address, for work in the background.
    var byPathSnapshot: [String: Entry] { byPath }

    /// Every file, in no particular order.
    public var entries: [Entry] {
        _ = version
        return Array(byPath.values)
    }

    nonisolated static func fold(_ string: String) -> String {
        contiguous(string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// Made Swift's own, not left as Foundation's string, so search goes through its bytes without copying them.
    nonisolated static func contiguous(_ string: String) -> String {
        var string = string
        string.makeContiguousUTF8()
        return string
    }

    /// One change more: what shows the index updates, and search gets a new corpus.
    /// `notes`: what notes say may have changed too, not only the text read in pictures and PDFs.
    private func changed(notes: Bool = true) {
        version += 1
        scheduleCorpus()
        if notes { onChanged?() }
    }

    /// Called whenever notes may have changed (or folders were hidden): the to-dos are read again.
    @ObservationIgnored var onChanged: (() -> Void)?

    // MARK: - Building

    /// Every file by its address, and the lookups made from them: made in the background, put in place at once.
    private struct Lookups: Sendable {
        var byPath: [String: Entry] = [:]
        var byFolder: [String: Set<String>] = [:]
        var byName: [String: Set<String>] = [:]
        var folderPaths: Set<String> = []

        init() {}

        /// Made from many entries at once, each lookup on a core of its own.
        init(all entries: [Entry]) {
            let paths = Mutex<[String: Entry]>([:]), folders = Mutex<[String: Set<String>]>([:])
            let names = Mutex<[String: Set<String>]>([:]), allFolders = Mutex<Set<String>>([])
            DispatchQueue.concurrentPerform(iterations: 3) { part in
                switch part {
                case 0:
                    var byPath = [String: Entry](minimumCapacity: entries.count)
                    for entry in entries { byPath[entry.path] = entry }
                    paths.withLock { $0 = byPath }
                case 1:
                    var byFolder: [String: Set<String>] = [:]
                    for entry in entries { byFolder[entry.folder, default: []].insert(entry.path) }
                    folders.withLock { $0 = byFolder }
                default:
                    var byName = [String: Set<String>](minimumCapacity: entries.count)
                    var folderPaths: Set<String> = []
                    for entry in entries {
                        for key in SearchIndex.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
                        if entry.kind == .folder { folderPaths.insert(entry.path) }
                    }
                    names.withLock { $0 = byName }
                    allFolders.withLock { $0 = folderPaths }
                }
            }
            byPath = paths.withLock { $0 }
            byFolder = folders.withLock { $0 }
            byName = names.withLock { $0 }
            folderPaths = allFolders.withLock { $0 }
        }

        mutating func add(_ entry: Entry) {
            byPath[entry.path] = entry
            byFolder[entry.folder, default: []].insert(entry.path)
            for key in SearchIndex.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
            if entry.kind == .folder { folderPaths.insert(entry.path) }
        }
    }

    /// Puts new lookups in place of the old, which go away on another thread: freeing the text of thousands of notes
    /// takes a while too.
    private func put(_ lookups: Lookups) {
        let old = (byPath, byFolder, byName, folderPaths)
        DispatchQueue.global(qos: .background).async { withExtendedLifetime(old) {} }
        byPath = lookups.byPath
        byFolder = lookups.byFolder
        byName = lookups.byName
        folderPaths = lookups.folderPaths
    }

    /// Reads every folder of the locations in the background, and puts what it found in place of what the index had.
    /// A file as it was when the index last read it (by its date and size) isn't read again: at launch, the index kept
    /// from the last run is shown at once and only what changed since is read.
    func rebuild(_ locations: [Location]) {
        generation += 1
        let generation = generation
        self.locations = locations
        isBuilding = true
        changedWhileBuilding = []
        pdfQueue = []
        let roots = locations.flatMap { location in location.folders.map { ($0.url, $0.place, location.id) } }
        let hidden = hiddenPaths, recognized = self.recognized, version = self.version
        let current = byPath
        let kept = hasBuilt ? nil : self.kept
        #if DEBUG
        let started = CACurrentMediaTime()
        let notesRead = Self.notesRead.load(ordering: .relaxed)
        #endif
        Task.detached(priority: .utility) {
            var known = current
            if let kept, let lookups = await kept.value {
                known = lookups.byPath
                // Anything read since launch is newer.
                for (path, entry) in current { known[path] = entry }
                await MainActor.run { self.install(lookups, generation: generation) }
            }
            var found = Lookups()
            var changes = 0
            var shown = CACurrentMediaTime()
            for (root, name, id) in roots {
                Self.walk(root.path, root: root.path, locationName: name, locationID: id, known: known) { entry, isNew in
                    found.add(entry)
                    if isNew { changes += 1 }
                    // A whole iCloud Drive takes a while: search finds what has been read so far in the meantime, unless
                    // it has all there was the last time.
                    if known.isEmpty, CACurrentMediaTime() - shown > 1.5 {
                        let partial = SearchCorpus(version: version, entries: found.byPath.values, hidden: hidden, recognized: recognized)
                        Task { @MainActor in
                            // Only before the index has anything: the last full one beats part of a new one.
                            guard generation == self.generation, self.isBuilding, self.byPath.isEmpty else { return }
                            self.show(partial)
                        }
                        shown = CACurrentMediaTime()
                    }
                }
            }
            let pdfs = found.byPath.values.filter { $0.kind == .pdf && !$0.isInCloud && $0.text == nil }.map { PDFJob(url: $0.url, path: $0.path, modified: $0.modified) }
            // Every file as the index had it, as after most launches: what it has stays, with what changed meanwhile.
            let isUnchanged = !known.isEmpty && changes == 0 && found.byPath.count == known.count
            let built = found
            await MainActor.run {
                guard generation == self.generation else { return }
                self.kept = nil
                self.hasBuilt = true
                if !isUnchanged {
                    self.put(built)
                    self.changed()
                    self.folderVersion += 1
                }
                self.isBuilding = false
                #if DEBUG
                self.lastBuild = (Self.notesRead.load(ordering: .relaxed) - notesRead, pdfs.count)
                self.log(String(format: "built %d files in %.0f ms, reading %d notes and %d PDFs", built.byPath.count, (CACurrentMediaTime() - started) * 1000,
                                self.lastBuild.notesRead, pdfs.count))
                #endif
                self.onBuilt?()
                self.onIndexed?(built.byPath)
                if !isUnchanged { self.onFoldersChanged?() }
                // Changes merged in meanwhile waited for this.
                if !isUnchanged || self.unsavedSince != nil { self.save() }
                self.readPDFs(pdfs)
                let changed = self.changedWhileBuilding
                self.changedWhileBuilding = []
                if !changed.isEmpty { self.refresh(folders: Array(changed), locations: self.locations) }
            }
        }
    }

    /// Puts the index kept from the last run in place while the files are read: search, links and Move To have
    /// everything at once. Only before the files have been read.
    private func install(_ lookups: Lookups, generation: Int) {
        guard generation == self.generation, !hasBuilt, isBuilding, !lookups.byPath.isEmpty else { return }
        kept = nil
        put(lookups)
        changed()
        folderVersion += 1
        #if DEBUG
        log("kept index of \(lookups.byPath.count) files in place")
        #endif
        onBuilt?()
        onFoldersChanged?()
        // Folders read since launch are newer than what was kept: read again.
        if !changedWhileBuilding.isEmpty { refresh(folders: Array(changedWhileBuilding), locations: locations) }
    }

    /// Folders left out with everything in them, as the sidebar leaves them out.
    nonisolated private static let skippedFolders: Set<String> = ["node_modules", "DerivedData", ".build", "Pods"]

    /// Goes through the files in `folder` (an address in the location folder `root`) and, if `deep`, in every folder in
    /// it, as the sidebar shows them: without hidden files and packages' insides. Calls `listed` with each folder whose
    /// files it goes through, before them, and `each` with every file, and whether it is new or changed since `known`. A
    /// file as it was in `known` (by its date and size) isn't read again.
    ///
    /// With `fts`, which hands over each file's date, size and flags with its name, in the system's own code: a hundred
    /// thousand files take well under a second, ten times less than with `FileManager`'s resource values.
    nonisolated static func walk(_ folder: String, root: String, locationName: String, locationID: UUID, deep: Bool = true, known: [String: Entry] = [:],
                                 listed: (String) -> Void = { _ in }, each: (_ entry: Entry, _ isNew: Bool) -> Void) {
        let relative = folder.hasPrefix(root) ? folder.dropFirst(root.count).split(separator: "/").map(String.init) : []
        // Every folder gone through, with its place: what the files in it share.
        var folders: [(path: String, place: String)] = [(folder, ([locationName] + relative).joined(separator: " › "))]
        let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_COMFOLLOW
        guard let fts = folder.withCString({ fts_open([UnsafeMutablePointer(mutating: $0), nil], options, nil) }) else { return }
        defer { fts_close(fts) }
        while let found = fts_read(fts) {
            let file = found.pointee
            let info = Int32(file.fts_info)
            // A folder that can't be read is shown, empty.
            let isDirectory = info == FTS_D || info == FTS_DNR
            guard isDirectory || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT, let stat = file.fts_statp?.pointee else { continue }
            func skip() { if isDirectory { fts_set(fts, found, FTS_SKIP) } }
            if file.fts_level == 0 {
                guard isDirectory else { return }
                found.pointee.fts_number = 0
                listed(folder)
                continue
            }
            let parent = folders[file.fts_parent.pointee.fts_number]
            let bytes = UnsafeRawPointer(file.fts_path).assumingMemoryBound(to: UInt8.self)
            var name = String(decoding: UnsafeBufferPointer(start: bytes + Int(file.fts_pathlen - file.fts_namelen), count: Int(file.fts_namelen)), as: UTF8.self)
            var inCloud = false
            if name.hasPrefix(".") {
                // Only in iCloud: a stand-in with the file's name between "." and ".icloud".
                guard !isDirectory, name.hasSuffix(".icloud"), name.count > 8 else {
                    skip()
                    continue
                }
                name = String(name.dropFirst().dropLast(7))
                inCloud = true
            }
            // Hidden as in the sidebar, like iCloud Drive's links to Desktop and Documents (indexed as folders of their own).
            if skippedFolders.contains(name) || (!inCloud && stat.st_flags & UInt32(UF_HIDDEN) != 0) {
                skip()
                continue
            }
            let path = inCloud ? parent.path + "/" + name : String(decoding: UnsafeBufferPointer(start: bytes, count: Int(file.fts_pathlen)), as: UTF8.self)
            var isFolder = isDirectory
            if isDirectory, name.contains("."), (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                isFolder = false
                skip()
            }
            // A file whose content is only in iCloud.
            if !isDirectory, stat.st_flags & UInt32(SF_DATALESS) != 0 { inCloud = true }
            if isFolder {
                if deep {
                    found.pointee.fts_number = folders.count
                    folders.append((path, parent.place + " › " + name))
                    listed(path)
                } else {
                    skip()
                }
            }
            let time = stat.st_mtimespec
            // As Foundation makes it, so dates read here and there compare equal.
            let modified = Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate + 1.0e-9 * Double(time.tv_nsec))
            let kind = FileKind(name: name, isDirectory: isFolder), size = isDirectory ? nil : Int(stat.st_size)
            let old = known.isEmpty ? nil : known[path]
            let entry = makeEntry(path: path, name: name, folder: parent.path, place: parent.place, locationID: locationID, kind: kind,
                                  modified: modified, size: size, inCloud: inCloud, known: old)
            each(entry, !(old?.isSame(as: entry) ?? false))
        }
    }

    /// The entry for a file: `known`, what the index had for it, if the file is as it was then; else read anew.
    nonisolated static func makeEntry(path: String, name fileName: String, folder: String, place: String, locationID: UUID, kind: FileKind,
                                      modified: Date?, size: Int?, inCloud: Bool, known: Entry? = nil) -> Entry {
        let url = known.flatMap { $0.kind == kind ? $0.url : nil } ?? URL(fileURLWithPath: path, isDirectory: kind == .folder)
        // Notes are kept on every device, so search and links work offline.
        if kind == .note, inCloud { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        if var entry = known, entry.isCurrent(kind: kind, modified: modified, size: size, inCloud: inCloud) {
            entry.place = place
            entry.locationID = locationID
            entry.isInCloud = inCloud
            return entry
        }
        let name = kind == .note ? FileKind.withoutExtension(fileName) : fileName
        var text: String?
        if kind == .note, !inCloud, (size ?? 0) < largestNote, let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8)
            #if DEBUG
            notesRead.add(1, ordering: .relaxed)
            #endif
        }
        var entry = Entry(url: url, name: name, kind: kind, place: place, locationID: locationID, modified: modified, size: size,
                          isInCloud: inCloud, text: text, folded: text.map(fold), foldedName: fold(name),
                          foldedFileName: fold(fileName), path: path, folder: folder)
        if let text {
            entry.headings = headings(in: text)
            entry.assets = FileOperations.assetNames(in: text).sorted()
        }
        return entry
    }

    /// A note's headings, as the outline shows them: without their Markdown, leaving out lines in code blocks and in
    /// front matter. Goes through the bytes, as it runs on every note in the locations.
    nonisolated static func headings(in text: String) -> [Heading] {
        var headings: [Heading] = []
        var fence: UInt8?
        var inFrontMatter = false
        var isFirst = true
        for line in text.utf8.split(separator: 10, omittingEmptySubsequences: false) {
            defer { isFirst = false }
            let indent = line.prefix { $0 == 32 }.count
            let rest = line.dropFirst(indent)
            let first = rest.first
            if isFirst, rest.starts(with: "---".utf8) {
                inFrontMatter = true
                continue
            }
            if inFrontMatter {
                if line.starts(with: "---".utf8) || line.starts(with: "...".utf8) { inFrontMatter = false }
                continue
            }
            // ``` or ~~~ open a code block, and the same close it.
            if let open = fence {
                if first == open, rest.prefix(3).allSatisfy({ $0 == open }), rest.count >= 3 { fence = nil }
                continue
            }
            if first == 96 || first == 126, rest.count >= 3, rest.prefix(3).allSatisfy({ $0 == first }) {
                fence = first
                continue
            }
            guard first == 35, indent < 4 else { continue }
            let level = rest.prefix { $0 == 35 }.count
            let after = rest.dropFirst(level)
            guard level <= 6, after.first == 32 || after.first == 9 else { continue }
            var title = String(decoding: after, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            // Closing #s, as in "## Plan ##".
            while title.hasSuffix("#") { title.removeLast() }
            title = plainMarkdown(title.trimmingCharacters(in: .whitespaces))
            if !title.isEmpty { headings.append(Heading(level: level, title: title)) }
        }
        return headings
    }

    /// Words without the Markdown in them, as they read in the note: `**Plan** for [[Kyoto]]` reads "Plan for Kyoto",
    /// a picture its description or file name, a link its text.
    nonisolated static func plainMarkdown(_ text: String) -> String {
        var text = text
        // ![description](address) reads as the description, or else the file's name; [text](address) as the text.
        while let open = text.range(of: "]("), let close = text[open.upperBound...].firstIndex(of: ")"),
              let start = text[..<open.lowerBound].lastIndex(of: "[") {
            var shown = String(text[text.index(after: start)..<open.lowerBound])
            var from = start
            if start > text.startIndex, text[text.index(before: start)] == "!" {
                from = text.index(before: start)
                if shown.isEmpty {
                    let address = String(text[open.upperBound..<close])
                    shown = (address.removingPercentEncoding ?? address).split(separator: "/").last.map(String.init) ?? address
                }
            }
            text.replaceSubrange(from...close, with: shown)
        }
        // [[note|shown]] reads as what it shows, ![[file]] as the file.
        while let open = text.range(of: "[["), let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            let inside = text[open.upperBound..<close.lowerBound]
            let shown = inside.split(separator: "|", maxSplits: 1).last ?? inside
            let from = open.lowerBound > text.startIndex && text[text.index(before: open.lowerBound)] == "!" ? text.index(before: open.lowerBound) : open.lowerBound
            text.replaceSubrange(from..<close.upperBound, with: shown)
        }
        for mark in ["**", "__", "==", "~~", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The names a link finds a file by: a note's with and without ".md", any other file's in full. None for folders.
    nonisolated static func nameKeys(of entry: Entry) -> [String] {
        switch entry.kind {
        case .folder: []
        case .note: entry.foldedName == entry.foldedFileName ? [entry.foldedName] : [entry.foldedName, entry.foldedFileName]
        default: [entry.foldedFileName]
        }
    }

    /// Reads the files in some folders again, after changes there: in the background, then merged in by the files that
    /// changed. Folders among them that are `deep` (renamed or moved, under their new address) are read with every
    /// folder in them.
    func refresh(folders: [URL], deep: [URL] = [], locations: [Location]) {
        self.locations = locations
        if isBuilding { changedWhileBuilding.formUnion(folders) }
        let paths = Set(folders.map { $0.standardizedFileURL.path })
        let jobs: [(folder: URL, root: URL, place: String, locationID: UUID)] = paths.compactMap { path in
            for location in locations {
                if let base = location.folder(containing: path) { return (URL(fileURLWithPath: path), base.url, base.place, location.id) }
            }
            return nil
        }
        guard !jobs.isEmpty else { return }
        refreshes += 1
        let id = refreshes
        for job in jobs { newestRefresh[job.folder.path] = id }
        let generation = generation
        let deep = Set(deep.map { $0.standardizedFileURL.path })
        // Files as they were aren't read again.
        let known = byPath
        Task.detached(priority: .utility) {
            var updates: [(folder: String, entries: [Entry])] = []
            for (folder, root, place, locationID) in jobs {
                // A folder that is gone lists nothing: it is taken out by reading the one it was in.
                var listed: [String] = []
                var found: [String: [Entry]] = [:]
                Self.walk(folder.path, root: root.path, locationName: place, locationID: locationID, deep: deep.contains(folder.path), known: known,
                          listed: { listed.append($0) }) { entry, _ in found[entry.folder, default: []].append(entry) }
                updates += listed.map { ($0, found[$0] ?? []) }
            }
            let scanned = updates
            await MainActor.run {
                guard generation == self.generation else { return }
                var pdfs: [PDFJob] = []
                var changed: [String: Entry] = [:]
                var removed = false
                let folders = self.folderPaths.count
                // Folders found in a deep one were asked for by nobody else, unless since.
                for (folder, found) in scanned where self.newestRefresh[folder] ?? id == id {
                    self.newestRefresh[folder] = nil
                    let merged = self.merge(found, into: folder)
                    pdfs += merged.pdfs
                    removed = removed || merged.removed
                    for entry in merged.changed { changed[entry.path] = entry }
                }
                if !changed.isEmpty { self.onIndexed?(changed) }
                // Folders read again as they were, as when the app comes back to the front, change nothing.
                if !changed.isEmpty || removed {
                    self.changed()
                    self.entriesChanged()
                }
                if self.foldersChanged || self.folderPaths.count != folders {
                    self.foldersChanged = false
                    self.folderVersion += 1
                    self.onFoldersChanged?()
                }
                self.readPDFs(pdfs)
                self.onRefreshed?()
            }
        }
    }

    /// Puts what is in a folder now in place of what was, and says which PDFs need their text read, which files are new
    /// or changed, and whether any went.
    private func merge(_ found: [Entry], into folder: String) -> (pdfs: [PDFJob], changed: [Entry], removed: Bool) {
        let paths = Set(found.map(\.path))
        // What was in the folder and is gone, with everything inside a folder that is gone.
        let gone = (byFolder[folder] ?? []).subtracting(paths)
        for path in gone { remove(path) }
        var pdfs: [PDFJob] = []
        var changed: [Entry] = []
        for entry in found {
            // A PDF as it was has its text already (`walk`).
            if entry.kind == .pdf, entry.text == nil, !entry.isInCloud {
                pdfs.append(PDFJob(url: entry.url, path: entry.path, modified: entry.modified))
            }
            let old = byPath.updateValue(entry, forKey: entry.path)
            if old.map({ !$0.isSame(as: entry) }) ?? true { changed.append(entry) }
            if old?.kind != entry.kind {
                if let old { forget(old) }
                for key in Self.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
                if entry.kind == .folder { folderPaths.insert(entry.path) }
            }
        }
        byFolder[folder] = paths.isEmpty ? nil : paths
        return (pdfs, changed, !gone.isEmpty)
    }

    private func remove(_ path: String) {
        if let entry = byPath.removeValue(forKey: path) { forget(entry) }
        for inside in byFolder.removeValue(forKey: path) ?? [] { remove(inside) }
    }

    /// Takes a file that is gone, or is something else now, out of the lookups by name and of the folders.
    private func forget(_ entry: Entry) {
        for key in Self.nameKeys(of: entry) {
            byName[key]?.remove(entry.path)
            if byName[key]?.isEmpty == true { byName[key] = nil }
        }
        if entry.kind == .folder, folderPaths.remove(entry.path) != nil { foldersChanged = true }
    }

    // MARK: - PDFs

    private struct PDFJob: Sendable {
        var url: URL
        var path: String
        var modified: Date?
    }

    @ObservationIgnored private var pdfQueue: [PDFJob] = []
    @ObservationIgnored private var pdfTask: Task<Void, Never>?
    nonisolated private static let pdfCache = PDFTextCache()

    /// Reads the text of PDFs in the background, one at a time, so search finds what is in them.
    private func readPDFs(_ jobs: [PDFJob]) {
        pdfQueue += jobs
        guard pdfTask == nil, !pdfQueue.isEmpty else { return }
        pdfTask = Task { [weak self] in
            while let job = self?.nextPDF() {
                let read = await Task.detached(priority: .background) { Self.text(of: job) }.value
                guard let self else { return }
                guard let read, var entry = byPath[job.path], entry.modified == job.modified else { continue }
                entry.text = read.text
                entry.folded = read.folded
                entry.pagesWithoutText = read.pagesWithoutText
                byPath[job.path] = entry
                changed(notes: false)
                entriesChanged()
                if !read.pagesWithoutText.isEmpty { onIndexed?([job.path: entry]) }
            }
            self?.pdfTask = nil
            // All read: kept soon, so a launch shortly after needn't read them again.
            if self?.unsavedSince != nil { self?.entriesChanged(quiet: .seconds(2)) }
        }
    }

    /// Whether the text of PDFs is being read.
    var isReadingPDFs: Bool { pdfTask != nil }

    private func nextPDF() -> PDFJob? {
        pdfQueue.isEmpty ? nil : pdfQueue.removeFirst()
    }

    nonisolated private static func text(of job: PDFJob) -> PDFText? {
        if let cached = pdfCache.text(for: job.path, modified: job.modified) { return cached }
        guard let document = PDFDocument(url: job.url) else { return nil }
        var pages: [String] = []
        var empty: [Int] = []
        for index in 0..<min(document.pageCount, 300) {
            let text = document.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { empty.append(index) }
            pages.append(text)
        }
        // Pages are separated by form feeds so a hit can say which page it is on.
        let text = pages.joined(separator: "\u{0C}")
        let read = PDFText(text: text, folded: fold(text), pagesWithoutText: empty)
        pdfCache.keep(read, for: job.path, modified: job.modified)
        return read
    }

    /// Called with files found or read again, so the text in pictures, scans and drawings among them can be read.
    @ObservationIgnored var onIndexed: (([String: Entry]) -> Void)?

    // MARK: - Kept between launches

    /// Where the index is kept between launches (`KeptIndex`); nil to keep nothing.
    @ObservationIgnored var storeURL: URL?
    /// The index kept from the last run, read in the background, until the first build has taken it.
    @ObservationIgnored private var kept: Task<Lookups?, Never>?
    /// When the files first changed since the index was last kept.
    @ObservationIgnored private var unsavedSince: ContinuousClock.Instant?
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    /// The last writing of the index, which the next one waits for, so an older one never ends up on disk.
    @ObservationIgnored private(set) var lastSave: Task<Void, Never>?

    /// Where the index is kept: in the app's caches, as it can always be made again. A folder given on the command line
    /// (`library`) gets a file of its own, so a run on the sample notes leaves the one for your locations alone. None
    /// in tests, which keep theirs where they say.
    nonisolated static func storeURL(library: String? = nil, name: String = "Search index", in directory: FileManager.SearchPathDirectory = .cachesDirectory) -> URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notebook", isDirectory: true)
        guard let library else { return folder.appendingPathComponent(name) }
        return folder.appendingPathComponent(name + " " + String(stableHash(library), radix: 36))
    }

    /// FNV-1a: the same for the same string at every launch, as Swift's own hashes aren't.
    nonisolated static func stableHash(_ string: String, from start: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        string.utf8.reduce(start) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// Starts reading the index kept from the last run, for the first build to show at once and to check the files
    /// against. In the background, while the locations are looked up.
    func loadKept(for locations: [Location]) {
        guard let storeURL, kept == nil, !hasBuilt else { return }
        let roots = locations.map { (id: $0.id, path: $0.url.path) }
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        kept = Task.detached(priority: .userInitiated) { [weak self] in
            guard let entries = KeptIndex.read(storeURL, locations: roots) else {
                #if DEBUG
                await self?.log("no kept index")
                #endif
                return nil
            }
            #if DEBUG
            let read = CACurrentMediaTime()
            #endif
            let lookups = Lookups(all: entries)
            #if DEBUG
            await self?.log(String(format: "read the kept index of %d files in %.0f ms, and made its lookups in %.0f ms", entries.count,
                                   (read - started) * 1000, (CACurrentMediaTime() - read) * 1000))
            #endif
            return lookups
        }
    }

    /// Keeps the files on disk once they have stopped changing for a while (`quiet`), or a couple of minutes after they
    /// first changed while they keep changing: writing them all takes a moment, and what wasn't kept is only read again
    /// at the next launch.
    private func entriesChanged(quiet: Duration = .seconds(10)) {
        guard storeURL != nil else { return }
        let now = ContinuousClock.now
        let since = unsavedSince ?? now
        unsavedSince = since
        let due = min(now + quiet, since + .seconds(120))
        saveTimer?.cancel()
        saveTimer = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Keeps what changed since the index was last kept, now: when the app goes to the background, where it may be
    /// stopped before long.
    func keepChanges() {
        if unsavedSince != nil { save() }
    }

    /// Writes the files in the background, one writing after another. Not before they have been read since launch, nor
    /// while they are read again: that keeps them when it is done.
    func save() {
        guard let storeURL, hasBuilt, !isBuilding else { return }
        saveTimer?.cancel()
        saveTimer = nil
        unsavedSince = nil
        let entries = byPath, roots = locations.map { (id: $0.id, path: $0.url.path) }, previous = lastSave
        #if os(iOS)
        // Written even when the app goes to the background right now.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Keeping the search index")
        #endif
        lastSave = Task.detached(priority: .utility) {
            await previous?.value
            #if DEBUG
            let started = CACurrentMediaTime()
            #endif
            try? KeptIndex.write(entries.values, locations: roots, to: storeURL)
            #if DEBUG
            let size = (try? storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            await self.log(String(format: "kept %d files (%.1f MB) in %.0f ms", entries.count, Double(size) / 1_000_000, (CACurrentMediaTime() - started) * 1000))
            #endif
            #if os(iOS)
            await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            #endif
        }
    }

    #if DEBUG
    /// Notes read from disk since launch, for the debug remote and the benchmark.
    nonisolated static let notesRead = Atomic<Int>(0)
    /// What the last build read: notes, and PDFs whose text it left to read.
    @ObservationIgnored private(set) var lastBuild = (notesRead: 0, pdfs: 0)
    /// What building and keeping the index did, with when since the app started, for the debug remote.
    @ObservationIgnored private(set) var history: [String] = []
    @ObservationIgnored private var loggedCorpora = 0

    /// When the app started, from the system: what a person waits for counts from there.
    private static let launch: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    private func log(_ message: String) {
        history.append(String(format: "%.2f s: ", Date().timeIntervalSince(Self.launch)) + message)
        if history.count > 40 { history.removeFirst() }
    }
    #endif

    // MARK: - Search

    /// Puts a new corpus in place and runs the searches on screen again on it.
    private func show(_ new: SearchCorpus) {
        // The old one goes away on another thread: freeing the text of thousands of notes takes a while too.
        let old = corpus
        corpus = new
        #if DEBUG
        if loggedCorpora < 3, !new.items.isEmpty {
            loggedCorpora += hasBuilt ? 3 : 1
            log("search has \(new.items.count) files and \(new.documents.count) texts")
        }
        #endif
        DispatchQueue.global(qos: .background).async { withExtendedLifetime(old) {} }
        corpusObservers.removeAll { $0.search == nil }
        for observer in corpusObservers { observer.search?.corpusChanged() }
    }

    /// Makes a new corpus in the background once the one being made is done: after a burst of changes, one for all.
    private func scheduleCorpus() {
        corpusWanted = true
        guard corpusTask == nil else { return }
        corpusWanted = false
        let version = version, entries = byPath, hidden = hiddenPaths, recognized = recognized
        corpusTask = Task.detached(priority: .userInitiated) { [weak self] in
            let corpus = SearchCorpus(version: version, entries: entries.values, hidden: hidden, recognized: recognized)
            await self?.made(corpus, fromNothing: entries.isEmpty)
        }
    }

    private func made(_ corpus: SearchCorpus, fromNothing: Bool) {
        corpusTask = nil
        // Nothing while the files are read the first time: what has been read so far shows meanwhile.
        if !fromNothing || !isBuilding { show(corpus) }
        if corpusWanted { scheduleCorpus() }
    }

    /// The corpus for what the index knows now, made here if the one made in the background isn't there yet. For
    /// tests and the few answers that can't wait; search itself takes `corpus` as it is.
    func currentCorpus() -> SearchCorpus {
        if corpus.version != version {
            show(SearchCorpus(version: version, entries: byPath.values, hidden: hiddenPaths, recognized: recognized))
        }
        return corpus
    }

    /// Runs `search` again whenever there is a new corpus, for as long as it is around.
    func observeCorpus(_ search: SearchSession) {
        corpusObservers.removeAll { $0.search == nil || $0.search === search }
        corpusObservers.append(WeakSearch(search: search))
    }

    private struct WeakSearch {
        weak var search: SearchSession?
    }

    public func entry(for url: URL) -> Entry? {
        _ = version
        return byPath[url.standardizedFileURL.path]
    }

    /// The file a `[[link]]` means: by name (".md" for notes left out), nearest to the note it is in first.
    public func resolve(_ target: String, from note: URL?) -> URL? {
        _ = version
        return Self.resolve(target, from: note, byName: byName, byPath: byPath)?.url
    }

    /// What every file is and where, as `resolve` reads it: for working out off the main thread where links point
    /// before and after files move (`LinkUpdate`).
    var linkTargets: LinkTargets { LinkTargets(byPath: byPath, byName: byName) }

    /// `resolve`, in lookups that can be the index's or a copy of them as they are after files moved.
    nonisolated static func resolve(_ target: String, from note: URL?, byName: [String: Set<String>], byPath: [String: Entry]) -> Entry? {
        var name = target
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let folded = fold(name)
        let pathPart = folded.contains("/") ? folded : nil
        let baseName = pathPart.map { String($0.split(separator: "/").last ?? "") } ?? folded
        let candidates = (byName[baseName] ?? []).compactMap { byPath[$0] }.filter { entry in
            if let pathPart {
                let path = fold(entry.url.deletingPathExtension().path)
                return path.hasSuffix("/" + pathPart) || fold(entry.url.path).hasSuffix("/" + pathPart)
            }
            return true
        }
        let folder = note?.deletingLastPathComponent().standardizedFileURL.path
        // Nearest the note first: in its folder, then the least deep; then by address, to always pick the same.
        return candidates.min { a, b in
            let aSame = a.folder == folder
            let bSame = b.folder == folder
            if aSame != bSame { return aSame }
            let aDepth = a.url.pathComponents.count, bDepth = b.url.pathComponents.count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.path < b.path
        }
    }

    /// Notes and files whose names match, best first: names starting with the query, then words starting with it,
    /// then containing it, then having its letters in order.
    public func files(matching query: String, limit: Int = 8) -> [Entry] {
        guard let query = SearchCorpus.Query(query) else { return [] }
        let corpus = currentCorpus()
        return corpus.matchNames(query, files: limit, folders: 0).files.compactMap { byPath[corpus.items[$0].url.path] }
    }

    /// Every folder, in no particular order, hidden ones too: for Move To.
    func allFolders() -> [(url: URL, name: String, path: String)] {
        _ = folderVersion
        return folderPaths.compactMap { path in byPath[path].map { ($0.url, $0.name, path) } }
    }

    public func folders(matching query: String, limit: Int = 12) -> [Entry] {
        guard let query = SearchCorpus.Query(query) else { return [] }
        let corpus = currentCorpus()
        return corpus.matchNames(query, files: 0, folders: limit).folders.compactMap { byPath[corpus.items[$0].url.path] }
    }

    /// Notes and PDFs that have the words in them, with the line they are in.
    func textHits(_ query: String, limit: Int = 8) -> [SearchCorpus.TextHit] {
        guard let query = SearchCorpus.Query(query) else { return [] }
        var limits = SearchCorpus.Limits(files: 0, folders: 0, headings: 0, texts: limit, pictures: 0)
        limits.texts = limit
        return currentCorpus().search(query, limits: limits).texts
    }

    /// In a hidden folder, or one itself.
    func isHidden(_ url: URL) -> Bool {
        Self.isHidden(url.path, in: hiddenPaths)
    }

    nonisolated static func isHidden(_ path: String, in hiddenPaths: [String]) -> Bool {
        guard !hiddenPaths.isEmpty else { return false }
        let path = HiddenFolders.withoutPrivate(path)
        return hiddenPaths.contains { folder in
            let folder = HiddenFolders.withoutPrivate(folder)
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    nonisolated static func score(_ name: String, _ query: String) -> Int? {
        if name == query { return 100 }
        if query.isEmpty { return 80 }
        if let offset = offset(of: query, in: name) {
            guard offset > 0 else { return 80 }
            let before = name.utf8[name.utf8.index(name.utf8.startIndex, offsetBy: offset - 1)]
            return before == UInt8(ascii: " ") || before == UInt8(ascii: "-") || before == UInt8(ascii: "_") ? 60 : 40
        }
        var letters = name.unicodeScalars.makeIterator()
        for wanted in query.unicodeScalars {
            while true {
                guard let letter = letters.next() else { return nil }
                if letter == wanted { break }
            }
        }
        return 10
    }

    /// Where `query` is in `text`, in bytes. Both are folded alike, so their bytes match where their letters do; this
    /// is far faster than String's own search, and it runs on every file for every letter typed.
    nonisolated static func offset(of query: String, in text: String) -> Int? {
        var text = text, query = query
        return text.withUTF8 { text in
            query.withUTF8 { query -> Int? in
                guard !query.isEmpty, query.count <= text.count, let start = text.baseAddress,
                      let found = memmem(start, text.count, query.baseAddress, query.count) else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(start)
            }
        }
    }

    /// What `[[query` could link to. Goes through the corpus as it is, even if a moment behind, so typing never waits.
    func linkSuggestions(_ query: String, from note: URL?) -> [LinkSuggestion] {
        var items: [LinkSuggestion] = []
        let current = note?.standardizedFileURL.path
        let candidates: [SearchCorpus.Item]
        if let parsed = SearchCorpus.Query(query) {
            candidates = corpus.matchNames(parsed, files: 8, folders: 0).files.map { corpus.items[$0] }.filter { $0.url.path != current }.prefix(7).map { $0 }
        } else {
            var newest = SearchCorpus.Best(6)
            for (index, item) in corpus.items.enumerated() where item.kind == .note && item.url.path != current {
                newest.add(SearchCorpus.Candidate(score: 0, modified: item.modified, path: item.url.path, index: index))
            }
            candidates = newest.items.map { corpus.items[$0.index] }
        }
        for item in candidates {
            let isNote = item.kind == .note
            let title = isNote ? item.name : item.url.lastPathComponent
            items.append(LinkSuggestion(kind: isNote ? .note : .file, title: title,
                                        detail: item.place.split(separator: "›").suffix(2).joined(separator: "›").trimmingCharacters(in: .whitespaces), insert: title))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !items.contains(where: { Self.fold($0.title) == Self.fold(trimmed) }) {
            let folder = note.map { $0.deletingLastPathComponent().lastPathComponent } ?? ""
            items.append(LinkSuggestion(kind: .create, title: "New note “\(trimmed)”", detail: folder.isEmpty ? "" : "in \(folder)", insert: trimmed))
        }
        return items
    }
}

struct PDFText: Sendable {
    var text: String
    var folded: String
    var pagesWithoutText: [Int]
}

/// The text of PDFs read before, kept for as long as the app runs, for any thread.
private final class PDFTextCache: Sendable {
    private let texts = Mutex<[String: (modified: Date?, read: PDFText)]>([:])

    func text(for path: String, modified: Date?) -> PDFText? {
        texts.withLock { texts in
            guard let cached = texts[path], cached.modified == modified else { return nil }
            return cached.read
        }
    }

    func keep(_ read: PDFText, for path: String, modified: Date?) {
        texts.withLock { $0[path] = (modified, read) }
    }
}
