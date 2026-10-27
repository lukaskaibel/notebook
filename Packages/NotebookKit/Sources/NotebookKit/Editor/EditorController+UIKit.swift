#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// The editor in a UIKit text view: taps instead of clicks, the keyboard's Return and Backspace as text, the keyboard
/// over the note, and a menu instead of a popover.
extension EditorController: UITextViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate, UITextDragDelegate, UITextDropDelegate {
    func configureTextView() {
        let view = textView
        view.isEditable = true
        view.isSelectable = true
        view.allowsEditingTextAttributes = false
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.dataDetectorTypes = []
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .always
        view.isFindInteractionEnabled = true
        view.tintColor = Theme.accent
        view.typingAttributes = MarkdownStyler.baseAttributes
        view.linkTextAttributes = [:]
        view.accessibilityLabel = "Note"
        view.delegate = self
        view.titleField.delegate = self
        view.titleField.addTarget(self, action: #selector(titleReturn), for: .editingDidEndOnExit)
        let bar = WritingBar(editor: self)
        writingBar = bar
        view.inputAccessoryView = bar
        // The title is plain text: none of the writing bar's formatting goes there. Without a bar of its own, it
        // would show the text view's, which it is inside of.
        view.titleField.inputAccessoryView = UIView(frame: .zero)

        view.textDragDelegate = self
        view.textDropDelegate = self
        let pictures = PictureInteractions(editor: self)
        pictures.install(on: view)
        pictureInteractions = pictures

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardAttachmentChanged), name: HardwareKeyboard.didChange, object: nil)
    }

    /// The note's view: the text view, which scrolls itself.
    public var view: UIView { textView }

    // MARK: - What the shared editor asks of the text view

    var selection: NSRange { textView.selectedRange }

    func setSelection(_ range: NSRange) {
        isSettingSelection = true
        textView.selectedRange = range
        isSettingSelection = false
    }

    var selectedRanges: [NSRange] { [textView.selectedRange] }
    var isFocused: Bool { textView.isFirstResponder }

    /// A finger is placing the caret or dragging a selection's handles: nothing is revealed or hidden until it
    /// lifts, so the text never moves under it. Scrolling doesn't count.
    var isTracking: Bool {
        func active(_ view: UIView) -> Bool {
            (view.gestureRecognizers ?? []).contains { recognizer in
                recognizer !== textView.panGestureRecognizer && recognizer !== textView.pinchGestureRecognizer
                    && (recognizer.state == .began || recognizer.state == .changed)
            }
        }
        return active(textView) || textView.subviews.contains(where: active)
    }

    var isInWindow: Bool { textView.window != nil }
    var textOrigin: CGPoint { textView.textContainerOrigin }

    /// The top of the visible part of the text view, which is under the navigation bar.
    var scrollTop: CGFloat { textView.contentOffset.y }
    /// The room the navigation bar takes at the top.
    var topInset: CGFloat { textView.adjustedContentInset.top }
    var visibleRect: CGRect { textView.bounds }
    /// From the layout rather than the content size, which UIKit updates only when it next lays the view out:
    /// right after a note is loaded it is still the last note's.
    var maxScrollTop: CGFloat {
        let height = layoutManager.usedRect(for: container).maxY + textView.textContainerInset.top + textView.textContainerInset.bottom
        return max(-topInset, height + textView.adjustedContentInset.bottom - textView.bounds.height)
    }

    func setScrollTop(_ y: CGFloat) {
        textView.contentOffset = CGPoint(x: -textView.adjustedContentInset.left, y: y)
    }

    func animateScrollTop(to y: CGFloat, completion: @escaping @MainActor () -> Void) {
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.setScrollTop(y)
        } completion: { _ in
            completion()
        }
    }

    var titleText: String {
        get { textView.titleField.text ?? "" }
        set { textView.titleField.text = newValue }
    }

    var isEditingTitle: Bool { textView.titleField.isFirstResponder }
    var titleFrame: CGRect { textView.titleField.frame }

    var metaText: String {
        get { textView.metaLabel.text ?? "" }
        set { textView.metaLabel.text = newValue }
    }

    /// The keyboard comes up for the text, or for the title, once the note is on screen if it isn't yet: a new
    /// note is made before its screen slides in.
    /// Nothing can be typed while the note's text is on its way, in the note or its title.
    func updateEditability() {
        textView.isEditable = !isWaitingForText && !isReadOnly
        textView.titleField.isEnabled = !isWaitingForText && !isReadOnly
    }

    /// The next change to the note fades in, as a file read in the background does (`FileLoadingView`): above all the
    /// text arriving under its title, which stays as it is.
    func fadeInNextChange() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        textView.layer.add(fade, forKey: "textArrived")
    }

    func makeTextFirstResponder() {
        requestedFocus = (.text, Date())
        pendingFocus = nil
        if textView.window == nil { pendingFocus = .text } else { _ = textView.becomeFirstResponder() }
    }

    func makeTitleFirstResponder() {
        requestedFocus = (.title, Date())
        pendingFocus = nil
        if textView.window == nil { pendingFocus = .title } else { _ = textView.titleField.becomeFirstResponder() }
    }

    func putTitleCaretAtEnd() {
        let field = textView.titleField
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
    }

    /// The editor is about to move to another screen: leaving the window takes the keyboard away, and with it
    /// comes back on the new screen.
    func beginMove() {
        isMoving = true
        // What was asked for a moment ago counts over what has the focus now: as the old screen slides away, UIKit
        // hands the title's focus to the text view it is in.
        if let (focus, date) = requestedFocus, Date().timeIntervalSince(date) < 1.5 {
            pendingFocus = focus
        } else if textView.titleField.isFirstResponder {
            pendingFocus = .title
        } else if textView.isFirstResponder {
            pendingFocus = .text
        }
    }

    func endMove() {
        isMoving = false
        focusWhenShown()
    }

    /// No screen took the editor (you went back to a folder): the keyboard stays away.
    func finishMoveIfNowhere() {
        guard isMoving, textView.window == nil else { return }
        isMoving = false
        pendingFocus = nil
        delegate?.editorEditingDidChange(self)
    }

    func focusWhenShown() {
        guard let focus = pendingFocus, textView.window != nil else { return }
        pendingFocus = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = focus == .title ? self.textView.titleField.becomeFirstResponder() : self.textView.becomeFirstResponder()
        }
    }

    var isDarkAppearance: Bool { textView.traitCollection.userInterfaceStyle == .dark }

    /// Selected pictures and tables draw a ring of their own, in the text.
    func textNeedsDisplay() {
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.bounds.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y), in: container)
        layoutManager.invalidateDisplay(forGlyphRange: glyphs)
    }

    /// The heading level in the margin: shown next to the heading the caret is on, where there is room for it.
    func marginNeedsDisplay() {
        let button = textView.headingButton
        guard textView.sideMargin >= 44, let (level, marker) = headingMarkLevel,
              let rect = layoutManager.headingMarkRect(at: marker.location, origin: textOrigin) else {
            button.isHidden = true
            return
        }
        button.frame = rect.insetBy(dx: -6, dy: -8)
        var configuration = button.configuration ?? .plain()
        configuration.attributedTitle = AttributedString("H\(level)", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: Theme.textTertiary]))
        configuration.background.backgroundColor = Theme.control
        configuration.background.cornerRadius = 5
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.isHidden = false
    }

    /// Changes the text as one step to undo (see `EditorUndo+UIKit`).
    func performEdit(_ range: NSRange, with string: String) -> Bool {
        guard range.upperBound <= storage.length, !isWaitingForText else { return false }
        storage.replaceCharacters(in: range, with: string)
        setSelection(NSRange(location: range.location + (string as NSString).length, length: 0))
        textChanged()
        return true
    }

    // MARK: - UITextViewDelegate

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isLoading else { return }
        let range = textView.selectedRange
        defer { previousSelection = textView.selectedRange }
        closeTypingStep(at: range)
        // The caret steps over bullets and pictures, and a selection takes Markdown whole, as on the Mac. Not while
        // a finger drags the selection's handles, which would make them jump.
        if !isSettingSelection, textView.markedTextRange == nil {
            let fixed = range.length == 0 ? NSRange(location: snapCaret(range.location, from: previousSelection), length: 0) : isTracking ? range : expandSelection(range)
            if fixed != range {
                setSelection(fixed)
                return
            }
        }
        selectionChanged()
        formatState.update(from: self)
        if isTracking { waitForTrackingToEnd() }
    }

    /// Shows what is next to the caret once the finger lifts.
    private func waitForTrackingToEnd() {
        guard !isWaitingForTracking else { return }
        isWaitingForTracking = true
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if self.isTracking { return check() }
                self.isWaitingForTracking = false
                let range = self.selection
                if range.length > 0 {
                    let expanded = self.expandSelection(range)
                    if expanded != range { self.setSelection(expanded) }
                }
                self.mouseTrackingEnded()
            }
        }
        check()
    }

    public func textViewDidChange(_ textView: UITextView) {
        textChanged()
        formatState.update(from: self)
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isLoading, !isPerformingEdit, textView.markedTextRange == nil else { return true }
        let selection = self.selection
        // Return picks the suggestion under `[[`.
        if suggestions.isVisible, text == "\n" {
            acceptSelectedSuggestion()
            return false
        }
        if text == "\n", range == selection {
            return !insertNewline()
        }
        if text.isEmpty, selection.length == 0, range.length > 0, range.upperBound == selection.location {
            return !deleteBackward()
        }
        if text == "\t", range == selection {
            return !indent(by: 1)
        }
        return shouldInsert(text, in: range)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        // A tap in the text while drawing stops drawing and puts the caret there.
        if isDrawing { endDrawing() }
        // Before the keyboard comes up, for the bar to come up with it as it should be.
        updateCaretContext()
        delegate?.editorEditingDidChange(self)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        guard !isMoving else { return }
        // Next time, the keyboard comes up again rather than the Format panel.
        if isShowingFormatPanel {
            textView.inputView = nil
            textView.inputAccessoryView = writingBar
        }
        delegate?.editorEditingDidChange(self)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePosition()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingPlace = nil
    }

    /// Copy Code first in the menu of a selection in a code block.
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.location < storage.length, let block = document.line(containing: range.location)?.block,
              case .code = document.blocks[block].kind else { return nil }
        let start = document.blocks[block].range.location
        let copyCode = UIAction(title: "Copy Code", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyCode(at: start) }
        return UIMenu(children: [copyCode] + suggestedActions)
    }

    // MARK: - Title

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        closeSuggestions()
        delegate?.editorEditingDidChange(self)
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        // Moving to another screen isn't leaving the title: it stays as it is being typed. Nor is loading another
        // note, whose title it now is.
        guard !isMoving, !isLoading else { return }
        commitTitle()
        delegate?.editorEditingDidChange(self)
    }

    /// Return in the title goes on to the text.
    @objc private func titleReturn() {
        focusText()
    }

    /// A keyboard was attached or taken away: marks show next to the caret with one, and not without.
    @objc func keyboardAttachmentChanged() {
        updateReveal()
    }

    // MARK: - Taps

    /// Taps on checkboxes, links and pictures are the editor's; everywhere else the text view places the caret.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // A touch on a drawing while drawing is the canvas's.
        if isDrawing, gestureRecognizer.view === textView, canvas(at: gestureRecognizer.location(in: textView)) != nil { return false }
        guard gestureRecognizer.view === textView, !(gestureRecognizer is UIPanGestureRecognizer) else { return true }
        guard let (hit, _) = touchHit(at: gestureRecognizer.location(in: textView)) else { return false }
        if case .headingLevel = hit { return false }
        return true
    }

    /// What a finger hits: the thing under it, or a checkbox right next to it, which is smaller than a fingertip.
    func touchHit(at point: CGPoint) -> (Hit, CGPoint)? {
        if let hit = hitTest(point) { return (hit, point) }
        for offset in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: 0, y: 8), CGPoint(x: 0, y: -8), CGPoint(x: 18, y: 0)] {
            let nearby = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            if let hit = hitTest(nearby), case .checkbox = hit { return (hit, nearby) }
        }
        return nil
    }

    /// The text view's own taps wait for this one, so a tap on a checkbox neither moves the caret nor brings up the
    /// keyboard.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer.view?.isDescendant(of: textView) == true
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let (hit, point) = touchHit(at: recognizer.location(in: textView)) else { return }
        handleTap(hit, at: point)
    }

    func handleTap(_ hit: Hit, at point: CGPoint) {
        switch hit {
        case .checkbox(let line):
            // A double tap ticks once: its second tap is where the first was on the screen, though the note may have
            // moved under it (a to-do that repeats keeps the ticked line under the finger).
            let onScreen = textView.convert(point, to: nil)
            if let last = lastCheckboxTap, Date.now.timeIntervalSince(last.time) < 0.4, hypot(onScreen.x - last.point.x, onScreen.y - last.point.y) < 24 { return }
            lastCheckboxTap = (.now, onScreen)
            UISelectionFeedbackGenerator().selectionChanged()
            toggleCheckbox(line: line)
        case .link(let kind):
            closeSuggestions()
            delegate?.editor(self, open: kind)
        case .picture(let range, let url):
            // A tap opens a drawing for drawing, as in Notes, and any other picture in Quick Look.
            if let drawing = drawing(at: range) {
                beginDrawing(in: drawing)
            } else if let url {
                delegate?.editor(self, quickLook: url)
            } else {
                makeTextFirstResponder()
                setSelection(range)
            }
        case .editLink(let range):
            editLink(at: range)
        case .block(_, let caret):
            openBlock(caret: caret, at: point)
        case .headingLevel:
            break
        case .todo(let line, let part):
            showTodoReminder(line: line, part: part)
        }
    }

    // MARK: - The keyboard

    /// The note scrolls on under the keyboard: what it covers is room to scroll the caret above it.
    @objc private func keyboardWillChange(_ notification: Notification) {
        // While drawing, the room at the bottom is the tool picker's.
        guard !isDrawing else { return updateDrawingInset() }
        guard let window = textView.window,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = window.convert(end, from: window.screen.coordinateSpace)
        let frame = textView.convert(textView.bounds, to: window)
        let hiding = notification.name == UIResponder.keyboardWillHideNotification
        // Taller than the bar above it: the touch keyboard, not just the bar a keyboard with keys leaves.
        let bar = textView.inputAccessoryView?.bounds.height ?? 0
        let isOnScreen = !hiding && keyboard.intersects(window.bounds)
        HardwareKeyboard.shared.isTouchKeyboardShown = isOnScreen && keyboard.height - bar > 120
        // The bar and the keyboard's shortcuts came up without the touch keyboard, which only a keyboard with keys does.
        if isOnScreen, !HardwareKeyboard.shared.isTouchKeyboardShown { HardwareKeyboard.shared.shortcutsCameAlone() }
        let overlap = hiding ? 0 : max(0, frame.maxY - keyboard.minY - textView.safeAreaInsets.bottom)
        guard textView.contentInset.bottom != overlap else { return }
        textView.contentInset.bottom = overlap
        textView.verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0, isFocused {
            DispatchQueue.main.async { [weak self] in self?.scrollCaretIntoView() }
        }
    }

    /// Keeps the line with the caret above the keyboard.
    func scrollCaretIntoView() {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: range.end)
        let bottom = textView.contentOffset.y + textView.bounds.height - textView.adjustedContentInset.bottom - 12
        if caret.maxY > bottom { setScrollTop(min(maxScrollTop, textView.contentOffset.y + caret.maxY - bottom)) }
    }

    // MARK: - Links

    /// The address of a link, which isn't part of the text you see: changed in an alert, as on iOS links are.
    func editLink(at range: NSRange, isNew: Bool = false) {
        guard let link = linkSpan(at: range.location), let presenter = textView.window?.rootViewController?.topmostPresented else { return }
        let address = nsText.substring(with: destinationRange(of: link))
        let alert = UIAlertController(title: isNew ? "Add Link" : "Edit Link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = address.removingPercentEncoding ?? address
            field.placeholder = "https://"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        let location = range.location
        let entered = { [weak alert] in alert?.textFields?.first?.text ?? "" }
        if !isNew {
            alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
                self?.finishEditingLink(at: location, outcome: .open(entered()), isNew: isNew)
            })
            alert.addAction(UIAlertAction(title: "Remove Link", style: .destructive) { [weak self] _ in
                self?.finishEditingLink(at: location, outcome: .remove, isNew: isNew)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finishEditingLink(at: location, outcome: .save(isNew ? "" : address), isNew: isNew)
        })
        let done = UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.finishEditingLink(at: location, outcome: .save(entered()), isNew: isNew)
        }
        alert.addAction(done)
        alert.preferredAction = done
        presenter.present(alert, animated: true)
    }

    // MARK: - Link suggestions

    func showSuggestions(_ items: [LinkSuggestion], query: String, anchor: Int) {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: anchor - 2) else { return closeSuggestions() }
        let caret = textView.caretRect(for: start)
        let visible = CGRect(x: 0, y: textView.contentOffset.y + textView.adjustedContentInset.top, width: textView.bounds.width,
                             height: textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom)
        suggestions.show(items, query: query, below: caret, within: visible, in: textView)
    }

    // MARK: - Pasteboard

    /// Copies the selection as Markdown (and, for a single picture, as that file). Returns false when there is
    /// nothing selected.
    @discardableResult
    func copySelection(cut: Bool) -> Bool {
        guard let clipping = clipping(cut: cut) else { return false }
        var item: [String: Any] = [UTType.utf8PlainText.identifier: clipping.markdown]
        if let data = clipping.fragment { item[Self.fragmentIdentifier] = data }
        if let url = clipping.file {
            item[UTType.fileURL.identifier] = url
            if MarkdownStyler.isImageFile(url), let image = UIImage(contentsOfFile: url.path) { item[UTType.image.identifier] = image }
        }
        UIPasteboard.general.setItems([item])
        if cut { replace(clipping.range, with: "", select: NSRange(location: clipping.range.location, length: 0), actionName: "Cut") }
        return true
    }

    /// Pastes over the selection. Returns false to leave it to UIKit.
    @discardableResult
    func paste(from pasteboard: UIPasteboard) -> Bool {
        let target = selection
        // Where the note's folder has to be given first, what was read off the pasteboard goes in once it is: reading
        // it again then would ask to paste.
        if let data = pasteboard.data(forPasteboardType: Self.fragmentIdentifier) {
            guard !copiesAssets(data) || mayStoreAssets(orRetry: { [weak self] in
                guard let self else { return }
                _ = self.pasteFragment(data, at: self.selection)
            }) else { return true }
            if pasteFragment(data, at: target) { return true }
        }
        if let urls = pasteboard.urls?.filter(\.isFileURL), !urls.isEmpty {
            guard mayStore(urls, orRetry: { [weak self] in self?.insertFiles(urls) }) else { return true }
            if pasteFiles(urls, at: target) { return true }
        }
        if pasteboard.hasImages, !pasteboard.hasStrings, let image = pasteboard.image {
            guard mayStoreAssets(orRetry: { [weak self] in self?.insertPictures([image]) }) else { return true }
            if let stored = storeAsset(image: image) {
                insertOnOwnLines("![](\(stored))", at: target)
                return true
            }
        }
        if let string = pasteboard.string {
            pasteText(string, at: target)
            return true
        }
        return false
    }

    // MARK: - Dragging

    /// What is dragged out of the note: its Markdown, where it was, and in which note.
    final class Drag {
        let range: NSRange
        let markdown: String
        let note: Int
        let isObject: Bool
        init(range: NSRange, markdown: String, note: Int, isObject: Bool) {
            self.range = range
            self.markdown = markdown
            self.note = note
            self.isObject = isObject
        }
    }

    /// What a drag out of the note carries: the Markdown, never the text view's attributed text, which can't travel
    /// and would drop as nothing. A picture or file selected whole goes as the file, for other apps, and its Markdown.
    func dragItem(for range: NSRange) -> UIDragItem? {
        guard range.length > 0, range.upperBound <= storage.length else { return nil }
        let markdown = nsText.substring(with: range)
        let isObject = isWholeObject(range)
        var provider = NSItemProvider()
        if isObject, let url = pictureInteractions?.picture(at: range)?.url, let file = NSItemProvider(contentsOf: url) {
            file.suggestedName = url.deletingPathExtension().lastPathComponent
            provider = file
        }
        provider.registerObject(markdown as NSString, visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = Drag(range: range, markdown: markdown, note: loadCount, isObject: isObject)
        return item
    }

    /// Selected text, dragged by the text view's own drag.
    public func textDraggableView(_ textDraggableView: UIView & UITextDraggable, itemsForDrag dragRequest: UITextDragRequest) -> [UIDragItem] {
        let start = textView.offset(from: textView.beginningOfDocument, to: dragRequest.dragRange.start)
        let end = textView.offset(from: textView.beginningOfDocument, to: dragRequest.dragRange.end)
        return dragItem(for: NSRange(location: start, length: end - start)).map { [$0] } ?? []
    }

    /// Text or a picture of this note, dragged within it.
    func noteDrag(in drop: UITextDropRequest) -> Drag? {
        guard let drag = drop.dropSession.localDragSession?.items.first?.localObject as? Drag,
              drag.note == loadCount, drag.range.upperBound <= storage.length,
              nsText.substring(with: drag.range) == drag.markdown else { return nil }
        return drag
    }

    // MARK: - Dropping pictures and files

    /// Pictures and files dragged in from Photos or Files go next to the note, as pasted ones do; text dragged
    /// within the note is the text view's.
    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        if noteDrag(in: drop) != nil {
            // Moved by the editor itself, in one change: see `willPerformDrop`.
            let proposal = UITextDropProposal(operation: .move)
            proposal.dropPerformer = .delegate
            proposal.dropAction = .insert
            return proposal
        }
        guard isFileDrop(drop) else { return drop.suggestedProposal }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropPerformer = .delegate
        proposal.dropAction = .insert
        return proposal
    }

    private func isFileDrop(_ drop: UITextDropRequest) -> Bool {
        guard noteDrag(in: drop) == nil else { return false }
        let providers = drop.dropSession.items.map(\.itemProvider)
        return !drop.isSameView && !providers.isEmpty && providers.allSatisfy { provider in
            provider.canLoadObject(ofClass: UIImage.self) || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || (!provider.canLoadObject(ofClass: String.self) && provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        }
    }

    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        if let drag = noteDrag(in: drop) {
            let location = textView.offset(from: textView.beginningOfDocument, to: drop.dropPosition)
            return drag.isObject ? moveObject(drag.range, to: location) : moveText(drag.range, to: location)
        }
        guard isFileDrop(drop) else { return }
        let location = textView.offset(from: textView.beginningOfDocument, to: drop.dropPosition)
        let providers = drop.dropSession.items.map(\.itemProvider)
        let note = loadCount
        Task { @MainActor in
            // Everything is read first; then the note's folder is asked for once, where it has to be given.
            var dropped: [Dropped] = []
            for provider in providers {
                if let item = await self.load(provider) { dropped.append(item) }
            }
            defer { dropped.forEach { $0.throwAway() } }
            // Large files take a while: by then another note may be open, which they aren't for.
            guard !dropped.isEmpty, await self.mayStoreAssets(), self.loadCount == note else { return }
            let markdown = dropped.compactMap(self.store)
            guard !markdown.isEmpty else { return }
            self.insertOnOwnLines(markdown.joined(separator: "\n"), at: NSRange(location: min(location, self.storage.length), length: 0))
        }
    }

    /// A dropped item, read: a picture, or a copy of a file, in a folder of its own among the temporary files.
    private enum Dropped {
        case picture(UIImage)
        case file(URL)

        func throwAway() {
            if case .file(let url) = self { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    /// Reads a dropped item, before anything of it is stored.
    private func load(_ provider: NSItemProvider) async -> Dropped? {
        if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), provider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage? = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
            }
            return image.map(Dropped.picture)
        }
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        // The file is there only while this runs: it is copied right away.
        let suggestedName = provider.suggestedName
        let copied: String? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                let file = copy.appendingPathComponent(suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: file)) != nil ? file.path : nil)
            }
        }
        return copied.map { .file(URL(fileURLWithPath: $0)) }
    }

    /// A dropped item in `.assets`, as Markdown: a picture, or any other file as its card.
    private func store(_ dropped: Dropped) -> String? {
        switch dropped {
        case .picture(let image):
            return storeAsset(image: image).map { "![](\($0))" }
        case .file(let url):
            guard let stored = storeAsset(copying: url) else { return nil }
            return MarkdownStyler.isImageFile(url) ? "![](\(stored))" : "![\(url.lastPathComponent)](\(stored))"
        }
    }

    /// Pictures from the camera, the photo library or the document scanner, saved next to the note and put in at
    /// the caret, each on a line of its own.
    public func insertPictures(_ images: [UIImage]) {
        guard mayStoreAssets(orRetry: { [weak self] in self?.insertPictures(images) }) else { return }
        let stored = images.compactMap { storeAsset(image: $0) }
        guard !stored.isEmpty else { return }
        insertOnOwnLines(stored.map { "![](\($0))" }.joined(separator: "\n"), at: selection)
    }

    /// Files picked in the Files app: copied next to the note, or linked when they are notes.
    public func insertFiles(_ urls: [URL]) {
        guard mayStore(urls, orRetry: { [weak self] in self?.insertFiles(urls) }) else { return }
        _ = pasteFiles(urls, at: selection)
    }

    // MARK: - The note's folder

    /// Whether pictures and drawings may go into `.assets`, asking for the note's folder first where Notebook has to
    /// be given it: a note opened from another app.
    func mayStoreAssets() async -> Bool {
        guard let folder, let delegate, !delegate.editor(self, mayWriteIn: folder) else { return true }
        return await delegate.editor(self, askToWriteIn: folder)
    }

    /// True when pictures and drawings may go into `.assets` now. Otherwise asks for the note's folder and does `retry`
    /// once it is given, if the note is still open.
    func mayStoreAssets(orRetry retry: @escaping () -> Void) -> Bool {
        guard let folder, let delegate, !delegate.editor(self, mayWriteIn: folder) else { return true }
        let note = loadCount
        Task {
            if await delegate.editor(self, askToWriteIn: folder), loadCount == note { retry() }
        }
        return false
    }

    /// The same for files to put in: notes become links, which need no folder; anything else is copied into `.assets`.
    private func mayStore(_ files: [URL], orRetry retry: @escaping () -> Void) -> Bool {
        files.allSatisfy { $0.pathExtension.lowercased() == "md" } || mayStoreAssets(orRetry: retry)
    }

    /// Whether pasting text copied in Notebook copies pictures and files into `.assets`: those of a note elsewhere.
    private func copiesAssets(_ fragment: Data) -> Bool {
        guard let fields = try? JSONSerialization.jsonObject(with: fragment) as? [String: String], let markdown = fields["markdown"],
              let source = fields["folder"], !source.isEmpty, let folder,
              URL(fileURLWithPath: source).standardizedFileURL != folder.standardizedFileURL else { return false }
        return markdown.contains("](.assets/")
    }
}

extension UIViewController {
    /// The view controller on top, which can present another.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif
