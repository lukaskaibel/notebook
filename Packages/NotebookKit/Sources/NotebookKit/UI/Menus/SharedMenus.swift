#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

extension FormatCommand {
    /// The keys the Format menu has for it, on the Mac and on an iPad with a keyboard.
    var keys: String? {
        switch self {
        case .title: MenuKeys.text("T", shift: true)
        case .heading: MenuKeys.text("H", shift: true)
        case .subheading: MenuKeys.text("J", shift: true)
        case .body: MenuKeys.text("B", shift: true)
        case .bold: MenuKeys.text("B")
        case .italic: MenuKeys.text("I")
        case .strikethrough: MenuKeys.text("X", shift: true)
        case .highlight: MenuKeys.text("H", control: true)
        case .code: MenuKeys.text("E")
        case .link: MenuKeys.text("L")
        case .checklist: MenuKeys.text("L", shift: true)
        case .bulletedList: MenuKeys.text("7", shift: true)
        case .numberedList: MenuKeys.text("9", shift: true)
        case .quote: MenuKeys.text("'")
        case .table: MenuKeys.text("T", option: true)
        case .indent: MenuKeys.text("]", option: true)
        case .outdent: MenuKeys.text("[", option: true)
        }
    }
}

/// Menus the Mac, the iPad and the iPhone have alike.
@MainActor
enum SharedMenus {
    /// The formatting commands, as in Notes' Aa button: the text styles each set as it is in the note, the one the
    /// caret's line has ticked, the rest with their symbols and keys. They go to `editor`, which keeps the caret.
    static func format(_ editor: EditorController, styleSize: CGFloat, lists: Bool = true) -> [MenuEntry] {
        let current = editor.currentLineFormat
        let face = NotebookSettings.shared.typography.face
        var entries: [MenuEntry] = FormatCommand.styles.map { style in
            MenuEntry(style.name, style.symbol, keys: style.keys, checked: current == style) { [weak editor] in editor?.perform(style) }
                .with { $0.font = Font(EditorStyle.styleSample(style, size: styleSize, face: face)) }
        }
        entries.append(.divider)
        for command in FormatCommand.inline + [.link] {
            entries.append(MenuEntry(command.name, command.symbol, keys: command.keys, checked: command != .link && editor.isActive(command)) { [weak editor] in
                editor?.perform(command)
            })
        }
        if lists {
            entries.append(.divider)
            for command in FormatCommand.lists {
                entries.append(MenuEntry(command.name, command.symbol, keys: command.keys, checked: current == command) { [weak editor] in
                    editor?.perform(command)
                })
            }
        }
        return entries
    }

    /// Move To, as a folder picker: every folder of every location, indented under its location, the one the file is
    /// in ticked; typing a folder's name finds it, with the folders it is in beside it.
    static func moveTo(_ url: URL, workspace: Workspace) -> MenuEntry {
        var entry = MenuEntry.submenu("Move To", "folder", placeholder: "Move to…") { [weak workspace] in
            guard let workspace else { return [] }
            return folders(for: url, workspace: workspace)
        }
        #if os(iOS)
        // A whole iCloud Drive has thousands of folders, too many for the system's menu to list.
        entry.insteadOfSubmenu = { [weak workspace] in workspace?.moving = MovingFile(url: url) }
        #endif
        return entry
    }

    static func folders(for url: URL, workspace: Workspace) -> [MenuEntry] {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var entries: [MenuEntry] = []
        for target in workspace.moveTargets(for: url) {
            // Each location's top first, as Notes has its accounts, with its folders indented under it.
            entries.append(.divider)
            // The names of the folders above the one at hand, by depth.
            var above: [String] = []
            for folder in target.folders {
                let depth = max(0, folder.depth)
                if folder.depth >= 0 { above = Array(above.prefix(depth)) }
                let isHere = folder.url.standardizedFileURL == parent
                let title = folder.depth < 0 ? target.location.name : folder.name
                var entry = MenuEntry(title, checked: isHere, enabled: !isHere) { [weak workspace] in
                    _ = workspace?.move(url, into: folder.url)
                }
                entry.icon = icon(of: folder.url, isTop: folder.depth < 0, location: target.location, workspace: workspace)
                entry.indent = folder.depth < 0 ? 0 : min(depth + 1, 8)
                // Where it is, for when typing finds it and the indentation no longer says.
                entry.detail = folder.depth < 0 ? nil : above.last ?? target.location.name
                entries.append(entry)
                if folder.depth >= 0 { above.append(folder.name) }
            }
        }
        return entries
    }

    /// A folder as the sidebar draws it: its emoji, or its symbol in its colour.
    private static func icon(of url: URL, isTop: Bool, location: Location, workspace: Workspace) -> MenuEntry.Icon {
        if isTop { return .symbol(location.isICloudDrive ? "icloud" : "externaldrive") }
        guard let look = workspace.folderIcon(for: url) else { return .symbol("folder") }
        if let emoji = look.emoji { return .emoji(emoji) }
        if let color = look.color { return .tinted(look.shownSymbol, color.color) }
        return .symbol(look.shownSymbol)
    }
}
