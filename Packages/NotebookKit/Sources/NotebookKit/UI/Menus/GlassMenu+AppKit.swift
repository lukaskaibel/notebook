#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's right-click menus and the toolbar's dropdowns, drawn in glass as Issues draws them: the same panel as the
/// to-do pickers, rows as tall as a picker's, the keys beside each entry, and a field to type in that finds any entry,
/// also inside a submenu. The menu bar stays the system's.
@MainActor
enum GlassMenu {
    /// Opens a right-click menu where `event` happened, with its top left corner at the pointer, as a menu would.
    static func show(_ entries: [MenuEntry], at event: NSEvent, in view: NSView, onClose: @escaping () -> Void = {}) {
        let point = view.convert(event.locationInWindow, from: nil)
        let anchor = NSRect(x: point.x + 2, y: point.y + (view.isFlipped ? 2 : -2), width: 1, height: 1)
        show(entries, at: anchor, in: view, placement: .pointer, onClose: onClose)
    }

    /// Opens a menu at `rect` of `view`: under it for a button, at it for a point.
    static func show(_ entries: [MenuEntry], at rect: NSRect, in view: NSView, placement: DropdownPlacement = .below, onClose: @escaping () -> Void = {}) {
        let level = MenuLevel(entries)
        guard !level.entries.isEmpty else { return }
        Dropdown.show(below: rect, in: view, placement: placement, onClose: onClose) { close in
            GlassMenuView(level: level, close: close)
        }
    }

    /// Whether this is a right-click, or a click with Control held: the clicks that open a right-click menu.
    static func isContextClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    // MARK: AppKit menus

    /// An AppKit menu's items as glass entries, each doing what it did: its action sent to its target, or along the
    /// responder chain. Its submenus are read as they open.
    static func entries(from menu: NSMenu) -> [MenuEntry] {
        menu.update()
        return menu.items.compactMap(entry)
    }

    static func entry(_ item: NSMenuItem) -> MenuEntry? {
        if item.isHidden || item.view != nil { return nil }
        if item.isSeparatorItem { return .divider }
        if item.isSectionHeader { return .section(item.title) }
        var entry: MenuEntry
        if let submenu = item.submenu {
            if let moveTo = submenu as? MoveToSubmenu, let made = moveTo.entry { return made.with { $0.isEnabled = item.isEnabled } }
            // One the system fills only as it opens, such as Services: nothing to show here.
            if submenu.items.isEmpty, submenu.delegate == nil { return nil }
            entry = .submenu(item.title, enabled: item.isEnabled) {
                submenu.delegate?.menuNeedsUpdate?(submenu)
                return entries(from: submenu)
            }
        } else if let action = item.action {
            entry = MenuEntry(item.title, enabled: item.isEnabled) { [item] in
                NSApp.sendAction(action, to: item.target, from: item)
            }
        } else if !item.isEnabled {
            // A title, such as what the menu is about.
            return .section(item.title)
        } else {
            return nil
        }
        entry.icon = item.image.map { .image($0) } ?? .none
        entry.keys = MenuKeys.text(of: item)
        entry.isChecked = item.state == .on
        entry.indent = item.indentationLevel
        if let title = item.attributedTitle, title.length > 0 {
            if let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font.pointSize != NSFont.menuFont(ofSize: 0).pointSize || font.fontDescriptor.symbolicTraits.contains(.bold) {
                entry.font = Font(font)
            }
            if let color = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, color == .systemRed { entry.isDestructive = true }
        }
        if (item as? ClosureMenuItem)?.isDestructive == true { entry.isDestructive = true }
        return entry
    }
}

/// One menu, or a submenu, as a glass list.
struct GlassMenuView: View {
    let level: MenuLevel
    /// Opened beside another menu: ← goes back to it.
    var isSubmenu = false
    var close: () -> Void

