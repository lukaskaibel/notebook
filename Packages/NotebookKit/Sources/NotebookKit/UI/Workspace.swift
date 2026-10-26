#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// The app's state: the locations, the file that is open, where you have been, and everything you can do with files.
@MainActor
@Observable
public final class Workspace: NSObject {
    public static let shared = Workspace()

    public private(set) var locations: [Location] = []
    private(set) var roots: [UUID: FileNode] = [:]
    /// The file shown on the right.
    public private(set) var currentURL: URL?
    /// The To-dos list is shown on the right, in place of a file.
    public private(set) var showsTodos = false
    public private(set) var note: NoteDocument?
    @ObservationIgnored public let editor = EditorController()
    let index = SearchIndex()

    private(set) var history: [URL] = []
    private(set) var historyIndex = -1
    #if os(macOS)
    /// Back and Forward by swiping.
    @ObservationIgnored let pages = PageSwiper()
    #endif
    /// Where you were in each note, to come back to.
    @ObservationIgnored private var places: [URL: EditorController.Place] = [:]
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []
    /// The folder chosen in Settings for new notes made outside a folder, by its path. Without one they go to the Inbox.
    private(set) var chosenDefaultFolder: String?
    /// The folders hidden from the sidebar: kept in iCloud, or only for this run with locations given on the command line.
    private(set) var hidden = HiddenFolders(defaults: nil, cloud: nil)
    /// The reminders of notes: kept in iCloud too, or only for this run with locations given on the command line.
    private(set) var reminders = Reminders(defaults: nil, cloud: nil)
    /// Every open to-do in the notes, read from what search knows.
    let todos = TodoList()
    /// The notes in Spotlight, fed from what search knows; nil when Spotlight doesn't get them (`startSpotlight`).
    @ObservationIgnored var spotlight: SpotlightIndex?
    /// Words to search for in ⌘K as it opens: Spotlight's Search in App.
    var paletteStart: (query: String, id: UUID)?
    /// Counts the reminders whose time came, so what shows them turns red then, without anything else changing.
    var remindersDue = 0
    @ObservationIgnored var dueTimer: Timer?
    /// The to-dos' notifications, scheduled a moment after the to-dos changed.
    @ObservationIgnored var todoScheduling: DispatchWorkItem?
    /// The last change to a to-do's file, which the next waits for, and what to-dos' lines became (`current(_:)`).
    @ObservationIgnored var lastTodoWrite: Task<Void, Never>?
    /// The to-do being edited in To-dos, whose words are written with the notes when the app goes away.
    @ObservationIgnored weak var todoEditing: TodoEditing?
    @ObservationIgnored var todoRewrites: [String: TodoReference] = [:]
    /// To-dos that repeat, ticked in To-dos or from a notification, by the line they were ticked to (`takeBackTick`).
    @ObservationIgnored var todoTicks: [String: TodoTick] = [:]
    #if DEBUG
    /// What `remindOfNext` was asked for, for tests: the next one's line, and whether as it will be.
    @ObservationIgnored var remindedOfNext: [(source: String, asItWillBe: Bool)] = []
    #endif
    #if DEBUG
    /// The sample notes' reminders, shown but never scheduled: a run on the sample notes leaves no notification behind.
    @ObservationIgnored var unscheduledReminders = Set<UUID>()
    #endif

    #if os(macOS)
    /// The search field in the toolbar.
    @ObservationIgnored lazy var search = SearchController(workspace: self)
    #else
    /// Search on iPhone and iPad: one field is out at a time.
    @ObservationIgnored lazy var searchSession = SearchSession(workspace: self)
    #endif
    /// Reads the text in pictures, scans and drawings for search.
    @ObservationIgnored lazy var recognizer = TextRecognizer(index: index)
    /// ⌘K, over the window.
    var palette: PaletteMode?
    /// What ⌘K finds.
    @ObservationIgnored lazy var paletteSearch = SearchSession(workspace: self)
    /// A PDF opened from search, with the words to show in it.
    private(set) var pdfFind: (url: URL, find: PDFFind)?
    /// Where to take a note opened from search once its text is there.
    @ObservationIgnored private var pendingPlace: (url: URL, place: NotePlace)?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isSidebarVisible: Bool {
        get { columnVisibility != .detailOnly }
        set { columnVisibility = newValue ? .all : .detailOnly }
    }
    /// The outline of the open note, on the right. On the iPad it starts hidden, leaving the note the room.
    var isOutlineVisible = UserDefaults.standard.object(forKey: "showsOutline") as? Bool ?? Workspace.showsOutlineAtFirst {
        didSet { UserDefaults.standard.set(isOutlineVisible, forKey: "showsOutline") }
    }
    /// The outline as the window shows it: To-dos has none, so the inspector makes way for it and comes back with the
    /// next note.
    var showsOutline: Bool {
        get { isOutlineVisible && !showsTodos }
        set { if !showsTodos { isOutlineVisible = newValue } }
    }
    #if os(macOS)
    private static let showsOutlineAtFirst = true
    #else
    private static let showsOutlineAtFirst = false
    #endif

    /// The open note's headings and length, and where in it you are.
    private(set) var outline: [OutlineHeading] = []
    private(set) var stats = NoteStats()
    private(set) var currentHeading: Int?
    /// True once the note's title has scrolled up under the toolbar, which then shows it.
    private(set) var isTitleScrolledAway = false
    /// The note is in drawing mode: the pencil in the toolbar is on and the drawing tools are out.
    private(set) var isDrawing = false
    /// While drawing: whether Undo and Redo have strokes to take back or bring again.
    private(set) var canUndoDrawing = false
    private(set) var canRedoDrawing = false
    /// The folder selected in the sidebar, where ⌘N puts a note when no note is open.
    var selectedFolder: URL?
    /// Locations given on the command line for this run only (tests, the demo library).
    @ObservationIgnored private(set) var temporaryLocations = false
    @ObservationIgnored private(set) var isStarted = false
    /// Brings the main window up (set by the window, which SwiftUI opens).
    @ObservationIgnored var showWindow: (() -> Void)?

    #if os(macOS)
    @ObservationIgnored weak var sidebar: SidebarController?
    /// Remind Me… while it is open, so another one takes its place.
    @ObservationIgnored weak var reminderPopover: NSPopover?
    /// Customize Folder… while it is open, the same.
    @ObservationIgnored weak var folderIconPopover: NSPopover?
    #else
    /// Counts changes to the folders that have been read, so the lists showing them read them again.
    private(set) var treeVersion = 0
    /// A folder to show, opened from search or a link: the iPhone goes into it, the iPad's sidebar opens down to it.
    private(set) var folderRequest: (url: URL, id: UUID)?
    /// A file or folder to show in the sidebar, and to select there.
    private(set) var revealRequest: (url: URL, select: Bool, id: UUID)?
    /// A new folder to name, or a file to rename, asked for in an alert.
    var renaming: URL?
    /// The file shown in Quick Look over everything.
    var quickLookURL: URL?
    /// Something that couldn't be done, for an alert.
    var problem: Problem?
    /// Counts ⌘F, which puts the caret in the search field.
    var searchRequest = 0
    #if os(iOS)
    /// Counts the times ⌘K asked for Settings and for Add Location, which the screens show.
    var settingsRequest = 0
    var locationRequest = 0
    #endif
    /// A file to delete for good, once you said so, where there is no Recently Deleted to put it in.
    var deleting: URL?
    /// A note to set a reminder for, in a sheet.
    var reminderRequest: ReminderRequest?
    /// A to-do to set a reminder for, in a sheet.
    var todoReminderRequest: TodoReference?
    /// A to-do whose date or place to change, in a sheet, as from its pill in a note.
    var todoPickRequest: TodoPickRequest?
    /// A folder to customize, in a sheet.
    var folderIconRequest: FolderIconRequest?
    /// A file or folder to move, in the sheet that asks where to.
    var moving: MovingFile?
    /// The open note's earlier versions, in the Version History sheet.
    var versionBrowser: VersionBrowser?
    /// What each note looked like when you went on from it, shown while the screen of the note you go on to slides
    /// over it, and while you swipe back to it. There is only one editor, and it is on the screen in front.
    @ObservationIgnored var pageSnapshots: [URL: UIView] = [:]
    /// True while the keyboard is up for the note or its title.
    private(set) var isEditing = false
    #endif
    /// The last file or folder renamed or moved, so screens showing it follow it to its new place.
    private(set) var relocation: (from: URL, to: URL, id: UUID)?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Reads folders off the main thread.
    @ObservationIgnored let reader = FolderReader()
    /// Counts the lookups of the locations (`survey`), and what waits until the newest is done.
    @ObservationIgnored private var surveys = 0
    @ObservationIgnored private var surveysDone = 0
    @ObservationIgnored private var afterSurvey: [() -> Void] = []
    /// The file to show in the sidebar once the folders down to it have been read.
    @ObservationIgnored private var revealing: URL?
    @ObservationIgnored private var pendingFolders = Set<String>()
    @ObservationIgnored private var refreshScheduled = false
    /// `.assets` files the open note used, so the ones it drops can go to the Trash when you leave it.
    @ObservationIgnored private var assetsInUse = Set<String>()
    /// Every folder Move To offers, in order (`prepareMoveFolders`).
    @ObservationIgnored private var moveFolders: MoveFolders?
    @ObservationIgnored private var preparingMoveFolders: MoveFolders.Key?
    /// Counts the times Move To's folders were sorted again in the background, for the menus that show them.
    private var moveFoldersVersion = 0
    /// The last change to files asked for, which the next one waits for (`changeFiles`), and how many are under way.
    @ObservationIgnored private var lastChange: Task<Void, Never>?
    @ObservationIgnored private var changesUnderWay = 0
    /// Files renamed or moved while changes were under way, for those asked for meanwhile to find them.
    @ObservationIgnored private var relocations: [(from: URL, to: URL)] = []
    /// Files renamed or moved a moment ago, which the index may not have read again yet: links are worked out with
    /// them where they went (`linkSnapshot`).
    @ObservationIgnored var recentMoves: [(move: LinkUpdate.Move, date: Date)] = []
    /// The text Notebook gave notes a moment ago when links in them followed a file, by their paths, for the index to
    /// catch up with the same way.
    @ObservationIgnored var recentLinkTexts: [String: (text: String, date: Date)] = [:]
    /// The last rewriting of links after a rename or move, which the next one waits for (`followLinks`).
    @ObservationIgnored var lastLinkChange: Task<Void, Never>?
    /// The names files get while they are renamed, by path: shown until the rename is done, so a row never shows the
    /// old name again in between.
    private(set) var newNames: [String: String] = [:]
    /// The changes to files Undo and Redo would take next, in order (`Workspace+Undo`).
    @ObservationIgnored let fileUndoLog = FileUndoLog()
    /// Where those changes are kept without a window to keep them (tests).
    @ObservationIgnored lazy var ownUndoManager = UndoManager()
    /// The new note that is open, made a moment ago: left empty, it goes away, and so does its New Note in Undo.
    @ObservationIgnored weak var newNoteChange: FileChange?
    #if os(iOS)
    /// What Notebook knew about a file it couldn't put in the Trash, before it closed it: for deleting it for good.
    @ObservationIgnored var rememberedForDeleting: FileChange.Remembered?
    #endif

