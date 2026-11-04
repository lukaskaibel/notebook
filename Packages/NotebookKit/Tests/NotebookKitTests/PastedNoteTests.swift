import AppKit
import XCTest
@testable import NotebookKit

/// A Markdown file's contents pasted whole: its `# Heading` is the note's title, pasted in the title or in an empty
/// note, and the rest its text. Pasted in the title, more than a line goes on into the note.
@MainActor
final class PastedNoteTests: XCTestCase {
    override func setUp() {
        // Pasting in the tests goes through a pasteboard of their own, never the clipboard of whoever runs them.
        UserDefaults.standard.set("notebook-paste-test-\(UUID().uuidString)", forKey: "NotebookPasteboard")
        appPasteboard.clearContents()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "NotebookPasteboard")
    }

    private func copy(_ string: String) {
        appPasteboard.clearContents()
        appPasteboard.setString(string, forType: .string)
    }

    /// A new note: its title empty, showing "Untitled", and nothing typed in it.
    private func newNote(_ text: String = "") -> EditorHarness {
        let h = EditorHarness("")
        h.editor.load(text: text, folder: h.folder, title: "", meta: "")
        h.settle()
        return h
    }

    // MARK: - Reading a document

    func testADocumentGivesItsHeadingAndTheRest() {
        let pasted = PastedNote(document: "# Kyoto trip\n\nFlights booked.\n\n## Day one\nTemples\n")
        XCTAssertEqual(pasted, PastedNote(title: "Kyoto trip", text: "Flights booked.\n\n## Day one\nTemples\n"))
    }

    func testLinesBeforeTheHeadingAndClosingHashesDontCount() {
        XCTAssertEqual(PastedNote(document: "\n  \n# Kyoto #\nText"), PastedNote(title: "Kyoto", text: "Text"))
        XCTAssertEqual(PastedNote(document: "# Kyoto\r\n\r\nText\r\n"), PastedNote(title: "Kyoto", text: "Text\n"), "Windows line breaks")
    }

    func testFrontMatterStaysAtTheTop() {
        XCTAssertEqual(PastedNote(document: "---\ntags: travel\n---\n\n# Kyoto\n\nText"), PastedNote(title: "Kyoto", text: "---\ntags: travel\n---\nText"))
    }

    func testOnlyATitleHeadingWithTextAfterItMakesADocument() {
        XCTAssertNil(PastedNote(document: "## Day one\nTemples"), "a section's heading")
        XCTAssertNil(PastedNote(document: "Notes\n# Kyoto\nText"), "a heading further down")
        XCTAssertNil(PastedNote(document: "# Kyoto\n\n"), "a heading by itself")
        XCTAssertNil(PastedNote(document: "#Kyoto\nText"), "not a heading")
        XCTAssertNil(PastedNote(document: "```\n# Kyoto\n```"), "code")
    }

    func testForTheTitleTheFirstLineAsItReads() {
        XCTAssertEqual(PastedNote(forTitle: "Kyoto"), PastedNote(title: "Kyoto", text: ""))
        XCTAssertEqual(PastedNote(forTitle: "## Kyoto"), PastedNote(title: "Kyoto", text: ""))
        XCTAssertEqual(PastedNote(forTitle: "# Kyoto"), PastedNote(title: "Kyoto", text: ""))
        XCTAssertEqual(PastedNote(forTitle: "Kyoto trip\nFlights\nHotel"), PastedNote(title: "Kyoto trip", text: "Flights\nHotel"))
        XCTAssertEqual(PastedNote(forTitle: "- Flights\n- Hotel"), PastedNote(title: "Flights", text: "- Hotel"))
        XCTAssertEqual(PastedNote(forTitle: "\n\n"), PastedNote(title: "", text: ""))
    }

    // MARK: - In the text

    func testADocumentPastedInANewNoteNamesIt() {
        let h = newNote()
        copy("# Kyoto trip\n\nFlights booked.\n- Hotel")
        h.textView.paste(nil)
        XCTAssertEqual(h.text, "Flights booked.\n- Hotel")
        XCTAssertEqual(h.editor.titleText, "Kyoto trip")
        XCTAssertEqual(h.committedTitles, ["Kyoto trip"], "the note is renamed")
        XCTAssertEqual(h.selection, NSRange(location: (h.text as NSString).length, length: 0))
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, "", "one Undo takes it back")
    }

    func testANoteStillCalledUntitledIsNamedToo() {
        let h = EditorHarness("")
        h.editor.load(text: "\n", folder: h.folder, title: "Untitled 2", meta: "")
        h.settle()
        copy("# Kyoto trip\nFlights")
        h.textView.paste(nil)
        XCTAssertEqual(h.editor.titleText, "Kyoto trip")
        XCTAssertEqual(h.text, "Flights")
    }

    func testANamedNoteKeepsItsNameAndLeavesTheHeadingOut() {
        let h = EditorHarness("")
        copy("# Osaka\n\nFlights booked.")
        h.textView.paste(nil)
        XCTAssertEqual(h.editor.titleText, "Kyoto trip")
        XCTAssertEqual(h.committedTitles, [])
        XCTAssertEqual(h.text, "Flights booked.")
    }

    func testADocumentPastedAmongOtherTextStaysAsItIs() {
        let h = EditorHarness("Plans")
        h.caret(5)
        copy("\n# Osaka\nFlights")
        h.textView.paste(nil)
        XCTAssertEqual(h.text, "Plans\n# Osaka\nFlights")
        XCTAssertEqual(h.editor.titleText, "Kyoto trip")
    }

    func testOverTheWholeTextItIsAWholeNote() {
        let h = newNote("Draft")
        h.select(NSRange(location: 0, length: 5))
        copy("# Osaka\nFlights")
        h.textView.paste(nil)
        XCTAssertEqual(h.text, "Flights")
        XCTAssertEqual(h.editor.titleText, "Osaka")
    }

    func testTextCopiedInNotebookCountsToo() throws {
        let h = newNote()
        let fragment = try JSONSerialization.data(withJSONObject: ["markdown": "# Osaka\nFlights", "folder": h.folder.path])
        appPasteboard.clearContents()
        appPasteboard.setString("# Osaka\nFlights", forType: .string)
        appPasteboard.setData(fragment, forType: EditorController.fragmentType)
        h.textView.paste(nil)
        XCTAssertEqual(h.text, "Flights")
        XCTAssertEqual(h.editor.titleText, "Osaka")
    }

    // MARK: - In the title

    private func pasteInTitle(_ h: EditorHarness, _ string: String) throws -> NSTextView {
        h.editor.focusTitle()
        h.settle(0)
        let field = try XCTUnwrap(h.textView.titleField.currentEditor() as? NSTextView)
        XCTAssertTrue(field is TitleFieldEditor)
        copy(string)
        field.paste(nil)
        h.settle(0)
        return field
    }

    func testADocumentPastedInTheTitleGoesOnIntoTheNote() throws {
        let h = newNote()
        _ = try pasteInTitle(h, "# Kyoto trip\n\nFlights booked.\n")
        XCTAssertEqual(h.editor.titleText, "Kyoto trip")
        XCTAssertEqual(h.text, "Flights booked.\n")
        XCTAssertFalse(h.editor.isEditingTitle, "the caret goes on into the text")
        XCTAssertTrue(h.editor.isFocused)
        XCTAssertEqual(h.selection, NSRange(location: (h.text as NSString).length, length: 0))
        XCTAssertTrue(h.committedTitles.contains("Kyoto trip"))
    }

    func testLinesPastedInTheTitleGoBeforeTheText() throws {
        let h = EditorHarness("Hotel")
        _ = try pasteInTitle(h, "Osaka\nFlights\n")
        XCTAssertEqual(h.editor.titleText, "Osaka", "over the title, which was all selected")
        XCTAssertEqual(h.text, "Flights\nHotel")
        XCTAssertEqual(h.selection, NSRange(location: 7, length: 0), "after what was pasted")
    }

    func testLinesPastedInTheTitleGoAfterFrontMatter() throws {
        let h = EditorHarness("---\ntags: travel\n---\nHotel")
        _ = try pasteInTitle(h, "Osaka\nFlights")
        XCTAssertEqual(h.text, "---\ntags: travel\n---\nFlights\nHotel")
        XCTAssertEqual(h.selection, NSRange(location: 28, length: 0), "after what was pasted")

        let only = EditorHarness("---\ntags: travel\n---")
        _ = try pasteInTitle(only, "Osaka\nFlights")
        XCTAssertEqual(only.text, "---\ntags: travel\n---\nFlights\n")
    }

    func testALinePastedInTheTitleStaysThere() throws {
        let h = newNote("Hotel")
        let field = try pasteInTitle(h, "## Osaka")
        XCTAssertEqual(h.editor.titleText, "Osaka", "without its #s")
        XCTAssertTrue(h.editor.isEditingTitle)
        XCTAssertEqual(field.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(h.text, "Hotel")
        field.undoManager?.undo()
        XCTAssertEqual(h.editor.titleText, "", "Undo takes it back")
    }
}
