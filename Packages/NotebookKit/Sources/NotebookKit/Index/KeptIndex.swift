import Compression
import CryptoKit
import Foundation

/// The index as it was when the app last ran, kept in the app's caches: search finds everything the moment the app
/// opens, and the first reading of the locations reads only the notes and PDFs that changed since
/// (`SearchIndex.rebuild`).
///
/// A file of its own rather than a database: search goes through `SearchCorpus` in memory, so all this has to do is put
/// the entries back as they were, quickly. It is read with Foundation and the system's LZ4, in blocks on every core at
/// once: a hundred thousand files with a hundred megabytes of notes take a fraction of a second. It is written again in
/// the background a while after files change.
///
/// What is in it: a mark, the format's version and where the blocks are, with a checksum of each; then, each block
/// compressed on its own, the
/// locations and the folders the files are in, and blocks of files: each file's address, kind, date, size, whether it
/// is only in iCloud, its names, and for a note or PDF its text with the headings, the pictures it shows and the pages
/// without text. The text is kept as written, and folded for search again as it is read, which takes less time than
/// reading it twice as much from the disk. A file that isn't one of these, is of another version or is cut short or
/// damaged is left alone, and the index made from the files as if it weren't there.
enum KeptIndex {
    /// "NBIX", at the start of the file, and at the end of every block.
    static let mark: UInt32 = 0x5849_424E
    /// Goes up whenever what is kept changes, or what an entry is made of (how headings are found, which text is read):
    /// a file of another version is ignored, and every file read again.
    static let version: UInt32 = 1

    /// About how much a block of files holds before it is compressed: small enough for every core to have a few.
    private static let blockSize = 2_000_000
    private static let kinds: [FileKind] = [.folder, .note, .pdf, .image, .video, .audio, .other]

    private struct Corrupt: Error {}

    // MARK: - Writing

