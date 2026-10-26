#if os(iOS)
import SwiftUI

/// The iPad, as the Mac: a sidebar with your favourites and a tree of every location, the open file next to it, and
/// the note's outline in an inspector on the right.
struct PadBrowser: View {
    @Bindable var workspace: Workspace
    @State private var newFolderIn: URL?
    @State private var query = ""
    @State private var showsSettings = false
    @State private var addsLocation = false
    @FocusState private var isSearchFocused: Bool
    /// Wide enough for the sidebar next to the page: an iPad in landscape, or a large window.
    @State private var isWide = true

    var body: some View {
        Group {
            // As in Notes and Mail: in a narrower window the sidebar lies over the page rather than squeezing it,
            // and gets out of the way once you have picked something.
            if isWide {
                splitView.navigationSplitViewStyle(.balanced)
            } else {
                splitView.navigationSplitViewStyle(.prominentDetail)
            }
        }
        // Room for the sidebar, a column of text and the outline: an iPad in landscape. In portrait, even the 13-inch
        // one's, the text would get too narrow with all three.
        .onGeometryChange(for: Bool.self) { $0.size.width >= 1100 } action: { isWide = $0 }
        .overlay {
            PaletteHost(workspace: workspace, actions: PaletteActions(
                openSettings: { _ in showsSettings = true },
                newFolder: { newFolderIn = workspace.selectedFolder ?? workspace.folderForNewNote ?? workspace.locations.first?.url },
                addLocation: { addsLocation = true }
            ), top: 80)
        }
        .modifier(FileAlerts(workspace: workspace, newFolderIn: $newFolderIn))
        .modifier(AppleNotesImporter(workspace: workspace))
        .sheet(isPresented: $showsSettings) { TouchSettings(workspace: workspace) }
        .folderImporter(isPresented: $addsLocation, workspace: workspace)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            let argument = notification.userInfo?["argument"] as? String ?? ""
            switch notification.userInfo?["command"] as? String {
            case "search":
                isSearchFocused = true
                query = argument
            case "endsearch":
                query = ""
                isSearchFocused = false
            case "settings": showsSettings = argument != "hide"
            case "newfolder": newFolderIn = workspace.locations.first?.url
            default: break
            }
        }
        #endif
        .onChange(of: workspace.searchRequest) { _, _ in
            if workspace.columnVisibility == .detailOnly { workspace.columnVisibility = .all }
            isSearchFocused = true
        }
        .onChange(of: workspace.currentURL) { _, url in
            if url != nil, !isWide, workspace.columnVisibility != .detailOnly {
                withAnimation { workspace.columnVisibility = .detailOnly }
            }
        }
        .onChange(of: workspace.showsTodos) { _, shows in
            if shows, !isWide, workspace.columnVisibility != .detailOnly {
                withAnimation { workspace.columnVisibility = .detailOnly }
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            PadSidebar(workspace: workspace, query: query, newFolderIn: $newFolderIn)
                .navigationTitle("Notebook")
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .onChange(of: query, initial: true) { _, query in workspace.searchSession.update(query) }
                .searchFocused($isSearchFocused)
                .onSubmit(of: .search) {
                    if let first = workspace.searchSession.sections.first?.items.first { workspace.open(first.result) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { newFolderIn = workspace.selectedFolder ?? workspace.folderForNewNote ?? workspace.locations.first?.url } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                            Button { addsLocation = true } label: { Label("Add Location", systemImage: "plus.rectangle.on.folder") }
                            if let folder = workspace.selectedFolder ?? workspace.folderForNewNote {
                                Button { workspace.appleNotesImportFolder = folder } label: {
                                    Label("Import from Apple Notes", systemImage: "square.and.arrow.down.on.square")
                                }
                            }
                            Divider()
                            ShowHiddenFoldersMenu(workspace: workspace)
                            Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NewNoteButton { workspace.newNote() }
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NavigationStack {
                Group {
                    if workspace.showsTodos {
                        TodosView(workspace: workspace, isInSplitView: true)
                    } else if let url = workspace.currentURL {
                        DocumentScreen(workspace: workspace, url: url, isInSplitView: true)
                    } else {
                        EmptyState()
                            .toolbar {
                                ToolbarItem(placement: .primaryAction) {
                                    NewNoteButton { workspace.newNote() }
                                }
                            }
                    }
                }
            }
            // On the stack rather than in it, which would take the page's toolbar away.
            .inspector(isPresented: Binding(get: { workspace.isOutlineVisible && workspace.currentURL != nil }, set: { workspace.isOutlineVisible = $0 })) {
                OutlinePanel(workspace: workspace)
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
            }
        }
    }

}

/// The sidebar: search results while you search; otherwise favourites and a section for every location, with its
/// folders opening in place, as in the Mac's sidebar.
struct PadSidebar: View {
    @Bindable var workspace: Workspace
    let query: String
    @Binding var newFolderIn: URL?
    @Environment(\.isSearching) private var isSearching
    @State private var expanded = Set(UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? [])
    @State private var collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                if isSearching {
                    SearchResultsList(workspace: workspace, query: query) { workspace.open($0) }
                } else {
                    if NotebookSettings.shared.showsTodos {
                        TodosRowLabel(count: workspace.dueTodoCount)
                            .tag(Workspace.todosURL)
                    }
                    let favorites = workspace.favoriteURLs
                    if !favorites.isEmpty {
                        Section("Favorites", isExpanded: sectionBinding("Favorites")) {
                            ForEach(favorites, id: \.self) { url in
                                favorite(url)
                            }
                        }
                    }
                    ForEach(workspace.locations) { location in
                        Section(isExpanded: sectionBinding(location.id.uuidString)) {
                            FolderTree(workspace: workspace, folder: location.url, expanded: $expanded, newFolderIn: $newFolderIn)
                        } header: {
                            LocationHeader(workspace: workspace, location: location) { newFolderIn = $0 }
                                .fileDragAndDrop(location.url, isFolder: true, workspace: workspace, canDrag: false)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                // The note open at launch, in its folder.
                if let url = workspace.currentURL {
                    reveal(url)
                    DispatchQueue.main.async { proxy.scrollTo(url) }
                }
            }
            .onChange(of: expanded) { _, expanded in UserDefaults.standard.set(Array(expanded), forKey: "expandedFolders") }
            .onChange(of: workspace.revealRequest?.id) { _, _ in
                guard let request = workspace.revealRequest else { return }
                reveal(request.url)
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(request.url) } }
            }
        }
    }

