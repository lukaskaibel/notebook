#if os(iOS)
import PencilKit
import SwiftUI
import UIKit

/// Shake to Undo, and ⌘Z on an iPhone, for changes to files and to-dos. UIKit offers Undo for what has the focus, and
/// in a list nothing has it, so a note deleted with a swipe couldn't be brought back. Right after a change to files,
/// unless something is being typed in, this view takes the focus, with the files' undo manager, until something else
/// does: the search field or a note. Screens with nothing to type in, as To-dos, ask for it too
/// (`Workspace.takeUndoFocusIfFree`).
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

    /// The system's Undo alert, made here: UIKit's own asks what has the focus for its undo manager again once a
    /// button is tapped, when the alert has taken the focus, and its Undo did nothing.
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, UIApplication.shared.applicationSupportsShakeToEdit, let manager = undoManager,
              manager.canUndo || manager.canRedo, var presenter = window?.rootViewController else {
            return super.motionEnded(motion, with: event)
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        // Not over an alert: one at a time (`FileAlerts` turns shaking off while its alerts ask).
        guard !(presenter is UIAlertController) else { return }
        let undoes = manager.canUndo
        let alert = UIAlertController(title: undoes ? manager.undoMenuItemTitle : manager.redoMenuItemTitle, message: nil, preferredStyle: .alert)
        // The focus comes back here once the alert has gone, for the next shake.
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.takeFocusSoon() })
        if undoes, manager.canRedo {
            alert.addAction(UIAlertAction(title: "Redo", style: .default) { [weak self] _ in
                manager.redo()
                self?.takeFocusSoon()
            })
        }
        alert.addAction(UIAlertAction(title: undoes ? "Undo" : "Redo", style: .default) { [weak self] _ in
            if undoes { manager.undo() } else { manager.redo() }
            self?.takeFocusSoon()
        })
        presenter.present(alert, animated: true)
    }

    /// Once the alert has let the focus go.
    private func takeFocusSoon() {
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfFree() }
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
