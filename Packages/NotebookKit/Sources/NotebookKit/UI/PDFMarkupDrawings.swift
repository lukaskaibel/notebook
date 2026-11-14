import PDFKit
import PencilKit

/// Handwriting on PDFs, from Apple's Markup (Files, Quick Look, Preview, the share sheet) and from drawing on a PDF
/// in Notebook, drawn as sharp as the text around it.
///
/// Markup saves a drawing as an annotation whose look is a picture, at about twice the page's size, which PDFKit
/// stretches and blurs as soon as the page is shown larger. The strokes themselves are in the annotation too, in
/// Markup's own entry (`/AAPL:AKExtras`, `MarkupInkArchive`), and Apple's apps draw those. Notebook keeps its strokes in
/// that same entry, next to a look made of lines that any app draws sharp, so Apple's apps take them for ink as well,
/// never for a picture they would draw again as pixels (`PDFMarkupEntries`). Either way the annotation is hidden, and
/// the page draws the strokes with its text, at the size they are shown. (An annotation of its own wouldn't do: PDFKit
/// draws annotations once at the page's size, and stretches them too.) Reading changes nothing in the file.
///
/// Notebook before 1.4 kept its strokes in an entry of its own (`/NotebookDrawing`); those are read too, and written in
/// Markup's entry with the next save.
enum MarkupDrawings {
    static let extrasKey = PDFAnnotationKey(rawValue: "/AAPL:AKExtras")
    static let annotationKey = "/AAPL:AKAnnotationV2"
    /// Notebook's strokes before 1.4: a PencilKit drawing, as Base64, measured from the top left of the page's crop box.
    static let notebookKey = PDFAnnotationKey(rawValue: "/NotebookDrawing")
    /// On Notebook's own ink annotations: their copy for Apple's apps is made again with every save.
    static let inkMarker = PDFAnnotationKey(rawValue: "/\(PDFMarkupEntries.notebookMarker)")

