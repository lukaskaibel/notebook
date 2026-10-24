#if os(macOS)
import AppKit
import SwiftUI

/// A dropdown, as Issues has them: a Liquid Glass panel without an arrow that opens right under what was clicked, takes
/// the keyboard straight away, and closes when you pick, press Escape or click elsewhere. A second click on what opened
/// it closes it, as it does a menu.
@MainActor
enum Dropdown {
    private static var panel: DropdownPanel?
    /// The click that last closed a dropdown from outside: where it was on screen, what the dropdown was opened from,
    /// and when. The same click then reaches what is under it; when that is what opened the dropdown, it stays closed.
    private static var dismissal: (click: NSPoint, anchor: NSRect, time: TimeInterval)?

    static var isOpen: Bool { panel != nil }

    /// As round as the system's menus.
    static let cornerRadius: CGFloat = 14

    /// Opens a dropdown under `rect`, given in `view`'s coordinates, or over it when there is no room below. Whatever
    /// dropdown is open closes first.
    @discardableResult
    static func show<Content: View>(below rect: NSRect, in view: NSView, onClose: @escaping () -> Void = {},
                                    @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) -> DropdownPanel? {
        guard let window = view.window else { return nil }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        if isSecondClick(on: anchor) {
            DispatchQueue.main.async(execute: onClose)
            return nil
        }
        close()
        let handle = PanelHandle()
        let close: () -> Void = { if let panel = handle.panel { Dropdown.close(panel) } }
        let radius = cornerRadius
        let root = content(close)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.theme(Theme.popoverBorder).opacity(0.35), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .fixedSize()
        let panel = DropdownPanel()
        panel.hosting.rootView = AnyView(root)
        let size = panel.hosting.fittingSize
        panel.hosting.lastSize = size

        let screen = window.screen?.visibleFrame ?? .infinite
        // Under the anchor, left edges in line; above it when there's no room below.
        var origin = NSPoint(x: anchor.minX - 4, y: anchor.minY - 4 - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.anchor = anchor
        panel.opener = window
        handle.panel = panel
        // The edge next to what was clicked stays where it is as the dropdown grows or shrinks: its top under it, its
        // bottom over it. AppKit keeps the top where it is when the content changes size on its own.
        let opensUpward = origin.y > anchor.minY
        let edge = opensUpward ? origin.y : origin.y + size.height
        panel.hosting.onFittingSizeChange = { [weak panel] fitting in
            guard let panel, fitting.height > 0 else { return }
            let frame = NSRect(x: panel.frame.minX, y: opensUpward ? edge : edge - fitting.height, width: fitting.width, height: fitting.height)
            panel.setFrame(frame, display: true, animate: false)
        }
        // The window's look, and with it the app's when the window has none of its own: it changes with the app's.
        panel.appearance = window.appearance
        panel.onClose = onClose
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        return panel
    }

    /// Whether this click is on what the open dropdown, or the one the click just closed, was opened from: then it
    /// closes it, as a second click on a menu's button does, instead of opening it again.
    private static func isSecondClick(on anchor: NSRect) -> Bool {
        func same(_ other: NSRect) -> Bool {
            abs(other.minX - anchor.minX) < 1 && abs(other.minY - anchor.minY) < 1 && abs(other.width - anchor.width) < 1
        }
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
              anchor.insetBy(dx: -1, dy: -1).contains(screenLocation(of: event)) else { return false }
        if let open = panel, same(open.anchor) {
            close()
            return true
        }
        // Buttons act on mouse up: the press already closed it.
        if let dismissal, ProcessInfo.processInfo.systemUptime - dismissal.time < 0.8,
           anchor.insetBy(dx: -1, dy: -1).contains(dismissal.click), same(dismissal.anchor) {
            Self.dismissal = nil
            return true
        }
        return false
    }

    private static func screenLocation(of event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    /// Closes the open dropdown.
    static func close() {
        if let panel { close(panel) }
    }

    static func close(_ closing: DropdownPanel) {
        guard closing === panel else { return }
        panel = nil
        let opener = closing.opener
        closing.parent?.removeChildWindow(closing)
        closing.orderOut(nil)
        closing.hosting.onFittingSizeChange = nil
        closing.onClose()
        closing.onClose = {}
        // Back to the window it was opened from, so its keys work again.
        if let opener, opener.isVisible { opener.makeKey() }
    }

    fileprivate static func panelDidResignKey(_ resigned: DropdownPanel) {
        // A click elsewhere takes the keyboard away while its button is still down.
        let click = NSApp.currentEvent.flatMap { event in
            [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) ? screenLocation(of: event) : nil
        } ?? (NSEvent.pressedMouseButtons != 0 ? NSEvent.mouseLocation : nil)
        DispatchQueue.main.async {
            guard resigned === panel else { return }
            if let click { dismissal = (click, resigned.anchor, ProcessInfo.processInfo.systemUptime) }
            close(resigned)
        }
    }

    #if DEBUG
    /// The open dropdown, for the debug remote.
    static var debugPanel: DropdownPanel? { panel }

    /// The debug remote's clicks reach the app in the background, where AppKit never takes the keyboard away from an
    /// open dropdown; this does what that would for a click at `point` on screen.
    static func debugClick(at point: NSPoint) {
        guard let panel, !panel.frame.contains(point) else { return }
        dismissal = (point, panel.anchor, ProcessInfo.processInfo.systemUptime)
        close(panel)
    }
    #endif
}

private final class PanelHandle {
    weak var panel: DropdownPanel?
}

/// A hosting view that reports when its content wants another size.
final class DropdownHostingView: NSHostingView<AnyView> {
    var onFittingSizeChange: ((NSSize) -> Void)?
    /// The size last measured.
    var lastSize: NSSize = .zero
    private var measuring = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Measured once the change is over, not for each part of it.
        guard !measuring else { return }
        measuring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            measuring = false
            let size = fittingSize
            guard size != lastSize else { return }
            lastSize = size
            onFittingSizeChange?(size)
        }
    }
}

