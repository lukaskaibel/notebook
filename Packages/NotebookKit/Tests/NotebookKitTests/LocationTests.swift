import XCTest
@testable import NotebookKit

/// iCloud Drive as the Finder shows it: with Desktop, Documents and the folders of apps that share theirs, which all
/// live outside iCloud Drive's own folder. Built here as a stand-in, next to a library folder for the other location.
@MainActor
final class LocationTests: XCTestCase {
    private var base: URL!
    private var drive: URL!
    private var desktop: URL { base.appendingPathComponent("Desktop") }
    private var plan: URL { desktop.appendingPathComponent("Trip/Plan.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-icloud-\(UUID().uuidString)").standardizedFileURL
        let containers = base.appendingPathComponent("Mobile Documents")
        drive = containers.appendingPathComponent("com~apple~CloudDocs")
        try make(drive.appendingPathComponent("Papers"))
        try make(desktop.appendingPathComponent("Trip"))
        try "# Plan\n".write(to: plan, atomically: true, encoding: .utf8)
        // The system's links to Desktop and Documents are hidden; a link made by hand isn't.
        let link = drive.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
        XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Shortcut"), withDestinationURL: desktop)
        // Apps that share their iCloud folder have it visible; the others' are hidden.
        try make(containers.appendingPathComponent("iCloud~md~obsidian/Documents/Vault"))
        try make(containers.appendingPathComponent("com~apple~mail/Documents"))
        XCTAssertEqual(chflags(containers.appendingPathComponent("com~apple~mail").path, UInt32(UF_HIDDEN)), 0)
        try make(containers.appendingPathComponent("iCloud~com~example~nodocuments"))
        UserDefaults.standard.set(drive.path, forKey: "NotebookICloudDrive")
    }

