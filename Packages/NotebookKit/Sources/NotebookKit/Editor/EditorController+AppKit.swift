#if os(macOS)
import AppKit

/// The editor in an AppKit text view in a scroll view: what the Mac's text system does differently from iOS's.
extension EditorController: NSTextViewDelegate, NSTextFieldDelegate {
    func configureTextView() {
        let view = textView
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        applySpelling()
        NotificationCenter.default.addObserver(self, selector: #selector(applySpelling), name: .notebookSpellingChanged, object: nil)
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.insertionPointColor = Theme.accent
        // The system's selection colour, without changing the colour of the text.
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        view.linkTextAttributes = [:]
        view.typingAttributes = MarkdownStyler.baseAttributes
        view.defaultParagraphStyle = EditorStyle.paragraph()
        view.textContainerInset = NSSize(width: 60, height: MarkdownTextView.headerHeight)
        view.setAccessibilityLabel("Note")
        view.delegate = self
        view.titleField.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        // Room for the toolbar, which the note scrolls under.
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    public var view: NSView { scrollView }

    /// Spelling as Edit › Spelling and Grammar sets it, the same in every note.
    @objc func applySpelling() {
        let settings = NotebookSettings.shared
        textView.isContinuousSpellCheckingEnabled = settings.checksSpelling
        textView.isGrammarCheckingEnabled = settings.checksGrammar
        textView.isAutomaticSpellingCorrectionEnabled = settings.correctsSpelling
    }

    // MARK: - What the shared editor asks of the text view

    var selection: NSRange { textView.selectedRange() }
    func setSelection(_ range: NSRange) { textView.setSelectedRange(range) }
    var selectedRanges: [NSRange] { textView.selectedRanges.map(\.rangeValue) }
    var isFocused: Bool { textView.window?.firstResponder === textView }
    /// The mouse button is down: nothing is revealed or hidden until it comes up.
    var isTracking: Bool { textView.isTrackingMouse }
    var isInWindow: Bool { textView.window != nil }
    var textOrigin: NSPoint { textView.textContainerOrigin }

    /// The top of the visible part of the text view, which is under the toolbar.
    var scrollTop: CGFloat { scrollView.contentView.bounds.minY }
    /// The room the toolbar takes at the top.
    var topInset: CGFloat { scrollView.contentInsets.top }
    var visibleRect: NSRect { scrollView.contentView.bounds }
    var maxScrollTop: CGFloat { max(-topInset, textView.frame.height - scrollView.contentView.bounds.height) }

    func setScrollTop(_ y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func animateScrollTop(to y: CGFloat, completion: @escaping @MainActor () -> Void) {
        let clip = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.scrollView.reflectScrolledClipView(clip)
                completion()
            }
        }
    }

    var titleText: String {
        get { textView.titleField.stringValue }
        set { textView.titleField.stringValue = newValue }
    }

    var isEditingTitle: Bool { textView.window?.firstResponder === textView.titleField.currentEditor() }
    var titleFrame: NSRect { textView.titleField.frame }

    var metaText: String {
        get { textView.metaLabel.stringValue }
        set { textView.metaLabel.stringValue = newValue }
    }

    /// Nothing can be selected or typed while the note's text is on its way, in the note or its title.
    func updateEditability() {
        let editable = !isWaitingForText
        textView.isEditable = editable && !isReadOnly
        textView.isSelectable = editable
        textView.titleField.isEditable = editable && !isReadOnly
        textView.titleField.isSelectable = editable
    }

    /// The next change to the note fades in, as a file read in the background does (`FileLoadingView`): above all the
    /// text arriving under its title, which stays as it is.
    func fadeInNextChange() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollView.layer?.add(fade, forKey: "textArrived")
    }

    func makeTextFirstResponder() { textView.window?.makeFirstResponder(textView) }
    func makeTitleFirstResponder() { textView.window?.makeFirstResponder(textView.titleField) }

