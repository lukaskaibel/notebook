#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// A screen of the iPhone's navigation: a folder or a file. It is an object rather than an address, so that a note
/// renamed or moved while it is open keeps its screen, which follows it to its new name.
@MainActor
@Observable
final class Page: Hashable {
    var url: URL
    let isFolder: Bool

    init(url: URL, isFolder: Bool) {
        self.url = url.standardizedFileURL
        self.isFolder = isFolder
    }

    /// The To-dos list's screen.
    static func todos() -> Page { Page(url: Workspace.todosURL, isFolder: false) }
    var isTodos: Bool { url == Workspace.todosURL }

    nonisolated static func == (a: Page, b: Page) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The iPhone, and an iPad window too narrow for a sidebar: one folder per screen, as in the Files app, and a file
/// on a screen of its own. Search and a new note are at the bottom, as in Notes.
struct PhoneBrowser: View {
    @Bindable var workspace: Workspace
    @State private var path: [Page] = []
    @State private var newFolderIn: URL?

    var body: some View {
        NavigationStack(path: $path) {
            HomeScreen(workspace: workspace, newFolderIn: $newFolderIn)
                .navigationDestination(for: Page.self) { page in
                    if page.isTodos {
                        TodosView(workspace: workspace)
                    } else if page.isFolder {
                        FolderScreen(workspace: workspace, page: page, newFolderIn: $newFolderIn)
                    } else {
                        DocumentScreen(workspace: workspace, url: page.url)
                    }
                }
        }
        .overlay {
            // ⌘K, from a keyboard: an iPad window as narrow as a phone shows these screens too.
            PaletteHost(workspace: workspace, actions: PaletteActions(
                openSettings: { _ in workspace.settingsRequest += 1 },
                newFolder: { newFolderIn = workspace.folderForNewNote ?? workspace.locations.first?.url },
                addLocation: { workspace.locationRequest += 1 }
            ), top: 60)
        }
        .modifier(FileAlerts(workspace: workspace, newFolderIn: $newFolderIn))
        .modifier(AppleNotesImporter(workspace: workspace))
        .onChange(of: workspace.newFolderRequest) { _, _ in newFolderIn = workspace.folderForNewNote ?? workspace.locations.first?.url }
        .onAppear {
            // Back where you were: in the note you had open, with its folders behind it.
            if let url = workspace.currentURL, path.isEmpty { path = folders(to: url) + [Page(url: url, isFolder: false)] }
        }
        .onChange(of: path) { _, path in pathChanged(path) }
        .onChange(of: workspace.currentURL) { _, url in fileChanged(url) }
        .onChange(of: workspace.showsTodos) { _, shows in
            if shows, path.last?.isTodos != true { path.append(.todos()) }
        }
        .onChange(of: workspace.folderRequest?.id) { _, _ in
            guard let folder = workspace.folderRequest?.url, path.last?.url != folder else { return }
            path.append(Page(url: folder, isFolder: true))
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            switch notification.userInfo?["command"] as? String {
            case "back": if !path.isEmpty { path.removeLast() }
            case "home": path = []
            case "push": if let argument = notification.userInfo?["argument"] as? String, let root = workspace.locations.first?.url {
                path.append(Page(url: root.appendingPathComponent(argument), isFolder: true))
            }
            default: break
            }
        }
        #endif
        .onChange(of: workspace.relocation?.id) { _, _ in
            guard let relocation = workspace.relocation else { return }
            for page in path { page.url = Self.relocated(page.url, relocation.from, relocation.to) }
        }
    }

    /// Back to a folder leaves the note (it is saved); back to a note opens it again where you were.
    private func pathChanged(_ path: [Page]) {
        if let top = path.last, top.isTodos {
            if !workspace.showsTodos { workspace.showTodos(recordHistory: false) }
            return
        }
        if workspace.showsTodos { workspace.closeTodos() }
        if let top = path.last, !top.isFolder {
            if workspace.currentURL != top.url {
                workspace.reopen(top.url)
                // Gone in the meantime (deleted or renamed on another device): its screen goes too.
                if workspace.currentURL != top.url {
                    if workspace.currentURL != nil { workspace.closeFile() }
                    self.path.removeLast()
                }
            }
        } else if workspace.currentURL != nil {
            workspace.closeFile()
        }
    }

    /// A file opened from a link, from search or as a new note gets a screen of its own; one deleted goes away.
    private func fileChanged(_ url: URL?) {
        guard let url else {
            if let top = path.last, !top.isFolder, !top.isTodos { path.removeLast() }
            return
        }
        if let top = path.last, !top.isFolder, !top.isTodos {
            if top.url == url { return }
            // Renamed or moved (itself or a folder it is in): the same screen, under the new name.
            if let relocation = workspace.relocation, Self.relocated(top.url, relocation.from, relocation.to) == url {
                top.url = url
                return
            }
        }
        path.append(Page(url: url, isFolder: false))
    }

