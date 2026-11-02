#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit
import PencilKit

/// What a PDF drawn on is to be, to be written into the file: its pages in order, each one of the file's as it was
/// when drawing started or a new page of paper, and what is now on each page drawn on. The file's pages can come in
/// any order, and one can come more than once: a page moved, and a page duplicated.
struct PDFPlan: Sendable {
    enum Origin: Equatable, Sendable {
        /// The page with this number in `PDFPageWriter.write`'s `base`. A copy of it, the second time it is there.
        case base(Int)
        case new
    }

    struct Slot: Sendable {
        var origin: Origin
        /// The paper for a new page, or for one of the file's that gets other paper; nil keeps the page as it is.
        var paper: PaperStyle?
        /// In points, for a new page.
        var size: CGSize
        /// What is on the page now, for a page drawn on; nil leaves what it has.
        var content: PageContent?
    }

    var slots: [Slot]

    /// What the pictures written without what they show do show, for those `ids` (what the base has) doesn't have,
    /// from `base`, a PDF that had them.
    mutating func fillPictures(missingFrom ids: Set<String>, from base: Data) {
        let missing = Set(slots.flatMap { $0.content?.pictures.filter { $0.image == nil }.map(\.id) ?? [] }).subtracting(ids)
        guard !missing.isEmpty, let document = CGDataProvider(data: base as CFData).flatMap(CGPDFDocument.init) else { return }
        let images = PDFPictures.images(in: document)
        for index in slots.indices {
            guard let pictures = slots[index].content?.pictures else { continue }
            slots[index].content?.pictures = pictures.map { picture in
                var picture = picture
                if picture.image == nil, missing.contains(picture.id) { picture.image = images[picture.id] }
                return picture
            }
        }
    }
}

/// Why a PDF drawn on couldn't be written. Not expected to happen: it says where, for a report.
enum PDFWriteError: LocalizedError {
    case pagesMissing([Int], Int)
    case pageCount(Int, Int)
    case noPaper
    case noPictures
    case notWritten

    var errorDescription: String? {
        switch self {
        case .pagesMissing(let kept, let count): "Pages \(kept.map { String($0 + 1) }.joined(separator: ", ")) of \(count) aren’t there."
        case .pageCount(let made, let planned): "It came out with \(made) pages instead of \(planned)."
        case .noPaper: "A new page couldn’t be made."
        case .noPictures: "The pictures couldn’t be put on the page."
        case .notWritten: "PDFKit couldn’t write it."
        }
    }
}

/// What Notebook keeps on a page: strokes measured from the top left of its crop box, and pictures.
struct PageContent: Sendable {
    var drawing = PKDrawing()
    var pictures: [PDFPicture] = []
}

