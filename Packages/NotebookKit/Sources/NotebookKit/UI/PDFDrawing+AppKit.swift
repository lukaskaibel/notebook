#if os(macOS)
import AppKit
import PDFKit
import PencilKit

/// Drawing right on a PDF on the Mac, as on the iPad: the pencil above it puts a canvas over every page and brings the
/// drawing tools to the bottom of the window, so the mouse, the trackpad or a tablet's pen draws on the page itself,
/// while two fingers still scroll and zoom. The strokes already there (Markup's, or Notebook's from any device) are in
/// the canvases to erase. Ending it, leaving the PDF, going to another app or quitting saves what changed into the PDF
/// itself (`PDFInk`), the same way the iPad does.
@MainActor
final class PDFDrawingSession: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let url: URL
    private weak var view: PDFView?
    /// Strokes are undone here, on whichever page they were drawn. Each is a step of its own.
    let strokeUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// Each page's strokes, by its number, as its canvas has them; pages not shown yet aren't here.
    private var drawings: [Int: PKDrawing] = [:]
    /// The pages drawn on since drawing started. They stay so once saved: saving writes a page's strokes whole.
    private var edited: Set<Int> = []
    /// Drawn on since it was last saved.
    private var isSaved = true
    private var resigning: NSObjectProtocol?
    private let report: (String, String) -> Void
    /// Turns drawing off, as Done does: Escape on a page.
    let stop: () -> Void

    init(url: URL, report: @escaping (String, String) -> Void, stop: @escaping () -> Void) {
        self.url = url
        self.report = report
        self.stop = stop
    }

    var hasChanges: Bool { !edited.isEmpty }

    /// The sessions drawing now, saved when Notebook quits.
    private static let active = NSHashTable<PDFDrawingSession>.weakObjects()

    /// Saves what every PDF drawn on now has, as Notebook quits.
    static func saveAll() {
        for session in active.allObjects { session.save() }
    }

    /// Puts canvases over the pages.
    func start(in view: PDFView) {
        self.view = view
        Self.active.add(self)
        view.isInMarkupMode = true
        view.pageOverlayViewProvider = self
        // As notes are written: going to another app saves.
        resigning = NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        (view as? NotebookPDFView)?.drawingChanged()
        showPages(of: view)
    }

    /// The canvases go and the pages draw their strokes again; what changed is saved. Without changes, the pages are
    /// drawn again at once; with them, once the saved PDF is read again (the canvases show the strokes until then).
    func end() {
        Self.active.remove(self)
        if let resigning { NotificationCenter.default.removeObserver(resigning) }
        resigning = nil
        guard let view else { return }
        view.isInMarkupMode = false
        let canvases = view.canvases
        if let window = view.window, canvases.contains(where: { window.firstResponder === $0 }) { window.makeFirstResponder(view) }
        if hasChanges {
            for canvas in canvases { canvas.takesEvents = false }
            isSaved = false
            save()
        } else {
            leavePages(of: view)
        }
        (view as? NotebookPDFView)?.drawingChanged()
        view.window?.invalidateCursorRects(for: view)
    }

    /// The saved PDF was read again: its pages draw the strokes now, and the canvases left over them go.
    func finish(in view: PDFView) {
        guard view.pageOverlayViewProvider === self else { return }
        leavePages(of: view)
    }

    /// The PDF was read again while drawing (saved as you went to another app, or changed elsewhere): the canvases
    /// come anew over its pages, with the strokes they had.
    func documentChanged(in view: PDFView) {
        showPages(of: view)
    }

    /// Writes the pages drawn on since the last save into the PDF, in the background.
    func save() {
        guard hasChanges, !isSaved else { return }
        isSaved = true
        let changes = edited.reduce(into: [Int: PKDrawing]()) { $0[$1] = drawings[$1] ?? PKDrawing() }
        PDFInk.save(url, failure: "Your drawing couldn’t be saved in “\(url.lastPathComponent)”.", report: report) { PDFInk.put(changes, in: $0) }
    }

    /// The pages stop drawing their own strokes, which the canvases show, and are drawn anew.
    private func showPages(of view: PDFView) {
        guard let document = view.document else { return }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { MarkupDrawings.setEditing(true, on: page) }
        }
        view.reloadDocument()
    }

    private func leavePages(of view: PDFView) {
        view.pageOverlayViewProvider = nil
        if let document = view.document {
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { MarkupDrawings.setEditing(false, on: page) }
            }
        }
        view.reloadDocument()
        // PDFKit on the Mac leaves the overlays it had on their pages, even without anyone to provide them.
        for canvas in view.canvases { canvas.removeFromSuperview() }
    }

    /// A page's strokes become `drawing`, as a step Undo takes back.
    fileprivate func commit(_ drawing: PKDrawing, on page: Int, actionName: String) {
        let old = drawings[page] ?? PKDrawing()
        let grouped = !strokeUndo.isUndoing && !strokeUndo.isRedoing
        if grouped { strokeUndo.beginUndoGrouping() }
        strokeUndo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.commit(old, on: page, actionName: actionName) }
        }
        strokeUndo.setActionName(actionName)
        if grouped { strokeUndo.endUndoGrouping() }
        drawings[page] = drawing
        edited.insert(page)
        isSaved = false
        view?.canvases.first { $0.pageIndex == page }?.show(drawing)
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // Strokes on a turned page couldn't be read back where they were drawn.
        guard let document = view.document, page.rotation == 0 else { return nil }
        let index = document.index(for: page)
        let drawing = drawings[index] ?? MarkupDrawings.drawing(on: page)
        drawings[index] = drawing
        let canvas = PageCanvas(session: self, pageIndex: index, pageSize: page.bounds(for: .cropBox).size)
        canvas.show(drawing)
        return canvas
    }
}

