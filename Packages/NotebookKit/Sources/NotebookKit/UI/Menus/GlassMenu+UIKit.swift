#if os(iOS)
import Observation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

private extension NSDirectionalEdgeInsets {
    var uiEdgeInsets: UIEdgeInsets { UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing) }
}

/// The iPhone's and the iPad's menus, drawn in glass as the Mac's are: one panel with a symbol on the left of each
/// row, a soft highlight, and a field on top for long menus that brings up the keyboard only when tapped. Touched and
/// held, a row opens its menu under it; without lifting, the finger slides to an entry and picks it as it lets go, as in
/// the system's menus. A submenu opens beside the menu on the iPad and in its place on the iPhone. They float in a
/// window of their own over the app's, so a menu opened in a sheet or a popover is over it too.
@MainActor @Observable
final class TouchMenus {
    static let shared = TouchMenus()

    /// The open panels: the menu, and on the iPad the submenu open beside it.
    private(set) var panels: [TouchMenuPanel] = []
    /// What the menu is for, marked while it is open: a row touched and held.
    private(set) var source: UUID?

    @ObservationIgnored private var overlay: MenuOverlayWindow?
    @ObservationIgnored private weak var home: UIWindow?
    /// Where the last menu opened, for what it opens in turn, such as the share sheet.
    @ObservationIgnored private(set) var lastAnchor: CGRect = .zero
    var lastWindow: UIWindow? { home }
    @ObservationIgnored private var keyboardTop: CGFloat?
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()
    @ObservationIgnored private var dwell: DispatchWorkItem?
    /// The finger that opened the menu is still down: it can slide to an entry and pick it.
    @ObservationIgnored private var isTracking = false
    @ObservationIgnored private var trackedFrom: CGPoint?

