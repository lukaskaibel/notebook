#if os(iOS)
import UIKit

/// The note's text view on iPhone and iPad: UIKit's, on the same TextKit 1 storage and layout manager as the Mac's,
/// so the note is styled, laid out and drawn by the same code. Typing, taps and the pasteboard go through the
/// `EditorController`; this class adds what has to live in the view: the title above the text, the column of text
/// in the middle, the heading level in the margin, and the keys of a hardware keyboard.
@MainActor
final class MarkdownTextView: UITextView {
    weak var controller: EditorController?

    let titleField = TitleField()
    let metaLabel = UILabel()
    /// The note's reminder, a bell and its time, before the date under the title. A tap changes or removes it.
    let reminderButton = UIButton(configuration: .plain())
    /// The level of the heading the caret is on, in the margin, as on the Mac; a tap on it changes the level. Only
    /// where the margin is wide enough for it (iPad), since the iPhone's is too narrow.
    let headingButton = UIButton(configuration: .plain())

    /// As tall as the title's font needs.
    private var titleHeight: CGFloat { ceil(titleField.font?.lineHeight ?? 40) + 2 }

    private var isCompact: Bool { bounds.width < 500 }
    private var titleTop: CGFloat { isCompact ? 10 : 28 }
    var headerHeight: CGFloat { titleTop + titleHeight + 34 }
    /// The space left and right of the text.
    var sideMargin: CGFloat {
        isCompact ? 20 : max(48, floor((bounds.width - EditorStyle.contentWidth) / 2))
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        titleField.textColor = Theme.text
        titleField.borderStyle = .none
        titleField.returnKeyType = .next
        titleField.autocapitalizationType = .sentences
        titleField.clearButtonMode = .never
        titleField.adjustsFontSizeToFitWidth = false
        titleField.accessibilityLabel = "Title"
        addSubview(titleField)
        metaLabel.font = .systemFont(ofSize: 13)
        metaLabel.textColor = Theme.textTertiary
        metaLabel.adjustsFontForContentSizeCategory = true
        addSubview(metaLabel)
        var reminder = UIButton.Configuration.plain()
        reminder.contentInsets = .zero
        reminder.imagePadding = 4
        reminder.image = UIImage(systemName: "bell.fill")
        reminder.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: .systemFont(ofSize: 11))
        reminderButton.configuration = reminder
        reminderButton.contentHorizontalAlignment = .leading
        reminderButton.isHidden = true
        reminderButton.addAction(UIAction { [weak self] _ in
            guard let controller = self?.controller else { return }
            controller.delegate?.editorShowReminder(controller)
        }, for: .primaryActionTriggered)
        addSubview(reminderButton)

        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        headingButton.configuration = configuration
        headingButton.addAction(UIAction { [weak self] _ in self?.controller?.showTextStyles() }, for: .primaryActionTriggered)
        headingButton.isHidden = true
        headingButton.accessibilityLabel = "Text Style"
        addSubview(headingButton)
        applyTypography()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The title in the note's typeface, twice the size of the text: as large as a large title at the standard size,
    /// and larger than the note's own headings.
    func applyTypography() {
        let font = EditorStyle.face((EditorStyle.bodySize * 2).rounded(), weight: .bold)
        titleField.font = font
        titleField.attributedPlaceholder = NSAttributedString(string: "Untitled", attributes: [.font: font, .foregroundColor: Theme.faint])
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        controller?.focusWhenShown()
    }

    // MARK: - Layout

    private var laidOutWidth: CGFloat = 0

