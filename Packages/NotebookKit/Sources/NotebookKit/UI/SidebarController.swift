#if os(macOS)
import AppKit
import SwiftUI

/// A row in the sidebar that isn't a file in a tree: a section title, Search, and the iPhone's first screen at the top,
/// To-dos and Favorites as tiles and what you opened last as cards.
final class SidebarEntry: NSObject {
    enum Kind {
        case header(String, location: UUID?)
        /// Opens ⌘K, as Search does at the top of Notion's sidebar; never selected.
        case search
        /// To-dos and Favorites as tiles (`HomeTileGrid`), as Reminders has its lists at the top of its sidebar.
        case tiles
        /// What you opened last as cards in a row (`RecentCardRow`), under the header Recent.
        case recent
        /// Open Folder, the last row: it scrolls with the files, so it shows once you reach the end of them, as at the
        /// end of the iPhone's list, rather than staying at the bottom of the window. Never selected; a folder dropped
        /// on it is opened, as below the sections.
        case openFolder
    }

    let kind: Kind
    /// What a section shows: the cards of Recent or a location's files.
    var children: [AnyObject] = []
    init(_ kind: Kind, children: [AnyObject] = []) {
        self.kind = kind
        self.children = children
    }

    var isHeader: Bool {
        if case .header = kind { return true }
        return false
    }

    /// The tiles or the cards: SwiftUI in the row, never selected, nothing to drop on.
    var isHosted: Bool {
        switch kind {
        case .tiles, .recent: true
        case .header, .search, .openFolder: false
        }
    }

    var isSearch: Bool {
        if case .search = kind { return true }
        return false
    }

    var isOpenFolder: Bool {
        if case .openFolder = kind { return true }
        return false
    }

    /// Names a section across reloads, to remember which ones you closed.
    var sectionKey: String? {
        guard case .header(let title, let location) = kind else { return nil }
        return location?.uuidString ?? title
    }

    var url: URL? { nil }
}

