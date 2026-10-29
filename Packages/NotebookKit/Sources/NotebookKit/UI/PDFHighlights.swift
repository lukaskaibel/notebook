import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The colours text in a PDF is highlighted in, as in Preview.
enum HighlightColor: String, CaseIterable {
    case yellow, green, blue, pink, purple

    var name: String { rawValue.capitalized }

    var hex: UInt32 {
        switch self {
        case .yellow: 0xFFE14D
        case .green: 0x9BE27A
        case .blue: 0x8CC8FF
        case .pink: 0xFF9DC6
        case .purple: 0xC9A6FF
        }
    }

    var color: NSColor { NSColor(hex: hex) }

    /// The one ⌃⌘H and Highlight use: the one picked last.
    static var current: HighlightColor {
        get { UserDefaults.standard.string(forKey: "pdfHighlightColor").flatMap(HighlightColor.init) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pdfHighlightColor") }
    }

    /// The one a highlight is in, or nearest to it (another app's).
    init(nearest color: NSColor?) {
        let rgba = (color ?? Self.yellow.color).rgba
        func distance(_ other: HighlightColor) -> CGFloat {
            let theirs = other.color.rgba
            return pow(rgba.red - theirs.red, 2) + pow(rgba.green - theirs.green, 2) + pow(rgba.blue - theirs.blue, 2)
        }
        self = Self.allCases.min { distance($0) < distance($1) } ?? .yellow
    }
}

/// A highlight on a page: what it takes to make it, and to find it again in the PDF read anew. Any app's highlight is
/// one, Preview's too.
struct PDFHighlight: Equatable {
    /// The page's number, from 0.
    var page: Int
    var bounds: CGRect
    /// Each line's corners, from the bounds' origin, as PDFKit has them: top left, top right, bottom left, bottom right.
    var quadrilaterals: [CGPoint]
    /// 0xRRGGBB.
    var color: UInt32

    init(page: Int, bounds: CGRect, quadrilaterals: [CGPoint], color: UInt32) {
        self.page = page
        self.bounds = bounds
        self.quadrilaterals = quadrilaterals
        self.color = color
    }

    init?(_ annotation: PDFAnnotation, page: Int) {
        guard annotation.type == "Highlight" else { return nil }
        self.page = page
        bounds = annotation.bounds
        #if os(macOS)
        quadrilaterals = (annotation.quadrilateralPoints ?? []).map(\.pointValue)
        #else
        quadrilaterals = (annotation.quadrilateralPoints ?? []).map(\.cgPointValue)
        #endif
        color = annotation.color.hexValue
    }

    /// The lines selected on the page, highlighted together.
    init?(_ selection: PDFSelection, on page: PDFPage, number: Int, color: HighlightColor) {
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first) { $0.union($1) }
        self.init(page: number, bounds: bounds, quadrilaterals: lines.flatMap { line in
            [CGPoint(x: line.minX, y: line.maxY), CGPoint(x: line.maxX, y: line.maxY), CGPoint(x: line.minX, y: line.minY), CGPoint(x: line.maxX, y: line.minY)]
                .map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
        }, color: color.hex)
    }