    // UIKit may size the content to the text without the spacing after a last paragraph that no line break ends
    // (`NotebookLayoutManager.usedRect`), where a diagram or formula being edited shows what it makes.
    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            var size = newValue
            if let layoutManager = layoutManager as? NotebookLayoutManager {
                size.height = max(size.height, ceil(layoutManager.usedRect(for: textContainer).maxY + textContainerInset.top + textContainerInset.bottom))
            }
            super.contentSize = size
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateInsets()
    }

    /// Centres a column of text at most `EditorStyle.contentWidth` wide, with room above for the title.
    func updateInsets() {
        let side = sideMargin
        let inset = UIEdgeInsets(top: headerHeight, left: side, bottom: 48, right: side)
        if textContainerInset != inset { textContainerInset = inset }
        let width = bounds.width - side * 2
        titleField.frame = CGRect(x: side, y: titleTop, width: width, height: titleHeight)
        var metaStart = side
        if !reminderButton.isHidden {
            // Taller than the line, for a fingertip.
            let size = reminderButton.intrinsicContentSize
            reminderButton.frame = CGRect(x: side, y: titleTop + titleHeight + 2 + 9 - 15, width: size.width, height: 30)
            metaStart = reminderButton.frame.maxX + 10
        }
        metaLabel.frame = CGRect(x: metaStart, y: titleTop + titleHeight + 2, width: max(0, side + width - metaStart), height: 18)
        if laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            applyTypography()
            controller?.marginNeedsDisplay()
            // Drawings are as wide as the text: their canvases follow.
            if controller?.isDrawing == true {
                DispatchQueue.main.async { [weak self] in self?.controller?.updateDrawingCanvases() }
            }
        }
    }


    private var knownTopInset: CGFloat = 0

    /// The bell and time of the note's reminder, red once the time has passed; nil for none.
    func setReminder(_ text: String?, isOverdue: Bool) {
        reminderButton.isHidden = text == nil
        var configuration = reminderButton.configuration ?? .plain()
        var title = AttributedString(text ?? "")
        title.font = .systemFont(ofSize: 13)
        configuration.attributedTitle = title
        configuration.baseForegroundColor = isOverdue ? .systemRed : Theme.accent
        reminderButton.configuration = configuration
        reminderButton.accessibilityLabel = text.map { "Reminder, \($0)" }
        setNeedsLayout()
    }

    /// A note opened before its screen had a navigation bar starts at the top once the bar is there: the room it
    /// takes comes later than the note.
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        let top = adjustedContentInset.top
        // Set even when UIKit moved it already: the text view goes back to the last offset set from outside
        // whenever its width changes.
        if let place = controller?.pendingPlace {
            controller?.scroll(to: place)
        } else if top != knownTopInset, abs(contentOffset.y + knownTopInset) < 1 || abs(contentOffset.y + top) < 1 {
            contentOffset = CGPoint(x: contentOffset.x, y: -top)
        }
        knownTopInset = top
    }

    /// Where the text container starts, as `NSTextView.textContainerOrigin`.
    var textContainerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    /// The editor's record of changes, which undo and redo go through (see `EditorUndo+UIKit`).
    override var undoManager: UndoManager? { controller?.undoStack ?? super.undoManager }

    /// ⌘Z and ⇧⌘Z in the text take back its changes, and the changes to files with them, newest first. Without these
    /// SwiftUI's hosting controller, further up, would take them for the window's undo manager whenever that has a
    /// change to files, however much was typed since. In the title or a drawing they are theirs.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    // MARK: - Caret

    /// A caret as tall as the text it is in, not as the line, which is taller than the font.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        guard let controller, !rect.isNull, !rect.isInfinite else { return rect }
        return controller.caretRect(proposed: rect)
    }

    #if DEBUG
    /// The caret UIKit proposes, for the debug remote's `caretinfo`.
    func proposedCaretRect(for position: UITextPosition) -> CGRect { super.caretRect(for: position) }
    #endif

    /// A picture selected whole shows the ring the layout manager draws around it, not the text's selection.
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        if let controller {
            let start = offset(from: beginningOfDocument, to: range.start)
            let length = offset(from: range.start, to: range.end)
            if controller.isWholeObject(NSRange(location: start, length: length)) { return [] }
        }
        return super.selectionRects(for: range)
    }

    // MARK: - Pictures

    /// Holding a picture lifts it (`PictureInteractions`): the text's loupe, which would put the caret there and bring
    /// up the keyboard, leaves pictures alone.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // While drawing, a touch on a drawing draws: it doesn't select text or bring up the keyboard. The note still
        // scrolls over it, with a finger where only Apple Pencil draws and with two fingers where a finger draws too.
        if let controller, controller.isDrawing, recognizer.view === self, let canvas = controller.canvas(at: recognizer.location(in: self)) {
            guard recognizer === panGestureRecognizer, controller.scrollsOverDrawing(recognizer) else { return false }
            // The first of two fingers began a stroke before the second made it a scroll.
            if recognizer.numberOfTouches > 1 { canvas.cancelStroke() }
            return true
        }
        if String(describing: type(of: recognizer)).contains("Loupe"),
           controller?.pictureInteractions?.picture(at: recognizer.location(in: self)) != nil {
            return false
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    // MARK: - Focus

    /// While the title lets go of the focus (see `TitleField`).
    var refusesFocus = false

    override func becomeFirstResponder() -> Bool {
        guard !refusesFocus else { return false }
        let result = super.becomeFirstResponder()
        if result { controller?.focusChanged() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { controller?.focusChanged() }
        return result
    }

    // MARK: - Pasteboard

    override func copy(_ sender: Any?) {
        if controller?.copySelection(cut: false) != true { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        if controller?.copySelection(cut: true) != true { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        if controller?.paste(from: .general) != true { super.paste(sender) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Pictures and files can be pasted too, which a plain text view doesn't take.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs { return true }
        // Bold and italic are Markdown: a text view without rich text would leave them out (and ⌘B, ⌘I with them).
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:)) { return isEditable }
        if action == #selector(toggleUnderline(_:)) { return false }
        if action == #selector(undo(_:)) { return isFirstResponder && undoManager?.canUndo == true }
        if action == #selector(redo(_:)) { return isFirstResponder && undoManager?.canRedo == true }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Formatting, from the keyboard's shortcuts and the edit menu

    override func toggleBoldface(_ sender: Any?) { controller?.toggle(.bold) }
    override func toggleItalics(_ sender: Any?) { controller?.toggle(.italic) }
    // Markdown has no underline: ⌘U marks text as code is not what you'd expect either, so it does nothing.
    override func toggleUnderline(_ sender: Any?) {}

    // MARK: - Keys of a hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        func command(_ input: String, _ modifiers: UIKeyModifierFlags = [], _ action: Selector, priority: Bool = true) {
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = priority
            commands.append(command)
        }
        if controller?.suggestions.isVisible == true {
            command(UIKeyCommand.inputUpArrow, [], #selector(suggestionUp))
            command(UIKeyCommand.inputDownArrow, [], #selector(suggestionDown))
            command("\t", [], #selector(acceptSuggestion))
            command(UIKeyCommand.inputEscape, [], #selector(closeSuggestions))
        } else {
            // Tab arrives as text and nests list items there; Shift-Tab needs a command of its own.
            command("\t", .shift, #selector(outdentLines))
            if controller?.isCaretOnFirstLine == true { command(UIKeyCommand.inputUpArrow, [], #selector(moveUpIntoTitle)) }
            if selectedRange == NSRange(location: 0, length: 0) { command(UIKeyCommand.inputLeftArrow, [], #selector(moveBackIntoTitle)) }
        }
        // The Format menu's shortcuts, which its buttons don't get on iPad.
        if isEditable, isFirstResponder {
            commands += FormatShortcut.all.enumerated().map { index, shortcut in shortcut.keyCommand(action: #selector(formatShortcut(_:)), index: index) }
        }
        return commands
    }

    @objc private func formatShortcut(_ sender: UIKeyCommand) {
        guard let index = sender.propertyList as? Int, let shortcut = FormatShortcut.all[safe: index] else { return }
        controller?.perform(shortcut)
    }

    @objc private func suggestionUp() { controller?.suggestions.move(by: -1) }
    @objc private func suggestionDown() { controller?.suggestions.move(by: 1) }
    @objc private func acceptSuggestion() { controller?.acceptSelectedSuggestion() }
    @objc private func closeSuggestions() { controller?.closeSuggestions() }
    @objc private func outdentLines() { controller?.indent(by: -1) }
    /// ↑ on the first line goes into the title.
    @objc private func moveUpIntoTitle() { _ = controller?.moveUpIntoTitle() }
    /// ← at the start of the note goes into the title.
    @objc private func moveBackIntoTitle() { _ = controller?.moveBackIntoTitle() }

    /// Delete at the very start of the note goes back into the title, as into the line above.
    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0), controller?.deleteBackIntoTitle() == true { return }
        super.deleteBackward()
        controller?.lastDeleteBackward = CACurrentMediaTime()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Keys pressed: a keyboard is attached, whatever the game controller framework says.
        if presses.contains(where: { $0.key != nil }) { HardwareKeyboard.shared.keyWasPressed() }
        // Return picks a suggestion on a hardware keyboard too; the software keyboard's Return arrives as text.
        if controller?.suggestions.isVisible == true, presses.contains(where: { $0.key?.keyCode == .keyboardReturnOrEnter && $0.key?.modifierFlags.isEmpty == true }) {
            controller?.acceptSelectedSuggestion()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

/// The title above the note: the file's name, renamed when you change it.
final class TitleField: UITextField {
    /// The title's own, so that undo while you rename a note undoes the renaming, not a change in the text below.
    private let titleUndo = UndoManager()
    override var undoManager: UndoManager? { titleUndo }

    /// ⌘Z and ⇧⌘Z take back the typing in the title before what SwiftUI would take back for the window.
    @objc func undo(_ sender: Any?) { titleUndo.undo() }
    @objc func redo(_ sender: Any?) { titleUndo.redo() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) { return titleUndo.canUndo }
        if action == #selector(redo(_:)) { return titleUndo.canRedo }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Tab, ↓ and → at the end go on into the text, as Return does, on a keyboard as on the Mac.
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        var inputs = ["\t", UIKeyCommand.inputDownArrow]
        if selectedTextRange.map({ $0.isEmpty && compare($0.end, to: endOfDocument) == .orderedSame }) ?? false {
            inputs.append(UIKeyCommand.inputRightArrow)
        }
        for input in inputs {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(goOnToText))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func goOnToText() {
        (superview as? MarkdownTextView)?.controller?.leaveTitle()
    }

    /// UIKit gives the focus a text field lets go of to the text view it is in, which would bring the keyboard
    /// back for the text when you leave the title or the note.
    override func resignFirstResponder() -> Bool {
        let textView = superview as? MarkdownTextView
        textView?.refusesFocus = true
        defer { textView?.refusesFocus = false }
        return super.resignFirstResponder()
    }
}
#endif
