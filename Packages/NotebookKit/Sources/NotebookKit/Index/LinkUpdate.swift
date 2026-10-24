import Foundation

/// Every file links can point at and where it is, as the index knew them at one moment (`SearchIndex.linkTargets`):
/// a copy, for working out off the main thread what links meant before files moved and what they mean after.
struct LinkTargets: Sendable {
    var byPath: [String: SearchIndex.Entry]
    var byName: [String: Set<String>]

    static let empty = LinkTargets(byPath: [:], byName: [:])

    /// What a `[[link]]` in a note means, by the same rules as everywhere else (`SearchIndex.resolve`).
    func resolve(_ target: String, from note: URL?) -> SearchIndex.Entry? {
        SearchIndex.resolve(target, from: note, byName: byName, byPath: byPath)
    }

    /// The file at an address, in either form the system gives it ("/private/var/…" and "/var/…").
    func entry(for url: URL) -> SearchIndex.Entry? { entry(atPath: url.standardizedFileURL.path) }

    func entry(atPath path: String) -> SearchIndex.Entry? {
        if let entry = byPath[path] { return entry }
        let plain = HiddenFolders.withoutPrivate(path)
        return byPath[plain] ?? byPath["/private" + plain]
    }

    /// The files in folders, and with `deep` in every folder in them, read from the disk: for a note from outside the
    /// locations, which the index doesn't know, before the index has read the locations, and for tests.
    static func reading(_ folders: URL..., deep: Bool) -> LinkTargets {
        reading(folders, deep: deep)
    }

    static func reading(_ folders: [URL], deep: Bool) -> LinkTargets {
        var targets = LinkTargets.empty
        for folder in folders {
            SearchIndex.walk(folder.path, root: folder.path, locationName: "", locationID: UUID(), deep: deep) { entry, _ in
                targets.add(entry)
            }
        }
        return targets
    }

    /// As they are once `moves` have been made, one after another: files renamed or moved, and everything in a folder
    /// with it.
    func moving(_ moves: [LinkUpdate.Move]) -> LinkTargets {
        var targets = self
        for move in moves { targets.apply(move, settling: false) }
        return targets
    }

    /// With files Notebook renamed or moved a moment ago where they went, however far the index has got in reading
    /// their folders again: those still at their old address go to the new one, and where the index already has them
    /// at the new one, the old entries go.
    func settled(_ recent: [LinkUpdate.Move]) -> LinkTargets {
        var targets = self
        for move in recent { targets.apply(move, settling: true) }
        return targets
    }

    /// With the text of some notes, by their paths, in place of what the index read.
    func withTexts(_ texts: [String: String]) -> LinkTargets {
        var targets = self
        for (path, text) in texts {
            guard var entry = entry(atPath: path), entry.kind == .note else { continue }
            entry.text = text
            entry.folded = SearchIndex.fold(text)
            targets.byPath[entry.path] = entry
        }
        return targets
    }

    private mutating func apply(_ move: LinkUpdate.Move, settling: Bool) {
        let from = HiddenFolders.withoutPrivate(move.from.standardizedFileURL.path)
        let to = HiddenFolders.withoutPrivate(move.to.standardizedFileURL.path)
        guard from != to else { return }
        let moved = byPath.keys.filter { key in
            let plain = HiddenFolders.withoutPrivate(key)
            return plain == from || plain.hasPrefix(from + "/")
        }
        var arrived: [SearchIndex.Entry] = []
        for key in moved {
            guard var entry = remove(key) else { continue }
            let path = Workspace.relocated(key, from: from, to: to)
            if settling, self.entry(atPath: path) != nil { continue }
            entry.path = path
            entry.url = URL(fileURLWithPath: path, isDirectory: entry.kind == .folder)
            entry.folder = (path as NSString).deletingLastPathComponent
            // The file or folder itself may have a new name; what is in a folder keeps its own.
            if HiddenFolders.withoutPrivate(key) == from {
                let fileName = (path as NSString).lastPathComponent
                entry.name = entry.kind == .note ? FileKind.withoutExtension(fileName) : fileName
                entry.foldedName = SearchIndex.fold(entry.name)
                entry.foldedFileName = SearchIndex.fold(fileName)
            }
            arrived.append(entry)
        }
        for entry in arrived { add(entry) }
    }

