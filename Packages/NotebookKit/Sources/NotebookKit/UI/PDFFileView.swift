import PDFKit
import SwiftUI

/// A PDF, drawn by PDFKit right in the window as Preview draws it: the pages one under the other on the grey behind
/// them, scrolling under the toolbar. The pages fade in once the file is read (see `FileLoadingView`). A PDF that
/// PDFKit can't show (damaged, or locked with a password) goes to Quick Look instead.
struct PDFFileView: View {
    let url: URL
    /// Words search found in it, to show on their page.
    var find: PDFFind?
    /// The pen above it is on: its pages are drawn on (iPhone and iPad).
    var isDrawing = false
    /// Tells that something went wrong, such as a drawing that couldn't be saved.
    var report: (String, String) -> Void = { _, _ in }

    var body: some View {
        FileLoadingView(url: url, background: FileKind.pdf.pageBackground) { url in
            FileLoading.read(url) { url -> PDFDocument? in
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
                MarkupDrawings.sharpen(document, fileAt: url)
                return document
            }
        } content: { document in
            #if os(macOS)
            PDFKitView(url: url, document: document, find: find)
                .ignoresSafeArea(.container, edges: .top)
            #else
            PDFKitView(url: url, document: document, find: find, isDrawing: isDrawing, report: report)
                .ignoresSafeArea(.container, edges: .top)
            #endif
        }
    }
}

/// Words to show in a PDF opened from search: on their page, selected.
struct PDFFind: Equatable {
    var words: String
    /// Counted from 1.
    var page: Int?
    var id = UUID()
}

extension PDFView {
    /// Goes to the words search found, on their page, and selects them as Find does: all of them together if they
    /// are, else the longest. Only that page is looked at, so a long PDF opens as fast as any.
    func show(_ find: PDFFind) {
        guard let document, document.pageCount > 0 else { return }
        let index = min(max((find.page ?? 1) - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        let text = (page.string ?? "") as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let words = find.words.split(whereSeparator: \.isWhitespace).map(String.init).sorted { $0.count > $1.count }
        let range = ([find.words] + words).lazy.map { text.range(of: $0, options: options) }.first { $0.location != NSNotFound }
        guard let range, let selection = page.selection(for: range) else {
            go(to: page)
            return
        }
        go(to: selection)
        setCurrentSelection(selection, animate: true)
    }
}

final class PDFViewCoordinator {
    let url: URL
    /// The search whose words are shown, so they are shown once.
    var shown: UUID?
    #if os(iOS)
    /// Drawing on its pages, from when the pen is on until what was drawn is saved and read again.
    var drawing: PDFDrawingSession?
    /// The document the canvases are over.
    weak var drawnDocument: PDFDocument?
    #endif

    init(url: URL) { self.url = url }
}

#if os(macOS)
/// PDFKit's view, set up like Preview's continuous scroll: the pages fit the width, with page breaks and shadows.
/// It keeps where you were in each PDF, so going back to one (or swiping to it) shows the page you left.
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let document: PDFDocument?
    let find: PDFFind?

    /// Where each PDF was left: how far it was scrolled, in the pages' own points, and its zoom unless it fit the width.
    @MainActor private static var places: [URL: (origin: CGPoint, scale: CGFloat?)] = [:]

    func makeCoordinator() -> PDFViewCoordinator { PDFViewCoordinator(url: url) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        defer {
            if let find, view.document != nil, context.coordinator.shown != find.id {
                context.coordinator.shown = find.id
                view.show(find)
            }
        }
        guard view.document !== document else { return }
        // Read again after it changed: it stays where it was.
        let place = view.document != nil ? Self.place(in: view) : Self.places[url]
        view.document = document
        if let scale = place?.scale { view.scaleFactor = scale }
        guard document != nil, let scrollView = view.documentView?.enclosingScrollView else { return }
        // PDFKit fits the pages to the width only now, and keeps the middle of the view where it was, which leaves
        // the first page part way down. It starts at the top instead, below the toolbar, or where it was left.
        view.layoutDocumentView()
        let clip = scrollView.contentView
        clip.scroll(to: place?.origin ?? NSPoint(x: clip.bounds.minX, y: -scrollView.contentInsets.top / scrollView.magnification))
        scrollView.reflectScrolledClipView(clip)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        if let place = place(in: view) { places[coordinator.url] = place }
    }

    private static func place(in view: PDFView) -> (origin: CGPoint, scale: CGFloat?)? {
        guard view.document != nil, let clip = view.documentView?.enclosingScrollView?.contentView else { return nil }
        return (clip.bounds.origin, view.autoScales ? nil : view.scaleFactor)
    }
}
#else
/// PDFKit's view, as Files and Books show a PDF: the pages one under the other, fitted to the width, with shadows.
/// It keeps where you were in each PDF, so going back to one shows the page you left.
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let document: PDFDocument?
    let find: PDFFind?
    let isDrawing: Bool
    let report: (String, String) -> Void

    /// Where each PDF was left: the page (by number, as each visit reads the file anew) and the point on it at the
    /// top of the view, and its zoom unless it fit.
    @MainActor private static var places: [URL: (page: Int, point: CGPoint, scale: CGFloat?)] = [:]

    func makeCoordinator() -> PDFViewCoordinator { PDFViewCoordinator(url: url) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        defer {
            if let find, view.document != nil, coordinator.shown != find.id {
                coordinator.shown = find.id
                view.show(find)
            }
            updateDrawing(view, coordinator: coordinator)
        }
        guard view.document !== document else { return }
        // Read again after it changed: it stays where it was.
        let place = view.document != nil ? Self.place(in: view) : Self.places[url]
        view.document = document
        if !isDrawing, let session = coordinator.drawing, document != nil {
            // What was drawn is saved and read again: the pages draw it now.
            session.finish(in: view)
            coordinator.drawing = nil
        }
        guard document != nil else { return }
        if let scale = place?.scale {
            view.autoScales = false
            view.scaleFactor = scale
        }
        if let place, let document, let page = document.page(at: min(place.page, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        }
    }

    /// The pen goes on: canvases over the pages. It goes off: what was drawn is saved.
    private func updateDrawing(_ view: PDFView, coordinator: PDFViewCoordinator) {
        guard view.document != nil else { return }
        if isDrawing, let session = coordinator.drawing {
            // On again before what was drawn was saved and read again: the same strokes go on.
            if !view.isInMarkupMode {
                coordinator.drawnDocument = view.document
                session.start(in: view)
                return
            }
            // Read again while drawing: the canvases come anew over its pages.
            guard coordinator.drawnDocument !== view.document else { return }
            coordinator.drawnDocument = view.document
            session.documentChanged(in: view)
        } else if isDrawing {
            let session = PDFDrawingSession(url: url, report: report)
            coordinator.drawing = session
            coordinator.drawnDocument = view.document
            session.start(in: view)
        } else if !isDrawing, let session = coordinator.drawing, view.isInMarkupMode {
            session.end()
            // Without changes there is nothing to wait for.
            if !session.hasChanges { coordinator.drawing = nil }
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        if let place = place(in: view) { places[coordinator.url] = place }
        // Leaving the PDF while drawing saves what was drawn.
        if view.isInMarkupMode { coordinator.drawing?.end() }
        coordinator.drawing = nil
    }

    private static func place(in view: PDFView) -> (page: Int, point: CGPoint, scale: CGFloat?)? {
        guard let document = view.document, let page = view.currentPage else { return nil }
        let top = view.convert(CGPoint(x: 0, y: view.safeAreaInsets.top), to: page)
        return (document.index(for: page), top, view.autoScales ? nil : view.scaleFactor)
    }
}
#endif
