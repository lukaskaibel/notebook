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
    /// Kept for the test: the workspace holds its sidebar weakly, and finds the window's undo manager through it.
    private var sidebar: SidebarController?

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
        // Folders and files a test made unreadable or unwritable, back as they were, to be deleted.
        if let enumerator = FileManager.default.enumerator(atPath: base.path) {
            for case let path as String in enumerator { chmod(base.appendingPathComponent(path).path, 0o755) }
        }
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

    // MARK: - What the review found

    func testAFolderThatHasTheTargetInItIsRefused() throws {
        let before = try FileManager.default.subpathsOfDirectory(atPath: export.path).sorted()
        let result = AppleNotesImport.run([export], into: archive)
        XCTAssertEqual(result.made, [nil])
        XCTAssertEqual(result.problems, ["Export: the folder the notes go into is in it"])
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: export.path).sorted(), before, "written into the export")
    }

    func testNotesWhoseNamesStartWithADotComeAlong() throws {
        try write(".NET plans\nPort it.\n", to: archive.appendingPathComponent(".NET plans.md"))
        try Data().write(to: archive.appendingPathComponent(".DS_Store"))
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/NET plans.md")), "Port it.\n")
        XCTAssertFalse(exists(inbox.appendingPathComponent("Archive/DS_Store")), "the Finder's file came along")
    }

    func testAFolderOfYoursCalledAttachmentsIsAFolder() throws {
        let tree = base.appendingPathComponent("From Notes")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try write("Bills\nGas, water.\n", to: tree.appendingPathComponent("Attachments/Bills.md"))
        try FileManager.default.moveItem(at: archive, to: tree.appendingPathComponent("Work"))
        let result = AppleNotesImport.run([tree], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("From Notes/Attachments/Bills.md")), "Gas, water.\n")
        XCTAssertTrue(exists(inbox.appendingPathComponent("From Notes/Work/.assets/IMG_0001.jpeg")))
        XCTAssertEqual(result.problems, [])
    }

    func testWhatCantComeOverIsNamed() throws {
        let tickets = archive.appendingPathComponent("Attachments/Flight tickets.pdf")
        let unused = archive.appendingPathComponent("Attachments/Unused.png")
        chmod(tickets.path, 0)
        chmod(unused.path, 0)
        let result = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(Set(result.problems), [
            "Archive/Attachments/Flight tickets.pdf: couldn’t be copied for “Trip to Kyoto”",
            "Archive/Attachments/Unused.png: couldn’t be copied",
        ])
        // The link stays as Notes wrote it, rather than pointing at nothing.
        XCTAssertTrue(try read(inbox.appendingPathComponent("Archive/Trip to Kyoto.md")).contains("(Attachments/Flight%20tickets.pdf)"))
    }

    func testAFolderThatCantBeMadeIsNamed() throws {
        chmod(inbox.path, 0o555)
        let result = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(result.made, [nil])
        XCTAssertEqual(result.problems, ["Archive: couldn’t be made in “Inbox”, with what is in it"])
    }

    func testEverythingAddedWhereSomethingWasIsListedForUndo() throws {
        let single = export.appendingPathComponent("Pasta")
        try FileManager.default.createDirectory(at: single.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try write("Pasta\n![](Attachments/photo)\n", to: single.appendingPathComponent("Pasta.md"))
        try jpeg.write(to: single.appendingPathComponent("Attachments/photo"))
        try png.write(to: single.appendingPathComponent("Attachments/extra.png"))
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try png.write(to: inbox.appendingPathComponent(".assets/mine.png"))
        let result = AppleNotesImport.run([single, archive], into: inbox)
        XCTAssertEqual(Set(result.added.map(\.lastPathComponent)), ["Pasta.md", "photo.jpg", "extra.png", "Archive"])
        XCTAssertTrue(result.added.contains { $0.path.hasSuffix("Inbox/.assets/photo.jpg") })
    }

    func testNothingThereIsWrittenOver() throws {
        let result = AppleNotesImport.run([archive], into: inbox) {
            // A note of the name comes, from iCloud say, while the import reads the export.
            try? "Mine\n".write(to: self.inbox.appendingPathComponent("Archive/Shopping list.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Shopping list.md")), "Mine\n")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Shopping list 2.md")), "- [ ] Milk\n- [x] Bread\n\n![](.assets/IMG_0001.jpeg)\n")
        XCTAssertTrue(try read(inbox.appendingPathComponent("Archive/Trip to Kyoto.md")).contains("[[Shopping list 2|Shopping list]]"))
        XCTAssertEqual(result.problems, [])
    }

    func testNamesDifferingInCaseDontTakeEachOthersPlace() throws {
        for name in ["Plan", "plan"] {
            let folder = base.appendingPathComponent("\(name) export \(name == "Plan" ? 1 : 2)/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("\(name)\nText of \(name).\n", to: folder.appendingPathComponent("\(name).md"))
        }
        let result = AppleNotesImport.run([base.appendingPathComponent("Plan export 1/Plan"), base.appendingPathComponent("plan export 2/plan")], into: inbox)
        XCTAssertEqual(result.made.map { $0?.lastPathComponent }, ["Plan.md", "plan 2.md"])
        XCTAssertEqual(try read(inbox.appendingPathComponent("Plan.md")), "Text of Plan.\n")
        XCTAssertEqual(try read(inbox.appendingPathComponent("plan 2.md")), "Text of plan.\n")
    }

    func testLinksToNotesFindExactlyThem() throws {
        try write("C# notes\nLINQ.\n", to: archive.appendingPathComponent("C# notes.md"))
        try write("A | B\nTwo ways.\n", to: archive.appendingPathComponent("A | B.md"))
        try write("Recipe:Soup\nLeeks.\n", to: archive.appendingPathComponent("Recipe:Soup.md"))
        try write("""
        Index
        [C# notes](C%23%20notes.md), [A | B](A%20%7C%20B.md), [Soup](Recipe:Soup.md), [Milk](Shopping%20list.md)
        """, to: archive.appendingPathComponent("Index.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Index.md")),
                       "[C# notes](C%23%20notes.md), [A | B](A%20%7C%20B.md), [[Recipe-Soup|Soup]], [[Shopping list|Milk]]")
    }

    func testLinksToNotesInOtherFoldersAreRelative() throws {
        let work = base.appendingPathComponent("Work")
        let home = base.appendingPathComponent("Home")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("Home/Plan"), withIntermediateDirectories: true)
        try write("Plan\nSee [the list](../Home/List.md).\n", to: work.appendingPathComponent("Plan.md"))
        try write("List\nEggs.\n", to: home.appendingPathComponent("List.md"))
        try write("Extra\nMore.\n", to: home.appendingPathComponent("Extra.md"))
        _ = AppleNotesImport.run([work, home], into: inbox)
        // Home was there, so Home's notes are in Home 2, and the link says so.
        XCTAssertEqual(try read(inbox.appendingPathComponent("Work/Plan.md")), "See [the list](../Home%202/List.md).\n")
    }

    func testLinksInCodeStayAsTheyAre() throws {
        try write("""
        Code
        Write `![](Attachments/IMG_0001.jpeg)` for a picture.

        ```
        [Shopping list](Shopping%20list.md)
        ```
        """, to: archive.appendingPathComponent("Code.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Code.md")), """
        Write `![](Attachments/IMG_0001.jpeg)` for a picture.

        ```
        [Shopping list](Shopping%20list.md)
        ```
        """)
    }

    func testLinkedFilesInFoldersOfAttachmentsArentCopiedAgain() throws {
        let sub = archive.appendingPathComponent("Attachments/1A2B")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try png.write(to: sub.appendingPathComponent("scan.png"))
        try png.write(to: sub.appendingPathComponent("other.png"))
        try write("Scan\n![](Attachments/1A2B/scan.png)\n", to: archive.appendingPathComponent("Scan.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertTrue(exists(folder.appendingPathComponent(".assets/scan.png")))
        XCTAssertFalse(exists(folder.appendingPathComponent("1A2B")), "the folder came along whole")
        XCTAssertFalse(exists(folder.appendingPathComponent("scan.png")), "a linked file came along loose too")
        XCTAssertTrue(exists(folder.appendingPathComponent("other.png")))
    }

    // MARK: - What the second look found

    func testAPackageInAttachmentsIsOneFile() throws {
        for name in ["Linked.rtfd", "Loose.rtfd"] {
            let package = archive.appendingPathComponent("Attachments/\(name)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("{\\rtf1 text}".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        }
        try write("Letter\n[Linked.rtfd](Attachments/Linked.rtfd)\n", to: archive.appendingPathComponent("Letter.md"))
        let result = AppleNotesImport.run([archive], into: inbox)
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertTrue(exists(folder.appendingPathComponent(".assets/Linked.rtfd/TXT.rtf")))
        XCTAssertTrue(exists(folder.appendingPathComponent("Loose.rtfd/TXT.rtf")))
        XCTAssertFalse(exists(folder.appendingPathComponent("TXT.rtf")), "a package came apart")
        XCTAssertFalse(exists(folder.appendingPathComponent("Linked.rtfd")), "a linked package came along loose too")
        XCTAssertEqual(result.problems, [])
    }

    func testANameThatFoldsLikeAnotherIsLinkedByItsAddress() throws {
        try write("Resume\nOld one.\n", to: archive.appendingPathComponent("Resume.md"))
        try write("Résumé\nNew one.\n", to: archive.appendingPathComponent("Résumé.md"))
        try write("Jobs\nSee [Résumé](R%C3%A9sum%C3%A9.md).\n", to: archive.appendingPathComponent("Jobs.md"))
        _ = AppleNotesImport.run([archive], into: inbox)
        let text = try read(inbox.appendingPathComponent("Archive/Jobs.md"))
        XCTAssertFalse(text.contains("[["), "[[Résumé]] may find Resume: \(text)")
        XCTAssertEqual(AppleNotesImport.file(String(text.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }), from: inbox.appendingPathComponent("Archive"))?.lastPathComponent,
                       "Résumé.md")
    }

    func testNotesWrittenBeforeANoteTookAnotherNameLinkToItsNewName() throws {
        try write("# Shopping list\n\n- [ ] Milk, for the [trip](Trip%20to%20Kyoto.md)\n", to: archive.appendingPathComponent("Shopping list.md"))
        _ = AppleNotesImport.run([archive], into: inbox) {
            try? "Mine\n".write(to: self.inbox.appendingPathComponent("Archive/Trip to Kyoto.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Shopping list.md")), "- [ ] Milk, for the [[Trip to Kyoto 2|trip]]\n")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Trip to Kyoto.md")), "Mine\n")
    }

    func testAttachmentsWithANoteInItOrWithoutNotesNextToItAreNotes() throws {
        // A note someone attached, in Notes' Attachments.
        try write("Recipe\nFrom a friend.\n", to: archive.appendingPathComponent("Attachments/Recipe.md"))
        try write("Cooking\n[Recipe.md](Attachments/Recipe.md)\n", to: archive.appendingPathComponent("Cooking.md"))
        // Notes in folders, with their Attachments above them.
        let tree = export.appendingPathComponent("Tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try png.write(to: tree.appendingPathComponent("Attachments/pic.png"))
        try write("Plan\n![](../Attachments/pic.png)\n", to: tree.appendingPathComponent("Work/Plan.md"))
        _ = AppleNotesImport.run([archive, tree], into: inbox)
        XCTAssertEqual(try read(inbox.appendingPathComponent("Archive/Cooking.md")), "![Recipe.md](.assets/Recipe.md)\n")
        XCTAssertFalse(exists(inbox.appendingPathComponent("Archive/Attachments")))
        XCTAssertEqual(try read(inbox.appendingPathComponent("Tree/Work/Plan.md")), "![](.assets/pic.png)\n")
        XCTAssertFalse(exists(inbox.appendingPathComponent("Tree/Attachments")))
    }

    // MARK: - In the window

    /// The library read, with the sidebar in a window, whose undo manager keeps the changes to files, as in the app.
    private func makeWindow() async throws -> (Workspace, UndoManager) {
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        self.sidebar = sidebar
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        await withCheckedContinuation { done in workspace.readFolders(to: inbox, including: true) { done.resume() } }
        return (workspace, try XCTUnwrap(window.undoManager))
    }

    /// The import shows in the sidebar, selected, and one Undo takes all of it to the Trash.
    func testImportShowsAndOneUndoTakesItBack() async throws {
        let loose = base.appendingPathComponent("Errands.md")
        try write("Errands\n- [ ] Post office\n", to: loose)
        let (workspace, manager) = try await makeWindow()

        workspace.importFromAppleNotes([archive, loose], into: inbox)
        await workspace.changeFiles { _ in }.value
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertTrue(exists(folder.appendingPathComponent("Trip to Kyoto.md")))
        XCTAssertTrue(exists(inbox.appendingPathComponent("Errands.md")))
        // In the sidebar at once, or once the Inbox has been read again after it.
        try await until("in the sidebar") {
            let names = workspace.node(for: self.inbox, reading: false)?.children?.map(\.name) ?? []
            return names.contains("Archive") && names.contains("Errands")
        }
        XCTAssertEqual(manager.undoActionName, "Import")

        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("taken back") { !self.exists(folder) && !self.exists(self.inbox.appendingPathComponent("Errands.md")) }
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(exists(archive.appendingPathComponent("Trip to Kyoto.md")), "the export was touched")
    }

    /// Undo keeps the order the changes were asked for in: a note made while the import runs goes first.
    func testUndoTakesBackInTheOrderAskedFor() async throws {
        let (workspace, manager) = try await makeWindow()
        workspace.importFromAppleNotes([archive], into: inbox)
        // ⌘N a moment later, while the import is under way: an event of its own.
        try await until("the group closed") { manager.groupingLevel == 0 }
        workspace.newNote(in: inbox, title: "Later")
        await workspace.changeFiles { _ in }.value
        let later = inbox.appendingPathComponent("Later.md")
        let folder = inbox.appendingPathComponent("Archive")
        XCTAssertTrue(exists(later) && exists(folder))

        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("the new note taken back") { !self.exists(later) }
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(exists(folder), "the import went first")
        manager.undo()
        try await until("the import taken back") { !self.exists(folder) }
    }

    /// A note imported on its own into a folder that was there: its picture goes into the folder's own `.assets`, a
    /// file nothing links to next to it, and one Undo takes all three back, leaving what was there.
    func testOneUndoTakesBackWhatWentIntoAFolderThatWasThere() async throws {
        let single = export.appendingPathComponent("Pasta")
        try FileManager.default.createDirectory(at: single.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try write("Pasta\n![](Attachments/photo)\n", to: single.appendingPathComponent("Pasta.md"))
        try jpeg.write(to: single.appendingPathComponent("Attachments/photo"))
        try png.write(to: single.appendingPathComponent("Attachments/extra.png"))
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try png.write(to: inbox.appendingPathComponent(".assets/mine.png"))
        let (workspace, manager) = try await makeWindow()

        workspace.importFromAppleNotes([single], into: inbox)
        await workspace.changeFiles { _ in }.value
        let added = ["Pasta.md", ".assets/photo.jpg", "extra.png"].map { inbox.appendingPathComponent($0) }
        XCTAssertTrue(added.allSatisfy(exists), "not all there")

        try await until("the group closed") { manager.groupingLevel == 0 }
        manager.undo()
        try await until("taken back") { !added.contains(where: self.exists) }
        await workspace.changeFiles { _ in }.value
        XCTAssertTrue(exists(inbox.appendingPathComponent(".assets/mine.png")), "a picture that was there went too")
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
