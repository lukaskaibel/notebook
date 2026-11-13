#if os(iOS)
import SwiftUI

/// Hide Folder and Unhide Folder, for a folder's menu; Hide and Unhide for its swipe actions.
struct HideFolderButton: View {
    let workspace: Workspace
    let url: URL
    var isShort = false

    var body: some View {
        let isHidden = workspace.isHidden(url)
        let title = isHidden ? "Unhide" : "Hide"
        Button { withAnimation { workspace.setHidden(url, !isHidden) } } label: {
            Label(isShort ? title : title + " Folder", systemImage: isHidden ? "eye" : "eye.slash")
        }
    }
}

/// Shows a location's hidden folders, dimmed, until you turn it off: for its menus.
@MainActor
enum ShowHiddenFolders {
    /// Ticked while they show; in a menu of locations, the location's name and symbol instead.
    static func entry(_ workspace: Workspace, _ location: Location, title: String = "Show Hidden Folders", symbol: String = "eye") -> MenuEntry {
        let shows = workspace.showsHiddenFolders(in: location)
        return MenuEntry(title, symbol, checked: shows) { withAnimation { workspace.showHiddenFolders(!shows, in: location) } }
    }

    /// Show Hidden Folders in the ⋯ menu of the sidebar and the first screen, when there are any: for the one location
    /// that has them, or a submenu of the locations that do.
    @MenuContent
    static func entries(_ workspace: Workspace) -> [MenuEntry] {
        let locations = workspace.locations.filter(workspace.hasHiddenFolders(in:))
        if locations.count == 1, let location = locations.first {
            entry(workspace, location)
        } else if !locations.isEmpty {
            MenuEntry.submenu("Show Hidden Folders", "eye") {
                for location in locations {
                    entry(workspace, location, title: location.name, symbol: location.isICloudDrive ? "icloud" : "externaldrive")
                }
            }
        }
    }
}

/// A location's name over its files and folders, and, as on the Mac, an eye to show its hidden folders, in the accent
/// colour while they show, and a folder with a plus for a new folder at its top: both under the pointer. A tap on the
/// name, or touching and holding it as a row, brings up what can be done with the location.
struct LocationHeader: View {
    let workspace: Workspace
    let location: Location
    /// Asks for the name of a new folder in the location.
    var newFolder: ((URL) -> Void)?
    @State private var isHovered = false

    var body: some View {
        let shows = workspace.showsHiddenFolders(in: location)
        HStack {
            // A list's context menus come only from its rows, and a section's header takes a touch and hold before
            // SwiftUI's menus in it see it: the menu is a UIKit button's, over the name and up to the buttons after it.
            Text(location.name)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    HeaderMenuButton(label: location.name) {
                        FileActions.entries(workspace, location.url, newFolder: newFolder)
                    }
                }
            if shows || isHovered, workspace.hasHiddenFolders(in: location) {
                let title = shows ? "Hide Hidden Folders" : "Show Hidden Folders"
                Button { withAnimation { workspace.showHiddenFolders(!shows, in: location) } } label: {
                    Label(title, systemImage: "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(shows ? Color.accentColor : Color.secondary)
                .help(title)
            }
            if isHovered, let newFolder {
                Button { newFolder(location.url) } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("New Folder")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
#endif
