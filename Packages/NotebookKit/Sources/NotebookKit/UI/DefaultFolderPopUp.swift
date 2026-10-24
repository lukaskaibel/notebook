#if os(macOS)
import AppKit
import SwiftUI

/// Settings' default folder on the Mac, as Reminders chooses its default list: a pop-up of every folder, indented under
/// its location as Move To lists them. Closed, it has only the folder chosen; the others are made when it opens and go
/// again when it closes, so Settings never waits for the thousands of folders a whole iCloud Drive has, nor grows as
/// wide as the longest of their names.
struct DefaultFolderPopUp: NSViewRepresentable {
    let workspace: Workspace
    /// The folder chosen, read where SwiftUI sees it change.
    let folder: URL?

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.menu = context.coordinator.menu
        button.setAccessibilityLabel("Default folder")
        context.coordinator.button = button
        context.coordinator.showChosen()
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.showChosen()
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        private weak var workspace: Workspace?
        weak var button: NSPopUpButton?
        let menu = NSMenu()

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init()
            menu.delegate = self
        }

        /// Only the folder chosen, as the button shows it.
        func showChosen() {
            guard let workspace, let button, let folder = workspace.defaultFolder else {
                menu.removeAllItems()
                return
            }
            let depth = workspace.locations.contains { FileNode.samePath($0.url, folder) } ? -1 : 0
            menu.items = [item(folder, name: workspace.folderName(folder), depth: depth, in: workspace.location(containing: folder))]
            button.select(menu.items.first)
        }

        /// Every folder, the chosen one ticked and over the button, as a pop-up opens.
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let workspace, let chosen = workspace.defaultFolder else { return }
            var items: [NSMenuItem] = []
            var selected: NSMenuItem?
            for target in workspace.defaultFolderChoices {
                items.append(.sectionHeader(title: target.location.name))
                for folder in target.folders {
                    let item = item(folder.url, name: folder.depth < 0 ? target.location.name : folder.name, depth: folder.depth, in: target.location)
                    if selected == nil, FileNode.samePath(folder.url, chosen) { selected = item }
                    items.append(item)
                }
            }
            // One hidden, or gone from the disk, stays chosen until another is.
            if selected == nil {
                let item = item(chosen, name: workspace.folderName(chosen), depth: 0, in: workspace.location(containing: chosen))
                items.insert(item, at: 0)
                selected = item
            }
            menu.items = items
            button?.select(selected)
        }

        func menuDidClose(_ menu: NSMenu) {
            // After the item chosen has been told.
            DispatchQueue.main.async { [weak self] in self?.showChosen() }
        }

        private func item(_ url: URL, name: String, depth: Int, in location: Location?) -> NSMenuItem {
            let item = NSMenuItem(title: name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let symbol = depth >= 0 ? "folder" : location?.isICloudDrive == true ? "icloud" : "externaldrive"
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.indentationLevel = min(max(0, depth), 15)
            return item
        }

        @objc private func choose(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            workspace?.chooseDefaultFolder(url)
        }
    }
}
#endif