    private init() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { TouchMenus.shared.keyboardMoved(to: frame) }
        }
    }

    var isOpen: Bool { !panels.isEmpty }

    /// How a menu is laid out on this device, at the size text is set in.
    var metrics: MenuMetrics {
        let scale = min(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17) / 17, 1.8)
        return isPad ? .pad(scale) : .phone(scale)
    }

    private var isPad: Bool { home?.traitCollection.horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad }

    /// Keys show where there are keys to press: on an iPad with a keyboard.
    var showsKeys: Bool { UIDevice.current.userInterfaceIdiom == .pad && HardwareKeyboard.shared.isAttached }

    /// How a menu opens from what it is for.
    enum Anchor {
        /// Under a button, or over it at the bottom of the screen; on the side of it the screen has room on.
        case button(CGRect)
        /// Under a row touched and held at `point`, or over it where there's no room below.
        case row(CGRect, at: CGPoint)
        /// With its corner at the pointer, as a right-click menu.
        case point(CGPoint)
    }

    #if DEBUG
    /// What the menus did lately, for the debug remote.
    @ObservationIgnored var trace: [String] = []
    #endif

    static var now: String { String(format: "%.2f", ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 100)) }

    func note(_ text: @autoclosure () -> String) {
        #if DEBUG
        trace.append(text())
        if trace.count > 30 { trace.removeFirst() }
        #endif
    }

    /// Opens a menu, in `window`'s coordinates. Whatever menu is open closes first.
    func show(_ entries: [MenuEntry], from anchor: Anchor, in window: UIWindow, source: UUID? = nil, tracking: Bool = false) {
        let level = MenuLevel(entries)
        note("show \(level.entries.count) entries from \(anchor) t=\(Self.now)")
        guard !level.entries.isEmpty else { return }
        closeNow()
        home = window
        switch anchor {
        case .button(let rect), .row(let rect, _): lastAnchor = rect
        case .point(let point): lastAnchor = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        let overlay = overlay(for: window)
        let panel = TouchMenuPanel(level: level, metrics: metrics)
        panel.frame = place(panel, from: anchor, in: overlay.bounds)
        panel.origin = origin(of: panel.frame, from: anchor)
        self.source = source
        isTracking = tracking
        trackedFrom = nil
        overlay.isHidden = false
        overlay.isUserInteractionEnabled = true
        selection.prepare()
        // Once the window is on screen, so the menu grows out of what opened it.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { self.panels = [panel] }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// Closes every open menu, `then` doing what was picked once it has started to go.
    func close(then action: (@MainActor () -> Void)? = nil) {
        guard isOpen else {
            action?()
            return
        }
        dwell?.cancel()
        isTracking = false
        source = nil
        let wasKey = overlay?.isKeyWindow == true
        // Touches go to the app at once, not only once the menu has faded.
        overlay?.isUserInteractionEnabled = false
        withAnimation(.easeOut(duration: 0.15)) { panels = [] } completion: { [weak self] in
            guard let self, self.panels.isEmpty else { return }
            self.overlay?.isHidden = true
            if wasKey, let home = self.home { home.makeKey() }
        }
        action?()
    }

    private func closeNow() {
        dwell?.cancel()
        panels = []
        source = nil
    }

    // MARK: Picking

    func activate(_ row: MenuLevel.Row, in panel: TouchMenuPanel) {
        guard row.entry.isEnabled else { return }
        switch row.entry.kind {
        case .action(let action):
            close(then: action)
        case .submenu:
            openSubmenu(row, of: panel)
        case .divider, .title:
            break
        }
    }

    /// The submenu of a row: beside the menu on the iPad, in its place on the iPhone.
    func openSubmenu(_ row: MenuLevel.Row, of panel: TouchMenuPanel) {
        guard let index = row.index, let submenu = panel.level.submenu(at: index), let bounds = overlay?.bounds else { return }
        dwell?.cancel()
        if isPad {
            guard let at = panels.firstIndex(where: { $0 === panel }) else { return }
            if panels.count > at + 1, panels[at + 1].level === submenu { return }
            panel.cursor.open = row.id
            let sub = TouchMenuPanel(level: submenu, metrics: metrics)
            let rowFrame = panel.rowFrames[row.id] ?? panel.frame
            let size = sub.size(in: bounds, keyboardTop: keyboardTop)
            var x = panel.frame.maxX + 6
            if x + size.width > bounds.maxX - 12 { x = panel.frame.minX - 6 - size.width }
            let y = min(max(rowFrame.minY - sub.topToFirstRow, bounds.minY + safeTop), (keyboardTop ?? bounds.maxY) - 12 - size.height)
            sub.frame = CGRect(x: max(12, x), y: y, width: size.width, height: size.height)
            sub.origin = UnitPoint(x: x > panel.frame.minX ? 0 : 1, y: 0)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                panels = Array(panels.prefix(at + 1)) + [sub]
            }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                panel.push(submenu, title: row.entry.title)
                panel.frame = refit(panel, in: bounds)
            }
        }
    }

    /// Back from a submenu shown in the menu's place.
    func goBack(in panel: TouchMenuPanel) {
        guard let bounds = overlay?.bounds else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            panel.pop()
            panel.frame = refit(panel, in: bounds)
        }
    }

    /// Closes the submenus open beside `panel`, which the pointer or a finger went back to.
    func closeSubmenus(after panel: TouchMenuPanel) {
        guard let at = panels.firstIndex(where: { $0 === panel }), panels.count > at + 1 else { return }
        panel.cursor.open = nil
        withAnimation(.easeOut(duration: 0.12)) { panels = Array(panels.prefix(at + 1)) }
    }

    /// A row the pointer rests on: its submenu opens after a moment, another's closes.
    func hover(_ row: MenuLevel.Row, in panel: TouchMenuPanel) {
        panel.cursor.key = row.id
        dwell?.cancel()
        guard isPad else { return }
        if row.entry.hasSubmenu {
            let work = DispatchWorkItem { [weak self] in self?.openSubmenu(row, of: panel) }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        } else if panel.cursor.open != nil {
            closeSubmenus(after: panel)
        }
    }

    // MARK: The finger that opened it

    /// The finger moved, still down after touching and holding: the row under it lights up.
    func track(_ point: CGPoint) {
        guard isTracking else { return }
        if trackedFrom == nil { trackedFrom = point }
        guard let start = trackedFrom, hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        var lit: (panel: TouchMenuPanel, row: MenuLevel.Row)?
        for panel in panels.reversed() where panel.frame.contains(point) {
            if let row = panel.row(at: point) { lit = (panel, row) }
            break
        }
        for panel in panels where panel !== lit?.panel { if panel.cursor.key != nil { panel.cursor.key = nil } }
        guard let lit else { return }
        if lit.panel.cursor.key != lit.row.id {
            lit.panel.cursor.key = lit.row.id
            if lit.row.entry.isChoosable { selection.selectionChanged() }
            dwell?.cancel()
            if lit.row.entry.hasSubmenu {
                let work = DispatchWorkItem { [weak self] in self?.openSubmenu(lit.row, of: lit.panel) }
                dwell = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (isPad ? 0.25 : 0.5), execute: work)
            }
        }
    }

    /// The finger let go: on an entry, it is picked; anywhere else the menu stays open for a tap.
    func release(at point: CGPoint) {
        guard isTracking else { return }
        isTracking = false
        dwell?.cancel()
        for panel in panels.reversed() where panel.frame.contains(point) {
            if let row = panel.row(at: point), panel.cursor.key == row.id, row.entry.isChoosable {
                activate(row, in: panel)
            }
            return
        }
        for panel in panels { panel.cursor.key = nil }
    }

    /// The finger went on to something else, such as dragging the row: the menu goes.
    func cancelTracking() {
        guard isTracking else { return }
        close()
    }

    // MARK: Where it goes

    private var safeTop: CGFloat { (home?.safeAreaInsets.top ?? 0) + 4 }

    private func place(_ panel: TouchMenuPanel, from anchor: Anchor, in bounds: CGRect) -> CGRect {
        let size = panel.size(in: bounds, keyboardTop: keyboardTop)
        let insets = home?.safeAreaInsets ?? .zero
        let top = bounds.minY + insets.top + 4
        let bottom = min(keyboardTop ?? bounds.maxY, bounds.maxY - insets.bottom) - 8
        let left = bounds.minX + max(insets.left, 12)
        let right = bounds.maxX - max(insets.right, 12)
        var origin: CGPoint
        switch anchor {
        case .button(let rect):
            origin = CGPoint(x: rect.midX > bounds.midX ? rect.maxX - size.width : rect.minX, y: rect.maxY + 8)
            if origin.y + size.height > bottom { origin.y = rect.minY - 8 - size.height }
        case .row(let rect, let point):
            origin = CGPoint(x: max(rect.minX + 16, point.x - size.width * 0.35), y: rect.maxY + 6)
            if origin.y + size.height > bottom { origin.y = rect.minY - 6 - size.height }
            if origin.y < top { origin.y = min(max(point.y - size.height / 2, top), bottom - size.height) }
        case .point(let point):
            origin = CGPoint(x: point.x, y: point.y + 4)
            if origin.y + size.height > bottom { origin.y = point.y - 4 - size.height }
        }
        origin.x = min(max(origin.x, left), right - size.width)
        origin.y = min(max(origin.y, top), bottom - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// Where the menu grows from: the corner nearest what opened it.
    private func origin(of frame: CGRect, from anchor: Anchor) -> UnitPoint {
        let point: CGPoint
        switch anchor {
        case .button(let rect): point = CGPoint(x: rect.midX, y: rect.midY)
        case .row(_, let at): point = at
        case .point(let at): point = at
        }
        return UnitPoint(x: min(max((point.x - frame.minX) / max(frame.width, 1), 0), 1), y: point.y < frame.midY ? 0 : 1)
    }

    /// The same panel with other rows: as tall as they need, its edge next to what opened it where it was.
    private func refit(_ panel: TouchMenuPanel, in bounds: CGRect) -> CGRect {
        var size = panel.size(in: bounds, keyboardTop: keyboardTop)
        var frame = panel.frame
        let bottom = min(keyboardTop ?? bounds.maxY, bounds.maxY - (home?.safeAreaInsets.bottom ?? 0)) - 8
        if panel.origin.y > 0.5 {
            // Opened upward: its bottom stays.
            frame.origin.y = frame.maxY - size.height
        } else {
            // Opened downward: its top stays, and it scrolls rather than move, while there's room for a few rows.
            size.height = min(size.height, max(bottom - frame.minY, panel.metrics.row * 4))
        }
        frame.size = size
        frame.origin.y = min(max(frame.origin.y, bounds.minY + safeTop), bottom - size.height)
        return frame
    }

    private func keyboardMoved(to frame: CGRect?) {
        if let frame, let window = home {
            let inWindow = window.convert(frame, from: window.screen.coordinateSpace)
            keyboardTop = inWindow.minY < window.bounds.maxY - 1 ? inWindow.minY : nil
        } else {
            keyboardTop = nil
        }
        refitPanels()
    }

    /// The open panels as tall as what they show now, such as what typing found, and above the keyboard.
    func refitPanels() {
        guard let bounds = overlay?.bounds, isOpen else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            for panel in panels { panel.frame = refit(panel, in: bounds) }
        }
    }

    private func overlay(for window: UIWindow) -> MenuOverlayWindow {
        if let overlay, overlay.windowScene === window.windowScene {
            overlay.frame = window.frame
            return overlay
        }
        overlay?.isHidden = true
        let made = MenuOverlayWindow(windowScene: window.windowScene!)
        made.frame = window.frame
        made.windowLevel = .normal + 1
        let host = UIHostingController(rootView: TouchMenuOverlay(menus: self))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        made.rootViewController = host
        made.isHidden = true
        overlay = made
        return made
    }

    #if DEBUG
    /// The open menus' rows, for the debug remote.
    var debugDescription: String {
        "overlay hidden=\(overlay?.isHidden ?? true) touches=\(overlay?.isUserInteractionEnabled ?? false) key=\(overlay?.isKeyWindow ?? false)\n"
            + trace.map { "  · " + $0 }.joined(separator: "\n") + "\n" + panels.enumerated().map { number, panel in
            "panel \(number) \(Int(panel.frame.minX)),\(Int(panel.frame.minY)) \(Int(panel.frame.width))x\(Int(panel.frame.height)): "
                + panel.rows.map { row in (row.entry.isDivider ? "—" : row.entry.title) + (panel.cursor.key == row.id ? "*" : "") }.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    /// Picks the entry with this title in the menu on top, as a tap would.
    func debugPick(_ title: String) -> Bool {
        guard let panel = panels.last, let row = panel.rows.first(where: { $0.entry.title == title }) else { return false }
        activate(row, in: panel)
        return true
    }

    func debugType(_ text: String) {
        panels.last?.query = text
    }
    #endif
}

/// One panel of a menu: its entries, the submenus shown in its place on the iPhone, what is typed, the lit row and
/// where its rows are.
@MainActor @Observable
final class TouchMenuPanel: Identifiable {
    let id = UUID()
    private(set) var stack: [(level: MenuLevel, title: String?)]
    var query = ""
    var frame: CGRect = .zero
    /// Where it grows from as it opens.
    var origin = UnitPoint.top
    let metrics: MenuMetrics
    @ObservationIgnored let cursor = MenuCursor<Int>()
    /// The rows' frames in the window, for the finger sliding over them.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]

    init(level: MenuLevel, metrics: MenuMetrics) {
        stack = [(level, nil)]
        self.metrics = metrics
    }

    var level: MenuLevel { stack.last!.level }
    var title: String? { stack.last!.title }
    var rows: [MenuLevel.Row] { level.rows(for: query) }

    /// A field to type in, for a menu long enough to need one.
    /// On a phone's or a tablet's screen only for a long menu: a short one reads at a glance.
    var showsField: Bool { level.isLonger(than: 11) || level.placeholder != "Type to find…" }

    func push(_ level: MenuLevel, title: String) {
        stack.append((level, title))
        query = ""
        cursor.key = nil
        rowFrames = [:]
    }

    func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        query = ""
        cursor.key = nil
        rowFrames = [:]
    }

    func row(at point: CGPoint) -> MenuLevel.Row? {
        guard let id = rowFrames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return rows.first { $0.id == id }
    }

    /// From the panel's top to its first row.
    var topToFirstRow: CGFloat {
        metrics.outer + (title != nil ? metrics.row : 0) + (showsField ? metrics.field + metrics.outer - 2 : 0)
    }

    /// As big as its rows need, and no taller than the screen has room for.
    func size(in bounds: CGRect, keyboardTop: CGFloat?) -> CGSize {
        let room = (keyboardTop ?? bounds.maxY) - bounds.minY - 120
        let height = topToFirstRow + max(metrics.height(of: rows), metrics.row) + metrics.outer
        return CGSize(width: min(metrics.width, bounds.width - 24), height: min(height, max(room, metrics.row * 4)))
    }
}

/// A window over the app's for the open menus: it takes every touch while a menu is open, so a tap anywhere else
/// closes it, as the system's menus do.
final class MenuOverlayWindow: UIWindow {}

/// What the overlay window shows: the open panels, over a ground that closes them when touched.
private struct TouchMenuOverlay: View {
    let menus: TouchMenus
    @State private var shownSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A touch anywhere else closes the menu as it comes down, as the system's do.
            Color.black.opacity(0.0001)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in menus.close() })
                .accessibilityHidden(true)
            ForEach(menus.panels) { panel in
                TouchMenuPanelView(panel: panel, menus: menus)
                    .frame(width: panel.frame.width, height: panel.frame.height, alignment: .top)
                    .containerShape(RoundedRectangle(cornerRadius: panel.metrics.cornerRadius, style: .continuous))
                    .background(Color.theme(Theme.menuBackdrop))
                    .clipShape(RoundedRectangle(cornerRadius: panel.metrics.cornerRadius, style: .continuous))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: panel.metrics.cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
                    .offset(x: panel.frame.minX, y: panel.frame.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: panel.origin)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Turned or resized: the menu was for where things were.
            if size != shownSize, shownSize != .zero, menus.isOpen { menus.close() }
            shownSize = size
        }
        .accessibilityAction(.escape) { menus.close() }
    }
}