    /// Draws the strokes in `document` sharp. Called in the background, right after it was read, before anything has
    /// looked at its pages.
    static func sharpen(_ document: PDFDocument, fileAt url: URL) {
        // Most PDFs have none: their bytes say so without reading a page. The entries are written uncompressed.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        let hasStrokes = data.range(of: Data("AAPL:AKAnnotationV2".utf8)) != nil || data.range(of: Data("NotebookDrawing".utf8)) != nil
        let hasPictures = data.range(of: Data("NotebookPicture".utf8)) != nil
        guard hasStrokes || hasPictures else { return }
        // Pages that can draw strokes, from the first one read.
        document.delegate = PageMaker.shared
        let file = CGPDFDocument(url as CFURL)
        if hasStrokes { readInk(from: file, into: document) }
        let images = hasPictures ? file.map { PDFPictures.images(in: $0) } ?? [:] : [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) as? DrawingPage else { continue }
            for annotation in page.annotations where annotation.shouldDisplay {
                guard let found = strokes(in: annotation, on: page) else { continue }
                annotation.shouldDisplay = false
                page.drawings.append(found)
            }
            for (annotation, picture) in PDFPictures.pictures(on: page) {
                guard let image = images[picture.id] else { continue }
                page.pictureImages[picture.id] = image
                // PDFKit would draw the stamp at the page's size, blurred as soon as the page is shown larger.
                guard let look = image.cgImage else { continue }
                annotation.shouldDisplay = false
                page.pictures.append((picture, look))
            }
        }
    }

    /// The pictures Notebook put on the page, with what they show, as read from the file.
    static func pictures(on page: PDFPage) -> [PDFPicture] {
        let images = (page as? DrawingPage)?.pictureImages ?? [:]
        return PDFPictures.pictures(on: page).map { found in
            var picture = found.picture
            picture.image = images[picture.id]
            return picture
        }
    }

    /// The strokes kept in an annotation, Markup's or Notebook's, and the box of the page they are measured in, from
    /// its top left. None for any other annotation, and for strokes Notebook can't place on the page.
    nonisolated static func strokes(in annotation: PDFAnnotation, on page: PDFPage) -> (drawing: PKDrawing, area: CGRect)? {
        guard page.rotation == 0 else { return nil }
        if let ink = foundInk(of: annotation) ?? markupInk(in: annotation) { return placed(ink, on: page) }
        if let encoded = annotation.value(forAnnotationKey: notebookKey) as? String {
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  let drawing = try? PKDrawing(data: data) else { return nil }
            return (drawing, page.bounds(for: .cropBox))
        }
        return nil
    }

    /// Whether the annotation is one of Notebook's own strokes, written by this version or an earlier one.
    nonisolated static func isNotebookInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: inkMarker) != nil || annotation.value(forAnnotationKey: notebookKey) != nil
    }

    /// The ink entries in the file's own bytes put with their annotations, also where PDFKit doesn't hand the entry
    /// out (squares). For a document just read from `file`.
    nonisolated static func readInk(from file: CGPDFDocument?, into document: PDFDocument) {
        guard let file else { return }
        for (index, found) in PDFMarkupEntries.inks(in: file) {
            guard let page = document.page(at: index) else { continue }
            var left = found
            for annotation in page.annotations {
                guard let match = left.firstIndex(where: { $0.subtype == String((annotation.type ?? "").drop { $0 == "/" }) && $0.rect.isClose(to: annotation.bounds) }) else {
                    continue
                }
                objc_setAssociatedObject(annotation, &inkKey, InkBox(left[match].ink, archive: left[match].archive), .OBJC_ASSOCIATION_RETAIN)
                left.remove(at: match)
            }
        }
    }

    /// The same for a document read from `data`.
    nonisolated static func readInk(from data: Data, into document: PDFDocument) {
        readInk(from: CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init), into: document)
    }

    /// A copy of a page keeps knowing the ink of its annotations.
    nonisolated static func copyInk(from page: PDFPage, to copy: PDFPage) {
        for (annotation, copied) in zip(page.annotations, copy.annotations) {
            guard let ink = objc_getAssociatedObject(annotation, &inkKey) else { continue }
            objc_setAssociatedObject(copied, &inkKey, ink, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    nonisolated(unsafe) private static var inkKey: UInt8 = 0

    private final class InkBox: @unchecked Sendable {
        let ink: MarkupInkArchive.Ink
        let archive: String
        init(_ ink: MarkupInkArchive.Ink, archive: String) {
            self.ink = ink
            self.archive = archive
        }
    }

    /// Markup's entry of an annotation with strokes, as it is: read from the file, or handed out by PDFKit (stamps,
    /// Notebook's strokes made just now). None for one without, and for Notebook's strokes of before 1.4.
    nonisolated static func entry(of annotation: PDFAnnotation) -> String? {
        if let box = objc_getAssociatedObject(annotation, &inkKey) as? InkBox { return box.archive }
        guard isMarkup(annotation), let extras = annotation.value(forAnnotationKey: extrasKey) as? [AnyHashable: Any],
              let encoded = (extras[annotationKey] ?? extras[String(annotationKey.dropFirst())]) as? String,
              MarkupInkArchive.decoded(encoded) != nil else { return nil }
        return encoded
    }

    private nonisolated static func foundInk(of annotation: PDFAnnotation) -> MarkupInkArchive.Ink? {
        (objc_getAssociatedObject(annotation, &inkKey) as? InkBox)?.ink
    }

    /// All the strokes on a page as one drawing, measured from the top left of its crop box: what a canvas over the
    /// page starts with.
    static func drawing(on page: PDFPage) -> PKDrawing {
        guard let page = page as? DrawingPage else { return PKDrawing() }
        let crop = page.bounds(for: .cropBox)
        return page.drawings.reduce(into: PKDrawing()) { all, found in
            let offset = CGAffineTransform(translationX: found.area.minX - crop.minX, y: crop.maxY - found.area.maxY)
            all.append(found.drawing.transformed(using: offset))
        }
    }

    /// While a canvas over the page shows its strokes to change them, and its pictures too with `pictures` (iPhone and
    /// iPad), the page doesn't draw them too.
    static func setEditing(_ editing: Bool, pictures: Bool = false, on page: PDFPage) {
        let drawingPage = page as? DrawingPage
        drawingPage?.isEditing = editing
        drawingPage?.hidesPictures = editing && pictures
        let drawn = Set(drawingPage?.pictures.map(\.picture.id) ?? [])
        for (annotation, picture) in PDFPictures.pictures(on: page) {
            annotation.shouldDisplay = !(editing && pictures) && !drawn.contains(picture.id)
        }
    }

    /// The ink Markup keeps in a stamp, as PDFKit hands it out: Notebook's strokes made just now, or a document whose
    /// file wasn't read for them (`readInk`).
    private nonisolated static func markupInk(in annotation: PDFAnnotation) -> MarkupInkArchive.Ink? {
        guard isMarkup(annotation), let extras = annotation.value(forAnnotationKey: extrasKey) as? [AnyHashable: Any],
              let encoded = (extras[annotationKey] ?? extras[String(annotationKey.dropFirst())]) as? String else { return nil }
        return MarkupInkArchive.decoded(encoded)
    }

    /// Whether Markup's entry is read on the annotation through PDFKit: on stamps, which Markup saved its drawings as.
    /// An ink annotation written on the Mac (Preview's Markup, PDFKit) has the entry too, with its points in it, and
    /// once that has been read, PDFKit on iPhone and iPad can't write the PDF with a page added or moved (#284).
    nonisolated static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Stamp"
    }

    /// The strokes where they go on the page, and the box they are measured in, from its top left. Apple writes them
    /// on a canvas of the annotation box's size (Notebook, Markup in Files), on the page's box with an older Markup, or
    /// fitted into the box with no canvas at all (PencilKit drawings that PDFKit puts on a page, as Preview does).
    nonisolated static func placed(_ ink: MarkupInkArchive.Ink, on page: PDFPage) -> (drawing: PKDrawing, area: CGRect)? {
        let canvas = ink.canvas
        if canvas.width > 0, canvas.height > 0 {
            if let rect = ink.rectangle, rect.size.isClose(to: canvas) { return (ink.drawing, rect) }
            if let box = [PDFDisplayBox.cropBox, .mediaBox].lazy.map({ page.bounds(for: $0) }).first(where: { $0.size.isClose(to: canvas) }) {
                return (ink.drawing, box)
            }
            guard let rect = ink.rectangle, rect.width > 0, rect.height > 0 else { return nil }
            return (ink.drawing.transformed(using: CGAffineTransform(scaleX: rect.width / canvas.width, y: rect.height / canvas.height)), rect)
        }
        let bounds = ink.drawing.bounds
        guard let rect = ink.rectangle, rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let fitted = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (rect.width - bounds.width * scale) / 2, y: (rect.height - bounds.height * scale) / 2))
        return (ink.drawing.transformed(using: fitted), rect)
    }
}

