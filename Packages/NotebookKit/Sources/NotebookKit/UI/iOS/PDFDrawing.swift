#if os(iOS)
import PaperKit
import PDFKit
import PencilKit
import UIKit

/// Drawing right on a PDF, as in Notes, and keeping a handwritten note in one: the pen above it puts a canvas over
/// every page (PaperKit's, the one Markup has), with the system's tool picker, so Apple Pencil, the eraser, the lasso
/// and the ruler work on the page itself, and pictures put on a page can be moved, turned and resized there. Pages can
/// be added, given other paper or taken out, and pulling past the last page adds one.
///
/// What is drawn is saved into the PDF a moment after you stop, and when the pen goes off, the PDF is left or the app
/// goes to the background (`PDFPageWriter`). Every save makes the file anew from the PDF as it was read when drawing
/// started (its `base`), so Undo can put back a page that was taken out, whatever was saved meanwhile.
@MainActor
final class PDFDrawingSession: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let url: URL
    private weak var view: PDFView?
    private let toolPicker = PKToolPicker()
    /// Keeps the tool picker up: it shows while its responder is focused, and no one canvas is (pages come and go).
    private lazy var anchor = ToolAnchor(session: self)
    /// Strokes, pictures and pages are undone here, whichever page they were on.
    let undo = UndoManager()
    /// A canvas for each page shown since drawing started, kept so its Undo has it to go back to.
    private var editors: [ObjectIdentifier: PageEditor] = [:]
    /// Where each page of the document shown comes from, and what happened to it.
    private var slots: [ObjectIdentifier: Slot] = [:]
    /// The PDF as it was read when drawing started, and when the file was last changed by this session.
    private var base: Data?
    private var written: Date?
    private var pausedGestures: [UIGestureRecognizer] = []
    private var scrollTouches: Int?
    private var bottomInset: CGFloat = 0
    private var background: NSObjectProtocol?
    private var scrolling: NSKeyValueObservation?
    private lazy var adder = PageAdder()
    private let report: (String, String) -> Void
    /// Tells the window of the pages and the page in view, for the Page menu.
    var changed: (() -> Void)?
    /// The tool picker's + asks for pictures from here.
    var addPictures: ((AttachmentSource) -> Void)?

    /// Counts the changes made and the ones saved.
    private var changes = 0
    private var savedChanges = 0
    private var saveTimer: Timer?
    private(set) var isSaving = false
    /// Drawing: the canvases take the touches. Once the pen goes off, what was drawn is saved and the pages draw it.
    private(set) var isActive = false
    /// The pages draw what was drawn again, and have no canvases.
    private var isFinished = false
    private var shownIndex: Int?

    private struct Slot {
        var origin: PDFPlan.Origin
        var paper: PaperStyle?
        var size: CGSize
    }

    /// Each page's place when last saved, which is its number in the file since then.
    private var savedPlaces: [ObjectIdentifier: Int] = [:]

    init(url: URL, report: @escaping (String, String) -> Void) {
        self.url = url
        self.report = report
    }

    var hasUnsavedChanges: Bool { changes != savedChanges }
    /// Anything changed since drawing started, saved or not.
    var isTouched: Bool { changes > 0 }
    /// Something was written into the file since drawing started.
    var hasSaved: Bool { savedChanges > 0 }

    /// For the pickers: the window the PDF is in.
    var window: UIWindow? { view?.window }

    // MARK: - Starting and ending

    /// Puts canvases over the pages and brings the tool picker.
    func start(in view: PDFView) {
        self.view = view
        isActive = true
        isFinished = false
        guard let document = view.document else { return }
        if slots.isEmpty {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                slots[ObjectIdentifier(page)] = Slot(origin: .base(index), size: page.bounds(for: .cropBox).size)
                savedPlaces[ObjectIdentifier(page)] = index
            }
            readBase()
        }
        view.addSubview(anchor)
        toolPicker.stateAutosaveName = "NotebookDrawing"
        // The page is paper, white also in Dark Mode: black ink stays black, and the tool picker's colours are those.
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.accessoryItem = accessoryItem()
        toolPicker.setVisible(true, forFirstResponder: anchor)
        // Up for whatever in the PDF has the focus: a canvas takes it while a picture is picked.
        view.pencilKitResponderState.activeToolPicker = toolPicker
        view.pencilKitResponderState.toolPickerVisibility = .visible
        _ = anchor.becomeFirstResponder()
        for editor in editors.values {
            editor.controller.isEditable = true
            toolPicker.setVisible(true, forFirstResponder: editor.controller)
        }
        view.isInMarkupMode = true
        view.pageOverlayViewProvider = self
        if let scrollView = view.scrollView {
            // One finger draws, so two scroll, as in Notes; where only Apple Pencil draws, a finger scrolls still.
            if !UIPencilInteraction.prefersPencilOnlyDrawing {
                scrollTouches = scrollView.panGestureRecognizer.minimumNumberOfTouches
                scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
            }
            // The last page scrolls up above the tool picker.
            bottomInset = 110
            scrollView.contentInset.bottom += bottomInset
            adder.attach(to: view)
            scrolling = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrolled(scrollView) }
            }
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        }
        // A stroke from left to right is also how you go back from anywhere on the screen: it would leave the PDF.
        var responder: UIResponder? = view
        while let next = responder, !(next is UINavigationController) { responder = next.next }
        if let back = (responder as? UINavigationController)?.interactiveContentPopGestureRecognizer, back.isEnabled {
            back.isEnabled = false
            pausedGestures.append(back)
        }
        pauseDocumentGestures(of: view)
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        showPages(of: view)
        changed?()
    }

    /// The canvases stop taking touches and the tool picker goes; what changed is saved. Once the saved PDF is read
    /// again (`finish`), its pages draw it and the canvases go.
    func end() {
        guard isActive else { return }
        isActive = false
        saveTimer?.invalidate()
        toolPicker.setVisible(false, forFirstResponder: anchor)
        for editor in editors.values {
            toolPicker.setVisible(false, forFirstResponder: editor.controller)
            editor.controller.selection = []
            editor.controller.isEditable = false
            _ = editor.controller.resignFirstResponder()
        }
        view?.pencilKitResponderState.toolPickerVisibility = nil
        view?.pencilKitResponderState.activeToolPicker = nil
        _ = anchor.resignFirstResponder()
        anchor.removeFromSuperview()
        pausedGestures.forEach { $0.isEnabled = true }
        pausedGestures = []
        scrolling = nil
        adder.detach()
        if let background { NotificationCenter.default.removeObserver(background) }
        background = nil
        guard let view else { return }
        if let scrollView = view.scrollView {
            if let scrollTouches { scrollView.panGestureRecognizer.minimumNumberOfTouches = scrollTouches }
            scrollTouches = nil
            scrollView.contentInset.bottom -= bottomInset
            bottomInset = 0
            scrollView.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
        }
        view.isInMarkupMode = false
        if hasUnsavedChanges { save() }
    }

    /// The saved PDF is shown, or nothing was changed: its pages draw the strokes now, and the canvases go.
    func finish(in view: PDFView) {
        guard view.pageOverlayViewProvider === self else { return }
        leavePages(of: view)
    }

    // MARK: - Pages

    /// The page in the middle of the view: the one the Page menu and new pictures are for.
    var currentPage: PDFPage? {
        guard let view else { return nil }
        return view.page(for: CGPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true) ?? view.currentPage
    }

    var pageCount: Int { view?.document?.pageCount ?? 0 }

    var currentIndex: Int? {
        guard let page = currentPage, let document = view?.document else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// The paper of a page, if Notebook made it.
    func paper(of page: PDFPage) -> PaperStyle? {
        slots[ObjectIdentifier(page)]?.paper ?? NotebookPaper.style(of: page)
    }

    /// A new page after `index` (or at the end), as large as the page before it and of its paper, or of `paper`.
    func addPage(_ paper: PaperStyle? = nil, after index: Int? = nil) {
        guard let view, let document = view.document, document.pageCount > 0 else { return }
        let after = min(index ?? document.pageCount - 1, document.pageCount - 1)
        guard let before = document.page(at: after) else { return }
        let style = paper ?? self.paper(of: before) ?? NotebookSettings.shared.paper
        let size = before.bounds(for: .cropBox).size
        guard let page = NotebookPaper.page(style, size: size) else { return }
        insert(page, at: after + 1, slot: Slot(origin: .new, paper: style, size: size), named: "Add Page")
        view.go(to: page)
        changed?()
    }

    /// Takes the page out; Undo puts it back.
    func removePage(at index: Int) {
        guard let view, let document = view.document, document.pageCount > 1, let page = document.page(at: index),
              let slot = slots[ObjectIdentifier(page)] else { return }
        remove(page, slot: slot, named: "Delete Page")
    }

    /// Other paper for a page, with what is on it.
    func changePaper(of index: Int, to paper: PaperStyle) {
        guard let view, let document = view.document, let old = document.page(at: index), let slot = slots[ObjectIdentifier(old)],
              self.paper(of: old) != paper, let page = NotebookPaper.page(paper, size: old.bounds(for: .cropBox).size) else { return }
        var new = slot
        new.paper = paper
        swap(old, for: page, slots: (slot, new))
        undo.setActionName("Change Paper")
    }

    /// One page in the place of another, the canvas going along with what is on it.
    private func swap(_ old: PDFPage, for page: PDFPage, slots: (old: Slot, new: Slot)) {
        guard let view, let document = view.document else { return }
        let index = document.index(for: old)
        guard index != NSNotFound else { return }
        let editor = editor(for: old)
        document.insert(page, at: index)
        document.removePage(at: index + 1)
        self.slots[ObjectIdentifier(old)] = nil
        self.slots[ObjectIdentifier(page)] = slots.new
        editors[ObjectIdentifier(page)] = editor
        editor.page = page
        MarkupDrawings.setEditing(true, pictures: true, on: page)
        undo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.swap(page, for: old, slots: (slots.new, slots.old)) }
        }
        reload(view)
        session(edited: editor)
    }

    private func insert(_ page: PDFPage, at index: Int, slot: Slot, named name: String) {
        guard let view, let document = view.document else { return }
        document.insert(page, at: min(index, document.pageCount))
        slots[ObjectIdentifier(page)] = slot
        MarkupDrawings.setEditing(true, pictures: true, on: page)
        undo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.remove(page, slot: slot, named: name) }
        }
        undo.setActionName(name)
        reload(view)
        madeChange()
    }

    private func remove(_ page: PDFPage, slot: Slot, named name: String) {
        guard let view, let document = view.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, document.pageCount > 1 else { return }
        document.removePage(at: index)
        slots[ObjectIdentifier(page)] = nil
        undo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.insert(page, at: index, slot: slot, named: name) }
        }
        undo.setActionName(name)
        reload(view)
        madeChange()
    }

    // MARK: - Pictures

    /// Puts pictures on the page in view, in the middle of what shows of it, picked so they can be moved at once.
    func insert(_ pictures: [PictureImage]) {
        guard isActive, let view, let page = currentPage, !pictures.isEmpty else { return }
        let editor = editor(for: page)
        guard var markup = editor.controller.markup else { return }
        let before = markup
        let crop = page.bounds(for: .cropBox)
        // The part of the page on screen, measured from its top left.
        let shown = view.convert(view.bounds, to: page)
        let visible = CGRect(x: shown.minX - crop.minX, y: crop.maxY - shown.maxY, width: shown.width, height: shown.height)
            .intersection(CGRect(origin: .zero, size: crop.size))
        let area = visible.isNull || visible.width < 40 || visible.height < 40 ? CGRect(origin: .zero, size: crop.size) : visible
        var placed: [MarkupOrderedSet.ElementID] = []
        for (offset, picture) in pictures.enumerated() {
            guard let image = picture.cgImage else { continue }
            let side = min(area.width, area.height) * 0.6
            let scale = min(side / CGFloat(image.width), side / CGFloat(image.height), 1)
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let step = CGFloat(offset) * 24
            let frame = CGRect(x: area.midX - size.width / 2 + step, y: area.midY - size.height / 2 + step, width: size.width, height: size.height)
            let element = ImageMarkup(image: image, frame: frame)
            editor.adopt(element.id, image: picture)
            // Under the strokes, where it stays once saved.
            markup.subelements.insert(element, at: 0)
            placed.append(MarkupOrderedSet.ElementID(element.id))
        }
        editor.controller.markup = markup
        editor.controller.selection = Set(placed)
        undo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.replace(editor, with: before, named: "Add Picture") }
        }
        undo.setActionName(pictures.count == 1 ? "Add Picture" : "Add Pictures")
        session(edited: editor)
    }

    /// Puts back what a page had, for Undo and Redo of what PaperKit doesn't undo itself.
    private func replace(_ editor: PageEditor, with markup: PaperMarkup?, named name: String) {
        let now = editor.controller.markup
        editor.controller.selection = []
        editor.controller.markup = markup
        undo.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.replace(editor, with: now, named: name) }
        }
        undo.setActionName(name)
        session(edited: editor)
    }

    // MARK: - Saving

    fileprivate func session(edited editor: PageEditor) {
        editor.isEdited = true
        madeChange()
    }

    /// Something changed: it is saved once you stop for a moment.
    private func madeChange() {
        changes += 1
        scheduleSave()
        // Once the pages have been laid out again.
        DispatchQueue.main.async { [weak self] in self?.changed?() }
    }

    private func scheduleSave(after delay: TimeInterval = 2) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// The PDF as it was read, from the file, before any save.
    private func readBase() {
        let url = url
        PDFInk.queue.async { [weak self] in
            let data = FileLoading.read(url) { try? Data(contentsOf: $0) }
            let date = Self.modificationDate(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.base = data
                    self?.written = date
                }
            }
        }
    }

    /// Asked of the disk each time: a URL keeps what it was told.
    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes what changed into the PDF, in the background. One save at a time; changes made meanwhile come after.
    func save() {
        saveTimer?.invalidate()
        guard hasUnsavedChanges, !isSaving, let document = view?.document else { return }
        guard let base else {
            // Still being read: the save comes once it is.
            scheduleSave(after: 0.3)
            return
        }
        isSaving = true
        let counted = changes
        var pages: [PDFPage] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { pages.append(page) }
        }
        let slots = pages.map { self.slots[ObjectIdentifier($0)] ?? Slot(origin: .new, paper: .blank, size: $0.bounds(for: .cropBox).size) }
        let edited = pages.map { page in editors[ObjectIdentifier(page)].flatMap { $0.isEdited ? $0 : nil } }
        let url = url, written = written
        Task { @MainActor in
            var plan = PDFPlan(slots: [])
            for (slot, editor) in zip(slots, edited) {
                plan.slots.append(PDFPlan.Slot(origin: slot.origin, paper: slot.paper, size: slot.size, content: await editor?.content()))
            }
            // The pages as last saved, for when the file changed elsewhere since and is what changes go into.
            let savedOrigins = pages.map { self.savedPlaces[ObjectIdentifier($0)].map(PDFPlan.Origin.base) ?? .new }
            let finalPlan = plan
            PDFInk.queue.async { [weak self] in
                var plan = finalPlan
                var base = base
                var rebased = false
                if let now = Self.modificationDate(url), let written, now > written.addingTimeInterval(0.5),
                   let current = FileLoading.read(url, { try? Data(contentsOf: $0) }) {
                    base = current
                    rebased = true
                    for index in plan.slots.indices { plan.slots[index].origin = savedOrigins[index] }
                }
                var failure: Error?
                do {
                    try PDFPageWriter.write(plan, base: base, to: url)
                } catch {
                    failure = error
                }
                let date = Self.modificationDate(url)
                let newBase = rebased ? base : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.saved(pages, counted: counted, date: date, base: newBase, failure: failure)
                    }
                }
            }
        }
    }

    private func saved(_ pages: [PDFPage], counted: Int, date: Date?, base newBase: Data?, failure: Error?) {
        isSaving = false
        if let failure {
            report("Your drawing couldn’t be saved in “\(url.lastPathComponent)”.", failure.localizedDescription)
            return
        }
        written = date
        savedPlaces = Dictionary(uniqueKeysWithValues: pages.enumerated().map { (ObjectIdentifier($1), $0) })
        if let newBase {
            // The file as saved is what pages come from now: a page put back since that it doesn't have is new paper.
            base = newBase
            for (key, slot) in slots {
                if let place = savedPlaces[key] {
                    slots[key]?.origin = .base(place)
                } else if case .base = slot.origin {
                    slots[key]?.origin = .new
                    if slot.paper == nil { slots[key]?.paper = .blank }
                }
            }
        }
        savedChanges = max(savedChanges, counted)
        if hasUnsavedChanges {
            if isActive { scheduleSave() } else { save() }
        } else if !isActive {
            // Done drawing: the PDF is read again, and its pages draw what was drawn.
            FileLoading.didWrite(url)
        }
    }

    // MARK: - Canvases

    fileprivate func editor(for page: PDFPage) -> PageEditor {
        if let editor = editors[ObjectIdentifier(page)] { return editor }
        let editor = PageEditor(page: page, session: self)
        editors[ObjectIdentifier(page)] = editor
        return editor
    }

    /// The pages stop drawing their own strokes and pictures, which the canvases show, and are drawn anew.
    private func showPages(of view: PDFView) {
        guard let document = view.document else { return }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { MarkupDrawings.setEditing(true, pictures: true, on: page) }
        }
        view.coveringRedraw { reload(view) }
    }

    private func leavePages(of view: PDFView) {
        isFinished = true
        view.pageOverlayViewProvider = nil
        // PDFKit leaves the overlays it was given where they are.
        for editor in editors.values { editor.host.removeFromSuperview() }
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
        guard let document = view.document else { return }
        view.keepingScroll {
            view.document = nil
            view.document = document
        }
        pauseDocumentGestures(of: view)
    }

    /// The PDF's text selection, its loupe and its taps on links would take the strokes, and its focus would take the
    /// tool picker away (markup mode doesn't stop them). Its view is made anew with the document given again.
    private func pauseDocumentGestures(of view: PDFView) {
        guard isActive else { return }
        for gesture in view.documentView?.gestureRecognizers ?? [] where gesture.isEnabled {
            gesture.isEnabled = false
            pausedGestures.append(gesture)
        }
    }

    fileprivate func attach(_ controller: PaperMarkupViewController) {
        toolPicker.addObserver(controller)
        if isActive { toolPicker.setVisible(true, forFirstResponder: controller) }
    }

    // MARK: - Pulling past the last page

    private func scrolled(_ scrollView: UIScrollView) {
        guard isActive else { return }
        adder.update(pulled: scrollView.contentOffset.y - pullStart(of: scrollView), dragging: scrollView.isDragging)
        if let index = currentIndex, index != shownIndex {
            shownIndex = index
            changed?()
        }
    }

    /// Where pulling past the last page starts: as far down as it scrolls, or where it rests when it all fits on the
    /// screen, which PDFKit puts in the middle.
    private func pullStart(of scrollView: UIScrollView) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        let end = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height
        if end < -inset.top { return restingOffset ?? -inset.top }
        return end
    }

    /// Where the pages rested when the drag began.
    private var restingOffset: CGFloat?

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began, let scrollView = view?.scrollView { restingOffset = scrollView.contentOffset.y }
        guard isActive, gesture.state == .ended || gesture.state == .cancelled else { return }
        guard adder.isArmed else { return }
        adder.reset()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        addPage()
    }

    // MARK: - The tool picker's +

    private func accessoryItem() -> UIBarButtonItem {
        let pictures = AttachmentSource.available.filter { $0 != .files }.map { source in
            UIAction(title: source.name, image: UIImage(systemName: source.symbol)) { [weak self] _ in self?.addPictures?(source) }
        }
        let file = UIAction(title: "Choose File", image: UIImage(systemName: "folder")) { [weak self] _ in self?.addPictures?(.files) }
        let pages = UIMenu(title: "Add Page", image: UIImage(systemName: "doc.badge.plus"), children: PaperStyle.allCases.map { paper in
            UIAction(title: paper.name, image: UIImage(systemName: paper.symbol)) { [weak self] _ in
                guard let self else { return }
                self.addPage(paper, after: self.currentIndex)
            }
        })
        let menu = UIMenu(children: [UIMenu(options: .displayInline, children: pictures + [file]), pages])
        let item = UIBarButtonItem(title: "Add", image: UIImage(systemName: "plus"), menu: menu)
        item.accessibilityLabel = "Add"
        return item
    }

    #if DEBUG
    /// For the debug remote: turns the first picture on the page in view, as its rotation handle does.
    func debugRotateFirstPicture(by angle: CGFloat) {
        guard let page = currentPage else { return }
        let editor = editor(for: page)
        guard var markup = editor.controller.markup,
              let index = markup.subelements.firstIndex(where: { $0 is ImageMarkup }), var picture = markup.subelements[index] as? ImageMarkup else { return }
        picture.rotation += angle
        markup.subelements.updateOrAppend(picture)
        editor.controller.markup = markup
        session(edited: editor)
    }

    /// For the debug remote: a finger draws, as when no Apple Pencil was ever used.
    func debugFingerDraws() {
        for editor in editors.values { editor.controller.directTouchMode = .drawing }
    }

    /// For the debug remote: the canvases and what they hold.
    var debugCanvases: String {
        let pages = view?.document.map { document in (0..<document.pageCount).compactMap { document.page(at: $0) } } ?? []
        let scroll = view?.scrollView.map { "offset \($0.contentOffset.y) size \($0.contentSize.height) bounds \($0.bounds.height) inset \($0.adjustedContentInset.top)/\($0.adjustedContentInset.bottom) " } ?? ""
        let ink = (editors.values.first?.controller.drawingTool as? PKInkingTool).map { "\($0.inkType.rawValue) \($0.width) " } ?? ""
        return scroll + "pencil only \(UIPencilInteraction.prefersPencilOnlyDrawing) \(ink)active \(isActive) provider \(view?.pageOverlayViewProvider === self) editors \(editors.count): " + pages.enumerated().map { index, page in
            guard let editor = editors[ObjectIdentifier(page)] else { return "\(index + 1): none" }
            let elements = editor.controller.markup?.subelements.map { $0 is PKStroke ? "stroke" : "\(type(of: $0))" } ?? []
            let marks = page.annotations.map { "\($0.type ?? "")=\($0.value(forAnnotationKey: NotebookPaper.key) ?? "-")" }
            return "\(index + 1): \(marks) \(editor.host.window != nil ? "shown" : "hidden") \(editor.host.frame.integral) canvas \(editor.controller.view.frame.integral) tool \(type(of: editor.controller.drawingTool)) touch \(editor.controller.directTouchMode) auto \(editor.controller.directTouchAutomaticallyDraws) first \(editor.controller.isFirstResponder) editable \(editor.controller.isEditable) edited \(editor.isEdited) \(elements)"
        }.joined(separator: "; ")
    }
    #endif

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        // PDFKit asks the provider it had for a while after it has none.
        guard !isFinished else { return nil }
        let editor = editor(for: page)
        editor.controller.isEditable = isActive
        return editor.host
    }
}

