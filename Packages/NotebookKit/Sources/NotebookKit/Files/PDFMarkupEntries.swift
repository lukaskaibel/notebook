import CoreGraphics
import Foundation

/// Apple's ink entries (`MarkupInkArchive`) as they are in the PDF's own bytes, where PDFKit can't reach them.
///
/// Apple's apps use an ink entry only while the annotation is still as it was when the entry was written: next to
/// the entry is a copy of the annotation's dictionary (`/AAPL:AKPDFAnnotationDictionary`), every key of it but its look
/// and the entry itself, and the two have to match (all but the date). Otherwise the annotation is a picture to them,
/// which they draw again as pixels when they save the page. PDFKit can't write that copy as it has to be: it turns
/// text that starts with a slash into a name, and `/DA (/Helvetica 12 Tf 0 g)` is such a text. Worse, when PDFKit writes
/// a PDF again, it leaves the entry out of the squares Preview keeps its handwriting in (it never hands it out), so
/// their strokes would be gone and only their picture left.
///
/// So before PDFKit writes, every annotation with strokes gets a tag (`/NotebookInk`) and its entry is kept aside;
/// once PDFKit has written the file, the entry goes back on each, with the copy made from the very bytes PDFKit wrote.
/// Notebook's own strokes keep the tag, which tells them apart; Apple's annotations lose it again.
///
/// It also reads Apple's ink entries on the annotations PDFKit keeps them from: on a `/Square`, the kind PDFKit itself
/// makes of PencilKit drawings (Preview on iPhone and iPad saves handwriting so), PDFKit hands out no entry at all.
enum PDFMarkupEntries {
    /// The tag of Notebook's own ink annotations, and of every ink annotation while its PDF is written.
    static let notebookMarker = "NotebookInk"
    private static let marker = "/" + notebookMarker
    private static let extras = "/AAPL:AKExtras"
    private static let entry = "/AAPL:AKAnnotationV2"
    private static let snapshot = "/AAPL:AKPDFAnnotationDictionary"

    /// An ink entry to put on the annotation with its tag: Markup's archive, as Base64, and whether the annotation is
    /// one of Notebook's own.
    struct Kept {
        var archive: String
        var isNotebook: Bool
    }

    // MARK: - Putting the entries in

    /// `data`, a PDF as PDFKit writes it, with the entry of each tagged annotation put in, by its tag (`kept`), or the
    /// one PDFKit wrote, and the copy of the annotation next to it. What can't be read as PDFKit writes it (an
    /// incremental update, cross-references in a stream) is left as it is.
    static func completed(_ data: Data, kept: [String: Kept] = [:]) -> Data {
        guard data.range(of: Data(notebookMarker.utf8)) != nil else { return data }
        let bytes = [UInt8](data)
        guard let file = try? File(bytes) else { return data }
        var replaced: [Int: [UInt8]] = [:]
        for (number, object) in file.objects where object.body.contains(marker: notebookMarker) {
            guard var lexer = Lexer(dictionaryIn: object.body), let entries = lexer.dictionary(),
                  let tag = entries.first(where: { $0.key == marker })?.value else { continue }
            // The entry's own dictionary: in the annotation, or an object of its own.
            let extrasValue = entries.first { $0.key == extras }?.value
            let extrasObject = extrasValue.flatMap(Lexer.reference).flatMap { file.objects[$0] != nil ? $0 : nil }
            let written: [UInt8]? = {
                guard let value = extrasObject.flatMap({ file.objects[$0]?.body }) ?? extrasValue,
                      var inner = Lexer(dictionaryIn: value), let extrasEntries = inner.dictionary() else { return nil }
                return extrasEntries.first { $0.key == entry }?.value
            }()
            let found = Lexer.text(tag).flatMap { kept[$0] }
            let ink: [UInt8]
            if let found {
                ink = Array("(\(found.archive))".utf8)
            } else if let written {
                ink = written
            } else {
                continue
            }
            // The annotation as it is to be, then the copy of it, then the entry.
            let isNotebook = found?.isNotebook ?? true
            let annotation = entries.filter { $0.key != extras && (isNotebook || $0.key != marker) }
            var copy = Array("<<".utf8)
            for (key, value) in annotation where key != "/AP" {
                copy += Array(" \(key) ".utf8) + value
            }
            copy += Array(" >>".utf8)
            let completed = Array("<< \(entry) ".utf8) + ink + Array(" \(snapshot) ".utf8) + copy + Array(" >>".utf8)
            if let extrasObject, let value = extrasValue {
                replaced[extrasObject] = completed
                replaced[number] = Lexer.dictionary(annotation + [(key: extras, value: value)])
            } else {
                replaced[number] = Lexer.dictionary(annotation + [(key: extras, value: completed)])
            }
        }
        guard !replaced.isEmpty, let written = file.writing(replaced) else { return data }
        return Data(written)
    }