final class DropdownPanel: NSPanel {
    let hosting = DropdownHostingView(rootView: AnyView(EmptyView()))
    var onClose: () -> Void = {}
    /// What it was opened from, on screen.
    var anchor: NSRect = .zero
    weak var opener: NSWindow?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Liquid Glass, as the system's own menus are drawn now.
        let glass = NSGlassEffectView()
        glass.cornerRadius = Dropdown.cornerRadius
        glass.contentView = hosting
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A click anywhere else closes it, as a menu would.
    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { Dropdown.panelDidResignKey(self) }
    }

    /// Escape, when nothing inside handled it.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { Dropdown.close(self) }
    }
}

// MARK: - SwiftUI

extension View {
    /// Shows a dropdown under this view while `isPresented` is true.
    func dropdown<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content) -> some View {
        background(DropdownAnchor(isPresented: isPresented, content: content))
    }
}

private struct DropdownAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var content: (_ close: @escaping () -> Void) -> Content

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        // A dropdown that closed itself set the binding to false, but until the view that owns the binding is drawn
        // again, this is handed what it held before, which would open it again at once.
        if !isPresented { view.closedItself = false }
        if isPresented, !view.isShowing, !view.closedItself {
            view.isShowing = true
            let binding = $isPresented
            view.panel = Dropdown.show(below: view.bounds, in: view, onClose: { [weak view] in
                view?.isShowing = false
                view?.closedItself = true
                binding.wrappedValue = false
            }, content: content)
        } else if !isPresented, view.isShowing, let panel = view.panel {
            Dropdown.close(panel)
            view.closedItself = false
        }
    }

    final class AnchorView: NSView {
        var isShowing = false
        /// The dropdown closed itself, and its owner hasn't been drawn closed since.
        var closedItself = false
        weak var panel: DropdownPanel?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// What opened it is gone: so is the dropdown.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, isShowing, let panel { Dropdown.close(panel) }
        }
    }
}
#endif