/// One panel's content: the way back to the menu (iPhone), the field, and the rows, scrolling when there are more than
/// fit.
private struct TouchMenuPanelView: View {
    @Bindable var panel: TouchMenuPanel
    let menus: TouchMenus
    @FocusState private var focused: Bool

    private var metrics: MenuMetrics { panel.metrics }

    var body: some View {
        let rows = panel.rows
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: metrics.outer)
            if let title = panel.title {
                Button { menus.goBack(in: panel) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: metrics.fontSize, weight: .semibold))
                            .foregroundStyle(Color.theme(Theme.accent))
                        Text(title).font(.system(size: metrics.fontSize, weight: .semibold))
                            .foregroundStyle(Color.theme(Theme.menuText))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, metrics.outer + metrics.padding - 2)
                    .frame(height: metrics.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .transition(.opacity)
            }
            if panel.showsField {
                field(rows)
            }
            if rows.isEmpty {
                Text("No Matches")
                    .font(metrics.font)
                    .foregroundStyle(Color.theme(Theme.menuTextSecondary))
                    .padding(.horizontal, metrics.outer + metrics.padding)
                    .frame(height: metrics.row)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in self.row(row).id(row.id) }
                    }
                    .padding(.bottom, metrics.outer)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: panel.cursor.keyMoves) {
                    if let lit = panel.cursor.key { proxy.scrollTo(lit) }
                }
            }
        }
        .id(panel.stack.count)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func field(_ rows: [MenuLevel.Row]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.fontSize * 0.9, weight: .medium))
                .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            TextField(panel.level.placeholder, text: $panel.query)
                .font(metrics.font)
                .focused($focused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    let lit = panel.cursor.key ?? rows.first(where: \.entry.isChoosable)?.id
                    if let row = rows.first(where: { $0.id == lit }) { menus.activate(row, in: panel) }
                }
                .onKeyPress(.downArrow) {
                    panel.cursor.step(1, through: rows.filter(\.entry.isChoosable).map(\.id))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    panel.cursor.step(-1, through: rows.filter(\.entry.isChoosable).map(\.id))
                    return .handled
                }
                .onKeyPress(.escape) {
                    menus.close()
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .frame(height: metrics.field)
        .background(metrics.innerShape.fill(Color.theme(Theme.menuField)))
        .padding(.horizontal, metrics.outer)
        .padding(.bottom, metrics.outer - 2)
        .onChange(of: panel.query) {
            panel.cursor.key = panel.query.isEmpty ? nil : panel.rows.first(where: \.entry.isChoosable)?.id
            menus.refitPanels()
        }
    }

    @ViewBuilder
    private func row(_ row: MenuLevel.Row) -> some View {
        switch row.entry.kind {
        case .divider:
            MenuLine(metrics: metrics)
        case .title:
            MenuSectionTitle(title: row.entry.title, metrics: metrics)
        case .action, .submenu:
            Button {
                menus.activate(row, in: panel)
            } label: {
                TouchMenuRow(row: row, cursor: panel.cursor, metrics: metrics, showsKeys: menus.showsKeys, hasIcons: panel.level.hasIcons)
            }
            .buttonStyle(TouchMenuRowStyle(metrics: metrics))
            .disabled(!row.entry.isEnabled)
            .onHover { inside in
                if inside { menus.hover(row, in: panel) } else if panel.cursor.key == row.id { panel.cursor.key = nil }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panel.rowFrames[row.id] = $0 }
            .accessibilityLabel(row.path.isEmpty ? row.entry.title : (row.path + [row.entry.title]).joined(separator: ", "))
            .accessibilityValue(row.entry.isChecked ? "Checked" : "")
            .accessibilityHint(row.entry.hasSubmenu ? "Opens a submenu" : "")
        }
    }
}