    private mutating func add(_ entry: SearchIndex.Entry) {
        byPath[entry.path] = entry
        for key in SearchIndex.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
    }

    private mutating func remove(_ path: String) -> SearchIndex.Entry? {
        guard let entry = byPath.removeValue(forKey: path) else { return nil }
        for key in SearchIndex.nameKeys(of: entry) {
            byName[key]?.remove(path)
            if byName[key]?.isEmpty == true { byName[key] = nil }
        }
        return entry
    }
}

/// A link rewritten in a note: what its address said, and says now. For a `[[link]]` the address is the part
/// before `#` and `|`, for a Markdown link or picture what is between the parentheses.
struct LinkEdit: Sendable, Equatable {
    enum Kind: Sendable { case wiki, markdown }
    var kind: Kind
    var old: String
    var new: String
}

/// A link to change, where its address is in the note's text.
struct LinkChange: Sendable {
    var range: NSRange
    var edit: LinkEdit
}

/// The links rewritten in one note, by where the note is once the files have moved.
struct NoteLinkEdits: Sendable {
    var note: URL
    var edits: [LinkEdit]
}

/// Links that keep pointing at the same note or file when Notebook renames or moves files. A link is rewritten only
/// when after the move it would point somewhere else, or nowhere, and then as short as it can be, as Obsidian does:
/// `[[Name]]` when the name finds it, else with as many of its folders in front as it takes. That covers links to
/// the files moved (and to everything in a folder moved), links to other files of the same name that one moved now
/// comes before, and the links in the notes moved, whose own folder is another now. Links to nothing stay as they are.
struct LinkUpdate: Sendable {
    struct Move: Sendable, Equatable {
        var from: URL
        var to: URL

        var reversed: Move { Move(from: to, to: from) }
    }

    let before: LinkTargets
    let after: LinkTargets
    let moves: [Move]

    init(before: LinkTargets, moves: [Move]) {
        self.before = before
        self.moves = moves
        after = before.moving(moves)
    }

    /// Where a file is once the files have moved.
    func relocated(_ url: URL) -> URL {
        moves.reduce(url) { Workspace.relocated($0, from: $1.from, to: $1.to) }
    }

    func relocated(_ path: String) -> String {
        moves.reduce(path) { Workspace.relocated($0, from: $1.from.standardizedFileURL.path, to: $1.to.standardizedFileURL.path) }
    }

    /// Where a file was before they moved.
    func original(_ url: URL) -> URL {
        moves.reversed().reduce(url) { Workspace.relocated($0, from: $1.to, to: $1.from) }
    }

    private func isMoved(_ path: String) -> Bool {
        let plain = HiddenFolders.withoutPrivate(path)
        return moves.contains { move in
            let from = HiddenFolders.withoutPrivate(move.from.standardizedFileURL.path)
            return plain == from || plain.hasPrefix(from + "/")
        }
    }

    // MARK: - Which notes

    /// The notes whose links change, by where they are once the files have moved, as far as the index's text of them
    /// tells: the notes moved and those with a link by the name of a file moved, of which only those whose links
    /// would point somewhere else. The text of notes the index hasn't read (still in iCloud) is unknown: they come
    /// apart, to be read. Goes through what the index has, not the disk.
    func notesToChange() -> (changing: [URL], unread: [URL]) {
        var names = Set<String>()
        for entry in before.byPath.values where isMoved(entry.path) {
            names.insert(entry.foldedName)
            names.insert(entry.foldedFileName)
            if let moved = after.entry(atPath: relocated(entry.path)) {
                names.insert(moved.foldedName)
                names.insert(moved.foldedFileName)
            }
        }
        var changing: [URL] = []
        var unread: [URL] = []
        for entry in before.byPath.values where entry.kind == .note {
            let note = relocated(entry.url)
            guard let text = entry.text, let folded = entry.folded else {
                if (entry.size ?? 0) < SearchIndex.largestNote { unread.append(note) }
                continue
            }
            guard isMoved(entry.path) || !Self.linkedNames(in: folded).isDisjoint(with: names) else { continue }
            if rewrite(text, of: note) != nil { changing.append(note) }
        }
        return (changing, unread)
    }