private extension CGSize {
    func isClose(to other: CGSize) -> Bool { abs(width - other.width) < 1 && abs(height - other.height) < 1 }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

/// Makes the document's pages ones that draw strokes.
private final class PageMaker: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    static let shared = PageMaker()
    func classForPage() -> AnyClass { DrawingPage.self }
}

/// A page that draws the strokes and pictures on it over itself, at the scale it is drawn at.
private final class DrawingPage: PDFPage, @unchecked Sendable {
    typealias Drawing = (drawing: PKDrawing, area: CGRect)
    typealias Picture = (picture: PDFPicture, look: CGImage)
    private final class State {
        var drawings: [Drawing] = []
        var pictureImages: [String: PictureImage] = [:]
        var pictures: [Picture] = []
        var isEditing = false
        var hidesPictures = false
    }
    nonisolated(unsafe) private static var key: UInt8 = 0

    /// Kept beside the page: PDFKit makes its pages without the initializer that would set a property of its own.
    private var state: State {
        if let state = objc_getAssociatedObject(self, &Self.key) as? State { return state }
        let state = State()
        objc_setAssociatedObject(self, &Self.key, state, .OBJC_ASSOCIATION_RETAIN)
        return state
    }

    /// The strokes, and the box of the page they are measured in, from its top left. Set before the page is shown.
    var drawings: [Drawing] {
        get { state.drawings }
        set { state.drawings = newValue }
    }