    override func tearDown() async throws {
        for key in ["NotebookICloudDrive", "NotebookLibrary", "NotebookSlowFolders", "expandedFolders"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A workspace with a library folder (for this run only), then iCloud Drive opened as File › Open does, once
    /// both have been read.
    private func makeWorkspace(settled: Bool = true) async throws -> Workspace {
        let library = base.appendingPathComponent("Library")
        try make(library)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        workspace.openFolder(drive)
        if settled { try await settle(workspace) }
        return workspace
    }

    /// Waits until the locations have been looked up and no folder is being read any more.
    private func settle(_ workspace: Workspace) async throws {
        for _ in 0..<250 {
            if workspace.hasReadLocations, workspace.reader.isIdle { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the locations were never read")
    }

    func testICloudDriveLinksDesktopAndSharedAppFolders() {
        let links = Location.iCloudDriveLinks(in: drive)
        XCTAssertEqual(links.map(\.name).sorted(), ["Desktop", "Obsidian"])
        XCTAssertEqual(links.first { $0.name == "Desktop" }?.url.path, desktop.path)
        XCTAssertEqual(links.first { $0.name == "Obsidian" }?.url.lastPathComponent, "Documents")
    }

    func testOtherFoldersLinkNothingAndLinksAreNotSaved() throws {
        var papers = Location(id: UUID(), name: "Papers", path: drive.appendingPathComponent("Papers").path, bookmark: nil)
        papers.findLinkedFolders()
        XCTAssertTrue(papers.linked.isEmpty)

        var drive = Location(id: UUID(), name: "iCloud Drive", path: drive.path, bookmark: nil)
        drive.findLinkedFolders()
        XCTAssertEqual(drive.linked.count, 2)
        let saved = try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(drive))
        XCTAssertEqual(saved.path, drive.path)
        XCTAssertTrue(saved.linked.isEmpty, "found again on every launch")
    }

    /// On My iPhone, chosen itself in the folder picker, is a folder called "File Provider Storage" (#130), like the
    /// storage of other apps' file providers; its bookmark names Apple's own provider.
    func testOnMyIPhoneIsKnownByItsBookmark() {
        let device = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-4E5F-6789-ABCD-EF0123456789/File Provider Storage")
        // What a bookmark made from the folder picker's address has in it, among the folder's path.
        func bookmark(provider: String) -> Data { Data("book\u{0}fp:/3xefWl4FZpxAEjeAG2GfjmAOxOJQGq9x=/\(provider)//fid=144320352\u{0}".utf8) }
        let onDevice = bookmark(provider: "com.apple.FileProvider.LocalStorage")
        XCTAssertEqual(Location.onDeviceFolders(device, bookmark: onDevice), [])
        XCTAssertEqual(Location.onDeviceFolders(device.appendingPathComponent("Downloads/Recipes"), bookmark: onDevice), ["Downloads", "Recipes"])
        // Another app's file provider keeps its files in a folder of that name too.
        XCTAssertNil(Location.onDeviceFolders(device, bookmark: bookmark(provider: "com.example.WorkingCopy.FileProvider")))
        XCTAssertNil(Location.onDeviceFolders(device.appendingPathComponent("8F3A/Notes"), bookmark: bookmark(provider: "com.example.WorkingCopy.FileProvider")))
        // Without a bookmark (a folder given on the command line, a location not looked up yet) it is a folder like any other.
        XCTAssertNil(Location.onDeviceFolders(device, bookmark: nil))
        XCTAssertNil(Location.onDeviceFolders(drive, bookmark: onDevice))
        XCTAssertNil(Location(id: UUID(), name: "File Provider Storage", path: device.path, bookmark: nil).onDeviceFolders)
        XCTAssertEqual(Location(id: UUID(), name: "File Provider Storage", path: device.path, bookmark: onDevice).onDeviceFolders, [])
    }

    func testSidebarShowsLinkedFoldersAmongTheOthers() async throws {
        let workspace = try await makeWorkspace()
        guard let location = workspace.location(containing: drive), let root = workspace.root(for: location) else { return XCTFail("no iCloud Drive") }
        XCTAssertEqual(location.name, "iCloud Drive")
        XCTAssertEqual(root.loadedChildren().map(\.name), ["Desktop", "Obsidian", "Papers", "Shortcut"])
        XCTAssertEqual(root.loadedChildren().filter(\.isLinked).map(\.name), ["Desktop", "Obsidian"])

        XCTAssertEqual(workspace.location(containing: plan)?.id, location.id)
        XCTAssertEqual(workspace.nodes(to: plan)?.nodes.map(\.name), ["com~apple~CloudDocs", "Desktop", "Trip", "Plan"])
        // Temporary folders come back as /private/var as well as /var.
        XCTAssertEqual(workspace.node(for: plan)?.url.resolvingSymlinksInPath().path, plan.resolvingSymlinksInPath().path)
        XCTAssertEqual(workspace.folderName(desktop), "Desktop")
        XCTAssertEqual(workspace.folderName(drive), "iCloud Drive")
        XCTAssertTrue(workspace.isLinkedFolder(desktop))
        XCTAssertFalse(workspace.isLinkedFolder(desktop.appendingPathComponent("Trip")))
    }

    func testLinkedFoldersStayPut() async throws {
        let workspace = try await makeWorkspace()
        let renamed = await workspace.rename(desktop, to: "Renamed").value
        XCTAssertNil(renamed)
        let trashed = await workspace.trash(desktop).value
        XCTAssertFalse(trashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))
    }

    func testOpeningAFolderAddsItOnlyWhenNoLocationHasIt() async throws {
        let workspace = try await makeWorkspace()
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive"])

        let trip = desktop.appendingPathComponent("Trip")
        workspace.openFolder(trip)
        workspace.openFolder(drive)
        XCTAssertEqual(workspace.locations.count, 2, "already in iCloud Drive")
        XCTAssertEqual(workspace.selectedFolder?.path, drive.path)

        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        workspace.openFolder(elsewhere)
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
    }

    func testOnlyFoldersTheSidebarDoesntShowAreAddedByDropping() async throws {
        let workspace = try await makeWorkspace()
        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        let file = base.appendingPathComponent("Loose.md")
        try "# Loose\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(workspace.newLocations(in: [elsewhere])?.map(\.path), [elsewhere.path])
        XCTAssertNil(workspace.newLocations(in: [elsewhere, file]), "a file can't be a location")
        XCTAssertNil(workspace.newLocations(in: [drive.appendingPathComponent("Papers")]), "already in iCloud Drive")
        XCTAssertNil(workspace.newLocations(in: [desktop]), "already in iCloud Drive, linked")
        XCTAssertNil(workspace.newLocations(in: []))

        XCTAssertTrue(workspace.addLocations([elsewhere]))
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
        XCTAssertFalse(workspace.addLocations([elsewhere]), "there already")
        XCTAssertEqual(workspace.locations.count, 3)
        try await settle(workspace)
    }

    func testSidebarAddsAFolderDroppedBetweenItsSections() async throws {
        let workspace = try await makeWorkspace()
        let sidebar = SidebarController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        window.layoutIfNeeded()
        let outline = sidebar.outline
        XCTAssertEqual(outline.numberOfRows, 7, "To-dos, then two sections, iCloud Drive’s open")

        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        let below = NSPoint(x: 100, y: 20)
        let papers = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.first { $0.name == "Papers" }!
        let onPapers = outline.convert(NSPoint(x: 100, y: outline.rect(ofRow: outline.row(forItem: papers)).midY), to: nil)
        func validate(_ urls: [URL], at point: NSPoint, proposing item: Any?, _ index: Int) -> NSDragOperation {
            sidebar.outlineView(outline, validateDrop: FakeDrag(urls, at: point), proposedItem: item, proposedChildIndex: index)
        }

        XCTAssertEqual(validate([elsewhere], at: onPapers, proposing: papers, NSOutlineViewDropOnItemIndex), .copy, "into Papers, as before")
        XCTAssertEqual(validate([elsewhere], at: below, proposing: nil, 1), .link)
        XCTAssertEqual(validate([elsewhere], at: below, proposing: papers, 0), .link, "below the last row")
        let file = base.appendingPathComponent("Loose.md")
        try "# Loose\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(validate([file], at: below, proposing: nil, 1), [], "a file isn't a location")
        XCTAssertEqual(validate([desktop.appendingPathComponent("Trip")], at: below, proposing: nil, 1), [], "already there")

        XCTAssertTrue(sidebar.outlineView(outline, acceptDrop: FakeDrag([elsewhere], at: below), item: nil, childIndex: NSOutlineViewDropOnItemIndex))
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
        XCTAssertTrue((0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? SidebarEntry)?.sectionKey == workspace.locations.last?.id.uuidString })
        try await settle(workspace)
    }

    // MARK: - Never waiting for the disk

    /// Adding a location shows it at once, by name, however slow its folders are to read; its files follow.
    func testAddingALocationDoesNotWaitForItsFiles() async throws {
        UserDefaults.standard.set(0.4, forKey: "NotebookSlowFolders")
        let workspace = try await makeWorkspace(settled: false)
        try await settle(workspace)
        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere.appendingPathComponent("Inside"))
        try "# A\n".write(to: elsewhere.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)

        let start = Date()
        workspace.addLocation(elsewhere)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "adding waited for the folder")
        guard let location = workspace.locations.last, let root = workspace.root(for: location) else { return XCTFail("not added") }
        XCTAssertEqual(location.name, "Elsewhere")
        XCTAssertFalse(root.hasLoadedChildren, "read on the main thread")
        XCTAssertTrue(workspace.isSurveying)