/// The sidebar: Search, the tiles of To-dos and Favorites, Recent, and a tree for every location, each a section you
/// can close. A source list
/// like the Finder's, so arrow keys, type-to-select, drag and drop and renaming in place work as there.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let workspace: Workspace
    let outline = SidebarOutlineView()
    let scrollView = NSScrollView()
    private var topItems: [AnyObject] = []
    private var isSelectingProgrammatically = false
    private var renaming: URL?
    /// What changed while a name was being typed, shown once it is in: reloading its row would end the typing, and a
    /// new folder's row reloads as soon as it shows, when it has been read ahead.
    private var heldNodes: [FileNode] = []
    private var heldAll = false
    /// A folder's files as the sidebar shows them (only notes, folders first or not), worked out once per reload.
    private var visible: [ObjectIdentifier: [FileNode]] = [:]
    private var collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])
    /// The folders open last time, opened again as their rows appear: the locations are read after the window is up.
    private var wantedExpansion = Set(UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? [])
    /// Open folders renamed or moved, and the open folders in them, under their new paths (without "/private"): opened
    /// again when the sidebar shows them there, as the Finder keeps a renamed folder open.
    private var movedExpansion = Set<String>()
    private var isExpandingSections = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        // A folder's files a step further in than in Notes, so a subfolder's chevron sits under its folder's icon.
        outline.indentationPerLevel = 14
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.controller = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.setAccessibilityLabel("Files")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        // Scrolling moves other rows under the pointer.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(outline, selector: #selector(SidebarOutlineView.queueHoverUpdate),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        workspace.sidebar = self
        // Recent's cards are as wide as the tiles, which follow the sidebar's width; so does the row's height.
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarResized), name: NSView.frameDidChangeNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(optionsChanged), name: .notebookSidebarOptionsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(orderChanged), name: .notebookFileOrderChanged, object: nil)
        rebuildTop()
        outline.reloadData()
        expandSections()
        restoreExpansion([])
        revealCurrent()
    }

    /// The main window opened again (it had been closed): what is open shows selected, as when the window closed.
    private func revealCurrent() {
        if workspace.showsTodos || workspace.showsFavorites { return selectNoRow() }
        guard let url = workspace.selectedFolder ?? workspace.currentURL else { return }
        reveal(url, select: true)
        // Scrolled to once the sidebar has its size in the window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outline.selectedRow >= 0 else { return }
            self.outline.scrollRowToVisible(self.outline.selectedRow)
        }
    }

    // MARK: - Items

    func visibleChildren(of node: FileNode) -> [FileNode] {
        if let cached = visible[ObjectIdentifier(node)] { return cached }
        // Not read yet: it is read off the main thread now, and its files appear when they are there (`reload`).
        guard node.hasLoadedChildren else {
            workspace.read([node])
            return []
        }
        let children = workspace.shownChildren(of: node, in: location(of: node))
        visible[ObjectIdentifier(node)] = children
        return children
    }

    /// The location a node is in, found from its top: locations can be inside one another.
    private func location(of node: FileNode) -> Location? {
        var top = node
        while let parent = top.parent { top = parent }
        guard let id = workspace.roots.first(where: { $0.value === top })?.key else { return nil }
        return workspace.locations.first { $0.id == id }
    }

    @objc private func optionsChanged() {
        reloadAll()
    }

    /// The sidebar was made wider or narrower: Recent's row takes the height of its cards at once, unanimated.
    @objc private func sidebarResized() {
        let width = recentRowWidth
        guard width != laidOutWidth else { return }
        laidOutWidth = width
        let row = outline.row(forItem: recentEntry)
        guard row >= 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: [row])
        }
    }

    /// You chose another order: the files in open folders slide into it, as in the Finder. Closed folders are sorted
    /// when they open.
    @objc private func orderChanged() {
        guard renaming == nil else { heldAll = true; return }
        var shown = workspace.locations.compactMap { workspace.root(for: $0) }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { shown.append(node) }
        }
        let keep = Set(shown.map(ObjectIdentifier.init))
        visible = visible.filter { keep.contains($0.key) }
        reload(shown)
    }

    /// Search, first of all, then the tiles and the cards of Recent; Open Folder last of all.
    private let searchEntry = SidebarEntry(.search)
    private let tilesEntry = SidebarEntry(.tiles)
    private let recentEntry = SidebarEntry(.recent)
    private let openFolderEntry = SidebarEntry(.openFolder)

    private func rebuildTop() {
        visible = [:]
        var items: [AnyObject] = [searchEntry]
        items.append(tilesEntry)
        hasRecents = !workspace.recentCardURLs.isEmpty
        if hasRecents { items.append(SidebarEntry(.header("Recent", location: nil), children: [recentEntry])) }
        for location in workspace.locations {
            let files = workspace.root(for: location).map { visibleChildren(of: $0) } ?? []
            items.append(SidebarEntry(.header(location.name, location: location.id), children: files))
        }
        items.append(openFolderEntry)
        topItems = items
    }

    /// Opens the sections you haven't closed; they are new objects after every reload.
    private func expandSections() {
        isExpandingSections = true
        for case let entry as SidebarEntry in topItems where !collapsedSections.contains(entry.sectionKey ?? "") {
            outline.expandItem(entry)
        }
        isExpandingSections = false
    }

    private func section(for location: Location) -> SidebarEntry? {
        topItems.lazy.compactMap { $0 as? SidebarEntry }.first {
            if case .header(_, let id) = $0.kind { return id == location.id }
            return false
        }
    }

    func reloadAll() {
        guard renaming == nil else { heldAll = true; return }
        let expanded = expandedPaths()
        rebuildTop()
        outline.reloadData()
        expandSections()
        restoreExpansion(expanded)
        selectCurrent()
    }

    /// Favourites and recents changed (or a location's top level): rebuild the top without closing folders.
    /// What the rows show changed, not which rows there are: a reminder was set or done.
    func refreshRows() {
        guard renaming == nil else { heldAll = true; return }
        guard outline.numberOfRows > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: [0])
    }

    /// Whether Recent is there: it comes with the first file you open.
    private var hasRecents = false

    /// The tiles and the cards, each made once and kept: a reload of the sidebar hands the row the same view, so the
    /// cards keep their places and where they are scrolled to, and slide when what you opened last changes. Their
    /// cells are laid out by `SidebarOutlineView.frameOfCell`: the tiles' from edge to edge less `tilesFromEdge`,
    /// Recent's across the whole sidebar, with its cards in the tiles' column.
    private lazy var tilesCell = SidebarHostedCell(SidebarHostedCell.tiles, HomeTileGrid(workspace: workspace),
                                                   insets: NSEdgeInsets(top: 4, left: 0, bottom: 6, right: 0))
    private lazy var recentCell = SidebarHostedCell(SidebarHostedCell.recent,
                                                    RecentCardRow(workspace: workspace, margin: SidebarOutlineView.tilesFromEdge),
                                                    insets: NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0))
    /// The sidebar's width when Recent's row last took its height (`sidebarResized`).
    private var laidOutWidth: CGFloat = 0

    /// The width Recent's row takes its height from: the sidebar's, as if no scroll bar took room in it. A scroll bar
    /// that takes room (with a mouse attached, or set to show always) comes as the files grow past the window and goes
    /// as they fit again. Taken from the files' own width, the row was a few points shorter with the scroll bar than
    /// without, so files just past the edge made room for it, fitted, lost it, grew past the edge again, and so on
    /// without end: a new note that brought them there stopped the app. With the scroll bar there the cards are a little
    /// narrower, and the row a few points taller than they are; they sit in its middle, as they do in its slack anyway.
    var recentRowWidth: CGFloat {
        NSScrollView.contentSize(forFrameSize: scrollView.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: nil,
                                 borderType: scrollView.borderType, controlSize: .regular, scrollerStyle: scrollView.scrollerStyle).width
            - scrollView.contentInsets.left - scrollView.contentInsets.right
    }

    /// A file opened or one gone: Recent's cards follow by themselves. The section comes with the first card, and
    /// fades away with the last.
    func recentsChanged() {
        let has = !workspace.recentCardURLs.isEmpty
        guard has != hasRecents else { return }
        guard !has, renaming == nil, let index = topItems.firstIndex(where: { ($0 as? SidebarEntry)?.children.first === recentEntry }) else {
            return reloadSections()
        }
        hasRecents = false
        topItems.remove(at: index)
        outline.removeItems(at: [index], inParent: nil, withAnimation: .effectFade)
    }

    func reloadSections() {
        guard renaming == nil else { heldAll = true; return }
        let expanded = expandedPaths()
        rebuildTop()
        outline.reloadData()
        expandSections()
        restoreExpansion(expanded)
        selectCurrent()
    }

    /// A file or folder is about to show under a new address: the folders open in it stay open there.
    func follow(from old: URL, to new: URL) {
        for path in expandedPaths() {
            let moved = Workspace.relocated(path, from: old.path, to: new.path)
            if moved != path { movedExpansion.insert(HiddenFolders.withoutPrivate(moved)) }
        }
    }

    /// The rows of a file being renamed say its new name until it has it (`Workspace.newNames`), and the old one again
    /// if it couldn't be renamed.
    func showName(of url: URL) {
        guard renaming == nil else { return }
        let rows = (0..<outline.numberOfRows).filter { row in self.url(at: row).map { FileNode.samePath($0, url) } ?? false }
        if !rows.isEmpty { outline.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: [0]) }
    }

    /// Folders whose contents changed, or were read for the first time: then their files fade in below them, and
    /// nothing else in the sidebar moves. Files that came, went or took another place in the order (a note just saved,
    /// when the newest come first) fade and slide there, as in the Finder. The open note stays selected, and on screen
    /// if it was.
    func reload(_ nodes: [FileNode]) {
        guard renaming == nil else { heldNodes += nodes; return }
        // The folders open before rows are reloaded, which closes the folders in them, to open them again: gone through
        // only then, as it means every row, and a note saved in a folder of thousands only moves rows.
        var expanded: Set<String>?
        func keepExpansion() {
            if expanded == nil { expanded = expandedPaths() }
        }
        // Where the open note's row (or the folder you chose) was, if it was there yet: whether it is selected doesn't
        // matter, a ⌘-click or closing its folder takes the selection away.
        let current = currentNode()
        let rowBefore = current.map { outline.row(forItem: $0) } ?? -1
        let placeBefore = rowBefore >= 0 ? outline.rect(ofRow: rowBefore) : nil
        let wasOnScreen = placeBefore?.intersects(outline.visibleRect) ?? false
        var topChanged = false
        var shown = false
        for node in nodes {
            let before = visible[ObjectIdentifier(node)]
            let wasEmpty = before?.isEmpty ?? true
            visible[ObjectIdentifier(node)] = nil
            if node.parent == nil {
                guard let section = section(forRoot: node) else { topChanged = true; continue }
                let old = section.children
                section.children = visibleChildren(of: node)
                if old.isEmpty, wasEmpty {
                    guard !section.children.isEmpty else { continue }
                    if outline.isItemExpanded(section) {
                        outline.insertItems(at: IndexSet(integersIn: 0..<section.children.count), inParent: section, withAnimation: .effectFade)
                    } else if !collapsedSections.contains(section.sectionKey ?? "") {
                        isExpandingSections = true
                        outline.expandItem(section)
                        isExpandingSections = false
                    }
                    shown = true
                } else if outline.isItemExpanded(section) {
                    rearrange(in: section, from: old, to: section.children, beforeReloading: keepExpansion)
                    shown = true
                } else {
                    keepExpansion()
                    outline.reloadItem(section, reloadChildren: true)
                }
            } else if outline.row(forItem: node) >= 0 {
                let children = visibleChildren(of: node)
                if outline.isItemExpanded(node), wasEmpty, !children.isEmpty {
                    outline.insertItems(at: IndexSet(integersIn: 0..<children.count), inParent: node, withAnimation: .effectFade)
                    shown = true
                } else if outline.isItemExpanded(node), let before, !before.isEmpty {
                    rearrange(in: node, from: before, to: children, beforeReloading: keepExpansion)
                    shown = true
                } else {
                    keepExpansion()
                    outline.reloadItem(node, reloadChildren: true)
                    shown = shown || outline.isItemExpanded(node)
                }
            }
        }
        if topChanged {
            keepExpansion()
            rebuildTop()
            outline.reloadData()
            expandSections()
        }
        // A folder read ahead of time, still closed, changes nothing on screen.
        guard topChanged || shown || !wantedExpansion.isEmpty || !movedExpansion.isEmpty else { return }
        if expanded != nil || !wantedExpansion.isEmpty || !movedExpansion.isEmpty { restoreExpansion(expanded ?? []) }
        if let current { selectRow(for: current, scrolling: false) } else { selectCurrent(scrolling: false) }
        // The open note's row showing for the first time (open at launch, its folder just read) is scrolled to. One that
        // was on screen and took another place is followed, gliding, only as far as it takes to keep it in view. Any
        // other change scrolls nothing: not when you are looking at another part of the sidebar, nor to show a row in
        // full that showed in part.
        guard let current else { return }
        let row = outline.row(forItem: current)
        guard row >= 0 else { return }
        if rowBefore < 0 {
            outline.scrollRowToVisible(row)
        } else if wasOnScreen, outline.rect(ofRow: row).minY != placeBefore?.minY {
            scrollRowToVisible(row, animated: true)
        }
    }

    /// The row selectCurrent selects: the folder you chose, else the open file. Nil while To-dos shows.
    private func currentNode() -> FileNode? {
        guard !workspace.showsTodos, let url = workspace.selectedFolder ?? workspace.currentURL else { return nil }
        return workspace.node(for: url, reading: false)
    }

    /// Moves, adds and takes away rows so they show a folder's files as they are now: they slide to their new places
    /// and fade in and out, and the rest of the sidebar stays as it is. Too many changes at once show all at once.
    /// The rows that stay show what changed about their files (in iCloud or not, a folder's look).
    private func rearrange(in parent: AnyObject, from old: [AnyObject], to new: [AnyObject], beforeReloading: () -> Void) {
        guard let changes = RowChanges(from: old.map(ObjectIdentifier.init), to: new.map(ObjectIdentifier.init), limit: 200) else {
            beforeReloading()
            outline.reloadItem(parent, reloadChildren: true)
            return
        }
        isSelectingProgrammatically = true
        if changes.count > 0 {
            outline.beginUpdates()
            for step in changes.steps {
                switch step {
                case .remove(let index): outline.removeItems(at: [index], inParent: parent, withAnimation: .effectFade)
                case .move(let from, let to): outline.moveItem(at: from, inParent: parent, to: to, inParent: parent)
                case .insert(let index): outline.insertItems(at: [index], inParent: parent, withAnimation: .effectFade)
                }
            }
            outline.endUpdates()
        }
        // Only the rows on screen, looked at one by one: a folder can hold thousands of files, and this runs at every
        // save of a note in it.
        let came = Set(changes.steps.compactMap { if case .insert(let index) = $0 { ObjectIdentifier(new[index]) } else { nil } })
        let onScreen = outline.rows(in: outline.visibleRect)
        var rows = IndexSet()
        for row in onScreen.location..<NSMaxRange(onScreen) {
            guard let item = outline.item(atRow: row) as AnyObject?, outline.parent(forItem: item) as AnyObject? === parent,
                  !came.contains(ObjectIdentifier(item)) else { continue }
            rows.insert(row)
        }
        if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: [0]) }
        isSelectingProgrammatically = false
    }

    private func section(forRoot root: FileNode) -> SidebarEntry? {
        workspace.locations.first { workspace.root(for: $0) === root }.flatMap(section(for:))
    }

    private func expandedPaths() -> Set<String> {
        var paths = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { paths.insert(node.url.path) }
        }
        return paths
    }

    /// Opens the folders that were open, and those open last time whose rows are there now.
    private func restoreExpansion(_ paths: Set<String>) {
        let paths = paths.union(wantedExpansion)
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, !outline.isItemExpanded(node),
               paths.contains(node.url.path) || movedExpansion.contains(HiddenFolders.withoutPrivate(node.url.path)) {
                outline.expandItem(node)
                wantedExpansion.remove(node.url.path)
            }
            row += 1
        }
        movedExpansion = []
        // Once every location has been read, folders from last time that aren't there any more are forgotten.
        if workspace.hasReadLocations { wantedExpansion = [] }
    }

    private func saveExpansion() {
        UserDefaults.standard.set(Array(expandedPaths()), forKey: "expandedFolders")
    }

    /// Opens the folders down to a file and scrolls it into view. For a location itself, its section.
    func reveal(_ url: URL, select: Bool) {
        guard let found = workspace.nodes(to: url, reading: false) else { return }
        let header = section(for: found.location)
        if let header, !outline.isItemExpanded(header) {
            collapsedSections.remove(header.sectionKey ?? "")
            outline.expandItem(header)
        }
        // The location's top is the section's header, not a row of its own.
        let nodes = found.nodes.dropFirst()
        for node in found.complete ? nodes.dropLast() : nodes where outline.row(forItem: node) >= 0 {
            outline.expandItem(node)
        }
        if let node = nodes.last {
            if select { selectRow(for: node) }
        } else if let header {
            scrollSectionToVisible(header)
        }
    }

    /// The header at the top, with as much of the section under it as fits.
    private func scrollSectionToVisible(_ header: SidebarEntry) {
        let row = outline.row(forItem: header)
        guard row >= 0 else { return }
        let next = topItems.firstIndex { $0 === header }.flatMap { topItems.indices.contains($0 + 1) ? outline.row(forItem: topItems[$0 + 1]) : nil }
        outline.scrollRowToVisible((next ?? outline.numberOfRows) - 1)
        outline.scrollRowToVisible(row)
    }

    /// The folder you selected, or else the open file, scrolled to unless `scrolling` is false; with To-dos or Favorites
    /// shown, their tile is selected, and no row.
    private func selectCurrent(scrolling: Bool = true) {
        if workspace.showsTodos || workspace.showsFavorites { return selectNoRow() }
        guard let current = workspace.selectedFolder ?? workspace.currentURL, let node = workspace.node(for: current, reading: false) else { return }
        selectRow(for: node, scrolling: scrolling)
    }

    /// To-dos or Favorites is shown: its tile is selected (it watches the workspace), and no row.
    func selectNoRow() {
        guard outline.selectedRow >= 0 else { return }
        isSelectingProgrammatically = true
        outline.deselectAll(nil)
        isSelectingProgrammatically = false
    }

    private func selectRow(for node: FileNode, scrolling: Bool = true) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        isSelectingProgrammatically = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scrolling { outline.scrollRowToVisible(row) }
        isSelectingProgrammatically = false
    }

    /// Scrolls a row into view, as little as it takes; with `animated`, gliding there, with rows that slide to new places.
    /// In a window nobody sees (behind others, or the display asleep) it is there at once: an animation only moves on
    /// while the screen is drawn.
    private func scrollRowToVisible(_ row: Int, animated: Bool) {
        let clip = scrollView.contentView
        let rect = outline.rect(ofRow: row)
        let shown = outline.visibleRect
        guard animated, outline.window?.occlusionState.contains(.visible) == true,
              rect.minY < shown.minY || rect.maxY > shown.maxY else { return outline.scrollRowToVisible(row) }
        let y = rect.minY < shown.minY ? clip.bounds.minY - (shown.minY - rect.minY) : clip.bounds.minY + (rect.maxY - shown.maxY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return topItems.count }
        if let entry = item as? SidebarEntry { return entry.children.count }
        return (item as? FileNode).map { visibleChildren(of: $0).count } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return topItems[index] }
        if let entry = item as? SidebarEntry { return entry.children[index] }
        return visibleChildren(of: item as! FileNode)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let entry = item as? SidebarEntry { return entry.isHeader }
        return (item as? FileNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarEntry)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let entry = item as? SidebarEntry else { return true }
        return !entry.isHeader && !entry.isSearch && !entry.isHosted && !entry.isOpenFolder
    }

    /// The tiles and the cards as tall as they are; every other row as tall as the source list makes them.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let entry = item as? SidebarEntry else { return outlineView.rowHeight }
        switch entry.kind {
        case .tiles: return 74
        case .recent: return SidebarOutlineView.recentRowHeight(width: recentRowWidth)
        case .header, .search: return outlineView.rowHeight
        case .openFolder: return outlineView.rowHeight + SidebarOutlineView.openFolderGap
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView ?? SidebarRowView()
        rowView.gap = (item as? SidebarEntry)?.isOpenFolder == true ? SidebarOutlineView.openFolderGap : 0
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        outline.queueHoverUpdate()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let entry = item as? SidebarEntry, case .header(let title, let id) = entry.kind {
            let cell = outlineView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) as? SidebarHeaderCell ?? SidebarHeaderCell()
            cell.label.stringValue = title
            cell.isExpanded = outlineView.isItemExpanded(item)
            cell.fold = { [weak self] in self?.toggle(section: entry) }
            // A location's header has ••• (its right-click menu) and + (a new note at its top); Favorites has neither.
            let location = workspace.locations.first { $0.id == id }
            cell.setButtons(for: title, more: location == nil ? nil : { [weak self] button in self?.showMenu(forRowOf: button) },
                            add: location.map { location in { [weak self] in self?.workspace.newNote(in: location.url) } })
            if let location, workspace.hasHiddenFolders(in: location), workspace.showsHiddenFolders(in: location) {
                cell.showHiddenButton(true) { [weak self] in self?.workspace.showHiddenFolders(false, in: location) }
            } else {
                cell.showHiddenButton(false)
            }
            return cell
        }
        if let entry = item as? SidebarEntry, entry.isHosted {
            if case .tiles = entry.kind { return tilesCell }
            return recentCell
        }
        let cell = outlineView.makeView(withIdentifier: SidebarFileCell.identifier, owner: nil) as? SidebarFileCell ?? SidebarFileCell()
        cell.label.delegate = self
        if (item as? SidebarEntry)?.isSearch == true {
            cell.configureSearch { [weak self] in self?.workspace.openSearch() }
            cell.setButtons(more: nil, add: nil)
            return cell
        }
        if (item as? SidebarEntry)?.isOpenFolder == true {
            cell.configureOpenFolder { [weak self] in self?.workspace.chooseLocation(iCloud: false) }
            cell.setButtons(more: nil, add: nil)
            return cell
        }
        // Under the pointer: ••• (the row's right-click menu), and on a folder + (a new note in it), as in Notion.
        let rowURL = (item as? FileNode)?.url ?? (item as? SidebarEntry)?.url
        let isFolder = (item as? FileNode)?.isFolder ?? rowURL.map(FileNode.isFolder) ?? false
        cell.setButtons(more: { [weak self] button in self?.showMenu(forRowOf: button) },
                        add: isFolder ? rowURL.map { url in { [weak self] in self?.workspace.newNote(in: url) } } : nil)
        let nested = outlineView.level(forItem: item) > 1
        if let node = item as? FileNode {
            // Folders on screen are read ahead, so opening one shows its files straight away.
            workspace.prefetch(node)
            // Hidden folders show dimmed while their location shows them, as hidden files in the Finder.
            let dimmed = NotebookSettings.shared.dimsOtherFiles && !node.isFolder && node.kind != .note || node.isFolder && workspace.isHidden(node.url)
            cell.configure(name: workspace.newName(for: node.url) ?? node.name, kind: node.kind, inCloud: node.isInCloud, url: node.url, icon: node.icon, nested: nested,
                           dimmed: dimmed, reminder: node.kind == .note ? workspace.reminder(for: node.url) : nil,
                           items: node.isFolder ? workspace.shownCount(of: node.url) : nil)
        }
        return cell
    }

    /// The little arrow by a section's name, turned for open or folded.
    private func showFolding(of item: Any?) {
        guard let entry = item as? SidebarEntry, entry.isHeader else { return }
        let row = outline.row(forItem: entry)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell else { return }
        cell.isExpanded = outline.isItemExpanded(entry)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        outline.placeChevron(of: notification.userInfo?["NSObject"])
        showFolding(of: notification.userInfo?["NSObject"])
        if let entry = notification.userInfo?["NSObject"] as? SidebarEntry, let key = entry.sectionKey {
            guard !isExpandingSections else { return }
            collapsedSections.remove(key)
            UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
        } else {
            saveExpansion()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        outline.placeChevron(of: notification.userInfo?["NSObject"])
        showFolding(of: notification.userInfo?["NSObject"])
        if let entry = notification.userInfo?["NSObject"] as? SidebarEntry, let key = entry.sectionKey {
            collapsedSections.insert(key)
            UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
        } else {
            saveExpansion()
        }
    }

    // MARK: - Selection and clicks

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, renaming == nil else { return }
        let row = outline.selectedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let node = item as? FileNode {
            if node.isFolder {
                workspace.selectedFolder = node.url
            } else {
                open(node.url)
            }
        }
    }

    /// Opens a file right after the row shows as selected, so the sidebar answers at once; with the arrow keys held
    /// down only the row you stop on opens.
    private var pendingOpen: URL?

    private func open(_ url: URL) {
        pendingOpen = url
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingOpen == url else { return }
            self.pendingOpen = nil
            self.workspace.open(url)
        }
    }

    /// A click on a folder opens or closes it straight away, every click, with a short slide.
    func toggle(_ node: FileNode) {
        slide(node)
    }

    /// A click on a section's header folds it or opens it again.
    func toggle(section entry: SidebarEntry) {
        slide(entry)
    }

    private func slide(_ item: Any) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if outline.isItemExpanded(item) { outline.animator().collapseItem(item) } else { outline.animator().expandItem(item) }
        }
    }

    /// The ••• of a row or a section's header: its right-click menu, under the button.
    func showMenu(forRowOf view: NSView) {
        let row = outline.row(for: view)
        guard row >= 0 else { return }
        let menu = NSMenu()
        fill(menu, row: row)
        guard !menu.items.isEmpty else { return }
        markMenu(of: row)
        GlassMenu.show(GlassMenu.entries(from: menu), at: view.bounds, in: view) { [weak self] in self?.markMenu(of: nil) }
        outline.queueHoverUpdate()
    }

    /// A right-click: the row's menu in glass at the pointer, the row ringed while it is open, as AppKit rings it.
    func showMenu(for event: NSEvent) {
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        fill(menu, row: row)
        guard !menu.items.isEmpty else { return }
        markMenu(of: row >= 0 ? row : nil)
        GlassMenu.show(GlassMenu.entries(from: menu), at: event, in: outline) { [weak self] in self?.markMenu(of: nil) }
    }

    /// The row whose menu is open.
    private var menuRow: Int?

    private func markMenu(of row: Int?) {
        if let old = menuRow, let view = outline.rowView(atRow: old, makeIfNecessary: false) as? SidebarRowView { view.isMenuTarget = false }
        menuRow = row
        if let row, let view = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView { view.isMenuTarget = true }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        openOnItsOwn(row: outline.clickedRow)
    }

    /// A double-click opens a file on its own, as in the Finder: a note in a window of its own, anything else in the
    /// app the Mac has for it. A folder already opens and closes with each click.
    func openOnItsOwn(row: Int) {
        guard let url = url(at: row) else { return }
        guard !((outline.item(atRow: row) as? FileNode)?.isFolder ?? FileNode.isFolder(url)) else { return }
        workspace.openOnItsOwn(url)
    }

    /// What shows once the file of a row goes to the Trash, as Notes shows the next note: the next file in its folder,
    /// or else the one before it. Folders are passed over.
    func nextFile(after row: Int) -> URL? {
        guard row >= 0, let item = outline.item(atRow: row) else { return nil }
        let parent = outline.parent(forItem: item)
        let index = outline.childIndex(forItem: item)
        guard index >= 0 else { return nil }
        for other in Array(index + 1 ..< outline.numberOfChildren(ofItem: parent)) + Array((0..<index).reversed()) {
            if let node = outline.child(other, ofItem: parent) as? FileNode, !node.isFolder { return node.url }
        }
        return nil
    }

    /// Tab: the keyboard to the note that is open, with the caret where it was. False when no note is open to type in.
    func focusNote() -> Bool {
        guard workspace.note?.isLoaded == true, !workspace.showsTodos, let window = outline.window else { return false }
        return window.makeFirstResponder(workspace.editor.textView)
    }

    func url(at row: Int) -> URL? {
        guard row >= 0 else { return nil }
        let item = outline.item(atRow: row)
        return (item as? FileNode)?.url ?? (item as? SidebarEntry)?.url
    }

    var selectedURL: URL? { url(at: outline.selectedRow) }

    // MARK: - Renaming in place

    func beginRenaming(_ url: URL) {
        guard let node = workspace.node(for: url), !node.isLinked else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFileCell else { return }
        renaming = url
        cell.label.isEditable = true
        cell.label.isSelectable = true
        outline.window?.makeFirstResponder(cell.label)
        if let editor = cell.label.currentEditor() { editor.selectedRange = NSRange(location: 0, length: (cell.label.stringValue as NSString).length) }
    }

    /// Takes the name being typed, as a click elsewhere would.
    func endRenaming() {
        guard renaming != nil else { return }
        outline.window?.makeFirstResponder(outline)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.isSelectable = false
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if movement == NSTextMovement.cancel.rawValue || name.isEmpty || name == current {
            field.stringValue = current
        } else {
            var target = name
            // Typing a name with the extension for a file that has one keeps just one extension.
            if !url.pathExtension.isEmpty, (name as NSString).pathExtension.lowercased() == url.pathExtension.lowercased() {
                target = (name as NSString).deletingPathExtension
            }
            // The name typed stays on the row while the file is renamed off the main thread; it goes back only when
            // the name is taken.
            let renaming = workspace.rename(url, to: target)
            Task { if await renaming.value == nil { field.stringValue = current } }
        }
        outline.window?.makeFirstResponder(outline)
        let held = (nodes: heldNodes, all: heldAll)
        heldNodes = []
        heldAll = false
        if held.all { reloadAll() } else if !held.nodes.isEmpty { reload(held.nodes) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField, let url = renaming {
            field.stringValue = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            outline.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, row: outline.clickedRow)
    }

    func fill(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let entry = item as? SidebarEntry, entry.isHosted || entry.isSearch || entry.isOpenFolder { return }
        if let entry = item as? SidebarEntry, case .header(_, let locationID) = entry.kind, let locationID,
           let location = workspace.locations.first(where: { $0.id == locationID }) {
            add(menu, "New Note", "square.and.pencil") { [weak self] in self?.workspace.newNote(in: location.url) }
            add(menu, "New Folder", "folder.badge.plus") { [weak self] in self?.workspace.newFolder(in: location.url) }
            menu.addItem(.separator())
            add(menu, "Show in Finder", "folder") { [weak self] in self?.workspace.revealInFinder(location.url) }
            if workspace.hasHiddenFolders(in: location) {
                let shows = workspace.showsHiddenFolders(in: location)
                add(menu, shows ? "Hide Hidden Folders" : "Show Hidden Folders", shows ? "eye.slash" : "eye") { [weak self] in
                    self?.workspace.showHiddenFolders(!shows, in: location)
                }
            }
            menu.addItem(.separator())
            add(menu, "Open Folder…", "plus.rectangle.on.folder") { [weak self] in self?.workspace.chooseLocation(iCloud: false) }
            add(menu, "Remove from Sidebar", "minus.circle") { [weak self] in self?.workspace.removeLocation(locationID) }
            return
        }
        guard let url = url(at: row) else {
            // The empty part of the sidebar.
            add(menu, "New Note", "square.and.pencil") { [weak self] in self?.workspace.newNote() }
            add(menu, "Open Folder…", "plus.rectangle.on.folder") { [weak self] in self?.workspace.chooseLocation(iCloud: false) }
            return
        }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isFolder ? url : url.deletingLastPathComponent()
        // A linked folder (iCloud Drive's Desktop) stays where it is, under its own name.
        let isLinked = workspace.isLinkedFolder(url)
        add(menu, "New Note in “\(workspace.folderName(folder))”", "square.and.pencil") { [weak self] in self?.workspace.newNote(in: folder) }
        add(menu, "New Folder", "folder.badge.plus") { [weak self] in self?.workspace.newFolder(in: folder) }
        menu.addItem(.separator())
        if !isFolder, FileKind(url: url, isDirectory: false) == .note {
            add(menu, "Open in New Window", "macwindow.badge.plus") { [weak self] in self?.workspace.openOnItsOwn(url) }
        } else if !isFolder {
            if let app = workspace.appName(opening: url) {
                add(menu, "Open in \(app)", "arrow.up.forward.app") { [weak self] in self?.workspace.openOnItsOwn(url) }
            }
            add(menu, "Quick Look", "eye") { [weak self] in self?.workspace.quickLook(url) }
        }
        let anchor = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
        if FileKind(url: url, isDirectory: isFolder) == .note {
            add(menu, "Remind Me…", "bell") { [weak self] in self?.workspace.askForReminder(url, from: anchor) }
        }
        if !isLinked {
            add(menu, "Rename", "pencil") { [weak self] in self?.beginRenaming(url) }
            menu.addItem(moveToItem(for: url))
            add(menu, "Duplicate", "plus.square.on.square") { [weak self] in self?.workspace.duplicate(url) }
        }
        let favorite = workspace.isFavorite(url)
        add(menu, favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") { [weak self] in self?.workspace.toggleFavorite(url) }
        if isFolder, workspace.canCustomize(url) {
            add(menu, "Customize Folder…", "paintpalette") { [weak self] in self?.workspace.customizeFolder(url, from: anchor) }
        }
        if isFolder, workspace.canHide(url) {
            let isHidden = workspace.isHidden(url)
            add(menu, isHidden ? "Unhide Folder" : "Hide Folder", isHidden ? "eye" : "eye.slash") { [weak self] in self?.workspace.setHidden(url, !isHidden) }
        }
        menu.addItem(.separator())
        // As the Finder's, with the key Copy File has in the Edit menu.
        let copy = add(menu, "Copy “\(Workspace.shownName(url))”", "doc.on.doc") { [weak self] in self?.workspace.copyFile(url) }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]
        if !isFolder { add(menu, "Copy Link", "link") { [weak self] in self?.workspace.copyLink(url) } }
        add(menu, "Show in Finder", "folder") { [weak self] in self?.workspace.revealInFinder(url) }
        if !isLinked {
            menu.addItem(.separator())
            let trash = add(menu, "Move to Trash", "trash") { [weak self] in self?.workspace.trash(url, next: self?.nextFile(after: row)) }
            trash.isDestructive = true
            trash.keyEquivalent = "\u{8}"
            trash.keyEquivalentModifierMask = .command
        }
    }

    /// Move To, with every folder indented under its location, as in Notes.
    private func moveToItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        item.submenu = MoveToSubmenu(workspace: workspace) { url }
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ symbol: String, action: @escaping () -> Void) -> ClosureMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    /// The keys the menu shows are the Edit menu's, for the selected file: never its items, which are for the row
    /// last clicked.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if let node = item as? FileNode { return node.isLinked ? nil : node.url as NSURL }
        if let entry = item as? SidebarEntry, let url = entry.url, !workspace.isLinkedFolder(url) { return url as NSURL }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Between the sections or below them, a folder from elsewhere becomes a location, shown where it is. The
        // whole sidebar lights up, not a place in a section.
        if isBetweenSections(info, proposedItem: item), workspace.newLocations(in: urls) != nil {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return info.draggingSourceOperationMask.contains(.link) ? .link : .generic
        }
        if let entry = item as? SidebarEntry, entry.isHosted || entry.isSearch || entry.isOpenFolder { return [] }
        guard let folder = dropFolder(for: item) else { return [] }
        guard !urls.isEmpty, !urls.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) else { return [] }
        if let node = folderNode(for: item) { outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        let local = urls.allSatisfy { workspace.location(containing: $0) != nil }
        return local && !isCopy(info) ? .move : .copy
    }

    /// Option-dragged, or a picture or file dragged out of a note, which keeps its own.
    private func isCopy(_ info: NSDraggingInfo) -> Bool {
        NSEvent.modifierFlags.contains(.option) || info.draggingSource is ObjectDrag
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Only a drop that adds locations is on the sidebar as a whole.
        if item == nil { return workspace.addLocations(urls) }
        guard let folder = dropFolder(for: item) else { return false }
        workspace.drop(urls, into: folder, copying: isCopy(info))
        return true
    }

    /// Between two sections, above the first, on Open Folder or in the empty space below it. Below the last section
    /// the outline proposes the end of whatever is open there, so that is told by where the pointer is.
    private func isBetweenSections(_ info: NSDraggingInfo, proposedItem item: Any?) -> Bool {
        let row = outline.row(at: outline.convert(info.draggingLocation, from: nil))
        return item == nil || row < 0 || (outline.item(atRow: row) as? SidebarEntry)?.isOpenFolder == true
    }

    private func folderNode(for item: Any?) -> FileNode? {
        guard let node = item as? FileNode else { return nil }
        return node.isFolder ? node : node.parent
    }

    /// Where Paste puts what was copied, as in the Finder: the folder selected, the folder of the file selected, or the
    /// top of the location whose header is.
    var pasteFolder: URL? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        let item = outline.item(atRow: row)
        if let folder = dropFolder(for: item) { return folder }
        guard let url = (item as? SidebarEntry)?.url else { return nil }
        return FileNode.isFolder(url) ? url : url.deletingLastPathComponent()
    }

    private func dropFolder(for item: Any?) -> URL? {
        if let entry = item as? SidebarEntry, case .header(_, let id?) = entry.kind {
            return workspace.locations.first { $0.id == id }?.url
        }
        if let node = folderNode(for: item) { return node.url }
        if let node = item as? FileNode, node.parent == nil { return node.url.deletingLastPathComponent() }
        if let file = item as? FileNode { return file.url.deletingLastPathComponent() }
        return nil
    }
}

