#if os(iOS)
import UIKit

/// Undo on iPhone and iPad. UIKit's text view keeps a record of what it typed itself, which goes wrong (or is
/// cleared) when the editor changes the text too: when a list continues, a link is put in, a change comes from
/// another device. So the editor keeps the record itself, of every change to the text from wherever it comes,
/// and the text view's undo manager is this one. Typing in one place is undone in one step, as in UIKit.
final class EditorUndoManager: UndoManager {
    /// Off while UIKit's text view would register its own record of typing, which this manager doesn't keep.
    fileprivate var acceptsRegistrations = false
    fileprivate var allowsClearing = false
    /// Takes what is sent to an invocation target this manager doesn't keep, and keeps none of it.
    private let sink: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()
    /// The changes to files, which are kept in the window's undo manager (`Workspace+Undo`). While the note has the
    /// focus ⌘Z comes here, and takes those back too when they are newer than the last change to the text, as on the
    /// Mac, where the text keeps its changes in the window's undo manager itself.
    weak var files: FileUndoLog?
    /// When each group of steps to undo was made, and each to redo was undone, oldest first, as `UndoOrder` counts.
    /// One for every group, also an empty one, which takes an Undo of its own too.
    private var undoOrders: [Int] = []
    private var redoOrders: [Int] = []
    private var isReplaying = false
    private var isOpeningGroup = false

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        guard acceptsRegistrations else { return }
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
    }

    override func prepare(withInvocationTarget target: Any) -> Any {
        acceptsRegistrations ? super.prepare(withInvocationTarget: target) : sink.prepare(withInvocationTarget: target)
    }

    override func beginUndoGrouping() {
        if groupingLevel == 0, !isOpeningGroup, !isReplaying, !isUndoing, !isRedoing {
            undoOrders.append(MainActor.assumeIsolated { UndoOrder.next() })
        }
        // A group opened by hand outside an event opens the event's group around it first, by calling this again:
        // one group, counted once.
        isOpeningGroup = true
        super.beginUndoGrouping()
        isOpeningGroup = false
    }

    override func removeAllActions() {
        guard allowsClearing else { return }
        super.removeAllActions()
        undoOrders.removeAll()
        redoOrders.removeAll()
    }

    override func removeAllActions(withTarget target: Any) {
        guard allowsClearing || target is EditorController else { return }
        super.removeAllActions(withTarget: target)
        // The steps are all the editor's.
        undoOrders.removeAll()
        redoOrders.removeAll()
    }

    /// Forgets everything: a new note is loaded.
    func clear() {
        allowsClearing = true
        removeAllActions()
        allowsClearing = false
    }

    /// A step was kept, which leaves nothing to redo.
    fileprivate func stepKept() {
        redoOrders.removeAll()
    }

    /// Whether the text has a step to take back, leaving the changes to files aside.
    var canUndoText: Bool { super.canUndo }

    #if DEBUG
    var debugOrders: String {
        "text undo \(undoOrders) \(super.canUndo) redo \(redoOrders) \(super.canRedo), files undo \(files?.nextUndo?.order ?? 0) redo \(files?.nextRedo?.order ?? 0)"
    }
    #endif

    /// The window's undo manager, when the change to files it would take back next is newer than the text's last step.
    private var filesFirst: UndoManager? {
        MainActor.assumeIsolated {
            guard let change = files?.nextUndo, let manager = change.manager, manager.canUndo else { return nil }
            guard super.canUndo, let text = undoOrders.last else { return manager }
            return change.order > text ? manager : nil
        }
    }

    /// The same for Redo: the one undone last comes back first.
    private var filesFirstForRedo: UndoManager? {
        MainActor.assumeIsolated {
            guard let change = files?.nextRedo, let manager = change.manager, manager.canRedo else { return nil }
            guard super.canRedo, let text = redoOrders.last else { return manager }
            return change.order > text ? manager : nil
        }
    }

    override var canUndo: Bool { super.canUndo || filesFirst != nil }
    override var canRedo: Bool { super.canRedo || filesFirstForRedo != nil }
    override var undoActionName: String { filesFirst?.undoActionName ?? super.undoActionName }
    override var redoActionName: String { filesFirstForRedo?.redoActionName ?? super.redoActionName }
    override var undoMenuItemTitle: String { filesFirst?.undoMenuItemTitle ?? super.undoMenuItemTitle }
    override var redoMenuItemTitle: String { filesFirstForRedo?.redoMenuItemTitle ?? super.redoMenuItemTitle }

    override func undo() {
        if let files = filesFirst { return files.undo() }
        guard super.canUndo else { return }
        if !undoOrders.isEmpty { undoOrders.removeLast() }
        replay { super.undo() }
        redoOrders.append(MainActor.assumeIsolated { UndoOrder.next() })
    }

    override func redo() {
        if let files = filesFirstForRedo { return files.redo() }
        guard super.canRedo else { return }
        if !redoOrders.isEmpty { redoOrders.removeLast() }
        replay { super.redo() }
        undoOrders.append(MainActor.assumeIsolated { UndoOrder.next() })
    }

    /// Undo or Redo, whose group of the steps that take them back again is dated here, not when it opens.
    private func replay(_ body: () -> Void) {
        isReplaying = true
        body()
        isReplaying = false
    }
}