        try await settle(workspace)
        XCTAssertEqual(root.visibleChildren().map(\.name), ["Inside", "A"])
        XCTAssertNotNil(workspace.locations.last?.bookmark, "the bookmark is made off the main thread")
    }

    /// The sidebar shows a new location's files once, with its linked folders among them: it doesn't read the top
    /// itself before they are known, which would slide Desktop and the app folders in a moment later.
    func testTheSidebarShowsANewLocationOnceWithItsLinkedFolders() async throws {
        let library = base.appendingPathComponent("Library")
        try make(library)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        try await settle(workspace)

        workspace.addLocation(drive)
        XCTAssertTrue(workspace.reader.isIdle, "the sidebar read iCloud Drive without its linked folders")
        try await settle(workspace)
        let rows = (0..<sidebar.outline.numberOfRows).compactMap { (sidebar.outline.item(atRow: $0) as? FileNode)?.name }
        XCTAssertEqual(rows, ["Desktop", "Obsidian", "Papers", "Shortcut"])
    }

    /// At launch the locations show by name straight away, and their files with the folders open last time come
    /// together a moment later, so the sidebar fills in once and doesn't grow folder by folder.
    func testFoldersOpenLastTimeAreReadWithTheirLocation() async throws {
        UserDefaults.standard.set(0.2, forKey: "NotebookSlowFolders")
        let trip = desktop.appendingPathComponent("Trip")
        UserDefaults.standard.set([drive.appendingPathComponent("Papers").path, desktop.path, trip.path], forKey: "expandedFolders")
        UserDefaults.standard.set(drive.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        guard let location = workspace.locations.first, let root = workspace.root(for: location) else { return XCTFail("no location") }
        XCTAssertFalse(root.hasLoadedChildren)

        try await settle(workspace)
        XCTAssertEqual(root.visibleChildren().map(\.name), ["Desktop", "Obsidian", "Papers", "Shortcut"])
        XCTAssertTrue(workspace.node(for: trip, reading: false)?.hasLoadedChildren ?? false, "read along with the location")
        XCTAssertEqual(workspace.node(for: plan, reading: false)?.name, "Plan")
    }

    /// The sidebar shows a file found by search only once the folders down to it have been read, off the main thread.
    func testFoldersDownToAFileAreReadBeforeItIsShown() async throws {
        let workspace = try await makeWorkspace()
        XCTAssertNil(workspace.node(for: plan, reading: false), "Desktop › Trip isn't open")
        XCTAssertEqual(workspace.folders(to: plan)?.folders.map(\.lastPathComponent), ["com~apple~CloudDocs", "Desktop", "Trip"])
        XCTAssertEqual(workspace.folders(to: desktop)?.folders.map(\.lastPathComponent), ["com~apple~CloudDocs"])
        XCTAssertEqual(workspace.folders(to: drive)?.folders, [])

        var shown = false
        workspace.readFolders(to: plan) { shown = true }
        XCTAssertFalse(shown)
        for _ in 0..<100 where !shown { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(shown)
        XCTAssertEqual(workspace.node(for: plan, reading: false)?.name, "Plan")
    }

    /// Files that change elsewhere (the Finder, iCloud) show up in folders already read.
    func testChangesElsewhereShowInFoldersRead() async throws {
        let workspace = try await makeWorkspace()
        let papers = drive.appendingPathComponent("Papers")
        guard let node = workspace.node(for: papers, reading: false) else { return XCTFail("Papers") }
        workspace.read([node])
        try await settle(workspace)
        XCTAssertEqual(node.visibleChildren().map(\.name), [])

        try "# New\n".write(to: papers.appendingPathComponent("New.md"), atomically: true, encoding: .utf8)
        for _ in 0..<150 where node.visibleChildren().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(node.visibleChildren().map(\.name), ["New"])
    }

    /// Only the newest reading of a folder counts: an older one finishing later doesn't put old files back.
    func testAnOlderReadingOfAFolderIsDropped() async throws {
        UserDefaults.standard.set(0.2, forKey: "NotebookSlowFolders")
        let reader = FolderReader()
        var first: [FolderReader.Result]?
        var second: [FolderReader.Result]?
        reader.read([.init(url: drive)]) { first = $0 }
        reader.read([.init(url: drive)]) { second = $0 }
        XCTAssertTrue(reader.isReading(drive))
        for _ in 0..<100 where first == nil || second == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(first?.count, 0)
        // Folders first; the hidden link to Desktop isn't read as a file of iCloud Drive's.
        XCTAssertEqual(second?.first?.listing?.map(\.url.lastPathComponent), ["Papers", "Shortcut"])
        XCTAssertTrue(reader.isIdle)
    }

    /// A folder read again after something you did in it, such as a rename, drops the readings of it
    /// still under way: they began before and could bring back the old name.
    func testReadingAgainDropsOlderReadings() async throws {
        UserDefaults.standard.set(0.2, forKey: "NotebookSlowFolders")
        let reader = FolderReader()
        var results: [FolderReader.Result]?
        reader.read([.init(url: drive)]) { results = $0 }
        // File events name it /private/var/…, the sidebar /var/….
        reader.dropReadings(of: URL(fileURLWithPath: "/private" + drive.path))
        XCTAssertFalse(reader.isReading(drive))
        for _ in 0..<100 where results == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(results?.count, 0)
    }

    /// A folder you open is read next, before the ones read ahead of time that were waiting already.
    func testAnOpenedFolderIsReadBeforeTheOnesReadAhead() async throws {
        let folders = (1...6).map { drive.appendingPathComponent("Folder \($0)") }
        try folders.forEach(make)
        let reader = FolderReader()
        // Each read takes this long, whatever another test run on the Mac sets `-NotebookSlowFolders` to meanwhile.
        reader.delay = 0.3
        var order: [String] = []
        for folder in folders {
            reader.read([.init(url: folder)], ahead: true) { results in order += results.map { URL(fileURLWithPath: $0.path).lastPathComponent } }
        }
        reader.hurry(folders[5])
        for _ in 0..<500 where order.count < 6 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(order.count, 6, "\(order)")
        XCTAssertLessThan(order.firstIndex(of: "Folder 6") ?? 6, order.firstIndex(of: "Folder 5") ?? -1, "\(order)")
    }

    /// Search follows changes folder by folder: new notes come in with their text, and a folder that went takes
    /// everything in it along.
    func testSearchFollowsChangesFolderByFolder() async throws {
        let workspace = try await makeWorkspace()
        let index = workspace.index
        for _ in 0..<100 where index.isBuilding || index.entry(for: plan) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let papers = drive.appendingPathComponent("Papers")
        let old = papers.appendingPathComponent("Old")
        try make(old)
        try "# Paper\nAbout quantum foam.\n".write(to: papers.appendingPathComponent("Paper.md"), atomically: true, encoding: .utf8)
        try "# Deep\n".write(to: old.appendingPathComponent("Deep.md"), atomically: true, encoding: .utf8)
        let before = index.count

        index.refresh(folders: [papers, old], locations: workspace.locations)
        for _ in 0..<100 where index.entry(for: old.appendingPathComponent("Deep.md")) == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(index.count, before + 3)
        XCTAssertEqual(index.textHits("quantum").map(\.item.name), ["Paper"])
        XCTAssertEqual(index.resolve("Deep", from: plan)?.lastPathComponent, "Deep.md")

        try FileManager.default.removeItem(at: old)
        index.refresh(folders: [papers], locations: workspace.locations)
        for _ in 0..<100 where index.entry(for: old) != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(index.entry(for: old.appendingPathComponent("Deep.md")), "went with its folder")
        XCTAssertEqual(index.count, before + 1)
    }

    func testSearchAndMoveToReachLinkedFolders() async throws {
        let workspace = try await makeWorkspace()
        for _ in 0..<100 where workspace.index.isBuilding || workspace.index.entry(for: plan) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(workspace.index.entry(for: plan)?.place, "iCloud Drive › Desktop › Trip")
        XCTAssertFalse(workspace.index.entries.contains { $0.url.path == drive.appendingPathComponent("Desktop").path },
                       "the hidden link isn't a file of its own")
        let targets = workspace.moveTargets(for: plan).first { $0.location.isICloudDrive }?.folders
        XCTAssertEqual(targets?.map(\.name), ["iCloud Drive", "Desktop", "Trip", "Obsidian", "Vault", "Papers"])
        XCTAssertEqual(targets?.map(\.depth), [-1, 0, 1, 0, 1, 0])
    }
}

/// A drag of files from the Finder, held over the sidebar at a point in the window.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-test-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(_ urls: [URL], at point: NSPoint) {
        draggingLocation = point
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