/// A row, lit by the pointer, the finger sliding over it or the keys.
private struct TouchMenuRow: View {
    let row: MenuLevel.Row
    let cursor: MenuCursor<Int>
    let metrics: MenuMetrics
    let showsKeys: Bool
    let hasIcons: Bool

    var body: some View {
        MenuRowLabel(row: row, metrics: metrics, isLit: cursor.isLit(row.id), showsKeys: showsKeys, hasIcons: hasIcons)
    }
}

/// A row pressed shows lit while the finger is on it.
private struct TouchMenuRowStyle: ButtonStyle {
    let metrics: MenuMetrics

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    metrics.innerShape
                        .fill(Color.theme(Theme.menuHighlight))
                        .padding(.horizontal, metrics.outer)
                }
            }
    }
}

// MARK: - Opening them

extension View {
    /// The view's menu, drawn in glass: touched and held, or clicked with the pointer's other button, it opens under
    /// the view, which is marked while it is open. VoiceOver offers it as an action. The entries are made when it opens.
    func glassContextMenu(@MenuContent _ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(TouchContextMenu(entries: entries))
    }
}

private struct TouchContextMenu: ViewModifier {
    var entries: () -> [MenuEntry]
    @State private var id = UUID()
    @State private var frame: CGRect = .zero
    /// In a list's cell, which marks the whole row itself.
    @State private var isInCell = false

