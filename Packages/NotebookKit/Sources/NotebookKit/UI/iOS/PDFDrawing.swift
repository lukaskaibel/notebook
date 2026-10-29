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
        PDFInk.save(url, failure: "Your drawing couldn’t be saved in “\(url.lastPathComponent)”.", report: report) { PDFInk.put(changes, in: $0) }
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
#endif
