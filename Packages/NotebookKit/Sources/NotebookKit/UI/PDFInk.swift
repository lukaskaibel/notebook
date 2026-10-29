import PDFKit
import PencilKit

/// Writing strokes into a PDF: on every page drawn on, one annotation with all its strokes, in place of the ones it
/// had (Markup's or Notebook's). Its look is made of lines, which every PDF app draws sharp; the strokes themselves go
/// with it, for Notebook to show and change them again. Highlights go in the same way (`PDFHighlights`).
enum PDFInk {
    /// One save after the other.
    static let queue = DispatchQueue(label: "Notebook.PDFInk")
    /// Changes asked for and not written yet, which quitting waits for.
    @MainActor private static var writing = 0
    @MainActor private static var whenDone: [() -> Void] = []

    @MainActor static var isWriting: Bool { writing > 0 }

    /// Changes the PDF in the background, after the changes asked for before. Once written, it is read again and
    /// shown; if it can't be, `report` tells why.
    @MainActor static func save(_ url: URL, failure: String, report: @escaping (String, String) -> Void, _ change: @escaping (PDFDocument) throws -> Void) {
        writing += 1
        queue.async {
            let error: Error?
            do {
                try self.change(url, change)
                error = nil
            } catch let failed {
                error = failed
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    writing -= 1
                    if let error { report(failure, error.localizedDescription) } else { FileLoading.didWrite(url) }
                    guard writing == 0 else { return }
                    let done = whenDone
                    whenDone = []
                    done.forEach { $0() }
                }
            }
        }
    }

    /// Calls `done` once every change asked for is written: at once when there are none.
    @MainActor static func whenWritten(_ done: @escaping () -> Void) {
        if writing == 0 { done() } else { whenDone.append(done) }
    }

    /// Each page's strokes in place of the ones it had. `drawings` are by page number, measured from the top left of
    /// each page's crop box.
    nonisolated static func put(_ drawings: [Int: PKDrawing], in document: PDFDocument) {
        for (index, drawing) in drawings {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where MarkupDrawings.strokes(in: annotation, on: page) != nil {
                page.removeAnnotation(annotation)
            }
            if !drawing.strokes.isEmpty { page.addAnnotation(InkAnnotation(drawing: drawing, on: page)) }
        }
    }

    /// Reads the PDF as it is now, changes it and writes it back, in one coordinated write.
    nonisolated static func change(_ url: URL, _ change: (PDFDocument) throws -> Void) throws {
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
                try change(document)
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                defer { try? FileManager.default.removeItem(at: temporary) }
                // PDFKit writes again whatever the file held, the annotations taken off too: like an incremental save,
                // each one leaves the strokes before it in the file. A document of its own, with only what is in use,
                // would lose Markup's strokes and the document's bookmarks, forms and structure.
                guard document.write(to: temporary) else { throw CocoaError(.fileWriteUnknown) }
                // Written in place, so the file keeps its tags, its colour and its place in the folder.
                try Data(contentsOf: temporary).write(to: url)
            } catch {
                failure = error
            }
        }
        if let error = failure ?? coordination { throw error }
    }
}

/// A page's strokes as a stamp. PDFKit makes its look by drawing it, as lines, when it writes the PDF.
private final class InkAnnotation: PDFAnnotation {
    private let drawing: PKDrawing
    /// The page's crop box, whose top left the strokes are measured from.
    private let crop: CGRect
    private static let rgb = CGColorSpaceCreateDeviceRGB()

    init(drawing: PKDrawing, on page: PDFPage) {
        self.drawing = drawing
        crop = page.bounds(for: .cropBox)
        let strokes = drawing.bounds.insetBy(dx: -2, dy: -2)
        super.init(bounds: CGRect(x: crop.minX + strokes.minX, y: crop.maxY - strokes.maxY, width: strokes.width, height: strokes.height),
                   forType: .stamp, withProperties: nil)
        setValue(drawing.dataRepresentation().base64EncodedString() as NSString, forAnnotationKey: MarkupDrawings.notebookKey)
        // Not the name of the device's owner, which PDFKit would write otherwise.
        userName = ""
        shouldPrint = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in drawing.strokes {
            var (red, green, blue, alpha) = Self.paperColor(of: stroke.ink)
            if stroke.ink.inkType == .marker { alpha *= 0.5 }
            // Plain RGB: a colour space of its own would put a colour profile into the PDF with every save.
            let ink = CGColor(colorSpace: Self.rgb, components: [red, green, blue, alpha].map { min(max($0, 0), 1) })
                ?? CGColor(gray: 0, alpha: 1)
            context.setStrokeColorSpace(Self.rgb)
            context.setFillColorSpace(Self.rgb)
            context.setStrokeColor(ink)
            context.setFillColor(ink)
            let scale = hypot(stroke.transform.a, stroke.transform.b)
            for range in stroke.maskedPathRanges {
                let points = stroke.path.interpolatedPoints(in: range, by: .distance(1)).map { point in
                    let location = point.location.applying(stroke.transform)
                    return (location: CGPoint(x: crop.minX + location.x, y: crop.maxY - location.y), width: max(point.size.width * scale, 0.3))
                }
                // A see-through ink is one line, as wide as the stroke is in the middle: pieces of it overlapping would
                // be darker where they meet. (A layer to draw it in doesn't survive PDFKit's writing.)
                if alpha < 1 {
                    let widths = points.map(\.width).sorted()
                    draw(points.map { ($0.location, widths.isEmpty ? 1 : widths[widths.count / 2]) }, in: context)
                } else {
                    draw(points, in: context)
                }
            }
        }
    }

    /// The ink's colour as on paper, in Light Mode: black ink stays black.
    private static func paperColor(of ink: PKInk) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        #if os(macOS)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            ink.color.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        #else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink.color.resolvedColor(with: .current).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        #endif
        return (red, green, blue, alpha)
    }

    /// A line through the points, each piece as wide as the stroke is there.
    private func draw(_ points: [(location: CGPoint, width: CGFloat)], in context: CGContext) {
        guard let first = points.first else { return }
        guard points.count > 1 else {
            context.fillEllipse(in: CGRect(x: first.location.x - first.width / 2, y: first.location.y - first.width / 2, width: first.width, height: first.width))
            return
        }
        // Pieces of about the same width go in one line, which keeps the PDF small.
        var width = first.width
        var last = first.location
        context.move(to: last)
        for point in points.dropFirst() {
            if abs(point.width - width) > 0.15 {
                context.setLineWidth(width)
                context.strokePath()
                context.move(to: last)
                width = point.width
            }
            context.addLine(to: point.location)
            last = point.location
        }
        context.setLineWidth(width)
        context.strokePath()
    }
}
