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
    /// Nil until asked again after a change.
    private var elements: [ReadingElement]?
    /// The elements last made, each with its line as the edits since have moved it.
    private var made: [ReadingElement] = []
    /// What `accessibilityElements()` last gave, with what was above the text and the canvases then.
    private var given: (above: [UIView], canvases: [URL: DrawingCanvas], all: [Any])?
    private var isAnnouncing = false

    init(view: MarkdownTextView) {
        self.view = view
        // VoiceOver or Switch Control turned off: the elements go, and are made again if Voice Control or Full Keyboard
        // Access, which say nothing of themselves, ask for them.
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning, self.isReading else { return }
                    self.reset()
                    UIAccessibility.post(notification: .layoutChanged, argument: nil)
                }
            }
        }
    }

    /// Whether something has asked what the note reads: VoiceOver, Switch Control, Voice Control, Full Keyboard Access.
    var isReading: Bool { !made.isEmpty }

    /// What VoiceOver goes through, in order: what is above the text, then the text. The same array while nothing
    /// changed, since it is asked for again for every step through the note.
    func accessibilityElements() -> [Any] {
        var above: [UIView] = [view.titleField]
        if !view.reminderButton.isHidden { above.append(view.reminderButton) }
        if !(view.metaLabel.text ?? "").isEmpty { above.append(view.metaLabel) }
        // While drawing, a drawing is its canvas.
        let canvases = view.controller?.drawingSession?.canvases ?? [:]
        if elements != nil, let given, given.above.elementsEqual(above, by: ===),
           given.canvases.count == canvases.count, given.canvases.allSatisfy({ canvases[$0.key] === $0.value }) {
            return given.all
        }
        let all: [Any] = above + readingElements().map { element -> Any in
            if case .picture(_, let url?) = element.item.hit, let canvas = canvases[url] { return canvas }
            return element
        }
        given = (above, canvases, all)
        return all
    }

    /// The note's text changed: each element stays with its line, wherever the change moved it, and one whose line it
    /// made into others no longer acts. Only worked out while something reads the note.
    func textChanged(_ moves: @autoclosure () -> LineMoves) {
        guard isReading else { return }
        let moves = moves()
        for element in made {
            guard case .item(let line, let ordinal)? = element.key else { continue }
            element.key = moves(line).map { .item(line: $0, ordinal: ordinal) }
        }
    }

    /// The note's text changed, or its look: read again when next asked. Whatever reads the note is told, VoiceOver or
    /// not: Switch Control, Voice Control and Full Keyboard Access would act on what was there before.
    func invalidate() {
        guard elements != nil else { return }
        elements = nil
        given = nil
        guard !view.isFirstResponder, !isAnnouncing else { return }
        isAnnouncing = true
        DispatchQueue.main.async { [weak self] in
            self?.isAnnouncing = false
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    /// Another note: none of the last one's elements stay, and those still held do nothing.
    func reset() {
        for element in made { element.key = nil }
        made = []
        elements = nil
        given = nil
    }

    /// Whether an element still stands for something in the note, read again first if the note changed since.
    func isCurrent(_ element: ReadingElement) -> Bool {
        _ = readingElements()
        return element.key != nil
    }

    /// A double-tap on what has changed since VoiceOver read it, written over or gone: nothing is done, and VoiceOver
    /// reads what is on its line now, or says it is gone.
    func changed(_ element: ReadingElement) {
        if let next = element.replacement, isCurrent(next) {
            UIAccessibility.post(notification: .layoutChanged, argument: next)
        } else {
            UIAccessibility.post(notification: .announcement, argument: "No longer in the note")
        }
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

    /// VoiceOver goes back to the line the caret is on once you stop writing; not when the keyboard went to another
    /// field, Find in Note's or a link's address, which VoiceOver is on then.
    func focusCaretLine() {
        guard isReading || UIAccessibility.isVoiceOverRunning, let controller = view.controller else { return }
        let line = controller.document.lineIndex(containing: controller.selection.location)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.view.isFirstResponder, !(UIResponder.focused is UITextInput) else { return }
            let elements = self.readingElements()
            let element = elements.last { $0.item.line <= line } ?? elements.first
            #if DEBUG
            self.lastFocused = element?.accessibilityLabel
            #endif
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
    }

    #if DEBUG
    /// The label of what `focusCaretLine` last moved to, for the debug remote, which takes it.
    var lastFocused: String?
    #endif

    private func readingElements() -> [ReadingElement] {
        if let elements { return elements }
        guard let controller = view.controller else { return [] }
        // The element of a line that is still there stays the same, so VoiceOver stays on the one it was on, and acts
        // on that line, wherever it moved.
        var old: [Key: ReadingElement] = [:]
        for element in made {
            guard let key = element.key else { continue }
            if old[key] == nil { old[key] = element } else { element.key = nil }
        }
        let items = controller.readingItems()
        let fresh = zip(items, keyed(items)).map { item, key in
            guard let element = old[key] else { return ReadingElement(item, key: key, editor: controller, in: view) }
            if key == .end || item.isStill(element.item) {
                old[key] = nil
                element.show(item)
                return element
            }
            // Written over: VoiceOver reads the new one when the old one is double-tapped.
            let made = ReadingElement(item, key: key, editor: controller, in: view)
            element.replacement = made
            return made
        }
        for element in old.values { element.key = nil }
        made = fresh
        elements = fresh
        return fresh
    }

    /// Each item's line and how many items of that line come before it.
    private func keyed(_ items: [ReadingItem]) -> [Key] {
        var counts: [Int: Int] = [:]
        return items.map { item in
            guard item.kind != .end else { return .end }
            defer { counts[item.line, default: 0] += 1 }
            return .item(line: item.line, ordinal: counts[item.line, default: 0])
        }
    }

    fileprivate enum Key: Hashable {
        case item(line: Int, ordinal: Int)
        case end
    }
}

/// One thing VoiceOver reads in a note.
final class ReadingElement: UIAccessibilityElement {
    private(set) var item: ReadingItem
    /// Its line, moved along by the edits since it was made; nil once it stands for nothing in the note.
    fileprivate var key: NoteReader.Key?
    /// What took its place when its line was written over.
    fileprivate weak var replacement: ReadingElement?
    private weak var editor: EditorController?

    fileprivate init(_ item: ReadingItem, key: NoteReader.Key, editor: EditorController, in view: MarkdownTextView) {
        self.item = item
        self.key = key
        self.editor = editor
        super.init(accessibilityContainer: view)
        show(item)
    }

    /// The editor, while this still stands for something in the note: the line it was made for may have been changed
    /// into others since, from another device, and acting on what is there now would be acting on something else.
    private var currentEditor: EditorController? {
        guard let editor, editor.textView.reader.isCurrent(self) else { return nil }
        return editor
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
        case .end:
            accessibilityTraits = .button
            accessibilityHint = nil
        }
        var actions: [UIAccessibilityCustomAction] = []
        guard editable else { return accessibilityCustomActions = actions }
        // A double-tap ticks a to-do: its words are written in from its actions.
        if item.kind.isTodo {
            actions.append(UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in
                guard let self, let editor = self.editor else { return false }
                guard editor.textView.reader.isCurrent(self) else { return self.wasChanged(in: editor) }
                return editor.write(at: self.item.caret)
            })
        }
        actions += item.actions.map { action in
            UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                guard let self, let editor = self.editor else { return false }
                guard editor.textView.reader.isCurrent(self) else { return self.wasChanged(in: editor) }
                // What the action does now: the line may have moved since.
                guard let action = self.item.actions.first(where: { $0.name == action.name }) else { return false }
                return editor.activate(self.item, hit: action.hit)
            }
        }
        accessibilityCustomActions = actions
    }

    /// Where it is now: the note scrolls, and its lines move as it is written in.
    override var accessibilityFrame: CGRect {
        get {
            guard let editor = currentEditor, let view = accessibilityContainer as? UIView, let rect = editor.readingFrame(of: item) else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(rect, in: view)
        }
        set {}
    }

    /// A to-do's circle, where a tap ticks it. Off the screen once it stands for nothing in the note: a tap where it
    /// was would land on whatever is there now, another to-do's circle, or at the top of the screen, which scrolls the
    /// note up.
    override var accessibilityActivationPoint: CGPoint {
        get {
            guard let editor = currentEditor, let view = accessibilityContainer as? UIView else { return Self.nowhere }
            if item.kind.isTodo, let circle = editor.layoutManager.rect(forObjectAt: item.range.location, origin: editor.textOrigin) {
                let screen = UIAccessibility.convertToScreenCoordinates(circle, in: view)
                return CGPoint(x: screen.midX, y: screen.midY)
            }
            let frame = accessibilityFrame
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        set {}
    }

    static let nowhere = CGPoint(x: -10_000, y: -10_000)

    override func accessibilityActivate() -> Bool {
        guard let editor else { return false }
        guard editor.textView.reader.isCurrent(self) else { return wasChanged(in: editor) }
        if item.kind == .end { return editor.writeAtEnd() }
        guard let hit = item.hit else { return editor.write(at: item.caret) }
        return editor.activate(item, hit: hit)
    }

    /// Done with: VoiceOver taps where an element was when its double-tap does nothing, which would be acting on
    /// whatever is there now.
    private func wasChanged(in editor: EditorController) -> Bool {
        editor.textView.reader.changed(self)
        return true
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
        // A second double-tap right after the first ticks nothing, as a second tap doesn't.
        guard handleTap(hit, at: point) else { return false }
        if case .checkbox(let line) = hit {
            // A to-do that repeats has the next one above it now.
            textView.reader.focusTodo(line: line + document.lines.count - lines)
        }
        return true
    }

    /// Starts writing after everything in the note, on a line of its own.
    func writeAtEnd() -> Bool {
        guard textView.isEditable, !isWaitingForText else { return false }
        return write(at: makeRoomAtEnd())
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
