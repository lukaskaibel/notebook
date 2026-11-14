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
    /// The handle of the row the caret is in, in a table typed in as a grid: half of it is in the margin, which the text
    /// isn't drawn again in.
    let tableRowHandle = TableRowHandleView()

    /// As tall as the title's font needs.
    private var titleHeight: CGFloat { ceil(titleField.font?.lineHeight ?? 40) + 2 }

    private var isCompact: Bool { bounds.width < 500 }
    private var titleTop: CGFloat { isCompact ? 10 : 28 }
    /// The line with the date under the title, as tall as the system's text size makes it.
    private var metaHeight: CGFloat { max(18, ceil(metaLabel.font.lineHeight) + 2) }
    var headerHeight: CGFloat { titleTop + titleHeight + 2 + metaHeight + 14 }
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
        metaLabel.font = Self.metaFont()
        metaLabel.textColor = Theme.textTertiary
        metaLabel.adjustsFontForContentSizeCategory = true
        addSubview(metaLabel)
        var reminder = UIButton.Configuration.plain()
        reminder.contentInsets = .zero
        reminder.imagePadding = 4
        reminder.image = UIImage(systemName: "bell.fill")
        reminder.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: Self.metaFont(11))
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
        tableRowHandle.isHidden = true
        addSubview(tableRowHandle)
        applyTypography()
        // The note's text follows the system's text size, on top of the size chosen in Settings › Text.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MarkdownTextView, _: UITraitCollection) in
            EditorStyle.follow(view.traitCollection.preferredContentSizeCategory)
            view.reminderButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: Self.metaFont(11))
            view.setReminder(view.reminderText, isOverdue: view.reminderIsOverdue)
        }
    }

    /// The date under the title and the reminder before it: small, as large as the system's text size makes them.
    private static func metaFont(_ size: CGFloat = 13) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: size))
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
        if window != nil { EditorStyle.follow(traitCollection.preferredContentSizeCategory) }
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
            let height = max(30, metaHeight + 12)
            reminderButton.frame = CGRect(x: side, y: titleTop + titleHeight + 2 + (metaHeight - height) / 2, width: size.width, height: height)
            metaStart = reminderButton.frame.maxX + 10
        }
        metaLabel.frame = CGRect(x: metaStart, y: titleTop + titleHeight + 2, width: max(0, side + width - metaStart), height: metaHeight)
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
    private var reminderText: String?
    private var reminderIsOverdue = false

    /// The bell and time of the note's reminder, red once the time has passed; nil for none.
    func setReminder(_ text: String?, isOverdue: Bool) {
        reminderText = text
        reminderIsOverdue = isOverdue
        reminderButton.isHidden = text == nil
        var configuration = reminderButton.configuration ?? .plain()
        var title = AttributedString(text ?? "")
        title.font = Self.metaFont()
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

    /// A picture selected whole shows the ring the layout manager draws around it, not the text's selection; in a
    /// table typed in as a grid, the selection is where the cell's letters are drawn.
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        if let controller {
            let start = offset(from: beginningOfDocument, to: range.start)
            let length = offset(from: range.start, to: range.end)
            if controller.isWholeObject(NSRange(location: start, length: length)) { return [] }
            if let boxes = controller.gridSelectionRects(NSRange(location: start, length: length)), !boxes.isEmpty {
                return boxes.enumerated().map { TableSelectionRect(box: $1, starts: $0 == 0, ends: $0 == boxes.count - 1) }
            }
        }
        return super.selectionRects(for: range)
    }

    /// A finger over a table typed in as a grid (the loupe, a selection's handle) is at the letter of the cell under it.
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let index = controller?.gridIndex(near: point) { return position(from: beginningOfDocument, offset: index) }
        return super.closestPosition(to: point)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        if let controller {
            let start = offset(from: beginningOfDocument, to: range.start)
            let length = offset(from: range.start, to: range.end)
            if length == 0, let caret = controller.tableCaretRect(at: start) { return caret }
            if let boxes = controller.gridSelectionRects(NSRange(location: start, length: length)), let first = boxes.first { return first }
        }
        return super.firstRect(for: range)
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
        if result {
            controller?.focusChanged()
            // VoiceOver goes from the line you double-tapped to the text field you write in.
            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: self) }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            controller?.focusChanged()
            reader.focusCaretLine()
        }
        return result
    }

    // MARK: - VoiceOver

    /// What VoiceOver reads while the note isn't being written in (`NoteReader`).
    private(set) lazy var reader = NoteReader(view: self)

    /// Read line by line as it shows, unless you are writing in it: then one text field, as UIKit makes it.
    override var isAccessibilityElement: Bool {
        get { isFirstResponder ? super.isAccessibilityElement : false }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityElements: [Any]? {
        get { isFirstResponder ? super.accessibilityElements : reader.accessibilityElements() }
        set { super.accessibilityElements = newValue }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let own = controller?.writingAccessibilityActions ?? []
            return own.isEmpty ? super.accessibilityCustomActions : own + (super.accessibilityCustomActions ?? [])
        }
        set { super.accessibilityCustomActions = newValue }
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
        // Pictures and files can be pasted too, which a plain text view doesn't take, and a file Copy File copied.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs
            || UIPasteboard.general.contains(pasteboardTypes: [EditorController.copiedFileType]) {
            return true
        }
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
        } else if isFirstResponder, controller?.activeGrid != nil {
            // In a table typed in as a grid the arrows go through its cells, and a cell has no line breaks.
            command("\t", .shift, #selector(outdentLines))
            for (index, move) in Self.gridKeys.enumerated() {
                let key = UIKeyCommand(title: "", action: #selector(moveInGrid(_:)), input: move.input, modifierFlags: move.modifiers, propertyList: index)
                key.wantsPriorityOverSystemBehavior = true
                commands.append(key)
            }
            command("\r", .shift, #selector(newTableRow))
        } else {
            // Tab arrives as text and nests list items there (or goes to the next cell of a table); Shift-Tab needs a
            // command of its own.
            command("\t", .shift, #selector(outdentLines))
            // ⇧Return breaks an AsciiDoc line with ` +`; it would arrive as Return.
            if controller?.syntax == .asciidoc { command("\r", .shift, #selector(breakAsciiDocLine)) }
            if controller?.isCaretOnFirstLine == true { command(UIKeyCommand.inputUpArrow, [], #selector(moveUpIntoTitle)) }
            if selectedRange == NSRange(location: 0, length: 0) { command(UIKeyCommand.inputLeftArrow, [], #selector(moveBackIntoTitle)) }
        }
        // ⌥⌘ and the arrows add rows and columns in a table, as on the Mac; ⌥⌘⌫ and ⌃⌘⌫ delete them, as in Numbers.
        if isFirstResponder, controller?.activeGrid != nil {
            for (index, edit) in Self.tableEditKeys.enumerated() {
                commands.append(UIKeyCommand(title: edit.title, action: #selector(editTable(_:)), input: edit.input, modifierFlags: edit.modifiers, propertyList: index))
            }
            // Escape leaves a row or column Delete marked to go.
            if controller?.tableDeletion != nil { command(UIKeyCommand.inputEscape, [], #selector(leaveTableDeletion)) }
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

    /// The arrows in a table typed in as a grid, with Shift to select and ⌘ to go to a cell's ends.
    private static let gridKeys: [(input: String, modifiers: UIKeyModifierFlags, move: EditorController.TableMove, extending: Bool)] = [
        (UIKeyCommand.inputLeftArrow, [], .left, false), (UIKeyCommand.inputRightArrow, [], .right, false),
        (UIKeyCommand.inputUpArrow, [], .up, false), (UIKeyCommand.inputDownArrow, [], .down, false),
        (UIKeyCommand.inputLeftArrow, .shift, .left, true), (UIKeyCommand.inputRightArrow, .shift, .right, true),
        (UIKeyCommand.inputUpArrow, .shift, .up, true), (UIKeyCommand.inputDownArrow, .shift, .down, true),
        (UIKeyCommand.inputLeftArrow, .alternate, .wordLeft, false), (UIKeyCommand.inputRightArrow, .alternate, .wordRight, false),
        (UIKeyCommand.inputLeftArrow, .command, .cellStart, false), (UIKeyCommand.inputRightArrow, .command, .cellEnd, false),
        (UIKeyCommand.inputLeftArrow, [.command, .shift], .cellStart, true), (UIKeyCommand.inputRightArrow, [.command, .shift], .cellEnd, true),
    ]

    private static let tableEditKeys: [(title: String, input: String, modifiers: UIKeyModifierFlags, edit: TableEdit)] = [
        ("Add Row Above", UIKeyCommand.inputUpArrow, [.alternate, .command], .addRow(above: true)),
        ("Add Row Below", UIKeyCommand.inputDownArrow, [.alternate, .command], .addRow(above: false)),
        ("Add Column Left", UIKeyCommand.inputLeftArrow, [.alternate, .command], .addColumn(left: true)),
        ("Add Column Right", UIKeyCommand.inputRightArrow, [.alternate, .command], .addColumn(left: false)),
        ("Delete Row", "\u{8}", [.alternate, .command], .deleteRow),
        ("Delete Column", "\u{8}", [.control, .command], .deleteColumn),
    ]

    @objc private func moveInGrid(_ sender: UIKeyCommand) {
        guard let index = sender.propertyList as? Int, let key = Self.gridKeys[safe: index] else { return }
        _ = controller?.moveInGrid(key.move, extending: key.extending)
    }

    @objc private func editTable(_ sender: UIKeyCommand) {
        guard let index = sender.propertyList as? Int, let key = Self.tableEditKeys[safe: index] else { return }
        controller?.editTable(key.edit)
    }

    @objc private func newTableRow() { _ = controller?.insertNewline() }
    @objc private func leaveTableDeletion() { controller?.clearTableDeletion() }

    @objc private func suggestionUp() { controller?.suggestions.move(by: -1) }
    @objc private func suggestionDown() { controller?.suggestions.move(by: 1) }
    @objc private func acceptSuggestion() { controller?.acceptSelectedSuggestion() }
    @objc private func closeSuggestions() { controller?.closeSuggestions() }
    @objc private func outdentLines() {
        guard let controller, !controller.moveToTableCell(by: -1) else { return }
        controller.indent(by: -1)
    }
    /// Where it can't break the line (a heading, a table, a listing), Return.
    @objc private func breakAsciiDocLine() {
        if controller?.insertAsciiDocLineBreak() != true { insertText("\n") }
    }
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

    /// Pasted Markdown with more than a line goes in the title and the note below it (`EditorController.pasteInTitle`).
    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        let source = pasteboard.data(forPasteboardType: EditorController.fragmentIdentifier).flatMap(EditorController.fragmentFolder)
        if let string = pasteboard.string, let controller = (superview as? MarkdownTextView)?.controller,
           controller.pasteInTitle(string, assetsFrom: source) {
            return
        }
        super.paste(sender)
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
/// A box of a selection in a table typed in as a grid, which UIKit draws with its handles.
final class TableSelectionRect: UITextSelectionRect {
    private let box: CGRect
    private let starts: Bool
    private let ends: Bool

    init(box: CGRect, starts: Bool, ends: Bool) {
        self.box = box
        self.starts = starts
        self.ends = ends
        super.init()
    }

    override var rect: CGRect { box }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { starts }
    override var containsEnd: Bool { ends }
    override var isVertical: Bool { false }
}
/// A table row's handle, drawn as the layout manager draws the column's. Taps on it are the editor's, as on the table.
final class TableRowHandleView: UIView {
    var isPicked = false {
        didSet { if isPicked != oldValue { setNeedsDisplay() } }
    }
    /// Its row is marked to be deleted: red.
    var isDeleting = false {
        didSet { if isDeleting != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        TableModel.drawHandle(in: bounds.insetBy(dx: 1, dy: 1), vertical: true, picked: isPicked, deleting: isDeleting)
    }
}
#endif
