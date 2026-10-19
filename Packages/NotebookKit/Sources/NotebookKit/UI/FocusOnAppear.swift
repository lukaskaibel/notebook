#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Puts the keyboard focus into this text field as soon as it is on screen.
    ///
    /// SwiftUI's `@FocusState` request is sometimes dropped when a field appears in a window that is already key, as
    /// ⌘K's does, leaving the window itself as first responder: typing goes nowhere and Escape does nothing. This finds
    /// the AppKit text field behind the SwiftUI one and makes it first responder directly, trying again briefly until
    /// it sticks. As in Issues.
    func focusOnAppear(_ isActive: Bool = true) -> some View {
        background(FocusAnchor(isActive: isActive))
    }
}

private struct FocusAnchor: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.isActive = isActive
    }

    final class AnchorView: NSView {
        var isActive = true
        private var attempts = 0

        // Never in the way of clicks on the field it sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attempts = 0
            if window != nil { scheduleFocus(after: 0) }
        }

        private func scheduleFocus(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focus()
            }
        }

        private func focus() {
            guard isActive, let window, let field = textField(in: window) else { return }
            if let editor = window.firstResponder as? NSTextView, editor.delegate === field { return }
            window.makeFirstResponder(field)
            attempts += 1
            // Something may still take it away in the same moment; check again a few times.
            if attempts < 8 { scheduleFocus(after: 0.04) }
        }

        /// The editable text field whose frame contains this anchor's centre.
        private func textField(in window: NSWindow) -> NSTextField? {
            guard let content = window.contentView else { return nil }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var found: NSTextField?
            func search(_ view: NSView) {
                guard found == nil, !view.isHidden else { return }
                if let field = view as? NSTextField, field.isEditable, !(field is NSSearchField),
                   field.convert(field.bounds, to: nil).contains(center) {
                    found = field
                    return
                }
                view.subviews.forEach(search)
            }
            search(content)
            return found
        }
    }
}
#endif