/// The canvas over one page, and what Notebook knows of the pictures on it.
@MainActor
private final class PageEditor: NSObject, PaperMarkupViewController.Delegate {
    weak var session: PDFDrawingSession?
    var page: PDFPage
    let controller: PaperMarkupViewController
    let host = PageHost()
    /// Changed since drawing started: saved with what it has, every save.
    var isEdited = false
    /// The pictures' ids in the file, by their elements; the ones in the file when drawing started; and the pictures of
    /// the ones new since, to be written.
    private var ids: [MarkupID<ImageMarkup>: String] = [:]
    private var inBase: Set<String> = []
    private var images: [String: PictureImage] = [:]

    init(page: PDFPage, session: PDFDrawingSession) {
        self.page = page
        self.session = session
        let crop = page.bounds(for: .cropBox)
        var markup = PaperMarkup(bounds: CGRect(origin: .zero, size: crop.size))
        markup.backgroundColor = UIColor.clear.cgColor
        var ids: [MarkupID<ImageMarkup>: String] = [:]
        for picture in MarkupDrawings.pictures(on: page) {
            guard let image = picture.image?.cgImage else { continue }
            let element = ImageMarkup(image: image, frame: picture.frame, rotation: picture.rotation)
            markup.subelements.append(element)
            ids[element.id] = picture.id
        }
        markup.append(contentsOf: MarkupDrawings.drawing(on: page))
        controller = PaperMarkupViewController(markup: markup, supportedFeatureSet: Self.features)
        self.ids = ids
        inBase = Set(ids.values)
        super.init()
        host.session = session
        controller.delegate = self
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.overrideUserInterfaceStyle = .light
        controller.zoomRange = 1...1
        controller.scrollConfiguration.isScrollEnabled = false
        controller.scrollConfiguration.visibleScrollIndicators = []
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(controller.view)
        host.accessibilityLabel = "Drawing"
        session.attach(controller)
    }

