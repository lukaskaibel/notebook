#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A to-do's reminder in the note. Its date and place are written after its words (`TodoMarks`) and show as pills; a
/// click on one, or on the bell at the end of a to-do under the pointer, opens Remind Me for it, and what you choose
/// there is written back as an edit Undo takes back.
extension EditorController {
    /// The to-do on a line: the line as it is, and its date and place.
    func todo(onLine index: Int) -> (source: String, due: TodoDue?, place: TodoPlace?, done: Bool)? {
        guard let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask else { return nil }
        let schedule = TodoMarks.schedule(of: line)
        return (nsText.substring(with: line.range), schedule.due, schedule.place, item.checked)
    }

    /// The line the to-do is on now: `line` if it still says `source`, else the nearest one that does.
    func todoLine(_ source: String, near line: Int) -> Int? {
        Todos.find(source, near: line, in: document, string: nsText)
    }

    /// Where a to-do's words end: before its date and place, or at the end of its line.
    func todoWordsEnd(line index: Int) -> Int {
        guard let line = document.lines[safe: index] else { return storage.length }
        guard let first = line.spans.first(where: { if case .todoMark = $0.kind { true } else { false } }) else { return line.range.upperBound }
        var end = first.range.location
        while end > line.content.location, [32, 9].contains(nsText.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// Gives the to-do on a line this date and place, or takes them away. The caret stays where it was in the words.
    @discardableResult
    func setTodoSchedule(line index: Int, due: TodoDue?, place: TodoPlace?) -> Bool {
        editTodo(line: index, actionName: due == nil && place == nil ? "Remove Reminder" : "Set Reminder") { text, line in
            TodoMarks.change(in: text, content: line.content, due: due, place: place)
        }
    }

    /// Changes the line of a to-do as `edit` says, as an edit Undo takes back.
    @discardableResult
    func editTodo(line index: Int, actionName: String, edit: (NSString, MarkdownLine) -> (range: NSRange, replacement: String)?) -> Bool {
        guard !isWaitingForText, let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask,
              let change = edit(nsText, line) else { return false }
        let selection = self.selection
        var caret = selection
        let delta = (change.replacement as NSString).length - change.range.length
        if selection.location >= change.range.upperBound {
            caret.location += delta
        } else if selection.upperBound > change.range.location {
            caret = NSRange(location: min(selection.location, change.range.location), length: 0)
        }
        var done = false
        preservingScroll {
            done = replace(change.range, with: change.replacement, select: caret, actionName: actionName)
        }
        return done
    }

    /// Styles the pills again: a time that passed turns red, and Tomorrow becomes Today at midnight.
    public func refreshTodoPills() {
        let lines = document.lines.indices.filter { index in
            document.lines[index].spans.contains { if case .todoMark = $0.kind { true } else { false } }
        }
        guard !lines.isEmpty else { return }
        restyle(lines: lines)
    }

    /// Ticks the to-do on a line, or unticks it.
    func setTodoDone(line index: Int, _ done: Bool) {
        guard let line = document.lines[safe: index], case .listItem(let item) = line.kind, item.isTask, item.checked != done else { return }
        toggleCheckbox(line: index)
    }

    /// Where Remind Me points for the to-do on a line: its first pill, or the end of its words.
    func todoAnchor(line index: Int) -> NSRect? {
        guard let line = document.lines[safe: index] else { return nil }
        let origin = textOrigin
        for span in line.spans {
            guard case .todoMark = span.kind, let rect = layoutManager.rect(forObjectAt: span.range.location, origin: origin) else { continue }
            return NSRect(x: rect.minX + TodoPill.gap, y: rect.minY, width: rect.width - TodoPill.gap, height: rect.height)
        }
        return todoEnd(line: index).map { NSRect(x: $0.x, y: $0.y - 9, width: 1, height: 18) }
    }

    /// The end of a to-do's words, at the middle of their letters, in the text view.
    func todoEnd(line index: Int) -> CGPoint? {
        guard let line = document.lines[safe: index], line.range.length > 0, line.range.upperBound <= storage.length else { return nil }
        layoutManager.ensureLayout(forCharacterRange: line.range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let last = glyphs.upperBound - 1
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let font = (storage.attribute(.font, at: line.content.location < storage.length ? line.content.location : line.range.location, effectiveRange: nil) as? NSFont) ?? EditorStyle.body
        let origin = textOrigin
        return CGPoint(x: origin.x + used.maxX, y: layoutManager.baseline(forGlyphAt: last, origin: origin) - font.capHeight / 2)
    }

    /// The to-do whose line a point is on, if it has neither a date nor a place yet and isn't done: the bell shows
    /// for it.
    func todoWithoutReminder(at point: CGPoint) -> Int? {
        guard storage.length > 0 else { return nil }
        let origin = textOrigin
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y), in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
        guard point.y >= fragment.minY, point.y <= fragment.maxY else { return nil }
        let index = document.lineIndex(containing: layoutManager.characterIndexForGlyph(at: glyph))
        guard let todo = todo(onLine: index), !todo.done, todo.due == nil, todo.place == nil else { return nil }
        // Not past the bell, which sits after the words.
        if let end = todoEnd(line: index), point.x > end.x + 40 { return nil }
        return index
    }

    func showTodoReminder(line: Int) {
        delegate?.editor(self, showTodoReminderOnLine: line)
    }

    #if os(macOS)
    /// Shows the bell after the to-do under the pointer, or hides it.
    func updateTodoBell(at point: NSPoint?) {
        let button = textView.todoBell
        guard !isDrawing, !isWaitingForText, textView.isEditable, let point, let line = todoWithoutReminder(at: point), let end = todoEnd(line: line) else {
            button.isHidden = true
            button.line = nil
            return
        }
        let size = TodoBellButton.size
        button.frame = NSRect(x: end.x + 4, y: (end.y - size.height / 2).rounded(), width: size.width, height: size.height)
        button.line = line
        button.isHidden = false
    }

    /// The pointer stayed put while the note moved under it.
    func updateTodoBellForPointer() {
        guard let window = textView.window, window.isKeyWindow else { return updateTodoBell(at: nil) }
        let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateTodoBell(at: textView.visibleRect.contains(point) ? point : nil)
    }

    /// Remind Me… in the context menu of a to-do.
    func addTodoReminder(to menu: NSMenu, at point: NSPoint) {
        let origin = textOrigin
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let line = document.lineIndex(containing: layoutManager.characterIndexForGlyph(at: glyph))
        guard let todo = todo(onLine: line) else { return }
        let item = NSMenuItem(title: todo.due == nil && todo.place == nil ? "Remind Me…" : "Change Reminder…", action: #selector(MarkdownTextView.remindOfTodo(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        item.representedObject = line
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
    #endif
}

#if os(macOS)
extension MarkdownTextView {
    @objc func remindOfTodo(_ sender: Any?) {
        guard let line = (sender as? NSMenuItem)?.representedObject as? Int ?? todoBell.line else { return }
        controller?.showTodoReminder(line: line)
    }
}

/// The bell after a to-do without a reminder, while the pointer is on its line: Remind Me for it.
@MainActor
final class TodoBellButton: NSButton {
    /// The line of the to-do it is for.
    var line: Int?

    static let size = NSSize(width: 22, height: 20)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageOnly
        refusesFirstResponder = true
        isHidden = true
        image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        contentTintColor = .tertiaryLabelColor
        toolTip = "Remind Me"
        setAccessibilityLabel("Remind Me")
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