    public override init() {
        super.init()
        editor.delegate = self
        index.onBuilt = { [weak self] in
            self?.refreshLinks()
            // Notes moved in the Finder can be found by their names now.
            self?.scheduleReminders()
            self?.indexChanged()
            self?.spotlight?.setNeedsUpdate()
        }
        index.onFoldersChanged = { [weak self] in self?.prepareMoveFolders() }
        index.onChanged = { [weak self] in
            self?.indexChanged()
            self?.spotlight?.setNeedsUpdate()
        }
        todos.onChange = { [weak self] in self?.todosChanged() }
        index.onRefreshed = { [weak self] in self?.refreshLinks() }
        index.onIndexed = { [weak self] entries in self?.recognizer.consider(entries) }
        #if os(macOS)
        pages.workspace = self
        #else
        editor.undoStack.files = fileUndoLog
        #endif
    }

    /// Search knows other notes now: links to them show as links, in this window and in notes open on their own.
    private func refreshLinks() {
        editor.refreshLinks()
        #if os(macOS)
        FileWindows.shared.refreshLinks()
        #endif
    }

    // MARK: - Starting

    /// Reads the locations, once: when the window first appears, or before that when a folder is opened from the Dock.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        #if os(macOS)
        MoveToSubmenu.fillSwiftUIMenus(for: self)
        #else
        Task.detached(priority: .utility) { FileOperations.emptyDeleted() }
        #endif
        #if DEBUG
        // The welcome screen, for screenshots, without touching the locations you added.
        if UserDefaults.standard.bool(forKey: "NotebookWelcome") {
            temporaryLocations = true
            return
        }
        #endif
        favorites = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
        recents = UserDefaults.standard.stringArray(forKey: "recents") ?? []
        chosenDefaultFolder = UserDefaults.standard.string(forKey: "defaultFolder")
        if let path = UserDefaults.standard.string(forKey: "NotebookLibrary") {
            // A folder given on the command line (tests, screenshots): used for this run, not remembered.
            temporaryLocations = true
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            // Its notes' earlier versions stay with it on this device, apart from those of your own notes.
            if let store = SearchIndex.storeURL(library: url.path, name: "History", in: .cachesDirectory) {
                NoteHistory.shared.keepOnDevice(in: store.appendingPathComponent("History.noindex", isDirectory: true))
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "NotebookDemo"), DemoLibrary.create(at: url) {
                // Versions of earlier sample notes at the same place go with them.
                NoteHistory.shared.forget(url)
                DemoLibrary.keepVersions(at: url)
            }
            #endif
            locations = [Location(id: Location.id(for: url.path), name: UserDefaults.standard.string(forKey: "NotebookLibraryName") ?? url.lastPathComponent, path: url.path, bookmark: nil)]
            favorites = []
            recents = []
            chosenDefaultFolder = nil
        } else {
            locations = LocationStore.load()
            hidden = HiddenFolders()
            reminders = Reminders()
            // Versions a year old go, also those of notes not written in since; not while the app is starting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NoteHistory.shared.tidyUp() }
        }
        #if DEBUG
        if temporaryLocations, UserDefaults.standard.bool(forKey: "NotebookDemo"), let library = locations.first {
            for path in DemoLibrary.hiddenFolders { hidden.set(hiddenKey(for: library.url.appendingPathComponent(path)), hidden: true) }
            for (path, date) in DemoLibrary.reminders() {
                unscheduledReminders.insert(reminders.set(note: hiddenKey(for: library.url.appendingPathComponent(path)), date: date).id)
            }
        }
        #endif
        // The index kept from the last run is read while the locations are looked up, for search to have it all at once.
        index.storeURL = SearchIndex.storeURL(library: temporaryLocations ? locations.first?.url.path : nil)
        index.loadKept(for: locations)
        startSpotlight()
        hidden.onChange = { [weak self] in self?.hiddenFoldersChanged() }
        reminders.onChange = { [weak self] in self?.remindersChanged() }
        readTextInPictures(NotebookSettings.shared.readsTextInPictures)
        watchForDueReminders()
        let last = temporaryLocations ? nil : UserDefaults.standard.string(forKey: "lastOpened")
        locationsChanged(resolving: true, reading: last.map { [$0] } ?? [])
        if let last, FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        }
    }

    /// Shows the locations at once, by name and with the files already read, and looks at them again off the main
    /// thread (`survey`).
    private func locationsChanged(resolving: Bool = false, reading files: [String] = [], new: UUID? = nil) {
        var fresh: [UUID: FileNode] = [:]
        for location in locations {
            fresh[location.id] = roots[location.id] ?? FileNode(url: location.url, kind: .folder, parent: nil)
        }
        roots = fresh
        // First, so the sidebar doesn't read a new location's top itself, without its linked folders.
        survey(resolving: resolving, reading: files, new: new)
        sidebarReloadAll()
    }

    /// Looks at every location off the main thread: where a saved one is now (`resolving`), its bookmark if it is
    /// `new`, iCloud Drive's linked folders, and the files at its top, with the folders that were open and those down
    /// to `files` for a location not read yet. Then shows it all at once, starts watching and builds the index. Reading
    /// folders meanwhile waits for it, so nothing is read twice or without its linked folders.
    private func survey(resolving: Bool, reading files: [String], new: UUID?) {
        surveys += 1
        let count = surveys
        var folders = UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? []
        for file in files {
            var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                folders.append(folder.path)
                folder = folder.deletingLastPathComponent()
            }
        }
        let jobs = locations.map { location in
            LocationSurvey.Job(id: location.id, url: location.url, bookmark: resolving ? location.bookmark : nil, isNew: location.id == new,
                               linked: location.linked, isRead: roots[location.id]?.hasLoadedChildren ?? false, folders: folders)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let surveys = jobs.map(LocationSurvey.run)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.surveyed(surveys, count: count) }
            }
        }
    }

    private func surveyed(_ surveys: [LocationSurvey], count: Int) {
        var changed: [FileNode] = []
        var reloadsAll = false
        var saves = false
        for survey in surveys {
            guard let index = locations.firstIndex(where: { $0.id == survey.id }) else { continue }
            if survey.url.path != locations[index].path {
                // Moved since last time: the bookmark found it.
                locations[index].path = survey.url.path
                roots[survey.id] = FileNode(url: locations[index].url, kind: .folder, parent: nil)
                reloadsAll = true
                saves = true
            }
            if let bookmark = survey.bookmark {
                locations[index].bookmark = bookmark
                saves = true
            }
            if let name = survey.name, name != locations[index].name {
                locations[index].name = name
                saves = true
                reloadsAll = true
            }
            locations[index].linked = survey.linked
            guard let root = roots[survey.id] else { continue }
            root.linked = survey.linked
            if let top = survey.top, root.apply(top) { changed.append(root) }
            for folder in survey.folders {
                if let node = node(for: URL(fileURLWithPath: folder.path), reading: false), node.isFolder, node.apply(folder.listing) {
                    changed.append(node)
                }
            }
        }
        if saves, !temporaryLocations { LocationStore.save(locations) }
        // An older lookup's files are as good as any, but only the newest knows every location.
        surveysDone = max(surveysDone, count)
        if reloadsAll { sidebarReloadAll() } else if !changed.isEmpty { sidebarReload(changed) }
        guard count == self.surveys else { return }
        watcher = FileWatcher(paths: locations.flatMap { $0.folders.map(\.url.path) }) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        updateHiddenPaths()
        index.rebuild(locations)
        scheduleReminders()
        let waiting = afterSurvey
        afterSurvey = []
        waiting.forEach { $0() }
    }

    /// True while the locations are being looked up (`survey`).
    var isSurveying: Bool { surveysDone < surveys }

    /// Does something once the locations have been looked up, with iCloud Drive's linked folders: at once if they have.
    func whenSurveyed(_ action: @escaping () -> Void) {
        if isSurveying { afterSurvey.append(action) } else { action() }
    }

    /// True once they have been, and their tops read.
    var hasReadLocations: Bool { surveysDone > 0 && !isSurveying }

    /// Adds a folder to the sidebar at once, by its name; its files show a moment later, read off the main thread
    /// like everything inside it, so even all of iCloud Drive never makes you wait.
    public func addLocation(_ url: URL) {
        let url = url.standardizedFileURL
        guard !locations.contains(where: { $0.path == url.path }) else { return }
        let location = LocationStore.make(for: url)
        locations.append(location)
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged(new: location.id)
        #if os(macOS)
        // At the end of a long sidebar it would be out of sight: once its files show, it scrolls into view.
        reveal(url, select: false)
        #endif
    }

    /// Of folders dragged onto the sidebar, the ones it could add: folders it doesn't show yet. Nil when the drag
    /// has anything else in it, such as a file or a folder already in a location.
    func newLocations(in urls: [URL]) -> [URL]? {
        let urls = urls.map(\.standardizedFileURL)
        let fresh = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !isPackage(url) && location(containing: url) == nil
        }
        return !fresh.isEmpty && fresh.count == urls.count ? fresh : nil
    }

    /// Folders dropped on the sidebar, each a location of its own, as folders dropped in the Finder's sidebar are.
    @discardableResult
    func addLocations(_ urls: [URL]) -> Bool {
        guard let fresh = newLocations(in: urls) else { return false }
        fresh.forEach(addLocation)
        return true
    }

    public func removeLocation(_ id: UUID) {
        locations.removeAll { $0.id == id }
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged()
    }

    #if os(macOS)
    /// Asks for iCloud Drive (or another folder) and adds it.
    public func chooseLocation(iCloud: Bool) {
        let start = iCloud ? URL(fileURLWithPath: Location.iCloudDrivePath, isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser
        guard let url = LocationStore.choose(startingIn: start, message: iCloud ? "Click Open to show iCloud Drive in Notebook." : nil) else { return }
        addLocation(url)
    }

    /// Asks where to put the sample notes, since the sandbox writes only where you chose, and makes them there.
    func chooseSampleNotesFolder() {
        guard let url = LocationStore.choose(startingIn: FileManager.default.homeDirectoryForCurrentUser,
                                             message: "Choose where to put the sample notes. Notebook makes a folder Sample Notes there.",
                                             prompt: "Make Sample Notes") else { return }
        addSampleNotes(in: url)
    }
    #endif

    /// Try Sample Notes: made-up notes, pictures, a drawing and PDFs in a new folder Sample Notes in `folder`, which
    /// becomes a location of its own. They are written off the main thread and show once they are there.
    func addSampleNotes(in folder: URL) {
        let url = folder.appendingPathComponent("Sample Notes", isDirectory: true)
        Task {
            let made = await Task.detached(priority: .userInitiated) { DemoLibrary.create(at: url) }.value
            if made { DemoLibrary.keepVersions(at: url) }
            addLocation(url)
        }
    }

    /// A folder from File › Open or the Dock icon: shown where it is in the sidebar, or added as a location of its own
    /// (iCloud Drive, say) when no location has it yet.
    public func openFolder(_ url: URL) {
        start()
        let url = url.standardizedFileURL
        if location(containing: url) == nil { addLocation(url) }
        showWindow?()
        isSidebarVisible = true
        open(url)
    }

    func root(for location: Location) -> FileNode? { roots[location.id] }

    func location(containing url: URL) -> Location? {
        locations.first { $0.contains(url) }
    }

    /// iCloud Drive's Desktop and the like: shown in a location, but not to be renamed, moved or thrown away from it.
    func isLinkedFolder(_ url: URL) -> Bool {
        locations.contains { $0.isLinkedFolder(url) }
    }

    /// A folder's name as the sidebar shows it: a location's, a linked folder's, or the folder's own.
    func folderName(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let location = locations.first(where: { $0.url.path == path }) { return location.name }
        if let linked = locations.lazy.flatMap(\.linked).first(where: { $0.url.path == path }) { return linked.name }
        return url.lastPathComponent
    }

    /// The nodes from a location's top down to a file, as far as they go: reading folders on the way, or with
    /// `reading` false only through folders already read. `complete` says whether they reach the file.
    func nodes(to url: URL, reading: Bool = true) -> (location: Location, nodes: [FileNode], complete: Bool)? {
        let path = url.standardizedFileURL.path
        guard let location = location(containing: url), let root = roots[location.id], let folder = location.folder(containing: path) else { return nil }
        var nodes = [root]
        func children(of node: FileNode) -> [FileNode] {
            reading || node.hasLoadedChildren ? node.loadedChildren() : []
        }
        if let linked = folder.linked {
            guard let top = children(of: root).first(where: { $0.isLinked && $0.url.path == linked.url.path }) else { return (location, nodes, false) }
            nodes.append(top)
        }
        for component in path.dropFirst(folder.url.path.count).split(separator: "/") {
            guard let next = children(of: nodes[nodes.count - 1]).first(where: { !$0.isLinked && $0.url.lastPathComponent == component }) else {
                return (location, nodes, false)
            }
            nodes.append(next)
        }
        return (location, nodes, true)
    }

    /// The node for a file: reading folders on the way to it, or with `reading` false only if they have been read.
    func node(for url: URL, reading: Bool = true) -> FileNode? {
        guard let found = nodes(to: url, reading: reading), found.complete else { return nil }
        return found.nodes.last
    }

    /// The folders from a location's top down to the one a file is in, worked out from its address alone.
    func folders(to url: URL) -> (location: Location, folders: [URL])? {
        let path = url.standardizedFileURL.path
        guard let location = location(containing: url), let folder = location.folder(containing: path) else { return nil }
        guard path != location.url.path else { return (location, []) }
        var folders = [location.url]
        if folder.linked != nil, path != folder.url.path { folders.append(folder.url) }
        var current = folder.url
        for component in path.dropFirst(folder.url.path.count).split(separator: "/").dropLast() {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            folders.append(current)
        }
        return (location, folders)
    }

    // MARK: - Reading folders

    /// Reads folders off the main thread and shows what they hold: those not read yet, or with `again` (files changed
    /// in them) all of them. A folder already waiting to be read ahead of time is read next instead.
    func read(_ nodes: [FileNode], again: Bool = false, ahead: Bool = false) {
        guard !isSurveying else {
            afterSurvey.append { [weak self] in self?.read(nodes, again: again, ahead: ahead) }
            return
        }
        var folders: [FileNode] = []
        for node in nodes where node.isFolder && (again || !node.hasLoadedChildren) {
            if !again, reader.isReading(node.url) {
                if !ahead { reader.hurry(node.url) }
            } else {
                folders.append(node)
            }
        }
        guard !folders.isEmpty else { return }
        read(folders.map { FolderReader.Request(url: $0.url, linked: $0.linked) }, ahead: ahead, then: nil)
    }

    /// Reads a folder's contents ahead of time, after everything else, so they are there when you open it.
    func prefetch(_ node: FileNode) {
        guard node.isFolder, !node.hasLoadedChildren else { return }
        read([node], ahead: true)
    }

    func prefetch(_ folder: URL) {
        if let node = node(for: folder, reading: false) { prefetch(node) }
    }

    /// Reads the folders down to a file that haven't been read yet (with the file itself, if it is a folder and
    /// `including`), then does `done`: at once when there is nothing to read. Without `done`, folders already being
    /// read are left to that.
    func readFolders(to url: URL, including: Bool = false, then done: (() -> Void)? = nil) {
        guard !isSurveying else {
            afterSurvey.append { [weak self] in self?.readFolders(to: url, including: including, then: done) }
            return
        }
        guard let found = folders(to: url) else { done?(); return }
        var folders = found.folders
        if including { folders.append(url.standardizedFileURL) }
        let missing = folders.filter { node(for: $0, reading: false)?.hasLoadedChildren != true && (done != nil || !reader.isReading($0)) }
        guard !missing.isEmpty else { done?(); return }
        let root = roots[found.location.id]
        read(missing.map { FolderReader.Request(url: $0, linked: $0 == root?.url ? root?.linked ?? [] : []) }, then: done)
    }

    private func read(_ requests: [FolderReader.Request], ahead: Bool = false, then done: (() -> Void)?) {
        reader.read(requests, ahead: ahead) { [weak self] results in
            guard let self else { return }
            var changed: [FileNode] = []
            for result in results {
                guard let listing = result.listing, let node = node(for: URL(fileURLWithPath: result.path), reading: false), node.isFolder else { continue }
                if node.apply(listing) { changed.append(node) }
            }
            if !changed.isEmpty { sidebarReload(changed) }
            done?()
        }
    }

    /// Whether a folder's contents have been read, for lists that say "Empty" only when it is.
    func hasRead(_ folder: URL) -> Bool {
        node(for: folder, reading: false)?.hasLoadedChildren ?? false
    }

    // MARK: - Files changing

    private func filesChanged(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            pendingFolders.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            pendingFolders.insert(url.standardizedFileURL.path)
        }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.applyFileChanges() }
        }
    }

    /// Reads the folders where files changed again, off the main thread: iCloud changes thousands of files while it
    /// syncs, and the sidebar and search follow without the window waiting.
    private func applyFileChanges() {
        refreshScheduled = false
        let folders = pendingFolders
        pendingFolders = []
        var changed: [FileNode] = []
        var indexFolders: [URL] = []
        for path in folders {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == ".assets" { continue }
            indexFolders.append(url)
            if let node = existingNode(for: url), node.isFolder, node.hasLoadedChildren { changed.append(node) }
        }
        read(changed, again: true)
        index.refresh(folders: indexFolders, locations: locations)
        remindersMayHaveChanged(in: indexFolders)
        editor.refreshLinks()
        if let current = currentURL, !FileManager.default.fileExists(atPath: current.path), note == nil {
            currentURL = nil
        }
    }

    /// A node that is already in the tree, without reading anything.
    private func existingNode(for url: URL) -> FileNode? {
        guard let found = nodes(to: url, reading: false), found.complete else { return nil }
        return found.nodes.last
    }

    // MARK: - Opening

    /// Opens what search found: a file, or a note or PDF at the words, heading or picture found in it.
    func open(_ result: SearchResult) {
        switch result {
        case .file(let url): open(url)
        case .text(let url, let words, let page): open(url, at: .words(words), page: page)
        case .heading(let url, let title): open(url, at: .heading(title))
        case .picture(let url, let asset):
            if let asset { open(url, at: .asset(asset)) } else { open(url) }
        case .newNote(let title): newNote(title: title)
        }
    }

    /// Opens a note scrolled to a place in it, with that selected; a PDF at the words on their page.
    func open(_ url: URL, at place: NotePlace, page: Int? = nil) {
        let target = url.standardizedFileURL
        if FileKind(url: target, isDirectory: false) == .pdf {
            if case .words(let words) = place { pdfFind = (target, PDFFind(words: words, page: page)) }
            open(target)
            return
        }
        if target == currentURL, let note, note.isLoaded {
            editor.reveal(place)
            return
        }
        pendingPlace = (target, place)
        open(target)
    }

    /// The words to show in the PDF that is open, if it was opened from search.
    func find(in url: URL) -> PDFFind? {
        guard let pdfFind, pdfFind.url == url.standardizedFileURL else { return nil }
        return pdfFind.find
    }

    /// Reading the text in pictures, scans and drawings, or not, from Settings.
    func readTextInPictures(_ reads: Bool) {
        // Never in tests: they make pictures of their own and look at search before it could have read them.
        guard reads, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            recognizer.stop()
            return
        }
        recognizer.start()
        if !index.isBuilding { recognizer.consider(index.byPathSnapshot) }
    }

    public func open(_ url: URL, recordHistory: Bool = true, focusTitle: Bool = false) {
        let target = url.standardizedFileURL
        // Words found by search show in the PDF opened for them, not when you come back to it later.
        if let pdfFind, !FileNode.samePath(pdfFind.url, target) { self.pdfFind = nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) || target.lastPathComponent.hasSuffix(".icloud") else { return }
        if isDirectory.boolValue, !isPackage(target) {
            selectedFolder = target
            reveal(target, select: true)
            #if os(iOS)
            folderRequest = (target, UUID())
            #endif
            return
        }
        if target == currentURL {
            if focusTitle { editor.focusTitle() }
            return
        }
        showsTodos = false
        #if os(macOS)
        pages.willOpen(target)
        #else
        keepSnapshot()
        #endif
        keepPlace()
        leaveCurrentNote()
        if (try? target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        }
        currentURL = target
        selectedFolder = nil
        if FileKind(url: target, isDirectory: false) == .note {
            // A note still in iCloud shows its title at once and its text when it has come down; the window doesn't
            // wait for it.
            let document = NoteDocument(url: target)
            // Opened with its title to type: a new note, which goes away again if it is left empty.
            document.isNew = focusTitle
            let place = recordHistory ? nil : places[target]
            document.onExternalChange = { [weak self] text in self?.editor.reload(text: text) }
            // Only while it is open: put in the Trash, a closed note can still hear that it went there.
            document.onMove = { [weak self, weak document] url in
                guard let self, self.note === document else { return }
                self.noteMoved(to: url)
            }
            document.onDelete = { [weak self, weak document] in
                guard let self, self.note === document else { return }
                self.currentNoteDeleted()
            }
            document.onSave = { [weak self, weak document] in
                guard let self, let document else { return }
                self.noteSaved(document.url)
            }
            document.onLoad = { [weak self, weak document] _ in
                guard let self, let document, self.note === document else { return }
                self.show(document, focusTitle: focusTitle, place: place)
            }
            note = document
            show(document, focusTitle: focusTitle, place: place)
        } else {
            note = nil
            outline = []
            stats = NoteStats()
            currentHeading = nil
            isTitleScrolledAway = false
        }
        if recordHistory {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(target)
            historyIndex = history.count - 1
        }
        recents.removeAll { $0 == target.path }
        recents.insert(target.path, at: 0)
        recents = Array(recents.prefix(8))
        if !temporaryLocations {
            UserDefaults.standard.set(recents, forKey: "recents")
            UserDefaults.standard.set(target.path, forKey: "lastOpened")
        }
        // Only the selection moves in the sidebar: nothing above it changes, so nothing jumps.
        reveal(target, select: true)
    }

    /// Puts the open note in the editor: its text, or only its title while the text is on its way. Back and Forward
    /// come back to `place` once the text is there.
    private func show(_ document: NoteDocument, focusTitle: Bool, place: EditorController.Place?) {
        assetsInUse = FileOperations.assetNames(in: document.text)
        editor.load(text: document.isLoaded ? document.text : nil, folder: document.url.deletingLastPathComponent(),
                    title: focusTitle ? "" : document.url.deletingPathExtension().lastPathComponent, meta: meta(for: document), focusTitle: focusTitle)
        updateReminderLine()
        if document.isLoaded, let place { restore(place) }
        if document.isLoaded, let pending = pendingPlace {
            pendingPlace = nil
            if FileNode.samePath(pending.url, document.url) { editor.reveal(pending.place) }
        }
        // The editor only reports changes, and a Quick Look file in between cleared the outline here.
        editorOutlineDidChange(editor)
        editorPositionDidChange(editor)
    }

    /// Remembers where you are in the note you leave, to come back there. A note whose text hasn't come yet keeps the
    /// place it had.
    private func keepPlace() {
        guard let note, note.isLoaded, let current = currentURL else { return }
        places[current] = editor.place
    }

    #if os(iOS)
    /// Leaves the file that is open, for the folder it is in: the iPhone's Back.
    public func closeFile() {
        guard currentURL != nil else { return }
        keepSnapshot()
        keepPlace()
        leaveCurrentNote()
        currentURL = nil
        outline = []
        stats = NoteStats()
        currentHeading = nil
        isTitleScrolledAway = false
    }

    /// Opens a note again, where you left it: going back to it on the iPhone.
    public func reopen(_ url: URL) {
        open(url, recordHistory: false)
    }

    /// The folder Notebook keeps on this device, shown in the Files app under On My iPhone › Notebook.
    nonisolated public static var onDeviceFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// A file or folder handed over by another app (the Files app's Open With, a share): a folder becomes a location,
    /// a file opens, from its folder if Notebook shows that.
    public func openFromOutside(_ url: URL) {
        start()
        guard url.isFileURL else { return }
        _ = url.startAccessingSecurityScopedResource()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if location(containing: url) == nil { addLocation(url) }
        }
        open(url)
    }

    /// Reads the folders on screen again: when Notebook comes back to the front and when you pull a list down. Pulling
    /// down (`thoroughly`) reads every folder for search again too.
    public func refresh(thoroughly: Bool = false) {
        guard isStarted, !locations.isEmpty else { return }
        var loaded: [FileNode] = []
        func visit(_ node: FileNode) {
            guard let children = node.children else { return }
            loaded.append(node)
            children.filter(\.isFolder).forEach(visit)
        }
        roots.values.forEach(visit)
        let folders = loaded.map(\.url)
        read(loaded, again: true)
        if thoroughly { index.rebuild(locations) } else { index.refresh(folders: folders, locations: locations) }
        editor.refreshLinks()
    }

    /// Keeps a picture of the note on screen, for its screen to show once the editor has moved on.
    private func keepSnapshot() {
        guard note != nil, let current = currentURL, editor.isInWindow,
              let snapshot = editor.view.snapshotView(afterScreenUpdates: false) else { return }
        pageSnapshots[current] = snapshot
        if pageSnapshots.count > 12, let old = pageSnapshots.keys.first(where: { $0 != current }) { pageSnapshots[old] = nil }
    }
    #endif

    /// Back and Forward come back to where you were, once the note is in the window again.
    private func restore(_ place: EditorController.Place) {
        if editor.isInWindow {
            editor.restore(place)
        } else {
            DispatchQueue.main.async { [weak self] in self?.editor.restore(place) }
        }
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// Saves the note being left; a new note left empty goes away, and pictures it no longer uses go to the Trash.
    private func leaveCurrentNote() {
        guard let note else { return }
        editor.endDrawing()
        // Back or ⌘N while typing a new name: the name counts, as it would once the title is left.
        if editor.isEditingTitle { editor.commitTitle() }
        note.update(text: editor.text)
        note.close()
        let folder = note.url.deletingLastPathComponent()
        let dropped = assetsInUse.subtracting(FileOperations.assetNames(in: note.text))
        // It reads every note in the folder, which takes a while in a large one.
        if !dropped.isEmpty { Task.detached(priority: .utility) { FileOperations.cleanUpAssets(in: folder, candidates: dropped) } }
        if isLeftEmpty(note) {
            let url = note.url
            // Nothing was made that Undo could take back.
            if let change = newNoteChange, change.after.map({ FileNode.samePath($0, url) }) == true { dropFromUndo(change) }
            changeFiles { [self] follow in
                let url = follow(url)
                let thrownAway = await Task.detached(priority: .userInitiated) { () -> Bool in
                    #if os(iOS)
                    // Where there is no Recently Deleted, an empty note made a moment ago goes for good: nothing is lost.
                    return FileOperations.trash(url) || FileOperations.delete(url).done
                    #else
                    return FileOperations.trash(url)
                    #endif
                }.value
                if thrownAway {
                    forgetRecent(url)
                    showChanges(in: [url.deletingLastPathComponent()], removing: [url])
                }
            }
        }
        self.note = nil
    }

    /// A note made with New Note and left as it came, without a name or text, unless Settings keeps those.
    private func isLeftEmpty(_ note: NoteDocument) -> Bool {
        NotebookSettings.shared.deletesEmptyNewNotes && note.isNew && note.isEmpty
            && note.url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled")
    }

    #if os(macOS)
    /// Quitting leaves the note too, and the next launch wouldn't know it was new: one left empty goes to the Trash
    /// before the app does, which waits a moment for it at most. A name being typed counts, though it can't be given.
    private func trashAsQuitting(_ note: NoteDocument) {
        let named = editor.isEditingTitle && !editor.titleText.trimmingCharacters(in: .whitespaces).isEmpty
        guard isLeftEmpty(note), !named else { return }
        note.close()
        let url = note.url
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = FileOperations.trash(url)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }
    #endif

    func meta(for document: NoteDocument) -> String {
        guard let date = document.modified else { return "" }
        return "Edited " + Self.relative(date)
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)) + " at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    public func goBack() {
        while canGoBack {
            historyIndex -= 1
            if goTo(history[historyIndex]) { return }
        }
    }

    public func goForward() {
        while canGoForward {
            historyIndex += 1
            if goTo(history[historyIndex]) { return }
        }
    }

    /// Back or Forward to a place in the history, if it is still there.
    private func goTo(_ url: URL) -> Bool {
        if url == Self.todosURL {
            guard NotebookSettings.shared.showsTodos else { return false }
            showTodos(recordHistory: false)
            return true
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        open(url, recordHistory: false)
        return true
    }

    /// The To-dos list's place in the history, among the files you opened.
    static let todosURL = URL(string: "notebook:to-dos")!

    /// Shows the To-dos list in place of the file that is open, which is saved and left as when you open another.
    public func showTodos(recordHistory: Bool = true) {
        guard !showsTodos, NotebookSettings.shared.showsTodos else { return }
        #if os(macOS)
        if currentURL != nil { pages.willOpen(Self.todosURL) }
        #else
        keepSnapshot()
        #endif
        keepPlace()
        leaveCurrentNote()
        currentURL = nil
        note = nil
        outline = []
        stats = NoteStats()
        currentHeading = nil
        isTitleScrolledAway = false
        selectedFolder = nil
        showsTodos = true
        if recordHistory {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(Self.todosURL)
            historyIndex = history.count - 1
        }
        sidebarSelectTodos()
    }

    /// To-dos turned off or on in Settings. Off, the list goes back to what was open before it, and the notifications
    /// of to-dos go; on, they come back.
    func todosSettingChanged() {
        if !NotebookSettings.shared.showsTodos, showsTodos {
            goBack()
            if showsTodos { showsTodos = false }
        }
        scheduleTodoNotifications()
        #if os(macOS)
        editor.updateTodoBellForPointer()
        #endif
    }

    #if os(iOS)
    /// Leaves the To-dos list: the iPhone's Back.
    public func closeTodos() {
        showsTodos = false
    }
    #endif

    /// The open note was renamed or moved somewhere else, in the Finder or on another device: its reminder follows.
    private func noteMoved(to url: URL) {
        if let old = currentURL {
            relocation = (old, url.standardizedFileURL, UUID())
            reminderMoved(from: old, to: url.standardizedFileURL)
        }
        currentURL = url.standardizedFileURL
        editor.setTitle(url.deletingPathExtension().lastPathComponent)
        reveal(url, select: true)
    }

    private func currentNoteDeleted() {
        note = nil
        currentURL = nil
    }

    // MARK: - Favourites and recents

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url.standardizedFileURL.path) }

    func toggleFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
        if !temporaryLocations { UserDefaults.standard.set(favorites, forKey: "favorites") }
        #if os(macOS)
        sidebar?.reloadSections()
        #endif
    }

    var favoriteURLs: [URL] {
        favorites.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The files opened last, newest first, without the one that is open: for File › Open Recent and search.
    var recentURLs: [URL] {
        recents.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) && $0 != currentURL }
    }

    func clearRecents() {
        recents = []
        if !temporaryLocations { UserDefaults.standard.set(recents, forKey: "recents") }
    }

    /// A new note thrown away again leaves the files opened last, which the iPhone shows without looking again.
    private func forgetRecent(_ url: URL) {
        recents.removeAll { FileNode.samePath(URL(fileURLWithPath: $0), url) }
        if !temporaryLocations { UserDefaults.standard.set(recents, forKey: "recents") }
    }

    private func replacePath(_ old: URL, with new: URL) {
        func fix(_ path: String) -> String { Self.relocated(path, from: old.path, to: new.path) }
        func fix(_ url: URL) -> URL { Self.relocated(url, from: old, to: new) }
        hiddenFolderMoved(from: old, to: new)
        reminderMoved(from: old, to: new)
        defaultFolderMoved(from: old, to: new)
        favorites = favorites.map(fix)
        recents = recents.map(fix)
        history = history.map(fix)
        relocation = (old.standardizedFileURL, new.standardizedFileURL, UUID())
        if let current = currentURL { currentURL = fix(current) }
        // Else ⌘N would make the folder again under its old name, for the note.
        if let folder = selectedFolder { selectedFolder = fix(folder) }
        #if os(iOS)
        pageSnapshots = Dictionary(pageSnapshots.map { (fix($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        #endif
        if !temporaryLocations {
            UserDefaults.standard.set(favorites, forKey: "favorites")
            UserDefaults.standard.set(recents, forKey: "recents")
        }
    }

    // MARK: - Making and changing files

    /// Where a new note goes: next to the open one, into the folder selected in the sidebar, or the default folder.
    var folderForNewNote: URL? {
        if let selectedFolder { return selectedFolder }
        if let currentURL { return currentURL.deletingLastPathComponent() }
        return defaultFolder
    }

    /// Where new notes made outside a folder go: the folder chosen in Settings while it is in a location, or the Inbox.
    var defaultFolder: URL? {
        if let chosen = chosenDefaultFolder.map({ URL(fileURLWithPath: $0, isDirectory: true) }), location(containing: chosen) != nil {
            return chosen
        }
        return inboxFolder
    }

    /// The Inbox at the top of the first location, made with the first note put in it.
    var inboxFolder: URL? {
        guard let location = locations.first else { return nil }
        return location.url.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Settings' default folder; the Inbox, or nil, goes back to having none chosen.
    func chooseDefaultFolder(_ folder: URL?) {
        let folder = folder?.standardizedFileURL
        chosenDefaultFolder = folder.flatMap { folder in inboxFolder.map { FileNode.samePath($0, folder) } == true ? nil : folder.path }
        if !temporaryLocations { UserDefaults.standard.set(chosenDefaultFolder, forKey: "defaultFolder") }
    }

    /// The default folder renamed or moved in Notebook, or the folder it is in, stays the default; thrown away, the
    /// Inbox is again.
    private func defaultFolderMoved(from old: URL, to new: URL?) {
        guard let chosen = chosenDefaultFolder, FileNode.isSameOrInside(URL(fileURLWithPath: chosen), old) else { return }
        chooseDefaultFolder(new.map { URL(fileURLWithPath: Self.relocated(chosen, from: old.path, to: $0.path), isDirectory: true) })
    }

    /// Where a folder is, as the sidebar leads to it: "iCloud Drive › Projects › Inbox".
    func place(of folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        guard let top = location(containing: folder)?.folder(containing: path) else { return folder.lastPathComponent }
        return ([top.place] + path.dropFirst(top.url.path.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }

    /// Does a change to files once the changes asked for before it are done, one after another in the order they were
    /// asked for. The writing itself goes off the main thread: in iCloud Drive a coordinated write can wait for iCloud,
    /// and the window never waits with it. `follow` gives where a file the change was asked for is now, when one before
    /// it renamed or moved it (or the folder it is in) meanwhile.
    @discardableResult
    func changeFiles<T: Sendable>(_ change: @escaping @MainActor (_ follow: (URL) -> URL) async -> T) -> Task<T, Never> {
        let previous = lastChange
        let mark = relocations.count
        changesUnderWay += 1
        let task = Task { @MainActor in
            await previous?.value
            let result = await change { url in
                self.relocations[mark...].reduce(url) { Self.relocated($0, from: $1.from, to: $1.to) }
            }
            self.changesUnderWay -= 1
            if self.changesUnderWay == 0 { self.relocations = [] }
            return result
        }
        lastChange = Task { _ = await task.value }
        return task
    }

    /// Where a file is once `from` went to `to`: there too if it is `from` or in it.
    nonisolated static func relocated(_ url: URL, from: URL, to: URL) -> URL {
        guard FileNode.isSameOrInside(url, from) else { return url }
        return URL(fileURLWithPath: relocated(url.path, from: from.path, to: to.path), isDirectory: url.hasDirectoryPath)
    }

    /// The same by path, in the form it was given: "/private/var/…" and "/var/…" are one folder, and the app has
    /// addresses of both kinds.
    nonisolated static func relocated(_ path: String, from: String, to: String) -> String {
        let plain = HiddenFolders.withoutPrivate(path)
        let old = HiddenFolders.withoutPrivate(from)
        guard plain == old || plain.hasPrefix(old + "/") else { return path }
        let target = HiddenFolders.withoutPrivate(to)
        return (path.hasPrefix("/private/") && !target.hasPrefix("/private/") ? "/private" + target : target) + plain.dropFirst(old.count)
    }

    /// Shows what was just done in folders before they have been read again: the files that went from them and those
    /// that came. Then reads them again in the background, for anything else that changed.
    func showChanges(in folders: [URL], removing: [URL] = [], adding: [FileNode.Listing] = [], carrying moved: FileNode? = nil) {
        let folders = folders.reduce(into: [URL]()) { list, folder in
            if !list.contains(where: { FileNode.samePath($0, folder) }) { list.append(folder) }
        }
        var changed: [FileNode] = []
        for folder in folders {
            guard let node = existingNode(for: folder) else { continue }
            let gone = removing.filter { FileNode.samePath($0.deletingLastPathComponent(), folder) }
            let came = adding.filter { FileNode.samePath($0.url.deletingLastPathComponent(), folder) }
            if node.update(removing: gone, adding: came), !changed.contains(node) { changed.append(node) }
        }
        if let moved, let listing = adding.first, let node = loadedNode(listing.url) { node.takeContents(of: moved) }
        if !changed.isEmpty { sidebarReload(changed) }
        readAgain(folders)
    }

    /// Reads folders again in the background, after something was done in them, then does `done`. Readings of them
    /// still under way began before that and could bring back what was there, so they are dropped. Search follows.
    func readAgain(_ folders: [URL], then done: (() -> Void)? = nil) {
        var requests: [FolderReader.Request] = []
        for folder in folders {
            guard let node = existingNode(for: folder), node.isFolder, node.hasLoadedChildren,
                  !requests.contains(where: { FileNode.samePath($0.url, node.url) }) else { continue }
            reader.dropReadings(of: node.url)
            requests.append(FolderReader.Request(url: node.url, linked: node.linked))
        }
        index.refresh(folders: folders, locations: locations)
        guard !requests.isEmpty else { done?(); return }
        read(requests, then: done)
    }

    /// Pulling a list down: its folder is read again, and the list waits until it has been.
    func readAgain(_ folder: URL) async {
        await withCheckedContinuation { continuation in readAgain([folder]) { continuation.resume() } }
    }

    /// A new note, opened with its title ready to type over, or with a title already chosen (search's New Note, a link
    /// to a note that isn't there yet). `text` is what it starts with, from Shortcuts. The task gives where it was made.
    @discardableResult
    public func newNote(in folder: URL? = nil, title: String? = nil, text: String = "") -> Task<URL?, Never> {
        let folder = folder ?? folderForNewNote
        // The default folder gone from the disk, thrown away in the Finder, say: the note goes to the Inbox instead.
        let inbox = folder.flatMap { folder in chosenDefaultFolder.map { FileNode.samePath(URL(fileURLWithPath: $0), folder) } == true ? inboxFolder : nil }
        let change = keepForUndo(FileChange(.make, "New Note"))
        return changeFiles { [self] follow in
            guard let chosen = folder.map(follow) else {
                dropFromUndo(change)
                return nil
            }
            let inbox = inbox.map(follow)
            let made = await Task.detached(priority: .userInitiated) { () -> (url: URL, folder: URL, listing: FileNode.Listing?, madeFolder: Bool)? in
                let folder = inbox.flatMap { FileManager.default.fileExists(atPath: chosen.path) ? nil : $0 } ?? chosen
                guard let made = FileOperations.createNote(in: folder, title: title ?? "Untitled", text: text) else { return nil }
                return (made.url, folder, FileNode.listing(of: made.url), made.madeFolder)
            }.value
            changeDone(change, to: made?.url)
            guard let made else {
                report("The note couldn’t be made.", "Notebook can’t write in “\(folderName(chosen))”.")
                return nil
            }
            // The Inbox, made for the first note in it, shows too.
            let folder = made.folder
            let parent = folder.deletingLastPathComponent()
            showChanges(in: made.madeFolder ? [parent, folder] : [folder],
                        adding: (made.listing.map { [$0] } ?? []) + (made.madeFolder ? [FileNode.Listing(url: folder, kind: .folder)] : []))
            open(made.url, focusTitle: title == nil)
            // After opening it: a new note left empty for this one goes, with its own New Note.
            if title == nil { newNoteChange = change }
            return made.url
        }
    }

    /// A new note in the default folder, asked for from outside the window: the New Note intent, from Shortcuts,
    /// Spotlight or the Action button. When that started the app, the note waits for the locations to be looked up:
    /// in the App Store build their bookmarks are what lets Notebook write in them. Nil when there is nowhere to make it.
    public func newNoteFromOutside(text: String = "") async -> URL? {
        start()
        await withCheckedContinuation { continuation in whenSurveyed { continuation.resume() } }
        showWindow?()
        #if os(macOS)
        NSApp.activate()
        #endif
        return await newNote(in: defaultFolder, text: text).value
    }

    /// A new folder, named "New Folder" to be renamed at once in the sidebar, as in the Finder, or with the name
    /// already chosen (iPhone and iPad ask for it first, as Notes does).
    public func newFolder(in parent: URL? = nil, named name: String? = nil) {
        #if os(macOS)
        // A name still being typed is taken first, as in the Finder: the selected folder may be the one renamed.
        sidebar?.endRenaming()
        #endif
        guard let parent = (parent ?? selectedFolder ?? currentURL?.deletingLastPathComponent() ?? locations.first?.url)?.standardizedFileURL else { return }
        let chosen = name.map(FileOperations.fileName(from:)) ?? ""
        let name = chosen.isEmpty ? "New Folder" : chosen
        let change = keepForUndo(FileChange(.make, "New Folder"))
        changeFiles { [self] follow in
            let parent = follow(parent)
            let made = await Task.detached(priority: .userInitiated, operation: { FileOperations.createFolder(in: parent, name: name) }).value
            changeDone(change, to: made)
            guard let url = made else {
                return report("The folder couldn’t be made.", "Notebook can’t write in “\(folderName(parent))”.")
            }
            // In the sidebar at once, however long reading its folder takes in iCloud.
            showChanges(in: [parent], adding: [FileNode.Listing(url: url, kind: .folder)])
            // Selected, on the Mac with its name ready to type over. Revealing it reads its folder if it hasn't been.
            #if os(macOS)
            selectedFolder = url
            #endif
            reveal(url, select: true) { [weak self] in
                #if os(macOS)
                self?.sidebar?.beginRenaming(url)
                #endif
            }
        }
    }

    /// The name a file is being renamed to, for its row.
    func newName(for url: URL) -> String? {
        newNames.isEmpty ? nil : newNames[HiddenFolders.withoutPrivate(url.path)]
    }

    /// Renames a file or folder. Links to it and to what is in it follow (`followLinks`), unless it is a new note
    /// getting its first name, which nothing links to yet. The task gives the new address, or nil when the name is taken.
    @discardableResult
    func rename(_ url: URL, to name: String, updatingLinks: Bool = true) -> Task<URL?, Never> {
        guard !isLinkedFolder(url) else { beep(); return Task { nil } }
        let key = HiddenFolders.withoutPrivate(url.path)
        let shown = existingNode(for: url).flatMap { node in
            FileOperations.destination(renaming: url, to: name, isDirectory: node.isFolder).map {
                node.kind == .note ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent
            }
        }
        if let shown, shown != existingNode(for: url)?.name {
            newNames[key] = shown
            sidebarShowName(of: url)
        }
        let change = keepForUndo(FileChange(.move, "Rename", from: url))
        change.updatesLinks = updatingLinks
        return changeFiles { [self] follow in
            let url = follow(url)
            // Its row has the new name by now, or says the old one again.
            defer {
                if newNames[key] == shown {
                    newNames[key] = nil
                    sidebarShowName(of: url)
                }
            }
            let renamed = await renameNow(url, to: name, updatingLinks: updatingLinks, change: change)
            changeDone(change, from: url, to: renamed)
            return renamed
        }
    }

    /// Renames a file or folder, in a change to files under way: to a name as typed, which keeps the file's extension,
    /// or (`fileName`) to a file name as it is, as Undo does. Nil when the name is taken, which an alert says. The links
    /// it rewrites are kept in `change`, and when `undoing` it, the links its rename rewrote are put back.
    func renameNow(_ url: URL, to name: String, fileName: Bool = false, updatingLinks: Bool, change: FileChange? = nil, undoing: Bool = false) async -> URL? {
        let isNote = FileKind(url: url, isDirectory: false) == .note
        let links = updatingLinks && !undoing ? linkSnapshot() : nil
        let document = noteMoving(with: url)
        document?.beginMove()
        let result = await Task.detached(priority: .userInitiated) { () -> (url: URL, listing: FileNode.Listing?)? in
            let renamed = fileName ? FileOperations.rename(url, toFileName: name, presenter: document) : FileOperations.rename(url, to: name, presenter: document)
            guard let renamed else { return nil }
            // Its earlier versions go along, before the note saves or keeps a copy under its new name.
            NoteHistory.shared.follow(from: url, to: renamed)
            return (renamed, FileNode.listing(of: renamed))
        }.value
        guard let renamed = result?.url else {
            document?.endMove(to: nil)
            let shown = fileName && isNote ? (name as NSString).deletingPathExtension : name
            report("The name “\(shown)” is already taken.", "Please choose a different name.")
            return nil
        }
        moved(url, to: renamed, listing: result?.listing, document: document)
        if undoing {
            takeBackLinks(change?.links, from: url, to: renamed)
        } else if let links {
            change?.links = followLinks(LinkUpdate.Move(from: url, to: renamed), from: links)
        }
        // A folder selected in the sidebar stays selected under its new name, as in the Finder.
        reveal(renamed, select: isCurrent(renamed) || selectedFolder.map { FileNode.samePath($0, renamed) } == true)
        return renamed
    }

    /// Moves a file or folder into another folder. A note takes the pictures it uses along; for one still in iCloud
    /// that waits until it has come down, and nothing else waits for it. Links to it, to what is in it, and in it
    /// follow (`followLinks`).
    @discardableResult
    func move(_ url: URL, into folder: URL) -> Task<URL?, Never> {
        guard !isLinkedFolder(url) else { beep(); return Task { nil } }
        let change = keepForUndo(FileChange(.move, "Move", from: url))
        return changeFiles { [self] follow in
            let url = follow(url)
            let moved = await moveNow(url, into: follow(folder), change: change)
            changeDone(change, from: url, to: moved)
            return moved
        }
    }

    /// Moves a file or folder into another folder, in a change to files under way: under its own name, or the one Undo
    /// gives it back (`fileName`), with a number when that is taken there. The links it rewrites are kept in `change`,
    /// and when `undoing` it, the links its move rewrote are put back.
    func moveNow(_ url: URL, into folder: URL, fileName: String? = nil, change: FileChange? = nil, undoing: Bool = false) async -> URL? {
        let source = url.deletingLastPathComponent()
        // Already there: nothing to do (rather than a copy of its name with a number).
        guard !FileNode.samePath(source, folder) else { return url }
        let isNote = FileKind(url: url, isDirectory: false) == .note
        let links = undoing ? nil : linkSnapshot()
        let document = noteMoving(with: url)
        document?.beginMove()
        let name = fileName ?? url.lastPathComponent
        let result = await Task.detached(priority: .userInitiated) { () -> (url: URL, listing: FileNode.Listing?, assets: (names: Set<String>, renamed: Bool)?)? in
            // Read before it moves only when that is quick: a note still in iCloud would have to come down first.
            let isHere = isNote && NoteDocument.wait(for: url) == nil
            let ext = (name as NSString).pathExtension
            let destination = FileOperations.uniqueURL(in: folder, name: (name as NSString).deletingPathExtension, extension: ext.isEmpty ? nil : ext)
            guard let moved = FileOperations.move(url, to: destination, presenter: document) else { return nil }
            NoteHistory.shared.follow(from: url, to: moved)
            // Its pictures come along before it shows there, when they can.
            let assets = isHere ? FileOperations.copyAssets(of: moved, from: source, renaming: !undoing) : nil
            return (moved, FileNode.listing(of: moved), assets)
        }.value
        guard let result else {
            document?.endMove(to: nil)
            beep()
            return nil
        }
        let moved = result.url
        if isNote {
            Task.detached(priority: .utility) {
                let assets = result.assets ?? FileOperations.copyAssets(of: moved, from: source, renaming: !undoing)
                // Open meanwhile, it shows the pictures that came after it.
                if result.assets == nil, !assets.names.isEmpty { await self.picturesArrived(for: moved) }
                FileOperations.cleanUpAssets(in: source, candidates: assets.names)
            }
        }
        self.moved(url, to: moved, listing: result.listing, document: document)
        // A picture whose name another had there came under a name of its own: the open note takes in what it says now.
        if result.assets?.renamed == true { document?.presentedItemDidChange() }
        if undoing {
            takeBackLinks(change?.links, from: url, to: moved)
        } else if let links {
            change?.links = followLinks(LinkUpdate.Move(from: url, to: moved), from: links)
        }
        reveal(moved, select: isCurrent(moved))
        return moved
    }

    private func picturesArrived(for note: URL) {
        if isCurrent(note) { editor.refreshLinks() }
    }

    private func isCurrent(_ url: URL) -> Bool {
        currentURL.map { FileNode.samePath($0, url) } ?? false
    }

    /// The open note, when it is the file or in the folder about to be renamed or moved.
    private func noteMoving(with url: URL) -> NoteDocument? {
        guard let note, FileNode.isSameOrInside(note.url, url) else { return nil }
        return note
    }

    /// A file Notebook renamed or moved, followed everywhere: by the note that was open in it, by what remembers files
    /// by their address, and in the sidebar, at once.
    private func moved(_ old: URL, to new: URL, listing: FileNode.Listing?, document: NoteDocument?) {
        document?.endMove(to: document.map { Self.relocated($0.url, from: old, to: new) })
        #if os(macOS)
        sidebar?.follow(from: old, to: new)
        #endif
        replacePath(old, with: new)
        relocations.append((old, new))
        recentMoves.append((LinkUpdate.Move(from: old, to: new), Date()))
        if !recentLinkTexts.isEmpty {
            recentLinkTexts = Dictionary(recentLinkTexts.map { (Self.relocated($0.key, from: old.path, to: new.path), $0.value) }) { a, _ in a }
        }
        // The open note in it, or it: its name, and the folder its pictures are in. Nothing else in the editor changes.
        if let note, document === note, let current = currentURL, FileNode.samePath(note.url, current) {
            editor.setTitle(note.url.deletingPathExtension().lastPathComponent)
            editor.folderMoved(to: note.url.deletingLastPathComponent())
            updateReminderLine()
        }
        let node = loadedNode(old)
        let kind = listing?.kind ?? node?.kind ?? .other
        showChanges(in: [old.deletingLastPathComponent(), new.deletingLastPathComponent()], removing: [old],
                    adding: [listing ?? FileNode.Listing(url: new, kind: kind)], carrying: node)
        // Search reads what is in a folder again only one folder at a time, as files change in it.
        if kind == .folder { index.refresh(folders: [new], deep: [new], locations: locations) }
    }

    /// A file's node, when its folder has been read: also for one that isn't there any more.
    private func loadedNode(_ url: URL) -> FileNode? {
        existingNode(for: url.deletingLastPathComponent())?.children?.first { FileNode.samePath($0.url, url) }
    }

    /// Files dropped on a folder: moved there from elsewhere in Notebook's locations, copied from anywhere else (or
    /// when `copying`, Option on the Mac).
    func drop(_ urls: [URL], into folder: URL, copying: Bool = false) {
        var moves: [URL] = []
        var copies: [URL] = []
        for url in urls {
            if location(containing: url) != nil, !copying {
                if !FileNode.samePath(url.deletingLastPathComponent(), folder) { moves.append(url) }
            } else {
                copies.append(url)
            }
        }
        let bring = { [self] in
            for url in moves { move(url, into: folder) }
            if !copies.isEmpty { copy(copies, into: folder) }
        }
        // Dropped together, they go back with one Undo.
        if moves.count + copies.count > 1 { undoTogether(bring) } else { bring() }
    }

    /// Files from outside the locations, copied into a folder.
    private func copy(_ copies: [URL], into folder: URL) {
        let changes = copies.map { _ in keepForUndo(FileChange(.make, "Copy")) }
        changeFiles { [self] follow in
            let folder = follow(folder)
            let sources = copies.map(follow)
            let made = await Task.detached(priority: .userInitiated) {
                sources.map { url -> (url: URL, listing: FileNode.Listing?)? in
                    let destination = FileOperations.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
                    return (destination, FileNode.listing(of: destination))
                }
            }.value
            for (change, copy) in zip(changes, made) { changeDone(change, to: copy?.url) }
            if made.contains(where: { $0 == nil }) { beep() }
            showChanges(in: [folder], adding: made.compactMap { $0?.listing })
        }
    }

    /// Where a file can be moved: every folder of every location, in order, with how deep it is.
    func moveTargets(for url: URL) -> [(location: Location, folders: [(url: URL, name: String, depth: Int)])] {
        let source = url.standardizedFileURL.path
        return currentMoveFolders().targets.map { target in
            (target.location, target.folders.compactMap { folder in
                folder.depth >= 0 && (folder.path == source || folder.path.hasPrefix(source + "/")) ? nil : (folder.url, folder.name, folder.depth)
            })
        }
    }

    /// The folders Settings offers as the default folder: Move To's, with the Inbox among the first location's folders
    /// before its first note has made it.
    var defaultFolderChoices: [(location: Location, folders: [(url: URL, name: String, depth: Int)])] {
        let inbox = inboxFolder
        return currentMoveFolders().targets.enumerated().map { number, target in
            var folders = target.folders.map { (url: $0.url, name: $0.name, depth: $0.depth) }
            if number == 0, let inbox, !folders.contains(where: { FileNode.samePath($0.url, inbox) }) {
                let place = folders.firstIndex { $0.depth == 0 && $0.name.localizedStandardCompare("Inbox") == .orderedDescending } ?? folders.endIndex
                folders.insert((inbox, "Inbox", 0), at: place)
            }
            return (target.location, folders)
        }
    }

    /// What the folders Move To lists now were sorted from: when it changes, so do they.
    var moveFoldersInUse: MoveFolders.Key { currentMoveFolders().key }

    private var moveFoldersKey: MoveFolders.Key {
        MoveFolders.Key(folders: index.folderVersion, locations: locations, hidden: index.hiddenPaths)
    }

    /// Move To's folders as they are now. After folders came or went they are as they were for the moment it takes to
    /// sort the new ones, as the index itself is behind the disk for a moment; a folder hidden or a location added
    /// shows at once.
    private func currentMoveFolders() -> MoveFolders {
        _ = moveFoldersVersion
        let key = moveFoldersKey
        if let moveFolders, moveFolders.key.locations == key.locations, moveFolders.key.hidden == key.hidden {
            if moveFolders.key != key { prepareMoveFolders() }
            return moveFolders
        }
        let made = MoveFolders(key, folders: index.allFolders())
        moveFolders = made
        preparingMoveFolders = nil
        return made
    }

    /// Sorts Move To's folders again in the background, after folders came or went: for a whole iCloud Drive that is
    /// thousands of them.
    private func prepareMoveFolders() {
        let key = moveFoldersKey
        guard moveFolders?.key != key, preparingMoveFolders != key else { return }
        preparingMoveFolders = key
        let folders = index.allFolders()
        Task.detached(priority: .utility) {
            let made = MoveFolders(key, folders: folders)
            await MainActor.run {
                guard self.preparingMoveFolders == key else { return }
                self.preparingMoveFolders = nil
                self.moveFolders = made
                self.moveFoldersVersion += 1
            }
        }
    }

    /// Moves a file or folder to the Trash. The task says whether it could (on iPhone and iPad a place may have no
    /// Recently Deleted).
    @discardableResult
    func trash(_ url: URL) -> Task<Bool, Never> {
        guard !isLinkedFolder(url) else { beep(); return Task { false } }
        let change = keepForUndo(FileChange(.trash, "Move to Trash", from: url))
        return changeFiles { [self] follow in
            let url = follow(url)
            change.remembered = remembered(url)
            let trashed = await trashNow(url)
            // Moved to the Trash with nowhere to say it went, it can't be put back.
            changeDone(change, from: url, to: trashed.place)
            if !trashed.done { beep() }
            #if os(iOS)
            // Deleted for good next, after asking (`moveToTrash`): Undo brings it back from there as it was now, open.
            if !trashed.done { rememberedForDeleting = change.remembered }
            #endif
            return trashed.done
        }
    }

    /// Moves a file or folder to the Trash, in a change to files under way: closed first when it is open, or the open
    /// note is in it. Says where in the Trash it went.
    func trashNow(_ url: URL) async -> (done: Bool, place: URL?) {
        let wasCurrent = currentURL.map { FileNode.isSameOrInside($0, url) } ?? false
        if wasCurrent {
            note?.close()
            note = nil
            currentURL = nil
        }
        let trashed = await Task.detached(priority: .userInitiated, operation: { FileOperations.moveToTrash(url) }).value
        guard trashed.done else { return trashed }
        thrownAway(url)
        #if os(macOS)
        if wasCurrent, currentURL == nil, let previous = history.last(where: { !FileNode.samePath($0, url) && FileManager.default.fileExists(atPath: $0.path) }) {
            open(previous, recordHistory: false)
        }
        #endif
        return trashed
    }

    #if os(iOS)
    /// Deletes for good, after you agreed to it: only where there is no Recently Deleted. Undo still brings it back
    /// while Notebook is open.
    func deleteImmediately(_ url: URL) {
        let change = keepForUndo(FileChange(.trash, "Delete", from: url))
        changeFiles { [self] follow in
            let url = follow(url)
            let known = rememberedForDeleting.flatMap { $0.path == url.path ? $0 : nil }
            rememberedForDeleting = nil
            change.remembered = known ?? remembered(url)
            let deleted = await deleteNow(url)
            changeDone(change, from: url, to: deleted.place)
            if !deleted.done { beep() }
        }
    }

    /// Deletes for good, in a change to files under way, and says where it waits for Undo, if anywhere.
    func deleteNow(_ url: URL) async -> (done: Bool, place: URL?) {
        if let current = currentURL, FileNode.isSameOrInside(current, url) { closeFile() }
        let deleted = await Task.detached(priority: .userInitiated, operation: { FileOperations.delete(url) }).value
        if deleted.done { thrownAway(url) }
        return deleted
    }
    #endif

    /// A file thrown away: forgotten everywhere, and gone from the sidebar at once.
    private func thrownAway(_ url: URL) {
        hiddenFolderMoved(from: url, to: nil)
        reminderMoved(from: url, to: nil)
        defaultFolderMoved(from: url, to: nil)
        favorites.removeAll { HiddenFolders.withoutPrivate($0) == HiddenFolders.withoutPrivate(url.path) }
        if !temporaryLocations { UserDefaults.standard.set(favorites, forKey: "favorites") }
        showChanges(in: [url.deletingLastPathComponent()], removing: [url])
    }

    @discardableResult
    func duplicate(_ url: URL) -> Task<URL?, Never> {
        guard !isLinkedFolder(url) else { beep(); return Task { nil } }
        let change = keepForUndo(FileChange(.make, "Duplicate"))
        return changeFiles { [self] follow in
            let url = follow(url)
            let result = await Task.detached(priority: .userInitiated) { () -> (url: URL, listing: FileNode.Listing?)? in
                guard let copy = FileOperations.duplicate(url) else { return nil }
                return (copy, FileNode.listing(of: copy))
            }.value
            changeDone(change, to: result?.url)
            guard let copy = result?.url else {
                beep()
                return nil
            }
            showChanges(in: [url.deletingLastPathComponent()], adding: result?.listing.map { [$0] } ?? [])
            reveal(copy, select: false)
            return copy
        }
    }

    func copyLink(_ url: URL) {
        let name = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        copyToPasteboard("[[\(name)]]")
    }

    #if os(macOS)
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a file apart from this window, as a double-click in the Finder does: a note in a window of its own, any
    /// other file in the app the Mac has for it (Preview, QuickTime Player).
    func openOnItsOwn(_ url: URL) {
        guard FileKind(url: url, isDirectory: false) != .note else { return FileWindows.shared.open(url) }
        // Without waiting for the app; when there is none, the system says so and offers to choose one.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The app a file opens in on its own, by name: "Preview".
    func appName(opening url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The note in the window you are working in: a file window's, or this window's.
    func activeEditor() -> (editor: EditorController, title: String, window: NSWindow?)? {
        if let key = NSApp.keyWindow, let controller = key.windowController as? FileWindowController {
            return (controller.editor, controller.url.deletingPathExtension().lastPathComponent, key)
        }
        guard note != nil else { return nil }
        return (editor, currentTitle, editor.textView.window)
    }

    func export(as format: NoteExporter.Format) {
        guard let active = activeEditor() else { NSSound.beep(); return }
        NoteExporter.export(active.editor, title: active.title, as: format, from: active.window)
    }

    func printNote() {
        guard let active = activeEditor() else { NSSound.beep(); return }
        NoteExporter.print(active.editor, title: active.title, from: active.window)
    }
    #endif

    /// The open file's name as you read it: notes without their extension.
    var currentTitle: String {
        if showsTodos { return "To-dos" }
        guard let currentURL else { return "Notebook" }
        if let name = newName(for: currentURL) { return name }
        return FileKind(url: currentURL, isDirectory: false) == .note ? currentURL.deletingPathExtension().lastPathComponent : currentURL.lastPathComponent
    }

    /// Saves everything; called when the app goes to the background or (`quitting`) quits, when drawings are written
    /// before it goes on.
    public func saveAll(quitting: Bool = false) {
        editor.saveDrawingsNow(waiting: quitting)
        todoEditing?.commit(now: quitting)
        #if os(macOS)
        FileWindows.shared.saveAll(quitting: quitting)
        #endif
        // Not as the app quits, which wouldn't wait for it: the next launch reads what changed.
        if !quitting { index.keepChanges() }
        defer {
            // Versions are written in the background; the app waits for them a moment at most as it quits.
            if quitting { NoteHistory.shared.waitUntilWritten(timeout: 1) }
        }
        guard let note else { return }
        note.update(text: editor.text)
        note.saveNow()
        // You stopped writing for now: what you wrote is kept as a version.
        note.keepCopyOfChanges()
        #if os(macOS)
        if quitting { trashAsQuitting(note) }
        #endif
    }

    func resolveConflict(_ resolution: NoteDocument.Resolution) {
        guard let note else { return }
        let text = note.resolve(resolution)
        editor.reload(text: text)
    }

    // MARK: - Quick Look

    func quickLook(_ url: URL) {
        #if os(macOS)
        QuickLookPanel.shared.show(url)
        #else
        quickLookURL = url
        #endif
    }

    // MARK: - What the window shows

    /// Something that couldn't be done: an alert, on the Mac over the window, or over a note's own window when that is
    /// the one in front, where it was asked for.
    func report(_ title: String, _ message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let front = NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) }
        let fileWindow = front?.windowController is FileWindowController ? front : nil
        if let window = fileWindow ?? editor.textView.window ?? NSApp.mainWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
        #else
        problem = Problem(title: title, message: message)
        #endif
    }

    /// Opens the folders down to a file in the sidebar, and selects it there: once they have been read, then `done`.
    func reveal(_ url: URL, select: Bool, then done: (() -> Void)? = nil) {
        revealing = url
        readFolders(to: url) { [weak self] in
            guard let self, self.revealing == url else { return }
            #if os(macOS)
            sidebar?.reveal(url, select: select)
            #else
            revealRequest = (url, select, UUID())
            #endif
            done?()
        }
    }

    func sidebarReloadAll() {
        #if os(macOS)
        sidebar?.reloadAll()
        #else
        treeVersion += 1
        #endif
    }

    /// A file's row while it is renamed: its new name, and its old one again if it couldn't be renamed. The lists on
    /// iPhone and iPad follow `newNames` by themselves.
    private func sidebarShowName(of url: URL) {
        #if os(macOS)
        sidebar?.showName(of: url)
        #endif
    }

    private func sidebarReload(_ nodes: [FileNode]) {
        #if os(macOS)
        sidebar?.reload(nodes)
        #else
        treeVersion += 1
        #endif
    }
}

/// Something that couldn't be done, and why.
public struct Problem: Identifiable, Equatable {
    public let id = UUID()
    public var title: String
    public var message: String
}

// MARK: - EditorControllerDelegate

extension Workspace: EditorControllerDelegate {
    public func editorTextDidChange(_ editor: EditorController) {
        note?.update(text: editor.text)
    }

    public func editorOutlineDidChange(_ editor: EditorController) {
        outline = editor.outline
        stats = editor.stats
    }

    /// To-dos scrolled its title up under the toolbar, or back.
    func todosTitleScrolled(away: Bool) {
        if showsTodos, isTitleScrolledAway != away { isTitleScrolledAway = away }
    }

    public func editorPositionDidChange(_ editor: EditorController) {
        if currentHeading != editor.currentHeading { currentHeading = editor.currentHeading }
        if isTitleScrolledAway != editor.isTitleScrolledAway { isTitleScrolledAway = editor.isTitleScrolledAway }
    }

    public func editorDrawingDidChange(_ editor: EditorController) {
        if isDrawing != editor.isDrawing { isDrawing = editor.isDrawing }
        if canUndoDrawing != editor.canUndoDrawing { canUndoDrawing = editor.canUndoDrawing }
        if canRedoDrawing != editor.canRedoDrawing { canRedoDrawing = editor.canRedoDrawing }
    }

    public func editorEditingDidChange(_ editor: EditorController) {
        #if os(iOS)
        // Asked once the focus has settled, so going from the title to the text doesn't count as stopping.
        DispatchQueue.main.async { [weak self] in
            let editing = editor.isFocused || editor.isEditingTitle
            if self?.isEditing != editing { self?.isEditing = editing }
        }
        #endif
    }

    public func editor(_ editor: EditorController, open target: LinkTarget.Kind) {
        switch target {
        case .url(let string):
            if let url = URL(string: string), url.scheme != nil { openExternally(url) }
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) { open(url) } else { beep() }
        case .note(let target):
            if let url = index.resolve(target, from: currentURL) {
                open(url)
            } else if let folder = currentURL?.deletingLastPathComponent() ?? folderForNewNote {
                // A link to a note that doesn't exist yet makes it.
                let name = target.components(separatedBy: "#").first ?? target
                Task {
                    if await newNote(in: folder, title: name).value != nil { editor.focusText() }
                }
            }
        }
    }

    public func editor(_ editor: EditorController, quickLook url: URL) {
        quickLook(url)
    }

    public func editor(_ editor: EditorController, commitTitle title: String) {
        guard let note else { return }
        let current = note.url.deletingPathExtension().lastPathComponent
        // A new note's title left empty keeps its placeholder, rather than "Untitled" to type over.
        if title.isEmpty, note.isNew { return }
        let wanted = title.isEmpty ? current : title
        if wanted.isEmpty || FileOperations.fileName(from: wanted) == current {
            editor.setTitle(current)
            return
        }
        let renaming = rename(note.url, to: wanted, updatingLinks: !note.isNew)
        note.isNew = false
        Task {
            // The name typed stays while the file is renamed; it goes back only when the name was taken.
            if await renaming.value == nil, self.note === note { editor.setTitle(note.url.deletingPathExtension().lastPathComponent) }
        }
    }

    public func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] {
        index.linkSuggestions(query, from: currentURL)
    }

    public func editor(_ editor: EditorController, resolve target: String) -> URL? {
        index.resolve(target, from: currentURL)
    }

    public func editorNoteName(_ editor: EditorController) -> String {
        currentURL?.deletingPathExtension().lastPathComponent ?? "Note"
    }

    public func editorShowReminder(_ editor: EditorController) {
        guard let currentURL, note != nil else { return }
        askForReminder(currentURL)
    }

    public func editor(_ editor: EditorController, showTodoReminderOnLine line: Int, part: TodoPart) {
        guard let currentURL, note != nil else { return }
        askForTodoReminder(in: editor, url: currentURL, line: line, part: part)
    }

    public func editor(_ editor: EditorController, tickedRepeatingTodo source: String, line: Int, next: String) {
        guard let currentURL, note != nil else { return }
        repeatingTodoTicked(in: currentURL, line: line, source: source, next: next)
    }
}
