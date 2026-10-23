#if os(macOS)
import AppKit
import SwiftUI

/// A row in the sidebar that isn't a file in a tree: a section title, a favourite, To-dos at the top.
final class SidebarEntry: NSObject {
    enum Kind {
        case header(String, location: UUID?)
        case favorite(URL)
        case todos
    }

    let kind: Kind
    /// What a section shows: favourites, recent notes or a location's files.
    var children: [AnyObject] = []
    init(_ kind: Kind, children: [AnyObject] = []) {
        self.kind = kind
        self.children = children
    }

    var isHeader: Bool {
        if case .header = kind { return true }
        return false
    }

    var isTodos: Bool {
        if case .todos = kind { return true }
        return false
    }

    /// Names a section across reloads, to remember which ones you closed.
    var sectionKey: String? {
        guard case .header(let title, let location) = kind else { return nil }
        return location?.uuidString ?? title
    }

    var url: URL? {
        switch kind {
        case .favorite(let url): url
        case .header, .todos: nil
        }
    }
}

/// The sidebar: To-dos, favourites and a tree for every location, each a section you can close. A source list
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
        outline.indentationPerLevel = 10
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
        workspace.sidebar = self
        NotificationCenter.default.addObserver(self, selector: #selector(optionsChanged), name: .notebookSidebarOptionsChanged, object: nil)
        rebuildTop()
        outline.reloadData()
        expandSections()
        restoreExpansion([])
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

    /// The To-dos row, first of all.
    private let todosEntry = SidebarEntry(.todos)

    private func rebuildTop() {
        visible = [:]
        var items: [AnyObject] = [todosEntry]
        let favorites = workspace.favoriteURLs
        if !favorites.isEmpty {
            items.append(SidebarEntry(.header("Favorites", location: nil), children: favorites.map { SidebarEntry(.favorite($0)) }))
        }
        for location in workspace.locations {
            let files = workspace.root(for: location).map { visibleChildren(of: $0) } ?? []
            items.append(SidebarEntry(.header(location.name, location: location.id), children: files))
        }
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
    /// nothing else in the sidebar moves.
    func reload(_ nodes: [FileNode]) {
        guard renaming == nil else { heldNodes += nodes; return }
        let expanded = expandedPaths()
        var topChanged = false
        var shown = false
        for node in nodes {
            let wasEmpty = visible[ObjectIdentifier(node)]?.isEmpty ?? true
            visible[ObjectIdentifier(node)] = nil
            if node.parent == nil {
                guard let section = section(forRoot: node), section.children.isEmpty, wasEmpty else { topChanged = true; continue }
                section.children = visibleChildren(of: node)
                guard !section.children.isEmpty else { continue }
                if outline.isItemExpanded(section) {
                    outline.insertItems(at: IndexSet(integersIn: 0..<section.children.count), inParent: section, withAnimation: .effectFade)
                } else if !collapsedSections.contains(section.sectionKey ?? "") {
                    isExpandingSections = true
                    outline.expandItem(section)
                    isExpandingSections = false
                }
                shown = true
            } else if outline.row(forItem: node) >= 0 {
                let count = visibleChildren(of: node).count
                if outline.isItemExpanded(node), wasEmpty, count > 0 {
                    outline.insertItems(at: IndexSet(integersIn: 0..<count), inParent: node, withAnimation: .effectFade)
                    shown = true
                } else {
                    outline.reloadItem(node, reloadChildren: true)
                    shown = shown || outline.isItemExpanded(node)
                }
            }
        }
        if topChanged {
            rebuildTop()
            outline.reloadData()
            expandSections()
        }
        // A folder read ahead of time, still closed, changes nothing on screen.
        guard topChanged || shown || !wantedExpansion.isEmpty || !movedExpansion.isEmpty else { return }
        restoreExpansion(expanded)
        selectCurrent()
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

    /// The folder you selected, or else the open file, or To-dos.
    private func selectCurrent() {
        if workspace.showsTodos { return selectTodos() }
        guard let current = workspace.selectedFolder ?? workspace.currentURL, let node = workspace.node(for: current, reading: false) else { return }
        selectRow(for: node)
    }

    func selectTodos() {
        let row = outline.row(forItem: todosEntry)
        guard row >= 0, outline.selectedRow != row else { return }
        isSelectingProgrammatically = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        isSelectingProgrammatically = false
    }

    /// The count next to To-dos changed.
    func refreshTodosRow() {
        let row = outline.row(forItem: todosEntry)
        guard row >= 0, renaming == nil else { return }
        outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: [0])
    }

    private func selectRow(for node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        isSelectingProgrammatically = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        isSelectingProgrammatically = false
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
        !((item as? SidebarEntry)?.isHeader ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let entry = item as? SidebarEntry, case .header(let title, let id) = entry.kind {
            let cell = outlineView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) as? SidebarHeaderCell ?? SidebarHeaderCell()
            cell.label.stringValue = title
            let location = workspace.locations.first { $0.id == id }
            cell.showAddButton(for: title, add: location.map { location in { [weak self] in self?.workspace.newFolder(in: location.url) } })
            if let location, workspace.hasHiddenFolders(in: location) {
                let shows = workspace.showsHiddenFolders(in: location)
                cell.showHiddenButton(shows: shows) { [weak self] in self?.workspace.showHiddenFolders(!shows, in: location) }
            } else {
                cell.showHiddenButton(shows: nil)
            }
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: SidebarFileCell.identifier, owner: nil) as? SidebarFileCell ?? SidebarFileCell()
        cell.label.delegate = self
        if (item as? SidebarEntry)?.isTodos == true {
            cell.configureTodos(count: workspace.dueTodoCount)
            return cell
        }
        let nested = outlineView.level(forItem: item) > 1
        if let node = item as? FileNode {
            // Folders on screen are read ahead, so opening one shows its files straight away.
            workspace.prefetch(node)
            // Hidden folders show dimmed while their location shows them, as hidden files in the Finder.
            let dimmed = NotebookSettings.shared.dimsOtherFiles && !node.isFolder && node.kind != .note || node.isFolder && workspace.isHidden(node.url)
            cell.configure(name: workspace.newName(for: node.url) ?? node.name, kind: node.kind, inCloud: node.isInCloud, url: node.url, nested: nested, dimmed: dimmed,
                           reminder: node.kind == .note ? workspace.reminder(for: node.url) : nil)
        } else if let entry = item as? SidebarEntry, let url = entry.url {
            let kind = FileKind(url: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            let name = workspace.newName(for: url) ?? (kind == .note ? url.deletingPathExtension().lastPathComponent : kind == .folder ? workspace.folderName(url) : url.lastPathComponent)
            cell.configure(name: name, kind: kind, inCloud: false, url: url, symbol: { if case .favorite = entry.kind, kind == .folder { return "star" } else { return nil } }(),
                           nested: nested, reminder: kind == .note ? workspace.reminder(for: url) : nil)
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        outline.placeChevron(of: notification.userInfo?["NSObject"])
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
        } else if let entry = item as? SidebarEntry, entry.isTodos {
            pendingOpen = nil
            workspace.showTodos()
        } else if let entry = item as? SidebarEntry, let url = entry.url {
            open(url)
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        openOnItsOwn(row: outline.clickedRow)
    }

    /// A double-click opens a file on its own, as in the Finder: a note in a window of its own, anything else in the
    /// app the Mac has for it. A folder already opens and closes with each click.
    func openOnItsOwn(row: Int) {
        guard let url = url(at: row) else { return }
        guard !((outline.item(atRow: row) as? FileNode)?.isFolder ?? FileWindows.isFolder(url)) else { return }
        workspace.openOnItsOwn(url)
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
        if (item as? SidebarEntry)?.isTodos == true { return }
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
            add(menu, "Add Location…", "plus.rectangle.on.folder") { [weak self] in self?.workspace.chooseLocation(iCloud: false) }
            add(menu, "Remove from Sidebar", "minus.circle") { [weak self] in self?.workspace.removeLocation(locationID) }
            return
        }
        guard let url = url(at: row) else {
            // The empty part of the sidebar.
            add(menu, "New Note", "square.and.pencil") { [weak self] in self?.workspace.newNote() }
            add(menu, "Add Location…", "plus.rectangle.on.folder") { [weak self] in self?.workspace.chooseLocation(iCloud: false) }
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
        if FileKind(url: url, isDirectory: isFolder) == .note {
            let anchor = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
            add(menu, "Remind Me…", "bell") { [weak self] in self?.workspace.askForReminder(url, from: anchor) }
        }
        if !isLinked {
            add(menu, "Rename", "pencil") { [weak self] in self?.beginRenaming(url) }
            menu.addItem(moveToItem(for: url))
            add(menu, "Duplicate", "plus.square.on.square") { [weak self] in self?.workspace.duplicate(url) }
        }
        let favorite = workspace.isFavorite(url)
        add(menu, favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") { [weak self] in self?.workspace.toggleFavorite(url) }
        if isFolder, workspace.canHide(url) {
            let isHidden = workspace.isHidden(url)
            add(menu, isHidden ? "Unhide Folder" : "Hide Folder", isHidden ? "eye" : "eye.slash") { [weak self] in self?.workspace.setHidden(url, !isHidden) }
        }
        menu.addItem(.separator())
        if !isFolder { add(menu, "Copy Link", "link") { [weak self] in self?.workspace.copyLink(url) } }
        add(menu, "Show in Finder", "folder") { [weak self] in self?.workspace.revealInFinder(url) }
        if !isLinked {
            menu.addItem(.separator())
            add(menu, "Move to Trash", "trash") { [weak self] in self?.workspace.trash(url) }
        }
    }

    /// Move To, with every folder indented under its location, as in Notes.
    private func moveToItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        item.submenu = MoveToSubmenu(workspace: workspace) { url }
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ symbol: String, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
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
        if (item as? SidebarEntry)?.isTodos == true { return [] }
        guard let folder = dropFolder(for: item) else { return [] }
        guard !urls.isEmpty, !urls.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) else { return [] }
        if let node = folderNode(for: item) { outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        let local = urls.allSatisfy { workspace.location(containing: $0) != nil }
        return local && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Only a drop that adds locations is on the sidebar as a whole.
        if item == nil { return workspace.addLocations(urls) }
        guard let folder = dropFolder(for: item) else { return false }
        workspace.drop(urls, into: folder, copying: NSEvent.modifierFlags.contains(.option))
        return true
    }

    /// Between two sections, above the first or in the empty space below the last. Below the last the outline
    /// proposes the end of whatever is open there, so that is told by where the pointer is.
    private func isBetweenSections(_ info: NSDraggingInfo, proposedItem item: Any?) -> Bool {
        item == nil || outline.row(at: outline.convert(info.draggingLocation, from: nil)) < 0
    }

    private func folderNode(for item: Any?) -> FileNode? {
        guard let node = item as? FileNode else { return nil }
        return node.isFolder ? node : node.parent
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

/// Keys the Finder has: Return renames, ⌘⌫ moves to the Trash, Space shows Quick Look.
final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarController?

    // A folder opens or closes on the press itself, so quick clicks each count; dragging still works after it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0, let node = item(atRow: row) as? FileNode, node.isFolder,
           event.modifierFlags.intersection([.command, .shift]).isEmpty,
           !frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: -4).contains(point) {
            controller?.toggle(node)
        }
        super.mouseDown(with: event)
    }

    // A folder's chevron centred on its icon, which is in the middle of the row; AppKit puts it 1–1.5 pt lower. The
    // chevron is a pixel right of the middle of its picture, so turned down for an open folder it's a pixel lower; a
    // subfolder's smaller icon is a pixel higher. Section headers keep AppKit's Show/Hide.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
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
        guard let controller, let url = controller.selectedURL else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []):
            controller.beginRenaming(url)
        case (51, .command):
            controller.workspace.trash(url)
        case (49, []):
            if FileKind(url: url, isDirectory: false) == .note { super.keyDown(with: event) } else { controller.workspace.quickLook(url) }
        default:
            super.keyDown(with: event)
        }
    }

}