/// One step of undo: at `location`, the text now `inserted` long was `removed` before.
final class UndoStep {
    var location: Int
    var inserted: Int
    var removed: String
    let selection: NSRange
    /// Typing goes on in the same step until the caret goes somewhere else.
    var isTyping: Bool

    init(location: Int, inserted: Int, removed: String, selection: NSRange, isTyping: Bool) {
        self.location = location
        self.inserted = inserted
        self.removed = removed
        self.selection = selection
        self.isTyping = isTyping
    }

    var end: Int { location + inserted }
}

extension EditorController {
    /// The text changed at `range` (as it is now), replacing `removed`: a step to undo, or part of the typing going on.
    func recordChange(_ range: NSRange, removed: String) {
        guard !isLoading else { return }
        let manager = undoStack
        let typing = !isPerformingEdit && !isReplayingUndo
        if typing, let step = openStep, step.isTyping, manager.canUndoText {
            // Typing on, or Backspace, right where the step ends.
            if removed.isEmpty, range.location == step.end {
                step.inserted += range.length
                return
            }
            let count = (removed as NSString).length
            if range.length == 0, range.location + count == step.end {
                if count <= step.inserted {
                    step.inserted -= count
                } else {
                    step.removed = (removed as NSString).substring(to: count - step.inserted) + step.removed
                    step.location -= count - step.inserted
                    step.inserted = 0
                }
                return
            }
            // What the keyboard replaces in what was just typed: marked text being composed, a word corrected.
            if range.location >= step.location, range.location + count <= step.end {
                step.inserted += range.length - count
                return
            }
        }
        let step = UndoStep(location: range.location, inserted: range.length, removed: removed, selection: previousSelection, isTyping: typing)
        openStep = step
        manager.acceptsRegistrations = true
        manager.registerUndo(withTarget: self) { editor in editor.revert(step) }
        manager.acceptsRegistrations = false
        if !manager.isUndoing, !manager.isRedoing { manager.stepKept() }
    }

    /// Puts back what a step changed, which records the opposite step for redo.
    private func revert(_ step: UndoStep) {
        guard step.end <= storage.length else { return }
        isReplayingUndo = true
        let caret = NSRange(location: step.location + (step.removed as NSString).length, length: 0)
        storage.replaceCharacters(in: NSRange(location: step.location, length: step.inserted), with: step.removed)
        isReplayingUndo = false
        openStep = nil
        setSelection(undoStack.isUndoing && step.selection.upperBound <= storage.length ? step.selection : caret)
        textChanged()
        scrollCaretIntoView()
    }

    /// The caret moved somewhere else than where typing goes on: what is typed next is a step of its own.
    func closeTypingStep(at selection: NSRange) {
        guard let step = openStep, selection.length > 0 || selection.location != step.end else { return }
        openStep = nil
    }
}
#endif