    @State private var query = ""
    @State private var cursor = MenuCursor<Int>()
    @State private var aim = SubmenuAim()
    @State private var frames = SubmenuFrames()

    private let metrics = MenuMetrics.mac

    /// A submenu opens as soon as the pointer slows down on its row or moves sideways, toward it; passing over rows on
    /// the way to another opens nothing. Stopping dead sends no more moves, so after this long it opens anyway.
    static let openDelay: TimeInterval = 0.06
    /// How long a submenu waits for the pointer heading to it across other rows.
    static let aimPatience: TimeInterval = 0.25

    var body: some View {
        let rows = level.rows(for: query)
        VStack(alignment: .leading, spacing: 0) {
            if showsField {
                field(rows)
            } else {
                // A short menu has no field: the keys still move through it.
                MenuKeyCatcher(onMove: { move($0, in: rows) }, onActivate: {
                    if let lit = cursor.key, let row = rows.first(where: { $0.id == lit }) { activate(row, withKeys: true) }
                }, onOpen: {
                    if let lit = cursor.key, let row = rows.first(where: { $0.id == lit }), row.entry.hasSubmenu { openSubmenu(row, withKeys: true) }
                }, onBack: isSubmenu ? close : nil)
                .frame(width: 0, height: 0)
                Color.clear.frame(height: metrics.outer)
            }
            if rows.isEmpty {
                Text("No Matches")
                    .foregroundStyle(Color.theme(Theme.menuTextSecondary))
                    .padding(.horizontal, metrics.outer + metrics.padding)
                    .frame(height: metrics.row)
            }
            list(rows)
        }
        .coordinateSpace(.named(SubmenuFrames.space))
        .overlay {
            SubmenuSlot(cursor: cursor, frames: frames) { index, closeSubmenu in
                if let submenu = level.submenu(at: index) {
                    GlassMenuView(level: submenu, isSubmenu: true, close: closeSubmenu)
                }
            }
        }
        .padding(.bottom, metrics.outer)
        .frame(width: metrics.width)
        .font(metrics.font)
        .foregroundStyle(Color.theme(Theme.menuText))
        .onContinuousHover(coordinateSpace: .named(SubmenuFrames.space)) { phase in
            guard case .active(let point) = phase else { return }
            aim.record(point)
            if aim.isWaiting {
                // Turned away from the open submenu, or stopped short of it: the row under the pointer lights at once.
                if !aim.headsForSubmenu() { settle() }
            } else if aim.opening != nil, aim.settles {
                openPending()
            }
        }
        .background(MenuWindowReader { window in
            aim.home = window
            #if DEBUG
            if let window {
                GlassMenuDebug.register(GlassMenuDebug.Open(window: window, rows: { level.rows(for: query) }, query: { query },
                                                            setQuery: { query = $0 }, lit: { cursor.key },
                                                            activate: { title in
                                                                guard let row = level.rows(for: query).first(where: { $0.entry.title == title }) else { return false }
                                                                activate(row, withKeys: false)
                                                                return true
                                                            }))
            }
            #endif
        })
        .onChange(of: query) {
            aim.cancel()
            cursor.open = nil
            cursor.key = query.isEmpty ? nil : level.rows(for: query).first { $0.entry.isChoosable }?.id
        }
        .onDisappear { aim.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu")
    }

    /// A field to type in, for a menu long enough to need one, and for a picker such as Move To's.
    private var showsField: Bool { level.isLonger(than: 7) || level.placeholder != "Type to find…" }

    private func field(_ rows: [MenuLevel.Row]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            TextField(level.placeholder, text: $query)
                .textFieldStyle(.plain)
                .focusOnAppear()
                .onKeyPress(.downArrow) {
                    move(1, in: rows)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1, in: rows)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard query.isEmpty, let lit = cursor.key, let row = rows.first(where: { $0.id == lit }), row.entry.hasSubmenu else { return .ignored }
                    openSubmenu(row, withKeys: true)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard query.isEmpty, isSubmenu else { return .ignored }
                    close()
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onSubmit {
                    if let lit = cursor.key, let row = rows.first(where: { $0.id == lit }) { activate(row, withKeys: true) }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: metrics.field)
        .background(metrics.innerShape.fill(Color.theme(Theme.menuField)))
        .padding([.horizontal, .top], metrics.outer)
        .padding(.bottom, metrics.outer - 2)
    }

    /// The rows, scrolling once there are more than the screen has room for, such as every folder of an iCloud Drive.
    @ViewBuilder
    private func list(_ rows: [MenuLevel.Row]) -> some View {
        let height = metrics.height(of: rows)
        let room = min(metrics.maxHeight, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
        if height > room {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in self.row(row).id(row.id) }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: room)
                .onChange(of: cursor.keyMoves) {
                    if let lit = cursor.key { proxy.scrollTo(lit) }
                }
            }
        } else {
            ForEach(rows) { row in self.row(row) }
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
            GlassMenuRow(row: row, cursor: cursor, frames: frames, metrics: metrics, hasIcons: level.hasIcons) {
                activate(row, withKeys: false)
            } onHover: { inside in
                hover(row, inside)
            }
        }
    }

    // MARK: Pointer

    private func hover(_ row: MenuLevel.Row, _ inside: Bool) {
        guard inside else {
            if aim.hovered == row.id { aim.hovered = nil }
            return
        }
        aim.hovered = row.id
        if let open = cursor.open, open != row.id, aim.headsForSubmenu() {
            // On the way to the open submenu across this row: it stays, and the row lights only if the pointer
            // settles here.
            aim.wait(Self.aimPatience) { settle() }
            return
        }
        lightUp(row.id)
    }

    /// Lights the row under the pointer, closes another row's submenu and opens the row's own after a moment's rest.
    private func lightUp(_ id: Int) {
        aim.cancel()
        cursor.key = id
        let closes = cursor.open != nil && cursor.open != id
        if closes { cursor.open = nil }
        guard query.isEmpty, level.entries.indices.contains(id), level.entries[id].hasSubmenu, level.entries[id].isEnabled,
              cursor.open != id else { return }
        aim.later(Self.openDelay) { openWhenResting() }
        aim.opening = id
        // Not in the same moment another closes: the one place submenus open from has to see it closed first.
        if aim.settles, !closes { openPending() }
    }

    /// The pointer sends no moves once it stops; still moving quickly, it may be on its way to another row.
    private func openWhenResting() {
        guard let id = aim.opening else { return }
        if aim.isMoving, !aim.settles {
            aim.later(Self.openDelay) { openWhenResting() }
            aim.opening = id
        } else {
            openPending()
        }
    }

    /// Opens the submenu the pointer slowed down on.
    private func openPending() {
        guard let id = aim.opening, aim.hovered == id, cursor.open == nil else { return }
        aim.cancel()
        cursor.openSubmenu(id, takesKey: false)
    }

    /// After the pointer headed for the open submenu: in it, the submenu's row stays lit; anywhere else in this menu,
    /// the row there lights up.
    private func settle() {
        if aim.pointerInSubmenu() {
            aim.cancel()
            cursor.key = cursor.open
        } else if let id = aim.hovered {
            lightUp(id)
        } else {
            aim.cancel()
        }
    }

    // MARK: Keys and clicks

    private func activate(_ row: MenuLevel.Row, withKeys: Bool) {
        guard row.entry.isEnabled else { return }
        switch row.entry.kind {
        case .submenu:
            openSubmenu(row, withKeys: withKeys)
        case .action(let action):
            // Everything closes first, as with a menu, so what the entry opens (a dialog, the palette) gets the
            // keyboard, and actions sent along the responder chain reach the window's.
            Dropdown.close()
            action()
        case .divider, .title:
            break
        }
    }

    /// Opens a row's submenu at once; from the keys, the submenu takes the keyboard, also when it is already open.
    private func openSubmenu(_ row: MenuLevel.Row, withKeys: Bool) {
        let id = row.id
        aim.cancel()
        cursor.key = id
        if cursor.open == id {
            if withKeys, let menu = aim.home { Dropdown.focusPanel(openedFrom: menu) }
        } else if cursor.open != nil {
            // Another row's submenu closes first, so the one place submenus open from sees it open anew.
            cursor.open = nil
            DispatchQueue.main.async { cursor.openSubmenu(id, takesKey: withKeys) }
        } else {
            cursor.openSubmenu(id, takesKey: withKeys)
        }
    }

    private func move(_ delta: Int, in rows: [MenuLevel.Row]) {
        aim.cancel()
        cursor.open = nil
        cursor.step(delta, through: rows.filter(\.entry.isChoosable).map(\.id))
    }
}