/// Keys the Finder has: Return renames, ⌘⌫ moves to the Trash, Space shows Quick Look, ⌘C copies the file and ⌘V
/// pastes in its folder. Tab goes on into the note, as it goes from the list to the note in Notes and Mail.
final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarController?

    // A folder opens or closes on the press itself, so quick clicks each count; dragging still works after it. A
    // section folds with a click on its header, as in Notion; the header's buttons take their own clicks.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        // ••• and + (and the eye) take their own clicks: the row stays as it is.
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false),
           cell.subviews.contains(where: { $0 is NSButton && !$0.isHidden && $0.frame.contains(cell.convert(point, from: self)) }) {
            super.mouseDown(with: event)
            return
        }
        if row >= 0, let entry = item(atRow: row) as? SidebarEntry, entry.isHeader {
            controller?.toggle(section: entry)
            return
        }
        // Search opens ⌘K and is never selected: what is open stays selected below it.
        if row >= 0, let entry = item(atRow: row) as? SidebarEntry, entry.isSearch {
            controller?.workspace.openSearch()
            return
        }
        // So does Open Folder, which asks for a folder to show.
        if row >= 0, let entry = item(atRow: row) as? SidebarEntry, entry.isOpenFolder {
            controller?.workspace.chooseLocation(iCloud: false)
            return
        }
        if row >= 0, let node = item(atRow: row) as? FileNode, node.isFolder,
           event.modifierFlags.intersection([.command, .shift]).isEmpty,
           !frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: -4).contains(point) {
            controller?.toggle(node)
        }
        super.mouseDown(with: event)
    }

    /// A right-click opens the row's menu in glass, like every menu of the app; VoiceOver's Show Menu still gets the
    /// AppKit menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        if GlassMenu.isContextClick(event), let controller {
            controller.showMenu(for: event)
            return nil
        }
        return super.menu(for: event)
    }

    // A folder's arrow a step quieter than AppKit's, as Notion has them: the folder's icon and name say more. No
    // Show/Hide at the end of a section's header: a click on the header folds it, as in Notion, and its end has the
    // header's own ••• and +. (Turned off with shouldShowOutlineCell, AppKit wouldn't fold the section at all.)
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier { view?.alphaValue = 0.7 }
        if identifier == NSOutlineView.showHideButtonIdentifier { view?.alphaValue = 0 }
        return view
    }

    // MARK: Under the pointer

    /// The row under the pointer, which shows a soft fill and its ••• and + buttons, as rows do in Notion. Only in the
    /// key window, as other hover effects on the Mac.
    private(set) var hoveredRow = -1
    /// A row shown as under the pointer whatever the pointer does, for the debug remote's pictures.
    var pinnedHoverRow: Int? {
        didSet { updateHover() }
    }
    private var hoverArea: NSTrackingArea?
    private var isHoverUpdateQueued = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(onlyIfMoved: true)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { updateHover() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { updateHover() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(queueHoverUpdate), name: name, object: newWindow)
        }
    }

    /// Rows move under a pointer that stays put: the list scrolled, changed, or the window came to the front.
    @objc func queueHoverUpdate() {
        guard !isHoverUpdateQueued else { return }
        isHoverUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.isHoverUpdateQueued = false
            self?.updateHover()
        }
    }

    /// `onlyIfMoved`: leaves the rows alone while the pointer stays in the same one.
    func updateHover(onlyIfMoved: Bool = false) {
        var row = -1
        if let pinnedHoverRow {
            row = pinnedHoverRow
        } else if let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(point) { row = self.row(at: point) }
        }
        if onlyIfMoved, row == hoveredRow { return }
        hoveredRow = row
        // Every row on screen, as rows that were added or removed have moved the others.
        enumerateAvailableRowViews { rowView, index in applyHover(to: rowView, row: index) }
    }

    func applyHover(to rowView: NSTableRowView, row: Int) {
        // The tiles and cards show it on the one under the pointer themselves (`HomeHover`), not on the whole row.
        let hovered = row == hoveredRow && !(rowView.view(atColumn: 0) is SidebarHostedCell)
        (rowView as? SidebarRowView)?.isHovered = hovered
        if let cell = rowView.view(atColumn: 0) as? SidebarFileCell {
            cell.isHovered = hovered
        } else if let cell = rowView.view(atColumn: 0) as? SidebarHeaderCell {
            cell.isHovered = hovered
        }
    }

    /// How far left of the files' cells Search starts: its magnifying glass lines up with the folders' chevrons and the
    /// section titles, and with the tiles' symbols, rather than with the files' icons.
    static let searchShift: CGFloat = 15
    /// Open Folder's row is this much taller than a file's, with the room above it: apart from the last section's files,
    /// as a section's title is from the one before.
    static let openFolderGap: CGFloat = 8
    /// From the sidebar's edges to the tiles and Recent's cards, about as far as a selected row's fill: what is in them,
    /// `HomeStyle.cardPadding` further in, then lines up with Search, the chevrons and the section titles.
    static let tilesFromEdge: CGFloat = 10.5

    /// Search reaches as far towards the sidebar's right edge as it starts from its left, so ⌘K ends over the tiles'
    /// counts. The tiles span the sidebar less `tilesFromEdge` on either side. Recent's row goes all the way across:
    /// its cards stop at the tiles' column, and the next one peeks in at the edge, so the row plainly scrolls.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard let entry = item(atRow: row) as? SidebarEntry else { return frame }
        let rowFrame = rect(ofRow: row)
        switch entry.kind {
        case .search:
            frame.origin.x -= Self.searchShift
            frame.size.width = rowFrame.maxX - (frame.minX - rowFrame.minX) - frame.minX
        case .openFolder:
            // Lined up with Search, at the bottom of its row, below the gap.
            frame.origin.x -= Self.searchShift
            frame.size.width = rowFrame.maxX - (frame.minX - rowFrame.minX) - frame.minX
            frame.origin.y = rowFrame.maxY - rowHeight
            frame.size.height = rowHeight
        case .tiles:
            frame.origin.x = rowFrame.minX + Self.tilesFromEdge
            frame.size.width = rowFrame.width - 2 * Self.tilesFromEdge
        case .recent:
            frame.origin.x = rowFrame.minX
            frame.size.width = rowFrame.width
        case .header:
            break
        }
        return frame
    }

    /// Recent's row as tall as its cards, which are as wide as the tiles: their pictures keep their shape as the
    /// sidebar is made wider or narrower. The rest of a card, its name and folder, and the row's margins take 62 pt.
    /// `width` is the sidebar's, not the files' (`SidebarController.recentRowWidth`).
    static func recentRowHeight(width: CGFloat) -> CGFloat {
        let card = (width - 2 * tilesFromEdge - HomeStyle.spacing) / 2
        let picture = (card - 2 * HomeStyle.cardPadding) * HomeStyle.picture.height / HomeStyle.picture.width
        return (picture + 62).rounded(.up)
    }

    // A folder's chevron centred on its icon, which is in the middle of the row; AppKit puts it 1–1.5 pt lower. The
    // chevron is a pixel right of the middle of its picture, so turned down for an open folder it's a pixel lower; a
    // subfolder's smaller icon is a pixel higher. Section headers have none: a click on them folds them.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        // A header's Show/Hide, which shows nothing, takes no clicks either: + is where it was.
        if (item(atRow: row) as? SidebarEntry)?.isHeader == true { return NSRect(x: frame.maxX, y: frame.midY, width: 0, height: 0) }
        guard !frame.isEmpty, level(forRow: row) > 0 else { return frame }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let pixels = (isItemExpanded(item(atRow: row)) ? 1 : 0) + (level(forRow: row) > 1 ? 1 : 0)
        frame.origin.y = rect(ofRow: row).midY - frame.height / 2 - CGFloat(pixels) * pixel
        return frame
    }

    /// Moves the chevron of a folder that opened or closed, which AppKit only turns.
    func placeChevron(of item: Any?) {
        let row = row(forItem: item)
        guard row >= 0, let rowView = rowView(atRow: row, makeIfNecessary: false) else { return }
        placeChevron(in: rowView, row: row)
    }

    private func placeChevron(in rowView: NSTableRowView, row: Int) {
        guard level(forRow: row) > 0,
              let button = rowView.subviews.first(where: { $0.identifier == NSOutlineView.disclosureButtonIdentifier }) else { return }
        button.frame = rowView.convert(frameOfOutlineCell(atRow: row), from: self)
    }

    // A pixel is another distance on another screen.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        enumerateAvailableRowViews { rowView, row in placeChevron(in: rowView, row: row) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.isEmpty, let controller, controller.focusNote() { return }
        guard let controller, let url = controller.selectedURL else { super.keyDown(with: event); return }
        switch (event.keyCode, flags) {
        case (36, []), (76, []):
            controller.beginRenaming(url)
        case (51, .command):
            controller.workspace.trash(url, next: controller.nextFile(after: selectedRow))
        case (49, []):
            if FileKind(url: url, isDirectory: false) == .note { super.keyDown(with: event) } else { controller.workspace.quickLook(url) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Edit › Copy (⌘C) copies the selected file, as in the Finder.
    @objc func copy(_ sender: Any?) {
        guard let controller, let url = controller.selectedURL else { return beep() }
        controller.workspace.copyFile(url)
    }

    /// Edit › Paste (⌘V) puts what was copied in the selected folder, as in the Finder: files as copies, and text as a
    /// note of its own (`Workspace.paste(from:into:)`).
    @objc func paste(_ sender: Any?) {
        guard let controller, let folder = controller.pasteFolder else { return beep() }
        controller.workspace.paste(from: appPasteboard, into: folder)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller?.selectedURL != nil }
        if item.action == #selector(paste(_:)) { return controller?.pasteFolder != nil && Workspace.canPaste(from: appPasteboard) }
        return super.validateUserInterfaceItem(item)
    }
}

