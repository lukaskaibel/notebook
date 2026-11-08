#if os(macOS)
import AppKit
import SwiftUI

/// A dropdown, as Issues has them: a Liquid Glass panel without an arrow that opens right under what was clicked, takes
/// the keyboard straight away, and closes when you pick, press Escape or click elsewhere. A second click on what opened
/// it closes it, as it does a menu. A dropdown opened from inside another one stacks on top of it, as a menu's submenu
/// does; closing it hands the keyboard back to the one underneath.
@MainActor
enum Dropdown {
    /// Open dropdowns, the first opened from a window and each further one from the one before.
    private static var panels: [DropdownPanel] = []
    /// Panels kept for the next dropdowns, with their glass and a place for content: making a window and its views
    /// took a third of the time a submenu needed to open.
    private static var spares: [DropdownPanel] = []
    /// The click that last closed dropdowns from outside: where it was on screen, what those dropdowns were opened
    /// from, and when. The same click then reaches what is under it; when that is what opened one of them, it stays
    /// closed.
    private static var dismissal: (click: NSPoint, anchors: [NSRect], time: TimeInterval)?

    static var isOpen: Bool { !panels.isEmpty }

    /// As round as the system's menus.
    static let cornerRadius: CGFloat = 14

    #if DEBUG
    /// Set by the debug remote to follow what dropdowns do.
    static var trace: ((String) -> Void)?
    #else
    static let trace: ((String) -> Void)? = nil
    #endif

