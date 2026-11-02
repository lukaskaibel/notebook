import CoreGraphics

/// Where each page of a PDF drawn on comes from, for the saves of `PDFDrawingSession`: a page of the PDF that saves
/// start from (`base`), or new paper; and where it was in the file when last saved. A save into the file changed
/// elsewhere meanwhile starts from the file as it is then, and takes each page from where it was last saved: a copy
/// made since, or a page given other paper, from where the page it was made from was. Pages taken out are kept, so
/// Undo puts them back from wherever they are by then. `Page` tells the pages apart.
struct PDFPageOrigins<Page: Hashable> {
    struct Entry {
        /// The page of `base` it is, or new paper.
        var origin: PDFPlan.Origin
        /// The paper of a new page, or other paper for a page of the file; nil keeps the page as it is.
        var paper: PaperStyle?
        var size: CGSize
        /// Its number in the file when last saved, which it has there since; nil when it wasn't in that save.
        var savedPlace: Int?
        /// The page it was made from, as a copy or with other paper, which has what it has under its strokes.
        var source: Page?
    }

    private var entries: [Page: Entry] = [:]

    init() {}

    /// The file's pages, as read when drawing started.
    init(pages: [(page: Page, size: CGSize)]) {
        for (index, page) in pages.enumerated() {
            entries[page.page] = Entry(origin: .base(index), size: page.size, savedPlace: index)
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    subscript(page: Page) -> Entry? { entries[page] }

    /// A new page of paper.
    mutating func add(_ page: Page, paper: PaperStyle, size: CGSize) {
        entries[page] = Entry(origin: .new, paper: paper, size: size)
    }

    /// A page made from another: a copy of it, or it with other paper (`paper`).
    mutating func add(_ page: Page, from other: Page, paper: PaperStyle? = nil) {
        guard var entry = entries[other] else { return }
        if let paper { entry.paper = paper }
        entry.savedPlace = nil
        entry.source = other
        entries[page] = entry
    }

    /// The page's slot in a save from `base`, without what is on it.
    func slot(of page: Page) -> PDFPlan.Slot? {
        entries[page].map { PDFPlan.Slot(origin: $0.origin, paper: $0.paper, size: $0.size) }
    }

    /// Where the page is in the file as last saved: its own place, else that of the page it was made from (one made
    /// since, or taken out since, isn't in the file itself). New paper when it isn't there at all.
    func savedOrigin(of page: Page) -> PDFPlan.Origin {
        var next: Page? = page
        var seen: Set<Page> = []
        while let page = next, seen.insert(page).inserted, let entry = entries[page] {
            if let place = entry.savedPlace { return .base(place) }
            next = entry.source
        }
        return .new
    }

    /// A save of `pages`, in this order, was written. `rebased`: into the file as it was changed elsewhere, which
    /// saves start from now, so every page, those taken out too, comes from where it was saved before.
    mutating func saved(_ pages: [Page], rebased: Bool) {
        if rebased {
            let origins = entries.keys.map { ($0, savedOrigin(of: $0)) }
            for (page, origin) in origins {
                entries[page]?.origin = origin
                // A page of the file that isn't in it any more: new paper, its strokes and pictures on it.
                if origin == .new, entries[page]?.paper == nil { entries[page]?.paper = .blank }
            }
        }
        for page in entries.keys { entries[page]?.savedPlace = nil }
        for (place, page) in pages.enumerated() { entries[page]?.savedPlace = place }
    }
}
