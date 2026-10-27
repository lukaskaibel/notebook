import AppKit
import XCTest
@testable import NotebookKit

/// Edit › Transformations, the find bar's Replace and Speech work on the text you see: a picture's path and a link's
/// address keep their case and their words, so the picture isn't lost and the link still goes where it went.
@MainActor
final class ShownTextTests: XCTestCase {
    private let note = "Kyoto trip with a **ryokan**.\n\n![](.assets/torii.png)\n\nThe [ryokan's site](https://example.com/ryokan) and [[Budget]].\n"

    func testUpperCaseLeavesPathsAndAddresses() {
        let h = EditorHarness(note)
        h.select(NSRange(location: 0, length: (h.text as NSString).length))
        h.textView.uppercaseWord(nil)
        XCTAssertEqual(h.text, "KYOTO TRIP WITH A **RYOKAN**.\n\n![](.assets/torii.png)\n\nTHE [RYOKAN'S SITE](https://example.com/ryokan) AND [[BUDGET]].\n")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, note, "one Undo takes it all back")
    }

    func testCapitalizeTheWordAtTheCaret() {
        let h = EditorHarness(note)
        h.caret(h.range(of: "trip").location + 2)
        h.textView.capitalizeWord(nil)
        XCTAssertTrue(h.text.hasPrefix("Kyoto Trip with a **ryokan**."), h.text)
    }

    func testReplaceLeavesWhatIsHidden() {
        let h = EditorHarness(note)
        let text = h.text as NSString
        var matches: [NSValue] = []
        var from = 0
        while case let found = text.range(of: "ryokan", range: NSRange(location: from, length: text.length - from)), found.location != NSNotFound {
            matches.append(NSValue(range: found))
            from = found.upperBound
        }
        XCTAssertEqual(matches.count, 3)
        // Replace All, which NSTextFinder asks about first: the address's match stays, the others are replaced here.
        XCTAssertFalse(h.textView.shouldReplaceCharacters(inRanges: matches, with: Array(repeating: "inn", count: matches.count)))
        XCTAssertEqual(h.text, "Kyoto trip with a **inn**.\n\n![](.assets/torii.png)\n\nThe [inn's site](https://example.com/ryokan) and [[Budget]].\n")
        let path = NSValue(range: (h.text as NSString).range(of: "torii"))
        XCTAssertFalse(h.textView.shouldReplaceCharacters(inRanges: [path], with: ["gate"]))
        XCTAssertTrue(h.text.contains(".assets/torii.png"))
        // A match you see goes on to NSTextView, which replaces it.
        XCTAssertTrue(h.textView.shouldReplaceCharacters(inRanges: [NSValue(range: h.range(of: "Kyoto"))], with: ["Nara"]))
    }

    func testSpeechReadsWhatYouSee() {
        let h = EditorHarness(note)
        let spoken = h.editor.shownText(in: NSRange(location: 0, length: (h.text as NSString).length))
        XCTAssertTrue(spoken.contains("Kyoto trip with a ryokan."), spoken)
        XCTAssertTrue(spoken.contains("The ryokan's site and"), spoken)
        for markdown in ["**", ".assets", "https", "]("] { XCTAssertFalse(spoken.contains(markdown), "\(markdown) in \(spoken)") }
    }
}