    /// Opens a dropdown at `rect`, given in `view`'s coordinates: under it, over it, or beside it as a submenu. From a
    /// view inside an open dropdown it opens on top of that one; from anywhere else it replaces whatever is open. A
    /// submenu opened under the pointer leaves the keyboard with its menu (`takesKey` false): its glass would otherwise
    /// turn dim with every row the pointer passes, and typing still reaches the submenu once the pointer is in it.
    @discardableResult
    static func show<Content: View>(below rect: NSRect, in view: NSView, placement: DropdownPlacement = .below, takesKey: Bool = true,
                                    onClose: @escaping () -> Void = {},
                                    @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) -> DropdownPanel? {
        guard let window = view.window else { return nil }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        if isSecondClick(on: anchor, from: window) {
            trace?("show: a second click on what opened it; it closes")
            DispatchQueue.main.async(execute: onClose)
            return nil
        }
        if let host = window as? DropdownPanel {
            // A closed dropdown's content lives on until its panel is used again; nothing opens from it meanwhile.
            guard let index = panels.firstIndex(where: { $0 === host }) else {
                DispatchQueue.main.async(execute: onClose)
                return nil
            }
            close(from: index + 1)
        } else {
            close()
        }
        let handle = PanelHandle()
        let close: () -> Void = { if let panel = handle.panel { Dropdown.close(panel) } }
        let radius = cornerRadius
        let root = content(close)
            // What fields and lit rows inside round their corners along: `ConcentricRectangle`.
            .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.theme(Theme.popoverBorder).opacity(0.35), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .fixedSize()
        // A panel kept from before has its content view in place; a new one is measured before it gets it, so it is
        // laid out once, at its size.
        let panel = spares.popLast() ?? DropdownPanel()
        let hosting = panel.hosting
        hosting.rootView = AnyView(root)
        let size = hosting.fittingSize
        hosting.lastSize = size

        let screen = window.screen?.visibleFrame ?? .infinite
        var origin: NSPoint
        switch placement {
        case .below, .above:
            // Under the anchor, left edges in line, or right edges for a button at the right of its window, as the
            // toolbar's ••• is; above it when asked or when there's no room below.
            origin = NSPoint(x: anchor.minX - 4, y: anchor.minY - 4 - size.height)
            if !(window is DropdownPanel), anchor.midX > window.frame.minX + window.frame.width * 0.6 { origin.x = anchor.maxX + 4 - size.width }
            if placement == .above || origin.y < screen.minY + 4 { origin.y = anchor.maxY + 4 }
            // Neither: as high as there is room for.
            if origin.y + size.height > screen.maxY - 4 { origin.y = max(screen.minY + 4, screen.maxY - 4 - size.height) }
        case .trailing:
            // Right of the row, its first row level with it (the panel has 6 pt above its rows); left of it when
            // there's no room on the right.
            origin = NSPoint(x: anchor.maxX + 6, y: anchor.maxY + 6 - size.height)
            if origin.x + size.width > screen.maxX - 4 { origin.x = anchor.minX - 6 - size.width }
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - 8 - size.height)
        case .pointer:
            // A right-click menu: its top left corner at the pointer, or its bottom left where there's no room below.
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
            if origin.y < screen.minY + 4 { origin.y = min(anchor.minY, screen.maxY - 4 - size.height) }
            if origin.y < screen.minY + 4 { origin.y = screen.minY + 4 }
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.attachContent()
        panel.anchor = anchor
        panel.opener = window
        // A submenu comes and goes at once, as the system's do: fading in, it seemed slow to open.
        panel.animationBehavior = window is DropdownPanel ? .none : .utilityWindow
        handle.panel = panel
        // The edge next to what was clicked stays where it is as the dropdown grows or shrinks: its top under it, its
        // bottom over it. AppKit keeps the top where it is when the content changes size on its own.
        let opensUpward = origin.y >= anchor.minY - 1
        let edge = opensUpward ? origin.y : origin.y + size.height
        hosting.onFittingSizeChange = { [weak panel] fitting in
            guard let panel, fitting.height > 0 else { return }
            let frame = NSRect(x: panel.frame.minX, y: opensUpward ? edge : edge - fitting.height, width: fitting.width, height: fitting.height)
            panel.setFrame(frame, display: true, animate: false)
        }
        // The window's look, and with it the app's when the window has none of its own: it changes with the app's.
        panel.appearance = window.appearance
        panel.onClose = onClose
        window.addChildWindow(panel, ordered: .above)
        if takesKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        // A panel used again had the shadow of the dropdown before.
        panel.invalidateShadow()
        panels.append(panel)
        if spares.isEmpty, !(window is DropdownPanel) {
            // One ready for a submenu, made once the dropdown is on screen; submenus that close are kept for the next.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if isOpen, spares.isEmpty { spares.append(DropdownPanel()) }
            }
        }
        trace?("show: \(panels.count) open, nested=\(window is DropdownPanel)")
        return panel
    }

    /// Whether this click is on what the open dropdown, or the one a click just closed, was opened from: then it
    /// closes it, as a second click on a menu's button does, instead of opening it again.
    private static func isSecondClick(on anchor: NSRect, from window: NSWindow) -> Bool {
        func same(_ other: NSRect) -> Bool {
            abs(other.minX - anchor.minX) < 1 && abs(other.minY - anchor.minY) < 1 && abs(other.width - anchor.width) < 1
        }
        let event = NSApp.currentEvent
        // Opened on mouse down: the dropdown is still open.
        if let event, [.leftMouseDown, .leftMouseUp].contains(event.type),
           anchor.insetBy(dx: -1, dy: -1).contains(screenLocation(of: event)),
           !(window is DropdownPanel), let open = panels.first, same(open.anchor) {
            close()
            return true
        }
        // Opened on mouse up, as buttons do: the press already closed it. SwiftUI runs a button's action once the
        // events waiting behind the release are handled, so the event at hand is often the pointer moving on: what
        // counts is where the press was. A key that opens the same dropdown is never a second click.
        if event?.type != .keyDown, let dismissal, ProcessInfo.processInfo.systemUptime - dismissal.time < 0.8,
           anchor.insetBy(dx: -1, dy: -1).contains(dismissal.click), dismissal.anchors.contains(where: same) {
            Self.dismissal = nil
            return true
        }
        return false
    }

    private static func noteDismissal(by click: NSPoint, closing: [DropdownPanel]) {
        guard !closing.isEmpty else { return }
        dismissal = (click, closing.map(\.anchor), ProcessInfo.processInfo.systemUptime)
    }

    private static func screenLocation(of event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    /// Closes every open dropdown.
    static func close() {
        close(from: 0)
    }

    /// Closes this dropdown and any opened from it.
    static func close(_ panel: DropdownPanel) {
        if let index = panels.firstIndex(where: { $0 === panel }) { close(from: index) }
    }

    private static func close(from index: Int) {
        guard panels.indices.contains(index) else { return }
        trace?("close from \(index) of \(panels.count)")
        let closing = panels[index...].reversed()
        let underneath = panels[index].opener
        panels.removeSubrange(index...)
        for panel in closing {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.onClose()
            keep(panel)
        }
        // Back to what the dropdown was opened from, so its keys work again.
        if let underneath, underneath.isVisible { underneath.makeKey() }
    }

    /// Keeps a closed dropdown's panel for the next one, emptied once it has faded out.
    private static func keep(_ panel: DropdownPanel) {
        panel.onClose = {}
        panel.opener = nil
        panel.hosting.onFittingSizeChange = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.animationBehavior == .none ? 0 : 0.3)) {
            guard !panel.isVisible, !panels.contains(where: { $0 === panel }) else { return }
            panel.hosting.rootView = AnyView(EmptyView())
            if spares.count < 2 { spares.append(panel) }
        }
    }

    /// The open dropdown under a point on screen, the top one where they overlap.
    static func panel(at point: NSPoint) -> DropdownPanel? {
        panels.last { $0.frame.contains(point) }
    }

    /// The dropdown opened from `panel`, such as the submenu open beside a menu.
    static func panel(openedFrom panel: NSWindow) -> DropdownPanel? {
        panels.first { $0.opener === panel }
    }

    /// Gives the keyboard to the dropdown opened from `panel`.
    static func focusPanel(openedFrom panel: NSWindow) {
        self.panel(openedFrom: panel)?.makeKey()
    }

    /// Keys pressed while the pointer is in a submenu that hasn't got the keyboard go to that submenu, which takes the
    /// keyboard from then on: typing finds what the pointer is on, as it would if the submenu had it all along.
    fileprivate static func submenuForKeys(from panel: DropdownPanel) -> DropdownPanel? {
        guard let index = panels.firstIndex(where: { $0 === panel }),
              let under = panels.lastIndex(where: { $0.frame.contains(NSEvent.mouseLocation) }), under > index else { return nil }
        return panels[under]
    }

    fileprivate static func panelDidResignKey(_ resigned: DropdownPanel) {
        // A click elsewhere takes the keyboard away while its button is still down.
        let click = NSApp.currentEvent.flatMap { event in
            [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) ? screenLocation(of: event) : nil
        } ?? (NSEvent.pressedMouseButtons != 0 ? NSEvent.mouseLocation : nil)
        // The new key window is known only once AppKit has finished switching.
        DispatchQueue.main.async {
            guard let index = panels.firstIndex(where: { $0 === resigned }) else { return }
            let key = NSApp.keyWindow
            let closing = panels.firstIndex(where: { $0 === key }).map { keyIndex in keyIndex < index ? Array(panels[(keyIndex + 1)...]) : [] } ?? panels
            if let click { noteDismissal(by: click, closing: closing) }
            if let keyIndex = panels.firstIndex(where: { $0 === key }) {
                // A click back in a dropdown further down closes the ones on top of it.
                if keyIndex < index { close(from: keyIndex + 1) }
            } else {
                // A click anywhere else closes them all, as a menu would.
                close()
            }
        }
    }

    #if DEBUG
    /// The dropdown on top, for the debug remote.
    static var debugPanel: DropdownPanel? { panels.last }
    /// Every open dropdown, the first opened first.
    static var debugPanels: [DropdownPanel] { panels }

    /// The debug remote's clicks reach the app in the background, where AppKit never takes the keyboard away from an
    /// open dropdown; this does to the dropdowns what that would for a click at `point` on screen.
    static func debugClick(at point: NSPoint) {
        guard !panels.isEmpty else { return }
        if let index = panels.lastIndex(where: { $0.frame.contains(point) }) {
            guard index < panels.count - 1 else { return }
            noteDismissal(by: point, closing: Array(panels[(index + 1)...]))
            close(from: index + 1)
        } else {
            noteDismissal(by: point, closing: panels)
            close()
        }
    }
    #endif
}

