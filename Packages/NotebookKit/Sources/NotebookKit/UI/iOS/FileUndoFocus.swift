#if os(iOS)
import PencilKit
import SwiftUI
import UIKit

/// Shake to Undo, and ⌘Z on an iPhone, for changes to files. UIKit offers Undo for what has the focus, and in a list
/// nothing has it, so a note deleted with a swipe couldn't be brought back. Right after a change to files, unless
/// something is being typed in, this view takes the focus, with the files' undo manager, until something else does:
/// the search field or a note.
struct FileUndoFocus: UIViewRepresentable {
    let workspace: Workspace

    func makeUIView(context: Context) -> FileUndoView {
        let view = FileUndoView()
        view.workspace = workspace
        workspace.fileUndoView = view
        return view
    }

    func updateUIView(_ view: FileUndoView, context: Context) {
        view.workspace = workspace
        workspace.fileUndoView = view
    }
}

final class FileUndoView: UIView {
    weak var workspace: Workspace?

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { workspace?.fileUndoManager }

    /// Takes the focus for the files' Undo, unless something being typed or drawn in has it: a note, its title, a
    /// search field, a drawing, whose tool picker goes with the focus.
    func takeFocusIfFree() {
        guard window != nil, !isFirstResponder else { return }
        UIResponder.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.reportFound(_:)), to: nil, from: nil, for: nil)
        if UIResponder.found is UIKeyInput || UIResponder.found is PKCanvasView { return }
        becomeFirstResponder()
    }

    /// An iPhone has no menu bar to make ⌘Z and ⇧⌘Z Undo and Redo, as a text view's own keys do in a note.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undo(_:))),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redo(_:)))]
    }

    @objc func undo(_ sender: Any?) {
        workspace?.fileUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        workspace?.fileUndoManager.redo()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(undo(_:)): workspace?.fileUndoManager.canUndo ?? false
        case #selector(redo(_:)): workspace?.fileUndoManager.canRedo ?? false
        default: super.canPerformAction(action, withSender: sender)
        }
    }
}

extension UIResponder {
    /// The first responder, which UIKit doesn't name: an action sent to it says who it is.
    fileprivate static weak var found: UIResponder?

    @objc fileprivate func reportFound(_ sender: Any?) {
        UIResponder.found = self
    }
}
#endif