/// The canvas over one page. Its strokes are measured from the top left of the page's crop box, in its points, and
/// drawn as on paper: black ink stays black in Dark Mode.
@MainActor
final class PageCanvas: StrokeCanvas {
    let pageIndex: Int
    private weak var session: PDFDrawingSession?
    private let pageSize: CGSize
    private var drawing = PKDrawing() {
        didSet {
            if drawing != oldValue { picture = nil }
            needsDisplay = true
        }
    }
    /// The strokes, drawn once for as long as neither they nor the zoom change.
    private var picture: (image: NSImage, scale: CGFloat)?
    /// Off once drawing ends: the canvas still shows the strokes until the pages draw them, and lets the clicks through.
    var takesEvents = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    init(session: PDFDrawingSession, pageIndex: Int, pageSize: CGSize) {
        self.session = session
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drawing on page \(pageIndex + 1)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { session?.strokeUndo }

    override var strokes: PKDrawing {
        get { drawing }
        set { drawing = newValue }
    }

    func show(_ drawing: PKDrawing) {
        self.drawing = drawing
    }

    override func commit(_ drawing: PKDrawing, actionName: String) {
        guard let session else { return }
        session.commit(drawing, on: pageIndex, actionName: actionName)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        takesEvents ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if takesEvents { super.resetCursorRects() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scale = newSize.width / max(1, pageSize.width)
    }

    /// Pixels on screen for a point of the canvas, at the zoom the page is shown.
    private var pixelsPerPoint: CGFloat {
        let unit = convert(NSSize(width: 1, height: 1), to: nil)
        return max(abs(unit.width), 0.01) * (window?.backingScaleFactor ?? 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pixels = pixelsPerPoint
        let pixelScale = scale * pixels
        let page = CGRect(origin: .zero, size: pageSize)
        if !drawing.strokes.isEmpty {
            // The whole page's strokes in one picture, unless zoomed so far in that it would be huge: then only the
            // part to draw.
            if page.width * page.height * pixelScale * pixelScale <= 16_000_000 {
                if picture?.scale != pixelScale, let image = DrawingFile.render(drawing, in: page, scale: pixelScale, dark: false) {
                    picture = (NSImage.make(image, scale: pixels), pixelScale)
                }
                picture?.image.drawUpright(in: viewRect(page))
            } else {
                let part = CGRect(x: dirtyRect.minX / scale, y: dirtyRect.minY / scale, width: dirtyRect.width / scale, height: dirtyRect.height / scale)
                    .intersection(page)
                if !part.isEmpty, let image = DrawingFile.render(drawing, in: part, scale: pixelScale, dark: false) {
                    NSImage.make(image, scale: pixels).drawUpright(in: viewRect(part))
                }
            }
        }
        if let live {
            let area = live.renderBounds.insetBy(dx: -2, dy: -2)
            if let image = DrawingFile.render(PKDrawing(strokes: [live]), in: area, scale: pixelScale, dark: false) {
                NSImage.make(image, scale: pixels).drawUpright(in: viewRect(area))
            }
        }
    }

    /// Escape stops drawing; the other keys go to the PDF, which scrolls with them.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session?.stop() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        session?.stop()
    }
}

extension PDFView {
    /// The canvases over the pages shown, while drawing.
    var canvases: [PageCanvas] {
        func find(_ view: NSView) -> [PageCanvas] { (view as? PageCanvas).map { [$0] } ?? view.subviews.flatMap(find) }
        return find(self)
    }
}
#endif