#if DEBUG
/// The open glass menus, for the debug remote.
@MainActor
enum GlassMenuDebug {
    struct Open {
        weak var window: NSWindow?
        let rows: () -> [MenuLevel.Row]
        let query: () -> String
        let setQuery: (String) -> Void
        let lit: () -> Int?
        let activate: (String) -> Bool
    }

    private static var menus: [Open] = []

    static func register(_ open: Open) {
        menus.removeAll { $0.window == nil || $0.window === open.window }
        menus.append(open)
    }

    /// The menus on screen, in the order the dropdowns are stacked.
    static var shown: [Open] {
        Dropdown.debugPanels.compactMap { panel in menus.last { $0.window === panel } }
    }
}
#endif

/// The frames of a menu's rows that have a submenu, in the menu's own space. Plain bookkeeping, read when a submenu
/// opens, so rows putting them down redraws nothing.
@MainActor
private final class SubmenuFrames {
    static let space = "glassMenu"
    var rects: [Int: CGRect] = [:]
}

/// Where a glass menu's submenu opens: beside the row whose submenu is open. One for the whole menu, in place of one
/// for every row with a submenu. It covers the whole menu and is told the row: moved onto the row instead, it would
/// still be where it was when the submenu opens, since it is laid out only afterwards.
private struct SubmenuSlot<Content: View>: View {
    let cursor: MenuCursor<Int>
    let frames: SubmenuFrames
    @ViewBuilder var content: (_ index: Int, _ close: @escaping () -> Void) -> Content

