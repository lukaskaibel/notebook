import PDFKit
import SwiftUI

/// A PDF, drawn by PDFKit right in the window as Preview draws it: the pages one under the other on the grey behind
/// them, scrolling under the toolbar. The pages fade in once the file is read (see `FileLoadingView`). A PDF that
/// PDFKit can't show (damaged, or locked with a password) goes to Quick Look instead.
struct PDFFileView: View {
    let url: URL
    /// Words search found in it, to show on their page.
    var find: PDFFind?

    var body: some View {
        FileLoadingView(url: url, background: FileKind.pdf.pageBackground) { url in
            FileLoading.read(url) { url -> PDFDocument? in
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
                return document
            }
        } content: { document in
            PDFKitView(url: url, document: document, find: find)
                .ignoresSafeArea(.container, edges: .top)
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
        view.document = document
        let place = Self.places[url]
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
        guard view.document != nil, let clip = view.documentView?.enclosingScrollView?.contentView else { return }
        places[coordinator.url] = (clip.bounds.origin, view.autoScales ? nil : view.scaleFactor)
    }
}
#else
/// PDFKit's view, as Files and Books show a PDF: the pages one under the other, fitted to the width, with shadows.
/// It keeps where you were in each PDF, so going back to one shows the page you left.
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let document: PDFDocument?
    let find: PDFFind?

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
        defer {
            if let find, view.document != nil, context.coordinator.shown != find.id {
                context.coordinator.shown = find.id
                view.show(find)
            }
        }
        guard view.document !== document else { return }
        view.document = document
        guard document != nil else { return }
        let place = Self.places[url]
        if let scale = place?.scale {
            view.autoScales = false
            view.scaleFactor = scale
        }
        if let place, let document, let page = document.page(at: min(place.page, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        guard let document = view.document, let page = view.currentPage else { return }
        let top = view.convert(CGPoint(x: 0, y: view.safeAreaInsets.top), to: page)
        places[coordinator.url] = (document.index(for: page), top, view.autoScales ? nil : view.scaleFactor)
    }
}
#endif
