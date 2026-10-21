#if os(iOS)
import GameController
import UIKit

/// Whether a keyboard is attached to the iPhone or iPad (a Magic Keyboard, a Bluetooth one). With one, a note shows its
/// Markdown next to the caret as on the Mac, where the arrow keys reach the marks and Delete takes them; on the touch
/// keyboard the bar above it turns styles on and off instead.
@MainActor
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()
    /// Posted when a keyboard is attached or taken away, or the touch keyboard comes or goes.
    static let didChange = Notification.Name("NotebookHardwareKeyboardDidChange")

    /// Whether you type with keys: a keyboard is attached and the touch keyboard isn't on screen (a keyboard can be
    /// attached and the touch keyboard brought up anyway, and the Simulator always has the Mac's).
    var isInUse: Bool { override ?? (isAttached && !isTouchKeyboardShown) }

    private(set) var isAttached = false {
        didSet { if isAttached != oldValue { changed() } }
    }

    /// The touch keyboard is on screen, as the text view's keyboard notifications tell.
    var isTouchKeyboardShown = false {
        didSet { if isTouchKeyboardShown != oldValue { changed() } }
    }

    /// For the debug remote: as if you typed with keys (true) or on the touch keyboard (false), whatever there is.
    var override: Bool? {
        didSet { changed() }
    }

    private init() {
        update()
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HardwareKeyboard.shared.update() }
            }
        }
    }

    private func update() {
        isAttached = GCKeyboard.coalesced != nil
    }

    /// A key of a keyboard was pressed, which the touch keyboard doesn't send: there is one.
    func keyWasPressed() {
        isAttached = true
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
#endif