    /// Where a file is after `from` became `to`: itself, or a folder it is in.
    static func relocated(_ url: URL, _ from: URL, _ to: URL) -> URL {
        let old = from.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == old { return to.standardizedFileURL }
        if path.hasPrefix(old + "/") { return URL(fileURLWithPath: to.standardizedFileURL.path + path.dropFirst(old.count)) }
        return url
    }

    /// The folders from the top of a location down to the one a file is in, below the location itself, whose
    /// folders the first screen shows.
    private func folders(to url: URL) -> [Page] {
        guard let found = workspace.folders(to: url) else { return [] }
        return found.folders.dropFirst().map { Page(url: $0, isFolder: true) }
    }
}

/// The first screen: favourites, what you opened last, and what is in each location, as Notes lists its folders.
struct HomeScreen: View {
    @Bindable var workspace: Workspace
    @Binding var newFolderIn: URL?
    @State private var query = ""
    @State private var isSearching = false
    @State private var showsSettings = false
    @State private var addsLocation = false
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        List {
            if isSearching {
                SearchResultsList(workspace: workspace, query: query) { open($0) }
            } else {
                if NotebookSettings.shared.showsTodos {
                    Section {
                        NavigationLink(value: Page.todos()) { TodosRowLabel(count: workspace.dueTodoCount) }
                    }
                }
                let favorites = workspace.favoriteURLs
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites, id: \.self) { url in
                            link(url, row: workspace.row(for: url, favorite: true))
                        }
                    }
                }
                // With the note you are in: going back to this screen doesn't put its row in at the end and push the
                // list down.
                let recents = Array(workspace.recentURLs(includingOpen: true).prefix(3))
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { url in
                            link(url, row: workspace.row(for: url, showsDetail: true))
                        }
                    }
                }
                ForEach(workspace.locations) { location in
                    Section {
                        let children = workspace.visibleChildren(of: location.url)
                        ForEach(children, id: \.url) { node in
                            NavigationLink(value: Page(url: node.url, isFolder: node.isFolder)) { node.row(in: workspace) }
                                .fileDragAndDrop(node.url, isFolder: node.isFolder, workspace: workspace)
                                .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
                        }
                        if children.isEmpty, workspace.isRead(location.url) {
                            Text("Empty").foregroundStyle(.secondary)
                        }
                    } header: {
                        LocationHeader(workspace: workspace, location: location) { newFolderIn = $0 }
                    }
                }
                Section {
                    Button { addsLocation = true } label: {
                        Label("Add Location", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Notebook")
        .searchable(text: $query, isPresented: $isSearching, prompt: "Search")
        .onChange(of: query, initial: true) { _, query in workspace.searchSession.update(query) }
        .onSubmit(of: .search) { submitSearch() }
        .refreshable { workspace.refresh(thoroughly: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addsLocation = true } label: { Label("Add Location", systemImage: "plus.rectangle.on.folder") }
                    if let folder = workspace.defaultFolder {
                        Button { workspace.appleNotesImportFolder = folder } label: {
                            Label("Import from Apple Notes", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                    // The files at the top of each location below are sorted too.
                    Section {
                        SortByPicker(folder: nil)
                        Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                    }
                    ShowHiddenFoldersMenu(workspace: workspace)
                    Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            // As in Notes: New Folder on the left, asking which location when there are several, New Note on the right.
            if !workspace.locations.isEmpty {
                ToolbarItem(placement: .bottomBar) { newFolderButton }
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                NewNoteButton { workspace.newNote(in: workspace.defaultFolder) }
            }
        }
        .sheet(isPresented: $showsSettings) { TouchSettings(workspace: workspace) }
        .folderImporter(isPresented: $addsLocation, workspace: workspace)
        .onChange(of: workspace.settingsRequest) { _, _ in showsSettings = true }
        .onChange(of: workspace.locationRequest) { _, _ in addsLocation = true }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            let argument = notification.userInfo?["argument"] as? String ?? ""
            switch notification.userInfo?["command"] as? String {
            case "search":
                isSearching = true
                query = argument
            case "endsearch":
                query = ""
                isSearching = false
            case "settings": showsSettings = argument != "hide"
            case "newfolder": newFolderIn = workspace.locations.first?.url
            default: break
            }
        }
        #endif
    }

    @ViewBuilder private var newFolderButton: some View {
        let label = Label("New Folder", systemImage: "folder.badge.plus")
        if workspace.locations.count == 1, let location = workspace.locations.first {
            Button { newFolderIn = location.url } label: { label }
        } else {
            Menu {
                Section("New Folder In") {
                    ForEach(workspace.locations) { location in
                        Button { newFolderIn = location.url } label: {
                            Label(location.name, systemImage: location.isICloudDrive ? "icloud" : "folder")
                        }
                    }
                }
            } label: { label }
        }
    }

    private func link(_ url: URL, row: FileRow) -> some View {
        let isFolder = row.kind == .folder
        return NavigationLink(value: Page(url: url, isFolder: isFolder)) { row }
            .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
    }

    private func open(_ result: SearchResult) {
        workspace.open(result)
    }

    /// Return opens the best match, as on the Mac.
    private func submitSearch() {
        guard let first = workspace.searchSession.sections.first?.items.first else { return }
        open(first.result)
    }
}

/// A folder's files and folders, newest notes with how they start.
struct FolderScreen: View {
    @Bindable var workspace: Workspace
    let page: Page
    @Binding var newFolderIn: URL?
    @State private var query = ""
    @State private var isSearching = false
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        let children = workspace.visibleChildren(of: page.url)
        List {
            if isSearching {
                SearchResultsList(workspace: workspace, query: query) { open($0) }
            } else {
                ForEach(children, id: \.url) { node in
                    NavigationLink(value: Page(url: node.url, isFolder: node.isFolder)) {
                        node.row(in: workspace, showsDetail: true)
                    }
                    .fileDragAndDrop(node.url, isFolder: node.isFolder, workspace: workspace)
                    .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
                    .swipeActions(edge: .trailing) {
                        if !node.isLinked {
                            Button(role: .destructive) { workspace.moveToTrash(node.url) } label: { Label("Delete", systemImage: "trash") }
                            Button { workspace.moving = MovingFile(url: node.url) } label: { Label("Move", systemImage: "folder") }
                                .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        let favorite = workspace.isFavorite(node.url)
                        Button { workspace.toggleFavorite(node.url) } label: {
                            Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "star.slash" : "star")
                        }
                        .tint(.orange)
                        if node.isFolder, workspace.canHide(node.url) {
                            HideFolderButton(workspace: workspace, url: node.url, isShort: true)
                                .tint(.gray)
                        }
                    }
                }
            }
        }
        // Grey, empty or not: a folder still being read doesn't turn from white to grey when its files come in.
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .overlay {
            if children.isEmpty, !isSearching {
                if workspace.isRead(page.url) {
                    ContentUnavailableView {
                        Label("No Notes", systemImage: "doc.text")
                    } description: {
                        Text("Notes and files you put in this folder show here.")
                    } actions: {
                        Button("New Note") { workspace.newNote(in: page.url) }
                    }
                } else {
                    FolderLoadingIndicator()
                }
            }
        }
        .animation(.default, value: children.map(\.url))
        .navigationTitle(workspace.folderName(page.url))
        .searchable(text: $query, isPresented: $isSearching, prompt: "Search")
        .onChange(of: query, initial: true) { _, query in workspace.searchSession.update(query) }
        .onSubmit(of: .search) {
            if let first = workspace.searchSession.sections.first?.items.first { open(first.result) }
        }
        .refreshable { await workspace.readAgain(page.url) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            guard notification.userInfo?["command"] as? String == "movesheet", let path = notification.userInfo?["argument"] as? String,
                  let root = workspace.locations.first?.url else { return }
            workspace.moving = MovingFile(url: root.appendingPathComponent(path))
        }
        #endif
        .onAppear { workspace.selectedFolder = page.url }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { newFolderIn = page.url } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Button { workspace.appleNotesImportFolder = page.url } label: {
                            Label("Import from Apple Notes", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                    Section {
                        SortByPicker(folder: page.url)
                        Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                        Toggle(isOn: $settings.showsOnlyNotes) { Label("Show Only Notes", systemImage: "doc.text") }
                        if let location = workspace.location(containing: page.url), workspace.hasHiddenFolders(in: location) {
                            ShowHiddenFoldersToggle(workspace: workspace, location: location)
                        }
                    }
                    Section {
                        let favorite = workspace.isFavorite(page.url)
                        Button { workspace.toggleFavorite(page.url) } label: {
                            Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                NewNoteButton { workspace.newNote(in: page.url) }
            }
        }
    }

    private func open(_ result: SearchResult) {
        if case .newNote(let title) = result {
            workspace.newNote(in: page.url, title: title)
        } else {
            workspace.open(result)
        }
    }
}

extension View {
    /// The Files app's folder picker, adding the folder you choose as a location.
    func folderImporter(isPresented: Binding<Bool>, workspace: Workspace) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            workspace.addLocation(url)
        }
    }
}
#endif