    // MARK: - Reading Apple's entries

    /// An ink entry found in the file, and the annotation it is on.
    struct FoundInk {
        var subtype: String
        /// The annotation's `/Rect`, in PDF points.
        var rect: CGRect
        var ink: MarkupInkArchive.Ink
        /// The entry as it is in the file, to be written back as it was.
        var archive: String
    }

    /// The ink entries on stamps and squares, by page number.
    static func inks(in document: CGPDFDocument) -> [Int: [FoundInk]] {
        var found: [Int: [FoundInk]] = [:]
        guard document.numberOfPages > 0 else { return found }
        for number in 1...document.numberOfPages {
            var annotations: CGPDFArrayRef?
            guard let page = document.page(at: number)?.dictionary, CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var name: UnsafePointer<CChar>?
                var extrasDictionary: CGPDFDictionaryRef?
                var text: CGPDFStringRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      CGPDFDictionaryGetName(annotation, "Subtype", &name), let name,
                      ["Stamp", "Square"].contains(String(cString: name)),
                      CGPDFDictionaryGetDictionary(annotation, String(extras.dropFirst()), &extrasDictionary), let extrasDictionary,
                      CGPDFDictionaryGetString(extrasDictionary, String(entry.dropFirst()), &text), let text,
                      let encoded = CGPDFStringCopyTextString(text) as String?,
                      let ink = MarkupInkArchive.decoded(encoded), let rect = rect(of: annotation) else { continue }
                found[number - 1, default: []].append(FoundInk(subtype: String(cString: name), rect: rect, ink: ink, archive: encoded))
            }
        }
        return found
    }

    private static func rect(of annotation: CGPDFDictionaryRef) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annotation, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in 0..<4 { guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil } }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]), width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    // MARK: - The file

    /// A PDF with one table of where its objects are, as PDFKit writes it.
    private struct File {
        struct Object {
            var generation: Int
            /// From the object's start up to the next one's.
            var range: Range<Int>
            /// What is between `obj` and `endobj`.
            var body: [UInt8]
        }

        let bytes: [UInt8]
        let objects: [Int: Object]
        let trailer: [UInt8]
        let size: Int
        let free: [Int: (next: Int, generation: Int)]
        let tableStart: Int

        enum Failure: Error { case unreadable }

        init(_ bytes: [UInt8]) throws {
            self.bytes = bytes
            // The last `startxref` says where the table is; it has to be a table, and the only one.
            guard let start = bytes.lastIndex(of: Array("startxref".utf8)) else { throw Failure.unreadable }
            var lexer = Lexer(bytes, at: start + 9)
            guard let offset = lexer.integer(), offset > 0, offset < bytes.count, bytes[offset...].starts(with: Array("xref".utf8)) else {
                throw Failure.unreadable
            }
            tableStart = offset
            lexer = Lexer(bytes, at: offset + 4)
            var entries: [Int: (offset: Int, generation: Int, used: Bool)] = [:]
            while let first = lexer.integer() {
                guard let count = lexer.integer() else { throw Failure.unreadable }
                for number in first..<(first + count) {
                    guard let place = lexer.integer(), let generation = lexer.integer(), let kind = lexer.word() else { throw Failure.unreadable }
                    entries[number] = (place, generation, kind == "n")
                }
            }
            guard lexer.word() == "trailer" else { throw Failure.unreadable }
            lexer.skipSpace()
            let trailerStart = lexer.position
            guard let fields = lexer.dictionary() else { throw Failure.unreadable }
            // An incremental update or a table in a stream: not as PDFKit writes.
            guard !fields.contains(where: { $0.key == "/Prev" || $0.key == "/XRefStm" }) else { throw Failure.unreadable }
            trailer = Array(bytes[trailerStart..<lexer.position])
            size = fields.first { $0.key == "/Size" }.flatMap { Int(String(decoding: $0.value, as: UTF8.self)) } ?? ((entries.keys.max() ?? 0) + 1)
            let used = entries.filter(\.value.used).sorted { $0.value.offset < $1.value.offset }
            var objects: [Int: Object] = [:]
            for (index, (number, entry)) in used.enumerated() {
                let end = index + 1 < used.count ? used[index + 1].value.offset : offset
                guard entry.offset < end, end <= bytes.count else { throw Failure.unreadable }
                let chunk = bytes[entry.offset..<end]
                guard let objStart = chunk.firstIndex(of: Array("obj".utf8)), let objEnd = chunk.lastIndex(of: Array("endobj".utf8)) else {
                    throw Failure.unreadable
                }
                objects[number] = Object(generation: entry.generation, range: entry.offset..<end, body: Array(bytes[(objStart + 3)..<objEnd]))
            }
            // Objects packed into streams: not as PDFKit writes.
            guard !objects.values.contains(where: { $0.body.contains(marker: "ObjStm") }) else { throw Failure.unreadable }
            self.objects = objects
            free = entries.filter { !$0.value.used }.mapValues { (next: $0.offset, generation: $0.generation) }
        }

        /// The file with the bodies of `replaced` objects changed, and its table made anew.
        func writing(_ replaced: [Int: [UInt8]]) -> [UInt8]? {
            let ordered = objects.sorted { $0.value.range.lowerBound < $1.value.range.lowerBound }
            guard let first = ordered.first?.value.range.lowerBound else { return nil }
            var output = Array(bytes[0..<first])
            var offsets: [Int: Int] = [:]
            for (number, object) in ordered {
                offsets[number] = output.count
                if let body = replaced[number] {
                    output += Array("\(number) \(object.generation) obj\n".utf8) + body + Array("\nendobj\n".utf8)
                } else {
                    output += bytes[object.range]
                }
            }
            let table = output.count
            output += Array("xref\n0 \(size)\n".utf8)
            for number in 0..<size {
                if let offset = offsets[number], let object = objects[number] {
                    output += Array(String(format: "%010d %05d n \n", offset, object.generation).utf8)
                } else {
                    let entry = free[number] ?? (next: 0, generation: number == 0 ? 65535 : 0)
                    output += Array(String(format: "%010d %05d f \n", entry.next, entry.generation).utf8)
                }
            }
            output += Array("trailer\n".utf8) + trailer + Array("\nstartxref\n\(table)\n%%EOF\n".utf8)
            return output
        }
    }

    // MARK: - Reading PDF syntax

    /// Reads PDF syntax, keeping each value as the very bytes it was written as.
    private struct Lexer {
        let bytes: [UInt8]
        var position: Int

        init(_ bytes: [UInt8], at position: Int = 0) {
            self.bytes = bytes
            self.position = position
        }

        /// At the dictionary in `bytes`, after any space.
        init?(dictionaryIn bytes: [UInt8]) {
            self.init(bytes, at: 0)
            skipSpace()
            guard position + 1 < bytes.count, bytes[position] == 0x3C, bytes[position + 1] == 0x3C else { return nil }
        }

        private static func isSpace(_ byte: UInt8) -> Bool { [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(byte) }
        private static func isDelimiter(_ byte: UInt8) -> Bool { Array("()<>[]{}/%".utf8).contains(byte) }

        mutating func skipSpace() {
            while position < bytes.count {
                if Self.isSpace(bytes[position]) {
                    position += 1
                } else if bytes[position] == 0x25 { // % comment
                    while position < bytes.count, bytes[position] != 0x0A, bytes[position] != 0x0D { position += 1 }
                } else {
                    return
                }
            }
        }

        /// A run of regular characters: a number, a keyword.
        mutating func word() -> String? {
            skipSpace()
            let start = position
            while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) { position += 1 }
            return position > start ? String(decoding: bytes[start..<position], as: UTF8.self) : nil
        }

        /// The next integer; nothing moves when there is none.
        mutating func integer() -> Int? {
            let saved = position
            guard let word = word(), let value = Int(word) else {
                position = saved
                return nil
            }
            return value
        }

        /// The entries of the dictionary here, each value as it is written.
        mutating func dictionary() -> [(key: String, value: [UInt8])]? {
            skipSpace()
            guard position + 1 < bytes.count, bytes[position] == 0x3C, bytes[position + 1] == 0x3C else { return nil }
            position += 2
            var entries: [(key: String, value: [UInt8])] = []
            while true {
                skipSpace()
                guard position < bytes.count else { return nil }
                if bytes[position] == 0x3E, position + 1 < bytes.count, bytes[position + 1] == 0x3E {
                    position += 2
                    return entries
                }
                guard bytes[position] == 0x2F, let key = name() else { return nil }
                skipSpace()
                let start = position
                guard skipValue() else { return nil }
                entries.append((key, Array(bytes[start..<position])))
            }
        }

        private mutating func name() -> String? {
            let start = position
            position += 1
            while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) { position += 1 }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        /// Past one value: a dictionary, an array, a string, a name, a number, a keyword, or a reference `n g R`.
        private mutating func skipValue() -> Bool {
            skipSpace()
            guard position < bytes.count else { return false }
            switch bytes[position] {
            case 0x3C where position + 1 < bytes.count && bytes[position + 1] == 0x3C:
                return dictionary() != nil
            case 0x3C: // <hex>
                guard let end = bytes[position...].firstIndex(of: 0x3E) else { return false }
                position = end + 1
                return true
            case 0x28: // (literal), with nested parentheses and escapes
                var depth = 0
                while position < bytes.count {
                    let byte = bytes[position]
                    position += 1
                    if byte == 0x5C { position += 1 } else if byte == 0x28 { depth += 1 } else if byte == 0x29 {
                        depth -= 1
                        if depth == 0 { return true }
                    }
                }
                return false
            case 0x5B: // [array]
                position += 1
                while true {
                    skipSpace()
                    guard position < bytes.count else { return false }
                    if bytes[position] == 0x5D {
                        position += 1
                        return true
                    }
                    guard skipValue() else { return false }
                }
            case 0x2F:
                return name() != nil
            default:
                guard let first = word() else { return false }
                // A reference: two integers and R.
                if Int(first) != nil {
                    let saved = position
                    if integer() != nil, word() == "R" { return true }
                    position = saved
                }
                return true
            }
        }

        /// The object a value refers to, for a value `n g R`.
        static func reference(_ value: [UInt8]) -> Int? {
            let words = String(decoding: value, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard words.count == 3, words[2] == "R", let number = Int(words[0]), Int(words[1]) != nil else { return nil }
            return number
        }

        /// A dictionary written from its entries.
        static func dictionary(_ entries: [(key: String, value: [UInt8])]) -> [UInt8] {
            var output = Array("<<".utf8)
            for entry in entries {
                output += Array(" \(entry.key) ".utf8) + entry.value
            }
            return output + Array(" >>".utf8)
        }

        /// What a literal string without escapes says, as PDFKit writes a tag.
        static func text(_ value: [UInt8]) -> String? {
            guard value.first == 0x28, value.last == 0x29, !value.contains(0x5C) else { return nil }
            return String(decoding: value.dropFirst().dropLast(), as: UTF8.self)
        }
    }
}

private extension Array where Element == UInt8 {
    func contains(marker: String) -> Bool { firstIndex(of: Array(marker.utf8)) != nil }
}

private extension Collection where Element == UInt8, Index == Int {
    /// Where `pattern` first starts.
    func firstIndex(of pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        var index = startIndex
        let last = endIndex - pattern.count
        while index <= last {
            if self[index] == pattern[0], self[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }

    /// Where `pattern` last starts.
    func lastIndex(of pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        var index = endIndex - pattern.count
        while index >= startIndex {
            if self[index] == pattern[0], self[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index -= 1
        }
        return nil
    }
}
