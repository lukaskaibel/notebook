import Foundation
import Synchronization

/// What search goes through as you type: a copy of the index laid out to be read fast, from any thread. The index makes
/// a new one in the background whenever files change, and a search goes through the one it started with, so typing
/// never waits for the main thread, nor the main thread for search.
///
/// The names of all files are one run of bytes, so a single pass of `memmem` finds a word in every name; the texts are
/// searched on every core at once. Both run in the system's own code, which is as fast in a Debug build as in a
/// Release one. A whole iCloud Drive (a hundred thousand files, thousands of notes) takes a few milliseconds.
final class SearchCorpus: Sendable {
    struct Item: Sendable {
        let url: URL
        let name: String
        let kind: FileKind
        /// Where it is, as "Location › Folder".
        let place: String
        let modified: Date
        let isInCloud: Bool
        let foldedName: String
    }

    /// Where the text of a document was found.
    enum Source: Sendable, Hashable {
        /// A note's own text, or a PDF's.
        case text
        /// Read in a picture: the picture itself, or one in a note (its name in `.assets`).
        case picture(asset: String?)
        /// Handwriting in a drawing in a note.
        case drawing(asset: String)
        /// Read in the pages of a PDF that has no text of its own, such as a scan. Pages are split by form feeds.
        case scan

        var isRecognized: Bool { self != .text }
    }

    struct Document: Sendable {
        /// The file it is in: the note for a picture or drawing in a note.
        let item: Int
        let text: String
        let folded: String
        let source: Source
    }

    struct Heading: Sendable {
        let item: Int
        let level: Int
        let title: String
    }

    /// What the index knew when this was made, to tell whether it is out of date.
    let version: Int
    let items: [Item]
    /// Every item's folded name, each after a newline and with one after the last: one pass of `memmem` finds a word
    /// in all of them.
    private let names: [UInt8]
    /// Where each item's name starts in `names`, and one more as if a name followed the last.
    private let nameStarts: [Int]
    /// The longest name's length in bytes: the room loose matching needs to go through any of them.
    private let longestName: Int
    /// Newest first.
    let documents: [Document]
    /// Each document's folded text, as `documents` has them: what the threads of a search read, without touching the
    /// rest.
    private let folds: [String]
    /// Each item's kind, as `items` has them.
    private let kinds: [FileKind]
    private let headingNames: [UInt8]
    private let headingStarts: [Int]
    let headings: [Heading]

    static let empty = SearchCorpus(version: -1, entries: [], hidden: [], recognized: [:])

    /// Made from the index's entries, leaving out what is in hidden folders, with the text read in pictures, scans and
    /// drawings (by the file's address; a picture in a note by `folder/.assets/name`).
    init(version: Int, entries: some Collection<SearchIndex.Entry>, hidden: [String], recognized: [String: PictureText]) {
        self.version = version
        var items: [Item] = []
        items.reserveCapacity(entries.count)
        var names: [UInt8] = [10]
        var nameStarts: [Int] = []
        nameStarts.reserveCapacity(entries.count + 1)
        var documents: [(modified: Date, document: Document)] = []
        var headingNames: [UInt8] = [10]
        var headingStarts: [Int] = []
        var headings: [Heading] = []
        for entry in entries where !SearchIndex.isHidden(entry.path, in: hidden) {
            let index = items.count
            let modified = entry.modified ?? .distantPast
            items.append(Item(url: entry.url, name: entry.name, kind: entry.kind, place: entry.place, modified: modified,
                              isInCloud: entry.isInCloud, foldedName: entry.foldedName))
            nameStarts.append(names.count)
            names.append(contentsOf: entry.foldedName.utf8)
            names.append(10)
            if let text = entry.text, let folded = entry.folded {
                documents.append((modified, Document(item: index, text: text, folded: folded, source: .text)))
            }
            if let read = recognized[entry.path], !read.text.isEmpty {
                documents.append((modified, Document(item: index, text: read.text, folded: read.folded,
                                                     source: entry.kind == .pdf ? .scan : .picture(asset: nil))))
            }
            for asset in entry.assets {
                guard let read = recognized[entry.folder + "/.assets/" + asset], !read.text.isEmpty else { continue }
                let source: Source = read.isHandwriting ? .drawing(asset: asset) : .picture(asset: asset)
                documents.append((modified, Document(item: index, text: read.text, folded: read.folded, source: source)))
            }
            for heading in entry.headings {
                let folded = SearchIndex.fold(heading.title)
                // The note's own name as its first heading is found as the note already.
                guard folded != entry.foldedName else { continue }
                headingStarts.append(headingNames.count)
                headingNames.append(contentsOf: folded.utf8)
                headingNames.append(10)
                headings.append(Heading(item: index, level: heading.level, title: heading.title))
            }
        }
        // Where a name after the last would start, right after the last newline: each name ends a byte before the next.
        nameStarts.append(names.count)
        headingStarts.append(headingNames.count)
        // Newest first: what you search for is most often what you worked on lately.
        documents.sort { $0.modified > $1.modified }
        self.items = items
        self.names = names
        self.nameStarts = nameStarts
        self.longestName = zip(nameStarts, nameStarts.dropFirst()).map { $1 - $0 - 1 }.max() ?? 0
        self.documents = documents.map(\.document)
        self.folds = self.documents.map(\.folded)
        self.kinds = items.map(\.kind)
        self.headingNames = headingNames
        self.headingStarts = headingStarts
        self.headings = headings
    }