    /// Whether a point on the page is on one of its lines.
    func contains(_ point: CGPoint) -> Bool {
        guard quadrilaterals.count >= 4 else { return bounds.contains(point) }
        return stride(from: 0, to: quadrilaterals.count - 3, by: 4).contains { index in
            let corners = quadrilaterals[index..<index + 4]
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let line = CGRect(x: xs.min()! + bounds.minX, y: ys.min()! + bounds.minY, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return line.contains(point)
        }
    }

    func recolored(_ color: HighlightColor) -> PDFHighlight {
        var highlight = self
        highlight.color = color.hex
        return highlight
    }

    /// The highlight as it is in a document: none once it is gone.
    func annotation(in document: PDFDocument) -> PDFAnnotation? {
        guard let page = document.page(at: page) else { return nil }
        return page.annotations.first { annotation in
            guard annotation.type == "Highlight" else { return false }
            let other = annotation.bounds
            return abs(other.minX - bounds.minX) < 0.5 && abs(other.minY - bounds.minY) < 0.5
                && abs(other.width - bounds.width) < 0.5 && abs(other.height - bounds.height) < 0.5
        }
    }

    func makeAnnotation() -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        // Plain RGB: a colour space of its own would put a colour profile into the PDF with every save.
        let rgb = NSColor(hex: color).rgba
        #if os(macOS)
        annotation.quadrilateralPoints = quadrilaterals.map { NSValue(point: $0) }
        annotation.color = NSColor(deviceRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #else
        annotation.quadrilateralPoints = quadrilaterals.map { NSValue(cgPoint: $0) }
        annotation.color = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #endif
        // Not the name of the device's owner, which PDFKit would write otherwise.
        annotation.userName = ""
        annotation.modificationDate = Date()
        return annotation
    }
}

extension PDFHighlight {
    /// Takes `removing` off a document and puts `adding` on it.
    static func apply(removing: [PDFHighlight], adding: [PDFHighlight], to document: PDFDocument) {
        for highlight in removing {
            if let annotation = highlight.annotation(in: document) { annotation.page?.removeAnnotation(annotation) }
        }
        for highlight in adding {
            document.page(at: highlight.page)?.addAnnotation(highlight.makeAnnotation())
        }
    }
}

#if os(macOS)
/// Highlighting text in PDFs on the Mac: one change after the other, shown at once and saved into the PDF itself, the
/// way drawing on it is (`PDFInk`). Undo takes each back, also once the PDF is no longer open.
@MainActor
enum PDFHighlights {
    /// What Undo calls back.
    private static let undoTarget = NSObject()

    /// Takes `removing` off the PDF and puts `adding` on it.
    static func change(_ url: URL, removing: [PDFHighlight], adding: [PDFHighlight], actionName: String, undo: UndoManager?,
                       report: @escaping (String, String) -> Void) {
        // Shown at once where the PDF is open; it is read again once saved.
        for view in NotebookPDFView.shown where view.url == url {
            if let document = view.document { PDFHighlight.apply(removing: removing, adding: adding, to: document) }
        }
        PDFInk.save(url, failure: "The highlight couldn’t be saved in “\(url.lastPathComponent)”.", report: report) { document in
            PDFHighlight.apply(removing: removing, adding: adding, to: document)
        }
        undo?.registerUndo(withTarget: undoTarget) { _ in
            MainActor.assumeIsolated {
                change(url, removing: adding, adding: removing, actionName: actionName, undo: undo, report: report)
            }
        }
        undo?.setActionName(actionName)
    }
}

/// The PDF in the window: PDFKit's view, which also highlights the text selected (Format › Highlight, ⌃⌘H, or from
/// the menu on a right click), takes a highlight off or changes its colour from the menu on it.
@MainActor
final class NotebookPDFView: PDFView {
    let url: URL
    private weak var workspace: Workspace?
    private let report: (String, String) -> Void
    private var selectionChanges: NSObjectProtocol?

    /// The PDFs shown now, which show a change to their highlights at once.
    private static let views = NSHashTable<NotebookPDFView>.weakObjects()
    static var shown: [NotebookPDFView] { views.allObjects }

