import Foundation
import UniformTypeIdentifiers

/// Import from Apple Notes: what Notes' own Markdown export wrote, put into a folder the way Notebook keeps notes.
/// Notes exports with File › Export as › Markdown on the Mac, several selected notes at once, and with Share › Export
/// as Markdown on iPhone and iPad, one note at a time. It writes a folder, named after the note or Archive for several,
/// with a Markdown file for each note and one Attachments folder for the pictures and files of all of them. Here:
///
/// - a note's pictures and files go into the `.assets` folder next to it, as Notebook's own do, so they move with it.
///   One Notes wrote without an extension gets one from what it is.
/// - links between the notes exported together point at them again: `[[links]]` in the same folder, relative Markdown
///   links elsewhere, which find exactly that note.
/// - the title, which Notes writes again as the first line, goes: the file's name is the title.
/// - each folder picked becomes a folder, with the folders in it, as the exports were put there. The folder Notes makes
///   for a single note is only that note.
/// - the notes keep the dates their files have.
///
/// The export is only read, all of it before anything is written, and nothing outside it is, whatever a link says.
/// Nothing that is there already is written over. A file in an Attachments folder that no note links to comes along as
/// a file of its own, next to the notes, and what can't come over is named in `Result.problems`, so nothing is left
/// behind without a word.
enum AppleNotesImport {
    /// What an import did:
    /// - `made`: for each folder or file picked, the folder or note it became, or nil when it couldn't be.
    /// - `added`: everything it put into the folder it imported into, which was there before: the folders and notes it
    ///   made there, the files it copied there, and the pictures and files it put into that folder's `.assets`. One Undo
    ///   takes these to the Trash; what the import made inside its own folders goes with them.
    /// - `problems`: what couldn't come over, by where it is in the export, with why.
    struct Result: Sendable {
        var made: [URL?]
        var added: [URL]
        var notes: Int
        var problems: [String]
    }

    /// What a link in a note points at, once it is in Notebook.
    enum Target: Equatable {
        /// Another note of the import: its address from the note's folder, and the name `[[…]]` finds it by when it is
        /// in the same folder and its name has nothing a `[[link]]` reads otherwise.
        case note(wiki: String?, address: String)
        /// A file in the note's `.assets`, by its address in Markdown.
        case asset(String, isPicture: Bool)
    }

    /// Imports `sources`, the folders Notes exported (or its Markdown files), into `folder`, which is there already. Off
    /// the main thread: an export can have hundreds of notes, and iCloud may have to bring each down first.
    /// `beforeWriting` runs once the export has been read and the folders made, for tests.
    static func run(_ sources: [URL], into folder: URL, beforeWriting: (() -> Void)? = nil) -> Result {
        let run = Run(sources: sources, target: folder)
        let made = sources.map { run.take($0) }
        beforeWriting?()
        run.writeNotes()
        run.keepUnlinkedFiles()
        let written = made.map { url in url.flatMap { run.written[$0.path] ?? (run.failed.contains($0.path) ? nil : $0) } }
        return Result(made: written, added: run.added, notes: run.written.count, problems: run.problems)
    }

    static func isNote(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    // MARK: - A note's text

    /// A note's Markdown as Notebook keeps it: the links Notes wrote to files and notes of the export point where
    /// `target` says, and the first line goes when it is only the title again.
    static func convert(_ text: String, title: String, target: (String) -> Target?) -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        return withoutTitle(rewritingLinks(text, target), title: title)
    }