    var body: some View {
        let open = cursor.open
        Color.clear
            .allowsHitTesting(false)
            .dropdown(isPresented: Binding(
                // Read when asked, not when drawn: a submenu that closes itself is asked about before this is redrawn.
                get: { cursor.open != nil },
                set: { isOpen in if !isOpen, cursor.open == open { cursor.open = nil } }
            ), placement: .trailing, at: open.flatMap { frames.rects[$0] }, takesKey: cursor.openTakesKey) { close in
                if let open = cursor.open { content(open, close) }
            }
    }
}

/// When a submenu opens and closes under the pointer, as a menu does it: once the pointer slows down on its row, so
/// passing over rows opens nothing, and not while the pointer crosses other rows on its way to the open submenu. Plain
/// bookkeeping, outside SwiftUI's state, so the pointer moving redraws nothing.
@MainActor
private final class SubmenuAim {
    /// Slower than this, in points a second, the pointer has arrived rather than passing by.
    static let slow: Double = 180

    /// The row under the pointer.
    var hovered: Int?
    /// The row whose submenu opens once the pointer settles on it.
    var opening: Int?
    /// The dropdown this menu is in.
    weak var home: NSWindow?
    /// Where the pointer was lately in the menu, from its top left, oldest first.
    private var trail: [(point: CGPoint, time: TimeInterval)] = []
    private var pending: DispatchWorkItem?
    /// Whether a submenu is kept open for the pointer heading to it.
    private(set) var isWaiting = false

