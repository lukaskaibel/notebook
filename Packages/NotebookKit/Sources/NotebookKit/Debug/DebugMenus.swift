#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// The debug remote's commands for the Mac's glass menus.
///
///     glassrow <name>          right-clicks the sidebar row showing that name: its menu in glass at the pointer
///     glassmore <name>         the ••• of that sidebar row
///     glasstext <x> <y>        right-clicks the note at a point of the window, from its top left
///     glassheading             the menu of the heading level in the margin, for the heading the caret is on
///     glassmenu                what the open menus show: each one's frame, field and rows, the lit one starred
///     glasstype <text>         types in the field of the menu on top
///     glasskey down|up|left|right|return|escape   a key in the menu on top
///     glasspick <title>        picks that entry of the menu on top, as a click on it
///     glassclose               closes every menu
@MainActor
enum DebugMenus {
    static func run(_ command: String, _ argument: String, workspace: Workspace, log: @escaping (String) -> Void) -> Bool {
        switch command {
        case "glassrow", "glassmore":
            guard let sidebar = workspace.sidebar else { log("\(command): no sidebar"); break }
            let outline = sidebar.outline
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                      cell.textField?.stringValue == argument else { continue }
                if command == "glassmore", let more = (cell as? SidebarFileCell)?.moreButton ?? (cell as? SidebarHeaderCell)?.moreButton {
                    sidebar.showMenu(forRowOf: more)
                } else {
                    let rect = outline.rect(ofRow: row)
                    let point = outline.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
                    if let event = rightClick(at: point, in: outline.window) { _ = outline.menu(for: event) }
                }
                log("\(command) \(argument)")
                return true
            }
            log("\(command): no row \(argument)")
        case "glasstext":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let textView = workspace.editor.textView as NSTextView?, let window = textView.window,
                  let content = window.contentView else { log("glasstext: no note"); break }
            let point = NSPoint(x: numbers[0], y: content.bounds.height - numbers[1])
            if let event = rightClick(at: point, in: window) { _ = textView.menu(for: event) }
            log("glasstext \(argument)")
        case "glasstoolbar":
            // glasstoolbar <label>: clicks that toolbar button, as the pointer would.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 && !($0 is NSPanel) }),
                  let item = window.toolbar?.items.first(where: { $0.label == argument }), let view = item.view else {
                log("glasstoolbar: no \(argument)"); break
            }
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    window.sendEvent(event)
                }
            }
            log("glasstoolbar \(argument)")
        case "glassright":
            // glassright <x> <y>: a right-click at a point of the main window, from its top left, through the app's event
            // queue, where the monitor of right-clicks on SwiftUI views sees it.
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 && !($0 is NSPanel) }), let content = window.contentView,
                  let event = rightClick(at: NSPoint(x: numbers[0], y: content.bounds.height - numbers[1]), in: window) else { log("glassright: no window"); break }
            NSApp.postEvent(event, atStart: false)
            log("glassright \(argument)")
        case "glassheading":
            let editor = workspace.editor
            guard let (_, marker) = editor.headingMarkLevel,
                  let rect = editor.layoutManager.headingMarkRect(at: marker.location, origin: editor.textView.textContainerOrigin) else {
                log("glassheading: the caret isn't on a heading"); break
            }
            editor.showHeadingMenu(at: NSPoint(x: rect.minX, y: rect.maxY))
            log("glassheading")
        case "glassmenu":
            let shown = GlassMenuDebug.shown
            log("glassmenu: \(shown.count) open\n" + shown.map { open in
                let frame = open.window?.frame.integral ?? .zero
                let rows = open.rows().map { row -> String in
                    let entry = row.entry
                    let name = entry.isDivider ? "—" : entry.isTitle ? "[\(entry.title)]" : (row.path + [entry.title]).joined(separator: " › ")
                    return name + (entry.keys.map { " \($0)" } ?? "") + (entry.isChecked ? " ✓" : "") + (entry.hasSubmenu ? " ›" : "")
                        + (entry.isEnabled ? "" : " (off)") + (open.lit() == row.id ? " *" : "")
                }
                return "  \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) key=\(open.window?.isKeyWindow ?? false) query=\"\(open.query())\": " + rows.joined(separator: " | ")
            }.joined(separator: "\n"))
        case "glasstype":
            guard let open = GlassMenuDebug.shown.last else { log("glasstype: no menu"); break }
            open.setQuery(open.query() + argument)
            log("glasstype \(argument)")
        case "glasskey":
            guard let panel = Dropdown.debugPanel else { log("glasskey: no menu"); break }
            let keys: [String: (String, UInt16)] = [
                "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                "return": ("\r", 36), "escape": ("\u{1b}", 53),
            ]
            guard let (characters, code) = keys[argument],
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code >= 123 && code <= 126 ? [.numericPad, .function] : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                log("glasskey: no key \(argument)"); break
            }
            panel.sendEvent(event)
            log("glasskey \(argument)")
        case "glasspick":
            guard let open = GlassMenuDebug.shown.last else { log("glasspick: no menu"); break }
            log("glasspick \(argument): \(open.activate(argument) ? "picked" : "no such entry")")
        case "glassclose":
            Dropdown.close()
            log("glassclose")
        case "glasstrace":
            Dropdown.trace = { log("  dropdown: \($0)") }
            log("glasstrace on")
        default:
            return false
        }
        return true
    }

    private static func rightClick(at point: NSPoint, in window: NSWindow?) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
#endif