    /// `[text](address)` and `![text](address)` whose address `target` knows, rewritten: to notes as `[[links]]` or
    /// relative links, and to files in `.assets`, shown in the note (`![…](…)`) when they were or stand on a line of
    /// their own, as Notes shows its attachments. Not in code, where they are text.
    private static func rewritingLinks(_ text: String, _ target: (String) -> Target?) -> String {
        let code = codeRanges(in: text)
        func isInCode(_ index: String.Index) -> Bool {
            let offset = text.utf16.distance(from: text.startIndex, to: index)
            return code.contains { NSLocationInRange(offset, $0) }
        }
        var result = ""
        var rest = text[...]
        while let middle = rest.range(of: "](") {
            let before = rest[..<middle.lowerBound]
            guard let open = before.lastIndex(of: "["), !before[open...].contains("\n"), !isInCode(open),
                  let (address, end) = destination(in: rest[middle.upperBound...]) else {
                result += rest[..<middle.upperBound]
                rest = rest[middle.upperBound...]
                continue
            }
            let bang = open > rest.startIndex && rest[rest.index(before: open)] == "!"
            let start = bang ? rest.index(before: open) : open
            let label = String(rest[rest.index(after: open)..<middle.lowerBound])
            result += rest[..<start]
            if let found = target(address) {
                let lineBefore = result[(result.lastIndex(of: "\n").map { result.index(after: $0) } ?? result.startIndex)...]
                let lineAfter = rest[end...].prefix { $0 != "\n" }
                let alone = lineBefore.allSatisfy(\.isWhitespace) && lineAfter.allSatisfy(\.isWhitespace)
                result += markdown(for: found, label: label, bang: bang, alone: alone)
            } else {
                result += rest[start..<end]
            }
            rest = rest[end...]
        }
        result += rest
        return result
    }