/// A sidebar row. Under the pointer it shows a soft fill in the shape of the selection, as rows do in Notion: the
/// selection AppKit draws fills the whole row, 10 pt in from the sidebar's sides, with corners of about 7.5 pt.
final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
    /// About half as strong as the selection when the sidebar doesn't have the keyboard.
    private static let hoverFill = NSColor(name: "SidebarHoverFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.025) : NSColor(white: 0, alpha: 0.025)
    }

    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// Room at the top that isn't the row's: Open Folder's gap above it (`SidebarOutlineView.openFolderGap`).
    var gap: CGFloat = 0

    /// Its menu is open: ringed in the accent colour, as AppKit rings the row of a right-click menu.
    var isMenuTarget = false {
        didSet { if isMenuTarget != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMenuTarget {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 11, dy: 1), xRadius: 6.5, yRadius: 6.5)
            ring.lineWidth = 2
            ring.stroke()
        }
        guard isHovered, !isSelected, !isGroupRowStyle else { return }
        Self.hoverFill.setFill()
        var row = bounds
        row.origin.y += gap
        row.size.height -= gap
        NSBezierPath(roundedRect: row.insetBy(dx: 10, dy: 0), xRadius: 7.5, yRadius: 7.5).fill()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isMenuTarget = false
    }
}