    func body(content: Content) -> some View {
        let marked = TouchMenus.shared.source == id
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .background {
                // Elsewhere, such as To-dos, the view itself is marked.
                if !isInCell {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.theme(Theme.menuHighlight))
                        .padding(-4)
                        .opacity(marked ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: marked)
                }
            }
            // In UIKit, beside the gestures the view has, such as dragging it, not after them: in SwiftUI's hands the
            // menu came only as the finger let go.
            .background(MenuPressAttacher(isMarked: marked, isInCell: $isInCell) { phase, point, window in
                switch phase {
                case .began:
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    TouchMenus.shared.show(entries(), from: .row(frame, at: point), in: window, source: id, tracking: true)
                case .changed:
                    TouchMenus.shared.track(point)
                case .ended:
                    TouchMenus.shared.release(at: point)
                case .cancelled:
                    TouchMenus.shared.cancelTracking()
                case .secondaryClick:
                    TouchMenus.shared.show(entries(), from: .point(point), in: window, source: id)
                }
            })
            .onAppear { TouchRecorder.install() }
            .accessibilityAction(named: "Show Menu") {
                guard let window = UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
                TouchMenus.shared.show(entries(), from: .row(frame, at: CGPoint(x: frame.minX + 40, y: frame.midY)), in: window, source: id)
            }
    }
}

