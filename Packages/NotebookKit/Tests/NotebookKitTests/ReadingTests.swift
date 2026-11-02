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
        return (h, h.editor.readingItems())
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
}
