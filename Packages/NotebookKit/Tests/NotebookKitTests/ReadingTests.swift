import XCTest
@testable import NotebookKit

/// What VoiceOver reads of a note on iPhone and iPad (#214): each line as it shows, without its Markdown; a to-do with
/// its state, ticked as a tap on its circle ticks it; links, pictures, drawings and a to-do's date of their own.
@MainActor
final class ReadingTests: XCTestCase {
    private func reading(_ text: String) -> (EditorHarness, [ReadingItem]) {
        let h = EditorHarness(text)
        // Nothing being written in: no marks next to a caret.
        h.window.makeFirstResponder(nil)
        h.settle()
        var items = h.editor.readingItems()
        // Last, where writing goes on at the end (`testAnEmptyNoteCanBeWrittenIn`).
        XCTAssertEqual(items.popLast()?.kind, .end)
        return (h, items)
    }

    func testLinesReadAsTheyShow() {
        let (_, items) = reading("""
        ## Packing **list**
        Costs are in [[Budget]], the rest on [the site](https://example.com).
        - Keep it *minimal*
        1. Sweat a shallot
        > Quoted ==words==
        `code` and $x^2$ inline

        """)
        XCTAssertEqual(items.map(\.label), [
            "Packing list", "Costs are in Budget, the rest on the site.", "Budget", "the site", "Keep it minimal",
            "1. Sweat a shallot", "Quoted words", "code and x^2 inline",
        ])
        XCTAssertEqual(items[0].kind, .heading(level: 2))
        XCTAssertEqual(items[1].kind, .text)
        XCTAssertEqual(items[2].kind, .link)
        XCTAssertEqual(items[2].hit, .link(.note("Budget")))
        XCTAssertEqual(items[3].hit, .link(.url("https://example.com")))
        XCTAssertEqual(items[3].actions.map(\.name), ["Edit Link"], "the pencil after a link")
        XCTAssertNil(items[1].hit, "a double-tap on text writes in it")
        XCTAssertEqual(items[1].caret, ("## Packing **list**\nCosts are in [[Budget]], the rest on [the site](https://example.com)." as NSString).length)
    }

    func testALineThatIsOnlyALinkIsTheLink() {
        let (_, items) = reading("https://example.com/an-article\n\nRead this on the train.\n")
        XCTAssertEqual(items.map(\.label), ["https://example.com/an-article", "Read this on the train."])
        XCTAssertEqual(items.map(\.kind), [.link, .text])
    }

    func testToDosSayTheirStateAndTickAsATapDoes() throws {
        let (h, items) = reading("""
        - [ ] Buy milk
        - [x] Pay the bill
        - [/] Renew the passport
        - [-] Sell the bike
        - [ ] Return the books 📅 2020-01-01
        - [ ] Buy plasters 📍 [Pharmacy at Rosenthaler Platz](https://maps.apple.com/?ll=52.5,13.4&q=Pharmacy)
        - [ ]

        """)
        let todos = items.filter { if case .todo = $0.kind { true } else { false } }
        XCTAssertEqual(todos.map(\.label), ["Buy milk", "Pay the bill", "Renew the passport", "Sell the bike", "Return the books", "Buy plasters", "To-do"])
        XCTAssertEqual(todos.map(\.value), ["Not completed", "Completed", "In Progress", "Cancelled", "Not completed", "Not completed", "Not completed"])
        XCTAssertEqual(todos.first?.hit, .checkbox(line: 0), "a double-tap does what a tap on the circle does")
        XCTAssertEqual(todos.first?.caret, ("- [ ] Buy milk" as NSString).length)
        XCTAssertEqual(todos.first?.actions.map(\.name), ["Remind Me"])

        let pills = items.filter { $0.kind == .pill }
        XCTAssertEqual(pills.count, 2)
        XCTAssertTrue(pills[0].label.hasPrefix("Overdue, "), pills[0].label)
        XCTAssertEqual(pills[1].label, "Arriving at Pharmacy at Rosenthaler Platz", "a place whole, though its pill is shortened")
        XCTAssertEqual(pills.first?.hit, .todo(line: 4, part: .date))
        XCTAssertEqual(pills.last?.hit, .todo(line: 5, part: .place))
        XCTAssertEqual(items.firstIndex(of: pills[0]), try XCTUnwrap(items.firstIndex(of: todos[4])) + 1, "the date right after its to-do")

        // Ticked as the circle ticks it: the note, Undo and VoiceOver's words all follow.
        h.editor.toggleCheckbox(line: 0)
        h.settle()
        XCTAssertTrue(h.text.hasPrefix("- [x] Buy milk"))
        XCTAssertEqual(h.editor.readingItems().first?.value, "Completed")
        h.textView.undoManager?.undo()
        h.settle()
        XCTAssertEqual(h.editor.readingItems().first?.value, "Not completed")
    }