/// Touching and holding a view, and clicking it with the pointer's other button, seen by UIKit recognizers on the list
/// cell (or the view) the view is in, for the touches inside it.
private struct MenuPressAttacher: UIViewRepresentable {
    enum Phase { case began, changed, ended, cancelled, secondaryClick }
    /// The menu is open for the view: a list's row shows it as the system's menus did, the whole cell highlighted.
    var isMarked: Bool
    @Binding var isInCell: Bool
    var action: (Phase, CGPoint, UIWindow) -> Void

    func makeUIView(context: Context) -> AttachView { AttachView() }

    func updateUIView(_ view: AttachView, context: Context) {
        view.action = action
        view.foundCell = { inCell in
            DispatchQueue.main.async { if isInCell != inCell { isInCell = inCell } }
        }
        view.isMarked = isMarked
        if let inCell = view.isInCell { view.foundCell(inCell) }
    }

    final class AttachView: UIView, UIGestureRecognizerDelegate {
        var action: (Phase, CGPoint, UIWindow) -> Void = { _, _, _ in }
        var foundCell: (Bool) -> Void = { _ in }
        /// Whether what takes its touches is a list's cell; nil until it is in a window.
        var isInCell: Bool? { host.map { $0 is UICollectionViewCell } }
        var isMarked = false {
            didSet {
                guard isMarked != oldValue, let cell = host as? UICollectionViewCell else { return }
                mark(cell, isMarked)
            }
        }
        private var markView: UIView?

