import Foundation
import UniformTypeIdentifiers

/// Import from Apple Notes: what Notes' own Markdown export wrote, put into a folder the way Notebook keeps notes.
/// Notes exports with File › Export as › Markdown on the Mac, several selected notes at once, and with Share › Export
/// as Markdown on iPhone and iPad, one note at a time. It writes a folder, named after the note or Archive for several,
/// with a Markdown file for each note and one Attachments folder for the pictures and files of all of them. Here:
///
/// - a note's pictures and files go into the `.assets` folder next to it, as Notebook's own do, so they move with it.
///   One Notes wrote without an extension gets one from what it is.
/// - links between the notes exported together become `[[links]]`.
/// - the title, which Notes writes again as the first line, goes: the file's name is the title.
/// - each folder picked becomes a folder, with the folders in it, as the exports were put there. The folder Notes makes
///   for a single note is only that note.
/// - the notes keep the dates their files have.
///
/// The export is only read. A file in an Attachments folder that no note links to comes along as a file of its own,
/// next to the notes, rather than being left behind.
enum AppleNotesImport {
    /// What an import made: for each folder or file picked, the folder or note it became, or nil when it couldn't be;
    /// how many notes were written, and how many couldn't be.
    struct Result: Sendable {
        var made: [URL?]
        var notes: Int
        var failed: Int
    }

    /// What a link in a note points at, once it is in Notebook.
    enum Target: Equatable {
        /// Another note of the import, as `[[target]]` finds it.
        case note(String)
        /// A file in the note's `.assets`, by its address in Markdown.
        case asset(String, isPicture: Bool)
    }