    // MARK: - Searching

    /// What was typed, folded as names and texts are, in words.
    struct Query: Sendable {
        let text: String
        let folded: String
        /// Each word once, longest first: the longest finds the fewest, so it is looked for first.
        let words: [String]

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = SearchIndex.fold(trimmed)
            var words: [String] = []
            for word in folded.split(whereSeparator: \.isWhitespace).map(String.init) where !words.contains(word) {
                words.append(SearchIndex.contiguous(word))
            }
            guard !words.isEmpty else { return nil }
            self.text = trimmed
            self.folded = folded
            self.words = words.sorted { $0.utf8.count > $1.utf8.count }
        }

        var isOneWord: Bool { words.count == 1 }
        /// How many letters it has, whatever their bytes.
        var letterCount: Int { folded.unicodeScalars.count }
        /// From this many letters on, names and commands only a bit like it are listed too, last.
        static let lettersForSimilar = 3
    }

    struct Limits: Sendable {
        var files = 6
        var folders = 3
        var headings = 4
        var texts = 6
        var pictures = 4
        /// Names that only match loosely, below everything else.
        var others = 3
    }

    struct TextHit: Sendable {
        let item: Item
        let source: Source
        /// The line the words are in, with a few words on each side.
        let snippet: String
        /// The words searched for, in `snippet`.
        let matches: [Range<String.Index>]
        /// For a PDF, the page they are on.
        let page: Int?
    }

    struct HeadingHit: Sendable {
        let item: Item
        let heading: Heading
    }

    struct Results: Sendable {
        var files: [Item] = []
        var folders: [Item] = []
        var headings: [HeadingHit] = []
        /// In notes and PDFs.
        var texts: [TextHit] = []
        /// In pictures, scans and drawings.
        var pictures: [TextHit] = []
        /// Files and folders whose names have the letters typed but not much like it: "kyo" in "Workout family notes".
        var others: [Item] = []
        /// How many notes and files have the words in them, shown or not.
        var textCount = 0

        var isEmpty: Bool { files.isEmpty && folders.isEmpty && headings.isEmpty && texts.isEmpty && pictures.isEmpty && others.isEmpty }
    }

    /// Everything that matches, best first in each kind. `isCancelled` is asked as it goes, so a search for what was
    /// typed before stops as soon as there is a newer one.
    func search(_ query: Query, limits: Limits = Limits(), names namesOnly: Bool = false, isCancelled: @Sendable () -> Bool = { false }) -> Results {
        var results = Results()
        let named = matchNames(query, files: limits.files, folders: limits.folders, others: limits.others, isCancelled: isCancelled)
        results.files = named.files.map { items[$0] }
        results.folders = named.folders.map { items[$0] }
        results.others = named.others.map { items[$0] }
        // A single letter is in nearly every note.
        if namesOnly || query.folded.utf8.count < 2 || isCancelled() { return results }
        results.headings = matchHeadings(query, limit: limits.headings).map { HeadingHit(item: items[headings[$0].item], heading: headings[$0]) }
        if isCancelled() { return results }
        let found = matchDocuments(query, isCancelled: isCancelled)
        // A note listed by its name or a heading already isn't listed again for its text.
        let shown = Set(named.files).union(results.headings.map(\.heading.item))
        var texts: [TextHit] = [], pictures: [TextHit] = []
        var counted = Set<Int>()
        for index in found {
            let document = documents[index]
            counted.insert(document.item)
            if document.source.isRecognized {
                if pictures.count < limits.pictures { pictures.append(hit(document, query)) }
            } else if texts.count < limits.texts, !shown.contains(document.item) {
                texts.append(hit(document, query))
            }
            if isCancelled() { return results }
        }
        results.texts = texts
        results.pictures = pictures
        results.textCount = counted.count
        // Listed for the words in it, a file isn't listed again for its name being a bit like them.
        let listed = Set(texts.map(\.item.url))
        results.others = named.others.filter { !listed.contains(items[$0].url) }.map { items[$0] }
        return results
    }

    // MARK: Names

    /// Items whose names have every word, best first, as notes and files and as folders; when there is room left and
    /// `loose`, those that have them loosely too, the good ones with them and up to `others` more that are only a bit
    /// like them. Not loose, it is quick enough for the main thread, as links typed in a note need.
    func matchNames(_ query: Query, files fileLimit: Int, folders folderLimit: Int, others otherLimit: Int = 0, loose: Bool = true,
                    isCancelled: @Sendable () -> Bool = { false }) -> (files: [Int], folders: [Int], others: [Int]) {
        var files = Best(fileLimit)
        var folders = Best(folderLimit)
        var others = Best(otherLimit)
        var seen = [Bool](repeating: false, count: items.count)
        func consider(_ index: Int, _ score: Int) {
            seen[index] = true
            if kinds[index] == .folder {
                guard folders.takes(score) else { return }
                let item = items[index]
                folders.add(Candidate(score: score, modified: item.modified, path: item.url.path, index: index))
            } else {
                let score = score + (kinds[index] == .note ? 5 : 0)
                guard files.takes(score) else { return }
                let item = items[index]
                files.add(Candidate(score: score, modified: item.modified, path: item.url.path, index: index))
            }
        }
        let first = Array(query.words[0].utf8)
        let whole = Array(query.folded.utf8)
        names.withUnsafeBufferPointer { buffer in
            nameStarts.withUnsafeBufferPointer { starts in
                guard let base = buffer.baseAddress else { return }
                var position = 0
                var item = 0
                var hits = 0
                while position < buffer.count,
                      let found = memmem(base + position, buffer.count - position, first, first.count) {
                    let offset = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    // The names are in order, and so are the places the word is found in them.
                    while starts[item + 1] <= offset { item += 1 }
                    let name = UnsafeBufferPointer(rebasing: buffer[starts[item]..<(starts[item + 1] - 1)])
                    if let score = Self.score(name, at: offset - starts[item], query, first: first, whole: whole) { consider(item, score) }
                    position = starts[item + 1]
                    hits += 1
                    if hits & 1023 == 0, isCancelled() { return }
                }
            }
        }
        // Names with the words loosely, when nothing better fills the lists: their letters in order, "kytr" for "Kyoto
        // trip", or with a letter wrong, "ryokna" for "ryokan". Those only a bit like them go last, also for a note.
        let letters = query.letterCount
        if loose, letters >= 2, files.items.count < fileLimit, !isCancelled() {
            for (index, quality) in looseMatches(query, skipping: seen, isCancelled: isCancelled) {
                let score = FuzzyMatch.score(quality)
                if quality >= FuzzyMatch.good {
                    consider(index, score)
                } else if letters >= Query.lettersForSimilar, others.takes(score) {
                    // Two letters are in order in most names.
                    let item = items[index]
                    others.add(Candidate(score: score, modified: item.modified, path: item.url.path, index: index))
                }
            }
        }
        return (files.items.map(\.index), folders.items.map(\.index), others.items.map(\.index))
    }

    /// How well a name matches, from where its first word was found in it: the whole query as the name (100), at its
    /// start (80), at a word's start (60), inside it (40), or every word of it somewhere in it (30).
    private static func score(_ name: UnsafeBufferPointer<UInt8>, at offset: Int, _ query: Query, first: [UInt8], whole: [UInt8]) -> Int? {
        guard let base = name.baseAddress else { return nil }
        func place(_ at: Int) -> Int {
            guard at > 0 else { return 80 }
            let before = name[at - 1]
            return before == 32 || before == 45 || before == 95 ? 60 : 40
        }
        if query.isOneWord {
            if name.count == first.count { return 100 }
            return place(offset)
        }
        if name.count == whole.count, memcmp(base, whole, whole.count) == 0 { return 100 }
        if let found = memmem(base, name.count, whole, whole.count) {
            return place(UnsafeRawPointer(found) - UnsafeRawPointer(base))
        }
        for word in query.words.dropFirst() {
            let found = word.utf8.withContiguousStorageIfAvailable { memmem(base, name.count, $0.baseAddress, $0.count) != nil } ?? false
            if !found { return nil }
        }
        return 30
    }

    /// Items whose names have every word loosely, with how well (`FuzzyMatch`), found on every core. A word with
    /// letters wrong is looked for first, through all names at once, only where a word of a name starts with its first
    /// letter; then every name not found already gets the best of that and its letters in order. The threads read the
    /// names through pointers taken once: in a Debug build, every use of a shared array from many threads at once would
    /// fight over its reference count.
    private func looseMatches(_ query: Query, skipping seen: [Bool], isCancelled: @Sendable () -> Bool) -> [(index: Int, quality: Double)] {
        let chunks = Self.chunks(items.count)
        let found = Mutex<[(index: Int, quality: Double)]>([])
        let stop = Atomic<Bool>(false)
        // The words one after the other, and where each ends.
        var letters: [UInt8] = []
        var ends: [Int] = []
        for word in query.words {
            letters += word.utf8
            ends.append(letters.count)
        }
        // For each word and item, the fewest letters wrong for the word to start a word of its name; 0 for none.
        var typos = [UInt8](repeating: 0, count: ends.count * items.count)
        let typed = query.words.map { word in
            var word = word
            return word.withUTF8 { FuzzyMatch.Typed($0) }
        }
        let count = items.count, longest = longestName
        // With one word, a name that has it as it is was found by it already; with more, it may have some of them.
        let mayHaveWords = !query.isOneWord
        names.withUnsafeBufferPointer { buffer in
            nameStarts.withUnsafeBufferPointer { starts in
                seen.withUnsafeBufferPointer { seen in
                    letters.withUnsafeBufferPointer { letters in
                        ends.withUnsafeBufferPointer { ends in
                            typos.withUnsafeMutableBufferPointer { typos in
                                guard let base = buffer.baseAddress, let letterBase = letters.baseAddress, let typoBase = typos.baseAddress else { return }
                                func word(_ number: Int) -> UnsafeBufferPointer<UInt8> {
                                    let from = number == 0 ? 0 : ends[number - 1]
                                    return UnsafeBufferPointer(start: letterBase + from, count: ends[number] - from)
                                }
                                for number in 0..<ends.count {
                                    let allowed = typed[number].allowed
                                    guard allowed > 0, let lead = typed[number].first.first else { continue }
                                    let row = typoBase + number * count
                                    typed[number].letters.withUnsafeBufferPointer { wordLetters in
                                        typed[number].first.withUnsafeBufferPointer { first in
                                            DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                                                let scratch = FuzzyMatch.Scratch(length: longest)
                                                defer { scratch.free() }
                                                let range = chunks[chunk]
                                                var item = range.lowerBound
                                                var position = starts[range.lowerBound]
                                                let end = starts[range.upperBound]
                                                var hits = 0
                                                while position < end, let at = memchr(base + position, Int32(lead), end - position) {
                                                    let offset = UnsafeRawPointer(at) - UnsafeRawPointer(base)
                                                    position = offset + 1
                                                    while starts[item + 1] <= offset { item += 1 }
                                                    if hits & 1023 == 0, stop.load(ordering: .relaxed) || isCancelled() {
                                                        stop.store(true, ordering: .relaxed)
                                                        return
                                                    }
                                                    hits += 1
                                                    let nameEnd = starts[item + 1] - 1
                                                    guard !seen[item], FuzzyMatch.couldBe(first, at: offset, in: base, length: nameEnd),
                                                          let wrong = FuzzyMatch.typos(wordLetters, allowed: allowed, at: base + offset,
                                                                                        length: nameEnd - offset, scratch) else { continue }
                                                    if row[item] == 0 || Int(row[item]) > wrong { row[item] = UInt8(wrong) }
                                                }
                                            }
                                        }
                                    }
                                }
                                guard !stop.load(ordering: .relaxed) else { return }
                                DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                                    let scratch = FuzzyMatch.Scratch(length: longest)
                                    defer { scratch.free() }
                                    var mine: [(index: Int, quality: Double)] = []
                                    let range = chunks[chunk]
                                    var index = range.lowerBound
                                    next: while index < range.upperBound {
                                        if (index - range.lowerBound) & 255 == 0, stop.load(ordering: .relaxed) || isCancelled() {
                                            stop.store(true, ordering: .relaxed)
                                            return
                                        }
                                        defer { index += 1 }
                                        if seen[index] { continue }
                                        let start = starts[index]
                                        let name = UnsafeBufferPointer(start: base + start, count: starts[index + 1] - 1 - start)
                                        var worst = 1.0
                                        for number in 0..<ends.count {
                                            let word = word(number)
                                            if mayHaveWords, let wordBase = word.baseAddress, word.count <= name.count,
                                               memmem(base + start, name.count, wordBase, word.count) != nil { continue }
                                            guard let quality = FuzzyMatch.quality(word, in: name, typos: Int(typoBase[number * count + index]), scratch) else { continue next }
                                            if quality < worst { worst = quality }
                                        }
                                        mine.append((index, worst))
                                    }
                                    let result = mine
                                    found.withLock { $0 += result }
                                }
                            }
                        }
                    }
                }
            }
        }
        return found.withLock { $0 }
    }

    /// How well a folded name matches, as search ranks names: the whole query as the name (100), at its start (80), at
    /// a word's start (60), inside it (40), every word of it somewhere in it (30), or loosely (below that, from
    /// `FuzzyMatch.goodScore` a good match).
    static func score(_ name: String, _ query: Query) -> Int? {
        if let score = SearchIndex.score(name, query.folded), score > FuzzyMatch.score(1) { return score }
        if !query.isOneWord, query.words.allSatisfy({ SearchIndex.offset(of: $0, in: name) != nil }) { return 30 }
        return FuzzyMatch.quality(query.words, in: name).map(FuzzyMatch.score)
    }

    // MARK: Headings

    private func matchHeadings(_ query: Query, limit: Int) -> [Int] {
        var best = Best(limit)
        let first = Array(query.words[0].utf8)
        let whole = Array(query.folded.utf8)
        headingNames.withUnsafeBufferPointer { buffer in
            headingStarts.withUnsafeBufferPointer { starts in
                guard let base = buffer.baseAddress else { return }
                var position = 0
                var heading = 0
                while position < buffer.count,
                      let found = memmem(base + position, buffer.count - position, first, first.count) {
                    let offset = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    while starts[heading + 1] <= offset { heading += 1 }
                    let title = UnsafeBufferPointer(rebasing: buffer[starts[heading]..<(starts[heading + 1] - 1)])
                    if let score = Self.score(title, at: offset - starts[heading], query, first: first, whole: whole), best.takes(score) {
                        let item = items[headings[heading].item]
                        best.add(Candidate(score: score, modified: item.modified, path: item.url.path, index: heading))
                    }
                    position = starts[heading + 1]
                }
            }
        }
        return best.items.map(\.index)
    }

    // MARK: Texts

    /// The documents with every word in them, on every core: those with the words together first (for more than one
    /// word), each newest first. The threads read the texts and the words through pointers taken once, as
    /// `looseMatches` does.
    func matchDocuments(_ query: Query, isCancelled: @Sendable () -> Bool) -> [Int] {
        guard !documents.isEmpty else { return [] }
        let chunks = Self.chunks(documents.count)
        var words: [UInt8] = []
        var bounds = [0]
        for word in query.words {
            words += word.utf8
            bounds.append(words.count)
        }
        let phrase: [UInt8] = query.isOneWord ? [] : Array(query.folded.utf8)
        var parts = [(together: [Int], apart: [Int])](repeating: ([], []), count: chunks.count)
        let stop = Atomic<Bool>(false)
        folds.withUnsafeBufferPointer { folds in
            words.withUnsafeBufferPointer { words in
                bounds.withUnsafeBufferPointer { bounds in
                    phrase.withUnsafeBufferPointer { phrase in
                        parts.withUnsafeMutableBufferPointer { parts in
                            guard let wordBase = words.baseAddress else { return }
                            DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                                var together: [Int] = [], apart: [Int] = []
                                let range = chunks[chunk]
                                var index = range.lowerBound
                                while index < range.upperBound {
                                    if index & 63 == 0, stop.load(ordering: .relaxed) || isCancelled() {
                                        stop.store(true, ordering: .relaxed)
                                        return
                                    }
                                    var text = folds[index]
                                    let found = text.withUTF8 { text -> Int in
                                        guard let base = text.baseAddress else { return 0 }
                                        var word = 0
                                        while word < bounds.count - 1 {
                                            let start = bounds[word], length = bounds[word + 1] - start
                                            if memmem(base, text.count, wordBase + start, length) == nil { return 0 }
                                            word += 1
                                        }
                                        guard let phraseBase = phrase.baseAddress else { return 2 }
                                        return memmem(base, text.count, phraseBase, phrase.count) == nil ? 1 : 2
                                    }
                                    if found == 2 { together.append(index) } else if found == 1 { apart.append(index) }
                                    index += 1
                                }
                                parts[chunk] = (together, apart)
                            }
                        }
                    }
                }
            }
        }
        return parts.flatMap(\.together) + parts.flatMap(\.apart)
    }

    /// The line of a document the words are in.
    private func hit(_ document: Document, _ query: Query) -> TextHit {
        let snippet = Self.snippet(of: document.text, query)
        let item = items[document.item]
        return TextHit(item: item, source: document.source, snippet: snippet.text, matches: snippet.matches,
                       page: item.kind == .pdf ? snippet.page : nil)
    }

    /// The line around the first place the words are, with at most a few words on each side, without the Markdown at
    /// its start; and where the words are in it, and the page (counted by form feeds).
    static func snippet(of text: String, _ query: Query) -> (text: String, matches: [Range<String.Index>], page: Int?) {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let range = (query.isOneWord ? nil : text.range(of: query.text, options: options))
            ?? query.words.lazy.compactMap { text.range(of: $0, options: options) }.first
        guard let range else { return (String(text.prefix(120)), [], nil) }
        let page = pageNumber(in: text, before: range.lowerBound)
        let breaks: (Character) -> Bool = { $0 == "\n" || $0 == "\u{0C}" }
        let lineStart = text[..<range.lowerBound].lastIndex(where: breaks).map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(where: breaks) ?? text.endIndex
        let start = text.index(range.lowerBound, offsetBy: -48, limitedBy: lineStart) ?? lineStart
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: lineEnd) ?? lineEnd
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start == lineStart { snippet = plainLine(snippet) }
        snippet = SearchIndex.plainMarkdown(snippet)
        if start > lineStart { snippet = "…" + snippet }
        if end < lineEnd { snippet += "…" }
        var matches: [Range<String.Index>] = []
        for word in query.isOneWord ? query.words : [query.text] + query.words {
            var from = snippet.startIndex
            while let found = snippet.range(of: word, options: options, range: from..<snippet.endIndex) {
                if !matches.contains(where: { $0.overlaps(found) }) { matches.append(found) }
                from = found.upperBound
            }
        }
        return (snippet, matches.sorted { $0.lowerBound < $1.lowerBound }, page)
    }

    /// Which page of a PDF's text a place is on: one more than the form feeds before it.
    private static func pageNumber(in text: String, before index: String.Index) -> Int {
        var text = text
        let offset = text.utf8.distance(from: text.startIndex, to: index)
        return text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return 1 }
            var pages = 1, position = 0
            while position < offset, let found = memchr(base + position, 0x0C, offset - position) {
                pages += 1
                position = UnsafeRawPointer(found) - UnsafeRawPointer(base) + 1
            }
            return pages
        }
    }

    /// A line without the Markdown at its start: "> ", "- [ ] ", "## ", "1. ", a callout's "[!tip]".
    static func plainLine(_ line: String) -> String {
        // A table's row reads as its cells.
        if line.hasPrefix("|") {
            return line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var result = Substring(line)
        var changed = true
        while changed {
            changed = false
            for prefix in ["> ", ">", "- ", "* ", "+ "] where result.hasPrefix(prefix) {
                result = result.dropFirst(prefix.count)
                changed = true
            }
            if let box = Todos.checkboxLength(result) {
                result = result.dropFirst(box)
                changed = true
            }
            if result.hasPrefix("#") {
                result = result.drop(while: { $0 == "#" }).drop(while: { $0 == " " })
                changed = true
            }
            if result.hasPrefix("[!"), let close = result.firstIndex(of: "]") {
                result = result[result.index(after: close)...].drop(while: { $0 == " " || $0 == "-" || $0 == "+" })
                changed = true
            }
            if let dot = result.firstIndex(of: "."), result[..<dot].allSatisfy(\.isNumber), !result[..<dot].isEmpty, result[result.index(after: dot)...].hasPrefix(" ") {
                result = result[result.index(dot, offsetBy: 2)...]
                changed = true
            }
        }
        return String(result)
    }

    // MARK: - Helpers

    /// Ranges of about equal size, a few for every core, so the cores finish at about the same time.
    private static func chunks(_ count: Int) -> [Range<Int>] {
        let parts = max(1, min(count / 32, ProcessInfo.processInfo.activeProcessorCount * 4))
        let size = (count + parts - 1) / parts
        return stride(from: 0, to: count, by: max(size, 1)).map { $0..<min($0 + size, count) }
    }

    struct Candidate {
        var score: Int
        var modified: Date
        /// To always list the same in the same order.
        var path: String
        var index: Int

        /// Higher scores first, then newer, then by address.
        func isBefore(_ other: Candidate) -> Bool {
            if score != other.score { return score > other.score }
            if modified != other.modified { return modified > other.modified }
            if path != other.path { return path < other.path }
            return index < other.index
        }
    }

    /// The first few of many, in order, without sorting them all.
    struct Best {
        let limit: Int
        private(set) var items: [Candidate] = []

        init(_ limit: Int) { self.limit = limit }

        /// Whether a candidate with this score could be among them, before making one.
        func takes(_ score: Int) -> Bool {
            limit > 0 && (items.count < limit || score >= items[items.count - 1].score)
        }

        mutating func add(_ candidate: Candidate) {
            guard limit > 0, items.count < limit || candidate.isBefore(items[items.count - 1]) else { return }
            let index = items.firstIndex { candidate.isBefore($0) } ?? items.count
            items.insert(candidate, at: index)
            if items.count > limit { items.removeLast() }
        }
    }
}
