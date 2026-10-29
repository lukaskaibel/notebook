#if DEBUG && os(macOS)
import AppKit
import MapKit
import PDFKit
import SwiftUI

/// Development-only remote control, as in Issues. Launch with `-debugCommandFile <path>` and append lines to that
/// file to drive the app with real mouse and keyboard events (click, drag, type, keys) and take snapshots, so the
/// app can be tested end to end without a person at the keyboard. Results go to `<path>.log`.
@MainActor
enum DebugRemote {
    /// The window `fakekey` made say it is key.
    nonisolated(unsafe) private static weak var fakeKeyWindow: NSWindow?
    /// The sheet over it, with `fakekey sheet`: key as a sheet is, with the window under it main.
    nonisolated(unsafe) private static weak var fakeKeySheet: NSWindow?
    /// A click the remote sends: what watches the app's clicks doesn't see it, as it goes straight to the window.
    static let clicked = Notification.Name("DebugRemoteClicked")
    private static var processed = 0
    private static var timer: Timer?
    private static var activity: NSObjectProtocol?
    private static weak var workspace: Workspace?

    static func startIfRequested(workspace: Workspace) {
        // Once, though the window appears again after it was closed.
        guard timer == nil, let path = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        self.workspace = workspace
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Debug remote")
        processed = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        if processed > 0 { processed -= 1 }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { poll(path) }
        }
        // In every run loop mode, so commands keep coming while a popover, menu or drag is in progress.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static var waitUntil: Date?
    /// The menu `movetomenu more` opened.
    private static weak var trackedMenu: NSMenu?
    /// The search `placesearch` runs, kept until it answers.
    private static var placeSearch: PlaceSearch?

    private static func poll(_ path: String) {
        if let waitUntil, Date() < waitUntil { return }
        waitUntil = nil
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        // The last element is what follows the final newline: not a finished command yet.
        while processed < lines.count - 1 {
            let line = lines[processed]
            processed += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            run(line)
            endEvent()
            if waitUntil != nil { return }
        }
    }

    /// Each command is an event, as typing or a click is: AppKit closes the undo groups the event opened once it has
    /// been handled, which it does for events it handles itself only.
    static func endEvent() {
        (UndoManager.self as AnyObject).perform(NSSelectorFromString("_endTopLevelGroupings"))
    }

    /// Search results on one line: each section's title, then its items with where they are or the line found.
    private static func describe(_ sections: [SearchSection]) -> String {
        sections.map { section in
            let items = section.items.map { item -> String in
                let detail = item.snippet ?? item.place
                return item.title + (detail.map { " (\($0))" } ?? "")
            }
            return "[\(section.title ?? "")] " + items.joined(separator: " | ")
        }.joined(separator: " ")
    }

