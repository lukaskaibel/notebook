#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import PDFKit
import PencilKit
import Vision

/// Text read in a picture, a scan or a drawing, for search.
struct PictureText: Sendable {
    let text: String
    let folded: String
    /// Handwriting in a drawing, rather than text in a picture.
    let isHandwriting: Bool

    init(_ text: String, isHandwriting: Bool) {
        self.text = text
        self.folded = SearchIndex.fold(text)
        self.isHandwriting = isHandwriting
    }
}

/// Reads the words in pictures with Vision, as Live Text does, in the pages of PDFs that have no text of their own,
/// and the handwriting in drawings with PencilKit, so search finds them. Pictures in the locations count, and those in
/// notes (in `.assets`), whose words are found as the note's.
///
/// It goes one file at a time in the background, waits in Low Power Mode and while the device is hot, reads only what
/// is on this device, and keeps what it read between launches, so each file is read once, until it changes.
@MainActor
final class TextRecognizer {
    enum Kind: Sendable, Equatable {
        case picture
        /// A drawing's picture: the strokes next to it are read for handwriting.
        case drawing
        /// A PDF, with the pages that have no text, counted from 0.
        case scan(pages: [Int])
    }

    struct Job: Sendable {
        let url: URL
        /// Where the text goes in the index: the file's address, or `folder/.assets/name` for a picture in a note.
        let key: String
        let kind: Kind
    }

    private struct Record: Sendable {
        var modified: Double
        var size: Int
        var reading: PictureText
    }

    /// Weak, so reading that finishes after its index is gone (in tests) is dropped rather than crashing.
    private weak var index: SearchIndex?
    private let storeURL: URL?
    private var records: [String: Record] = [:]
    /// What is still to be read, the next last, so taking it is quick with tens of thousands.
    private var queue: [Job] = []
    private var queued = Set<String>()
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var isLoaded = false
    /// Files found before what was read before had been loaded.
    private var waiting: [Job] = []
    private var unsaved = 0
    private var publishScheduled = false
    private(set) var isEnabled = false
    /// How many files were read since launch, for the debug remote.
    private(set) var readCount = 0

    /// Pictures smaller than this, on their longer side, are icons and the like: nothing to read.
    nonisolated static let smallestPicture = 64
    /// Pages of a scan read at most, from the first.
    nonisolated static let mostPages = 60

    init(index: SearchIndex, storeURL: URL? = TextRecognizer.defaultStoreURL) {
        self.index = index
        self.storeURL = storeURL
    }

