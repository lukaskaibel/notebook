import AppKit
import XCTest
@testable import NotebookKit

/// Arrows, dashes, an ellipsis and the signs of comparison drawn in a Markdown note in place of what is written for
/// them. The file keeps what was typed, and next to the caret it shows.
@MainActor
final class TypographicSignsTests: XCTestCase {
    private func signs(_ text: String) -> [String] {
        MarkdownParser.parse(text).lines.flatMap(\.spans).compactMap { if case .replacement(let shown) = $0.kind { shown } else { nil } }
    }

    func testArrows() {
        XCTAssertEqual(signs("A -> B, B <- A, A <-> B, x => y, p <=> q"), ["→", "←", "↔", "⇒", "⇔"])
        XCTAssertEqual(signs("A --> B, B <-- A, A <--> B"), ["⟶", "⟵", "⟷"])
        XCTAssertEqual(signs("Kyoto->Nara"), ["→"])
        XCTAssertEqual(signs("-> at the start of a line"), ["→"])
        XCTAssertEqual(signs("## Plan -> Day 1"), ["→"], "in a heading")
        XCTAssertEqual(signs("- [ ] Station -> ryokan"), ["→"], "in a to-do")
        XCTAssertEqual(signs("[Station -> ryokan](https://example.com)"), ["→"], "in a link's words")
        XCTAssertEqual(signs("| Day | Route |\n| --- | --- |\n| 1 | Station -> ryokan |"), ["→"], "in a table, not in its delimiter row")
    }

    func testDashesEllipsisAndComparisons() {
        XCTAssertEqual(signs("Kyoto -- Nara"), ["–"])
        XCTAssertEqual(signs("10--20 May"), ["–"])
        XCTAssertEqual(signs("then---suddenly---rain"), ["—", "—"])
        XCTAssertEqual(signs("Tea --- or coffee"), ["—"])
        XCTAssertEqual(signs("Wait..."), ["…"])
        XCTAssertEqual(signs("x <= 5, y >= 3, a != b"), ["≤", "≥", "≠"])
        XCTAssertEqual(signs("20 +- 2 min or +/- 2"), ["±", "±"])
    }

    func testWhatStaysAsItIs() {
        let plain = [
            "git push --force", "--", "a ---> b", "a <== b", "a ==> b", "a !== b", "wait....", "x <<- y", "a->>b",
            "`a -> b`", "$a <= b$", "\\-> b", "<!-- a comment -->", "Before <!-- a -- b --> after", "[[A -> B]]",
            "https://example.com/a->b", "==highlight==", "![photo](a.png)",
        ]
        for text in plain {
            XCTAssertEqual(signs(text), [], text)
        }
        XCTAssertEqual(MarkdownParser.parse("---").lines[0].kind, .thematicBreak, "three dashes alone are still a rule")
    }

    func testTheNoteDrawsTheArrowAndTheFileKeepsWhatIsWritten() {
        let h = EditorHarness("")
        h.type("Kyoto -> Nara")
        XCTAssertEqual(h.text, "Kyoto -> Nara")
        let arrow = h.range(of: "->")
        guard case .replacement(let shown)? = (h.editor.storage.attribute(.notebookObject, at: arrow.location, effectiveRange: nil) as? EditorObject)?.kind else {
            return XCTFail("no arrow drawn")
        }
        XCTAssertEqual(shown, "→")
        XCTAssertEqual(h.visibleText(in: arrow), "", "the arrow is drawn in place of the two characters")
        h.caret(arrow.location + 1)
        XCTAssertEqual(h.visibleText(in: arrow), "->", "next to the caret what is written shows")
        h.caret((h.text as NSString).length)
        XCTAssertEqual(h.visibleText(in: arrow), "")
    }

    func testAnArrowCanStartALine() {
        let h = EditorHarness("")
        h.type("-> Nara\n--> Kyoto\n- item")
        XCTAssertEqual(h.text, "-> Nara\n--> Kyoto\n- item", "a dash typed there still makes a bullet")
        XCTAssertEqual(signs(h.text), ["→", "⟶"])
    }

    func testArrowsNoTypefaceHasAreMadeFromItsOwn() {
        for face in Typography.Face.allCases {
            for weight in [NSFont.Weight.regular, .bold] {
                let font = face.font(17, weight: weight)
                for sign in SignShape.signs {
                    let shape = SignShape.shape(sign, font: font)
                    XCTAssertNotNil(shape, "\(sign) in \(face)")
                    XCTAssertFalse(shape?.path.boundingBoxOfPath.isEmpty ?? true, "\(sign) in \(face)")
                }
                let arrow = ("→" as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThan(SignShape.shape("⟶", font: font)?.advance ?? 0, arrow * 1.3, "a long arrow is longer, in \(face)")
            }
        }
        XCTAssertNil(SignShape.shape("→", font: EditorStyle.body), "the typeface's own arrow is its character")
        let regular = SignShape.shape("⇒", font: Typography.Face.system.font(17))!.path.boundingBoxOfPath
        let bold = SignShape.shape("⇒", font: Typography.Face.system.font(17, weight: .bold))!.path.boundingBoxOfPath
        XCTAssertGreaterThan(bold.height, regular.height, "in bold text, bolder")
    }

    func testTableCellsShowTheSign() {
        let font = NSFont.systemFont(ofSize: 15)
        let rendered = InlineRenderer.renderMapped("Kyoto -> Nara", font: font, color: .textColor)
        XCTAssertEqual(rendered.shown.string, "Kyoto → Nara")
        XCTAssertEqual(rendered.map.count, 14)
        XCTAssertEqual(rendered.map[6], 6, "the arrow's place")
        XCTAssertEqual(rendered.map[8], 7, "after it")
        XCTAssertEqual(rendered.map[13], 12)
        let revealed = InlineRenderer.renderMapped("Kyoto -> Nara", font: font, color: .textColor, revealing: [NSRange(location: 6, length: 2)])
        XCTAssertEqual(revealed.shown.string, "Kyoto -> Nara", "next to the caret what is written shows")
        XCTAssertEqual(InlineRenderer.render("Kyoto -- Nara...", font: font, color: .textColor).string, "Kyoto – Nara…")
    }
}