    /// Strokes and pictures: no stickers, text, shapes, loupes or links, which the PDF wouldn't keep.
    private static var features: FeatureSet {
        var features = FeatureSet.latest
        for feature in [FeatureSet.Feature.stickers, .text, .loupes, .links, .shapeFills, .shapeStrokes, .shapeOpacity] {
            features.remove(feature)
        }
        features.shapes = []
        return features
    }

    /// A picture put on the page since drawing started.
    func adopt(_ id: MarkupID<ImageMarkup>, image: PictureImage) {
        let name = UUID().uuidString
        ids[id] = name
        images[name] = image
    }

    /// What is on the page, to be saved: strokes, and pictures with what they show when the file doesn't have it yet.
    func content() async -> PageContent {
        var content = PageContent()
        guard let markup = controller.markup else { return content }
        var strokes: [PKStroke] = []
        for element in markup.subelements {
            if let stroke = element as? PKStroke {
                // Made anew: PaperKit's strokes have no id of their own, which a drawing made of them needs.
                strokes.append(PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask))
            } else if let picture = element as? ImageMarkup {
                // A copy made with Duplicate, or pasted, is a picture of its own.
                let id: String
                if let known = ids[picture.id] {
                    id = known
                } else {
                    id = UUID().uuidString
                    ids[picture.id] = id
                }
                var image = inBase.contains(id) ? nil : images[id]
                if !inBase.contains(id), image == nil, let pixels = await picture.image {
                    image = await Task.detached { PictureImage.make(from: pixels) }.value
                    images[id] = image
                }
                content.pictures.append(PDFPicture(id: id, frame: picture.frame, rotation: picture.rotation, image: image))
            }
        }
        content.drawing = PKDrawing(strokes: strokes)
        return content
    }

    func paperMarkupViewControllerDidChangeMarkup(_ controller: PaperMarkupViewController) {
        session?.session(edited: self)
    }
}