    func testPicturesAndDrawingsAreNamed() throws {
        let (h, items) = reading("""
        ![](.assets/torii.png)

        ![The gate at sunrise](.assets/torii.png)

        ![Drawing](.assets/missing%20drawing.png)

        """)
        XCTAssertEqual(items.map(\.label), ["torii", "The gate at sunrise", "Drawing"])
        XCTAssertEqual(items.map(\.kind), [.picture, .picture, .picture], "a drawing without strokes is a picture")
        XCTAssertEqual(items.first?.hit, .picture(range: NSRange(location: 0, length: 22), url: h.folder.appendingPathComponent(".assets/torii.png").standardizedFileURL))
        for item in items { XCTAssertNotNil(h.editor.readingFrame(of: item), item.label) }
    }

    func testBlocksReadAsTheyShow() throws {
        let (h, items) = reading("""
        > [!tip] Good to know
        > Get an ICOCA card.

        | Day | Area |
        | --- | --- |
        | 1 | Fushimi |

        $$
        E = mc^2
        $$

        """)
        XCTAssertEqual(items.map(\.label), ["Tip: Good to know", "Get an ICOCA card.", "Day, Area", "Day: 1, Area: Fushimi", "Formula"])
        XCTAssertEqual(items[2].value, "Table, 2 rows")
        XCTAssertEqual(items[4].value, "E = mc^2")
        if case .block = try XCTUnwrap(items[3].hit) {} else { XCTFail("a row opens the table as a tap on it does") }
        let header = try XCTUnwrap(h.editor.readingFrame(of: items[2]))
        let row = try XCTUnwrap(h.editor.readingFrame(of: items[3]))
        XCTAssertEqual(row.minY, header.maxY, accuracy: 0.5, "each row where it is drawn")
    }

    func testNothingReadsTheMarks() {
        let (_, items) = reading("# Title\n- [ ] [[Budget]] **now**\n---\n> quote\n")
        for item in items {
            for mark in ["#", "[", "]", "*", ">", "-"] { XCTAssertFalse(item.label.contains(mark), "\(item.label) has \(mark)") }
        }
    }

    // MARK: - Writing at the end (#279)

    /// An empty note, or one with only blank lines, has nothing to read: what is left is to write in it.
    func testAnEmptyNoteCanBeWrittenIn() throws {
        for text in ["", "\n\n"] {
            let h = reading(text).0
            let items = h.editor.readingItems()
            XCTAssertEqual(items.map(\.label), ["Write in the note"], text.debugDescription)
            let end = try XCTUnwrap(items.last)
            XCTAssertEqual(end.kind, .end)
            XCTAssertNil(end.hit, "a double-tap writes")
            XCTAssertEqual(end.caret, (text as NSString).length, "at the very end")
            let frame = try XCTUnwrap(h.editor.readingFrame(of: end))
            XCTAssertGreaterThanOrEqual(frame.height, 44, "big enough for a fingertip")
        }
    }

    /// Below a table or a picture at the end there is no line to double-tap: the end is its own.
    func testANoteEndingInATableOrAPictureCanBeWrittenAfterIt() throws {
        for text in ["Days\n\n| Day | Area |\n| --- | --- |\n| 1 | Fushimi |", "The gate\n\n![](.assets/torii.png)\n"] {
            let h = reading(text).0
            let items = h.editor.readingItems()
            let end = try XCTUnwrap(items.last)
            XCTAssertEqual(end.kind, .end, text)
            XCTAssertEqual(end.label, "Write at the end")
            XCTAssertEqual(end.caret, (text as NSString).length)
            let last = try XCTUnwrap(h.editor.readingFrame(of: items[items.count - 2]))
            let below = try XCTUnwrap(h.editor.readingFrame(of: end))
            XCTAssertGreaterThanOrEqual(below.minY, last.maxY - 0.5, "under what the note ends in: \(text)")
        }
    }

    // MARK: - Lines followed through changes (#279)

    /// Where each line of `old` is once the text is `new`, changed as Change from Another Device changes it: only the
    /// part between what the two share at the start and at the end.
    private func moves(_ old: String, _ new: String) throws -> [Int?] {
        let h = EditorHarness(old)
        let change = try XCTUnwrap(h.editor.change(to: new))
        let length = (change.replacement as NSString).length
        let moves = LineMoves(from: MarkdownParser.parse(old), to: MarkdownParser.parse(new),
                              edited: NSRange(location: change.range.location, length: length), changeInLength: length - change.range.length)
        return MarkdownParser.parse(old).lines.indices.map { moves($0) }
    }

