import Observation
import Synchronization
import XCTest
@testable import NotebookKit

/// Customize Folder: a folder's symbol or emoji and colour, kept where the Finder keeps them, so the Finder shows what
/// Notebook chose and Notebook what the Finder did; shown in the sidebar at once, written off the main thread, taken
/// back by Undo, and followed when another app changes them.
@MainActor
final class FolderIconTests: XCTestCase {
    private var library: URL!
    private var recipes: URL { library.appendingPathComponent("Recipes") }
    private var travel: URL { library.appendingPathComponent("Travel") }
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-icons-\(UUID().uuidString)").standardizedFileURL
        for folder in [recipes, travel] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "# Pancakes\n".write(to: recipes.appendingPathComponent("Pancakes.md"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections"] { UserDefaults.standard.removeObject(forKey: key) }
        windows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: library)
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func setAttribute(_ name: String, _ data: Data, on url: URL) {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        XCTAssertEqual(result, 0)
    }

    private func tagData(_ tags: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
    }

    private func tags(of url: URL) -> [String] {
        FolderIcons.value(FolderIcons.tagsAttribute, of: url).map(FolderIcons.tags) ?? []
    }

    private func json(of url: URL) throws -> [String: String] {
        guard let data = FolderIcons.value(FolderIcons.attribute, of: url) else { return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).mapValues { "\($0)" }
    }

    /// The library, read, in a sidebar in a window.
    private func makeSidebar() async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle && workspace.node(for: self.recipes, reading: false) != nil }
        window.layoutIfNeeded()
        return (workspace, sidebar)
    }

    private func cell(_ url: URL, in sidebar: SidebarController) throws -> SidebarFileCell {
        let node = try XCTUnwrap(sidebar.workspace.node(for: url, reading: false))
        let row = sidebar.outline.row(forItem: node)
        XCTAssertGreaterThanOrEqual(row, 0)
        return try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFileCell)
    }

    // MARK: - Where the Finder keeps them

    func testReadsWhatTheFinderWrote() throws {
        setAttribute(FolderIcons.attribute, Data(#"{"sym":"fork.knife"}"#.utf8), on: recipes)
        // A colour tag named in another language still has its colour.
        setAttribute(FolderIcons.tagsAttribute, try tagData(["Rot\n6"]), on: recipes)
        XCTAssertEqual(FolderIcons.read(recipes), FolderIcon(symbol: "fork.knife", color: .red))
        setAttribute(FolderIcons.attribute, Data(#"{"emoji":"✈️"}"#.utf8), on: travel)
        XCTAssertEqual(FolderIcons.read(travel), FolderIcon(emoji: "✈️"))
        XCTAssertNil(FolderIcons.read(library))
    }

    func testWritesWhereTheFinderReads() throws {
        XCTAssertTrue(FolderIcons.write(FolderIcon(symbol: "airplane", color: .blue), to: travel))
        XCTAssertEqual(try json(of: travel), ["sym": "airplane"])
        XCTAssertEqual(tags(of: travel), ["Blue\n4"])
        // An emoji takes the symbol's place.
        XCTAssertTrue(FolderIcons.write(FolderIcon(emoji: "🧳", color: .blue), to: travel))
        XCTAssertEqual(try json(of: travel), ["emoji": "🧳"])
        XCTAssertEqual(FolderIcons.read(travel), FolderIcon(emoji: "🧳", color: .blue))
        // The plain folder leaves nothing behind.
        XCTAssertTrue(FolderIcons.write(nil, to: travel))
        XCTAssertNil(FolderIcons.value(FolderIcons.attribute, of: travel))
        XCTAssertNil(FolderIcons.value(FolderIcons.tagsAttribute, of: travel))
        XCTAssertNil(FolderIcons.read(travel))
    }

    /// Only the plain colour tags change: your own tags stay, and so does anything else the Finder keeps.
    func testKeepsTheFoldersOtherTags() throws {
        setAttribute(FolderIcons.tagsAttribute, try tagData(["Work\n0", "Red\n6", "Important"]), on: recipes)
        setAttribute(FolderIcons.attribute, Data(#"{"sym":"star","later":"kept"}"#.utf8), on: recipes)
        XCTAssertTrue(FolderIcons.write(FolderIcon(emoji: "🍕", color: .green), to: recipes))
        XCTAssertEqual(tags(of: recipes), ["Work\n0", "Important", "Green\n2"])
        XCTAssertEqual(try json(of: recipes), ["emoji": "🍕", "later": "kept"])
        XCTAssertTrue(FolderIcons.write(nil, to: recipes))
        XCTAssertEqual(tags(of: recipes), ["Work\n0", "Important"])
        XCTAssertEqual(try json(of: recipes), ["later": "kept"])
    }

    /// The Finder tints a folder with the colour of its last tag that has one.
    func testColourIsTheLastColouredTags() {
        XCTAssertEqual(FolderIcons.color(of: ["Work\n4", "Home\n2"]), .green)
        XCTAssertEqual(FolderIcons.color(of: ["Work\n4", "Later\n0"]), .blue)
        XCTAssertEqual(FolderIcons.color(of: ["Purple"]), .purple)
        XCTAssertNil(FolderIcons.color(of: ["Later\n0", "Important"]))
    }

    /// A renamed or moved folder keeps its look: it is on the folder.
    func testLookStaysWithTheFolder() throws {
        XCTAssertTrue(FolderIcons.write(FolderIcon(symbol: "fork.knife", color: .orange), to: recipes))
        let moved = travel.appendingPathComponent("Cooking")
        try FileManager.default.moveItem(at: recipes, to: moved)
        XCTAssertEqual(FolderIcons.read(moved), FolderIcon(symbol: "fork.knife", color: .orange))
        let copy = library.appendingPathComponent("Cooking copy")
        try FileManager.default.copyItem(at: moved, to: copy)
        XCTAssertEqual(FolderIcons.read(copy), FolderIcon(symbol: "fork.knife", color: .orange))
    }

    // MARK: - In the sidebar

    func testListingsCarryTheLook() throws {
        XCTAssertTrue(FolderIcons.write(FolderIcon(symbol: "fork.knife"), to: recipes))
        let listing = FileNode.list(library)
        XCTAssertEqual(listing.first { $0.url.lastPathComponent == "Recipes" }?.icon, FolderIcon(symbol: "fork.knife"))
        XCTAssertNil(listing.first { $0.url.lastPathComponent == "Travel" }?.icon)
        // A changed look is a change, which shows.
        let top = FileNode(url: library, kind: .folder, parent: nil)
        XCTAssertTrue(top.apply(listing))
        XCTAssertFalse(top.apply(FileNode.list(library)))
        XCTAssertTrue(FolderIcons.write(FolderIcon(symbol: "fork.knife", color: .red), to: recipes))
        XCTAssertTrue(top.apply(FileNode.list(library)))
        XCTAssertEqual(top.loadedChildren().first { $0.url.lastPathComponent == "Recipes" }?.icon?.color, .red)
    }

    /// The lists on iPhone and iPad redraw a row when its folder's look changes, though nothing else in the folder did.
    func testALookAloneIsAChangeListsSee() throws {
        let top = FileNode(url: library, kind: .folder, parent: nil)
        top.apply(FileNode.list(library))
        let node = try XCTUnwrap(top.loadedChildren().first { $0.url.lastPathComponent == "Recipes" })
        let seen = Mutex(false)
        withObservationTracking { _ = node.icon } onChange: { seen.withLock { $0 = true } }
        XCTAssertTrue(FolderIcons.write(FolderIcon(symbol: "fork.knife"), to: recipes))
        top.apply(FileNode.list(library))
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertTrue(try XCTUnwrap(top.loadedChildren().first { $0.url.lastPathComponent == "Recipes" }) === node)
    }

    func testCustomizingShowsAtOnceAndUndoTakesItBack() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        XCTAssertTrue(workspace.canCustomize(recipes))
        XCTAssertFalse(workspace.canCustomize(library))
        let look = FolderIcon(symbol: "fork.knife", color: .orange)
        workspace.setFolderIcon(look, for: recipes)
        // Shown before it has been written.
        XCTAssertEqual(workspace.folderIcon(for: recipes), look)
        XCTAssertEqual(try cell(recipes, in: sidebar).icon.contentTintColor, NSColor.systemOrange)
        try await until("written") { FolderIcons.read(self.recipes) == look }
        // Customize Folder keeps one Undo for all it changed.
        workspace.keepFolderIconForUndo(from: nil, to: look, for: recipes)
        XCTAssertEqual(workspace.fileUndoManager.undoActionName, "Customize Folder")
        workspace.fileUndoManager.undo()
        XCTAssertNil(workspace.folderIcon(for: recipes))
        try await until("the plain folder written back") { FolderIcons.read(self.recipes) == nil }
        workspace.fileUndoManager.redo()
        XCTAssertEqual(workspace.folderIcon(for: recipes), look)
        try await until("written again") { FolderIcons.read(self.recipes) == look }
    }

    /// The Finder, or iCloud from another device, changes a folder's look: the sidebar follows.
    func testLookChangedElsewhereShows() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FolderIcons.write(FolderIcon(emoji: "✈️", color: .blue), to: travel))
        try await until("the sidebar shows the new look") { workspace.folderIcon(for: self.travel) == FolderIcon(emoji: "✈️", color: .blue) }
        try await until("the row shows the emoji") { (try? self.cell(self.travel, in: sidebar).icon.image?.isTemplate) == false }
    }

    // MARK: - What Customize Folder offers

    func testEverySymbolIsThere() {
        let missing = FolderIconCatalog.everySymbol.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [])
        // The README promises over 300.
        XCTAssertGreaterThan(Set(FolderIconCatalog.symbolGroups.flatMap(\.items)).count, 300)
        for group in FolderIconCatalog.symbolGroups + FolderIconCatalog.emojiGroups {
            XCTAssertEqual(Set(group.items).count, group.items.count, "twice in \(group.title)")
        }
    }

    func testSuggestionsFollowTheName() {
        XCTAssertEqual(FolderIconCatalog.suggestedSymbols(for: "Recipes").first, "fork.knife")
        XCTAssertEqual(FolderIconCatalog.suggestedSymbols(for: "Rezepte").first, "fork.knife")
        XCTAssertEqual(FolderIconCatalog.suggestedSymbols(for: "Uni Lectures").first, "graduationcap")
        XCTAssertTrue(FolderIconCatalog.suggestedSymbols(for: "Linear algebra").contains("function"))
        XCTAssertEqual(FolderIconCatalog.suggestedEmoji(for: "Summer trip 2026").first, "✈️")
        // A short word only as it is: "Apple" isn't about apps.
        XCTAssertEqual(FolderIconCatalog.suggestedSymbols(for: "Apple"), [])
        XCTAssertEqual(FolderIconCatalog.suggestedSymbols(for: "2025"), [])
    }

    func testSearchFindsByNameAndPurpose() {
        // Worked out once, when Customize Folder first searches.
        _ = FolderIconCatalog.emoji(matching: "a")
        _ = FolderIconCatalog.symbols(matching: "a")
        XCTAssertTrue(FolderIconCatalog.symbols(matching: "plane").contains("airplane"))
        XCTAssertTrue(FolderIconCatalog.symbols(matching: "recipe").contains("fork.knife"))
        XCTAssertTrue(FolderIconCatalog.symbols(matching: "fork kni").contains("fork.knife"))
        XCTAssertEqual(FolderIconCatalog.symbols(matching: "zzz"), [])
        XCTAssertTrue(FolderIconCatalog.emoji(matching: "pizza").contains("🍕"))
        XCTAssertTrue(FolderIconCatalog.emoji(matching: "heart").contains("❤️"))
        XCTAssertTrue(FolderIconCatalog.emoji(matching: "germany").contains("🇩🇪"))
        // Emoji that aren't in the groups are found too, and quickly, as you type.
        let start = Date()
        _ = FolderIconCatalog.emoji(matching: "o")
        _ = FolderIconCatalog.symbols(matching: "o")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertTrue(FolderIconCatalog.emoji(matching: "otter").contains("🦦"))
    }
}
