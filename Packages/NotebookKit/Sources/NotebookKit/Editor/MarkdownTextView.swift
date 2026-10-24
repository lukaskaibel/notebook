#if os(macOS)
import AppKit

/// The note's text view. Mouse, keyboard and pasteboard go through the `EditorController`; this class only adds what
/// has to live in the view: tracking the mouse, the caret, the title above the text and centring the text column.
@MainActor
final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?

    /// True while the mouse button is down and AppKit is tracking a click or drag. Markdown doesn't show next to the
    /// caret until the button comes up, so selecting never moves text around under the pointer.
    private(set) var isTrackingMouse = false

    let titleField = TitleField()
    let metaLabel = NSTextField(labelWithString: "")
    /// The note's reminder, a bell and its time, before the date under the title. A click changes or removes it.
    let reminderButton = NSButton(title: "", target: nil, action: nil)
    let copyButton = CodeCopyButton()
    let todoBell = TodoBellButton()

    static let titleTop: CGFloat = 44
    static let titleHeight: CGFloat = 40
    static let headerHeight: CGFloat = 112

    /// Set on a copy laid out for export or printing: this much margin all round, and no date under the title.
    var exportMargin: CGFloat? {
        didSet {
            metaLabel.isHidden = exportMargin != nil
            if exportMargin != nil { reminderButton.isHidden = true }
            updateInsets()
        }
    }

    private var titleTop: CGFloat { exportMargin ?? Self.titleTop }
    var headerHeight: CGFloat { exportMargin.map { $0 + Self.titleHeight + 18 } ?? Self.headerHeight }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        titleField.textColor = Theme.text
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.setAccessibilityLabel("Title")
        addSubview(titleField)
        metaLabel.font = .systemFont(ofSize: 12.5)
        metaLabel.textColor = Theme.textTertiary
        addSubview(metaLabel)
        reminderButton.isBordered = false
        reminderButton.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)
        reminderButton.imagePosition = .imageLeading
        reminderButton.imageHugsTitle = true
        reminderButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .regular)
        reminderButton.isHidden = true
        reminderButton.target = self
        reminderButton.action = #selector(showReminder(_:))
        reminderButton.toolTip = "Change or remove the reminder"
        addSubview(reminderButton)
        copyButton.target = self
        copyButton.action = #selector(copyCodeBlock(_:))
        addSubview(copyButton)
        todoBell.target = self
        todoBell.action = #selector(remindOfTodo(_:))
        addSubview(todoBell)
        applyTypography()
    }

    /// The title in the note's typeface; the width of the text follows the settings too.
    func applyTypography() {
        let font = EditorStyle.face(30, weight: .bold)
        titleField.font = font
        titleField.placeholderAttributedString = NSAttributedString(string: "Untitled", attributes: [.font: font, .foregroundColor: Theme.faint])
        updateInsets()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        var newSize = newSize
        // AppKit sizes the view to the text without the spacing after a last paragraph that no line break ends
        // (`NotebookLayoutManager.usedRect`), where a diagram or formula being edited shows what it makes.
        if isVerticallyResizable, let layoutManager = layoutManager as? NotebookLayoutManager, let container = textContainer {
            newSize.height = max(newSize.height, ceil(layoutManager.usedRect(for: container).maxY + textContainerOrigin.y + textContainerInset.height))
        }
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        updateInsets()
        // Drawings are as wide as the text, and the last one reaches down to the end of the page: their canvases
        // follow.
        if changed, controller?.isDrawing == true {
            DispatchQueue.main.async { [weak self] in self?.controller?.updateDrawingCanvases() }
        }
    }

    /// Centres a column of text at most `EditorStyle.contentWidth` wide, with room above for the title.
    func updateInsets() {
        let side = exportMargin ?? max(52, floor((bounds.width - EditorStyle.contentWidth) / 2))
        let inset = NSSize(width: side, height: headerHeight)
        if textContainerInset != inset { textContainerInset = inset }
        let width = bounds.width - side * 2
        titleField.frame = NSRect(x: side - 2, y: titleTop, width: width + 4, height: Self.titleHeight)
        var metaStart = side
        if !reminderButton.isHidden {
            let size = reminderButton.intrinsicContentSize
            reminderButton.frame = NSRect(x: side, y: titleTop + Self.titleHeight + 2 + floor((18 - size.height) / 2), width: size.width, height: size.height)
            metaStart = reminderButton.frame.maxX + 10
        }
        metaLabel.frame = NSRect(x: metaStart, y: titleTop + Self.titleHeight + 2, width: max(0, side + width - metaStart), height: 18)
    }

    /// The bell and time of the note's reminder, red once the time has passed; nil for none.
    func setReminder(_ text: String?, isOverdue: Bool) {
        reminderButton.isHidden = text == nil || exportMargin != nil
        let color: NSColor = isOverdue ? .systemRed : Theme.accent
        reminderButton.contentTintColor = color
        reminderButton.attributedTitle = NSAttributedString(string: text ?? "", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: color])
        reminderButton.setAccessibilityLabel(text.map { "Reminder, \($0)" })
        updateInsets()
    }

    /// Where Remind Me… shows its popover for the open note: from the reminder, or the date where it will be.
    var reminderAnchor: NSView { reminderButton.isHidden ? metaLabel : reminderButton }

    @objc private func showReminder(_ sender: Any?) {
        guard let controller else { return }
        controller.delegate?.editorShowReminder(controller)
    }

    // Leave more room under the last line than above the title.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: headerHeight)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // A click in the text (canvases take their own) stops drawing and puts the caret where it was clicked, which
        // stays under the pointer while the drawings settle to their size.
        if let controller, controller.isDrawing {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            controller.endDrawing(keeping: index)
            window?.makeFirstResponder(self)
            controller.setSelection(NSRange(location: min(index, controller.storage.length), length: 0))
            return
        }
        if controller?.handleMouseDown(event) == true { return }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        controller?.mouseTrackingEnded()
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.updateCopyButton(at: convert(event.locationInWindow, from: nil))
        controller?.updateTodoBell(at: convert(event.locationInWindow, from: nil))
        controller?.updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.updateCopyButton(at: nil)
        controller?.updateTodoBell(at: nil)
    }

    // AppKit puts the I-beam back on every cursor update; links and checkboxes keep the hand.
    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        controller?.updateCursor(for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(for: event, base: super.menu(for: event)) ?? super.menu(for: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pointer isn't tracked in a window in the background, so nothing would hide the copy button there.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
            // Drops reach the text view only once it has registered for them, which takes a window and which it does
            // by itself only when it is made editable again: a note that opens at once was never ready for them.
            updateDragTypeRegistration()
        }
    }

    @objc private func windowResignedKey() {
        controller?.updateCopyButton(at: nil)
        controller?.updateTodoBell(at: nil)
    }

    #if DEBUG
    /// For recordings of a window in the background, which draws no caret of its own.
    static var drawsCaretAlways = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard Self.drawsCaretAlways, selectedRange().length == 0, window?.firstResponder === self,
              let window, var rect = Optional(firstRect(forCharacterRange: selectedRange(), actualRange: nil)) else { return }
        rect = convert(window.convertFromScreen(rect), from: nil)
        let caret = controller?.caretRect(proposed: NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)) ?? rect
        insertionPointColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height), xRadius: 1, yRadius: 1).fill()
    }
    #endif

    // The margin is the view's to draw: the text system only draws inside the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        controller?.drawMarginMarks(in: rect)
    }

    // MARK: - Caret

    /// A caret as tall as the text it is in, not as the line, which is taller than the font.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let caret = controller?.caretRect(proposed: rect) ?? rect
        if flag {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height), xRadius: 1, yRadius: 1).fill()
        } else {
            super.drawInsertionPoint(in: rect.union(NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)), color: color, turnedOn: false)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -2, dy: 0), avoidAdditionalLayout: flag)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
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
        if controller?.paste(from: .general, at: nil) != true { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) { insertText(string, replacementRange: selectedRange()) }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string, EditorController.fragmentType] + super.readablePasteboardTypes
    }

    // Text dragged to another note brings its pictures along, as copied text does.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes + [EditorController.fragmentType]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == EditorController.fragmentType, let data = controller?.clipping(of: selectedRange()).fragment {
            return pboard.setData(data, forType: type)
        }
        return super.writeSelection(to: pboard, type: type)
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        controller?.dropOperation(for: dragInfo) ?? super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        // A picture dragged within the note is moved by the editor; text dragged within it is AppKit's; files and
        // pictures from elsewhere are the editor's.
        if controller?.dropObject(sender, at: index) == true { return true }
        if sender.draggingSource as? NSTextView !== self, controller?.paste(from: sender.draggingPasteboard, at: index) == true {
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - Keys the menus don't cover

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The title above the note: the file's name, renamed when you change it.
final class TitleField: NSTextField {
    var onCommandBy: ((Selector) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
}
#endif
