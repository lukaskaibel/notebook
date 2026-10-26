import XCTest
@testable import NotebookKit

/// Sorting a folder's files by name, date edited or date created: the dates come with the folder read, the order is
/// made from them on the main thread without looking at any file, and the sidebar slides rows to their new places
/// without losing the selection or jumping its scroll.
@MainActor
final class FileOrderTests: XCTestCase {
    private var base: URL!
    private var notes: URL { base.appendingPathComponent("Notes") }
    private var window: NSWindow!
    private var orders: FileOrders { NotebookSettings.shared.fileOrders }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-order-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        UserDefaults.standard.set(base.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Library", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        orders.set(.name, for: nil)
        NotebookSettings.shared.foldersFirst = true
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections", "fileOrder"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        try? FileManager.default.removeItem(at: base)
    }

    /// A note edited and made `edited` and `made` seconds ago.
    @discardableResult
    private func note(_ name: String, in folder: URL? = nil, edited: TimeInterval, made: TimeInterval? = nil) throws -> URL {
        let url = (folder ?? notes).appendingPathComponent(name + ".md")
        try "# \(name)\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -edited),
                                               .creationDate: Date(timeIntervalSinceNow: -(made ?? edited))], ofItemAtPath: url.path)
        return url
    }

    private let now = Date()

    private func node(_ name: String, folder: Bool = false, edited: TimeInterval?, made: TimeInterval?) -> FileNode {
        FileNode(url: notes.appendingPathComponent(folder ? name : name + ".md"), kind: folder ? .folder : .note,
                 modified: edited.map { now.addingTimeInterval(-$0) }, created: made.map { now.addingTimeInterval(-$0) }, parent: nil)
    }

    // MARK: - The order

    func testReadingAFolderBringsWhenEachFileWasEditedAndMade() throws {
        try note("Old", edited: 100, made: 5000)
        let listing = FileNode.list(notes)
        let old = try XCTUnwrap(listing.first { $0.url.lastPathComponent == "Old.md" })
        XCTAssertEqual(try XCTUnwrap(old.modified).timeIntervalSinceNow, -100, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(old.created).timeIntervalSinceNow, -5000, accuracy: 2)
    }

    func testDatesSortNewestFirstWithFoldersOnTopOrAmongTheFiles() {
        // As reading the folder lists them: folders first, each by name.
        let nodes = [node("Archive", folder: true, edited: 50, made: 9000), node("Projects", folder: true, edited: 5, made: 10),
                     node("Groceries", edited: 1, made: 8000), node("Ideas", edited: 30, made: 20), node("Undated", edited: nil, made: nil),
                     node("Zebra", edited: 30, made: 20)]
        func names(_ order: FileOrder, foldersFirst: Bool, onlyNotes: Bool = false) -> [String] {
            FileNode.Arrangement(order: order, foldersFirst: foldersFirst, onlyNotes: onlyNotes).apply(to: nodes).map(\.name)
        }
        XCTAssertEqual(names(.dateEdited, foldersFirst: true), ["Projects", "Archive", "Groceries", "Ideas", "Zebra", "Undated"],
                       "newest first, files of one date by name, one without a date last")
        XCTAssertEqual(names(.dateEdited, foldersFirst: false), ["Groceries", "Projects", "Ideas", "Zebra", "Archive", "Undated"])
        XCTAssertEqual(names(.dateCreated, foldersFirst: true), ["Projects", "Archive", "Ideas", "Zebra", "Groceries", "Undated"])
        XCTAssertEqual(names(.dateCreated, foldersFirst: false, onlyNotes: true), ["Projects", "Ideas", "Zebra", "Groceries", "Archive", "Undated"])
        XCTAssertEqual(names(.name, foldersFirst: true), ["Archive", "Projects", "Groceries", "Ideas", "Undated", "Zebra"])
        XCTAssertEqual(names(.name, foldersFirst: false), ["Archive", "Groceries", "Ideas", "Projects", "Undated", "Zebra"])
    }

    func testFoldersAmongTheFilesSortAsTheFinderSortsNames() throws {
        for name in ["Note 10", "note 2", "Ärger", "Zeta", "alpha", "Note 1"] { try note(name, edited: 10) }
        for name in ["Folder 3", "b-folder", "Note 5", "Österreich"] {
            try FileManager.default.createDirectory(at: notes.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let root = FileNode(url: notes, kind: .folder, parent: nil)
        root.apply(FileNode.list(notes))
        let woven = FileNode.Arrangement(order: .name, foldersFirst: false).apply(to: root.loadedChildren()).map(\.sortName)
        let sorted = root.loadedChildren().map(\.sortName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(woven, sorted)
    }

    func testTheOrderIsWorkedOutOncePerChange() throws {
        try note("A", edited: 10)
        try note("B", edited: 20)
        let root = FileNode(url: notes, kind: .folder, parent: nil)
        root.apply(FileNode.list(notes))
        orders.set(.dateEdited, for: notes)
        let first = root.visibleChildren()
        XCTAssertEqual(first.map(\.name), ["A", "B"])
        // The same nodes, in the same array, until something changes.
        XCTAssertTrue(zip(root.visibleChildren(), first).allSatisfy { $0 === $1 })
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: notes.appendingPathComponent("B.md").path)
        XCTAssertTrue(root.apply(FileNode.list(notes)), "a new date is a change")
        XCTAssertEqual(root.visibleChildren().map(\.name), ["B", "A"])
        orders.set(.name, for: notes)
        XCTAssertEqual(root.visibleChildren().map(\.name), ["A", "B"])
    }

    func testAFolderMadeHereGoesToTheTopWhenTheNewestComeFirst() throws {
        try note("Older", edited: 100)
        let root = FileNode(url: notes, kind: .folder, parent: nil)
        try FileManager.default.createDirectory(at: notes.appendingPathComponent("Aaa"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -50)], ofItemAtPath: notes.appendingPathComponent("Aaa").path)
        root.apply(FileNode.list(notes))
        orders.set(.dateEdited, for: notes)
        try FileManager.default.createDirectory(at: notes.appendingPathComponent("Zzz"), withIntermediateDirectories: true)
        XCTAssertTrue(root.insertFolder(notes.appendingPathComponent("Zzz")))
        XCTAssertEqual(root.visibleChildren().map(\.name), ["Zzz", "Aaa", "Older"], "where reading the folder again puts it")
    }

    // MARK: - Steps for a list

    func testRowChangesTurnOneOrderIntoTheOther() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let old = Array(0..<Int.random(in: 0...20, using: &generator))
            var new = old.filter { _ in Int.random(in: 0..<5, using: &generator) > 0 }.shuffled(using: &generator)
            for extra in 100..<(100 + Int.random(in: 0...3, using: &generator)) { new.insert(extra, at: Int.random(in: 0...new.count, using: &generator)) }
            let changes = try XCTUnwrap(RowChanges(from: old, to: new))
            var rows = old
            for step in changes.steps {
                switch step {
                case .remove(let index): rows.remove(at: index)
                case .move(let from, let to): rows.insert(rows.remove(at: from), at: to)
                case .insert(let index): rows.insert(new[index], at: index)
                }
            }
            XCTAssertEqual(rows, new, "\(old) → \(new): \(changes.steps)")
        }
    }

    func testANoteThatMovesToTheTopIsOneStep() throws {
        XCTAssertEqual(try XCTUnwrap(RowChanges(from: ["a", "b", "c", "d"], to: ["d", "a", "b", "c"])).steps, [.move(3, 0)])
        XCTAssertEqual(try XCTUnwrap(RowChanges(from: ["a", "b", "c", "d"], to: ["b", "c", "d", "a"])).steps, [.move(0, 3)])
        XCTAssertEqual(try XCTUnwrap(RowChanges(from: ["a", "b"], to: ["a", "b"])).steps, [])
        XCTAssertNil(RowChanges(from: Array(0..<10), to: Array((0..<10).reversed()), limit: 5), "too many to animate")
    }

    // MARK: - The sidebar

    private func makeSidebar(height: CGFloat = 600) async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle && !self.names(sidebar).isEmpty }
        let folder = try XCTUnwrap((0..<sidebar.outline.numberOfRows).lazy.compactMap { sidebar.outline.item(atRow: $0) as? FileNode }.first { $0.name == "Notes" })
        sidebar.outline.expandItem(folder)
        try await until("the notes are in the sidebar") { workspace.reader.isIdle && self.names(sidebar).count > 1 }
        window.layoutIfNeeded()
        return (workspace, sidebar)
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func names(_ sidebar: SidebarController) -> [String] {
        (0..<sidebar.outline.numberOfRows).compactMap { (sidebar.outline.item(atRow: $0) as? FileNode)?.name }
    }

    private func selectedName(_ sidebar: SidebarController) -> String? {
        (sidebar.outline.item(atRow: sidebar.outline.selectedRow) as? FileNode)?.name
    }

    private func isOnScreen(_ row: Int, in sidebar: SidebarController) -> Bool {
        NSLocationInRange(row, sidebar.outline.rows(in: sidebar.outline.visibleRect))
    }

    /// The note you write in moves to the top of its folder when the newest come first: its row slides there (it is
    /// the same row, not a new one), it stays selected, and it is still on screen.
    func testANoteSavedSlidesToTheTopAndStaysSelected() async throws {
        for index in 0..<6 { try note("Note \(index)", edited: Double(100 + index * 10)) }
        orders.set(.dateEdited, for: notes)
        let (workspace, sidebar) = try await makeSidebar()
        XCTAssertEqual(names(sidebar), ["Notes", "Note 0", "Note 1", "Note 2", "Note 3", "Note 4", "Note 5"])
        let last = notes.appendingPathComponent("Note 5.md")
        workspace.open(last)
        try await until("Note 5 selected") { self.selectedName(sidebar) == "Note 5" }
        let row = try XCTUnwrap(sidebar.outline.item(atRow: sidebar.outline.selectedRow) as? FileNode)

        try "# Note 5\n\nMore.\n".write(to: last, atomically: false, encoding: .utf8)
        await workspace.readAgain(notes)
        XCTAssertEqual(names(sidebar), ["Notes", "Note 5", "Note 0", "Note 1", "Note 2", "Note 3", "Note 4"])
        XCTAssertEqual(selectedName(sidebar), "Note 5")
        XCTAssertTrue(sidebar.outline.item(atRow: sidebar.outline.selectedRow) as AnyObject === row, "moved, not taken away and put in again")
        XCTAssertTrue(isOnScreen(sidebar.outline.selectedRow, in: sidebar))
    }

    /// In a sidebar too short for the folder, the selected note on screen at the bottom moves up out of view: the
    /// sidebar follows it. Scrolled away from the selected note, changes elsewhere leave the scroll where it is.
    func testTheSidebarFollowsTheSelectedNoteOnlyIfItWasOnScreen() async throws {
        for index in 0..<30 { try note(String(format: "Note %02d", index), edited: Double(100 + index * 10)) }
        orders.set(.dateEdited, for: notes)
        let (workspace, sidebar) = try await makeSidebar(height: 220)
        let last = notes.appendingPathComponent("Note 29.md")
        workspace.open(last)
        try await until("Note 29 selected and on screen") {
            self.selectedName(sidebar) == "Note 29" && self.isOnScreen(sidebar.outline.selectedRow, in: sidebar)
        }
        try "# Note 29\n\nMore.\n".write(to: last, atomically: false, encoding: .utf8)
        await workspace.readAgain(notes)
        XCTAssertEqual(names(sidebar).prefix(2), ["Notes", "Note 29"])
        try await until("the sidebar followed it up") { self.isOnScreen(sidebar.outline.selectedRow, in: sidebar) }
        XCTAssertEqual(selectedName(sidebar), "Note 29")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(isOnScreen(sidebar.outline.selectedRow, in: sidebar))

        // Scrolled to the bottom, away from Note 29 at the top: another note saved moves, and nothing scrolls.
        sidebar.outline.scrollRowToVisible(sidebar.outline.numberOfRows - 1)
        XCTAssertFalse(isOnScreen(sidebar.outline.selectedRow, in: sidebar))
        let scrolled = sidebar.scrollView.contentView.bounds.origin
        try "# Note 10\n\nMore.\n".write(to: notes.appendingPathComponent("Note 10.md"), atomically: false, encoding: .utf8)
        await workspace.readAgain(notes)
        XCTAssertEqual(names(sidebar).prefix(3), ["Notes", "Note 10", "Note 29"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sidebar.scrollView.contentView.bounds.origin, scrolled, "the sidebar jumped to the selected note")
        XCTAssertEqual(selectedName(sidebar), "Note 29")
    }

    /// Choosing another order sorts the open folders again, keeping the same rows and the selection.
    func testChoosingAnotherOrderSortsTheOpenFolders() async throws {
        try note("Banana", edited: 10, made: 300)
        try note("Apple", edited: 20, made: 100)
        try note("Cherry", edited: 30, made: 200)
        let (workspace, sidebar) = try await makeSidebar()
        XCTAssertEqual(names(sidebar), ["Notes", "Apple", "Banana", "Cherry"])
        workspace.open(notes.appendingPathComponent("Cherry.md"))
        try await until("Cherry selected") { self.selectedName(sidebar) == "Cherry" }
        orders.set(.dateEdited, for: notes)
        XCTAssertEqual(names(sidebar), ["Notes", "Banana", "Apple", "Cherry"])
        orders.set(.dateCreated, for: notes)
        XCTAssertEqual(names(sidebar), ["Notes", "Apple", "Cherry", "Banana"])
        XCTAssertEqual(selectedName(sidebar), "Cherry")
    }
}
