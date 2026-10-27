#if os(iOS)
import SwiftUI
import UIKit

/// Shake to Undo, and the three-finger swipes, where nothing takes the keyboard: UIKit asks what has the focus for
/// its undo manager, and with nothing focused, as in To-dos while no to-do is edited, nothing answers, so a to-do
/// deleted, ticked or moved couldn't be taken back without a keyboard. This takes the focus then, and answers with the
/// undo manager of the changes to files, as Reminders does with its own. `focusing` changes when it should take the
/// focus again: once the keyboard has gone.
struct ShakeToUndo: UIViewRepresentable {
    let workspace: Workspace
    var focusing: Int

    func makeUIView(context: Context) -> Responder {
        Responder()
    }

    func updateUIView(_ view: Responder, context: Context) {
        view.workspace = workspace
        guard view.focusing != focusing else { return }
        view.focusing = focusing
        view.takeFocus()
    }

    final class Responder: UIView {
        weak var workspace: Workspace?
        var focusing = 0

        override var canBecomeFirstResponder: Bool { true }
        override var undoManager: UndoManager? { workspace?.fileUndoManager }

        /// The system's alert, made here: UIKit's own asks what has the focus for its undo manager again once a button
        /// is tapped, when the alert has taken the focus, and its Undo did nothing.
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake, UIApplication.shared.applicationSupportsShakeToEdit, let manager = undoManager,
                  manager.canUndo || manager.canRedo, var presenter = window?.rootViewController else {
                return super.motionEnded(motion, with: event)
            }
            while let presented = presenter.presentedViewController { presenter = presented }
            let undoes = manager.canUndo
            let alert = UIAlertController(title: undoes ? manager.undoMenuItemTitle : manager.redoMenuItemTitle, message: nil, preferredStyle: .alert)
            // The focus comes back here once the alert has gone, for the next shake.
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.takeFocus() })
            if undoes, manager.canRedo {
                alert.addAction(UIAlertAction(title: "Redo", style: .default) { [weak self] _ in
                    manager.redo()
                    self?.takeFocus()
                })
            }
            alert.addAction(UIAlertAction(title: undoes ? "Undo" : "Redo", style: .default) { [weak self] _ in
                if undoes { manager.undo() } else { manager.redo() }
                self?.takeFocus()
            })
            presenter.present(alert, animated: true)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            takeFocus()
        }

        /// Once what had the keyboard has let it go.
        func takeFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, !isFirstResponder else { return }
                becomeFirstResponder()
            }
        }
    }
}
#endif
