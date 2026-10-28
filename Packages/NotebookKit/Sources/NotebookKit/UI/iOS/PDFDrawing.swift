#if os(iOS)
import PDFKit
import PencilKit
import UIKit

/// Drawing right on a PDF, as in Notes: the pen above it puts a PencilKit canvas over every page and brings the
/// system's tool picker, so Apple Pencil, the eraser, the lasso and the ruler work on the page itself. The strokes
/// already there (Markup's or Notebook's) are in the canvases to erase or move. Ending it, leaving the PDF or leaving
/// the app saves what changed into the PDF itself (`PDFInk`).
@MainActor
final class PDFDrawingSession: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let url: URL
    private weak var view: PDFView?
    private let toolPicker = PKToolPicker()
    /// Keeps the tool picker up: it shows while its responder is focused, and no one canvas is (pages come and go).
    private lazy var anchor = ToolAnchor(session: self)
    /// Strokes are undone here, on whichever page they were drawn.
    let strokeUndo = UndoManager()
    /// Each page's strokes, by its number, as its canvas has them; pages not shown yet aren't here.
    private var drawings: [Int: PKDrawing] = [:]
    /// The pages drawn on since drawing started. They stay so once saved: saving writes a page's strokes whole.
    private var edited: Set<Int> = []
    private var pausedGestures: [UIGestureRecognizer] = []
    private var scrollTouches: Int?
    private var background: NSObjectProtocol?
    private let report: (String, String) -> Void

    init(url: URL, report: @escaping (String, String) -> Void) {
        self.url = url
        self.report = report
    }

    var hasChanges: Bool { !edited.isEmpty }

    /// Puts canvases over the pages and brings the tool picker.
    func start(in view: PDFView) {
        self.view = view
        view.addSubview(anchor)
        toolPicker.stateAutosaveName = "NotebookDrawing"
        // The page is paper, white also in Dark Mode: black ink stays black, and the tool picker's colours are those.
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.setVisible(true, forFirstResponder: anchor)
        _ = anchor.becomeFirstResponder()
        view.isInMarkupMode = true
        view.pageOverlayViewProvider = self
        // One finger draws, so two scroll, as in Notes; where only Apple Pencil draws, a finger scrolls still.
        if let scrollView = view.scrollView, !UIPencilInteraction.prefersPencilOnlyDrawing {
            scrollTouches = scrollView.panGestureRecognizer.minimumNumberOfTouches
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        }
        // A stroke from left to right is also how you go back from anywhere on the screen: it would leave the PDF.
        var responder: UIResponder? = view
        while let next = responder, !(next is UINavigationController) { responder = next.next }
        if let back = (responder as? UINavigationController)?.interactiveContentPopGestureRecognizer, back.isEnabled {
            back.isEnabled = false
            pausedGestures.append(back)
        }
        // The PDF's text selection, its loupe and its taps on links would take the strokes, and its focus would take
        // the tool picker away (markup mode doesn't stop them).
        for gesture in view.documentView?.gestureRecognizers ?? [] where gesture.isEnabled {
            gesture.isEnabled = false
            pausedGestures.append(gesture)
        }
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        showPages(of: view)
    }

    /// The canvases go and the pages draw their strokes again; what changed is saved. Without changes, the pages are
    /// drawn again at once; with them, once the saved PDF is read again (the canvases show the strokes until then).
    func end() {
        toolPicker.setVisible(false, forFirstResponder: anchor)
        _ = anchor.resignFirstResponder()
        anchor.removeFromSuperview()
        pausedGestures.forEach { $0.isEnabled = true }
        pausedGestures = []
        if let scrollTouches, let scrollView = view?.scrollView { scrollView.panGestureRecognizer.minimumNumberOfTouches = scrollTouches }
        if let background { NotificationCenter.default.removeObserver(background) }
        background = nil
        guard let view else { return }
        view.isInMarkupMode = false
        if hasChanges {
            for canvas in view.canvases { canvas.isUserInteractionEnabled = false }
            save()
        } else {
            leavePages(of: view)
        }
    }

    /// The saved PDF was read again: its pages draw the strokes now, and the canvases left over them go.
    func finish(in view: PDFView) {
        guard view.pageOverlayViewProvider === self else { return }
        leavePages(of: view)
    }

    /// The PDF was read again while drawing (saved as Notebook went to the background, or changed elsewhere): the
    /// canvases come anew over its pages, with the strokes they had.
    func documentChanged(in view: PDFView) {
        showPages(of: view)
    }

    /// Writes the pages drawn on into the PDF, in the background.
    func save() {
        guard hasChanges else { return }
        let changes = edited.reduce(into: [Int: PKDrawing]()) { $0[$1] = drawings[$1] ?? PKDrawing() }
        let url = url, report = report
        PDFInk.queue.async {
            do {
                try PDFInk.write(changes, to: url)
                DispatchQueue.main.async { FileLoading.didWrite(url) }
            } catch {
                DispatchQueue.main.async { report("Your drawing couldn’t be saved in “\(url.lastPathComponent)”.", error.localizedDescription) }
            }
        }
    }

    /// The pages stop drawing their own strokes, which the canvases show, and are drawn anew.
    private func showPages(of view: PDFView) {
        guard let document = view.document else { return }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { MarkupDrawings.setEditing(true, on: page) }
        }
        reload(view)
    }

    private func leavePages(of view: PDFView) {
        view.pageOverlayViewProvider = nil
        if let document = view.document {
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { MarkupDrawings.setEditing(false, on: page) }
            }
        }
        reload(view)
    }

    /// PDFKit asks for overlays, and draws a page anew, only when given its document again. It stays where it was.
    /// While drawing, the tool picker comes back after (the PDF takes the focus as it is shown).
    private func reload(_ view: PDFView) {
        defer {
            if anchor.superview != nil { DispatchQueue.main.async { [anchor] in _ = anchor.becomeFirstResponder() } }
        }
        guard let document = view.document, let page = view.currentPage else { return }
        let top = view.convert(CGPoint(x: 0, y: view.safeAreaInsets.top), to: page)
        let scale = view.scaleFactor, autoScales = view.autoScales
        view.document = nil
        view.document = document
        if !autoScales {
            view.autoScales = false
            view.scaleFactor = scale
        }
        view.go(to: PDFDestination(page: page, at: top))
    }

    fileprivate func changed(_ canvas: PageCanvas) {
        drawings[canvas.pageIndex] = canvas.drawing
        edited.insert(canvas.pageIndex)
    }

    fileprivate func tool(for canvas: PageCanvas) {
        switch toolPicker.selectedToolItem {
        case let item as PKToolPickerInkingItem: canvas.tool = item.inkingTool
        case let item as PKToolPickerEraserItem: canvas.tool = item.eraserTool
        case is PKToolPickerLassoItem: canvas.tool = PKLassoTool()
        default: break
        }
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        let canvas = PageCanvas(session: self, pageIndex: index)
        // The strokes come once the canvas is in place: given before, PencilKit shows none drawn after.
        let drawing = drawings[index] ?? MarkupDrawings.drawing(on: page)
        drawings[index] = drawing
        DispatchQueue.main.async { canvas.show(drawing) }
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvas else { return }
        toolPicker.addObserver(canvas)
        tool(for: canvas)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvas else { return }
        toolPicker.removeObserver(canvas)
    }
}