    static func log(_ text: String) {
        guard let path = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        let url = URL(fileURLWithPath: path + ".log")
        let line = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Commands go to the main window, or after `usewindow file` to the last file window opened.
    private static var usesFileWindow = false

    private static var window: NSWindow? {
        if usesFileWindow { return FileWindows.shared.windows.last }
        return NSApp.windows.first { $0.isVisible && $0.frame.width > 500 && !($0 is NSPanel) && !($0.windowController is FileWindowController) }
    }

    private static var editor: EditorController? {
        if usesFileWindow { return (FileWindows.shared.windows.last?.windowController as? FileWindowController)?.editor }
        return workspace?.editor
    }

    private static func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "wait":
            waitUntil = Date().addingTimeInterval(numbers.first ?? 0.5)
        case "open":
            guard let workspace, let location = workspace.locations.first else { return }
            let url = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : location.url.appendingPathComponent(argument)
            workspace.open(url)
        case "timeopen":
            // timeopen <path>: opens a note and logs how long the main thread was busy with it, until the window had
            // drawn it and the main thread was free again.
            guard let workspace, let location = workspace.locations.first else { return }
            let url = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : location.url.appendingPathComponent(argument)
            let start = CACurrentMediaTime()
            workspace.open(url)
            let opened = CACurrentMediaTime()
            let timer = Timer(timeInterval: 0.001, repeats: false) { _ in
                let done = CACurrentMediaTime()
                MainActor.assumeIsolated { log(String(format: "timeopen %@: open %.1f ms, until free %.1f ms", url.lastPathComponent, (opened - start) * 1000, (done - start) * 1000)) }
            }
            RunLoop.main.add(timer, forMode: .common)
        case "activate":
            window?.orderFront(nil)
        case "fakekey":
            // The window says it is key and main, as one clicked in the app in front does, while the app stays in the
            // background: SwiftUI's focus then behaves as it does for you.
            // Dropdowns too, so their glass is drawn as it is in the app in front.
            // fakekey sheet: the sheet over it too (Browse All Versions…), with its default button lit.
            guard let window, let windowClass = object_getClass(window) else { break }
            fakeKeyWindow = window
            var patches = [(windowClass, #selector(getter: NSWindow.isKeyWindow)), (windowClass, #selector(getter: NSWindow.isMainWindow)),
                           (DropdownPanel.self, #selector(getter: NSWindow.isKeyWindow))]
            if argument == "sheet", let sheet = window.attachedSheet, let sheetClass = object_getClass(sheet) {
                fakeKeySheet = sheet
                patches.append((sheetClass, #selector(getter: NSWindow.isKeyWindow)))
            }
            for (patched, selector) in patches {
                guard let method = class_getInstanceMethod(patched, selector) else { continue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
                let replacement: @convention(block) (AnyObject) -> Bool = { object in
                    if selector == #selector(getter: NSWindow.isKeyWindow), let sheet = DebugRemote.fakeKeySheet, sheet.isVisible {
                        return object === sheet || object is DropdownPanel || original(object, selector)
                    }
                    return object === DebugRemote.fakeKeyWindow || object is DropdownPanel || original(object, selector)
                }
                class_replaceMethod(patched, selector, imp_implementationWithBlock(replacement), method_getTypeEncoding(method))
            }
            // The app says so too, so the menus enable their items for what has the keyboard in it, as they do for you.
            for selector in [#selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.mainWindow)] {
                guard let method = class_getInstanceMethod(NSApplication.self, selector) else { continue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> NSWindow?
                let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
                let replacement: @convention(block) (AnyObject) -> NSWindow? = { object in
                    original(object, selector) ?? DebugRemote.fakeKeyWindow
                }
                class_replaceMethod(NSApplication.self, selector, imp_implementationWithBlock(replacement), method_getTypeEncoding(method))
            }
            log("fakekey: key \(window.isKeyWindow), first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        case "resignfocus":
            // The keyboard back to the window itself, as when SwiftUI loses a field it was asked to focus.
            window?.makeFirstResponder(nil)
            log("resignfocus: first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        case "firstresponder":
            log("firstresponder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        case "makekey":
            // The window key and main, as a click on it makes it, while the app stays in the background.
            window?.makeKey()
            window?.makeMain()
            log("makekey: key \(window?.isKeyWindow == true), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        case "focus":
            if let editor { window?.makeFirstResponder(editor.textView) }
        case "focustitle":
            editor?.focusTitle()
        case "seen":
            if let editor { log(editor.debugSeenLine) }
        case "fold":
            // fold <index>: where the character at index is drawn over the next frames (see debugSampleFold).
            if let editor, let index = numbers.first { editor.debugSampleFold(at: Int(index), log: log) }
        case "caret":
            if let editor, let location = numbers.first {
                window?.makeFirstResponder(editor.textView)
                editor.textView.setSelectedRange(NSRange(location: Int(location), length: 0))
            }
        case "select":
            if let editor, numbers.count == 2 {
                window?.makeFirstResponder(editor.textView)
                editor.textView.setSelectedRange(NSRange(location: Int(numbers[0]), length: Int(numbers[1])))
            }
        case "type":
            for character in argument.replacingOccurrences(of: "\\n", with: "\n") {
                if character == "\n" { sendKey("\r", code: 36) } else { sendKey(String(character), code: 0) }
            }
        case "key":
            key(argument)
        case "click", "doubleclick", "rightclick":
            // click <x> <y>: in points from the window's top-left corner.
            if numbers.count >= 2 { click(at: CGPoint(x: numbers[0], y: numbers[1]), count: command == "doubleclick" ? 2 : 1, right: command == "rightclick") }
        case "clicktext":
            // clicktext <character index> [fraction across the character]
            if let editor, let index = numbers.first, let point = windowPoint(ofCharacter: Int(index), fraction: numbers.count > 1 ? numbers[1] : 0.5, in: editor) {
                click(at: point)
            }
        case "drag":
            // drag <from character> <to character>
            if let editor, numbers.count == 2,
               let from = windowPoint(ofCharacter: Int(numbers[0]), fraction: 0.05, in: editor),
               let to = windowPoint(ofCharacter: Int(numbers[1]), fraction: 0.95, in: editor) {
                click(at: from, dragTo: to)
            }
        case "selectrow":
            // selectrow <name>: selects that sidebar row as a click does, and gives the sidebar the focus.
            guard let outline = workspace?.sidebar?.outline else { return }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, cell.textField?.stringValue == argument else { continue }
                window?.makeFirstResponder(outline)
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                log("selected row \(row) \(argument)")
                break
            }
        case "clickrow":
            // clickrow <name>: the sidebar row showing that name.
            if let point = sidebarRowPoint(named: argument) { click(at: point) } else { log("no row \(argument)") }
        case "doubleclickrow":
            // doubleclickrow <name>: what a double-click on that row does. The list takes no clicks of its own in a
            // window that isn't key, so the row is selected and its double action run, as the clicks would.
            guard let sidebar = workspace?.sidebar else { break }
            let outline = sidebar.outline
            guard let row = (0..<outline.numberOfRows).first(where: { (outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == argument }) else {
                log("no row \(argument)")
                break
            }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.openOnItsOwn(row: row)
            log("doubleclickrow \(row) \(argument)")
        case "clickobject":
            // clickobject <character index> [x y]: inside the object drawn there, at x, y from its top-left.
            if let editor, let index = numbers.first, let window, let content = window.contentView,
               let rect = editor.layoutManager.rect(forObjectAt: Int(index), origin: editor.textView.textContainerOrigin) {
                let blockRect = blockObjectRect(editor, Int(index)) ?? rect
                let inText = NSPoint(x: blockRect.minX + (numbers.count > 2 ? numbers[1] : blockRect.width / 2), y: blockRect.minY + (numbers.count > 2 ? numbers[2] : blockRect.height / 2))
                let inWindow = editor.textView.convert(inText, to: nil)
                click(at: CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y), count: 1)
            } else {
                log("no object at \(argument)")
            }
        case "dragpoints":
            if numbers.count == 4 { click(at: CGPoint(x: numbers[0], y: numbers[1]), dragTo: CGPoint(x: numbers[2], y: numbers[3])) }
        case "scroll":
            if let editor, let y = numbers.first {
                editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
            }
        case "scrolllist":
            // scrolllist <y>: the list showing in place of the editor, such as To-dos, scrolled to y.
            guard let y = numbers.first, let root = window?.contentView else { break }
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
            }
            let others = [editor?.scrollView, workspace?.sidebar?.outline.enclosingScrollView].compactMap { $0 }
            guard let list = scrollViews(in: root).filter({ view in !view.isHiddenOrHasHiddenAncestor && !others.contains { $0 === view } })
                .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return log("scrolllist: no list") }
            list.contentView.scroll(to: NSPoint(x: 0, y: y))
            list.reflectScrolledClipView(list.contentView)
            log("scrolllist \(Int(y)) in \(type(of: list))")
        case "move":
            // move <x> <y> [<x2> <y2>]: the pointer moving to a point, or from one to another, through the window, as
            // SwiftUI's hover sees it (the real pointer stays put).
            if numbers.count >= 2 { move(from: CGPoint(x: numbers[0], y: numbers[1]), to: numbers.count >= 4 ? CGPoint(x: numbers[2], y: numbers[3]) : nil) }
        case "hover":
            // hover <character index>: as if the pointer rested on that character (the real one stays put).
            if let editor, let index = numbers.first, let window, let content = window.contentView,
               let point = windowPoint(ofCharacter: Int(index), fraction: 0.5, in: editor) {
                editor.updateCopyButton(at: editor.textView.convert(NSPoint(x: point.x, y: content.bounds.height - point.y), from: nil))
                let button = editor.textView.copyButton
                let frame = editor.textView.convert(button.frame, to: nil)
                log(button.isHidden ? "hover \(Int(index)): no copy button" : "hover \(Int(index)): copy button at \(Int(frame.midX)) \(Int(content.bounds.height - frame.midY))")
            }
        case "drawing", "drawstroke", "drawinfo", "drawundo", "drawredo":
            if let editor { log(editor.debugDrawing(command, argument)) }
        case "dragtypes", "dragobject", "dropfile":
            if let editor { log(editor.debugDragging(command, argument)) }
        case "drawtool":
            // drawtool pen|pencil|marker|eraser [width 0-2] [object|pixel|RRGGBB]
            let bits = argument.split(separator: " ").map(String.init)
            let tools = DrawingTools.shared
            if let tool = bits.first.flatMap(DrawingTools.Tool.init) { tools.tool = tool }
            if bits.count > 1, let level = Int(bits[1]) { tools.widthLevel = level }
            if bits.count > 2, let eraser = DrawingTools.Eraser(rawValue: bits[2]) { tools.eraser = eraser }
            if bits.count > 2, let hex = UInt32(bits[2], radix: 16) { tools.color = NSColor(hex: hex) }
            log("tool \(tools.tool) width \(tools.width) eraser \(tools.eraser)")
        case "drawslow":
            // drawslow <seconds> x y x y …: as drawpath, through a smooth curve, at the speed of a hand (for recordings).
            guard numbers.count >= 5 else { return }
            let points = stride(from: 1, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            drag(along: smooth(points), seconds: numbers[0])
        case "drawpath":
            // drawpath x y x y …: the mouse button down at the first point (window points from the top left),
            // dragged through the others and up at the last, as real events.
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            if points.count >= 2 { drag(through: points) }
        case "snapshot":
            snapshot(to: argument)
        case "dump":
            dump()
        case "rect":
            // rect <character index>: where a character is drawn, in window points from the top-left.
            if let editor, let index = numbers.first, let point = windowPoint(ofCharacter: Int(index), fraction: 0.5, in: editor) {
                log("rect \(Int(index)): \(Int(point.x)) \(Int(point.y)) y-in-text=\(Int(editor.yPosition(of: Int(index)))) scroll=\(Int(editor.scrollView.contentView.bounds.minY))")
            }
        case "object":
            // object <index>: what is drawn at a character.
            if let editor, let index = numbers.first.map(Int.init) {
                let layout = editor.layoutManager
                let glyph = layout.glyphIndexForCharacter(at: index)
                let object = layout.object(at: index)
                let character = (editor.text as NSString).substring(with: NSRange(location: index, length: 1))
                log("object \(index) '\(character)': \(object.map { String(describing: $0.kind) } ?? "none") glyph=\(glyph) property=\(layout.propertyForGlyph(at: glyph).rawValue) rect=\(layout.rect(forObjectAt: index, origin: editor.textView.textContainerOrigin).map { "\($0)" } ?? "nil")")
            }
        case "views":
            // views <class name>: the views of that class in the window, with their frames.
            func walk(_ view: NSView, _ depth: Int) {
                if String(describing: type(of: view)).contains(argument) {
                    log("view \(type(of: view)) frame=\(view.convert(view.bounds, to: nil)) hidden=\(view.isHiddenOrHasHiddenAncestor) subviews=\(view.subviews.count)")
                }
                for subview in view.subviews { walk(subview, depth + 1) }
            }
            if let root = window?.contentView?.superview { walk(root, 0) }
        case "find":
            // find <text>: the character index where it first is.
            if let editor { log("find \"\(argument)\": \((editor.text as NSString).range(of: argument).location)") }
        case "appearance":
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "window":
            if numbers.count == 2, let window {
                var frame = window.frame
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                window.setFrame(frame, display: true)
            }
        case "menu":
            // menu <Menu>/<Item> or <Menu>/<Submenu>/<Item>: runs a menu item as choosing it would, and says whether it
            // is ticked.
            let path = argument.split(separator: "/").map(String.init)
            guard path.count >= 2, var menu = NSApp.mainMenu?.item(withTitle: path[0])?.submenu else { log("no menu \(argument)"); return }
            // What happens before a menu opens, so SwiftUI brings its items up to date.
            func update(_ menu: NSMenu) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.delegate?.menuWillOpen?(menu)
                menu.update()
                menu.delegate?.menuDidClose?(menu)
            }
            update(menu)
            for title in path.dropFirst().dropLast() {
                guard let submenu = menu.item(withTitle: title)?.submenu else { log("no submenu \(title) in \(argument)"); return }
                menu = submenu
                update(menu)
            }
            guard let index = menu.items.firstIndex(where: { $0.title == path[path.count - 1] }) else { log("no item \(argument): \(menu.items.map(\.title))"); return }
            let item = menu.items[index]
            log("menu \(argument): enabled=\(item.isEnabled) key=\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)\(item.state == .on ? " ticked" : "")")
            if item.isEnabled { menu.performActionForItem(at: index) }
        case "showmenu":
            // showmenu <Menu>[ > <Submenu>]: pops that menu of the menu bar up in the window, under where it is in the
            // menu bar, for a picture (`capture all`), as the menu bar of an app in the background can't be opened.
            // It shows on screen until `showmenu close`.
            if argument == "close" {
                trackedMenu?.cancelTracking()
                trackedMenu = nil
                break
            }
            let path = argument.components(separatedBy: " > ")
            guard var menu = NSApp.mainMenu?.item(withTitle: path[0])?.submenu, let content = window?.contentView else { log("no menu \(argument)"); break }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            var offset: CGFloat = 0
            for title in path.dropFirst() {
                guard let index = menu.items.firstIndex(where: { $0.title == title }), let submenu = menu.items[index].submenu else { log("no \(title) in \(menu.items.map(\.title))"); return }
                offset = CGFloat(index)
                menu = submenu
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            // The menu bar's own menus are drawn outside the app, where a picture of its windows doesn't see them: a
            // menu of copies of their items is the app's.
            let copy = NSMenu(title: menu.title)
            for item in menu.items { if let item = item.copy() as? NSMenuItem { copy.addItem(item) } }
            menu = copy
            trackedMenu = menu
            let top = 6 + offset * 22
            let point = NSPoint(x: path.count > 1 ? 330 : 90, y: content.isFlipped ? top : content.bounds.height - top)
            log("showmenu at \(point) in a view flipped=\(content.isFlipped), on screen at \(content.window?.convertPoint(toScreen: content.convert(point, to: nil)) ?? .zero)")
            DispatchQueue.main.async {
                let opened = CACurrentMediaTime()
                let shown = menu.popUp(positioning: nil, at: point, in: content)
                log(String(format: "showmenu closed after %.2f s, chosen=%@", CACurrentMediaTime() - opened, String(shown)))
            }
            log("showmenu \(argument): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (disabled)") }.joined(separator: " | "))
        case "menus":
            // menus: every menu item with its shortcut and action, to check shortcuts are unique.
            func walk(_ menu: NSMenu, _ path: String) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                for item in menu.items where !item.isSeparatorItem {
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue >> 16)+\(item.keyEquivalent)]"
                    log("\(path)/\(item.title)\(key) \(item.action.map(NSStringFromSelector) ?? "")\(item.isEnabled ? "" : " (disabled)")")
                    if let submenu = item.submenu { walk(submenu, "\(path)/\(item.title)") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
        case "editlink":
            // editlink <index>: opens the link editor for the link around a character, as its pencil does.
            if let editor, let index = numbers.first.map(Int.init) {
                let line = editor.document.lines[editor.document.lineIndex(containing: index)]
                if let link = line.spans.first(where: { if case .link = $0.kind { return $0.range.contains(index) } else { return false } }) {
                    log("editlink opening \(link.range)")
                    editor.editLink(at: link.range)
                    log("editlink opened")
                } else {
                    log("editlink: no link at \(index)")
                }
            }
        case "popovertype":
            // popovertype <text>: what typing the address into the open link editor does.
            if let model = LinkEditorModel.current { model.address = argument; log("popovertype ok") } else { log("popovertype: no link editor") }
        case "popoverreturn":
            if let model = LinkEditorModel.current { model.finish(.save(model.address)) }
        case "showcaret":
            MarkdownTextView.drawsCaretAlways = argument == "1"
            editor?.textView.needsDisplay = true
        case "caretinfo":
            // caretinfo: the caret's line, the caret drawn in it and the baseline of the text there, in text view points.
            if let editor { caretInfo(editor) }
        case "settings":
            // settings <general|text|sidebar>: opens Settings at that tab.
            UserDefaults.standard.set(argument.isEmpty ? "general" : argument, forKey: "settingsTab")
            // The app menu's Settings…: SwiftUI's Settings window no longer answers showSettingsWindow:.
            if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
            }
        case "usewindow":
            usesFileWindow = argument == "file"
        case "windows":
            // windows: the windows open, a note's own windows with their file and how many tabs they are in.
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                let file = (window.windowController as? FileWindowController).map { " file=\($0.url.path) tabs=\(window.tabbedWindows?.count ?? 1)" } ?? ""
                log("window \"\(window.title)\" id=\(window.identifier?.rawValue ?? "none")\(file)")
            }
        case "openfile":
            FileWindows.shared.open(URL(fileURLWithPath: argument))
        case "closefile":
            // closefile: closes the last of the notes' own windows, as its close button does.
            FileWindows.shared.windows.last?.performClose(nil)
        case "sheet":
            // sheet [cancel]: the sheet over the window, such as Attach File's Open panel; with cancel, closes it as
            // its Cancel button does.
            guard let window, let sheet = window.attachedSheet else { log("sheet: none"); break }
            log("sheet: \(type(of: sheet)) \(sheet.frame.size)")
            if argument == "cancel" { (sheet as? NSSavePanel)?.cancel(nil) ?? window.endSheet(sheet, returnCode: .cancel) }
        case "attachfiles":
            // attachfiles <path>[|<path>…]: what choosing those files in Attach File's Open panel puts in the note.
            guard let editor else { log("attachfiles: no note"); break }
            let urls = argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            log("attachfiles: \(editor.pasteFiles(urls, at: editor.selection))")
        case "front":
            // front: which window is in front and what the menus act on there.
            if let workspace {
                let key = NSApp.keyWindow
                log("front key=\"\(key?.title ?? "none")\" main=\"\(NSApp.mainWindow?.title ?? "none")\" mainOpen=\(workspace.isMainWindowOpen) other=\(workspace.isOtherWindowInFront) fileNote=\(workspace.keyFileNote?.url.lastPathComponent ?? "none") file=\(workspace.fileInFront?.lastPathComponent ?? "none") hasNote=\(workspace.hasNoteInFront) visibleNote=\(workspace.hasVisibleNote) active=\(workspace.activeEditor()?.title ?? "none") fileUndo=\(workspace.fileUndoManager === window?.undoManager ? "window" : "other")")
            }
        case "replaceall":
            // replaceall <find>|<replace>: types both in the note's find bar, as you would, and clicks All.
            guard let editor else { break }
            let parts = argument.components(separatedBy: "|")
            func send(_ action: NSTextFinder.Action) {
                let item = NSMenuItem()
                item.tag = action.rawValue
                editor.textView.performTextFinderAction(item)
            }
            send(.showReplaceInterface)
            func fields(in view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields(in: $0) } }
            let found = editor.scrollView.findBarView.map(fields(in:))?.filter(\.isEditable) ?? []
            guard found.count >= 2, parts.count == 2 else { log("replaceall: \(found.count) fields"); break }
            for (field, text) in zip(found, parts) {
                field.stringValue = text
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
            }
            send(.replaceAll)
            log("replaceall: done, fields \(found.map(\.stringValue))")
        case "becomemain":
            // becomemain <title>: that window becomes the one you work in, as a click on it makes it (Settings, say).
            if let found = NSApp.windows.first(where: { $0.isVisible && $0.title == argument }) { FileWindows.becameMain(found) } else { log("becomemain: no \(argument)") }
        case "resignactive":
            // resignactive: what switching to another app tells Notebook (it never is the active app here).
            NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        case "minimize":
            // minimize: the main window into the Dock, as its yellow button does; `windowstate` says where it is.
            NSApp.windows.first { $0.isVisible && Workspace.shared.isMainWindow($0) }?.miniaturize(nil)
        case "windowstate":
            for window in NSApp.windows where !(window is NSPanel) && (window.isVisible || window.isMiniaturized) {
                log("windowstate \"\(window.title)\" miniaturized=\(window.isMiniaturized) visible=\(window.isVisible) main=\(window.isMainWindow)")
            }
        case "closemain":
            // closemain: closes the main window, as its close button does.
            window?.performClose(nil)
        case "reopen":
            // reopen: what a click on the Dock icon does: the Dock sends the app this Apple event.
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            var reply = AEDesc()
            if let raw = event.aeDesc {
                let error = NSAppleEventManager.shared().dispatchRawAppleEvent(raw, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)
                log("reopen: \(error == noErr ? "sent" : "error \(error)")")
            }
        case "samplenotes":
            // samplenotes <folder>: what Try Sample Notes… does once a folder is chosen.
            workspace?.addSampleNotes(in: URL(fileURLWithPath: argument, isDirectory: true))
        case "importnotes":
            // importnotes <path>[|<path>…]: what Import from Apple Notes… does once Notes' export is chosen.
            guard let workspace, let folder = workspace.folderForNewNote else { log("importnotes: nowhere to import to"); break }
            workspace.importFromAppleNotes(argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }, into: folder)
            log("importnotes into \(folder.path)")
        case "storeasset":
            // storeasset <file>|picture: what pasting a file, or a picture, into the open note puts in its .assets.
            guard let editor else { log("storeasset: no note open"); break }
            let picture = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { NSColor.systemRed.setFill(); $0.fill(); return true }
            let path = argument == "picture" ? editor.storeAsset(image: picture) : editor.storeAsset(copying: URL(fileURLWithPath: argument))
            log("storeasset: \(path ?? "failed") in \(editor.assetsFolder?.path ?? "no folder")")
        case "trash":
            // trash <path>: what Move to Trash does with a file or folder.
            guard let workspace else { break }
            Task { log("trash \(argument): \(await workspace.trash(URL(fileURLWithPath: argument)).value ? "done" : "failed")") }
        case "placesearch":
            // placesearch <words>: what typing a place in Remind Me finds in Apple Maps, and where the first one is.
            let search = PlaceSearch()
            placeSearch = search
            search.query = argument
            Task {
                try? await Task.sleep(for: .seconds(4))
                log("placesearch \(argument): \(search.results.count) found \(search.results.prefix(3).map(\.title))")
                guard let first = search.results.first else { return }
                let place = await search.place(for: first)
                log("placesearch place: \(place.map { "\($0.name) \($0.latitude) \($0.longitude)" } ?? "none")")
            }
        case "mapsnapshot":
            // mapsnapshot <latitude> <longitude> <out.png>: a map from the tiles Remind Me's map loads, to see they come.
            let bits = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard bits.count == 3, let latitude = Double(bits[0]), let longitude = Double(bits[1]) else { log("mapsnapshot <latitude> <longitude> <out.png>"); break }
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), latitudinalMeters: 800, longitudinalMeters: 800)
            options.size = CGSize(width: 300, height: 200)
            MKMapSnapshotter(options: options).start { snapshot, error in
                MainActor.assumeIsolated {
                    guard let snapshot, let tiff = snapshot.image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                        log("mapsnapshot: \(error?.localizedDescription ?? "no picture")"); return
                    }
                    try? png.write(to: URL(fileURLWithPath: bits[2]))
                    log("mapsnapshot \(bits[2])")
                }
            }
        case "openurls":
            // openurls <path>: what File › Open and the Dock icon do with a file or folder.
            FileWindows.shared.open([URL(fileURLWithPath: argument)])
        case "rows":
            // rows: the sidebar as shown, indented, with the selected row marked and the visible rows' range.
            if let outline = workspace?.sidebar?.outline {
                let lines = (0..<outline.numberOfRows).map { row -> String in
                    let item = outline.item(atRow: row)
                    let name = (item as? FileNode)?.name ?? (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "?"
                    let hidden = (item as? FileNode).map { $0.isFolder && workspace?.isHidden($0.url) == true } ?? false
                    var header = ""
                    if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell {
                        if !cell.hiddenButton.isHidden { header += " [eye\(cell.hiddenButton.contentTintColor == .controlAccentColor ? " on" : "")]" }
                        if !cell.addButton.isHidden { header += " [+]" }
                    }
                    // The name being typed, in its field.
                    let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFileCell)?.label
                    let renaming = field?.currentEditor().map { " (renaming “\($0.string)”, \(NSStringFromRange($0.selectedRange)) selected)" } ?? ""
                    // What the row says while its file is being renamed.
                    let says = field.flatMap { $0.currentEditor() == nil && $0.stringValue != name ? " (says “\($0.stringValue)”)" : nil } ?? ""
                    return String(repeating: "  ", count: outline.level(forRow: row)) + name + (hidden ? " (hidden)" : "") + header + renaming + says + (outline.selectedRow == row ? " *" : "")
                }
                let visible = outline.rows(in: outline.visibleRect)
                log("rows (visible \(visible.location)..<\(visible.location + visible.length)):\n" + lines.joined(separator: "\n"))
            }
        case "hide", "unhide":
            // hide <path>, unhide <path>: what Hide Folder and Unhide Folder in the sidebar's menu do.
            workspace?.setHidden(URL(fileURLWithPath: argument), command == "hide")
            log("\(command) \(argument): \(workspace?.hidden.keys.sorted() ?? [])")
        case "hiddenpaths":
            // hiddenpaths [text]: what search leaves out, and the paths of the files whose path has the text.
            if let index = workspace?.index {
                log("hiddenpaths: \(index.hiddenPaths) entries: " + index.entries.filter { argument.isEmpty || $0.url.path.contains(argument) }.prefix(8).map { "\($0.url.path) hidden=\(index.isHidden($0.url))" }.joined(separator: ", "))
            }
        case "showhidden":
            // showhidden <location name> <1|0>: the eye button on that location's header; showhidden all: View › Show Hidden Folders.
            guard let workspace else { break }
            if argument == "all" {
                workspace.toggleAllHiddenFolders()
            } else if let space = argument.lastIndex(of: " "), let location = workspace.locations.first(where: { $0.name == argument[..<space] }) {
                workspace.showHiddenFolders(argument[argument.index(after: space)...] == "1", in: location)
            }
            log("showhidden \(argument): \(workspace.locations.filter(workspace.showsHiddenFolders(in:)).map(\.name))")
        case "hoverheader":
            // hoverheader <title> <1|0>: as if the pointer rested on a section's header (the real one stays put).
            guard let outline = workspace?.sidebar?.outline, let space = argument.lastIndex(of: " ") else { break }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell, cell.label.stringValue == argument[..<space] else { continue }
                cell.isHovered = argument[argument.index(after: space)...] == "1"
                let height = window?.contentView?.bounds.height ?? 0
                func place(_ button: NSButton) -> String {
                    let frame = button.convert(button.bounds, to: nil)
                    return button.isHidden ? "hidden" : "at \(Int(frame.midX)) \(Int(height - frame.midY))"
                }
                log("hoverheader \(argument): eye \(place(cell.hiddenButton)), plus \(place(cell.addButton))")
            }
        case "rowmenu":
            // rowmenu <name>: the titles of the context menu of the sidebar row showing that name.
            guard let sidebar = workspace?.sidebar, let outline = Optional(sidebar.outline) else { break }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, cell.textField?.stringValue == argument else { continue }
                let menu = NSMenu()
                sidebar.fill(menu, row: row)
                log("rowmenu \(argument): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
                break
            }
        case "menuitem":
            // menuitem <row name> > <title>: chooses an item of that row's context menu.
            let bits = argument.components(separatedBy: " > ")
            guard bits.count == 2, let sidebar = workspace?.sidebar else { break }
            let outline = sidebar.outline
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, cell.textField?.stringValue == bits[0] else { continue }
                let menu = NSMenu()
                sidebar.fill(menu, row: row)
                if let index = menu.items.firstIndex(where: { $0.title == bits[1] }) { menu.performActionForItem(at: index) }
                log("menuitem \(argument)")
                break
            }
        case "clickeye", "clickplus":
            // clickeye <title>, clickplus <title>: presses the eye or the plus (New Folder) on a section's header.
            guard let outline = workspace?.sidebar?.outline else { break }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell, cell.label.stringValue == argument else { continue }
                let button = command == "clickeye" ? cell.hiddenButton : cell.addButton
                log("\(command) \(argument)" + (button.isHidden ? ": hidden" : ""))
                if !button.isHidden { button.performClick(nil) }
                break
            }
        case "exportto":
            // exportto <pdf|png> <path>: writes the open note without asking where.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if let editor, bits.count == 2 {
                let title = usesFileWindow ? (window?.title ?? "") : (workspace?.currentTitle ?? "")
                Task { @MainActor in
                    let data = await NoteExporter.data(for: editor, title: title, as: bits[0] == "png" ? .png : .pdf)
                    try? data?.write(to: URL(fileURLWithPath: bits[1]))
                    log("exportto \(bits[0]): \(data?.count ?? 0) bytes")
                }
            }
        case "set":
            // set <setting> <value>: face, size, spacing, width, headings, onlynotes, dim, foldersfirst, order (name, dateEdited,
            // dateCreated), deleteempty, color.<kind> (note, pdf, image, video, audio, other) with a tag colour or accent.
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2 else { break }
            let settings = NotebookSettings.shared
            switch bits[0] {
            case "face": if let face = Typography.Face(rawValue: bits[1]) { settings.typography.face = face }
            case "size": if let size = Double(bits[1]) { settings.typography.size = size }
            case "spacing": if let spacing = Typography.Spacing(rawValue: bits[1]) { settings.typography.spacing = spacing }
            case "width": if let width = Typography.Width(rawValue: bits[1]) { settings.typography.width = width }
            case "headings": if let marks = NotebookSettings.HeadingMarks(rawValue: bits[1]) { settings.headingMarks = marks }
            case "onlynotes": settings.showsOnlyNotes = bits[1] == "1"
            case "dim": settings.dimsOtherFiles = bits[1] == "1"
            case "foldersfirst": settings.foldersFirst = bits[1] == "1"
            case "order": if let order = FileOrder(rawValue: bits[1]) { settings.fileOrders.set(order, for: workspace?.folderInView) }
            case "deleteempty": settings.deletesEmptyNewNotes = bits[1] == "1"
            case let key where key.hasPrefix("color."):
                guard let kind = FileKind(rawValue: String(key.dropFirst(6))), kind != .folder else { break }
                settings.fileColors[kind] = FolderColor.allCases.first { $0.name.lowercased() == bits[1].lowercased() }
            default: break
            }
            log("set \(argument)")
        case "searchfocus":
            // searchfocus: the caret in the toolbar's search field, as ⌥⌘F puts it there.
            workspace?.search.focus()
        case "palette":
            // palette: opens or closes ⌘K; palette rows: what it lists.
            if argument == "rows" {
                log("palette \(String(describing: workspace?.palette)): " + describe(workspace?.paletteSearch.sections ?? []))
            } else {
                workspace?.togglePalette()
            }
        case "search":
            // search <text>: what the toolbar's suggestions menu lists for it, once the search in the background is done.
            if let search = workspace?.search {
                search.field.stringValue = argument
                search.session.update(argument)
                let start = CACurrentMediaTime()
                func report() {
                    guard !search.session.isSearching else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: report)
                        return
                    }
                    log(String(format: "search %@ (%.1f ms, in the background %.1f ms): ", argument, (CACurrentMediaTime() - start) * 1000,
                               search.session.lastDuration * 1000) + describe(search.session.sections))
                }
                report()
            }
        case "searchtime":
            // searchtime <text>: how long search takes for every letter of the text, typed one after another.
            guard let corpus = workspace?.index.corpus else { break }
            var line = "searchtime (\(corpus.items.count) files, \(corpus.documents.count) texts):"
            for end in 1...max(1, argument.count) {
                let typed = String(argument.prefix(end))
                guard let query = SearchCorpus.Query(typed) else { continue }
                let start = CACurrentMediaTime()
                let results = corpus.search(query)
                line += String(format: " %@=%.1fms(%d+%d+%d)", typed, (CACurrentMediaTime() - start) * 1000, results.files.count, results.texts.count, results.pictures.count)
            }
            log(line)
        case "index":
            // index: how the index was built and kept since launch, and what search has now.
            guard let index = workspace?.index else { break }
            log("index files=\(index.count) building=\(index.isBuilding) search=\(index.corpus.items.count) | " + index.history.joined(separator: " | "))
        case "spotlight":
            // spotlight […]: see `Workspace.spotlightCommand`.
            if let workspace { log(workspace.spotlightCommand(argument)) }
        case "recognizer":
            // recognizer [file]: what reading text in pictures is doing, or what it read in a file.
            if argument.isEmpty {
                log("recognizer \(workspace?.recognizer.status ?? "")")
            } else {
                log("recognizer \(argument): \(workspace?.recognizer.text(for: argument) ?? "nothing")")
            }
        case "searchfield":
            // searchfield: where the search field, its buttons and the text you type in it are, in the field's points.
            guard let field = workspace?.search.field, let cell = field.cell as? NSSearchFieldCell else { break }
            let bounds = field.bounds
            var line = "searchfield frame=\(field.convert(bounds, to: nil)) bounds=\(bounds) focused=\(field.currentEditor() != nil)"
            line += " glass=\(cell.searchButtonRect(forBounds: bounds)) text=\(cell.searchTextRect(forBounds: bounds)) clear=\(cell.cancelButtonRect(forBounds: bounds))"
            if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                line += " editor=\(editor.convert(editor.bounds, to: field)) typed=\(editor.convert(used, to: field))"
            }
            log(line)
        case "selectlist":
            // selectlist <row>: selects a row of the inspector's list, as a click on it does.
            if let root = window?.contentView?.superview, let row = numbers.first.map(Int.init) {
                func lists(in view: NSView) -> [NSOutlineView] {
                    (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(lists)
                }
                if let list = lists(in: root).first(where: { $0 !== workspace?.sidebar?.outline }) {
                    list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    log("selectlist \(row) of \(list.numberOfRows)")
                }
            }
        case "expanded":
            // expanded: the folders open in the sidebar.
            if let outline = workspace?.sidebar?.outline {
                let names = (0..<outline.numberOfRows).compactMap { row -> String? in
                    guard let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) else { return nil }
                    return node.name
                }
                log("expanded: " + names.joined(separator: ", "))
            }
        case "movetargets":
            // movetargets: the folders Move To lists for the open file.
            if let workspace, let url = workspace.currentURL {
                log("movetargets: " + workspace.moveTargets(for: url).map { target in
                    "[\(target.location.name)] " + target.folders.map { String(repeating: "·", count: max(0, $0.depth)) + $0.name }.joined(separator: ", ")
                }.joined(separator: " "))
            }
        case "movetomenu":
            // movetomenu file|more|row <name> [> <folder>]: what Move To holds in the File menu, the toolbar's More menu
            // or a sidebar row's menu once that menu opens, and with a folder, chooses it. More is opened for real (its
            // menu shows for a moment); the File menu is told it opens, as AppKit tells it.
            let bits = argument.components(separatedBy: " > ")
            let which = bits[0], pick = bits.count > 1 ? bits[1] : nil
            func report(_ menu: NSMenu) {
                guard let item = menu.items.first(where: { $0.title == "Move To" }), let submenu = item.submenu else {
                    log("movetomenu: no Move To in \(menu.items.map(\.title))"); return
                }
                let start = CACurrentMediaTime()
                submenu.delegate?.menuNeedsUpdate?(submenu)
                let titles = submenu.items.map { ($0.isEnabled ? "" : "~") + String(repeating: "·", count: $0.indentationLevel) + $0.title }
                log(String(format: "movetomenu: %@ %d items in %.1f ms: ", String(describing: type(of: submenu)), titles.count, (CACurrentMediaTime() - start) * 1000) + titles.prefix(12).joined(separator: ", "))
                if let pick, let index = submenu.items.firstIndex(where: { $0.title == pick && $0.isEnabled }) {
                    submenu.performActionForItem(at: index)
                    log("movetomenu: moved to \(pick), now \(workspace?.currentURL?.path ?? "nothing")")
                }
            }
            if which == "file" {
                guard let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu, let main = NSApp.mainMenu else { break }
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
                file.delegate?.menuNeedsUpdate?(file)
                report(file)
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: main)
            } else if which.hasPrefix("row "), let sidebar = workspace?.sidebar {
                let name = String(which.dropFirst(4))
                let outline = sidebar.outline
                for row in 0..<outline.numberOfRows {
                    guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, cell.textField?.stringValue == name else { continue }
                    let menu = NSMenu()
                    sidebar.fill(menu, row: row)
                    report(menu)
                    break
                }
            } else {
                guard let more = window?.toolbar?.items.first(where: { $0.label == "More" }), let view = more.view, let content = window?.contentView else {
                    log("movetomenu: no More in \(window?.toolbar?.items.map(\.label) ?? [])"); break
                }
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { notification in
                    MainActor.assumeIsolated { trackedMenu = notification.object as? NSMenu }
                    // Once the menu is up: report, then close it.
                    let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            guard let menu = trackedMenu else { return }
                            report(menu)
                            menu.cancelTracking()
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
                // A click reaches the toolbar of a key window only; the app stays in the background.
                window?.makeKey()
                let frame = view.convert(view.bounds, to: nil)
                click(at: CGPoint(x: frame.midX, y: content.bounds.height - frame.midY))
                // SwiftUI opens the menu a moment later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationCenter.default.removeObserver(observer) }
            }
        case "mainmenu":
            // mainmenu <Menu> [> <Item>] [seconds]: opens a menu of the menu bar in the window, at its top left, as if
            // dropped down from the menu bar (which a window in the background hasn't got), and closes it after a few
            // seconds, for a picture of it. With an item, that item's submenu instead, where it opens next to the menu.
            // A menu opened this way takes no clicks or pointer moves sent to it; Accessibility can highlight an item.
            var bits = argument.components(separatedBy: " > ")
            let seconds = bits.last?.split(separator: " ").last.flatMap { Double($0) }
            if seconds != nil { bits[bits.count - 1] = bits[bits.count - 1].split(separator: " ").dropLast().joined(separator: " ") }
            guard let window, let content = window.contentView, let menu = NSApp.mainMenu?.item(withTitle: bits[0])?.submenu else { log("mainmenu: no \(argument)"); break }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            var shown = menu
            var point = NSPoint(x: 90, y: 60)
            if bits.count > 1 {
                guard let index = menu.items.firstIndex(where: { $0.title == bits[1] }), let submenu = menu.items[index].submenu else { log("mainmenu: no submenu \(argument)"); break }
                submenu.delegate?.menuNeedsUpdate?(submenu)
                submenu.update()
                shown = submenu
                // Where it opens next to the menu: at the right of the menu, its first item level with the item.
                point.x += menu.size.width - 6
                point.y += menu.items[..<index].reduce(CGFloat(0)) { height, item in height + (item.isHidden ? 0 : item.isSeparatorItem ? 11 : 24) }
            }
            if !content.isFlipped { point.y = content.bounds.height - point.y }
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: shown, queue: nil) { _ in
                MainActor.assumeIsolated { log("mainmenu: open") }
                let close = Timer(timeInterval: seconds ?? 3, repeats: false) { _ in MainActor.assumeIsolated { shown.cancelTracking() } }
                RunLoop.main.add(close, forMode: .common)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shown.popUp(positioning: nil, at: point, in: content)
                NotificationCenter.default.removeObserver(observer)
                log("mainmenu: closed")
            }
        case "toolbarmenu", "headingmenu":
            // toolbarmenu <label> [seconds]: opens a toolbar item's menu for real; headingmenu [seconds]: the menu of the
            // heading level in the margin. Logs each item's font and symbol and closes the menu after a second, or
            // after the seconds given, to take a picture of it in the meantime.
            let bits = argument.split(separator: " ").map(String.init)
            let label = command == "toolbarmenu" ? bits.dropLast(bits.count > 1 && Double(bits.last!) != nil ? 1 : 0).joined(separator: " ") : ""
            let seconds = bits.last.flatMap(Double.init) ?? 1
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu, menu !== NSApp.mainMenu else { return }
                    trackedMenu = menu
                    for item in menu.items {
                        let font = item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                        log("  \(item.isSeparatorItem ? "—" : item.title) font=\(font.map { "\($0.fontName) \($0.pointSize)" } ?? "-") image=\(item.image != nil)\(item.state == .on ? " on" : "")\(item.submenu != nil ? " ›" : "")")
                    }
                }
                let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                    MainActor.assumeIsolated { trackedMenu?.cancelTracking() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) { NotificationCenter.default.removeObserver(observer) }
            if command == "headingmenu" {
                guard let editor, let (_, marker) = editor.headingMarkLevel,
                      let rect = editor.layoutManager.headingMarkRect(at: marker.location, origin: editor.textView.textContainerOrigin) else {
                    log("headingmenu: the caret isn't on a heading"); break
                }
                log("headingmenu:")
                editor.showHeadingMenu(at: NSPoint(x: rect.minX, y: rect.maxY))
            } else {
                guard let item = window?.toolbar?.items.first(where: { $0.label == label }), let view = item.view, let content = window?.contentView else {
                    log("toolbarmenu: no \(label) in \(window?.toolbar?.items.map(\.label) ?? [])"); break
                }
                log("toolbarmenu \(label):")
                // A click reaches the toolbar of a key window only; the app stays in the background.
                window?.makeKey()
                let frame = view.convert(view.bounds, to: nil)
                click(at: CGPoint(x: frame.midX, y: content.bounds.height - frame.midY))
            }
        case "searchpick":
            // searchpick <n>: chooses the nth suggestion, counted over all sections.
            if let search = workspace?.search, let n = numbers.first.map(Int.init) {
                let items = search.session.sections.flatMap(\.items)
                if let item = items[safe: n] { search.run(item.result) }
            }
        case "newnote":
            workspace?.newNote()
        case "defaultfolder":
            // defaultfolder [<path>|inbox]: chooses Settings' default folder, then says which it is.
            guard let workspace else { break }
            if argument == "inbox" { workspace.chooseDefaultFolder(nil) }
            if argument.hasPrefix("/") { workspace.chooseDefaultFolder(URL(fileURLWithPath: argument, isDirectory: true)) }
            log("defaultfolder: \(workspace.defaultFolder?.path ?? "none") (chosen \(workspace.chosenDefaultFolder ?? "none"))")
        case "defaultfoldermenu":
            // defaultfoldermenu [<folder>]: what Settings' default folder pop-up holds as it opens, and with a folder,
            // chooses it; then what it holds closed again. defaultfoldermenu open: opens it for real for two seconds,
            // for a picture.
            func popUps(in view: NSView) -> [NSPopUpButton] {
                (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popUps)
            }
            guard let button = NSApp.windows.lazy.compactMap({ $0.contentView }).flatMap(popUps).first(where: { $0.accessibilityLabel() == "Default folder" }),
                  let menu = button.menu else { log("defaultfoldermenu: no pop-up; open Settings first"); break }
            if argument == "open" {
                let timer = Timer(timeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { menu.cancelTracking() } }
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.async { button.performClick(nil) }
                break
            }
            let start = CACurrentMediaTime()
            menu.delegate?.menuNeedsUpdate?(menu)
            let titles = menu.items.map { ($0.isSectionHeader ? "[" : "") + String(repeating: "·", count: $0.indentationLevel) + $0.title + ($0.isSectionHeader ? "]" : "") }
            log(String(format: "defaultfoldermenu: %d items in %.1f ms, selected %@: ", titles.count, (CACurrentMediaTime() - start) * 1000, button.titleOfSelectedItem ?? "nothing") + titles.prefix(20).joined(separator: ", "))
            if !argument.isEmpty, let index = menu.items.firstIndex(where: { $0.title == argument && !$0.isSectionHeader }) {
                menu.performActionForItem(at: index)
            }
            menu.delegate?.menuDidClose?(menu)
            DispatchQueue.main.async {
                log("defaultfoldermenu: closed with \(menu.items.map(\.title)), selected \(button.titleOfSelectedItem ?? "nothing"), now \(workspace?.defaultFolder?.path ?? "none")")
            }
        case "drop":
            // drop <file> > <folder>: what dragging a file onto a folder in the sidebar does (Option: dropcopy).
            let paths = argument.components(separatedBy: " > ")
            if paths.count == 2 { workspace?.drop([URL(fileURLWithPath: paths[0])], into: URL(fileURLWithPath: paths[1], isDirectory: true)) }
        case "links":
            // links: every link in the open note and the file a click on it opens.
            log("links: " + (workspace?.debugLinks() ?? ""))
        case "mainthread":
            // mainthread: how many folders were read and files changed on the main thread so far (none should be).
            log("mainthread: \(FileNode.mainThreadReads.withLock { $0 }) folder reads, \(FileOperations.mainThreadWrites.withLock { $0 }) file changes")
        case "swipe":
            // swipe back|forward <0…1>: holds a swipe still part of the way; swipe back|forward play: the whole
            // thing by itself; swipe end 1|0: goes to the page, or back to where it started.
            let bits = argument.split(separator: " ").map(String.init)
            guard let pages = workspace?.pages, let first = bits.first else { break }
            if first == "end" {
                pages.end(commit: bits.count > 1 && bits[1] == "1")
            } else {
                let direction: PageSwiper.Direction = first == "back" ? .back : .forward
                if bits.count > 1, bits[1] == "play" { pages.debugPlay(direction) } else { pages.debugShow(direction, numbers.first ?? 0.5) }
            }
            log("swipe \(argument)")
        case "undo", "redo":
            // undo, redo: Edit › Undo and Redo, as the menu sends them, to the first responder and up from there to
            // what takes them (in the end the window, with its undo manager). Says what the item said.
            guard let window else { break }
            let action = Selector((command + ":"))
            var target: NSResponder? = window.firstResponder
            while let responder = target, !responder.responds(to: action) { target = responder.nextResponder }
            let item = NSMenuItem(title: command == "undo" ? "Undo" : "Redo", action: action, keyEquivalent: "")
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target != nil)
            log("\(command): \(item.title) enabled=\(enabled) in \(target.map { String(describing: type(of: $0)) } ?? "nothing") from \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")")
            if enabled { NSApp.sendAction(action, to: target, from: item) }
        case "undostate":
            // undostate: how the window's undo manager groups what is done.
            if let manager = window?.undoManager {
                log("undostate level=\(manager.groupingLevel) byEvent=\(manager.groupsByEvent) modes=\(manager.runLoopModes.map(\.rawValue)) undo “\(manager.undoActionName)” redo “\(manager.redoActionName)” files=\(manager === workspace?.fileUndoManager) \(type(of: manager))")
            }
        case "loaddelay", "pdfdelay":
            // loaddelay <seconds>: reading a note, PDF, picture or video takes this long (0 for as long as it really
            // takes).
            FileLoading.debugDelay = numbers.first.flatMap { $0 > 0 ? $0 : nil }
        case "pictureinfo":
            // pictureinfo: the open picture's size, zoom and where it sits.
            if let view = window?.contentView.flatMap(pictureView), let picture = view.picture {
                log("picture size=\(picture.size) pixelsPerPoint=\(picture.pixelsPerPoint) animated=\(picture.animation != nil) zoom=\(view.magnification) fitting=\(view.fittingMagnification) fits=\(view.fits) clip=\(view.contentView.bounds) frame=\(view.frame) insets=\(view.contentInsets)")
            } else {
                log("picture none")
            }
        case "picturezoom":
            // picturezoom: what a double click in the middle of the open picture does.
            if let view = window?.contentView.flatMap(pictureView) {
                view.toggleZoom(at: NSPoint(x: view.contentView.bounds.midX, y: view.contentView.bounds.midY))
            }
        case "pdfinfo":
            // pdfinfo: how far the open PDF is scrolled, its zoom and its insets.
            if let pdf = window?.contentView.flatMap(pdfView), let scrollView = pdf.documentView?.enclosingScrollView {
                log("pdf clip=\(scrollView.contentView.bounds) scale=\(pdf.scaleFactor) auto=\(pdf.autoScales) insets=\(scrollView.contentInsets) document=\(scrollView.documentView?.frame ?? .zero) selection=\(pdf.currentSelection?.string ?? "none")")
            }
        case "pdfpen":
            // pdfpen [off]: the pencil above the open PDF, on or off.
            workspace?.drawsOnPDF = argument == "off" ? nil : workspace?.currentPDF
        case "pdfdraw":
            // pdfdraw [shift] <page> x y x y …: a drag through points on a page (from its crop box's top left, page
            // points, the page counted from 1), as real events, with Shift held if asked.
            var bits = argument.split(separator: " ").map(String.init)
            let shift = bits.first == "shift"
            if shift { bits.removeFirst() }
            let values = bits.compactMap { Double($0) }
            guard let pdf = window?.contentView.flatMap(pdfView), values.count >= 5, let page = pdf.document?.page(at: Int(values[0]) - 1) else {
                return log("pdfdraw: no page")
            }
            let points = stride(from: 1, to: values.count - 1, by: 2).compactMap { windowPoint(on: page, x: values[$0], y: values[$0 + 1], in: pdf) }
            drag(through: points, modifiers: shift ? .shift : [])
        case "pdfsave":
            // pdfsave: what going to another app or quitting does while drawing on a PDF.
            PDFDrawingSession.saveAll()
        case "pdfcanvases":
            // pdfcanvases: the canvases over the open PDF's pages, while drawing.
            guard let pdf = window?.contentView.flatMap(pdfView) else { return log("pdfcanvases: no PDF") }
            let canvases = pdf.canvases.map { canvas in
                let strokes = canvas.strokes.strokes.map { "\($0.ink.inkType.rawValue) \(String(format: "%06X", $0.ink.color.hexValue)) \($0.renderBounds.integral)" }
                return "page \(canvas.pageIndex + 1): \(strokes.count) strokes [\(strokes.joined(separator: ", "))], frame \(canvas.frame.integral), scale \(String(format: "%.3f", canvas.scale)), takes \(canvas.takesEvents)"
            }
            log("pdfcanvases markup=\(pdf.isInMarkupMode) first=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") \(canvases.joined(separator: "; "))")
        case "pdfselect":
            // pdfselect <page> <words>: selects the words on that page, as a drag over them does.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let pdf = window?.contentView.flatMap(pdfView), bits.count == 2, let number = Int(bits[0]), let page = pdf.document?.page(at: number - 1),
                  let text = page.string else { return log("pdfselect: no page") }
            let range = (text as NSString).range(of: bits[1])
            guard range.location != NSNotFound, let selection = page.selection(for: range) else { return log("pdfselect: no “\(bits[1])”") }
            pdf.setCurrentSelection(selection, animate: false)
            log("pdfselect “\(selection.string ?? "")” canHighlight=\(workspace?.canHighlight ?? false)")
        case "pdfhighlight":
            // pdfhighlight [colour]: Format › Highlight, or the colour picked in the menu on the text selected.
            if let color = HighlightColor(rawValue: argument), let pdf = window?.contentView.flatMap(pdfView) as? NotebookPDFView {
                pdf.highlight(in: color)
            } else {
                workspace?.highlight()
            }
        case "pdfannotations":
            // pdfannotations: every page's annotations, as the PDF on screen has them.
            guard let document = window?.contentView.flatMap(pdfView)?.document else { return log("pdfannotations: no PDF") }
            var lines: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.type != "Link" {
                    let quads = annotation.quadrilateralPoints?.count ?? 0
                    let color = String(format: "%06X", annotation.color.hexValue)
                    let notebook = annotation.value(forAnnotationKey: MarkupDrawings.notebookKey) != nil
                    lines.append("page \(index + 1) \(annotation.type ?? "?") \(annotation.bounds.integral) quads=\(quads) color=\(color) shown=\(annotation.shouldDisplay)\(notebook ? " notebook-strokes" : "")")
                }
            }
            log("pdfannotations \(lines.isEmpty ? "none" : lines.joined(separator: " | "))")
        case "pdfmenu", "pdfmenupick":
            // pdfmenu <page> x y: the menu a right click there shows. pdfmenupick <page> x y <item>: picks an item in it,
            // by its title or a colour's name.
            let bits = argument.split(separator: " ", maxSplits: 3).map(String.init)
            guard let pdf = window?.contentView.flatMap(pdfView), let window, bits.count >= 3, let number = Int(bits[0]),
                  let page = pdf.document?.page(at: number - 1), let x = Double(bits[1]), let y = Double(bits[2]),
                  let point = windowPoint(on: page, x: x, y: y, in: pdf),
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: point.x, y: (window.contentView?.bounds.height ?? 0) - point.y),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = pdf.menu(for: event) else { return log("\(command): no menu") }
            func describe(_ item: NSMenuItem) -> String {
                if item.isSeparatorItem { return "—" }
                if let palette = item.submenu, palette.presentationStyle == .palette {
                    return "[" + palette.items.map { $0.title + ($0.state == .on ? "✓" : "") }.joined(separator: " ") + "]"
                }
                let key = item.keyEquivalent.isEmpty ? "" : " (\(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")⌘\(item.keyEquivalent.uppercased()))"
                let action = item.action.map { " <\(NSStringFromSelector($0))>" } ?? (item.view.map { " <view \(type(of: $0))>" } ?? "")
                let submenu = item.submenu.map { " {" + $0.items.map(\.title).joined(separator: ", ") + "}" } ?? ""
                return item.title + key + action + submenu
            }
            if command == "pdfmenu", bits.count == 4, let seconds = Double(bits[3]) {
                // pdfmenu <page> x y <seconds>: opens it for real, for a picture, and closes it after the seconds.
                trackedMenu = menu
                let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { trackedMenu?.cancelTracking() } }
                RunLoop.main.add(timer, forMode: .common)
                log("pdfmenu open")
                NSMenu.popUpContextMenu(menu, with: event, for: pdf)
                return
            }
            guard command == "pdfmenupick", bits.count == 4 else {
                return log("pdfmenu " + menu.items.map(describe).joined(separator: " · "))
            }
            for (index, item) in menu.items.enumerated() {
                if item.title == bits[3] {
                    menu.performActionForItem(at: index)
                    return log("pdfmenupick \(bits[3])")
                }
                if let palette = item.submenu, palette.presentationStyle == .palette,
                   let choice = palette.items.firstIndex(where: { $0.title == bits[3] }) {
                    palette.performActionForItem(at: choice)
                    return log("pdfmenupick colour \(bits[3]), selected \(palette.selectedItems.map(\.title))")
                }
            }
            log("pdfmenupick: no \(bits[3])")
        case "pdfscroll":
            // pdfscroll <y>: scrolls the open PDF, in its pages' points from the top.
            if let pdf = window?.contentView.flatMap(pdfView), let scrollView = pdf.documentView?.enclosingScrollView, let y = numbers.first {
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        default:
            // Reminders' commands, which iPhone and iPad have too: paths are absolute or in the first location.
            let resolve = { (path: String) -> URL? in
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace?.locations.first?.url.appendingPathComponent(path)
            }
            if let workspace, DebugReminders.run(command, argument, workspace: workspace, url: resolve, log: log) { break }
            if let workspace, DebugFolderIcons.run(command, argument, workspace: workspace, url: resolve, log: log) { break }
            if let workspace, DebugTodos.run(command, argument, workspace: workspace, log: log) { break }
            if let workspace, DebugVersions.run(command, argument, workspace: workspace, log: log) { break }
            log("unknown command: \(line)")
        }
    }

    private static func pictureView(in view: NSView) -> PictureScrollView? {
        if let picture = view as? PictureScrollView { return picture }
        return view.subviews.lazy.compactMap(pictureView).first
    }

    private static func pdfView(in view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap(pdfView).first
    }

    /// A point on a page, from its crop box's top left in page points, in window points from the top left.
    private static func windowPoint(on page: PDFPage, x: Double, y: Double, in pdf: PDFView) -> CGPoint? {
        guard let content = pdf.window?.contentView else { return nil }
        let crop = page.bounds(for: .cropBox)
        let inWindow = pdf.convert(pdf.convert(CGPoint(x: crop.minX + x, y: crop.maxY - y), from: page), to: nil)
        return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
    }

    /// The caret as proposed by AppKit (the line's used rect, as when it blinks, and `firstRect`, as `showcaret` draws
    /// it) and as drawn, next to the baseline and font of the nearest text on its line. Window points from the top left.
    private static func caretInfo(_ editor: EditorController) {
        guard let window else { return }
        let view = editor.textView, layout = editor.layoutManager, origin = view.textContainerOrigin
        let index = view.selectedRange().location
        func inWindow(_ rect: NSRect) -> String {
            let r = view.convert(rect, to: nil)
            return String(format: "y %.2f–%.2f (h %.2f) x %.1f", window.frame.height - r.maxY, window.frame.height - r.minY, r.height, r.minX)
        }
        let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, editor.storage.length - 1)))
        var glyphs = NSRange()
        var used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        if index >= editor.storage.length, layout.extraLineFragmentTextContainer != nil { used = layout.extraLineFragmentUsedRect }
        let x = view.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
        let proposed = NSRect(x: view.convert(window.convertFromScreen(x), from: nil).minX, y: used.minY + origin.y, width: 1, height: used.height)
        let first = view.convert(window.convertFromScreen(x), from: nil)
        log("caretinfo \(index): used \(inWindow(proposed)) → caret \(inWindow(editor.caretRect(proposed: proposed)))")
        log("caretinfo \(index): firstRect \(inWindow(first)) → caret \(inWindow(editor.caretRect(proposed: NSRect(x: first.minX, y: first.minY, width: 2, height: first.height))))")
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = editor.text as NSString
        if let character = (characters.location..<NSMaxRange(characters)).first(where: { text.character(at: $0) != 10 && !layout.isHidden($0) }) {
            let g = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let baseline = origin.y + line.minY + layout.location(forGlyphAt: g).y
            let font = editor.storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? EditorStyle.body
            let offset = editor.storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat ?? 0
            log(String(format: "caretinfo \(index): text '%@' %@ %.1f pt, ascender %.2f descender %.2f offset %.2f, line \(inWindow(NSRect(x: 0, y: origin.y + line.minY, width: 1, height: line.height))), ascender–descender \(inWindow(NSRect(x: 0, y: baseline - font.ascender, width: 1, height: font.ascender - font.descender)))",
                       text.substring(with: NSRange(location: character, length: 1)), font.fontName, font.pointSize, font.ascender, font.descender, offset))
        }
    }

    private static func dump() {
        guard let editor else { return }
        let selection = editor.textView.selectedRange()
        let text = editor.text.replacingOccurrences(of: "\n", with: "⏎")
        log("""
        --- dump
        file: \(workspace?.currentURL?.path ?? "none")
        title: \(editor.titleText) waiting: \(editor.isWaitingForText) pending: \(workspace?.note?.pending.map { "\($0)" } ?? "none") editingTitle: \(editor.isEditingTitle) titleSelection: \((editor.textView.titleField.currentEditor() as? NSTextView).map { "\($0.selectedRange().location) \($0.selectedRange().length)" } ?? "none")
        selection: \(selection.location) \(selection.length)
        revealed: \(editor.revealed.map { "\($0.location)+\($0.length)" }.joined(separator: " "))
        activeBlock: \(editor.activeBlock.map(String.init) ?? "none")
        responder: \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        scroll: \(Int(editor.scrollView.contentView.bounds.minY)) inset: \(Int(editor.scrollView.contentInsets.top))
        outline: \(workspace?.outline.map { "\($0.level):\($0.title)" }.joined(separator: ", ") ?? "") current: \(workspace?.currentHeading.map(String.init) ?? "title") titleAway: \(workspace?.isTitleScrolledAway == true)
        search: \(workspace?.search.field.stringValue ?? "")
        text: \(text.prefix(4000))
        """)
    }

    private static func sidebarRowPoint(named name: String) -> CGPoint? {
        guard let outline = workspace?.sidebar?.outline, let window, let content = window.contentView else { return nil }
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.textField?.stringValue == name else { continue }
            outline.scrollRowToVisible(row)
            outline.enclosingScrollView?.layoutSubtreeIfNeeded()
            let rect = outline.rect(ofRow: row)
            let inWindow = outline.convert(NSPoint(x: rect.minX + 80, y: rect.midY), to: nil)
            let back = outline.convert(inWindow, from: nil)
            log("row \(row) \(name): rect=\(rect) row at point=\(outline.row(at: back)) flipped=\(outline.isFlipped)")
            return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
        }
        return nil
    }

    /// Where a picture, table or diagram on a line of its own is drawn.
    private static func blockObjectRect(_ editor: EditorController, _ index: Int) -> NSRect? {
        guard let object = editor.layoutManager.object(at: index), object.isBlock else { return nil }
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: index)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = editor.storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let size = layout.blockSize(object, at: index, width: line.width - (style?.firstLineHeadIndent ?? 0))
        let origin = editor.textView.textContainerOrigin
        return NSRect(x: line.minX + origin.x, y: line.minY + origin.y + (style?.paragraphSpacingBefore ?? 0), width: size.width, height: size.height)
    }

    private static func windowPoint(ofCharacter index: Int, fraction: Double, in editor: EditorController) -> CGPoint? {
        guard let window, let content = window.contentView, index <= editor.storage.length else { return nil }
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, editor.storage.length - 1)))
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container)
        if index >= editor.storage.length { rect.origin.x = rect.maxX; rect.size.width = 0 }
        let origin = editor.textView.textContainerOrigin
        let inText = NSPoint(x: rect.minX + rect.width * fraction + origin.x, y: rect.midY + origin.y)
        let inWindow = editor.textView.convert(inText, to: nil)
        return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
    }

    // MARK: - Events

    /// Clicks by handing the events straight to the view under the point, so it works while Notebook is in the
    /// background and never moves the real pointer or takes the focus from what you are doing.
    private static func click(at point: CGPoint, dragTo end: CGPoint? = nil, count: Int = 1, right: Bool = false) {
        guard let window, let content = window.contentView else { return }
        let location = CGPoint(x: point.x, y: content.bounds.height - point.y)
        let endLocation = end.map { CGPoint(x: $0.x, y: content.bounds.height - $0.y) } ?? location
        let root = content.superview ?? content
        guard var target = root.hitTest(location) else { log("click: nothing at \(point)"); return }
        // Rows of a list take their clicks in the list, as a real click does.
        var ancestor: NSView? = target
        while let view = ancestor {
            if view is NSTableView { target = view; break }
            ancestor = view.superview
        }
        func event(_ type: NSEvent.EventType, _ at: CGPoint, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        }
        // A button over the note (a code block's copy button) tracks clicks with a gesture recognizer, which only sees
        // events the window delivers to a key window: press it the way accessibility does.
        if let button = target as? NSButton, button.superview is NSTextView, end == nil, !right {
            button.performClick(nil)
            log("press \(Int(point.x)),\(Int(point.y)) on \(type(of: button))")
            return
        }
        // SwiftUI controls track clicks through the window, so they get the events the way the window would send them.
        let isAppKitView = sequence(first: target, next: { $0.superview }).contains { $0 is NSTextView || $0 is NSTableView }
        if !isAppKitView, end == nil, !right {
            for click in 1...count {
                if let down = event(.leftMouseDown, location, clicks: click) {
                    NotificationCenter.default.post(name: clicked, object: down)
                    window.sendEvent(down)
                }
                if let up = event(.leftMouseUp, location, clicks: click) { window.sendEvent(up) }
            }
            log("click \(Int(point.x)),\(Int(point.y)) through the window on \(type(of: target))")
            return
        }
        for click in 1...count {
            if end != nil, click == count {
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let at = CGPoint(x: location.x + (endLocation.x - location.x) * t, y: location.y + (endLocation.y - location.y) * t)
                    if let drag = event(.leftMouseDragged, at, clicks: click) { NSApp.postEvent(drag, atStart: false) }
                }
            }
            if let up = event(.leftMouseUp, end != nil && click == count ? endLocation : location, clicks: click) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, location, clicks: click) {
                if window.firstResponder !== target, target.acceptsFirstResponder { window.makeFirstResponder(target) }
                target.mouseDown(with: down)
            }
            // Releases a view handled itself are left in the queue: take them out.
            while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        }
        log("click \(Int(point.x)),\(Int(point.y))\(end.map { " to \(Int($0.x)),\(Int($0.y))" } ?? "") on \(type(of: target))")
    }

    /// Mouse moves through the window, in points from its top-left corner: to `start`, then on to `end` in steps.
    private static func move(from start: CGPoint, to end: CGPoint?) {
        guard let window, let content = window.contentView else { return }
        var points = [start]
        if let end {
            points = (0...10).map { step -> CGPoint in
                let t = CGFloat(step) / 10
                return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            }
        }
        for point in points {
            let location = CGPoint(x: point.x, y: content.bounds.height - point.y)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(event)
            }
        }
        log("move to \(Int((end ?? start).x)),\(Int((end ?? start).y))")
    }

    /// Points every few pixels along a curve through `points`.
    private static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result: [CGPoint] = []
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            let steps = max(2, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 3))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func value(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                result.append(CGPoint(x: value(p0.x, p1.x, p2.x, p3.x), y: value(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// A mouse drag along points over `seconds`: the button goes down on the view under the first, and a timer
    /// moves it on while that view follows the mouse.
    private static func drag(along points: [CGPoint], seconds: Double) {
        guard let window, let content = window.contentView, let first = points.first, let last = points.last else { return }
        let root = content.superview ?? content
        let flip = { (point: CGPoint) in CGPoint(x: point.x, y: content.bounds.height - point.y) }
        guard let target = root.hitTest(flip(first)) else { return log("drawslow: nothing at \(first)") }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: flip(point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        var next = 1
        let interval = max(0.004, seconds / Double(max(1, points.count)))
        // On the main run loop, so on the main thread.
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                if next < points.count {
                    if let drag = event(.leftMouseDragged, points[next]) { NSApp.postEvent(drag, atStart: false) }
                    next += 1
                } else {
                    if let up = event(.leftMouseUp, last) { NSApp.postEvent(up, atStart: false) }
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        if let down = event(.leftMouseDown, first) { target.mouseDown(with: down) }
        timer.invalidate()
        log("drawslow \(points.count) points on \(type(of: target))")
    }

    /// A mouse drag through points, delivered to the view under the first one: down, dragged, up.
    private static func drag(through points: [CGPoint], modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let content = window.contentView, let first = points.first else { return }
        let root = content.superview ?? content
        let flip = { (point: CGPoint) in CGPoint(x: point.x, y: content.bounds.height - point.y) }
        guard let target = root.hitTest(flip(first)) else { return log("drawpath: nothing at \(first)") }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: flip(point), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        for (a, b) in zip(points, points.dropFirst()) {
            for step in 1...6 {
                let t = CGFloat(step) / 6
                if let drag = event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { NSApp.postEvent(drag, atStart: false) }
            }
        }
        if let up = event(.leftMouseUp, points[points.count - 1]) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, first) { target.mouseDown(with: down) }
        while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        log("drawpath \(points.count) points on \(type(of: target))")
    }

    private static func key(_ argument: String) {
        let bits = argument.split(separator: " ").map(String.init)
        guard let name = bits.first else { return }
        var modifiers: NSEvent.ModifierFlags = []
        if bits.contains("cmd") { modifiers.insert(.command) }
        if bits.contains("shift") { modifiers.insert(.shift) }
        if bits.contains("opt") { modifiers.insert(.option) }
        if bits.contains("ctrl") { modifiers.insert(.control) }
        let table: [String: (String, UInt16)] = [
            "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49), "delete": ("\u{7F}", 51), "escape": ("\u{1B}", 53),
            "forwarddelete": (String(UnicodeScalar(NSDeleteFunctionKey)!), 117),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
        ]
        let codes: [String: UInt16] = ["[": 33, "]": 30, ",": 43, "7": 26, "9": 25, "'": 39, "a": 0, "s": 1, "f": 3, "b": 11, "i": 34, "k": 40, "n": 45, "z": 6, "x": 7, "c": 8, "v": 9, "e": 14, "l": 37, "u": 32, "t": 17]
        if let (characters, code) = table[name] {
            if [123, 124, 125, 126].contains(code) { modifiers.insert(.function) }
            sendKey(characters, code: code, modifiers: modifiers)
        } else {
            sendKey(name, code: codes[name] ?? 0, modifiers: modifiers)
        }
    }

    /// Sends a key to Notebook's window directly (menus first, for shortcuts), so it works in the background.
    private static func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = self.window else { return }
        let ignoring = modifiers.contains(.shift) ? characters.lowercased() : characters
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: modifiers.contains(.shift) ? characters.uppercased() : characters,
                                          charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) else { return }
        if modifiers.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        if !modifiers.contains(.command) || !(window.firstResponder?.performKeyEquivalent(with: down) ?? false) {
            window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) {
            window.sendEvent(up)
        }
    }

    // MARK: - Snapshot

    /// The window as a PNG, drawn by the app itself so it works without screen recording permission.
    private static func snapshot(to path: String) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: bitmap)
        // Floating panels (the link popup) are windows of their own.
        let scale = window.backingScaleFactor
        if let cgImage = bitmap.cgImage, let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            for child in window.childWindows ?? [] where child.isVisible {
                guard let childView = child.contentView, let childBitmap = childView.bitmapImageRepForCachingDisplay(in: childView.bounds) else { continue }
                childView.cacheDisplay(in: childView.bounds, to: childBitmap)
                if let childImage = childBitmap.cgImage {
                    let x = (child.frame.minX - window.frame.minX) * scale
                    let y = (child.frame.minY - window.frame.minY) * scale
                    context.draw(childImage, in: CGRect(x: x, y: y, width: child.frame.width * scale, height: child.frame.height * scale))
                }
            }
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                log("snapshot \(path)")
                return
            }
        }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("snapshot \(path)")
    }
}
#endif
