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

    /// A folder the Mac asks about first doesn't hold Quick Look up: the note shows at once, with its picture by its
    /// name, and the picture comes once the folder could be read.
    func testTheNoteShowsWhileItsFolderIsAskedAbout() async throws {
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

    /// Where Quick Look can't read the note's folder, as on iPhone and iPad, a `[[link]]` shows as a link: what it names
    /// may well be there. Once the folder could be read, a link to nothing in it shows as a note still to be made, as in
    /// the app.
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

    /// Quick Look is asked for the kinds of files the extension claims in its Info.plist, which has to be every kind
    /// Notebook opens as a note: a kind of note the app learns to open is shown in Quick Look too.
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
        let extensionInfo = try XCTUnwrap(plist("QuickLook-Info.plist")["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let claimed = Set(try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String]))
        XCTAssertFalse(notes.isEmpty)
        XCTAssertEqual(claimed, notes, "Config/QuickLook-Info.plist claims the kinds of notes Config/Info.plist opens")
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
