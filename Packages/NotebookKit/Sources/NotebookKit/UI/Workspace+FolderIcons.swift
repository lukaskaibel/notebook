#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A folder to customize, for the sheet on iPhone and iPad.
struct FolderIconRequest: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Customize Folder: a symbol or an emoji instead of the folder, and a colour, kept with the folder where the Finder
/// keeps them (`FolderIcons`), so they go wherever it goes.
extension Workspace {
    /// A folder's look, as the sidebar read it; nil for the plain folder or one not read yet.
    func folderIcon(for url: URL) -> FolderIcon? {
        node(for: url, reading: false)?.icon
    }

    /// Any folder in a location but a location's own top, and the folders iCloud Drive shows there from elsewhere
    /// (Desktop, Documents), which look the way the system has them.
    func canCustomize(_ url: URL) -> Bool {
        location(containing: url) != nil && !locations.contains { $0.url.path == url.standardizedFileURL.path } && !isLinkedFolder(url)
    }

    /// Shows a folder's new look at once and writes it off the main thread, after the changes to files asked for
    /// before. Then the folder it is in is read again, for a reading begun before it not to bring the old look back.
    func setFolderIcon(_ icon: FolderIcon?, for url: URL) {
        let icon = icon?.isPlain == true ? nil : icon
        if let node = node(for: url, reading: false), node.icon != icon {
            node.show(icon)
            sidebarRefreshRows()
        }
        changeFiles { [self] follow in
            let folder = follow(url)
            let written = await Task.detached(priority: .userInitiated) { FolderIcons.write(icon, to: folder) }.value
            if !written { beep() }
            readAgain([folder.deletingLastPathComponent()])
        }
    }

    /// One Undo for everything chosen while Customize Folder was open, and Redo for it.
    func keepFolderIconForUndo(from old: FolderIcon?, to new: FolderIcon?, for url: URL) {
        guard old != new else { return }
        let manager = fileUndoManager
        // As for changes to files (`keepForUndo`): a group of its own when no event has one open.
        let opens = manager.groupingLevel == 0
        if opens { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { workspace in
            workspace.setFolderIcon(old, for: url)
            workspace.keepFolderIconForUndo(from: new, to: old, for: url)
        }
        manager.setActionName("Customize Folder")
        if opens { manager.endUndoGrouping() }
    }

    /// Customize Folder… from a menu: on the Mac a popover from the folder's row, on iPhone and iPad a sheet.
    #if os(macOS)
    func customizeFolder(_ url: URL, from anchor: NSView?) {
        guard let anchor, anchor.window != nil else { return beep() }
        folderIconPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: FolderIconEditor(workspace: self, url: url) { [weak popover] in popover?.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        folderIconPopover = popover
    }
    #else
    func customizeFolder(_ url: URL) {
        folderIconRequest = FolderIconRequest(url: url)
    }
    #endif
}

extension FolderColor {
    /// The system's colour for the tag's, as the Finder tints folders with it.
    var platformColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    var color: Color { Color.theme(platformColor) }
}

extension FolderIcon {
    /// The symbol to show: the one chosen, if this system has it (one chosen on a newer system may not be), else the
    /// folder.
    var shownSymbol: String {
        guard let symbol, NSImage.hasSymbol(symbol) else { return FileKind.folder.symbol }
        return symbol
    }
}

extension NSImage {
    static func hasSymbol(_ name: String) -> Bool {
        #if os(macOS)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: name) != nil
        #endif
    }
}
