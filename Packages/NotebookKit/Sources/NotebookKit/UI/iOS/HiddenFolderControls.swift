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
struct ShowHiddenFoldersToggle: View {
    let workspace: Workspace
    let location: Location
    /// In a menu of locations, the location's name and symbol instead.
    var title = "Show Hidden Folders"
    var symbol = "eye"

    var body: some View {
        Toggle(isOn: Binding(get: { workspace.showsHiddenFolders(in: location) }, set: { shows in
            withAnimation { workspace.showHiddenFolders(shows, in: location) }
        })) {
            Label(title, systemImage: symbol)
        }
    }
}

/// Show Hidden Folders in the ⋯ menu of the sidebar and the first screen, when there are any: for the one location
/// that has them, or a menu of the locations that do.
struct ShowHiddenFoldersMenu: View {
    let workspace: Workspace

    var body: some View {
        let locations = workspace.locations.filter(workspace.hasHiddenFolders(in:))
        if locations.count == 1, let location = locations.first {
            ShowHiddenFoldersToggle(workspace: workspace, location: location)
        } else if !locations.isEmpty {
            Menu {
                ForEach(locations) { location in
                    ShowHiddenFoldersToggle(workspace: workspace, location: location, title: location.name,
                                            symbol: location.isICloudDrive ? "icloud" : "externaldrive")
                }
            } label: {
                Label("Show Hidden Folders", systemImage: "eye")
            }
        }
    }
}

/// A location's name over its files and folders, and, as on the Mac, an eye to show its hidden folders, in the accent
/// colour while they show, and a folder with a plus for a new folder at its top: both under the pointer. A tap on the
/// name brings up what can be done with the location.
struct LocationHeader: View {
    let workspace: Workspace
    let location: Location
    /// Asks for the name of a new folder in the location.
    var newFolder: ((URL) -> Void)?
    @State private var isHovered = false

    var body: some View {
        let shows = workspace.showsHiddenFolders(in: location)
        HStack {
            // A menu of its own, opened with a tap: a list's context menus come only from its rows, and its long press
            // never reaches a section's header, not even a menu's.
            Menu {
                FileActions(workspace: workspace, url: location.url, newFolder: newFolder)
            } label: {
                Text(location.name)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
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