    /// Imports `sources`, the folders and Markdown files Notes exported, into `folder`, which is there already. Off
    /// the main thread: an export can have hundreds of notes, and iCloud may have to bring each down first.
    static func run(_ sources: [URL], into folder: URL) -> Result {
        let run = Run(sources: sources)
        let made = sources.map { run.plan($0, into: folder) }
        run.writeNotes()
        run.keepUnlinkedFiles()
        return Result(made: made.map { url in url.flatMap { run.failed.contains($0.path) ? nil : $0 } }, notes: run.written, failed: run.failed.count)
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

    /// `[text](address)` and `![text](address)` whose address `target` knows, rewritten: as `[[links]]` to notes, and
    /// to files in `.assets`, shown in the note (`![…](…)`) when they were or stand on a line of their own, as Notes
    /// shows its attachments.
    private static func rewritingLinks(_ text: String, _ target: (String) -> Target?) -> String {
        var result = ""
        var rest = text[...]
        while let middle = rest.range(of: "](") {
            let before = rest[..<middle.lowerBound]
            guard let open = before.lastIndex(of: "["), !before[open...].contains("\n"),
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

    private static func markdown(for target: Target, label: String, bang: Bool, alone: Bool) -> String {
        switch target {
        case .note(let name):
            if bang { return "![[\(name)]]" }
            let shown = label.trimmingCharacters(in: .whitespaces)
            return shown.isEmpty || shown == (name as NSString).lastPathComponent ? "[[\(name)]]" : "[[\(name)|\(shown)]]"
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

    /// Whether a line and a file name say the same, but for case and the characters a file name can't have.
    static func sameName(_ line: String, _ name: String) -> Bool {
        func folded(_ text: String) -> String {
            var text = text
            for character in ["/", ":", "\\"] { text = text.replacingOccurrences(of: character, with: "-") }
            return text.trimmingCharacters(in: .whitespaces).folding(options: .caseInsensitive, locale: nil)
        }
        return !line.isEmpty && folded(line) == folded(name)
    }

    // MARK: - Files

    /// The file a link's address names, from the folder of the note: nil for web addresses, anchors and files that
    /// aren't there. Notes may write the address with its spaces encoded or not.
    static func file(_ address: String, from folder: URL) -> URL? {
        guard !address.isEmpty, !address.hasPrefix("#") else { return nil }
        if let url = URL(string: address), let scheme = url.scheme, scheme.count > 1 {
            return scheme == "file" && FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    // MARK: - An import

    /// One import: the notes of the export and where each goes, written once all are known, so that links between
    /// them find them under the names they get.
    private final class Run {
        /// Where the export is: the folders picked, and the folders of the notes picked on their own, outside which
        /// nothing is read, whatever a link says.
        let boundaries: [String]
        var notes: [(source: URL, destination: URL)] = []
        /// Where each note goes, by where it is in the export.
        var destinations: [String: URL] = [:]
        /// The addresses notes will have, taken before they are written.
        var reserved = Set<String>()
        /// The Attachments folders of the export, with the folder their notes go to, and the files notes linked to.
        var attachmentFolders: [(folder: URL, destination: URL)] = []
        var linked = Set<String>()
        /// The files put in a `.assets`, by the file and the folder: a picture two notes there show is copied once.
        var copied: [String: String] = [:]
        var written = 0
        var failed = Set<String>()

        init(sources: [URL]) {
            boundaries = sources.map { source in
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return AppleNotesImport.key(isFolder ? source : source.deletingLastPathComponent())
            }
        }

        /// Takes in a folder or note of the export, going into `folder`: a folder is made at once, a note only gets its
        /// address. Where it goes, or nil.
        func plan(_ source: URL, into folder: URL) -> URL? {
            guard isFolder(source) else {
                return AppleNotesImport.isNote(source) ? reserve(source, in: folder) : copy(source, into: folder)
            }
            let contents = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: .skipsHiddenFiles)) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let attachments = contents.filter { isFolder($0) && $0.lastPathComponent.lowercased() == "attachments" }
            let rest = contents.filter { item in !attachments.contains(item) }
            // The folder Notes makes for a single note, named after it, is just that note.
            if rest.count == 1, let note = rest.first, AppleNotesImport.isNote(note),
               AppleNotesImport.sameName(note.deletingPathExtension().lastPathComponent, source.lastPathComponent) {
                attachmentFolders += attachments.map { ($0, folder) }
                return reserve(note, in: folder)
            }
            guard let made = FileOperations.createFolder(in: folder, name: source.lastPathComponent) else { return nil }
            attachmentFolders += attachments.map { ($0, made) }
            for item in rest { _ = plan(item, into: made) }
            return made
        }

        private func isFolder(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }

        /// A note's address in `folder`: its name, or its name with a number when a file or another note of the import
        /// has it.
        private func reserve(_ note: URL, in folder: URL) -> URL {
            let name = note.deletingPathExtension().lastPathComponent
            func address(_ number: Int) -> URL {
                folder.appendingPathComponent(number < 2 ? name : "\(name) \(number)").appendingPathExtension("md")
            }
            var number = 1
            while reserved.contains(address(number).path) || FileManager.default.fileExists(atPath: address(number).path) { number += 1 }
            let destination = address(number)
            reserved.insert(destination.path)
            notes.append((note, destination))
            destinations[AppleNotesImport.key(note)] = destination
            return destination
        }

        /// A file other than a note, copied as it is, with an extension when Notes wrote it without one.
        @discardableResult
        private func copy(_ file: URL, into folder: URL) -> URL? {
            let name = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension.isEmpty ? (isFolder(file) ? nil : AppleNotesImport.sniffedExtension(of: file)) : file.pathExtension
            let destination = FileOperations.uniqueURL(in: folder, name: name, extension: ext)
            var done = false
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
                done = (try? FileManager.default.copyItem(at: from, to: to)) != nil
            }
            return done ? destination : nil
        }

        func writeNotes() {
            for (source, destination) in notes {
                guard let text = FileOperations.read(source, coordinator: NSFileCoordinator()) else {
                    failed.insert(destination.path)
                    continue
                }
                let title = source.deletingPathExtension().lastPathComponent
                let converted = AppleNotesImport.convert(text, title: title) { self.target($0, in: source, goingTo: destination) }
                let dates = try? FileManager.default.attributesOfItem(atPath: source.path)
                var done = false
                NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: nil) { url in
                    done = (try? Data(converted.utf8).write(to: url, options: .atomic)) != nil
                    // The dates the note had in Notes, if its export kept them; else when it was exported.
                    var kept: [FileAttributeKey: Any] = [:]
                    if let created = dates?[.creationDate] { kept[.creationDate] = created }
                    if let modified = dates?[.modificationDate] { kept[.modificationDate] = modified }
                    if done, !kept.isEmpty { try? FileManager.default.setAttributes(kept, ofItemAtPath: url.path) }
                }
                if done { written += 1 } else { failed.insert(destination.path) }
            }
        }

        /// What a link in a note of the export points at: another note of the import, or a file of the export, copied
        /// into the `.assets` of the folder the note goes to.
        private func target(_ address: String, in note: URL, goingTo destination: URL) -> Target? {
            guard let file = AppleNotesImport.file(address, from: note.deletingLastPathComponent()) else { return nil }
            let key = AppleNotesImport.key(file)
            guard boundaries.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) else { return nil }
            if let other = destinations[key] { return .note(linkName(other, from: destination)) }
            guard !isFolder(file), let name = asset(file, in: destination.deletingLastPathComponent()) else { return nil }
            linked.insert(key)
            return .asset(LinkUpdate.encoded(".assets/" + name), isPicture: AppleNotesImport.isPicture(name))
        }

        /// How `[[…]]` names another note of the import: by its name in the same folder, else with its folder's name
        /// before it, which finds it wherever else a note of its name is.
        private func linkName(_ other: URL, from note: URL) -> String {
            let name = other.deletingPathExtension().lastPathComponent
            let folder = other.deletingLastPathComponent()
            return FileNode.samePath(folder, note.deletingLastPathComponent()) ? name : folder.lastPathComponent + "/" + name
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
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
                done = (try? FileManager.default.copyItem(at: from, to: to)) != nil
            }
            guard done else { return nil }
            copied[id] = name
            return name
        }

        /// The files of an Attachments folder no note linked to come along as files next to the notes, where they can
        /// be seen, rather than being lost.
        func keepUnlinkedFiles() {
            for (folder, destination) in attachmentFolders {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
                for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where !linked.contains(AppleNotesImport.key(file)) {
                    copy(file, into: destination)
                }
            }
        }
    }
}
