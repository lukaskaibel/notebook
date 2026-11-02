import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import NotebookKit

/// Copy File (⇧⌘C, the sidebar's menu, ⌘C in the sidebar): the file itself goes on the pasteboard as the Finder puts it
/// there. Pasted or dropped in a note, a file of the locations goes in as a link to it where it is; a file from
/// elsewhere is copied next to the note, as before.
@MainActor
final class CopyFileTests: XCTestCase {
    private var library: URL!
    private var outside: URL!
    private var trips: URL { library.appendingPathComponent("Trips") }
    private var work: URL { library.appendingPathComponent("Work") }
    private var notes: URL { library.appendingPathComponent("Notes") }
    private var kyoto: URL { trips.appendingPathComponent("Kyoto.jpg") }
    private var otherKyoto: URL { work.appendingPathComponent("Kyoto.jpg") }
    private var railPass: URL { trips.appendingPathComponent("Rail pass.pdf") }
    private var clip: URL { trips.appendingPathComponent("Clip.mov") }
    private var plan: URL { trips.appendingPathComponent("Japan plan.md") }
    private var oddName: URL { trips.appendingPathComponent("Plan #2.pdf") }
    private var index: URL { notes.appendingPathComponent("Index.md") }
    private var window: NSWindow?

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-copy-\(UUID().uuidString)").standardizedFileURL
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-downloads-\(UUID().uuidString)").standardizedFileURL
        for folder in [trips, work, notes, outside!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let picture = Self.pictureData()
        try picture.write(to: kyoto)
        try picture.write(to: otherKyoto)
        try picture.write(to: outside.appendingPathComponent("Photo.png"))
        try Data("%PDF-1.4".utf8).write(to: railPass)
        try Data("%PDF-1.4".utf8).write(to: oddName)
        try Data(repeating: 0, count: 64).write(to: clip)
        try "# Japan plan\n".write(to: plan, atomically: true, encoding: .utf8)
        try "Index\n".write(to: index, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        // Copying in the app goes to a pasteboard of the test's own, never the clipboard of whoever runs the tests.
        UserDefaults.standard.set("notebook-copy-test-\(UUID().uuidString)", forKey: "NotebookPasteboard")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "NotebookPasteboard", "expandedFolders", "collapsedSections"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window?.close()
        try? FileManager.default.removeItem(at: library)
        try? FileManager.default.removeItem(at: outside)
    }

    private static func pictureData() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-copy-file-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// The library read and its index built, with the sidebar and `Index` open in one window, as in the app.
    private func makeWindow() async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView!.addSubview(sidebar.scrollView)
        workspace.editor.view.frame = NSRect(x: 260, y: 0, width: 640, height: 600)
        window.contentView!.addSubview(workspace.editor.view)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        for folder in [trips, work, notes] {
            await withCheckedContinuation { done in workspace.readFolders(to: folder, including: true) { done.resume() } }
        }
        try await until("the index was built") { workspace.index.hasBuilt && !workspace.index.isBuilding && workspace.index.entry(for: kyoto) != nil }
        workspace.open(index)
        try await until("open") { workspace.note?.isLoaded == true }
        workspace.editor.setSelection(NSRange(location: workspace.editor.text.utf16.count, length: 0))
        return (workspace, sidebar)
    }

