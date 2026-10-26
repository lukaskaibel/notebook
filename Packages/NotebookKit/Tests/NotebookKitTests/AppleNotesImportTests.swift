import XCTest
@testable import NotebookKit

/// Import from Apple Notes, on an export laid out as Notes' File › Export as › Markdown writes it: a folder (Archive for
/// several notes, the note's name for one), a Markdown file for each note, and an Attachments folder for the pictures
/// and files of all of them, some without an extension.
@MainActor
final class AppleNotesImportTests: XCTestCase {
    private var base: URL!
    private var export: URL { base.appendingPathComponent("Export") }
    private var archive: URL { export.appendingPathComponent("Archive") }
    private var library: URL { base.appendingPathComponent("Library") }
    private var inbox: URL { library.appendingPathComponent("Inbox") }
    private var window: NSWindow?

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 5, 6, 7, 8])
    private let pdf = Data("%PDF-1.4\n%fake\n".utf8)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-applenotes-\(UUID().uuidString)").standardizedFileURL
        let attachments = archive.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write("""
        # Shopping list

        - [ ] Milk
        - [x] Bread

        ![](Attachments/IMG_0001.jpeg)

        """, to: archive.appendingPathComponent("Shopping list.md"))
        try write("""
        Trip to Kyoto
        The tickets are in [Flight tickets.pdf](Attachments/Flight%20tickets.pdf), the list in [Shopping list](Shopping%20list.md).

        [Flight tickets.pdf](<Attachments/Flight tickets.pdf>)

        ![](Attachments/Drawing)

        | Day | Plan |
        | --- | --- |
        | 1 | Temples |

        [Apple](https://www.apple.com) and [a note elsewhere](applenotes:note/1234)
        """, to: archive.appendingPathComponent("Trip to Kyoto.md"))
        try jpeg.write(to: attachments.appendingPathComponent("IMG_0001.jpeg"))
        try pdf.write(to: attachments.appendingPathComponent("Flight tickets.pdf"))
        try png.write(to: attachments.appendingPathComponent("Drawing"))
        try png.write(to: attachments.appendingPathComponent("Unused.png"))
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Folders and notes

    func testAFolderComesInWithItsNotesAndTheirPicturesInAssets() throws {
        let result = AppleNotesImport.run([archive], into: inbox)
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertEqual(result.made.map { $0?.path }, [folder.path])
        XCTAssertEqual(result.notes, 2)
        // The title Notes repeats as the first line goes: the file's name is the title.
        XCTAssertEqual(try read(folder.appendingPathComponent("Shopping list.md")), "- [ ] Milk\n- [x] Bread\n\n![](.assets/IMG_0001.jpeg)\n")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".assets/IMG_0001.jpeg")), jpeg)
        XCTAssertFalse(exists(folder.appendingPathComponent("Attachments")), "Notes' Attachments folder came along")
    }

    func testFilesLinksAndNotesAreRewritten() throws {
        _ = AppleNotesImport.run([archive], into: inbox)
        let folder = inbox.appendingPathComponent("Archive")
        let text = try read(folder.appendingPathComponent("Trip to Kyoto.md"))
        XCTAssertEqual(text, """
        The tickets are in [Flight tickets.pdf](.assets/Flight%20tickets.pdf), the list in [[Shopping list]].

        ![Flight tickets.pdf](.assets/Flight%20tickets.pdf)

        ![](.assets/Drawing.png)

        | Day | Plan |
        | --- | --- |
        | 1 | Temples |

        [Apple](https://www.apple.com) and [a note elsewhere](applenotes:note/1234)
        """)
        // A file linked twice is there once; one without an extension got one from what it is.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".assets").path).sorted(),
                       ["Drawing.png", "Flight tickets.pdf", "IMG_0001.jpeg"])
    }

    func testAFileNoNoteLinksToComesAlongWhereItCanBeSeen() throws {
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Archive/Unused.png")), png)
    }

    func testTheFolderNotesMakesForOneNoteIsJustTheNote() throws {
        let single = export.appendingPathComponent("Pasta")
        try FileManager.default.createDirectory(at: single.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try write("**Pasta**\nBoil water.\n\n![](Attachments/photo)\n", to: single.appendingPathComponent("Pasta.md"))
        try jpeg.write(to: single.appendingPathComponent("Attachments/photo"))
        let result = AppleNotesImport.run([single], into: inbox)
        XCTAssertEqual(result.made.map { $0?.path }, [inbox.appendingPathComponent("Pasta.md").path])
        XCTAssertEqual(try read(inbox.appendingPathComponent("Pasta.md")), "Boil water.\n\n![](.assets/photo.jpg)\n")
        XCTAssertFalse(exists(inbox.appendingPathComponent("Pasta")))
    }

    func testFoldersTheExportsWerePutInComeAlong() throws {
        let tree = base.appendingPathComponent("From Notes")
        let work = tree.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: archive, to: work)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("Clients"), withIntermediateDirectories: true)
        try write("Acme\nCall back on Monday.\n", to: work.appendingPathComponent("Clients/Acme.md"))
        _ = AppleNotesImport.run([tree], into: inbox)
        let made = inbox.appendingPathComponent("From Notes/Work")
        XCTAssertTrue(exists(made.appendingPathComponent("Shopping list.md")))
        XCTAssertEqual(try read(made.appendingPathComponent("Clients/Acme.md")), "Call back on Monday.\n")
        XCTAssertTrue(exists(made.appendingPathComponent(".assets/IMG_0001.jpeg")))
    }

    func testNamesTakenAlreadyGetANumber() throws {
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let notes = base.appendingPathComponent("Loose")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try write("Errands\n- [ ] Post office\n", to: notes.appendingPathComponent("Errands.md"))
        try write("Mine\n", to: inbox.appendingPathComponent("Errands.md"))
        let result = AppleNotesImport.run([archive, notes.appendingPathComponent("Errands.md")], into: inbox)
        XCTAssertEqual(result.made.map { $0?.path }, [inbox.appendingPathComponent("Archive 2").path, inbox.appendingPathComponent("Errands 2.md").path])
        XCTAssertEqual(try read(inbox.appendingPathComponent("Errands.md")), "Mine\n", "a note there already was changed")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Errands 2.md")), "- [ ] Post office\n")
    }

    func testAPictureOfTheSameNameThereAlreadyIsKept() throws {
        let assets = inbox.appendingPathComponent("Archive/.assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try png.write(to: assets.appendingPathComponent("IMG_0001.jpeg"))
        // Archive is there, so the import makes Archive 2; its .assets is new, and nothing in the old one changes.
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("IMG_0001.jpeg")), png)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Archive 2/.assets/IMG_0001.jpeg")), jpeg)
    }

    func testNotesKeepTheirDates() throws {
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        let changed = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: changed], ofItemAtPath: archive.appendingPathComponent("Shopping list.md").path)
        _ = AppleNotesImport.run([archive], into: inbox)
        let attributes = try FileManager.default.attributesOfItem(atPath: inbox.appendingPathComponent("Archive/Shopping list.md").path)
        XCTAssertEqual(attributes[.creationDate] as? Date, made)
        XCTAssertEqual(attributes[.modificationDate] as? Date, changed)
    }

    func testNothingOutsideTheExportIsRead() throws {
        try png.write(to: base.appendingPathComponent("secret.png"))
        try write("Sneaky\n![](../../secret.png)\n", to: archive.appendingPathComponent("Sneaky.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Sneaky.md")), "![](../../secret.png)\n")
        XCTAssertFalse(exists(inbox.appendingPathComponent("Archive/.assets/secret.png")))
    }

    func testTheExportIsOnlyRead() throws {
        let before = try FileManager.default.subpathsOfDirectory(atPath: export.path).sorted()
        let text = try read(archive.appendingPathComponent("Trip to Kyoto.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: export.path).sorted(), before)
        XCTAssertEqual(try read(archive.appendingPathComponent("Trip to Kyoto.md")), text)
    }

    // MARK: - A note's text

    func testTheTitleLineGoesOnlyWhenItIsTheTitle() {
        func converted(_ text: String, _ title: String) -> String { AppleNotesImport.convert(text, title: title) { _ in nil } }
        XCTAssertEqual(converted("# Groceries\n\nEggs\n", "Groceries"), "Eggs\n")
        XCTAssertEqual(converted("\n**Groceries**\nEggs", "Groceries"), "Eggs")
        XCTAssertEqual(converted("groceries\r\nEggs\r\n", "Groceries"), "Eggs\n")
        XCTAssertEqual(converted("Plans 1/2\nEggs", "Plans 1-2"), "Eggs")
        // Cut short for the file's name: the line says more, so it stays.
        XCTAssertEqual(converted("A very long first line that Notes cut\nEggs", "A very long first line"), "A very long first line that Notes cut\nEggs")
        XCTAssertEqual(converted("Eggs\nMilk", "Groceries"), "Eggs\nMilk")
        XCTAssertEqual(converted("---\ntitle: Groceries\n---\nEggs", "Groceries"), "---\ntitle: Groceries\n---\nEggs")
    }

    func testLinkAddressesAreReadAsNotesWritesThem() {
        var asked: [String] = []
        let text = """
        ![a](Attachments/One%20(1).png "Photo")
        [b](<Attachments/Two words.pdf>)
        ![c](Attachments/Three.png)
        [unclosed](Attachments/Four.png
        """
        let converted = AppleNotesImport.convert(text, title: "Other") { address in
            asked.append(address)
            return .asset(".assets/x", isPicture: false)
        }
        XCTAssertEqual(asked, ["Attachments/One%20(1).png", "Attachments/Two words.pdf", "Attachments/Three.png"])
        XCTAssertEqual(converted, "![a](.assets/x)\n![b](.assets/x)\n![c](.assets/x)\n[unclosed](Attachments/Four.png")
    }

    func testFilesWithoutAnExtensionGetOneFromWhatTheyAre() throws {
        let kinds: [(Data, String?)] = [
            (png, "png"), (jpeg, "jpg"), (pdf, "pdf"), (Data("GIF89a......".utf8), "gif"),
            (Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0]), "heic"),
            (Data([0, 0, 0, 0x18] + Array("ftypM4A ".utf8) + [0, 0, 0, 0]), "m4a"),
            (Data("just some text".utf8), nil),
        ]
        for (number, (data, ext)) in kinds.enumerated() {
            let file = base.appendingPathComponent("file\(number)")
            try data.write(to: file)
            XCTAssertEqual(AppleNotesImport.sniffedExtension(of: file), ext, "for \(ext ?? "text")")
        }
    }

    // MARK: - In the window

    /// The import shows in the sidebar, selected, and one Undo takes all of it to the Trash.
    func testImportShowsAndOneUndoTakesItBack() async throws {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
        let loose = base.appendingPathComponent("Errands.md")
        try write("Errands\n- [ ] Post office\n", to: loose)
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        await withCheckedContinuation { done in workspace.readFolders(to: inbox, including: true) { done.resume() } }
        let manager = try XCTUnwrap(window.undoManager)

        workspace.importFromAppleNotes([archive, loose], into: inbox)
        await workspace.changeFiles { _ in }.value
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertTrue(exists(folder.appendingPathComponent("Trip to Kyoto.md")))
        XCTAssertTrue(exists(inbox.appendingPathComponent("Errands.md")))
        let names = workspace.node(for: inbox, reading: false)?.children?.map(\.name) ?? []
        XCTAssertTrue(names.contains("Archive") && names.contains("Errands"), "not in the sidebar: \(names)")
        XCTAssertEqual(manager.undoActionName, "Import")

        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("taken back") { !self.exists(folder) && !self.exists(self.inbox.appendingPathComponent("Errands.md")) }
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(exists(archive.appendingPathComponent("Trip to Kyoto.md")), "the export was touched")
    }

    private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