    init(url: URL, workspace: Workspace?, report: @escaping (String, String) -> Void) {
        self.url = url
        self.workspace = workspace
        self.report = report
        super.init(frame: .zero)
        Self.views.add(self)
        workspace?.shownPDF = self
        // Nothing is selected in this one yet, whatever was in the one before.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workspace?.pdfSelectionChanged(self)
        }
        selectionChanges = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workspace?.pdfSelectionChanged(self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The view leaves the window, as the PDF does.
    func leaveWindow() {
        if let selectionChanges { NotificationCenter.default.removeObserver(selectionChanges) }
        selectionChanges = nil
        Self.views.remove(self)
        workspace?.pdfClosed(self)
    }

    /// Drawing on the pages started or ended: the text can't be highlighted while drawing.
    func drawingChanged() {
        workspace?.pdfSelectionChanged(self)
    }

    var canHighlight: Bool {
        guard !isInMarkupMode, let selection = currentSelection, let text = selection.string else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Highlighting

    @objc func highlightSelection(_ sender: Any?) {
        highlight(in: HighlightColor.current)
    }

    func highlight(in color: HighlightColor) {
        guard canHighlight, let selection = currentSelection, let document else { return }
        HighlightColor.current = color
        let highlights = selection.pages.compactMap { page in
            PDFHighlight(selection, on: page, number: document.index(for: page), color: color)
        }
        guard !highlights.isEmpty else { return }
        // The colour shows, not the selection over it.
        clearSelection()
        PDFHighlights.change(url, removing: [], adding: highlights, actionName: "Highlight", undo: undoManager, report: report)
    }

    func remove(_ highlight: PDFHighlight) {
        PDFHighlights.change(url, removing: [highlight], adding: [], actionName: "Remove Highlight", undo: undoManager, report: report)
    }

    func recolor(_ highlight: PDFHighlight, _ color: HighlightColor) {
        HighlightColor.current = color
        guard highlight.color != color.hex else { return }
        PDFHighlights.change(url, removing: [highlight], adding: [highlight.recolored(color)], actionName: "Change Highlight Colour",
                             undo: undoManager, report: report)
    }

    /// The highlight under a point in the view, any app's.
    func highlight(at point: NSPoint) -> PDFHighlight? {
        guard let document, let page = page(for: point, nearest: false) else { return nil }
        let onPage = convert(point, to: page)
        let number = document.index(for: page)
        // The one on top: the last one made.
        return page.annotations.lazy.reversed().compactMap { PDFHighlight($0, page: number) }.first { $0.contains(onPage) }
    }

    // MARK: - The menu on a right click

    /// On a highlight: Remove Highlight and its colours. On text selected: Highlight and the colours to do it in.
    /// Above PDFKit's own (Look Up, Copy, the zoom).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // PDFKit's own for a highlight (its colours, Remove Highlight, Add Note) change the page on screen only, never
        // the PDF: Notebook's take their place.
        for item in menu.items.reversed() where item.view != nil || item.action.map({ Self.pdfKitMarkup.contains(NSStringFromSelector($0)) }) == true {
            menu.removeItem(item)
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        for (index, item) in menu.items.enumerated().reversed() where item.isSeparatorItem && index > 0 && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(item)
        }
        guard !isInMarkupMode, document != nil else { return menu }
        var items: [NSMenuItem] = []
        if let highlight = highlight(at: convert(event.locationInWindow, from: nil)) {
            let remove = MenuAction(title: "Remove Highlight") { [weak self] in self?.remove(highlight) }
            items.append(remove.item)
            items.append(colors(selected: HighlightColor(nearest: NSColor(hex: highlight.color))) { [weak self] color in
                self?.recolor(highlight, color)
            })
        } else if canHighlight {
            let highlight = MenuAction(title: "Highlight") { [weak self] in self?.highlightSelection(nil) }
            highlight.item.keyEquivalent = "h"
            highlight.item.keyEquivalentModifierMask = [.command, .control]
            items.append(highlight.item)
            items.append(colors(selected: nil) { [weak self] color in self?.highlight(in: color) })
        }
        guard !items.isEmpty else { return menu }
        if !menu.items.isEmpty { items.append(.separator()) }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    private static let pdfKitMarkup: Set<String> = ["_removeMarkup:", "_addNote:"]

    /// The colours in a row, as Finder's tags are: picking one does `pick`.
    private func colors(selected: HighlightColor?, pick: @escaping (HighlightColor) -> Void) -> NSMenuItem {
        let cases = HighlightColor.allCases
        var ticked: NSMenuItem?
        let palette = NSMenu.palette(colors: cases.map(\.color), titles: cases.map(\.name)) { menu in
            // The one just picked, not the highlight's own, which may still be ticked too.
            let picked = menu.selectedItems.first { $0 !== ticked } ?? menu.selectedItems.first
            guard let index = picked.flatMap({ menu.index(of: $0) }), cases.indices.contains(index) else { return }
            MainActor.assumeIsolated { pick(cases[index]) }
        }
        palette.selectionMode = .selectOne
        if let selected, let index = cases.firstIndex(of: selected) {
            ticked = palette.items[index]
            ticked?.state = .on
        }
        let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        item.submenu = palette
        return item
    }
}

/// A menu item that runs a closure, for menus made as they open.
private final class MenuAction: NSObject {
    let item: NSMenuItem
    private let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        super.init()
        item.target = self
        // The item keeps what it runs for as long as the menu does.
        item.representedObject = self
    }

    @objc private func run() { action() }
}
#endif