        /// The whole row lit, as the system's menus lit it: in the shape the list gives its rows' backgrounds (the
        /// sidebar's capsule, a grouped list's full width), in the grey of a row a finger is on.
        private func mark(_ cell: UICollectionViewCell, _ on: Bool) {
            if on {
                let background = cell.backgroundConfiguration
                let view = markView ?? UIView()
                view.isUserInteractionEnabled = false
                view.backgroundColor = .systemGray4
                view.frame = cell.bounds.inset(by: background?.backgroundInsets.uiEdgeInsets ?? .zero)
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.layer.cornerRadius = min(background?.cornerRadius ?? 0, view.bounds.height / 2)
                view.layer.cornerCurve = .continuous
                view.alpha = 0
                cell.insertSubview(view, belowSubview: cell.contentView)
                markView = view
                UIView.animate(withDuration: 0.12) { view.alpha = 1 }
            } else if let view = markView {
                markView = nil
                UIView.animate(withDuration: 0.25) { view.alpha = 0 } completion: { _ in view.removeFromSuperview() }
            }
        }
        /// Learns of the finger coming down, and once it holds, keeps the touch from scrolling the list. A drag that
        /// takes the finger cancels it, which tells a drag from the finger sliding to an entry.
        private let press = MenuPressRecognizer()
        private let click = UITapGestureRecognizer()
        private weak var host: UIView?
        /// The finger on the view, followed by itself: its touch tells where it is and whether it is still down, which
        /// the recognizer's own calls didn't always.
        private weak var finger: UITouch?
        private var fingerStart: CGPoint = .zero
        private var hold: DispatchWorkItem?

        /// How long the finger rests before the menu comes.
        static let holdTime: TimeInterval = 0.45

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            press.minimumPressDuration = Self.holdTime
            press.delegate = self
            // A trackpad's or a mouse's: a finger's touches have no buttons, and the mask alone let a tap through.
            click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            click.buttonMaskRequired = .secondary
            click.addTarget(self, action: #selector(clicked(_:)))
            click.delegate = self
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                stopFollowing()
                host?.removeGestureRecognizer(press)
                host?.removeGestureRecognizer(click)
                host = nil
                return
            }
            // What takes the touches on the view: the list cell it is in, else the scroll view, else the window. A
            // view SwiftUI draws has no UIView of its own to put it on.
            var found: UIView? = window
            var scroll: UIView?
            var ancestor = superview
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell { found = view; scroll = nil; break }
                if scroll == nil, view is UIScrollView { scroll = view }
                ancestor = view.superview
            }
            if let scroll { found = scroll }
            guard let found, found !== host else { return }
            host?.removeGestureRecognizer(press)
            host?.removeGestureRecognizer(click)
            found.addGestureRecognizer(press)
            found.addGestureRecognizer(click)
            host = found
            foundCell(found is UICollectionViewCell)
        }

        /// Only touches on the view itself, not elsewhere in what it is in.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let inside = window != nil && bounds.contains(touch.location(in: self))
            if inside, recognizer === press, touch.type == .direct { follow(touch) }
            return inside
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func clicked(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let window else { return }
            action(.secondaryClick, recognizer.location(in: window), window)
        }

        // MARK: The finger

        private var isShown = false

        private func follow(_ touch: UITouch) {
            stopFollowing()
            isShown = false
            finger = touch
            fingerStart = touch.location(in: nil)
            press.onMoved = { [weak self] touch in self?.moved(touch) }
            press.onEnded = { [weak self] touch in self?.ended(touch) }
            press.onCancelled = { [weak self] in self?.cancelled() }
            let work = DispatchWorkItem { [weak self] in self?.held() }
            hold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTime, execute: work)
        }

        private var distance: CGFloat {
            guard let point = finger?.location(in: nil) else { return 0 }
            return hypot(point.x - fingerStart.x, point.y - fingerStart.y)
        }

        /// Held still: the menu comes.
        private func held() {
            guard let finger, [.began, .stationary, .moved].contains(finger.phase), distance < 10, let window else { return }
            press.claim()
            isShown = true
            action(.began, finger.location(in: window), window)
        }

        /// The finger slides on: to an entry, which lights up.
        private func moved(_ touch: UITouch) {
            guard isShown, let window else { return }
            action(.changed, touch.location(in: window), window)
        }

        /// Let go: on an entry the finger slid to, that is picked; anywhere else the menu stays for a tap.
        private func ended(_ touch: UITouch) {
            let wasShown = isShown
            stopFollowing()
            guard wasShown, let window else { return }
            action(.ended, touch.location(in: window), window)
        }

        /// Something else took the finger, such as dragging the row once it moved: the menu goes, as the system's does.
        private func cancelled() {
            let wasShown = isShown
            stopFollowing()
            guard wasShown, let window else { return }
            action(.cancelled, .zero, window)
        }

        private func stopFollowing() {
            hold?.cancel()
            hold = nil
            isShown = false
            press.onMoved = nil
            press.onEnded = nil
            press.onCancelled = nil
        }
    }
}

