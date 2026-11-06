import AppKit
import XCTest
@testable import NotebookKit

/// Quick Look shows a note as Notebook does: with the app's own editor, in the look set in Notebook's settings, for
/// every kind of note Notebook opens. What changes in how Notebook shows notes changes in Quick Look with it.
@MainActor
final class QuickLookTests: XCTestCase {
    private var folder: URL!
    private var group: UserDefaults!
    private var kept: (Typography, NotebookSettings.HeadingMarks)!

    private let note = """
    A plain first line, where the app's caret is.

    # Kyoto trip

    Five days in **October**, with *a little* `code`, ==highlights== and ~~plans~~, see [[Budget]].

    ## Packing
    - [x] Passport
    - [ ] Power adapter
      - Type A

    > Quiet temples early in the morning.

    | Day | Where |
    | --- | --- |
    | 1 | Gion |

    $$e^{i\\pi} + 1 = 0$$

    ```swift
    let trip = "Kyoto"
    ```
    """

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-quicklook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = NotebookSettings.shared
        kept = (settings.typography, settings.headingMarks)
        group = TestRun.settings()
        NotebookSettings.groupDefaults = group
    }

    override func tearDown() async throws {
        NotebookSettings.shared.typography = kept.0
        NotebookSettings.shared.headingMarks = kept.1
        NotebookSettings.groupDefaults = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// The preview is the app's editor, read only: a note comes out in it with the same text, fonts, colours and
    /// spacing as in the app, and nothing styles it for Quick Look alone.
    func testThePreviewSetsANoteAsTheAppDoes() async throws {
        let url = folder.appendingPathComponent("Kyoto trip.md")
        try note.write(to: url, atomically: true, encoding: .utf8)
        // [[Budget]] is next to the note, as the app's finds it.
        try "# Budget\nFlights €1,240".write(to: folder.appendingPathComponent("Budget.md"), atomically: true, encoding: .utf8)
        let app = EditorHarness(note)
        let preview = NotePreview()
        try await preview.show(url)

        XCTAssertEqual(preview.editor.text, app.editor.text)
        XCTAssertEqual(preview.editor.titleText, "Kyoto trip")
        XCTAssertEqual(preview.editor.metaText, Workspace.meta(modified: NoteDocument.modificationDate(url)), "the line under the title, as the app writes it")
        XCTAssertTrue(preview.editor.metaText.hasPrefix("Edited "))
        assertSameLook(preview.editor.storage, app.editor.storage)
    }

    /// A folder slow to read doesn't hold Quick Look up: the note shows at once, with its picture by its name, and the
    /// picture comes once the folder could be read.
    func testTheNoteShowsWhileItsFolderIsRead() async throws {
        let url = folder.appendingPathComponent("Kyoto trip.md")
        try "Gates at dawn.\n\n![[torii.png]]\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EditorHarness("").folder.appendingPathComponent(".assets/torii.png"),
                                         to: folder.appendingPathComponent(".assets/torii.png"))
        NotePreview.readingDelay = 1.5
        defer { NotePreview.readingDelay = 0 }

        let preview = NotePreview()
        let started = Date()
        try await preview.show(url)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the note shows before its folder is read")
        XCTAssertEqual(preview.editor.text, "Gates at dawn.\n\n![[torii.png]]\n")
        XCTAssertNil(picture(in: preview), "the picture by its name meanwhile")

        try await TestRun.wait(while: { picture(in: preview) == nil })
        XCTAssertEqual(picture(in: preview)?.lastPathComponent, "torii.png")
    }

    /// Where Quick Look can't read the note's folder, as on the Mac, iPhone and iPad, a `[[link]]` shows as a link: what
    /// it names may well be there. Once the folder could be read, a link to nothing in it shows as a note still to be
    /// made, as in the app.
    func testLinksShowAsLinksWhileTheFolderIsOutOfReach() async throws {
        let url = folder.appendingPathComponent("Kyoto trip.md")
        try "Costs are in [[Budget]].\n".write(to: url, atomically: true, encoding: .utf8)
        NotePreview.readingDelay = 1.5
        defer { NotePreview.readingDelay = 0 }

        let preview = NotePreview()
        try await preview.show(url)
        XCTAssertEqual(link(in: preview), .chip(resolved: true), "a link while the folder can't be read")

        try await TestRun.wait(while: { link(in: preview) == .chip(resolved: true) })
        XCTAssertEqual(link(in: preview), .chip(resolved: false), "no Budget next to the note")
    }

    /// On the Mac, a note in one of Notebook's locations is read through the app's bookmark to the location: the
    /// innermost folder kept that the note is in, and none for a note elsewhere. The app keeps them (LocationTests).
    func testQuickLookOpensTheLocationTheNoteIsIn() throws {
        let library = folder.appendingPathComponent("Library")
        let inner = library.appendingPathComponent("Shared")
        for made in [library.appendingPathComponent("Travel"), inner] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        QuickLookAccess.keep(QuickLookAccess.bookmarks(for: [library, inner]), in: group)
        func opened(_ path: String) -> String? {
            QuickLookAccess.open(for: folder.appendingPathComponent(path), in: group)?.resolvingSymlinksInPath().path
        }
        XCTAssertEqual(opened("Library/Travel/Kyoto trip.md"), library.resolvingSymlinksInPath().path)
        XCTAssertEqual(opened("Library/Shared/Plan.md"), inner.resolvingSymlinksInPath().path)
        XCTAssertNil(opened("Elsewhere/Note.md"))
        XCTAssertNil(opened("Library.md"), "a note next to the location isn't in it")
        XCTAssertNil(QuickLookAccess.open(for: library.appendingPathComponent("Travel/Kyoto trip.md"), in: nil), "a build without the App Group")
    }

    /// How the note's `[[Budget]]` shows.
    private func link(in preview: NotePreview) -> Decoration.Kind? {
        let storage = preview.editor.storage
        let at = (storage.string as NSString).range(of: "[[Budget]]").location + 3
        return (storage.attribute(.notebookDecoration, at: at, effectiveRange: nil) as? Decoration)?.kind
    }

    /// The URL of the first picture in the note, once it is found.
    private func picture(in preview: NotePreview) -> URL? {
        var found: URL?
        let storage = preview.editor.storage
        storage.enumerateAttribute(.notebookObject, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if case .image(let url, _, _)? = (value as? EditorObject)?.kind { found = url; stop.pointee = true }
        }
        return found
    }

    /// The app keeps its typeface and heading marks in the App Group as they change, and Quick Look, which has
    /// settings of its own, takes them from there for each note it shows, however long it has been running.
    func testThePreviewTakesTheLookSetInTheApp() async throws {
        let settings = NotebookSettings.shared
        settings.typography = Typography(face: .mono, size: 14, spacing: .compact, width: .narrow)
        settings.headingMarks = .inline
        XCTAssertEqual(group.data(forKey: "typography"), UserDefaults.standard.data(forKey: "typography"), "the app keeps its look in the App Group")
        XCTAssertEqual(group.string(forKey: "headingMarks"), "inline")

        // Set otherwise in Notebook while Quick Look's extension kept running.
        let set = Typography(face: .serif, size: 19, spacing: .relaxed, width: .wide)
        group.set(try JSONEncoder().encode(set), forKey: "typography")
        group.set("margin", forKey: "headingMarks")

        let url = folder.appendingPathComponent("Kyoto trip.md")
        try note.write(to: url, atomically: true, encoding: .utf8)
        let preview = NotePreview()
        try await preview.show(url)
        XCTAssertEqual(settings.typography, set)
        XCTAssertEqual(settings.headingMarks, .margin)
        let first = try XCTUnwrap(preview.editor.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(first.pointSize, 19)
        XCTAssertEqual(first.fontName, Typography.Face.serif.font(19).fontName, "in New York, as set in the app")

        // And a look set back to how Notebook starts is taken out of Quick Look's settings too.
        group.removeObject(forKey: "typography")
        _ = NotePreview()
        XCTAssertEqual(settings.typography, Typography())
    }

    /// Quick Look is asked for the kinds of files the extensions claim in their Info.plists, which has to be every kind
    /// Notebook opens as a note: a kind of note the app learns to open is shown in Quick Look, and has a thumbnail, too.
    func testQuickLookClaimsEveryKindOfNote() throws {
        let config = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Config")
        func plist(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: config.appendingPathComponent(name))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let types = try XCTUnwrap(plist("Info.plist")["CFBundleDocumentTypes"] as? [[String: Any]])
        let notes = Set(types.filter { $0["CFBundleTypeRole"] as? String == "Editor" }.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertFalse(notes.isEmpty)
        for name in ["QuickLook-Info.plist", "Thumbnail-Info.plist"] {
            let extensionInfo = try XCTUnwrap(plist(name)["NSExtension"] as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let claimed = Set(try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String]))
            XCTAssertEqual(claimed, notes, "Config/\(name) claims the kinds of notes Config/Info.plist opens")
        }
    }

    // MARK: - Thumbnails

    /// A note's thumbnail is the top of it set by the app's editor: the same text, fonts, colours and spacing as in the
    /// app, under its title, on a page about the shape of a sheet of paper.
    func testTheThumbnailSetsANoteAsTheAppDoes() async throws {
        let url = folder.appendingPathComponent("Kyoto trip.md")
        try note.write(to: url, atomically: true, encoding: .utf8)
        try "# Budget\nFlights €1,240".write(to: folder.appendingPathComponent("Budget.md"), atomically: true, encoding: .utf8)
        let app = EditorHarness(note)
        let size = NoteThumbnail.size(fitting: CGSize(width: 256, height: 256))
        XCTAssertEqual(size, CGSize(width: 197, height: 256))
        let (image, editor) = try await NoteThumbnail.page(of: url, size: size, scale: 2)

        XCTAssertEqual(image.width, 394)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(editor.text, app.editor.text)
        XCTAssertEqual(editor.titleText, "Kyoto trip")
        assertSameLook(editor.storage, app.editor.storage)
        // Drawn: white paper, with the title's ink near the top.
        let pixels = try bitmap(image)
        XCTAssertEqual(pixels.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0, 1, accuracy: 0.02)
        let title = (0..<pixels.pixelsWide).flatMap { x in (20..<70).map { (x, $0) } }
        XCTAssertTrue(title.contains { pixels.colorAt(x: $0.0, y: $0.1).map { $0.usingColorSpace(.sRGB)!.brightnessComponent < 0.4 } ?? false })
    }

    /// An AsciiDoc note is read as AsciiDoc in its preview and its thumbnail, as the app reads it.
    func testAnAsciiDocNoteIsSetAsTheAppSetsIt() async throws {
        let text = "A plain first line, where the app's caret is.\n\n== Sync\n\nNOTE: Nothing is -- ever -- lost.\n\n* one\n** two\n\n[cols=\"1,2\"]\n|===\n| A | B\n|===\n"
        let url = folder.appendingPathComponent("Sync.adoc")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let app = EditorHarness(text, syntax: .asciidoc)
        let preview = NotePreview()
        try await preview.show(url)
        XCTAssertEqual(preview.editor.syntax, .asciidoc)
        assertSameLook(preview.editor.storage, app.editor.storage)
        let (_, editor) = try await NoteThumbnail.page(of: url, size: NoteThumbnail.size(fitting: CGSize(width: 256, height: 256)), scale: 2)
        XCTAssertEqual(editor.syntax, .asciidoc)
        assertSameLook(editor.storage, app.editor.storage)
    }

    /// The Finder asks for thumbnails as you scroll by, so a thumbnail reads the note and nothing next to it, even where
    /// it could: its pictures show by their names, and the notes and files it links to by theirs, still as links.
    func testTheThumbnailReadsOnlyTheNote() async throws {
        let url = folder.appendingPathComponent("Kyoto trip.md")
        try """
        Gates at dawn, see [[Budget]] and [[Tickets.pdf]].

        ![[torii.png]]

        ![](.assets/rail%20pass.png)

        ![[Tickets.pdf]]

        ![[Budget]]
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EditorHarness("").folder.appendingPathComponent(".assets/torii.png"),
                                         to: folder.appendingPathComponent(".assets/torii.png"))
        try "# Budget\nFlights €1,240".write(to: folder.appendingPathComponent("Budget.md"), atomically: true, encoding: .utf8)
        NotePreview.readingDelay = 30
        defer { NotePreview.readingDelay = 0 }

        let started = Date()
        let (image, editor) = try await NoteThumbnail.page(of: url, size: NoteThumbnail.size(fitting: CGSize(width: 256, height: 256)), scale: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the folder isn't read")
        XCTAssertNil(editor.folder)
        XCTAssertTrue(editor.isFolderOutOfReach, "nothing next to the note is read to draw it")
        let storage = editor.storage
        var objects: [EditorObject.Kind] = []
        storage.enumerateAttribute(.notebookObject, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let object = value as? EditorObject {
                switch object.kind {
                case .image, .fileCard, .noteEmbed: objects.append(object.kind)
                default: break
                }
            }
        }
        XCTAssertEqual(objects.map { "\($0)" }, [
            "\(EditorObject.Kind.image(url: nil, source: "torii.png", inline: false))",
            "\(EditorObject.Kind.image(url: nil, source: ".assets/rail%20pass.png", inline: false))",
            "\(EditorObject.Kind.noteEmbed(target: "Tickets.pdf", url: nil))",
            "\(EditorObject.Kind.noteEmbed(target: "Budget", url: nil))",
        ])
        for name in ["Budget", "Tickets.pdf"] {
            let link = (storage.string as NSString).range(of: name)
            XCTAssertEqual(describe(storage.attribute(.foregroundColor, at: link.location, effectiveRange: nil)!), describe(Theme.accent), "\(name) as a link, not a missing note")
        }
    }

    /// A long note isn't laid out to its end for its thumbnail: only what is more than enough for its top.
    func testTheThumbnailReadsTheTopOfALongNote() async throws {
        let url = folder.appendingPathComponent("Diary.md")
        let lines = (1...4000).map { "Day \($0): walked along the river and wrote it down." }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let (_, editor) = try await NoteThumbnail.page(of: url, size: NoteThumbnail.size(fitting: CGSize(width: 512, height: 512)), scale: 2)
        XCTAssertTrue(editor.text.hasPrefix(lines.prefix(100).joined(separator: "\n")))
        XCTAssertLessThan((editor.text as NSString).length, NoteThumbnail.length + 100)
        XCTAssertTrue(editor.text.hasSuffix("\n"), "cut at the end of a line")
    }

    private func bitmap(_ image: CGImage) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: image)
    }

    /// Every character in the same font, colour and paragraph style, with the same marks and objects.
    private func assertSameLook(_ preview: NSAttributedString, _ app: NSAttributedString, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(preview.string, app.string, file: file, line: line)
        var differences: [String] = []
        app.enumerateAttributes(in: NSRange(location: 0, length: app.length)) { attributes, range, _ in
            var shown = NSRange()
            let other = preview.attributes(at: range.location, longestEffectiveRange: &shown, in: range)
            for key in Set(attributes.keys).union(other.keys) {
                let a = attributes[key].map(describe)
                let b = other[key].map(describe)
                if a != b || shown != range {
                    differences.append("\(key.rawValue) at \(range): app \(a ?? "none"), preview \(b ?? "none")")
                }
            }
        }
        XCTAssertTrue(differences.isEmpty, differences.prefix(8).joined(separator: "\n"), file: file, line: line)
    }

    /// An attribute by what it says rather than which object it is: each editor makes its decorations, objects, links
    /// and some colours of its own.
    private func describe(_ value: Any) -> String {
        if let color = value as? NSColor {
            // Colours made for light and dark as they are asked for: by how they come out in each.
            return [NSAppearance.Name.aqua, .darkAqua].map { name in
                var resolved = color
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
                return "\(resolved)"
            }.joined(separator: " / ")
        }
        guard let kind = Mirror(reflecting: value).children.first(where: { $0.label == "kind" })?.value else { return "\(value)" }
        return "\(type(of: value))(\(kind))"
    }
}