    /// In the app's caches: what was read can always be read again.
    nonisolated static var defaultStoreURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notebook", isDirectory: true)
            .appendingPathComponent("Text in pictures.plist")
    }

    /// Starts reading, with what was read before going to search at once.
    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        guard !isLoaded else {
            publish()
            run()
            return
        }
        let url = storeURL
        Task.detached(priority: .utility) { [weak self] in
            let loaded = url.flatMap(Self.load) ?? [:]
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (key, record) in loaded where self.records[key] == nil { self.records[key] = record }
                self.isLoaded = true
                self.publish()
                self.add(self.waiting)
                self.waiting = []
            }
        }
    }

    /// Stops reading, and search no longer finds what was read; it stays kept for when it starts again.
    func stop() {
        isEnabled = false
        worker?.cancel()
        worker = nil
        queue = []
        queued = []
        index?.recognized = [:]
    }

    /// Looks for what to read among files the index found or read again: pictures, the pictures and drawings in
    /// notes, and PDFs with pages without text. Sorted out in the background, as there can be a hundred thousand.
    func consider(_ entries: [String: SearchIndex.Entry]) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) { [weak self] in
            let jobs = Self.jobs(in: entries.values)
            await MainActor.run { [weak self] in self?.add(jobs) }
        }
    }

    /// What to read among some files, in the order to read it: the pictures and drawings in notes and the scans first,
    /// then the pictures in the folders, which can be thousands of photos.
    nonisolated static func jobs(in entries: some Sequence<SearchIndex.Entry>) -> [Job] {
        var first: [Job] = [], later: [Job] = []
        for entry in entries where !entry.isInCloud {
            switch entry.kind {
            case .image where isReadable(entry.url):
                later.append(Job(url: entry.url, key: entry.path, kind: .picture))
            case .pdf where !entry.pagesWithoutText.isEmpty:
                first.append(Job(url: entry.url, key: entry.path, kind: .scan(pages: entry.pagesWithoutText)))
            case .note:
                for asset in entry.assets {
                    let url = URL(fileURLWithPath: entry.folder).appendingPathComponent(".assets").appendingPathComponent(asset)
                    guard isReadable(url) else { continue }
                    first.append(Job(url: url, key: entry.folder + "/.assets/" + asset, kind: DrawingFile.isDrawing(url) ? .drawing : .picture))
                }
            default:
                break
            }
        }
        return first + later
    }

    /// Pictures Vision reads: not vector art or animations.
    nonisolated private static func isReadable(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "webp"].contains(url.pathExtension.lowercased())
    }

    private func add(_ jobs: [Job]) {
        guard isLoaded else {
            waiting += jobs
            return
        }
        let fresh = jobs.filter { queued.insert($0.key).inserted }
        // After what is waiting already, which is at the front.
        queue.insert(contentsOf: fresh.reversed(), at: 0)
        run()
    }

    // MARK: - Reading

    private func run() {
        guard isEnabled, worker == nil, !queue.isEmpty else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            while let self, self.isEnabled, let job = self.nextJob() {
                let known = self.records[job.key].map { (modified: $0.modified, size: $0.size) }
                let outcome = await Task.detached(priority: .utility) { await Self.read(job, known: known) }.value
                guard !Task.isCancelled else { break }
                self.queued.remove(job.key)
                switch outcome {
                case .unchanged:
                    continue
                case .gone:
                    if self.records.removeValue(forKey: job.key) != nil { self.changed() }
                case .read(let reading, let modified, let size):
                    self.records[job.key] = Record(modified: modified, size: size, reading: reading)
                    self.readCount += 1
                    self.changed()
                }
            }
            guard let self, self.workerID == id else { return }
            self.worker = nil
            self.publish()
            self.save()
        }
    }

    private func nextJob() -> Job? {
        queue.popLast()
    }

    private enum Outcome: Sendable {
        case unchanged
        case gone
        case read(PictureText, modified: Double, size: Int)
    }

    /// Reads a file, unless it is as it was when it was read before. One that is only in iCloud now keeps what was read
    /// while it was here.
    nonisolated private static func read(_ job: Job, known: (modified: Double, size: Int)?) async -> Outcome {
        let placeholder = job.url.deletingLastPathComponent().appendingPathComponent(".\(job.url.lastPathComponent).icloud")
        guard let values = try? job.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]) else {
            return FileManager.default.fileExists(atPath: placeholder.path) ? .unchanged : .gone
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .unchanged }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let size = values.fileSize ?? 0
        if let known, known.modified == modified, known.size == size { return .unchanged }
        await waitForGoodTime()
        let text: String
        var isHandwriting = false
        switch job.kind {
        case .picture:
            text = picture(job.url).map(recognize) ?? ""
        case .drawing:
            isHandwriting = true
            text = await handwriting(in: job.url) ?? picture(job.url).map(recognize) ?? ""
        case .scan(let pages):
            text = scan(job.url, pages: pages)
        }
        return .read(PictureText(text, isHandwriting: isHandwriting), modified: modified, size: size)
    }

    /// Not on battery saver, and not while the device is hot: this can wait.
    nonisolated private static func waitForGoodTime() async {
        while ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
        }
    }

    /// The picture, turned as it is shown and at most so large that Vision reads it quickly.
    nonisolated static func picture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) >= smallestPicture else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2600,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The lines of text Vision finds in a picture, top to bottom.
    nonisolated static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// What is written in a drawing, read from its strokes.
    nonisolated private static func handwriting(in picture: URL) async -> String? {
        guard let file = DrawingFile.read(picture: picture), !file.drawing.strokes.isEmpty else { return nil }
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(file.drawing)
        guard let text = await recognizer.indexableContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The text on the pages of a PDF that have none of their own, read from their pictures; every page up to the
    /// last one read is there, split by form feeds, so search can say which page it is on.
    nonisolated private static func scan(_ url: URL, pages: [Int]) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let wanted = Set(pages.filter { $0 < mostPages })
        guard let last = wanted.max() else { return "" }
        var texts: [String] = []
        for index in 0...last {
            guard wanted.contains(index), let page = document.page(at: index), let image = render(page) else {
                texts.append("")
                continue
            }
            texts.append(recognize(image))
        }
        return texts.joined(separator: "\u{0C}")
    }

    /// A page as a picture about 2000 pixels on its longer side, on white.
    nonisolated private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(4, 2000 / max(box.width, box.height))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Search and the disk

    /// Hands what was read to search: soon after the first file, then at most every few seconds, as each new set makes
    /// search's corpus again.
    private func changed() {
        unsaved += 1
        if unsaved >= 50 { save() }
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (queue.isEmpty ? 0.3 : 8)) { [weak self] in
            self?.publishScheduled = false
            self?.publish()
        }
    }

    private func publish() {
        guard isEnabled else { return }
        index?.recognized = records.mapValues(\.reading)
    }

    private func save() {
        unsaved = 0
        guard let storeURL else { return }
        let list = records.mapValues { [$0.modified, $0.size, $0.reading.text, $0.reading.isHandwriting] as [Any] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    nonisolated private static func load(_ url: URL) -> [String: Record]? {
        guard let data = try? Data(contentsOf: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [Any]] else { return nil }
        var records: [String: Record] = [:]
        for (key, values) in list where values.count == 4 {
            guard let modified = values[0] as? Double, let size = values[1] as? Int, let text = values[2] as? String,
                  let handwriting = values[3] as? Bool else { continue }
            records[key] = Record(modified: modified, size: size, reading: PictureText(text, isHandwriting: handwriting))
        }
        return records
    }

    #if DEBUG
    /// What it is doing, for the debug remote.
    var status: String {
        "enabled=\(isEnabled) loaded=\(isLoaded) queued=\(queue.count) reading=\(worker != nil) read=\(readCount) kept=\(records.count)"
    }

    /// What was read in a file, for the debug remote.
    func text(for key: String) -> String? { records[key]?.reading.text }
    #endif
}
