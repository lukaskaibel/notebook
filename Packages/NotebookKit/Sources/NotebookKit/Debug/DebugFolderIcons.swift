#if DEBUG
import Foundation

/// The debug remote's commands for folders' looks, the same on the Mac and on iPhone and iPad:
///
///     foldericon <folder>                        the look the sidebar shows, and what the folder has on disk
///     setfoldericon <folder> <look>              gives it a look, as Customize Folder does: "symbol=star color=red",
///                                                "emoji=🍕", "color=blue" or "plain"
///     customize <folder>                         Customize Folder… from the folder's menu: the popover or the sheet
///     customize close                            puts the popover or the sheet away
///     iconpick tab <symbols|emoji>               in Customize Folder: the Symbols or Emoji tab,
///     iconpick search <text>                     a search (empty clears it),
///     iconpick color <red|…|none>                a colour,
///     iconpick <symbol or emoji>                 a symbol or an emoji, as clicked
@MainActor
enum DebugFolderIcons {
    /// Posted for iconpick, which Customize Folder takes as clicked.
    static let pick = Notification.Name("NotebookDebugFolderIconPick")

    static func run(_ command: String, _ argument: String, workspace: Workspace, url: (String) -> URL?, log: @escaping (String) -> Void) -> Bool {
        switch command {
        case "foldericon":
            guard let folder = url(argument) else { break }
            let tags = FolderIcons.value(FolderIcons.tagsAttribute, of: folder).map(FolderIcons.tags) ?? []
            let attribute = FolderIcons.value(FolderIcons.attribute, of: folder).flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            log("foldericon \(folder.lastPathComponent): shown \(describe(workspace.folderIcon(for: folder))), on disk \(describe(FolderIcons.read(folder))), "
                + "attribute \(attribute), tags \(tags.map { $0.replacingOccurrences(of: "\n", with: "/") })")
        case "setfoldericon":
            let split = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let folder = split.first.flatMap(url) else { break }
            var icon = FolderIcon()
            for part in (split.count > 1 ? split[1] : "").split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "symbol": icon.symbol = pair[1]
                case "emoji": icon.emoji = pair[1]
                case "color": icon.color = FolderColor.allCases.first { $0.name.lowercased() == pair[1].lowercased() }
                default: break
                }
            }
            workspace.setFolderIcon(icon, for: folder)
            log("setfoldericon \(folder.lastPathComponent): \(describe(icon))")
        case "customize":
            #if os(macOS)
            if argument == "close" {
                workspace.folderIconPopover?.close()
                log("customize close")
                break
            }
            guard let folder = url(argument), let sidebar = workspace.sidebar, let node = workspace.node(for: folder, reading: false) else { break }
            let row = sidebar.outline.row(forItem: node)
            workspace.customizeFolder(folder, from: row >= 0 ? sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: false) : nil)
            log("customize \(folder.lastPathComponent): popover \(workspace.folderIconPopover?.isShown == true ? "shown" : "not shown")")
            #else
            if argument == "close" {
                workspace.folderIconRequest = nil
                log("customize close")
                break
            }
            guard let folder = url(argument) else { break }
            workspace.customizeFolder(folder)
            log("customize \(folder.lastPathComponent)")
            #endif
        case "iconpick":
            let split = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let what = ["tab", "search", "color"].contains(split[0]) ? split[0] : "item"
            let rest = what == "item" ? argument : split.count > 1 ? split[1] : ""
            NotificationCenter.default.post(name: pick, object: nil, userInfo: ["what": what, "argument": rest])
            log("iconpick \(argument)")
        default:
            return false
        }
        return true
    }

    private static func describe(_ icon: FolderIcon?) -> String {
        guard let icon else { return "plain" }
        return [icon.symbol.map { "symbol=\($0)" }, icon.emoji.map { "emoji=\($0)" }, icon.color.map { "color=\($0.name.lowercased())" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}
#endif