/// Holds a page's canvas. PaperKit takes the undo manager of what it is in: the session's, so that Undo goes back
/// through every page in the order things were done.
@MainActor
private final class PageHost: UIView {
    weak var session: PDFDrawingSession?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { session?.undo }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}

/// What shows when you pull past the last page: a hint at the bottom, and a tap you feel once letting go adds a page.
@MainActor
private final class PageAdder {
    private let label = UILabel()
    private let symbol = UIImageView()
    private let stack = UIStackView()
    private(set) var isArmed = false
    /// How far past the last page to pull.
    private let distance: CGFloat = 80

    init() {
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        symbol.tintColor = .secondaryLabel
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        stack.addArrangedSubview(symbol)
        stack.addArrangedSubview(label)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.alpha = 0
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    func attach(to view: UIView) {
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -130),
        ])
        reset()
    }

    func detach() {
        stack.removeFromSuperview()
        isArmed = false
    }

    func update(pulled: CGFloat, dragging: Bool) {
        guard stack.superview != nil else { return }
        // Only while pulling: the pages bounce back with nothing left over.
        stack.alpha = dragging ? min(max((pulled - 10) / 40, 0), 1) : 0
        guard dragging else { return }
        let armed = pulled > distance
        guard armed != isArmed else { return }
        isArmed = armed
        if armed { UISelectionFeedbackGenerator().selectionChanged() }
        show(armed)
    }

    func reset() {
        isArmed = false
        stack.alpha = 0
        show(false)
    }

    private func show(_ armed: Bool) {
        label.text = armed ? "Release to Add a Page" : "Pull to Add a Page"
        symbol.image = UIImage(systemName: armed ? "doc.badge.plus" : "arrow.up")
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
    override var undoManager: UndoManager? { session?.undo }
    private let noAccessory = UIView(frame: .zero)
    override var inputAccessoryView: UIView? { noAccessory }

    @objc func undo(_ sender: Any?) { session?.undo.undo() }
    @objc func redo(_ sender: Any?) { session?.undo.redo() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) { return session?.undo.canUndo ?? false }
        if action == #selector(redo(_:)) { return session?.undo.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }
}