/// Writes a `PDFPlan` into a PDF, off the main thread, on `PDFInk.queue` with every other change to a PDF. The pages
/// come from `base`, the PDF as it was read when drawing started, so pages taken out can be put back with Undo; what
/// the file had and the plan doesn't change stays as it was, pictures that move keep their JPEG, and the file is written
/// anew with only what its pages use.
enum PDFPageWriter {
    nonisolated static func write(_ plan: PDFPlan, base: Data, to url: URL) throws {
        let data = try make(plan, base: base)
        #if DEBUG
        // `-NotebookSlowDrawingSaves <seconds>`: a slow save, for trying out what waits for it.
        let delay = UserDefaults.standard.double(forKey: "NotebookSlowDrawingSaves")
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        #endif
        var failure: Error?
        var coordination: NSError?
        // Written in place, so the file keeps its tags, its colour and its place in the folder.
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try data.write(to: url) } catch { failure = error }
        }
        if let error = failure ?? coordination { throw error }
    }

    /// The PDF the plan makes of `base`.
    static func make(_ plan: PDFPlan, base: Data) throws -> Data {
        guard let document = PDFDocument(data: base), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
        // The pictures already in the file, for those that move and for writing the file anew; and the new ones.
        var images = base.range(of: Data("NotebookPicture".utf8)) == nil ? [:]
            : CGDataProvider(data: base as CFData).flatMap(CGPDFDocument.init).map { PDFPictures.images(in: $0) } ?? [:]
        for slot in plan.slots {
            for picture in slot.content?.pictures ?? [] { if let image = picture.image { images[picture.id] = image } }
        }
        let carriers = Carriers()
        try apply(plan, to: document, base: base, images: images, carriers: carriers)
        let written = try compacted(document, images: images, carriers: carriers) ?? document
        // Entries PDFKit doesn't know are written only once read, on the Mac at least.
        for index in 0..<written.pageCount { written.page(at: index)?.annotations.forEach(keepEntries) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard written.write(to: temporary) else { throw PDFWriteError.notWritten }
        // Only now: the looks of the pictures carried in are still the carriers' until written.
        withExtendedLifetime(carriers) {}
        return try Data(contentsOf: temporary)
    }

    /// The file as it was changed elsewhere, as what saves start from now (`current`), with pages of the old `base`
    /// after its own (`keeping`): pages taken out, or put back since, that the file doesn't have, so Undo can put them
    /// back as they were. Where each of those is in it.
    static func rebase(_ current: Data, keeping kept: [Int], from base: Data) throws -> (base: Data, places: [Int: Int]) {
        guard !kept.isEmpty else { return (current, [:]) }
        guard let document = PDFDocument(data: current), !document.isLocked, let old = PDFDocument(data: base) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Taken before any goes in: a page goes from its document into the other.
        let pages = kept.compactMap { index in old.page(at: index).map { (index, $0) } }
        var places: [Int: Int] = [:]
        for (index, page) in pages {
            places[index] = document.pageCount
            document.insert(page, at: document.pageCount)
        }
        // Written again, the file's own pages too keep only what has been read.
        for index in 0..<document.pageCount { document.page(at: index)?.annotations.forEach(keepEntries) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary) else { throw PDFWriteError.notWritten }
        // Only now: what those pages have keeps reading its look from the old base until written.
        withExtendedLifetime(old) {}
        return (try Data(contentsOf: temporary), places)
    }

    /// The PDFs pictures were carried in from. A stamp moved from one keeps reading its look from it, so they stay
    /// until the document is written.
    final class Carriers {
        var documents: [PDFDocument] = []
    }

    /// Makes the document read from `base` into what the plan says. `images` are the pictures in `base`, by id.
    static func apply(_ plan: PDFPlan, to document: PDFDocument, base: Data, images: [String: PictureImage] = [:], carriers: Carriers) throws {
        let kept = plan.slots.compactMap { slot -> Int? in
            if case .base(let index) = slot.origin { return index }
            return nil
        }
        guard kept.allSatisfy({ $0 >= 0 && $0 < document.pageCount }) else {
            throw PDFWriteError.pagesMissing(kept, document.pageCount)
        }
        // The pages in the plan's order: the file's own the first time, a copy read from `base` after that, new paper.
        let originals = (0..<document.pageCount).compactMap { document.page(at: $0) }
        var used = Set<Int>()
        // `base` read again for the copies, each time for one copy of any of its pages: as often as the page copied
        // most often has copies, not for every copy.
        var copies: [(document: PDFDocument, used: Set<Int>)] = []
        var pages: [PDFPage] = []
        for slot in plan.slots {
            switch slot.origin {
            case .base(let index) where used.insert(index).inserted:
                pages.append(originals[index])
            case .base(let index):
                // A page of a document of its own, as a picture is carried in: what it has keeps its look until written.
                if !copies.contains(where: { !$0.used.contains(index) }) {
                    guard let read = PDFDocument(data: base) else { throw PDFWriteError.pagesMissing(kept, document.pageCount) }
                    carriers.documents.append(read)
                    copies.append((read, []))
                }
                guard let round = copies.firstIndex(where: { !$0.used.contains(index) }), let copy = copies[round].document.page(at: index) else {
                    throw PDFWriteError.pagesMissing(kept, document.pageCount)
                }
                copies[round].used.insert(index)
                copy.annotations.forEach(keepEntries)
                pages.append(copy)
            case .new:
                guard let page = NotebookPaper.page(slot.paper ?? .blank, size: slot.size) else { throw PDFWriteError.noPaper }
                pages.append(page)
            }
        }
        // The ones the plan doesn't have go; the rest are put in its order, the file's own moved rather than copied.
        let own = Set(pages.map(ObjectIdentifier.init))
        for index in stride(from: document.pageCount - 1, through: 0, by: -1) where !own.contains(ObjectIdentifier(originals[index])) {
            document.removePage(at: index)
        }
        let isOriginal = Set(originals.map(ObjectIdentifier.init))
        for (position, page) in pages.enumerated() where document.page(at: position) !== page {
            if isOriginal.contains(ObjectIdentifier(page)) {
                let index = document.index(for: page)
                guard index != NSNotFound else { throw PDFWriteError.pagesMissing(kept, originals.count) }
                document.exchangePage(at: position, withPageAt: index)
            } else {
                document.insert(page, at: position)
            }
        }
        for (position, slot) in plan.slots.enumerated() {
            switch slot.origin {
            case .new:
                if let inserted = document.page(at: position), let paper = slot.paper { NotebookPaper.mark(inserted, as: paper) }
            case .base:
                guard let paper = slot.paper, let old = document.page(at: position), NotebookPaper.style(of: old) != paper else { continue }
                try replacePaper(at: position, with: paper, in: document)
            }
        }
        guard document.pageCount == plan.slots.count else { throw PDFWriteError.pageCount(document.pageCount, plan.slots.count) }
        for (position, slot) in plan.slots.enumerated() {
            guard let content = slot.content, let page = document.page(at: position) else { continue }
            try write(content, on: page, in: document, images: images, carriers: carriers)
        }
    }

    /// Gives the page other paper: a page of it in its place, with everything that was on it.
    private static func replacePaper(at index: Int, with paper: PaperStyle, in document: PDFDocument) throws {
        guard let old = document.page(at: index) else { return }
        let crop = old.bounds(for: .cropBox)
        guard let page = NotebookPaper.page(paper, size: crop.size) else { throw PDFWriteError.noPaper }
        document.insert(page, at: index + 1)
        guard let new = document.page(at: index + 1) else { return }
        let newCrop = new.bounds(for: .cropBox)
        let shift = CGAffineTransform(translationX: newCrop.minX - crop.minX, y: newCrop.minY - crop.minY)
        for annotation in old.annotations where annotation.value(forAnnotationKey: NotebookPaper.key) == nil {
            keepEntries(of: annotation)
            old.removeAnnotation(annotation)
            // Measured from the same corner. (Moving one makes PDFKit draw its look anew, so only when it has to.)
            if !shift.isIdentity { annotation.bounds = annotation.bounds.applying(shift) }
            new.addAnnotation(annotation)
        }
        NotebookPaper.mark(new, as: paper)
        document.removePage(at: index)
    }

/// Puts the page's strokes and pictures in place of the ones it had: pictures under the strokes, and stamps of
    /// pictures that didn't move left as they are.
    private static func write(_ content: PageContent, on page: PDFPage, in document: PDFDocument, images: [String: PictureImage], carriers: Carriers) throws {
        for annotation in page.annotations where MarkupDrawings.strokes(in: annotation, on: page) != nil {
            page.removeAnnotation(annotation)
        }
        let existing = PDFPictures.pictures(on: page)
        var placed: [PDFPicture] = []
        for picture in content.pictures {
            if let old = existing.first(where: { $0.picture.id == picture.id }), old.picture.isPlaced(like: picture), picture.image == nil {
                continue
            }
            var picture = picture
            if picture.image == nil { picture.image = images[picture.id] }
            if picture.image != nil { placed.append(picture) }
        }
        let kept = Set(content.pictures.map(\.id)).subtracting(placed.map(\.id))
        for (annotation, picture) in existing where !kept.contains(picture.id) {
            page.removeAnnotation(annotation)
        }
        if !placed.isEmpty { try carry(placed, onto: page, in: document, carriers: carriers) }
        if !content.drawing.strokes.isEmpty {
            page.addAnnotation(InkAnnotation(drawing: content.drawing, on: page))
        }
    }

    /// Puts stamps made in a PDF of their own on the page: carried in on a page of their own, which goes again.
    private static func carry(_ pictures: [PDFPicture], onto page: PDFPage, in document: PDFDocument, carriers: Carriers) throws {
        let crop = page.bounds(for: .cropBox)
        guard let carrierDocument = PDFDocument(data: PDFPictures.carrier(pictures, crop: crop)), let carrier = carrierDocument.page(at: 0) else {
            throw PDFWriteError.noPictures
        }
        carriers.documents.append(carrierDocument)
        for annotation in carrier.annotations { keepEntries(of: annotation) }
        let index = document.pageCount
        document.insert(carrier, at: index)
        guard let inserted = document.page(at: index) else { throw PDFWriteError.noPictures }
        for annotation in inserted.annotations {
            keepEntries(of: annotation)
            inserted.removeAnnotation(annotation)
            page.addAnnotation(annotation)
        }
        document.removePage(at: index)
    }

    /// The entries PDFKit doesn't know: it keeps one when the annotation goes to another page or document only once
    /// it has been read. Markup's only on its drawings (`MarkupDrawings.isMarkup`); on others PDFKit writes what it
    /// knows of them and leaves it out.
    static func keepEntries(of annotation: PDFAnnotation) {
        for key in [MarkupDrawings.notebookKey, PDFPictures.key, NotebookPaper.key] {
            _ = annotation.value(forAnnotationKey: key)
        }
        if MarkupDrawings.isMarkup(annotation) { _ = annotation.value(forAnnotationKey: MarkupDrawings.extrasKey) }
    }

    /// The document written anew with only what its pages use. PDFKit writes again everything the file had, the
    /// annotations taken off too, so a PDF drawn on would grow with every save. Its pages go into a document of their
    /// own, where an annotation PDFKit read keeps its entries once they have been read, but not its look: Notebook's
    /// strokes and pictures are made again, with the pictures in `images`. So it is only for a PDF whose other
    /// annotations PDFKit draws itself (links, notes, highlights), without an outline or a form, which live outside its
    /// pages: anything else keeps growing a little rather than lose something.
    static func compacted(_ document: PDFDocument, images: [String: PictureImage], carriers: Carriers) throws -> PDFDocument? {
        guard document.outlineRoot == nil, !document.isEncrypted, document.pageCount > 0 else { return nil }
        let redrawn: Set<String> = ["Link", "Text", "Popup", "Highlight", "Underline", "StrikeOut", "Squiggly", "Square", "Circle", "Line"]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return nil }
            for annotation in page.annotations {
                // Notebook's own, which are made again. (On the Mac, PDFKit gives every stamp Markup's entry too.)
                if annotation.value(forAnnotationKey: MarkupDrawings.notebookKey) != nil || annotation.value(forAnnotationKey: NotebookPaper.key) != nil { continue }
                if let entry = annotation.value(forAnnotationKey: PDFPictures.key) as? String {
                    guard let picture = PDFPictures.parse(entry), images[picture.id] != nil else { return nil }
                    continue
                }
                // Markup's drawings have a look of their own, which wouldn't come along.
                guard redrawn.contains(annotation.type ?? ""), MarkupDrawings.strokes(in: annotation, on: page) == nil else { return nil }
            }
        }
        guard let first = document.page(at: 0), let fresh = PDFDocument(data: NotebookPaper.pageData(.blank, size: first.bounds(for: .mediaBox).size)) else { return nil }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return nil }
            page.annotations.forEach(keepEntries)
            fresh.insert(page, at: fresh.pageCount)
        }
        fresh.removePage(at: 0)
        for index in 0..<fresh.pageCount {
            guard let page = fresh.page(at: index) else { continue }
            var content = PageContent()
            var found = false
            for annotation in page.annotations {
                if let strokes = MarkupDrawings.strokes(in: annotation, on: page) {
                    content.drawing.append(strokes.drawing)
                } else if let entry = annotation.value(forAnnotationKey: PDFPictures.key) as? String, var picture = PDFPictures.parse(entry) {
                    picture.image = images[picture.id]
                    content.pictures.append(picture)
                } else {
                    continue
                }
                found = true
                page.removeAnnotation(annotation)
            }
            if found { try write(content, on: page, in: fresh, images: images, carriers: carriers) }
        }
        fresh.documentAttributes = document.documentAttributes
        return fresh
    }
}