    private var selection: Binding<URL?> {
        Binding(get: { workspace.showsTodos ? Workspace.todosURL : workspace.currentURL }, set: { url in
            if url == Workspace.todosURL {
                workspace.showTodos()
            } else if let url, url != workspace.currentURL {
                workspace.open(url)
            }
        })
    }

    private func favorite(_ url: URL) -> some View {
        let row = workspace.row(for: url, favorite: true)
        return Group {
            if row.kind == .folder {
                Button { workspace.open(url) } label: { row }
                    .buttonStyle(.plain)
            } else {
                row.tag(url)
            }
        }
        .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
    }

    private func sectionBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsedSections.contains(key) }, set: { open in
            if open { collapsedSections.remove(key) } else { collapsedSections.insert(key) }
            UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
        })
    }

    /// Opens the folders down to a file, and its location's section.
    private func reveal(_ url: URL) {
        guard let found = workspace.folders(to: url) else { return }
        collapsedSections.remove(found.location.id.uuidString)
        for folder in found.folders.dropFirst() { expanded.insert(folder.path) }
        // A folder opened from a link or a favourite opens too.
        let target = url.standardizedFileURL
        if target != found.location.url, workspace.node(for: target, reading: false)?.isFolder ?? false { expanded.insert(target.path) }
    }
}

/// A folder's files and folders, the folders opening in place.
struct FolderTree: View {
    let workspace: Workspace
    let folder: URL
    @Binding var expanded: Set<String>
    @Binding var newFolderIn: URL?

    var body: some View {
        ForEach(workspace.visibleChildren(of: folder), id: \.url) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: binding(node.url.path)) {
                    FolderTree(workspace: workspace, folder: node.url, expanded: $expanded, newFolderIn: $newFolderIn)
                } label: {
                    node.row(in: workspace)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { toggle(node.url.path) } }
                        .fileDragAndDrop(node.url, isFolder: true, workspace: workspace)
                        .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
                }
                .id(node.url)
            } else {
                node.row(in: workspace)
                    .tag(node.url)
                    .id(node.url)
                    .fileDragAndDrop(node.url, isFolder: false, workspace: workspace)
                    .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
            }
        }
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(path) }, set: { open in
            if open { expanded.insert(path) } else { expanded.remove(path) }
        })
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}
#endif