    func testLinesMoveWithWhatIsAddedAbove() throws {
        // Another device's to-do above, which starts as the one below it does: the edit cuts into that one's line.
        XCTAssertEqual(try moves("- [ ] Buy milk\n- [ ] Pay rent\n", "- [ ] Bread\n- [ ] Buy milk\n- [ ] Pay rent\n"), [1, 2, 3])
        XCTAssertEqual(try moves("# Week\n- [ ] Buy milk\n- [ ] Pay rent\n", "# Week\nMonday\n\n- [ ] Buy milk\n- [ ] Pay rent\n"), [0, 3, 4, 5])
        // Taken away above.
        XCTAssertEqual(try moves("- [ ] Bread\n- [ ] Buy milk\n- [ ] Pay rent\n", "- [ ] Buy milk\n- [ ] Pay rent\n"), [nil, 0, 1, 2])
    }

    func testALineChangedWithinItStays() throws {
        // Ticked elsewhere, or a word put right: the same line.
        XCTAssertEqual(try moves("- [ ] Buy milk\n- [ ] Pay rent\n", "- [x] Buy milk\n- [ ] Pay rent\n"), [0, 1, 2])
        XCTAssertEqual(try moves("- [ ] Buy milk\n- [ ] Pay rent\n", "- [ ] Buy oat milk\n- [ ] Pay rent\n"), [0, 1, 2])
    }

    func testALineMadeIntoOthersIsGone() throws {
        // Joined with the next: neither is the line it was.
        XCTAssertEqual(try moves("- [ ] Buy milk\n- [ ] Pay rent", "- [ ] Buy milk- [ ] Pay rent"), [nil, nil])
        // Split in two.
        XCTAssertEqual(try moves("- [ ] Buy milk and bread\n- [ ] Pay rent", "- [ ] Buy milk\n- [ ] and bread\n- [ ] Pay rent"), [nil, 2])
        // Written over within the line: the same line, which reads as something else now, so VoiceOver's element for
        // it doesn't stay (`isStill`).
        XCTAssertEqual(try moves("- [ ] Buy milk\n- [ ] Pay rent\n", "- [ ] Call Mia\n- [ ] Pay rent\n"), [0, 1, 2])
    }

    /// VoiceOver's element for an item stays only while it reads the same, a to-do ticked or not.
    func testAnElementStaysOnlyWhileItsItemReadsTheSame() throws {
        let (h, items) = reading("## Week\n- [ ] Buy milk\n")
        h.editor.toggleCheckbox(line: 1)
        h.settle()
        let ticked = h.editor.readingItems()
        XCTAssertTrue(ticked[1].isStill(items[1]), "ticked, the same to-do")
        XCTAssertTrue(ticked[0].isStill(items[0]))
        h.editor.reload(text: "## Week\n- [x] Call Mia\n")
        h.settle()
        let written = h.editor.readingItems()
        XCTAssertFalse(written[1].isStill(ticked[1]), "written over, another to-do")
        XCTAssertFalse(written[1].isStill(written[0]), "a heading is not a to-do")
    }

    /// The next one of a repeating to-do goes in above the ticked one, which moves down with its tick.
    func testATickedRepeatingToDoMovesDown() throws {
        let h = EditorHarness("Plants\n- [ ] Water the plants 🔁 every week 📅 2026-11-02\n- [ ] Pay rent\n")
        h.settle()
        var old = h.editor.document
        var lines = Array(old.lines.indices).map { Optional($0) }
        let observer = StorageEdits(h.editor.storage) { edited, delta in
            let new = MarkdownParser.parse(h.editor.storage.string)
            let moves = LineMoves(from: old, to: new, edited: edited, changeInLength: delta)
            lines = lines.map { $0.flatMap { moves($0) } }
            old = new
        }
        h.editor.toggleCheckbox(line: 1)
        h.settle()
        withExtendedLifetime(observer) {}
        XCTAssertTrue(h.text.contains("- [x] Water the plants"), h.text)
        let ticked = try XCTUnwrap(lines[1])
        XCTAssertTrue(h.editor.document.lines[ticked].range.location == (h.text as NSString).range(of: "- [x] Water").location, "\(lines) \(h.text)")
        XCTAssertEqual(lines[2], ticked + 1, "Pay rent below it")
        XCTAssertEqual(lines[0], 0)
    }
}

/// Says what changed in a text storage, each edit as `didProcessEditing` has it, before the editor restyles it.
@MainActor
private final class StorageEdits: NSObject {
    private var token: NSObjectProtocol?

    init(_ storage: NSTextStorage, _ changed: @escaping (NSRange, Int) -> Void) {
        super.init()
        token = NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification, object: storage, queue: nil) { note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edited = storage.editedRange
            let delta = storage.changeInLength
            MainActor.assumeIsolated { changed(edited, delta) }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