    /// Writes the entries of some locations, for `read` to put back.
    static func write(_ entries: some Collection<SearchIndex.Entry>, locations: [(id: UUID, path: String)], to url: URL) throws {
        // The files of a folder together: they share its address, which compresses well.
        var folders: [(path: String, place: String)] = []
        var folderIndex: [String: Int] = [:]
        var byFolder: [[SearchIndex.Entry]] = []
        for entry in entries {
            if let index = folderIndex[entry.folder] {
                byFolder[index].append(entry)
            } else {
                folderIndex[entry.folder] = folders.count
                folders.append((entry.folder, entry.place))
                byFolder.append([entry])
            }
        }
        // Locations are kept by their folders' addresses, as the IDs of folders given on the command line are new at
        // every launch.
        var locationIndex: [UUID: Int] = [:]
        var tables = Writer()
        tables.int(locations.count)
        for (index, location) in locations.enumerated() {
            tables.string(location.path)
            locationIndex[location.id] = index
        }
        tables.int(folders.count)
        for folder in folders {
            tables.string(folder.path)
            tables.string(folder.place)
        }
        tables.int(Int(mark))
        var blocks = [tables.bytes]
        var block = Writer()
        var count = 0
        func finishBlock() {
            guard count > 0 else { return }
            block.int(Int(mark))
            var counted = Writer()
            counted.int(count)
            blocks.append(counted.bytes + block.bytes)
            block = Writer()
            count = 0
        }
        for (folder, entries) in byFolder.enumerated() {
            for entry in entries {
                write(entry, folder: folder, location: locationIndex[entry.locationID] ?? -1, to: &block)
                count += 1
                if block.bytes.count >= blockSize { finishBlock() }
            }
        }
        finishBlock()
        var header = Writer()
        header.int(Int(mark))
        header.int(Int(version))
        header.int(blocks.count)
        var compressed: [[UInt8]] = []
        for block in blocks {
            let packed = try compress(block)
            header.int(packed.count)
            header.int(block.count)
            header.int64(packed.withUnsafeBufferPointer { checksum(of: $0) })
            compressed.append(packed)
        }
        var data = Data(header.bytes)
        for packed in compressed { data.append(contentsOf: packed) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func write(_ entry: SearchIndex.Entry, folder: Int, location: Int, to writer: inout Writer) {
        writer.string(entry.path)
        writer.byte(UInt8(kinds.firstIndex(of: entry.kind) ?? kinds.count - 1))
        var flags: UInt8 = 0
        if entry.isInCloud { flags |= 1 }
        if entry.modified != nil { flags |= 2 }
        if entry.size != nil { flags |= 4 }
        if entry.text != nil { flags |= 8 }
        writer.byte(flags)
        writer.int(location)
        writer.int(folder)
        if let modified = entry.modified { writer.int64(Int64(bitPattern: modified.timeIntervalSinceReferenceDate.bitPattern)) }
        if let size = entry.size { writer.int64(Int64(size)) }
        writer.string(entry.name)
        writer.string(entry.foldedName)
        writer.string(entry.foldedFileName)
        if let text = entry.text { writer.string(text) }
        writer.int(entry.headings.count)
        for heading in entry.headings {
            writer.byte(UInt8(clamping: heading.level))
            writer.string(heading.title)
        }
        writer.int(entry.assets.count)
        for asset in entry.assets { writer.string(asset) }
        writer.int(entry.pagesWithoutText.count)
        for page in entry.pagesWithoutText { writer.int(page) }
    }

    private static func compress(_ bytes: [UInt8]) throws -> [UInt8] {
        let capacity = bytes.count + bytes.count / 64 + 4096
        let packed = [UInt8](unsafeUninitializedCapacity: capacity) { buffer, count in
            count = bytes.withUnsafeBufferPointer { source in
                compression_encode_buffer(buffer.baseAddress!, capacity, source.baseAddress!, source.count, nil, COMPRESSION_LZ4)
            }
        }
        guard !packed.isEmpty || bytes.isEmpty else { throw Corrupt() }
        return packed
    }

    /// The start of the bytes' SHA-256: a block damaged on the disk is never taken for what was written, which
    /// LZ4 alone doesn't tell.
    private static func checksum(of bytes: UnsafeBufferPointer<UInt8>) -> Int64 {
        SHA256.hash(data: UnsafeRawBufferPointer(bytes)).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func byte(_ value: UInt8) {
            bytes.append(value)
        }

        mutating func int(_ value: Int) {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func int64(_ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func string(_ value: String) {
            var value = value
            value.withUTF8 { utf8 in
                int(utf8.count)
                bytes.append(contentsOf: utf8)
            }
        }
    }

    // MARK: - Reading

    /// The entries kept in a file that are in the locations there are now (by their folders' addresses), with these
    /// locations' IDs; nil if there is no such file, or it is of another version or can't be read.
    static func read(_ url: URL, locations: [(id: UUID, path: String)]) -> [SearchIndex.Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { raw -> [SearchIndex.Entry]? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return try? read(UnsafeBufferPointer(start: base, count: raw.count), locations: locations)
        }
    }

    private static func read(_ file: UnsafeBufferPointer<UInt8>, locations: [(id: UUID, path: String)]) throws -> [SearchIndex.Entry] {
        var header = Reader(file)
        guard try header.int() == Int(mark), try header.int() == Int(version) else { throw Corrupt() }
        var blocks: [Block] = []
        var lengths: [(packed: Int, size: Int, checksum: Int64)] = []
        for _ in 0..<(try header.count()) { lengths.append((try header.int(), try header.int(), try header.int64())) }
        for length in lengths { blocks.append(Block(packed: try header.take(length.packed), size: length.size, checksum: length.checksum)) }
        guard header.isAtEnd, let first = blocks.first else { throw Corrupt() }

        var ids: [UUID?] = []
        var folders: [(path: String, place: String)] = []
        try unpack(first).withUnsafeBufferPointer { tables in
            var reader = Reader(tables)
            for _ in 0..<(try reader.count()) {
                let path = try reader.string()
                ids.append(locations.first { $0.path == path }?.id)
            }
            for _ in 0..<(try reader.count()) { folders.append((try reader.string(), try reader.string())) }
            guard try reader.int() == Int(mark), reader.isAtEnd else { throw Corrupt() }
        }

        // Each block on a core of its own. The threads read what they share through pointers taken once: in a Debug
        // build, every use of a shared array from many threads at once would fight over its reference count.
        var parts = [[SearchIndex.Entry]?](repeating: nil, count: blocks.count - 1)
        blocks.withUnsafeBufferPointer { blocks in
            ids.withUnsafeBufferPointer { ids in
                folders.withUnsafeBufferPointer { folders in
                    parts.withUnsafeMutableBufferPointer { parts in
                        DispatchQueue.concurrentPerform(iterations: parts.count) { index in
                            parts[index] = try? entries(in: blocks[index + 1], ids: ids, folders: folders)
                        }
                    }
                }
            }
        }
        var entries: [SearchIndex.Entry] = []
        entries.reserveCapacity(parts.reduce(0) { $0 + ($1?.count ?? 0) })
        for part in parts {
            guard let part else { throw Corrupt() }
            entries += part
        }
        return entries
    }

    private struct Block {
        let packed: UnsafeBufferPointer<UInt8>
        /// Unpacked.
        let size: Int
        let checksum: Int64
    }

    private static func unpack(_ block: Block) throws -> [UInt8] {
        guard checksum(of: block.packed) == block.checksum else { throw Corrupt() }
        let bytes = [UInt8](unsafeUninitializedCapacity: block.size) { buffer, count in
            count = block.size == 0 ? 0 : compression_decode_buffer(buffer.baseAddress!, block.size, block.packed.baseAddress!, block.packed.count, nil, COMPRESSION_LZ4)
        }
        guard bytes.count == block.size else { throw Corrupt() }
        return bytes
    }

    private static func entries(in block: Block, ids: UnsafeBufferPointer<UUID?>,
                                folders: UnsafeBufferPointer<(path: String, place: String)>) throws -> [SearchIndex.Entry] {
        let bytes = try unpack(block)
        return try bytes.withUnsafeBufferPointer { bytes in
            var reader = Reader(bytes)
            let count = try reader.count()
            var entries: [SearchIndex.Entry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let path = try reader.string()
                let kindIndex = Int(try reader.byte())
                let flags = try reader.byte()
                let location = try reader.int()
                let folderIndex = try reader.int()
                guard kindIndex < kinds.count, folderIndex < folders.count else { throw Corrupt() }
                let modified = flags & 2 != 0 ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(bitPattern: try reader.int64()))) : nil
                let size = flags & 4 != 0 ? Int(try reader.int64()) : nil
                let name = try reader.string()
                let foldedName = try reader.string()
                let foldedFileName = try reader.string()
                let text = flags & 8 != 0 ? try reader.string() : nil
                var headings: [SearchIndex.Heading] = []
                for _ in 0..<(try reader.count()) {
                    let level = Int(try reader.byte())
                    headings.append(SearchIndex.Heading(level: level, title: try reader.string()))
                }
                var assets: [String] = []
                for _ in 0..<(try reader.count()) { assets.append(try reader.string()) }
                var pages: [Int] = []
                for _ in 0..<(try reader.count()) { pages.append(try reader.int()) }
                // In a location that is gone.
                guard location < ids.count, let id = ids[location] else { continue }
                let kind = kinds[kindIndex]
                let folder = folders[folderIndex]
                entries.append(SearchIndex.Entry(url: URL(fileURLWithPath: path, isDirectory: kind == .folder), name: name, kind: kind,
                                                 place: folder.place, locationID: id, modified: modified, size: size,
                                                 isInCloud: flags & 1 != 0, text: text, folded: text.map(SearchIndex.fold),
                                                 foldedName: foldedName, foldedFileName: foldedFileName, path: path, folder: folder.path,
                                                 headings: headings, assets: assets, pagesWithoutText: pages))
            }
            guard try reader.int() == Int(mark), reader.isAtEnd else { throw Corrupt() }
            return entries
        }
    }

    /// Goes through bytes, never past their end.
    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0

        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func take(_ count: Int) throws -> UnsafeBufferPointer<UInt8> {
            guard count >= 0, count <= bytes.count - offset, let base = bytes.baseAddress else { throw Corrupt() }
            defer { offset += count }
            return UnsafeBufferPointer(start: base + offset, count: count)
        }

        mutating func byte() throws -> UInt8 {
            try take(1)[0]
        }

        mutating func int() throws -> Int {
            Int(UInt32(littleEndian: UnsafeRawPointer(try take(4).baseAddress!).loadUnaligned(as: UInt32.self)))
        }

        /// A number of things to come, each at least a byte long: no more than there are bytes left.
        mutating func count() throws -> Int {
            let count = try int()
            guard count <= bytes.count - offset else { throw Corrupt() }
            return count
        }

        mutating func int64() throws -> Int64 {
            Int64(littleEndian: UnsafeRawPointer(try take(8).baseAddress!).loadUnaligned(as: Int64.self))
        }

        mutating func string() throws -> String {
            String(decoding: try take(try int()), as: UTF8.self)
        }
    }
}
