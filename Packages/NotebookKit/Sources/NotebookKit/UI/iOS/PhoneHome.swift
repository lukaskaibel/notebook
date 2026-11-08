#if os(iOS)
import SwiftUI

/// To-dos and Favorites at the top of the iPhone's first screen, as Reminders shows its lists that gather things from
/// all the others: side by side, each with its count, each opening its own screen. Favorites only once something is
/// starred.
struct HomeTiles: View {
    let workspace: Workspace

    var body: some View {
        let showsTodos = NotebookSettings.shared.showsTodos
        let favorites = workspace.favoriteURLs.count
        if showsTodos || favorites > 0 {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    if showsTodos {
                        tile(.todos()) { HomeTileLabel(title: "To-dos", symbol: "checklist", color: .accentColor, count: workspace.dueTodoCount) }
                    }
                    if favorites > 0 {
                        tile(.favorites()) { HomeTileLabel(title: "Favorites", symbol: "star.fill", color: .orange, count: favorites) }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private func tile(_ page: Page, label: () -> HomeTileLabel) -> some View {
        NavigationLink(value: page, label: label)
            .buttonStyle(.plain)
            // Two links share the row: the list would give each the row's chevron, after the tile.
            .navigationLinkIndicatorVisibility(.hidden)
    }
}

/// What you opened last, as cards in a row that scrolls sideways (`RecentCardLabel`), each opening its file's screen.
struct RecentCards: View {
    let workspace: Workspace
    @Binding var newFolderIn: URL?

    var body: some View {
        // With the note you are in: going back to this screen doesn't put its card in at the start and push the others
        // along.
        let recents = Array(workspace.recentURLs(includingOpen: true).prefix(RecentCardRow.limit))
        if !recents.isEmpty {
            Section("Recent") {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HomeStyle.spacing) {
                        ForEach(recents, id: \.self) { url in
                            NavigationLink(value: Page(url: url, isFolder: false)) {
                                RecentCardLabel(workspace: workspace, url: url)
                            }
                            .buttonStyle(.plain)
                            .navigationLinkIndicatorVisibility(.hidden)
                            .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }
}

/// A location's top level on the first screen: its folders, each with how much is in it, and its notes. A folder with
/// folders in it has an arrow that unfolds them below it, indented and quieter, as Notes shows folders in folders; a
/// tap anywhere else on the row opens it.
struct HomeFileRows: View {
    let workspace: Workspace
    let nodes: [FileNode]
    @Binding var newFolderIn: URL?
    /// The folders unfolded, by path, one to a line: kept between launches.
    @AppStorage(HomeFileRows.unfoldedKey) private var unfoldedList = ""

    static let unfoldedKey = "unfoldedFolders"

    struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: URL { node.url }
    }

    var body: some View {
        let unfolded = Set(unfoldedList.split(separator: "\n").map(String.init))
        ForEach(rows(unfolded: unfolded)) { row in
            if row.node.isFolder {
                folderRow(row, unfolded: unfolded)
            } else {
                NavigationLink(value: Page(url: row.node.url, isFolder: false)) { row.node.row(in: workspace) }
                    .fileDragAndDrop(row.node.url, isFolder: false, workspace: workspace)
                    .contextMenu { FileActions(workspace: workspace, url: row.node.url) { newFolderIn = $0 } }
            }
        }
    }

    private func folderRow(_ row: Row, unfolded: Set<String>) -> some View {
        let url = row.node.url
        let canFold = !(workspace.shownSubfolders(of: url) ?? []).isEmpty
        let isUnfolded = canFold && unfolded.contains(url.path)
        let count = workspace.shownCount(of: url)
        return NavigationLink(value: Page(url: url, isFolder: true)) {
            HStack(spacing: 6) {
                row.node.row(in: workspace, isQuiet: row.depth > 0)
                    .padding(.leading, CGFloat(row.depth) * 28)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if canFold {
                    Button { fold(url, unfolded: unfolded) } label: {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(isUnfolded ? 90 : 0))
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                }
            }
        }
        // The arrow says it folds; the row's own chevron would say it opens, twice.
        .navigationLinkIndicatorVisibility(canFold ? .hidden : .automatic)
        .fileDragAndDrop(url, isFolder: true, workspace: workspace)
        .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
        .accessibilityValue(count.map { "\($0) items" } ?? "")
        .accessibilityActions {
            if canFold {
                Button(isUnfolded ? "Hide Folders Inside" : "Show Folders Inside") { fold(url, unfolded: unfolded) }
            }
        }
    }

    private func fold(_ url: URL, unfolded: Set<String>) {
        var unfolded = unfolded
        if unfolded.contains(url.path) { unfolded.remove(url.path) } else { unfolded.insert(url.path) }
        withAnimation { unfoldedList = unfolded.sorted().joined(separator: "\n") }
    }

    /// The nodes, each followed by the folders in it when it is unfolded, and so on down.
    private func rows(unfolded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func add(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isFolder, depth < 8, unfolded.contains(node.url.path), let subfolders = workspace.shownSubfolders(of: node.url) {
                    add(subfolders, depth: depth + 1)
                }
            }
        }
        add(nodes, depth: 0)
        return rows
    }
}

/// Your favourites: on the iPhone a screen of their own, from their tile on the first screen; on the iPad next to the
/// sidebar, in place of a note. Notes and folders you starred, in the order you starred them.
struct FavoritesScreen: View {
    @Bindable var workspace: Workspace
    @Binding var newFolderIn: URL?
    /// On the iPad, next to the sidebar: a tap opens a note in place of the list, and a folder in the sidebar.
    var isInSplitView = false

    var body: some View {
        let favorites = workspace.favoriteURLs
        List {
            ForEach(favorites, id: \.self) { url in
                let row = workspace.row(for: url, showsDetail: true, favorite: true)
                Group {
                    if isInSplitView {
                        Button { workspace.open(url) } label: { row }
                            .tint(.primary)
                    } else {
                        NavigationLink(value: Page(url: url, isFolder: row.kind == .folder)) { row }
                    }
                }
                .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
                .swipeActions(edge: .trailing) {
                    Button { withAnimation { workspace.toggleFavorite(url) } } label: {
                        Label("Unfavorite", systemImage: "star.slash")
                    }
                    .tint(.orange)
                }
            }
        }
        .overlay {
            if favorites.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Swipe right on a note or folder to add it to your favorites.")
                }
            }
        }
        .animation(.default, value: favorites)
        .navigationTitle("Favorites")
        .toolbar {
            if isInSplitView {
                ToolbarItem(placement: .primaryAction) { NewNoteButton(workspace: workspace) }
            } else {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NewNoteButton(workspace: workspace, folder: workspace.defaultFolder)
                }
            }
        }
    }
}
#endif
