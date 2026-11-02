#if os(iOS)
import UIKit

/// VoiceOver in a note on iPhone and iPad. While nothing is being written in the note, its text view is read line by
/// line as it shows (`EditorController.readingItems`), after the title and the date: a heading is a heading, a to-do
/// says whether it is done and a double-tap ticks it, a link is a link, a picture says its name. A double-tap on a line
/// starts writing at its end; while you write, the text view is the one text field VoiceOver edits, as it always was,
/// with its caret, its rotor and the actions of the to-do the caret is in.
@MainActor
final class NoteReader {
    private unowned let view: MarkdownTextView
    /// Nil until VoiceOver asks again after a change.
    private var elements: [ReadingElement]?
    private var isAnnouncing = false

    init(view: MarkdownTextView) {
        self.view = view
    }

    /// What VoiceOver goes through, in order: what is above the text, then the text.
    func accessibilityElements() -> [Any] {
        var above: [Any] = [view.titleField]
        if !view.reminderButton.isHidden { above.append(view.reminderButton) }
        if !(view.metaLabel.text ?? "").isEmpty { above.append(view.metaLabel) }
        // While drawing, a drawing is its canvas.
        let canvases = view.controller?.drawingSession?.canvases ?? [:]
        return above + readingElements().map { element -> Any in
            if case .picture(_, let url?) = element.item.hit, let canvas = canvases[url] { return canvas }
            return element
        }
    }

    /// The note's text changed, or its look: read again when next asked.
    func invalidate() {
        guard elements != nil else { return }
        elements = nil
        guard UIAccessibility.isVoiceOverRunning, !view.isFirstResponder, !isAnnouncing else { return }
        isAnnouncing = true
        DispatchQueue.main.async { [weak self] in
            self?.isAnnouncing = false
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    /// Another note: none of the last one's elements stay.
    func reset() {
        elements = nil
        lastElements = []
    }

    /// Moves VoiceOver to the to-do on a line, which reads its new state: after a tick, which may have put the next one
    /// of a repeating to-do above it.
    func focusTodo(line: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let element = self.readingElements().first { $0.item.line == line && $0.item.kind.isTodo }
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
    }

    /// VoiceOver goes back to the line the caret is on once you stop writing.
    func focusCaretLine() {
        guard UIAccessibility.isVoiceOverRunning, let controller = view.controller else { return }
        let line = controller.document.lineIndex(containing: controller.selection.location)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.view.isFirstResponder else { return }
            let elements = self.readingElements()
            let element = elements.last { $0.item.line <= line } ?? elements.first
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
    }

    private func readingElements() -> [ReadingElement] {
        if let elements { return elements }
        guard let controller = view.controller else { return [] }
        // The elements of the lines that are still there stay the same, so VoiceOver stays on the one it was on.
        var old = Dictionary(keyed(lastElements.map(\.item)).enumerated().map { ($1, lastElements[$0]) }) { first, _ in first }
        let items = controller.readingItems()
        let made = zip(items, keyed(items)).map { item, key in
            if let element = old.removeValue(forKey: key) {
                element.show(item)
                return element
            }
            return ReadingElement(item, editor: controller, in: view)
        }
        lastElements = made
        elements = made
        return made
    }

    private var lastElements: [ReadingElement] = []

    /// Each item's line and how many items of that line come before it.
    private func keyed(_ items: [ReadingItem]) -> [Key] {
        var counts: [Int: Int] = [:]
        return items.map { item in
            defer { counts[item.line, default: 0] += 1 }
            return Key(line: item.line, ordinal: counts[item.line, default: 0])
        }
    }

    private struct Key: Hashable {
        var line: Int
        var ordinal: Int
    }
}

/// One thing VoiceOver reads in a note.
final class ReadingElement: UIAccessibilityElement {
    private(set) var item: ReadingItem
    private weak var editor: EditorController?

    init(_ item: ReadingItem, editor: EditorController, in view: MarkdownTextView) {
        self.item = item
        self.editor = editor
        super.init(accessibilityContainer: view)
        show(item)
    }

    func show(_ item: ReadingItem) {
        self.item = item
        let editable = editor?.textView.isEditable ?? false
        if case .heading(let level) = item.kind {
            accessibilityAttributedLabel = NSAttributedString(string: item.label, attributes: [.accessibilityTextHeadingLevel: level])
        } else {
            accessibilityLabel = item.label
        }
        accessibilityValue = item.value
        switch item.kind {
        case .text:
            accessibilityTraits = .staticText
            accessibilityHint = editable ? "Edits the text here." : nil
        case .heading:
            accessibilityTraits = [.staticText, .header]
            accessibilityHint = editable ? "Edits the heading." : nil
        case .todo(let mark):
            accessibilityTraits = editable ? .button : .staticText
            accessibilityHint = editable ? (mark.isClosed ? "Marks it as not done." : "Marks it as done.") : nil
        case .link:
            accessibilityTraits = .link
            accessibilityHint = nil
        case .picture:
            accessibilityTraits = .image
            accessibilityHint = nil
        case .drawing:
            accessibilityTraits = .image
            accessibilityHint = editable ? "Draws in it." : nil
        case .file:
            accessibilityTraits = .button
            accessibilityHint = nil
        case .pill:
            accessibilityTraits = editable ? .button : .staticText
            accessibilityHint = editable ? "Changes the reminder." : nil
        case .block:
            accessibilityTraits = .staticText
            accessibilityHint = editable ? "Edits it." : nil
        }
        var actions: [UIAccessibilityCustomAction] = []
        guard editable else { return accessibilityCustomActions = actions }
        // A double-tap ticks a to-do: its words are written in from its actions.
        if item.kind.isTodo {
            actions.append(UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in
                guard let self, let editor = self.editor else { return false }
                return editor.write(at: self.item.caret)
            })
        }
        actions += item.actions.map { action in
            UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                guard let self, let editor = self.editor else { return false }
                return editor.activate(self.item, hit: action.hit)
            }
        }
        accessibilityCustomActions = actions
    }