/// Touching and holding that never waits for the other gestures where it is to fail, and says what the finger does
/// after: UIKit hands it the touches itself, where its calls to a target didn't always come.
final class MenuPressRecognizer: UILongPressGestureRecognizer {
    var onMoved: ((UITouch) -> Void)?
    var onEnded: ((UITouch) -> Void)?
    var onCancelled: (() -> Void)?

    /// The menu came: the touch is the menu's from here on, so the row doesn't also open as the finger lets go.
    func claim() {
        if state == .possible { state = .began }
    }

    override func shouldRequireFailure(of other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    // It leaves dragging alone: a drag that begins after the menu came closes the menu.
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
        !String(describing: type(of: other)).contains("Drag")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let touch = touches.first { onMoved?(touch) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if let touch = touches.first { onEnded?(touch) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        onCancelled?()
    }
}


/// A button that opens a menu in glass under it, as the bars' ••• and Aa do.
struct GlassMenuButton<Label: View>: View {
    @MenuContent var entries: () -> [MenuEntry]
    @ViewBuilder var label: Label
    @State private var anchor = MenuButtonAnchor()

    var body: some View {
        Button {
            if let view = anchor.view, let window = view.window {
                TouchMenus.shared.show(entries(), from: .button(view.convert(view.bounds, to: window)), in: window)
            } else if let touched = TouchRecorder.lastButton() {
                // In a bar, which SwiftUI makes of UIKit's buttons and not of this label: the button touched.
                TouchMenus.shared.show(entries(), from: .button(touched.rect), in: touched.window)
            } else if let window = TouchRecorder.keyWindow {
                // From the keyboard: at the top of the window, on the side bars have their menus.
                let insets = window.safeAreaInsets
                TouchMenus.shared.show(entries(), from: .button(CGRect(x: window.bounds.maxX - insets.right - 60, y: insets.top, width: 44, height: 44)), in: window)
            }
        } label: {
            label.background(MenuAnchorView(anchor: anchor))
        }
        .onAppear { TouchRecorder.install() }
    }
}

/// Notes where the last touch came down in each window, never taking it: for a button in a bar, which SwiftUI makes of
/// UIKit's buttons, to know where it is.
final class TouchRecorder: UIGestureRecognizer, UIGestureRecognizerDelegate {
    @MainActor private static var last: (window: UIWindow, point: CGPoint, view: UIView?, time: TimeInterval)?

    @MainActor static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// Puts one in every window of the app that hasn't one.
    @MainActor static func install() {
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] where !(window is MenuOverlayWindow) {
                guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchRecorder }) else { continue }
                let recorder = TouchRecorder()
                recorder.cancelsTouchesInView = false
                recorder.delaysTouchesBegan = false
                recorder.delaysTouchesEnded = false
                recorder.delegate = recorder
                window.addGestureRecognizer(recorder)
            }
        }
    }

    /// The button the last touch came down on, a moment ago, in its window.
    @MainActor static func lastButton() -> (window: UIWindow, rect: CGRect)? {
        guard let last, ProcessInfo.processInfo.systemUptime - last.time < 2 else { return nil }
        // What was touched is the button's symbol or its label; the button is the first view around it that big.
        var view = last.view
        while let current = view, current.bounds.width < 32 || current.bounds.height < 28, let parent = current.superview { view = parent }
        guard let button = view, button.bounds.width < last.window.bounds.width / 2 else {
            return (last.window, CGRect(x: last.point.x - 22, y: last.point.y - 22, width: 44, height: 44))
        }
        return (last.window, button.convert(button.bounds, to: last.window))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let window = view as? UIWindow {
            let point = touch.location(in: window)
            MainActor.assumeIsolated { Self.last = (window, point, touch.view, ProcessInfo.processInfo.systemUptime) }
        }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The UIKit view behind a button's label: where it is on screen, also in a bar, which SwiftUI lays out in UIKit.
@MainActor
final class MenuButtonAnchor {
    weak var view: UIView?
}

private struct MenuAnchorView: UIViewRepresentable {
    let anchor: MenuButtonAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

/// The share sheet for a menu's Share, from where the menu was.
@MainActor
enum MenuShare {
    static func share(_ items: [Any], from window: UIWindow?, at rect: CGRect) {
        guard let root = window?.rootViewController?.topmostPresented ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first?.topmostPresented else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = root.view.convert(rect, from: window)
        root.present(sheet, animated: true)
    }
}
#endif