/// The canvas over one page. Its strokes are measured from the top left of the page's crop box, in its points.
@MainActor
private final class PageCanvas: PKCanvasView {
    let pageIndex: Int
    private weak var session: PDFDrawingSession?
    private var isShowing = false
    /// The canvas's delegate. Not the canvas itself: PencilKit passes some of its own calls on to the delegate, which
    /// would go round in circles.
    private lazy var events = CanvasEvents(canvas: self)

    init(session: PDFDrawingSession, pageIndex: Int) {
        self.session = session
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        overrideUserInterfaceStyle = .light
        drawingPolicy = .default
        isScrollEnabled = false
        bounces = false
        pinchGestureRecognizer?.isEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        accessibilityLabel = "Drawing"
        delegate = events
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { session?.strokeUndo }

    func show(_ drawing: PKDrawing) {
        isShowing = true
        self.drawing = drawing
        isShowing = false
    }

    fileprivate func drawingChanged() {
        guard !isShowing else { return }
        session?.changed(self)
    }
}

private final class CanvasEvents: NSObject, PKCanvasViewDelegate {
    weak var canvas: PageCanvas?

    init(canvas: PageCanvas) { self.canvas = canvas }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        MainActor.assumeIsolated { canvas?.drawingChanged() }
    }

}

/// What the tool picker shows for, and where ⌘Z and the tool picker's Undo go.
@MainActor
private final class ToolAnchor: UIView {
    private weak var session: PDFDrawingSession?

    init(session: PDFDrawingSession) {
        self.session = session
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { session?.strokeUndo }
    private let noAccessory = UIView(frame: .zero)
    override var inputAccessoryView: UIView? { noAccessory }

    @objc func undo(_ sender: Any?) { session?.strokeUndo.undo() }
    @objc func redo(_ sender: Any?) { session?.strokeUndo.redo() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) { return session?.strokeUndo.canUndo ?? false }
        if action == #selector(redo(_:)) { return session?.strokeUndo.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }
}

private extension PDFView {
    /// PDFKit's own scroll view, which scrolls the pages.
    var scrollView: UIScrollView? { subviews.lazy.compactMap { $0 as? UIScrollView }.first }

    var canvases: [PageCanvas] {
        func find(_ view: UIView) -> [PageCanvas] { (view as? PageCanvas).map { [$0] } ?? view.subviews.flatMap(find) }
        return find(self)
    }
}

/// Writing strokes into a PDF: on every page drawn on, one annotation with all its strokes, in place of the ones it
/// had (Markup's or Notebook's). Its look is made of lines, which every PDF app draws sharp; the strokes themselves go
/// with it, for Notebook to show and change them again.
enum PDFInk {
    /// One save after the other.
    static let queue = DispatchQueue(label: "Notebook.PDFInk")

    /// `drawings` are by page number, measured from the top left of each page's crop box. Reads the PDF as it is now
    /// and writes it back, in one coordinated write.
    nonisolated static func write(_ drawings: [Int: PKDrawing], to url: URL) throws {
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
                for (index, drawing) in drawings {
                    guard let page = document.page(at: index) else { continue }
                    for annotation in page.annotations where MarkupDrawings.strokes(in: annotation, on: page) != nil {
                        page.removeAnnotation(annotation)
                    }
                    if !drawing.strokes.isEmpty { page.addAnnotation(InkAnnotation(drawing: drawing, on: page)) }
                }
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
        var color: UIColor = .black
        for stroke in drawing.strokes {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { color = stroke.ink.color.resolvedColor(with: .current) }
            var alpha: CGFloat = 1
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            if stroke.ink.inkType == .marker { alpha *= 0.5 }
            // Plain RGB: a colour space of its own would put a colour profile into the PDF with every save.
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: nil)
            let ink = CGColor(colorSpace: Self.rgb, components: [red, green, blue, alpha].map { min(max($0, 0), 1) }) ?? color.cgColor
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
#endif
