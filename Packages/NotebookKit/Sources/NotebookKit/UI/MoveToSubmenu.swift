#if os(macOS)
import AppKit

/// Move To's submenu on the Mac: every folder, indented under its location as in Notes, the one the file is in greyed.
/// Its items are made when it opens, not with the menu it is in, so opening a note or a menu never waits for an item
/// for each of the thousands of folders a whole iCloud Drive has.
@MainActor
final class MoveToSubmenu: NSMenu, NSMenuDelegate {
    private weak var workspace: Workspace?
    /// The file to move, when the submenu opens.
    private let file: () -> URL?
    /// What the items were made for: the file, and the folders as they were then.
    private var filled: (url: URL, folders: MoveFolders.Key)?

    init(workspace: Workspace, file: @escaping () -> URL?) {
        self.workspace = workspace
        self.file = file
        super.init(title: "Move To")
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let workspace, let url = file() else {
            removeAllItems()
            filled = nil
            return
        }
        let folders = workspace.moveFoldersInUse
        guard filled?.url != url || filled?.folders != folders else { return }
        let targets = workspace.moveTargets(for: url)
        filled = (url, folders)
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var items: [NSMenuItem] = []
        let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        for target in targets {
            items.append(.sectionHeader(title: target.location.name))
            for folder in target.folders {
                let item = NSMenuItem(title: folder.depth < 0 ? "Top Level" : folder.name, action: #selector(move(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder.url
                item.image = symbol
                item.indentationLevel = min(max(0, folder.depth), 15)
                item.isEnabled = folder.url.standardizedFileURL != parent
                items.append(item)
            }
        }
        self.items = items
    }

    @objc private func move(_ item: NSMenuItem) {
        guard let folder = item.representedObject as? URL, let url = filled?.url else { return }
        workspace?.move(url, into: folder)
    }

    /// SwiftUI's Move To items (in the File menu and the toolbar's More menu) are left empty and get this submenu,
    /// for the file that is open, whenever SwiftUI has brought their menu up to date: when it opens.
    static func fillSwiftUIMenus(for workspace: Workspace) {
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak workspace] notification in
            MainActor.assumeIsolated {
                guard let workspace, let menu = notification.object as? NSMenu else { return }
                // In the menu bar SwiftUI brings the File menu up to date only as it opens, after this.
                let menus = menu === NSApp.mainMenu ? [menu.item(withTitle: "File")?.submenu].compactMap { $0 } : [menu]
                for menu in menus where menu === NSApp.mainMenu?.item(withTitle: "File")?.submenu || hasSwiftUIMoveTo(menu) {
                    Relay.install(on: menu) { attach(in: $0, workspace: workspace) }
                }
            }
        }
    }

    private static func hasSwiftUIMoveTo(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.title == "Move To" && $0.submenu != nil && !($0.submenu is MoveToSubmenu) }
    }

    private static func attach(in menu: NSMenu, workspace: Workspace) {
        for item in menu.items where item.title == "Move To" && item.submenu != nil && !(item.submenu is MoveToSubmenu) {
            item.submenu = MoveToSubmenu(workspace: workspace) { [weak workspace] in workspace?.fileInFront }
        }
    }

    /// Takes the place of SwiftUI's delegate of a menu, passing everything on to it, and after SwiftUI has brought the
    /// menu up to date puts Move To's submenu in again.
    private final class Relay: NSObject, NSMenuDelegate {
        private weak var original: NSMenuDelegate?
        private let updated: (NSMenu) -> Void
        nonisolated(unsafe) private static var key: UInt8 = 0

        private init(original: NSMenuDelegate?, updated: @escaping (NSMenu) -> Void) {
            self.original = original
            self.updated = updated
        }

        static func install(on menu: NSMenu, updated: @escaping (NSMenu) -> Void) {
            updated(menu)
            guard !(menu.delegate is Relay) else { return }
            let relay = Relay(original: menu.delegate, updated: updated)
            // A menu doesn't keep its delegate.
            objc_setAssociatedObject(menu, &key, relay, .OBJC_ASSOCIATION_RETAIN)
            menu.delegate = relay
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            original?.menuNeedsUpdate?(menu)
            updated(menu)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}
#endif
