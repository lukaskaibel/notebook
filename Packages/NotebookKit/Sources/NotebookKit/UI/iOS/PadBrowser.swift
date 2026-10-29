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
    @State private var isWide: Bool
    /// The width is known, and the split view made for it: a split view changes what it shows as it first appears
    /// back to what it was made with, so the sidebar has to be away from the start where it makes way.
    @State private var hasMeasured: Bool
    /// The split view is made without the sidebar, which the workspace hears of once the width is measured.
    @State private var startsWithoutSidebar: Bool
    @Bindable private var settings = NotebookSettings.shared

    init(workspace: Workspace) {
        _workspace = Bindable(workspace)
        // The window's own width is known before anything in it is laid out, so the split view is made at once, for
        // it: no empty frame as the iPad's layout takes over from the iPhone's screens or the welcome screen.
        let width = Self.windowWidth
        let wide = width.map { $0 >= Self.wide } ?? true
        _isWide = State(initialValue: wide)
        _hasMeasured = State(initialValue: width != nil)
        _startsWithoutSidebar = State(initialValue: !wide && (workspace.currentURL != nil || workspace.showsTodos))
    }

    /// From this wide on there is room for the sidebar, a column of text and the outline: an iPad in landscape. In
    /// portrait, even the 13-inch one's, the text would get too narrow with all three. Narrowing, the sidebar goes a
    /// little below it, so a Stage Manager window dragged about the edge doesn't take it away and back each time.
    private static let wide: CGFloat = 1100
    private static let narrow: CGFloat = 1060

    /// The width of the window Notebook is in, when that is sure: there is one window, or all are as wide. A view
    /// can't tell which window it is in before it is laid out, and a new one next to another, active one could be
    /// made for the other's width; it then waits for its first measure.
    private static var windowWidth: CGFloat? {
        let widths = Set(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.effectiveGeometry.coordinateSpace.bounds.width })
        return widths.count == 1 ? widths.first : nil
    }

    var body: some View {
        // One split view, whatever the width: choosing between two styles as the iPad turned or a window was resized
        // made a new one after each turn, with the page jumping and the sidebar left lying over it. Where there isn't
        // room for both, the sidebar makes way for the page instead, as Files' does.
        ZStack {
            // Made once the width is known, already without the sidebar where it has to make way: the note open at
            // launch in portrait, or a window coming back from phone width, has none next to it or sliding off.
            if hasMeasured { splitView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let wide = width >= (hasMeasured && isWide ? Self.narrow : Self.wide)
            if startsWithoutSidebar {
                // Made without it: now the workspace's too, and it comes back as the window widens.
                startsWithoutSidebar = false
                workspace.columnVisibility = .detailOnly
                workspace.sidebarHiddenForWidth = true
            }
            guard !hasMeasured || wide != isWide else { return }
            isWide = wide
            if hasMeasured {
                withAnimation { fitSidebar() }
            } else {
                fitSidebar()
                hasMeasured = true
            }
        }
        .overlay {
            PaletteHost(workspace: workspace, actions: PaletteActions(
                openSettings: { _ in showsSettings = true },
                newFolder: { newFolderIn = newFolderParent },
                addLocation: { addsLocation = true }
            ), top: 80)
        }
        .onChange(of: workspace.newFolderRequest) { _, _ in newFolderIn = newFolderParent }
        .modifier(FileAlerts(workspace: workspace, newFolderIn: $newFolderIn))
        .modifier(AppleNotesImporter(workspace: workspace))
        .background(alignment: .topLeading) { FileUndoFocus(workspace: workspace).frame(width: 0, height: 0) }
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
            if url != nil { withAnimation { makeWayForPage() } }
        }
        .onChange(of: workspace.showsTodos) { _, shows in
            if shows { withAnimation { makeWayForPage() } }
        }
        .onChange(of: workspace.columnVisibility) { _, visibility in
            // Shown by hand: it stays, whatever the width does next.
            if visibility != .detailOnly { workspace.sidebarHiddenForWidth = false }
        }
    }

    /// Where there isn't room for both, the sidebar goes once something is open: you have picked what you wanted.
    private func makeWayForPage() {
        guard !isWide, workspace.columnVisibility != .detailOnly else { return }
        workspace.columnVisibility = .detailOnly
        workspace.sidebarHiddenForWidth = true
    }

    /// Narrower, the sidebar makes way for what is open, as Files' does when the iPad turns to portrait; wider again,
    /// it comes back if it went for want of room.
    private func fitSidebar() {
        if !isWide {
            if workspace.currentURL != nil || workspace.showsTodos { makeWayForPage() }
        } else if workspace.sidebarHiddenForWidth {
            workspace.columnVisibility = .all
            workspace.sidebarHiddenForWidth = false
        }
    }

    /// Where New Folder makes one: in the folder you are in.
    private var newFolderParent: URL? {
        workspace.selectedFolder ?? workspace.folderForNewNote ?? workspace.locations.first?.url
    }

    /// The sidebar's place: away from the start where it makes way as the window first appears.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { startsWithoutSidebar ? .detailOnly : workspace.columnVisibility }, set: { workspace.columnVisibility = $0 })
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            PadSidebar(workspace: workspace, query: query, newFolderIn: $newFolderIn)
                .navigationTitle("Notebook")
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .onChange(of: query, initial: true) { _, query in workspace.searchSession.update(query) }
                .searchFocused($isSearchFocused)
                .onSubmit(of: .search) {
                    if let first = SearchSection.firstToOpen(in: workspace.searchSession.sections) { workspace.open(first.result) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { newFolderIn = newFolderParent } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                            Button { addsLocation = true } label: { Label("Add Location", systemImage: "plus.rectangle.on.folder") }
                            if let folder = workspace.selectedFolder ?? workspace.folderForNewNote {
                                Button { workspace.appleNotesImportFolder = folder } label: {
                                    Label("Import from Apple Notes", systemImage: "square.and.arrow.down.on.square")
                                }
                            }
                            Section {
                                SortByPicker(folder: workspace.folderInView)
                                Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                            }
                            ShowHiddenFoldersMenu(workspace: workspace)
                            Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        } label: {
                            // Not More, which the note's ⋯ next to it is.
                            Label("More for Notebook", systemImage: "ellipsis")
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        NewNoteButton(workspace: workspace)
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
                                    NewNoteButton(workspace: workspace)
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
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var expanded = Set((UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? []).map(Workspace.rerooted))
    @State private var collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])
    /// A folder opened from search, to show in the tree when search has ended.
    @State private var revealsAfterSearch: URL?

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
            // Read before an update's move was known: the folders open follow it.
            .onReceive(NotificationCenter.default.publisher(for: Workspace.documentsMoved)) { _ in expanded = Set(expanded.map(Workspace.rerooted)) }
            .onChange(of: workspace.revealRequest?.id) { _, _ in
                guard let request = workspace.revealRequest else { return }
                // What was opened from search shows in the tree once the tree is back.
                if isSearching {
                    revealsAfterSearch = request.url
                    return
                }
                reveal(request.url)
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(request.url) } }
            }
            // A folder opens in the tree, which search covers: search ends, as Cancel ends it.
            .onChange(of: workspace.folderRequest?.id) { _, _ in
                if isSearching { dismissSearch() }
            }
            .onChange(of: isSearching) { _, searching in
                guard !searching, let url = revealsAfterSearch else { return }
                revealsAfterSearch = nil
                reveal(url)
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(url) } }
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
                        // VoiceOver reads the row, arrow and all, as one: "Personal, collapsed", as Files does.
                        .accessibilityValue(expanded.contains(node.url.path) ? "expanded" : "collapsed")
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