final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")
    let label = NSTextField(labelWithString: "")
    /// Makes a folder at the top of the location: there while the pointer is on the header, next to the section's own
    /// Show/Hide, as the Add button on Smart Mailboxes in Mail and on Albums in Photos. A folder with a plus rather than
    /// a plain plus, which on "iCloud Drive" could as well mean a new note.
    let addButton = NSButton()
    /// Shows a location's hidden folders: there while the pointer is on the header, and in the accent colour while
    /// they show, like a filter that is on.
    let hiddenButton = NSButton()
    private var addFolder: (() -> Void)?
    private var toggleHidden: (() -> Void)?
    private var showsHidden: Bool?
    var isHovered = false {
        didSet { updateButtons() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = label
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        for (button, symbol, action) in [(addButton, "folder.badge.plus", #selector(addButtonClicked)), (hiddenButton, "eye", #selector(hiddenButtonClicked))] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
        }
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Folder"
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: hiddenButton.leadingAnchor, constant: -4),
            // Left of the row's own Show/Hide chevron, which comes up on hover at the end of the row. The eye keeps its
            // place while the folder button is away.
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            hiddenButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
        ])
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `add` is nil for a section that isn't a location (Favorites).
    func showAddButton(for title: String, add: (() -> Void)?) {
        addFolder = add
        addButton.setAccessibilityLabel("New Folder in \(title)")
        updateHover()
    }

    /// `shows` is nil for a section without hidden folders.
    func showHiddenButton(shows: Bool?, toggle: (() -> Void)? = nil) {
        showsHidden = shows
        toggleHidden = toggle
        let title = shows == true ? "Hide Hidden Folders" : "Show Hidden Folders"
        hiddenButton.toolTip = title
        hiddenButton.setAccessibilityLabel(title)
        updateHover()
    }

    // The sidebar makes new headers when it reloads, under a pointer that hasn't moved.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHover()
    }

    private func updateHover() {
        guard let window else { return updateButtons() }
        isHovered = window.isKeyWindow && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateButtons() {
        addButton.isHidden = addFolder == nil || !isHovered
        hiddenButton.isHidden = showsHidden == nil || showsHidden == false && !isHovered
        hiddenButton.contentTintColor = showsHidden == true ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func addButtonClicked() {
        addFolder?()
    }

    @objc private func hiddenButtonClicked() {
        toggleHidden?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

final class SidebarFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let accessory = NSImageView()
    /// How many to-dos are due, next to To-dos, as Mail counts unread mail.
    let count = NSTextField(labelWithString: "")

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
        // Icon and name where Notes has them. The icon keeps its own size, centred on its column.
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -4),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tint: NSColor = .secondaryLabelColor

    /// To-dos: the checklist, and how many are due today or overdue.
    func configureTodos(count due: Int) {
        label.stringValue = "To-dos"
        label.textColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .large)
        icon.alphaValue = 1
        icon.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        tint = .controlAccentColor
        accessory.image = nil
        isOverdue = false
        count.stringValue = due > 0 ? "\(due)" : ""
        count.isHidden = due == 0
        updateTint()
        toolTip = nil
        setAccessibilityLabel(due > 0 ? "To-dos, \(due) due" : "To-dos")
    }

    func configure(name: String, kind: FileKind, inCloud: Bool, url: URL, symbol: String? = nil, nested: Bool, dimmed: Bool = false, reminder: Reminder? = nil) {
        count.isHidden = true
        label.stringValue = name
        label.textColor = dimmed ? .tertiaryLabelColor : inCloud ? .secondaryLabelColor : .labelColor
        // As in Notes: large icons on a section's own rows, smaller ones inside a folder.
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: nested ? .medium : .large)
        icon.alphaValue = dimmed ? 0.5 : 1
        icon.image = NSImage(systemSymbolName: symbol ?? kind.symbol, accessibilityDescription: nil)
        tint = kind == .folder ? .controlAccentColor : kind == .note || kind == .other ? .secondaryLabelColor : kind.tint
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
    }

    private var isOverdue = false

    // On the accent-coloured selection of a focused sidebar, icons turn white like the text.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private func updateTint() {
        let emphasized = backgroundStyle == .emphasized
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : tint
        count.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        accessory.contentTintColor = emphasized ? .alternateSelectedControlTextColor : isOverdue ? .systemRed : .tertiaryLabelColor
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

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

/// At the bottom of the sidebar, where Notes has New Folder and Reminders Add List: another folder for the sidebar,
/// picked or dropped on it.
struct AddLocationButton: View {
    let workspace: Workspace
    @State private var isTargeted = false

    var body: some View {
        Button { workspace.chooseLocation(iCloud: false) } label: {
            Label("Add Location", systemImage: "plus.circle")
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(isTargeted ? 0.18 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show another folder in the sidebar. You can also drop a folder here.")
        .dropDestination(for: URL.self) { urls, _ in
            workspace.addLocations(urls)
        } isTargeted: { isTargeted = $0 }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
#endif