/// Where a dropdown opens relative to what was clicked.
enum DropdownPlacement {
    /// Under it, or over it when there's no room below.
    case below
    /// Over it, for things at the bottom of the window.
    case above
    /// To its right, as a submenu of a menu row; to its left when there's no room on the right.
    case trailing
    /// With its top left corner at a point, as a right-click menu opens.
    case pointer
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
        // Measured once the change is over, not for each part of it: measuring lays the whole content out.
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
    /// What the dropdown shows, swapped when the panel is used again for another one.
    let hosting = DropdownHostingView(rootView: AnyView(EmptyView()))
    var onClose: () -> Void = {}
    /// What it was opened from, on screen.
    var anchor: NSRect = .zero
    /// The window it was opened from: the app's window, or the dropdown a submenu belongs to.
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Puts the content into the panel the first time it is used; a panel used again has it already.
    func attachContent() {
        guard hosting.window == nil else { return }
        // Liquid Glass, as the system's own menus are drawn now.
        let glass = NSGlassEffectView()
        glass.cornerRadius = Dropdown.cornerRadius
        glass.contentView = hosting
        contentView = glass
    }

    /// A click anywhere else closes it, as a menu would.
    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { Dropdown.panelDidResignKey(self) }
    }

    /// Escape, when nothing inside handled it.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { Dropdown.close(self) }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let submenu = MainActor.assumeIsolated({ Dropdown.submenuForKeys(from: self) }) {
            submenu.makeKey()
            submenu.sendEvent(event)
            return
        }
        // A click in a submenu opened under the pointer picks at once, as in a menu: a window without the keyboard
        // hands its first click only to views that ask for it.
        if [.leftMouseDown, .rightMouseDown].contains(event.type), !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

// MARK: - SwiftUI

extension View {
    /// Shows a dropdown under this view while `isPresented` is true, or over it or beside it; with `rect`, under or
    /// beside that part of the view, from its top left. `takesKey` false leaves the keyboard where it is, for a submenu
    /// opened under the pointer.
    func dropdown<Content: View>(isPresented: Binding<Bool>, placement: DropdownPlacement = .below, at rect: CGRect? = nil, takesKey: Bool = true,
                                 @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content) -> some View {
        background(DropdownAnchor(isPresented: isPresented, placement: placement, rect: rect, takesKey: takesKey, content: content))
    }
}

private struct DropdownAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var placement: DropdownPlacement
    var rect: CGRect?
    var takesKey: Bool
    var content: (_ close: @escaping () -> Void) -> Content

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        // A dropdown that closed itself set the binding to false, but until the view that owns the binding is drawn
        // again, this is handed what it held before, which would open it again at once.
        if !isPresented { view.closedItself = false }
        if isPresented, !view.isShowing, !view.closedItself {
            view.isShowing = true
            let binding = $isPresented
            view.panel = Dropdown.show(below: rect ?? view.bounds, in: view, placement: placement, takesKey: takesKey, onClose: { [weak view] in
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