/// ••• or + at the end of a row or section header under the pointer, as Notion has them: a symbol in the controls' grey,
/// no border.
@MainActor
private func hoverButton(_ symbol: String, action: Selector) -> NSButton {
    let button = NSButton()
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    button.contentTintColor = .secondaryLabelColor
    button.action = action
    button.isHidden = true
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 20), button.heightAnchor.constraint(equalToConstant: 20)])
    return button
}

/// Where ••• and + sit in a row or header: + about 19 pt from the sidebar's edge, ten inside the row's fill, and •••
/// 12 pt before it, as in Notion. Measured from the row's end, as a header's cell runs to it and a file's ends 14 pt
/// before it.
@MainActor
private enum HoverButtons {
    static let addFromRowEnd: CGFloat = 16
    static let moreBeforeAdd: CGFloat = 4

    /// The + button's trailing constraint, kept at the same place in every row as the cell's end moves.
    static func place(_ constraint: NSLayoutConstraint, in cell: NSView) {
        guard let row = cell.superview else { return }
        let constant = -(addFromRowEnd - (row.bounds.maxX - cell.frame.maxX))
        if constraint.constant != constant {
            constraint.constant = constant
            cell.needsLayout = true
        }
    }
}

final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")
    let label = NSTextField(labelWithString: "")
    /// The location's right-click menu (New Note, New Folder, Show in Finder, Show Hidden Folders, Remove from Sidebar),
    /// there while the pointer is on the header, as Notion's sections have it.
    let moreButton = hoverButton("ellipsis", action: #selector(SidebarHeaderCell.moreClicked(_:)))
    /// A new note at the top of the location, as Notion's + on a section makes a page.
    let addButton = hoverButton("plus", action: #selector(SidebarHeaderCell.addClicked))
    /// While a location's hidden folders show: the eye in the accent colour, like a filter that is on, which hides them
    /// again. Show Hidden Folders itself is in •••.
    let hiddenButton = NSButton()
    /// Turned down while the section is open, right while it's folded; under the pointer, as AppKit's Show/Hide was.
    private let foldArrow = NSImageView()
    private var addEnd: NSLayoutConstraint!
    private var more: ((NSView) -> Void)?
    private var add: (() -> Void)?
    private var hideHidden: (() -> Void)?
    /// Folds or opens the section: what a click on the header does, offered to VoiceOver as an action, as the
    /// Show/Hide button was.
    var fold: (() -> Void)?
    var isHovered = false {
        didSet { updateButtons() }
    }
    var isExpanded = true {
        didSet { updateFolding() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = label
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        for button in [moreButton, addButton] { button.target = self }
        hiddenButton.isBordered = false
        hiddenButton.imagePosition = .imageOnly
        hiddenButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        hiddenButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        hiddenButton.contentTintColor = .controlAccentColor
        hiddenButton.toolTip = "Hide Hidden Folders"
        hiddenButton.setAccessibilityLabel("Hide Hidden Folders")
        hiddenButton.target = self
        hiddenButton.action = #selector(hiddenClicked)
        hiddenButton.translatesAutoresizingMaskIntoConstraints = false
        foldArrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        foldArrow.contentTintColor = .tertiaryLabelColor
        foldArrow.translatesAutoresizingMaskIntoConstraints = false
        for view in [moreButton, addButton, hiddenButton, foldArrow] { addSubview(view) }
        addEnd = addButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            foldArrow.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            foldArrow.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            foldArrow.trailingAnchor.constraint(lessThanOrEqualTo: hiddenButton.leadingAnchor, constant: -2),
            addEnd,
            addButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -HoverButtons.moreBeforeAdd),
            moreButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            hiddenButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -HoverButtons.moreBeforeAdd),
            hiddenButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            hiddenButton.widthAnchor.constraint(equalToConstant: 20),
            hiddenButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        updateFolding()
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `more` and `add` are nil for a section that isn't a location (Favorites).
    func setButtons(for title: String, more: ((NSView) -> Void)?, add: (() -> Void)?) {
        self.more = more
        self.add = add
        moreButton.toolTip = "More"
        moreButton.setAccessibilityLabel("More for \(title)")
        addButton.toolTip = "New Note"
        addButton.setAccessibilityLabel("New Note in \(title)")
        updateButtons()
    }

    /// The eye, while the location shows its hidden folders.
    func showHiddenButton(_ shows: Bool, hide: (() -> Void)? = nil) {
        hiddenButton.isHidden = !shows
        hideHidden = hide
    }

    private func updateButtons() {
        moreButton.isHidden = more == nil || !isHovered
        addButton.isHidden = add == nil || !isHovered
        foldArrow.isHidden = !isHovered
    }

    private func updateFolding() {
        foldArrow.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: isExpanded ? "Collapse" : "Expand") { [weak self] in
            self?.fold?()
            return self?.fold != nil
        }])
    }

    @objc private func moreClicked(_ sender: NSButton) {
        more?(sender)
    }

    @objc private func addClicked() {
        add?()
    }

    @objc private func hiddenClicked() {
        hideHidden?()
    }

    override func layout() {
        HoverButtons.place(addEnd, in: self)
        super.layout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

/// A row of SwiftUI in the sidebar: the tiles of To-dos and Favorites, or Recent's cards. They watch the workspace
/// themselves, so counts and cards change without the row being reloaded.
final class SidebarHostedCell: NSTableCellView {
    static let tiles = NSUserInterfaceItemIdentifier("tiles")
    static let recent = NSUserInterfaceItemIdentifier("recent")

    init<Content: View>(_ identifier: NSUserInterfaceItemIdentifier, _ content: Content, insets: NSEdgeInsets) {
        super.init(frame: .zero)
        self.identifier = identifier
        let host = OpaqueHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        // The row has its height (`heightOfRowByItem`): the view fills it rather than asking for its own.
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            host.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The tiles and cards bring their own fills and colours, which the sidebar's vibrancy would otherwise blend.
private final class OpaqueHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { false }
}

final class SidebarFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let accessory = NSImageView()
    /// How many files a folder holds, as Notes counts a folder's notes, or Search's shortcut.
    let count = NSTextField(labelWithString: "")
    /// The row's right-click menu, there while the pointer is on the row, as in Notion.
    let moreButton = hoverButton("ellipsis", action: #selector(SidebarFileCell.moreClicked(_:)))
    /// On a folder: a new note in it, as Notion's + on a page makes a page in it.
    let addButton = hoverButton("plus", action: #selector(SidebarFileCell.addClicked))
    private var more: ((NSView) -> Void)?
    private var add: (() -> Void)?
    /// The name ends before ••• and + while they show, and runs on to the bell or cloud otherwise.
    private var labelBeforeButtons: NSLayoutConstraint!
    private var addEnd: NSLayoutConstraint!
    /// ••• before + on a folder, and in +'s place on a file, which never has one.
    private var moreBeforeAdd: NSLayoutConstraint!
    private var moreInAddsPlace: NSLayoutConstraint!
    /// A folder's count 8 pt before the cell's end; Search's ⌘K at the tiles' right edge below it, as its cell reaches
    /// as far from the sidebar's edge as it starts (`SidebarOutlineView.frameOfCell`): the tips of the K on the tiles'
    /// edge, as the tiles' inset is.
    private var countEnd: NSLayoutConstraint!
    private static let countInset: CGFloat = -8
    private static let searchShortcutInset: CGFloat = -6.75
    var isHovered = false {
        didSet { updateButtons() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // Not the cell's imageView: the source list would size and place it itself, further right than Notes does.
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        accessory.contentTintColor = Theme.textTertiary
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.isHidden = true
        addSubview(icon)
        addSubview(label)
        addSubview(accessory)
        addSubview(count)
        for button in [moreButton, addButton] {
            button.target = self
            addSubview(button)
        }
        moreButton.toolTip = "More"
        addButton.toolTip = "New Note"
        countEnd = count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.countInset)
        labelBeforeButtons = label.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -4)
        addEnd = addButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        moreBeforeAdd = moreButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -HoverButtons.moreBeforeAdd)
        moreInAddsPlace = moreButton.trailingAnchor.constraint(equalTo: addButton.trailingAnchor)
        // 9 pt from a folder's arrow, which AppKit puts just before the cell, to the icon, and 9 pt from the icon to the
        // name, as in Notion; Notes has them closer, which looked cramped. The icon keeps its own size, centred on its
        // column.
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14.5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -4),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            countEnd,
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            addEnd,
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreBeforeAdd,
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tint: NSColor = .secondaryLabelColor

    /// `add` only for a folder; neither for To-dos. Without +, ••• moves to the row's end, so a file's name runs on
    /// further.
    func setButtons(more: ((NSView) -> Void)?, add: (() -> Void)?) {
        self.more = more
        self.add = add
        // Deactivate before activating, so the two never pull ••• at once.
        moreBeforeAdd.isActive = false
        moreInAddsPlace.isActive = false
        (add == nil ? moreInAddsPlace : moreBeforeAdd).isActive = true
        updateButtons()
    }

    private var shownCount = false

    private func updateButtons() {
        // Not over a name being typed.
        let shows = isHovered && more != nil && label.currentEditor() == nil
        moreButton.isHidden = !shows
        addButton.isHidden = !shows || add == nil
        labelBeforeButtons.isActive = shows
        // The bell, cloud or count give way to the buttons.
        accessory.isHidden = shows
        count.isHidden = shows || !shownCount
        moreButton.setAccessibilityLabel("More for \(label.stringValue)")
        addButton.setAccessibilityLabel("New Note in \(label.stringValue)")
    }

    @objc private func moreClicked(_ sender: NSButton) {
        more?(sender)
    }

    @objc private func addClicked() {
        add?()
    }

    override func layout() {
        HoverButtons.place(addEnd, in: self)
        super.layout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        press = nil
    }

    /// What a row that isn't selected does when VoiceOver presses it: Search's.
    private var press: (() -> Void)?

    override func accessibilityRole() -> NSAccessibility.Role? {
        press == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return super.accessibilityPerformPress() }
        press()
        return true
    }

    /// The count's colour: To-dos' count, or Search's shortcut, a step quieter.
    private var countColor: NSColor = .secondaryLabelColor

    /// Search: the magnifying glass, and ⌘K where a folder has its count. `press` opens it.
    func configureSearch(press: @escaping () -> Void) {
        label.stringValue = "Search"
        label.textColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .large)
        icon.alphaValue = 1
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        tint = .controlAccentColor
        accessory.image = nil
        isOverdue = false
        self.press = press
        count.font = .systemFont(ofSize: 12)
        countColor = .tertiaryLabelColor
        count.stringValue = "⌘K"
        countEnd.constant = Self.searchShortcutInset
        shownCount = true
        count.isHidden = false
        updateTint()
        toolTip = "Search notes, files and pictures (⌘K)"
        setAccessibilityLabel("Search")
        updateButtons()
    }

    /// Open Folder at the end of the sidebar: a grey plus in a circle and its name, as Search has its magnifying glass.
    /// (In the sidebar's vibrancy the secondary colour comes out much lighter on a name than on a count or a symbol,
    /// near the sections' titles.) `press` asks for a folder.
    func configureOpenFolder(press: @escaping () -> Void) {
        label.stringValue = "Open Folder"
        label.textColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .large)
        icon.alphaValue = 1
        icon.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        tint = .secondaryLabelColor
        accessory.image = nil
        isOverdue = false
        self.press = press
        count.stringValue = ""
        shownCount = false
        count.isHidden = true
        updateTint()
        toolTip = "Show another folder in the sidebar. You can also drop a folder here."
        setAccessibilityLabel("Open Folder")
        updateButtons()
    }

    /// `look` is a folder's symbol or emoji and colour, if you chose any (Customize Folder); `items` how many files and
    /// folders it holds, once it has been read.
    func configure(name: String, kind: FileKind, inCloud: Bool, url: URL, icon look: FolderIcon? = nil, symbol: String? = nil, nested: Bool, dimmed: Bool = false,
                   reminder: Reminder? = nil, items: Int? = nil) {
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countColor = .secondaryLabelColor
        countEnd.constant = Self.countInset
        count.stringValue = items.map { "\($0)" } ?? ""
        shownCount = items != nil
        count.isHidden = items == nil
        press = nil
        label.stringValue = name
        label.textColor = dimmed ? .tertiaryLabelColor : inCloud ? .secondaryLabelColor : .labelColor
        // As in Notes: large icons on a section's own rows, smaller ones inside a folder.
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: nested ? .medium : .large)
        icon.alphaValue = dimmed ? 0.5 : 1
        if let emoji = look?.emoji {
            icon.image = Self.picture(of: emoji, nested: nested)
        } else {
            icon.image = NSImage(systemSymbolName: look.flatMap { $0.symbol == nil ? nil : $0.shownSymbol } ?? symbol ?? kind.symbol, accessibilityDescription: nil)
        }
        tint = look?.color?.platformColor ?? kind.tint
        updateTint()
        // A reminder's bell, red once its time has passed, goes before the cloud of a note still in iCloud.
        if let reminder {
            accessory.image = NSImage(systemSymbolName: reminder.date == nil ? "location.fill" : "bell.fill", accessibilityDescription: "Reminder")
            isOverdue = reminder.isOverdue
        } else {
            accessory.image = inCloud ? NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "In iCloud, not downloaded") : nil
            isOverdue = false
        }
        toolTip = reminder.map { url.path + "\nReminder: " + $0.text } ?? url.path
        setAccessibilityLabel(reminder.map { "\(name), reminder \($0.text)" } ?? name)
        updateButtons()
    }

    private var isOverdue = false

    private static var emojiPictures: [String: NSImage] = [:]

    /// An emoji as a picture about as large as the symbols on the other rows: just its square, so it sits in their
    /// middle rather than on the line's baseline.
    static func picture(of emoji: String, nested: Bool) -> NSImage {
        let key = emoji + (nested ? " nested" : "")
        if let picture = emojiPictures[key] { return picture }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: nested ? 12 : 13.5)]))
        let square = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let picture = NSImage(size: square.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.textPosition = CGPoint(x: -square.minX, y: -square.minY)
            CTLineDraw(line, context)
            return true
        }
        emojiPictures[key] = picture
        return picture
    }

    // On the accent-coloured selection of a focused sidebar, icons turn white like the text.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private func updateTint() {
        let emphasized = backgroundStyle == .emphasized
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : tint
        count.textColor = emphasized ? .alternateSelectedControlTextColor : countColor
        for button in [moreButton, addButton] { button.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
        accessory.contentTintColor = emphasized ? .alternateSelectedControlTextColor : isOverdue ? .systemRed : .tertiaryLabelColor
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    /// Drawn in red in a glass menu, as Move to Trash.
    var isDestructive = false

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The sidebar in SwiftUI.
struct SidebarOutline: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> SidebarController { SidebarController(workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

#endif