    private func until(_ what: String, seconds: Double = TestRun.patience, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func paste(_ url: URL, in workspace: Workspace) -> String {
        let pasteboard = pasteboard()
        Workspace.writeFile(url, to: pasteboard)
        XCTAssertTrue(workspace.editor.paste(from: pasteboard, at: nil))
        return workspace.editor.text
    }

    // MARK: - What is copied

    /// As the Finder copies a file: its address, which the Finder, Mail and Messages take, and its name as text. A
    /// picture comes as the picture too, as it is in its file and as TIFF, for apps that only take pictures.
    func testCopiedPictureIsTheFileAndThePicture() throws {
        let pasteboard = pasteboard()
        Workspace.writeFile(kyoto, to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [kyoto])
        XCTAssertEqual(pasteboard.string(forType: .string), "Kyoto.jpg")
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), try Data(contentsOf: kyoto),
                       "the picture as it is in its file")
        XCTAssertNotNil(pasteboard.data(forType: .tiff).flatMap(NSImage.init(data:)), "and as a picture every Mac app takes")
    }

    /// Any other file, a video as well as a folder, is its address only: nothing of it is read to copy it.
    func testCopiedVideoAndFolderAreTheirAddresses() throws {
        for url in [clip, trips] {
            let pasteboard = pasteboard()
            Workspace.writeFile(url, to: pasteboard)
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            XCTAssertEqual(urls?.map(\.standardizedFileURL), [url.standardizedFileURL])
            XCTAssertNil(pasteboard.availableType(from: [.tiff]), "no picture of \(url.lastPathComponent)")
        }
    }

    // MARK: - Pasted in a note

    /// A picture, a PDF and a video of the locations go in as links to them where they are, shown as the note's own
    /// pictures and cards are; a note as a link in the line. Nothing is copied next to the note.
    func testFilesOfTheLocationsGoInAsLinks() async throws {
        let (workspace, _) = try await makeWindow()
        XCTAssertTrue(paste(kyoto, in: workspace).contains("\n![[Kyoto.jpg]]"), workspace.editor.text)
        XCTAssertTrue(paste(railPass, in: workspace).contains("\n![[Rail pass.pdf]]"), workspace.editor.text)
        XCTAssertTrue(paste(clip, in: workspace).contains("\n![[Clip.mov]]"), workspace.editor.text)
        workspace.editor.setSelection(NSRange(location: 5, length: 0))
        XCTAssertTrue(paste(plan, in: workspace).hasPrefix("Index[[Japan plan]]"), workspace.editor.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent(".assets").path), "nothing copied")

        let text = workspace.editor.text as NSString
        let picture = workspace.editor.layoutManager.object(at: text.range(of: "![[Kyoto.jpg]]").location)
        guard case .image(let url, _, _) = picture?.kind else { return XCTFail("shown as a picture: \(String(describing: picture?.kind))") }
        XCTAssertEqual(url?.standardizedFileURL, kyoto, "the picture where it is")
        let card = workspace.editor.layoutManager.object(at: text.range(of: "![[Clip.mov]]").location)
        guard case .fileCard(let cardURL, _) = card?.kind else { return XCTFail("shown as a card: \(String(describing: card?.kind))") }
        XCTAssertEqual(cardURL?.standardizedFileURL, clip)
    }

    /// A link pasted right after a picture goes on a line of its own: on the picture's line, it would be text.
    func testLinkAfterAPictureGoesOnItsOwnLine() async throws {
        let (workspace, _) = try await makeWindow()
        _ = paste(railPass, in: workspace)
        XCTAssertTrue(paste(plan, in: workspace).hasSuffix("\n![[Rail pass.pdf]]\n[[Japan plan]]"), workspace.editor.text)
        let text = workspace.editor.text as NSString
        XCTAssertNotNil(workspace.editor.layoutManager.object(at: text.range(of: "![[Rail pass.pdf]]").location), "still a card")
    }

    /// Of two pictures with one name, the one `[[Kyoto.jpg]]` doesn't find gets its folder in front.
    func testLinkHasTheFoldersItTakes() async throws {
        let (workspace, _) = try await makeWindow()
        XCTAssertTrue(paste(otherKyoto, in: workspace).contains("![[Work/Kyoto.jpg]]"), workspace.editor.text)
        XCTAssertEqual(workspace.index.resolve("Work/Kyoto.jpg", from: index)?.standardizedFileURL, otherKyoto)
    }

    /// A name `[[` would read as a heading, and a folder, which `[[` doesn't find, go in as Markdown links to them.
    func testOddNamesAndFoldersGoInAsMarkdownLinks() async throws {
        let (workspace, _) = try await makeWindow()
        XCTAssertTrue(paste(oddName, in: workspace).contains("![Plan #2.pdf](../Trips/Plan%20%232.pdf)"), workspace.editor.text)
        XCTAssertTrue(paste(trips, in: workspace).contains("[Trips](../Trips/)"), workspace.editor.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent(".assets").path), "nothing copied")
    }

    /// A file from elsewhere, such as Downloads, which gets emptied, is copied next to the note, as before; so is a
    /// file of the locations dropped with Option held.
    func testFilesFromElsewhereAndOptionDropsAreCopied() async throws {
        let (workspace, _) = try await makeWindow()
        XCTAssertTrue(paste(outside.appendingPathComponent("Photo.png"), in: workspace).contains("![](.assets/Photo.png)"), workspace.editor.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent(".assets/Photo.png").path))
        XCTAssertTrue(workspace.editor.pasteFiles([kyoto], at: workspace.editor.selection, linking: false))
        XCTAssertTrue(workspace.editor.text.contains("![](.assets/Kyoto.jpg)"), workspace.editor.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent(".assets/Kyoto.jpg").path))
    }

    /// A note's own pictures in `.assets` stay its own, and those of another note's `.assets`, which links don't find,
    /// are copied.
    func testPicturesInAssetsAreNotLinked() async throws {
        let (workspace, _) = try await makeWindow()
        let assets = trips.appendingPathComponent(".assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.pictureData().write(to: assets.appendingPathComponent("Torii.png"))
        XCTAssertNil(workspace.libraryLink(to: assets.appendingPathComponent("Torii.png"), from: index))
        XCTAssertTrue(paste(assets.appendingPathComponent("Torii.png"), in: workspace).contains("![](.assets/Torii.png)"), workspace.editor.text)
    }

    // MARK: - Where it is asked for

    /// The sidebar's menu has Copy, with the Edit menu's key, which never runs the menu's items for the row clicked
    /// before. ⇧⌘C copies the file selected in the sidebar while it has the keyboard, else the file open; ⌘C there
    /// copies the selected one. Each says so in a capsule.
    func testSidebarMenuAndKeysCopyTheFile() async throws {
        let (workspace, sidebar) = try await makeWindow()
        workspace.reveal(railPass, select: true)
        try await until("selected") { sidebar.selectedURL?.standardizedFileURL == railPass }
        let menu = NSMenu()
        sidebar.fill(menu, row: sidebar.outline.selectedRow)
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy “Rail pass.pdf”" })
        XCTAssertEqual(copy.keyEquivalent, "c")
        XCTAssertEqual(copy.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertLessThan(menu.index(of: copy), menu.indexOfItem(withTitle: "Copy Link"))
        var target: AnyObject?
        var action: Selector?
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertFalse(sidebar.menuHasKeyEquivalent(menu, for: key, target: &target, action: &action))

        window?.makeFirstResponder(workspace.editor.textView)
        XCTAssertEqual(workspace.fileToCopy?.standardizedFileURL, workspace.currentURL?.standardizedFileURL, "the file open")
        window?.makeFirstResponder(sidebar.outline)
        XCTAssertEqual(workspace.fileToCopy?.standardizedFileURL, railPass, "the file selected in the sidebar")
        XCTAssertTrue(sidebar.outline.validateUserInterfaceItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))

        sidebar.outline.copy(nil)
        XCTAssertNotEqual(appPasteboard, .general)
        let urls = appPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [railPass])
        XCTAssertEqual(workspace.copied.file?.name, "Rail pass.pdf", "the capsule says so")
    }
}