    func record(_ point: CGPoint) {
        trail.append((point, ProcessInfo.processInfo.systemUptime))
        if trail.count > 4 { trail.removeFirst() }
    }

    /// Whether the pointer moved a moment ago.
    var isMoving: Bool {
        trail.last.map { ProcessInfo.processInfo.systemUptime - $0.time < 0.04 } ?? false
    }

    /// Slowing down, or moving sideways toward where submenus open rather than up or down to other rows.
    var settles: Bool {
        // Too few moves to tell: the timer opens it once the pointer stops.
        guard trail.count > 1, let from = trail.first, let to = trail.last, to.time > from.time else { return false }
        let dx = to.point.x - from.point.x, dy = to.point.y - from.point.y
        return hypot(dx, dy) / (to.time - from.time) < Self.slow || abs(dx) > 2 * abs(dy)
    }

    func later(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func wait(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        later(delay, work)
        isWaiting = true
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        opening = nil
        isWaiting = false
    }

    /// The open submenu, on screen.
    private var submenuFrame: NSRect? {
        home.flatMap { Dropdown.panel(openedFrom: $0) }?.frame
    }

    func pointerInSubmenu() -> Bool {
        submenuFrame?.contains(NSEvent.mouseLocation) ?? false
    }

    /// Whether the pointer moves into the triangle between where it was and the submenu's near edge: on its way there.
    func headsForSubmenu() -> Bool {
        guard let screen = submenuFrame, let menu = home?.frame, let from = trail.first?.point, let to = trail.last?.point, from != to else { return false }
        // The submenu in the menu's own space, which runs down from its top left as the trail does.
        let target = CGRect(x: screen.minX - menu.minX, y: menu.maxY - screen.maxY, width: screen.width, height: screen.height)
        let onRight = target.midX > menu.width / 2
        let edge = onRight ? target.minX : target.maxX
        // Moving away from the submenu's side is never on the way.
        guard onRight ? to.x > from.x : to.x < from.x else { return false }
        let top = CGPoint(x: edge, y: target.minY - 20)
        let bottom = CGPoint(x: edge, y: target.maxY + 20)
        func side(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let s1 = side(from, top, to), s2 = side(top, bottom, to), s3 = side(bottom, from, to)
        return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
    }
}

/// An entry of a glass menu, lit under the pointer or the keys. A click runs it without a `Button`, which would give
/// every row an AppKit view of its own for the keyboard loop; the arrow keys in the search field move through the menu
/// instead.
private struct GlassMenuRow: View {
    let row: MenuLevel.Row
    let cursor: MenuCursor<Int>
    /// Where rows with a submenu put down their frames, for the submenu to open beside them.
    let frames: SubmenuFrames
    let metrics: MenuMetrics
    var hasIcons = true
    var action: () -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        let label = MenuRowLabel(row: row, metrics: metrics, isLit: cursor.isLit(row.id), hasIcons: hasIcons)
            .onTapGesture(perform: action)
            .onHover(perform: onHover)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.path.isEmpty ? row.entry.title : (row.path + [row.entry.title]).joined(separator: ", "))
            .accessibilityValue(row.entry.isChecked ? "Checked" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
        if row.entry.hasSubmenu {
            label.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(SubmenuFrames.space))
            } action: { frame in
                frames.rects[row.id] = frame
            }
        } else {
            label
        }
    }
}

