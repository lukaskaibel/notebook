import PDFKit
import PencilKit

/// Handwriting from Apple's Markup (Files, Quick Look, Preview, the share sheet) drawn as sharp as the text around it.
///
/// Markup saves a drawing as a stamp whose look is a picture at twice the page's size, which PDFKit stretches and
/// blurs as soon as the page is shown larger. The strokes themselves are in the stamp too, in Markup's own entry
/// (`/AAPL:AKExtras`), and Files and Preview draw those. So does Notebook: the stamp is hidden, and the page draws
/// the strokes with its text, at the size they are shown. (An annotation of its own wouldn't do: PDFKit draws
/// annotations once at the page's size, and stretches them too.) The file itself is never changed.
enum MarkupDrawings {
    private static let extrasKey = PDFAnnotationKey(rawValue: "/AAPL:AKExtras")
    private static let annotationKey = "/AAPL:AKAnnotationV2"

    /// Draws the Markup drawings in `document` sharp. Called in the background, right after it was read, before
    /// anything has looked at its pages.
    static func sharpen(_ document: PDFDocument, fileAt url: URL) {
        // Most PDFs have none: their bytes say so without reading a page. Markup writes its entries uncompressed.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.range(of: Data("AAPL:AKAnnotationV2".utf8)) != nil else { return }
        // Pages that can draw strokes, from the first one read.
        document.delegate = PageMaker.shared
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) as? DrawingPage else { continue }
            for annotation in page.annotations where annotation.shouldDisplay {
                guard let (drawing, canvas) = drawing(in: annotation),
                      let area = area(of: page, canvas: canvas) else { continue }
                annotation.shouldDisplay = false
                page.drawings.append((drawing, area))
            }
        }
    }

    /// The strokes Markup keeps in an annotation, and the size of the page they were drawn on.
    private static func drawing(in annotation: PDFAnnotation) -> (PKDrawing, CGSize)? {
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
    private static func area(of page: PDFPage, canvas: CGSize) -> CGRect? {
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

/// A page that draws Markup's strokes over itself, at the scale it is drawn at.
private final class DrawingPage: PDFPage, @unchecked Sendable {
    typealias Drawing = (drawing: PKDrawing, area: CGRect)
    private final class Drawings {
        var list: [Drawing] = []
    }
    nonisolated(unsafe) private static var key: UInt8 = 0

    /// The strokes, and the box of the page they are measured in, from its top left. Set before the page is shown.
    /// Kept beside the page: PDFKit makes its pages without the initializer that would set a property of its own.
    var drawings: [Drawing] {
        get { (objc_getAssociatedObject(self, &Self.key) as? Drawings)?.list ?? [] }
        set {
            let drawings = Drawings()
            drawings.list = newValue
            objc_setAssociatedObject(self, &Self.key, drawings, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard !drawings.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // PDFKit draws the page in its own space; it goes into the box's, as annotations do.
        let bounds = self.bounds(for: box)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        let device = context.userSpaceToDeviceSpaceTransform
        // As many pixels as the screen has at this zoom, however far in: only the part in view is drawn, so the picture
        // stays the size of a tile. The limit is for a context that claims more than any screen.
        let scale = min(max(hypot(device.a, device.b), hypot(device.c, device.d), 1), 64)
        let clip = context.boundingBoxOfClipPath
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