private extension PDFView {
    /// PDFKit's own scroll view, which scrolls the pages.
    var scrollView: UIScrollView? { subviews.lazy.compactMap { $0 as? UIScrollView }.first }
}
#endif

#if os(iOS)
/// The PDF drawn on, for the toolbar's Page and Add menus: its pages, the one in view and its paper, and the session
/// that changes them.
@MainActor
@Observable
final class PDFEditing {
    @ObservationIgnored weak var session: PDFDrawingSession?
    private(set) var pageCount = 0
    private(set) var pageIndex = 0
    /// The paper of the page in view, when Notebook made it: only that can be given other paper.
    private(set) var paper: PaperStyle?
    /// Something was written, put or changed on the PDF's pages: it is no longer a new note left empty.
    @ObservationIgnored var touched: ((URL) -> Void)?

    func connect(_ session: PDFDrawingSession?) {
        self.session = session
        update()
    }

    func update() {
        guard let session else {
            pageCount = 0
            return
        }
        if session.isTouched { touched?(session.url) }
        let count = session.pageCount, index = session.currentIndex ?? 0, paper = session.currentPage.flatMap(session.paper)
        if count != pageCount { pageCount = count }
        if index != pageIndex { pageIndex = index }
        if paper != self.paper { self.paper = paper }
    }

    func addPage(_ paper: PaperStyle) { session?.addPage(paper, after: pageIndex) }
    func changePaper(to paper: PaperStyle) { session?.changePaper(of: pageIndex, to: paper) }
    func deletePage() { session?.removePage(at: pageIndex) }

    func addPictures(from source: AttachmentSource) {
        guard let session else { return }
        PagePicturePicker.shared.present(source, for: session)
    }
}
#endif