    /// The names a text's links go by, folded as the index folds the text: the last part of each `[[link]]`'s
    /// address and of each Markdown link's. Read in a hurry, without the Markdown: it only says where to look closer.
    static func linkedNames(in folded: String) -> Set<String> {
        var names = Set<String>()
        var text = folded
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            let count = bytes.count
            func name(_ start: Int, _ end: Int) -> String {
                var name = String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                while name.hasSuffix("/") { name.removeLast() }
                return name.split(separator: "/").last.map(String.init) ?? name
            }
            let (open, close, bar, hash, parenthesis, closeParenthesis) = (UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "|"), UInt8(ascii: "#"), UInt8(ascii: "("), UInt8(ascii: ")"))
            var i = 0
            while i + 1 < count {
                if bytes[i] == open, bytes[i + 1] == open {
                    var j = i + 2
                    while j < count, bytes[j] != close, bytes[j] != bar, bytes[j] != hash, bytes[j] != 10 { j += 1 }
                    names.insert(name(i + 2, j))
                    i = j
                } else if bytes[i] == close, bytes[i + 1] == parenthesis {
                    var j = i + 2
                    while j < count, bytes[j] != closeParenthesis, bytes[j] != 10, bytes[j] != hash { j += 1 }
                    var address = name(i + 2, j)
                    if address.hasPrefix("<") { address.removeFirst() }
                    if address.hasSuffix(">") { address.removeLast() }
                    names.insert(SearchIndex.fold(address.removingPercentEncoding ?? address))
                    i = j
                } else {
                    i += 1
                }
            }
        }
        return names
    }

    // MARK: - Rewriting

    /// A note's text with its links pointing where they pointed before the files moved, and what changed; nil when
    /// none had to. `note` is where the note is now.
    func rewrite(_ text: String, of note: URL) -> (text: String, edits: [LinkEdit])? {
        let string = text as NSString
        let changes = linkChanges(in: string, of: note)
        guard !changes.isEmpty else { return nil }
        return (Self.applying(changes, to: string), changes.map(\.edit))
    }

    /// The links in a note that have to change, where they are in its text.
    func linkChanges(in string: NSString, of note: URL) -> [LinkChange] {
        // In the index's form of its address, which its folder is compared by.
        let note = after.entry(for: note)?.url ?? note
        let noteBefore = original(note)
        var changes: [LinkChange] = []
        for link in Self.links(in: string) {
            let old = string.substring(with: link.address)
            let new: String? = switch link.kind {
            case .wiki: newWikiAddress(old, from: noteBefore, to: note)
            case .markdown: newMarkdownAddress(old, angled: link.angled, from: noteBefore, to: note)
            }
            guard let new, new != old else { continue }
            changes.append(LinkChange(range: link.address, edit: LinkEdit(kind: link.kind, old: old, new: new)))
        }
        return changes
    }

    /// Whether the files were known to the index, as a note has to be for its links to be read the index's way: a
    /// note from outside the locations finds only the notes next to it.
    func knows(_ note: URL) -> Bool {
        before.entry(for: original(note)) != nil
    }

    /// What a `[[link]]`'s address becomes: nil when it still finds what it found, or found nothing.
    private func newWikiAddress(_ address: String, from noteBefore: URL, to note: URL) -> String? {
        guard let target = before.resolve(address, from: noteBefore) else { return nil }
        let path = relocated(target.path)
        if let now = after.resolve(address, from: note), Self.samePath(now.path, path) { return nil }
        guard let moved = after.entry(atPath: path) else { return nil }
        return shortestAddress(to: moved, from: note, like: address)
    }

    /// The shortest address that finds `target` from `note`: its name as the link wrote it, unless the file was
    /// renamed, with as many of its folders in front as it takes.
    private func shortestAddress(to target: SearchIndex.Entry, from note: URL, like old: String) -> String? {
        let oldName = old.split(separator: "/").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? old
        let folded = SearchIndex.fold(oldName)
        let name: String
        if folded == target.foldedName || folded == target.foldedFileName {
            name = oldName
        } else {
            // Renamed: the new name, with ".md" when the link had it.
            let fileName = (target.path as NSString).lastPathComponent
            let hadExtension = target.kind == .note && ["md", "markdown"].contains((folded as NSString).pathExtension)
            name = target.kind == .note && !hadExtension ? target.name : fileName
        }
        let folders = (target.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for count in 0...folders.count {
            let address = (folders.suffix(count) + [name]).joined(separator: "/")
            if let found = after.resolve(address, from: note), Self.samePath(found.path, target.path) { return address }
        }
        return nil
    }

    /// What a Markdown link's or picture's address becomes, when it is a file next to the note or in a folder near
    /// it: the way from the note's folder now to where the file is now. Web addresses, places in the note, and the
    /// note's own pictures in `.assets` (which go along with a note that moves) stay.
    private func newMarkdownAddress(_ address: String, angled: Bool, from noteBefore: URL, to note: URL) -> String? {
        if let url = URL(string: address), let scheme = url.scheme, scheme.count > 1 { return nil }
        guard !address.hasPrefix("#"), !address.hasPrefix("/") else { return nil }
        var path = address
        var fragment = ""
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[hash...])
            path = String(path[..<hash])
        }
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty, !decoded.hasPrefix(".assets/"), !decoded.hasPrefix("./.assets/") else { return nil }
        let target = noteBefore.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
        let moved = relocated(target)
        let folder = note.deletingLastPathComponent()
        if Self.samePath(folder.appendingPathComponent(decoded).standardizedFileURL.path, moved.path) { return nil }
        // Only a link to something that is there.
        guard before.entry(for: target) != nil || after.entry(for: moved) != nil || FileManager.default.fileExists(atPath: moved.path) else { return nil }
        var relative = Self.relativePath(from: folder, to: moved)
        guard !relative.isEmpty else { return nil }
        if decoded.hasSuffix("/") { relative += "/" }
        let encode = !angled && (path.contains("%") || relative.contains { " ()<>%".contains($0) })
        return (encode ? Self.encoded(relative) : relative) + fragment
    }

    static func relativePath(from folder: URL, to target: URL) -> String {
        let from = HiddenFolders.withoutPrivate(folder.standardizedFileURL.path).split(separator: "/")
        let to = HiddenFolders.withoutPrivate(target.standardizedFileURL.path).split(separator: "/")
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...].map(String.init)).joined(separator: "/")
    }

    /// A path for Markdown, as Notebook writes the addresses of pictures (`EditorController.markdownPath`).
    static func encoded(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        HiddenFolders.withoutPrivate(a) == HiddenFolders.withoutPrivate(b)
    }

    // MARK: - Undo

    /// Puts the addresses a rewrite changed back (`undoing`), or changes them again: each link that says what the
    /// rewrite made it say, once for every link it changed. Links that say the same find the same file, so it doesn't
    /// matter which of them is which. Nil when no link says that any more.
    static func replay(_ edits: [LinkEdit], in text: String, undoing: Bool) -> (text: String, edits: [LinkEdit])? {
        let string = text as NSString
        let changes = replayChanges(edits, in: string, undoing: undoing)
        guard !changes.isEmpty else { return nil }
        return (applying(changes, to: string), changes.map(\.edit))
    }

    /// The same, where the links are in the text. Each edit says what its link said before and says after.
    static func replayChanges(_ edits: [LinkEdit], in string: NSString, undoing: Bool) -> [LinkChange] {
        var waiting = edits
        var changes: [LinkChange] = []
        for link in links(in: string) where !waiting.isEmpty {
            let address = string.substring(with: link.address)
            guard let index = waiting.firstIndex(where: { $0.kind == link.kind && (undoing ? $0.new : $0.old) == address }) else { continue }
            let edit = waiting.remove(at: index)
            changes.append(LinkChange(range: link.address, edit: undoing ? LinkEdit(kind: edit.kind, old: edit.new, new: edit.old) : edit))
        }
        return changes
    }

    // MARK: - Links in a note

    struct Link {
        var kind: LinkEdit.Kind
        /// The address, without the spaces around it: for `[[Plan#Today|today]]` "Plan".
        var address: NSRange
        /// A Markdown address between `<` and `>`, where spaces may stay as they are.
        var angled = false
    }

    /// The links in a note as the editor shows them, and the `[[links]]` in its front matter, where Obsidian keeps
    /// properties such as `up: "[[Plan]]"`. Not those in code.
    static func links(in string: NSString) -> [Link] {
        let document = MarkdownParser.parse(string)
        var links: [Link] = []
        for line in document.lines {
            if line.kind == .frontmatter {
                links += frontMatterLinks(in: string, line: line.range)
                continue
            }
            for span in line.spans {
                switch span.kind {
                case .wikiLink, .embed:
                    let opening = if case .embed = span.kind { 3 } else { 2 }
                    let inner = NSRange(location: span.range.location + opening, length: span.range.length - opening - 2)
                    if let address = wikiAddress(in: string, inner: inner) { links.append(Link(kind: .wiki, address: address)) }
                case .link, .image:
                    if let link = markdownAddress(in: string, span: span) { links.append(link) }
                default:
                    break
                }
            }
        }
        return links
    }

    /// In what is between `[[` and `]]`, the part before `#` and `|`, without spaces around it.
    private static func wikiAddress(in string: NSString, inner: NSRange) -> NSRange? {
        guard inner.length > 0 else { return nil }
        var end = inner.location
        while end < inner.upperBound, string.character(at: end) != UInt16(UInt8(ascii: "|")), string.character(at: end) != UInt16(UInt8(ascii: "#")) { end += 1 }
        var start = inner.location
        while start < end, isSpace(string.character(at: start)) { start += 1 }
        while end > start, isSpace(string.character(at: end - 1)) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Between `](` and `)`: the address, without a title after it.
    private static func markdownAddress(in string: NSString, span: InlineSpan) -> Link? {
        guard let close = span.markers.last, close.length >= 3 else { return nil }
        var start = close.location + 2
        let end = close.upperBound - 1
        while start < end, isSpace(string.character(at: start)) { start += 1 }
        guard start < end else { return nil }
        if string.character(at: start) == UInt16(UInt8(ascii: "<")) {
            var stop = start + 1
            while stop < end, string.character(at: stop) != UInt16(UInt8(ascii: ">")) { stop += 1 }
            guard stop < end, stop > start + 1 else { return nil }
            return Link(kind: .markdown, address: NSRange(location: start + 1, length: stop - start - 1), angled: true)
        }
        var stop = start
        while stop < end, !isSpace(string.character(at: stop)) { stop += 1 }
        return Link(kind: .markdown, address: NSRange(location: start, length: stop - start))
    }

    private static func frontMatterLinks(in string: NSString, line: NSRange) -> [Link] {
        var links: [Link] = []
        var search = line
        while search.length > 0 {
            let open = string.range(of: "[[", range: search)
            guard open.location != NSNotFound else { break }
            let rest = NSRange(location: open.upperBound, length: line.upperBound - open.upperBound)
            let close = string.range(of: "]]", range: rest)
            guard close.location != NSNotFound else { break }
            if let address = wikiAddress(in: string, inner: NSRange(location: open.upperBound, length: close.location - open.upperBound)) {
                links.append(Link(kind: .wiki, address: address))
            }
            search = NSRange(location: close.upperBound, length: line.upperBound - close.upperBound)
        }
        return links
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    /// The text with each link's address changed, from the last one back so the others stay where they are.
    static func applying(_ changes: [LinkChange], to string: NSString) -> String {
        let result = NSMutableString(string: string)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: change.range, with: change.edit.new)
        }
        return result as String
    }
}