    /// The pictures of Notebook's picture stamps, by id, read from the file's own objects.
    var pictureImages: [String: PictureImage] {
        get { state.pictureImages }
        set { state.pictureImages = newValue }
    }

    /// The pictures the page draws in place of their stamps, under the strokes. Set before the page is shown.
    var pictures: [Picture] {
        get { state.pictures }
        set { state.pictures = newValue }
    }

    /// A canvas over the page shows the strokes meanwhile. The view showing the page draws it again only when given
    /// its document again.
    var isEditing: Bool {
        get { state.isEditing }
        set { state.isEditing = newValue }
    }

    /// A canvas over the page shows the pictures too.
    var hidesPictures: Bool {
        get { state.hidesPictures }
        set { state.hidesPictures = newValue }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        let drawsStrokes = !drawings.isEmpty && !isEditing, drawsPictures = !pictures.isEmpty && !hidesPictures
        guard drawsStrokes || drawsPictures else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // PDFKit draws the page in its own space; it goes into the box's, as annotations do.
        let bounds = self.bounds(for: box)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        let clip = context.boundingBoxOfClipPath
        if drawsPictures { drawPictures(in: context, clip: clip) }
        guard drawsStrokes else { return }
        let device = context.userSpaceToDeviceSpaceTransform
        // As many pixels as the screen has at this zoom, however far in: only the part in view is drawn, so the picture
        // stays the size of a tile. The limit is for a context that claims more than any screen.
        let scale = min(max(hypot(device.a, device.b), hypot(device.c, device.d), 1), 64)
        for (drawing, area) in drawings {
            // Only the part in view, at the pixels it covers: zoomed in, a whole page of strokes would be a huge picture.
            let strokes = drawing.bounds
            let onPage = CGRect(x: area.minX + strokes.minX, y: area.maxY - strokes.maxY, width: strokes.width, height: strokes.height)
            let shown = onPage.intersection(clip)
            guard !shown.isNull, shown.width > 0, shown.height > 0 else { continue }
            let part = CGRect(x: shown.minX - area.minX, y: area.maxY - shown.maxY, width: shown.width, height: shown.height)
            guard let image = Self.image(of: drawing, part: part, scale: scale) else { continue }
            context.draw(image, in: shown)
        }
    }

    /// The pictures as their stamps show them: turned about their middles, the corners a little round.
    private func drawPictures(in context: CGContext, clip: CGRect) {
        let crop = bounds(for: .cropBox)
        context.interpolationQuality = .high
        for (picture, look) in pictures {
            let box = PDFPictures.bounds(of: picture)
            guard CGRect(x: crop.minX + box.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height).intersects(clip) else { continue }
            let (w, h) = (picture.frame.width / 2, picture.frame.height / 2)
            context.saveGState()
            context.translateBy(x: crop.minX + picture.frame.midX, y: crop.maxY - picture.frame.midY)
            context.rotate(by: -picture.rotation)
            let rect = CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h)
            let radius = min(4, w, h)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.draw(look, in: rect)
            context.restoreGState()
        }
    }

    /// The strokes as on paper, black ink black also in Dark Mode.
    private static func image(of drawing: PKDrawing, part: CGRect, scale: CGFloat) -> CGImage? {
        var image: CGImage?
        #if os(macOS)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: part, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        #else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: part, scale: scale).cgImage
        }
        #endif
        return image
    }
}