/// Gives a menu without a field the keyboard: ↑ and ↓ move, Return or Space picks, → opens a submenu, ← goes back
/// and Escape closes. As in Issues.
private struct MenuKeyCatcher: NSViewRepresentable {
    var onMove: (Int) -> Void
    var onActivate: () -> Void
    var onOpen: () -> Void
    var onBack: (() -> Void)?

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onMove = onMove
        view.onActivate = onActivate
        view.onOpen = onOpen
        view.onBack = onBack
    }

    final class KeyView: NSView {
        var onMove: (Int) -> Void = { _ in }
        var onActivate: () -> Void = {}
        var onOpen: () -> Void = {}
        var onBack: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The panel is made key right after its content is in place.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 125: onMove(1)
            case 126: onMove(-1)
            case 36, 76, 49: onActivate()
            case 124: onOpen()
            case 123: onBack?()
            case 53: window?.cancelOperation(nil)
            default: super.keyDown(with: event)
            }
        }
    }
}

/// Reports the window a view is in.
private struct MenuWindowReader: NSViewRepresentable {
    var found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var found: (NSWindow?) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}

// MARK: - SwiftUI

extension View {
    /// The view's right-click menu, drawn in glass like every other menu of the app. The entries are made when it
    /// opens, from what the view shows then.
    /// `cornerRadius` is for the iPhone's and the iPad's, which lift the view out as its menu opens.
    func appContextMenu(cornerRadius: CGFloat? = nil, @MenuContent _ entries: @escaping () -> [MenuEntry]) -> some View {
        background(ContextMenuRegion(entries: entries))
    }
}

/// Where a SwiftUI view's right-click menu is: an AppKit view behind it that never takes a click, found by the one
/// monitor of right-clicks (`GlassMenu.watchContextClicks`), innermost first.
private struct ContextMenuRegion: NSViewRepresentable {
    var entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        // The latest closure, so the menu shows what the view shows now.
        view.entries = entries
    }

    final class RegionView: NSView {
        var entries: () -> [MenuEntry] = { [] }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Its menu is open: ringed in the accent colour a little outside it, as AppKit rings what a right-click menu is
        /// for.
        var isMarked = false {
            didSet {
                wantsLayer = true
                layer?.masksToBounds = false
                ring.removeFromSuperlayer()
                guard isMarked, let layer else { return }
                ring.frame = bounds.insetBy(dx: -6, dy: -3)
                ring.cornerRadius = 8
                ring.cornerCurve = .continuous
                ring.borderWidth = 2
                ring.borderColor = NSColor.controlAccentColor.cgColor
                layer.addSublayer(ring)
            }
        }
        private let ring = CALayer()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ContextMenuRegions.register(self, present: window != nil)
        }
    }
}

/// The SwiftUI views with a glass right-click menu, and the monitor that opens them.
@MainActor
enum ContextMenuRegions {
    private static let table = NSHashTable<NSView>.weakObjects()
    private static var monitor: Any?

    fileprivate static func register(_ view: NSView, present: Bool) {
        if present { table.add(view) } else { table.remove(view) }
        watch()
    }

    /// The menu under a right-click: the smallest region there.
    private static func entries(at event: NSEvent) -> (view: NSView, entries: [MenuEntry])? {
        guard let window = event.window else { return nil }
        let regions = table.allObjects.compactMap { $0 as? ContextMenuRegion.RegionView }
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .filter { $0.convert($0.bounds, to: nil).contains(event.locationInWindow) }
            .sorted { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        for region in regions {
            let entries = region.entries()
            if !entries.isEmpty { return (region, entries) }
        }
        return nil
    }

    private static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard GlassMenu.isContextClick(event) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let found = entries(at: event) else { return false }
                let region = found.view as? ContextMenuRegion.RegionView
                region?.isMarked = true
                GlassMenu.show(found.entries, at: event, in: found.view) { region?.isMarked = false }
                return true
            }
            return handled ? nil : event
        }
    }
}

/// A button that opens a menu in glass under it, as the toolbar's Aa and ••• do.
struct AppMenuButton<Label: View>: View {
    @MenuContent var entries: () -> [MenuEntry]
    @ViewBuilder var label: Label
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            label
        }
        .dropdown(isPresented: $open) { close in
            GlassMenuView(level: MenuLevel(entries()), close: close)
        }
    }
}
#endif