    func putTitleCaretAtEnd() {
        guard let editor = textView.titleField.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    var isDarkAppearance: Bool {
        textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func textNeedsDisplay() { textView.needsDisplay = true }
    func marginNeedsDisplay() { textView.needsDisplay = true }

    /// Changes the text the way typing does, so it can be undone.
    func performEdit(_ range: NSRange, with string: String) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
        storage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        return true
    }

    @objc func scrolled() {
        updatePosition()
        updateCopyButtonForPointer()
        updateTodoBellForPointer()
    }

    // MARK: - NSTextViewDelegate

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }

    public func textDidChange(_ notification: Notification) {
        textUndoManager = textView.undoManager
        textChanged()
    }

    /// Another note: Undo forgets the changes to the text. They are in the window's undo with the changes to files,
    /// in the order they were made (`Workspace+Undo`), which stay. The text's are also taken from the window it was
    /// last changed in, should the text view be out of that window now.
    func forgetTextUndo() {
        for manager in [textView.undoManager, textUndoManager].compactMap({ $0 }) {
            manager.removeAllActions(withTarget: storage)
            manager.removeAllActions(withTarget: textView)
        }
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue], toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        guard !isLoading, !selectsExactly, newSelectedCharRanges.count == 1, let old = oldSelectedCharRanges.first?.rangeValue else { return newSelectedCharRanges }
        let range = newSelectedCharRanges[0].rangeValue
        if range.length == 0 {
            return [NSValue(range: NSRange(location: snapCaret(range.location, from: old), length: 0))]
        }
        return [NSValue(range: expandSelection(range))]
    }

    /// No spelling marks in code, math, links, addresses or hidden Markdown: they aren't prose.
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0, affectedCharRange.upperBound <= storage.length, !document.lines.isEmpty else { return value }
        for index in affectedCharRange.location..<affectedCharRange.upperBound {
            if layoutManager.isHidden(index) || layoutManager.object(at: index) != nil { return 0 }
            if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont, font.isFixedPitch { return 0 }
        }
        let line = document.lines[document.lineIndex(containing: affectedCharRange.location)]
        for span in line.spans where NSIntersectionRange(span.range, affectedCharRange).length > 0 {
            switch span.kind {
            case .code, .math, .link, .autolink, .wikiLink, .embed, .image: return 0
            default: break
            }
        }
        if case .code = line.kind { return 0 }
        return value
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isLoading, let replacement = replacementString else { return true }
        return shouldInsert(replacement, in: affectedCharRange)
    }

    /// Return, Tab, Backspace and the arrow keys, as the text view sends them.
    func handleCommand(_ selector: Selector) -> Bool {
        if suggestions.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                suggestions.move(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                suggestions.move(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let suggestion = suggestions.selected { acceptSuggestion(suggestion) } else { closeSuggestions() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                closeSuggestions()
                return true
            default:
                break
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return insertNewline()
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insert("\n")
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            defer { lastDeleteBackward = CACurrentMediaTime() }
            return deleteBackward()
        case #selector(NSResponder.deleteForward(_:)):
            return deleteForward()
        case #selector(NSResponder.insertTab(_:)):
            return indent(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            return indent(by: -1)
        case #selector(NSResponder.moveUp(_:)):
            return moveUpIntoTitle()
        case #selector(NSResponder.moveLeft(_:)):
            return moveBackIntoTitle()
        default:
            return false
        }
    }

    // MARK: - Title

    public func control(_ control: NSControl, textView fieldEditor: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === textView.titleField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            leaveTitle()
            return true
        case #selector(NSResponder.moveRight(_:)):
            // → at the end of the title goes on into the text, as at the end of a line.
            guard fieldEditor.selectedRange() == NSRange(location: (fieldEditor.string as NSString).length, length: 0) else { return false }
            leaveTitle()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return false
        default:
            return false
        }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        // Loading another note isn't leaving the title: the name was taken as the note was left.
        guard (notification.object as? NSTextField) === textView.titleField, !isLoading else { return }
        commitTitle()
    }
}
#endif