    /// Code blocks, maths and inline code, as the editor reads them.
    private static func codeRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        for line in MarkdownParser.parse(text as NSString).lines {
            switch line.kind {
            case .fence, .code, .mathDelimiter, .math:
                ranges.append(line.range)
            default:
                for span in line.spans {
                    switch span.kind {
                    case .code, .math: ranges.append(span.range)
                    default: break
                    }
                }
            }
        }
        return ranges
    }

    private static func markdown(for target: Target, label: String, bang: Bool, alone: Bool) -> String {
        switch target {
        case .note(let wiki, let address):
            let shown = label.trimmingCharacters(in: .whitespaces)
            if let wiki, !shown.contains("]"), !shown.contains("|") {
                if bang { return "![[\(wiki)]]" }
                return shown.isEmpty || shown == wiki ? "[[\(wiki)]]" : "[[\(wiki)|\(shown)]]"
            }
            let name = ((address as NSString).lastPathComponent.removingPercentEncoding ?? address) as NSString
            return "[\(shown.isEmpty ? name.deletingPathExtension : label)](\(address))"
        case .asset(let address, let isPicture):
            guard bang || alone else { return "[\(label)](\(address))" }
            // A file's card says its name, as for files Notebook puts in a note itself.
            let name = ((address as NSString).lastPathComponent.removingPercentEncoding ?? address)
            return "![\(isPicture || !label.isEmpty ? label : name)](\(address))"
        }
    }

    /// A link's address, from just after its `](`, and where the link ends: `<…>`, or up to the `)` that closes it, a
    /// title in quotes left out. Nil when the link doesn't close on its line.
    private static func destination(in text: Substring) -> (String, Substring.Index)? {
        var index = text.startIndex
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        if text[index] == "<" {
            guard let close = text[index...].firstIndex(of: ">"), !text[index..<close].contains("\n"),
                  let end = text[close...].firstIndex(of: ")"), !text[close..<end].contains("\n") else { return nil }
            return (String(text[text.index(after: index)..<close]), text.index(after: end))
        }
        var depth = 0
        var cursor = index
        while cursor < text.endIndex {
            switch text[cursor] {
            case "\n":
                return nil
            case "(":
                depth += 1
            case ")" where depth > 0:
                depth -= 1
            case ")":
                var address = text[index..<cursor].trimmingCharacters(in: .whitespaces)
                if address.hasSuffix("\""), let quote = address.dropLast().lastIndex(of: "\""), quote > address.startIndex,
                   address[address.index(before: quote)] == " " {
                    address = address[..<quote].trimmingCharacters(in: .whitespaces)
                }
                return (address, text.index(after: cursor))
            default:
                break
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// The text without its first line when that is only the title again, as Notes starts every note: the file is
    /// named after it, and Notebook shows the name above the text. A first line that is longer, cut short for the
    /// name, stays.
    static func withoutTitle(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              sameName(plainLine(lines[first]), title) else { return text }
        lines.removeSubrange(...first)
        while let line = lines.first, line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// A line without the marks around it: a heading's #s, bold or italic stars.
    private static func plainLine(_ line: String) -> String {
        var plain = line.trimmingCharacters(in: .whitespaces)
        while plain.hasPrefix("#") { plain.removeFirst() }
        plain = plain.trimmingCharacters(in: .whitespaces)
        for mark in ["**", "__", "*", "_"] where plain.count > 2 * mark.count && plain.hasPrefix(mark) && plain.hasSuffix(mark) {
            plain = String(plain.dropFirst(mark.count).dropLast(mark.count))
        }
        return plain.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a line and a file name say the same, but for case, dots before it and the characters a file name can't
    /// have.
    static func sameName(_ line: String, _ name: String) -> Bool {
        func folded(_ text: String) -> String {
            FileOperations.fileName(from: text).folding(options: .caseInsensitive, locale: nil)
        }
        return !line.isEmpty && folded(line) == folded(name)
    }

    // MARK: - Files

    /// The file a link's address names, from the folder of the note: nil for web addresses, anchors and files that
    /// aren't there. Notes may write the address with its spaces encoded or not, and a name may have a colon in it, so
    /// an address counts as a web address only when it names no file.
    static func file(_ address: String, from folder: URL) -> URL? {
        guard !address.isEmpty, !address.hasPrefix("#") else { return nil }
        if address.lowercased().hasPrefix("file:") {
            guard let url = URL(string: address), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        let withoutAnchor = address.firstIndex(of: "#").map { String(address[..<$0]) }
        for path in [address.removingPercentEncoding, address, withoutAnchor?.removingPercentEncoding].compactMap({ $0 }) where !path.isEmpty {
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The extension of a file Notes wrote without one, from how it starts: pictures, PDFs, recordings and videos.
    static func sniffedExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        func starts(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts("GIF8") { return "gif" }
        if starts("%PDF") { return "pdf" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts("RIFF"), starts("WEBP", at: 8) { return "webp" }
        if starts("RIFF"), starts("WAVE", at: 8) { return "wav" }
        if starts("ID3") { return "mp3" }
        if starts("caff") { return "caf" }
        if starts("ftyp", at: 4), bytes.count >= 12 {
            switch String(decoding: bytes[8..<12], as: UTF8.self) {
            case "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1": return "heic"
            case "avif", "avis": return "avif"
            case "M4A ", "M4B ": return "m4a"
            case "qt  ": return "mov"
            case "M4V ", "M4VH", "M4VP": return "m4v"
            default: return "mp4"
            }
        }
        return nil
    }

    static func isPicture(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true
    }

    /// A file's address with links followed, for knowing it again however it was reached: a temporary folder is
    /// /var/… one way and /private/var/… another.
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// An address a file is to get, but for case and how accented letters are written, as the file system tells names
    /// apart.
    private static func nameKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// What the Finder leaves in folders, which isn't part of an export.
    private static func isClutter(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return [".DS_Store", ".localized", "Icon\r"].contains(name) || name.hasPrefix("._")
    }

    // MARK: - An import

    /// What is in the export, all of it read before anything is written: a folder picked inside the one imported
    /// into would otherwise list the folders made in it.
    private indirect enum Item {
        /// A folder of the export, what is in it, and its Attachments folders.
        case folder(URL, [Item], attachments: [URL])
        /// A note, with the Attachments of the folder Notes made for it alone.
        case note(URL, attachments: [URL])
        case file(URL)
    }

    /// One import: the notes of the export and where each goes, written once all are known, so that links between
    /// them find them under the names they get.
    private final class Run {
        /// The folder imported into.
        let target: URL
        /// Where the export is: the folders picked, and the folders of the notes picked on their own, outside which
        /// nothing is read, whatever a link says.
        let boundaries: [String]
        var notes: [(source: URL, destination: URL)] = []
        /// Where each note goes, by where it is in the export.
        var destinations: [String: URL] = [:]
        /// The addresses notes will have, taken before they are written, as the file system tells names apart.
        var reserved = Set<String>()
        /// The Attachments folders of the export, with the folder their notes go to, and the files notes linked to.
        var attachmentFolders: [(folder: URL, destination: URL)] = []
        var linked = Set<String>()
        /// The files put in a `.assets`, by the file and the folder: a picture two notes there show is copied once.
        var copied: [String: String] = [:]
        /// Notes written, by the address they were to get and the one they got, and those that couldn't be.
        var written: [String: URL] = [:]
        var failed = Set<String>()
        /// The notes of the import each note links to, and those that took another name than planned, whose links in
        /// notes written before then are written again.
        var linksTo: [String: Set<String>] = [:]
        var renamed = Set<String>()
        /// The names `[[…]]` finds files by in a folder, as it folds them, with how many files have each.
        var foldedNames: [String: [String: Int]] = [:]
        var added: [URL] = []
        var problems: [String] = []

        init(sources: [URL], target: URL) {
            self.target = target.standardizedFileURL
            boundaries = sources.map { source in
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return AppleNotesImport.key(isFolder ? source : source.deletingLastPathComponent())
            }
        }

        /// Takes in a folder or note picked: reads all of it, then makes its folders in the folder imported into and
        /// gives its notes their addresses. Where it goes, or nil.
        func take(_ source: URL) -> URL? {
            let inside = AppleNotesImport.key(target)
            let picked = AppleNotesImport.key(source)
            if isFolder(source), inside == picked || inside.hasPrefix(picked + "/") {
                problem(source, "the folder the notes go into is in it")
                return nil
            }
            guard let item = read(source) else { return nil }
            return make(item, in: target)
        }

        private func read(_ url: URL) -> Item? {
            guard isFolder(url) else { return AppleNotesImport.isNote(url) ? .note(url, attachments: []) : .file(url) }
            let contents = listing(url)
            let notesHere = contents.contains { AppleNotesImport.isNote($0) && !isFolder($0) }
            // Notes' Attachments sits next to the notes it is for (and may hold a note someone attached), or has no
            // notes in it at all; a folder of yours in Notes called Attachments, exported with the others, has notes
            // and none next to it, and is a folder like them.
            let attachments = contents.filter { item in
                isFolder(item) && item.lastPathComponent.lowercased() == "attachments" && (notesHere || !hasNotes(in: item))
            }
            let rest = contents.filter { !attachments.contains($0) }
            // The folder Notes makes for a single note, named after it, is just that note.
            if rest.count == 1, let note = rest.first, AppleNotesImport.isNote(note), !isFolder(note),
               AppleNotesImport.sameName(note.deletingPathExtension().lastPathComponent, url.lastPathComponent) {
                return .note(note, attachments: attachments)
            }
            return .folder(url, rest.compactMap(read), attachments: attachments)
        }

        /// Whether a folder has notes in it, or in the folders in it.
        private func hasNotes(in folder: URL) -> Bool {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsPackageDescendants)
            return (enumerator?.allObjects as? [URL] ?? []).contains { AppleNotesImport.isNote($0) && !isFolder($0) }
        }

        /// What is in a folder, hidden files too (a note may be called ".NET plans"), but not the Finder's own.
        private func listing(_ folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey])) ?? [])
                .filter { !AppleNotesImport.isClutter($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        private func make(_ item: Item, in folder: URL) -> URL? {
            switch item {
            case .note(let url, let attachments):
                attachmentFolders += attachments.map { ($0, folder) }
                return reserve(url, in: folder)
            case .file(let url):
                return copy(url, into: folder)
            case .folder(let url, let items, let attachments):
                let name = FileOperations.fileName(from: url.lastPathComponent)
                guard let made = FileOperations.createFolder(in: folder, name: name.isEmpty ? "Folder" : name) else {
                    problem(url, "couldn’t be made in “\(folder.lastPathComponent)”, with what is in it")
                    return nil
                }
                if FileNode.samePath(folder, target) { added.append(made) }
                attachmentFolders += attachments.map { ($0, made) }
                for item in items { _ = make(item, in: made) }
                return made
            }
        }

        private func isFolder(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }

        /// A note's address in `folder`: its name, without dots before it, or with a number when a file there or
        /// another note of the import has it.
        private func reserve(_ note: URL, in folder: URL) -> URL {
            let destination = freeAddress(for: note, in: folder)
            reserved.insert(AppleNotesImport.nameKey(destination))
            notes.append((note, destination))
            destinations[AppleNotesImport.key(note)] = destination
            return destination
        }

        private func freeAddress(for note: URL, in folder: URL) -> URL {
            let clean = FileOperations.fileName(from: note.deletingPathExtension().lastPathComponent)
            let name = clean.isEmpty ? "Untitled" : clean
            func address(_ number: Int) -> URL {
                folder.appendingPathComponent(number < 2 ? name : "\(name) \(number)").appendingPathExtension("md")
            }
            var number = 1
            while reserved.contains(AppleNotesImport.nameKey(address(number))) || FileManager.default.fileExists(atPath: address(number).path) { number += 1 }
            return address(number)
        }

        /// A file other than a note, copied as it is, with an extension when Notes wrote it without one.
        @discardableResult
        private func copy(_ file: URL, into folder: URL) -> URL? {
            let clean = FileOperations.fileName(from: file.deletingPathExtension().lastPathComponent)
            let ext = file.pathExtension.isEmpty ? (isFolder(file) ? nil : AppleNotesImport.sniffedExtension(of: file)) : file.pathExtension
            let destination = FileOperations.uniqueURL(in: folder, name: clean.isEmpty ? "File" : clean, extension: ext)
            var done = false
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], writingItemAt: destination, options: [], error: nil) { from, to in
                done = (try? FileManager.default.copyItem(at: from, to: to)) != nil
            }
            guard done else {
                problem(file, "couldn’t be copied")
                return nil
            }
            if FileNode.samePath(folder, target) { added.append(destination) }
            return destination
        }

        func writeNotes() {
            for (source, planned) in notes {
                let plannedKey = planned.path
                guard let text = FileOperations.read(source, coordinator: NSFileCoordinator()) else {
                    failed.insert(plannedKey)
                    problem(source, "couldn’t be read")
                    continue
                }
                let title = source.deletingPathExtension().lastPathComponent
                let converted = AppleNotesImport.convert(text, title: title) { self.linkTarget($0, in: source, goingTo: planned) }
                let dates = try? FileManager.default.attributesOfItem(atPath: source.path)
                // A note of the name may have come meanwhile, from iCloud say: it stays, and this one takes the next name.
                var destination = planned
                var outcome = write(converted, to: destination, dates: dates)
                while outcome == .taken {
                    destination = freeAddress(for: destination, in: destination.deletingLastPathComponent())
                    reserved.insert(AppleNotesImport.nameKey(destination))
                    destinations[AppleNotesImport.key(source)] = destination
                    renamed.insert(AppleNotesImport.key(source))
                    foldedNames[destination.deletingLastPathComponent().path] = nil
                    outcome = write(converted, to: destination, dates: dates)
                }
                guard outcome == .written else {
                    failed.insert(plannedKey)
                    problem(source, "couldn’t be written")
                    continue
                }
                written[plannedKey] = destination
                if FileNode.samePath(destination.deletingLastPathComponent(), target) { added.append(destination) }
            }
            relinkRenamed()
        }

        /// Notes written before a note they link to had to take another name link to it again.
        private func relinkRenamed() {
            guard !renamed.isEmpty else { return }
            for (source, planned) in notes where !(linksTo[AppleNotesImport.key(source)] ?? []).isDisjoint(with: renamed) {
                guard let destination = written[planned.path], let text = FileOperations.read(source, coordinator: NSFileCoordinator()) else { continue }
                let converted = AppleNotesImport.convert(text, title: source.deletingPathExtension().lastPathComponent) {
                    self.linkTarget($0, in: source, goingTo: destination)
                }
                let dates = try? FileManager.default.attributesOfItem(atPath: source.path)
                NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: nil) { url in
                    guard FileOperations.write(Data(converted.utf8), to: url) else { return }
                    var kept: [FileAttributeKey: Any] = [:]
                    if let created = dates?[.creationDate] { kept[.creationDate] = created }
                    if let modified = dates?[.modificationDate] { kept[.modificationDate] = modified }
                    if !kept.isEmpty { try? FileManager.default.setAttributes(kept, ofItemAtPath: url.path) }
                }
            }
        }

        private enum Outcome { case written, taken, failed }

        /// Writes a new note, never over a file: when one has the name, it says so.
        private func write(_ text: String, to url: URL, dates: [FileAttributeKey: Any]?) -> Outcome {
            var outcome = Outcome.failed
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: nil) { url in
                do {
                    try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                    NoteHistory.shared.made(url)
                    outcome = .written
                } catch {
                    outcome = FileManager.default.fileExists(atPath: url.path) ? .taken : .failed
                    return
                }
                // The dates the note had in Notes, if its export kept them; else when it was exported.
                var kept: [FileAttributeKey: Any] = [:]
                if let created = dates?[.creationDate] { kept[.creationDate] = created }
                if let modified = dates?[.modificationDate] { kept[.modificationDate] = modified }
                if !kept.isEmpty { try? FileManager.default.setAttributes(kept, ofItemAtPath: url.path) }
            }
            return outcome
        }

        /// What a link in a note of the export points at: another note of the import, or a file of the export, copied
        /// into the `.assets` of the folder the note goes to.
        private func linkTarget(_ address: String, in note: URL, goingTo destination: URL) -> Target? {
            guard let file = AppleNotesImport.file(address, from: note.deletingLastPathComponent()) else { return nil }
            let key = AppleNotesImport.key(file)
            guard boundaries.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) else { return nil }
            if let other = destinations[key] {
                linksTo[AppleNotesImport.key(note), default: []].insert(key)
                return noteTarget(other, from: destination)
            }
            guard !isFolder(file) else { return nil }
            // Taken care of here, copied or not: it isn't copied again, loose, with the files nothing links to.
            linked.insert(key)
            guard let name = asset(file, in: destination.deletingLastPathComponent()) else {
                problem(file, "couldn’t be copied for “\(destination.deletingPathExtension().lastPathComponent)”")
                return nil
            }
            return .asset(LinkUpdate.encoded(".assets/" + name), isPicture: AppleNotesImport.isPicture(name))
        }

        /// Another note of the import: by `[[name]]` in the same folder, where that finds it first, when its name has
        /// none of the characters a `[[link]]` reads as more than a name; else by its address from the note's folder,
        /// which finds exactly it, whatever other note of its name there is.
        private func noteTarget(_ other: URL, from note: URL) -> Target {
            let name = other.deletingPathExtension().lastPathComponent
            let here = note.deletingLastPathComponent().standardizedFileURL.pathComponents
            let there = other.standardizedFileURL.pathComponents
            var common = 0
            while common < min(here.count, there.count - 1), here[common] == there[common] { common += 1 }
            let path = (Array(repeating: "..", count: here.count - common) + there[common...]).joined(separator: "/")
            let sameFolder = common == here.count && common == there.count - 1
            let plain = !name.contains { "#|^[]".contains($0) }
            let alone = sameFolder && plain && foldedCount(of: name, in: other.deletingLastPathComponent()) <= 1
            return .note(wiki: alone ? name : nil, address: LinkUpdate.encoded(path))
        }

        /// How many files in a folder `[[name]]` finds, as it reads names, ignoring case, accents and width
        /// (`SearchIndex.fold`): those there and the notes of the import going there. With more than one, "Résumé" may
        /// find "Resume".
        private func foldedCount(of name: String, in folder: URL) -> Int {
            let path = folder.standardizedFileURL.path
            if foldedNames[path] == nil {
                var files = Set(((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).map(\.standardizedFileURL.path))
                for destination in destinations.values where FileNode.samePath(destination.deletingLastPathComponent(), folder) {
                    files.insert(destination.standardizedFileURL.path)
                }
                var counts: [String: Int] = [:]
                for file in files {
                    let fileName = (file as NSString).lastPathComponent
                    let name = AppleNotesImport.isNote(URL(fileURLWithPath: file)) ? (fileName as NSString).deletingPathExtension : fileName
                    counts[SearchIndex.fold(name), default: 0] += 1
                }
                foldedNames[path] = counts
            }
            return foldedNames[path]?[SearchIndex.fold(name)] ?? 0
        }

        /// A file a note links to, in the `.assets` of `folder`: its name there.
        private func asset(_ file: URL, in folder: URL) -> String? {
            let id = AppleNotesImport.key(file) + "\n" + folder.path
            if let name = copied[id] { return name }
            let assets = folder.appendingPathComponent(".assets", isDirectory: true)
            var name = file.lastPathComponent
            if file.pathExtension.isEmpty, let ext = AppleNotesImport.sniffedExtension(of: file) { name += "." + ext }
            try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            var destination = assets.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                if FileManager.default.contentsEqual(atPath: file.path, andPath: destination.path) {
                    copied[id] = name
                    return name
                }
                name = FileOperations.freeAssetName(for: name, in: assets)
                destination = assets.appendingPathComponent(name)
            }
            var done = false
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], writingItemAt: destination, options: [], error: nil) { from, to in
                done = (try? FileManager.default.copyItem(at: from, to: to)) != nil
            }
            guard done else { return nil }
            copied[id] = name
            if FileNode.samePath(folder, target) { added.append(destination) }
            return name
        }

        /// The files of an Attachments folder no note linked to, in it or in folders in it, come along as files next
        /// to the notes, where they can be seen, rather than being lost. A package (an RTFD, a Pages document) is one
        /// file.
        func keepUnlinkedFiles() {
            for (folder, destination) in attachmentFolders {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey]
                let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: .skipsPackageDescendants)
                let files = (enumerator?.allObjects as? [URL] ?? [])
                    .filter { file in
                        let values = try? file.resourceValues(forKeys: Set(keys))
                        return (values?.isRegularFile == true || values?.isPackage == true) && !AppleNotesImport.isClutter(file)
                    }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for file in files where !linked.contains(AppleNotesImport.key(file)) {
                    copy(file, into: destination)
                }
            }
        }

        /// Something that couldn't come over, by where it is in the export.
        private func problem(_ url: URL, _ why: String) {
            let path = AppleNotesImport.key(url)
            let place = boundaries.first { path == $0 || path.hasPrefix($0 + "/") }.map { boundary in
                (boundary as NSString).lastPathComponent + path.dropFirst(boundary.count)
            } ?? url.lastPathComponent
            let line = "\(place): \(why)"
            if !problems.contains(line) { problems.append(line) }
        }
    }
}
