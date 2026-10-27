import XCTest
@testable import NotebookKit

/// New folders from the sidebar: the plus on a location's header, and New Folder in a folder's menu. The folder shows
/// at once, selected, with its name ready to type over, as in the Finder: at the top of a location, inside a folder,
/// and in the folders iCloud Drive links in. Built on a stand-in iCloud Drive, as in LocationTests.
@MainActor
final class NewFolderTests: XCTestCase {
    private var base: URL!
    private var drive: URL!
    private var desktop: URL { base.appendingPathComponent("Desktop") }
    private var papers: URL { drive.appendingPathComponent("Papers") }
    private var vault: URL { base.appendingPathComponent("Mobile Documents/iCloud~md~obsidian/Documents") }
    private var window: NSWindow!
    /// Kept as long as the test is: a new folder's row is still sliding in as a test ends on a busy Mac, and its name
    /// field then asks the sidebar for its row.
    private var sidebar: SidebarController?

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-newfolder-\(UUID().uuidString)").standardizedFileURL
        drive = base.appendingPathComponent("Mobile Documents/com~apple~CloudDocs")
        try make(papers)
        try make(desktop.appendingPathComponent("Trip"))
        try make(vault.appendingPathComponent("Vault"))
        try "# Draft\n".write(to: papers.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        let link = drive.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
        XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)
        UserDefaults.standard.set(drive.path, forKey: "NotebookICloudDrive")
        UserDefaults.standard.set(drive.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("iCloud Drive", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookICloudDrive", "NotebookLibrary", "NotebookLibraryName", "NotebookSlowFolders", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// iCloud Drive as the only location, read, in a sidebar in a window.
    private func makeSidebar() async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        self.sidebar = sidebar
        workspace.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("iCloud Drive was read") { workspace.hasReadLocations && workspace.reader.isIdle && !self.names(sidebar).isEmpty }
        window.layoutIfNeeded()
        return (workspace, sidebar)
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func names(_ sidebar: SidebarController) -> [String] {
        (0..<sidebar.outline.numberOfRows).compactMap { (sidebar.outline.item(atRow: $0) as? FileNode)?.name }
    }

    private func row(_ name: String, under parent: URL, in sidebar: SidebarController) -> Int? {
        (0..<sidebar.outline.numberOfRows).first {
            guard let node = sidebar.outline.item(atRow: $0) as? FileNode else { return false }
            // Reading a temporary folder names what is in it /private/var/…, not /var/….
            return node.name == name && node.url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
        }
    }

    /// The field the row's name is being typed in, if it is.
    private func nameField(at row: Int, in sidebar: SidebarController) -> NSText? {
        (sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFileCell)?.label.currentEditor()
    }

    private func header(_ title: String, in sidebar: SidebarController) throws -> SidebarHeaderCell {
        let row = try XCTUnwrap((0..<sidebar.outline.numberOfRows).first {
            (sidebar.outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SidebarHeaderCell)?.label.stringValue == title
        })
        return try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarHeaderCell)
    }

    /// Waits for a new folder's row: selected, with all of its name selected to type over.
    private func newRow(_ name: String, under parent: URL, in sidebar: SidebarController) async throws -> Int {
        try await until("\(name) in \(parent.lastPathComponent), selected and named in place") {
            guard let row = row(name, under: parent, in: sidebar) else { return false }
            return sidebar.outline.selectedRow == row && nameField(at: row, in: sidebar)?.selectedRange == NSRange(location: 0, length: (name as NSString).length)
        }
        return try XCTUnwrap(row(name, under: parent, in: sidebar))
    }

    func testThePlusOnALocationsHeaderMakesAFolderToName() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let cell = try header("iCloud Drive", in: sidebar)
        XCTAssertTrue(cell.addButton.isHidden, "only under the pointer")
        cell.isHovered = true
        XCTAssertFalse(cell.addButton.isHidden)
        XCTAssertEqual(cell.addButton.accessibilityLabel(), "New Folder in iCloud Drive")
        cell.addButton.performClick(nil)

        let row = try await newRow("New Folder", under: drive, in: sidebar)
        let made = drive.appendingPathComponent("New Folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        XCTAssertEqual(workspace.selectedFolder?.path, made.path, "⌘N puts a note in it")
        XCTAssertEqual(names(sidebar), ["Desktop", "New Folder", "Obsidian", "Papers"], "among the other folders, linked ones too")

        let field = try XCTUnwrap(nameField(at: row, in: sidebar) as? NSTextView)
        field.insertText("Ideas", replacementRange: field.selectedRange())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let ideas = drive.appendingPathComponent("Ideas")
        try await until("renamed on disk") { FileManager.default.fileExists(atPath: ideas.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
        try await until("Ideas selected under its new name") { sidebar.outline.selectedRow == self.row("Ideas", under: self.drive, in: sidebar) }
        XCTAssertEqual(workspace.selectedFolder?.path, ideas.path, "follows the rename")

        // Another one is New Folder again; one next to a folder of that name is New Folder 2.
        workspace.newFolder(in: drive)
        _ = try await newRow("New Folder", under: drive, in: sidebar)
        workspace.newFolder(in: drive)
        let second = try await newRow("New Folder 2", under: drive, in: sidebar)
        // Escape keeps the name it has, as in the Finder.
        try XCTUnwrap(nameField(at: second, in: sidebar) as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(nameField(at: second, in: sidebar))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("New Folder 2").path))

        // File › New Folder while a name is typed: the name is taken, and the folder goes in the one selected.
        sidebar.beginRenaming(drive.appendingPathComponent("New Folder 2"))
        let renaming = try XCTUnwrap(nameField(at: second, in: sidebar) as? NSTextView)
        renaming.insertText("Trips", replacementRange: renaming.selectedRange())
        workspace.newFolder()
        _ = try await newRow("New Folder", under: drive.appendingPathComponent("Trips"), in: sidebar)
    }

    func testFoldersInsideFoldersAndInTheFoldersICloudDriveLinksIn() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        // Papers, Desktop (a link to ~/Desktop), Obsidian (an app's iCloud folder) and a folder in Desktop.
        for (parent, level) in [(papers, 2), (desktop, 2), (vault, 2), (desktop.appendingPathComponent("Trip"), 3)] {
            workspace.newFolder(in: parent)
            let row = try await newRow("New Folder", under: parent, in: sidebar)
            XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("New Folder").path), parent.path)
            XCTAssertEqual(sidebar.outline.level(forRow: row), level, "opened down to it")
            window.makeFirstResponder(sidebar.outline)
        }
        // Linked folders can't be renamed, but what is made in them can.
        let elsewhere = await workspace.rename(desktop, to: "Elsewhere").value
        XCTAssertNil(elsewhere)
        let drafts = await workspace.rename(desktop.appendingPathComponent("New Folder"), to: "Drafts").value
        XCTAssertNotNil(drafts)
    }

    /// In iCloud Drive reading a folder can take seconds: the new one shows before that, and the readings that come
    /// in after it neither take it away nor end typing its name.
    func testTheNewFolderShowsBeforeItsFolderHasBeenReadAgain() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        UserDefaults.standard.set(1.0, forKey: "NotebookSlowFolders")
        let start = Date()
        workspace.newFolder(in: drive)
        let row = try await newRow("New Folder", under: drive, in: sidebar)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8, "waited for iCloud Drive to be read again")
        XCTAssertTrue(workspace.reader.isReading(drive))

        try await until("every reading is in", seconds: 8) { workspace.reader.isIdle }
        XCTAssertEqual(self.row("New Folder", under: drive, in: sidebar), row)
        XCTAssertNotNil(nameField(at: row, in: sidebar), "the readings ended typing the name")
    }

    /// While a name is typed the rest of the sidebar waits, as reloading the row would end the typing; what changed
    /// shows once the name is in.
    func testChangesWaitUntilTheNameIsIn() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        sidebar.beginRenaming(papers)
        let row = try XCTUnwrap(row("Papers", under: drive, in: sidebar))
        XCTAssertNotNil(nameField(at: row, in: sidebar))
        try make(drive.appendingPathComponent("Arrived"))
        await workspace.readAgain(drive)
        workspace.sidebarReloadAll()
        sidebar.refreshRows()
        XCTAssertNotNil(nameField(at: row, in: sidebar), "a reload ended it")
        XCTAssertFalse(names(sidebar).contains("Arrived"))

        try XCTUnwrap(nameField(at: row, in: sidebar) as? NSTextView).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(names(sidebar), ["Arrived", "Desktop", "Obsidian", "Papers"])
    }

    func testAFolderMadeHereGoesInInTheSidebarsOrder() throws {
        let root = FileNode(url: drive, kind: .folder, parent: nil)
        root.linked = Location.iCloudDriveLinks(in: drive)
        root.apply(FileNode.list(drive, linked: root.linked))
        let desktopNode = try XCTUnwrap(root.loadedChildren().first { $0.isLinked && $0.name == "Desktop" })
        try make(drive.appendingPathComponent("Ideas"))
        XCTAssertTrue(root.insertFolder(drive.appendingPathComponent("Ideas")))
        XCTAssertEqual(root.loadedChildren().map(\.name), ["Desktop", "Ideas", "Obsidian", "Papers"])
        XCTAssertTrue(root.loadedChildren().first { $0.name == "Desktop" } === desktopNode, "the others stay as they were")
        XCTAssertFalse(root.insertFolder(drive.appendingPathComponent("Ideas")), "there already")
        root.apply(FileNode.list(drive, linked: root.linked))
        XCTAssertEqual(root.loadedChildren().map(\.name), ["Desktop", "Ideas", "Obsidian", "Papers"], "reading the folder again finds the same")
    }
}