    /// Where it is now: the note scrolls, and its lines move as it is written in.
    override var accessibilityFrame: CGRect {
        get {
            guard let editor, let view = accessibilityContainer as? UIView, let rect = editor.readingFrame(of: item) else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(rect, in: view)
        }
        set {}
    }

    /// A to-do's circle, where a tap ticks it.
    override var accessibilityActivationPoint: CGPoint {
        get {
            if item.kind.isTodo, let editor, let view = accessibilityContainer as? UIView,
               let circle = editor.layoutManager.rect(forObjectAt: item.range.location, origin: editor.textOrigin) {
                let screen = UIAccessibility.convertToScreenCoordinates(circle, in: view)
                return CGPoint(x: screen.midX, y: screen.midY)
            }
            let frame = accessibilityFrame
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard let editor else { return false }
        guard let hit = item.hit else { return editor.write(at: item.caret) }
        return editor.activate(item, hit: hit)
    }
}

extension EditorController {
    /// Does what a tap on an item does, as VoiceOver's double-tap: a to-do is ticked as by a tap on its circle, so Undo,
    /// its reminder and the To-dos list follow as they do then.
    func activate(_ item: ReadingItem, hit: Hit) -> Bool {
        switch hit {
        case .checkbox, .todo, .block, .editLink:
            guard textView.isEditable else { return false }
        default:
            break
        }
        let frame = readingFrame(of: item) ?? .zero
        var point = CGPoint(x: frame.midX, y: frame.midY)
        if case .checkbox = hit, let circle = layoutManager.rect(forObjectAt: item.range.location, origin: textOrigin) {
            point = CGPoint(x: circle.midX, y: circle.midY)
        }
        let lines = document.lines.count
        handleTap(hit, at: point)
        if case .checkbox(let line) = hit, UIAccessibility.isVoiceOverRunning {
            // A to-do that repeats has the next one above it now.
            textView.reader.focusTodo(line: line + document.lines.count - lines)
        }
        return true
    }

    /// Starts writing at a place in the text, as a tap there does.
    func write(at caret: Int?) -> Bool {
        guard let caret, textView.isEditable else { return false }
        makeTextFirstResponder()
        setSelection(NSRange(location: min(caret, storage.length), length: 0))
        return true
    }

    /// While you write, the actions of the to-do the caret is in: ticking it, as ⌘⇧U does.
    var writingAccessibilityActions: [UIAccessibilityCustomAction]? {
        guard textView.isFirstResponder, let line = document.lines[safe: document.lineIndex(containing: selection.location)],
              case .listItem(let item) = line.kind, item.isTask else { return nil }
        return [UIAccessibilityCustomAction(name: item.checked ? "Mark as Not Done" : "Mark as Done") { [weak self] _ in
            guard let self else { return false }
            self.toggleChecked()
            UIAccessibility.post(notification: .announcement, argument: Self.todoState(item.checked ? .open : .done))
            return true
        }]
    }
}

private extension ReadingItem.Kind {
    var isTodo: Bool { if case .todo = self { true } else { false } }
}
#endif
