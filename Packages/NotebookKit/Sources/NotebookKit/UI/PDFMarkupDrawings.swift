import PDFKit
import PencilKit

/// Handwriting on PDFs, from Apple's Markup (Files, Quick Look, Preview, the share sheet) and from drawing on a PDF
/// in Notebook, drawn as sharp as the text around it.
///
/// Markup saves a drawing as a stamp whose look is a picture at twice the page's size, which PDFKit stretches and
/// blurs as soon as the page is shown larger. The strokes themselves are in the stamp too, in Markup's own entry
/// (`/AAPL:AKExtras`), and Files and Preview draw those. Notebook keeps its own strokes in an entry of its own
/// (`/NotebookDrawing`), next to a look made of lines that any app draws sharp. Either way the stamp is hidden, and the
/// page draws the strokes with its text, at the size they are shown. (An annotation of its own wouldn't do: PDFKit
/// draws annotations once at the page's size, and stretches them too.) Reading changes nothing in the file.
enum MarkupDrawings {
    static let extrasKey = PDFAnnotationKey(rawValue: "/AAPL:AKExtras")
    private static let annotationKey = "/AAPL:AKAnnotationV2"
    /// Notebook's strokes: a PencilKit drawing, as Base64, measured from the top left of the page's crop box.
    static let notebookKey = PDFAnnotationKey(rawValue: "/NotebookDrawing")

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
        let images = hasPictures ? CGPDFDocument(url as CFURL).map { PDFPictures.images(in: $0) } ?? [:] : [:]
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
        if let encoded = annotation.value(forAnnotationKey: notebookKey) as? String {
            guard page.rotation == 0, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  let drawing = try? PKDrawing(data: data) else { return nil }
            return (drawing, page.bounds(for: .cropBox))
        }
        guard let (drawing, canvas) = markupDrawing(in: annotation), let area = area(of: page, canvas: canvas) else { return nil }
        return (drawing, area)
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

    /// The strokes Markup keeps in an annotation, and the size of the page they were drawn on.
    private nonisolated static func markupDrawing(in annotation: PDFAnnotation) -> (PKDrawing, CGSize)? {
        guard let extras = annotation.value(forAnnotationKey: extrasKey) as? [AnyHashable: Any],
              let encoded = extras[annotationKey] as? String,
              let archive = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        // Markup's own classes aren't here; one of ours reads the two entries needed.
        for name in ["AKInkAnnotation2", "AKInkAnnotation"] { unarchiver.setClass(MarkupInk.self, forClassName: name) }
        defer { unarchiver.finishDecoding() }
        guard let ink = unarchiver.decodeObject(of: MarkupInk.self, forKey: NSKeyedArchiveRootObjectKey),
              let data = ink.drawing, let size = ink.canvas, size.width > 0, size.height > 0,
              let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        return (drawing, size)
    }

    /// The page's box the drawing was made on: its strokes are measured from the box's top left. None for a turned
    /// page or one of another size, which keeps Markup's picture.
    private nonisolated static func area(of page: PDFPage, canvas: CGSize) -> CGRect? {
        guard page.rotation == 0 else { return nil }
        return [PDFDisplayBox.cropBox, .mediaBox].lazy.map { page.bounds(for: $0) }.first { box in
            abs(box.width - canvas.width) < 1 && abs(box.height - canvas.height) < 1
        }
    }
}

/// Makes the document's pages ones that draw strokes.
private final class PageMaker: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    static let shared = PageMaker()
    func classForPage() -> AnyClass { DrawingPage.self }
}

/// Stands in for Markup's ink annotation, to read its strokes and the size of their page.
@objc(NotebookMarkupInk)
private final class MarkupInk: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let drawing: Data?
    let canvas: CGSize?

    init?(coder: NSCoder) {
        drawing = coder.decodeObject(of: NSData.self, forKey: "drawing") as Data?
        let size = coder.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self], forKey: "drawingSize") as? [String: Any]
        if let width = (size?["Width"] as? NSNumber)?.doubleValue, let height = (size?["Height"] as? NSNumber)?.doubleValue {
            canvas = CGSize(width: width, height: height)
        } else {
            canvas = nil
        }
    }

    func encode(with coder: NSCoder) {}
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
