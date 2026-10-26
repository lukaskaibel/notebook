import XCTest
@testable import NotebookKit

/// Show Changes: the version with what was added since then and what was taken out marked in it.
final class VersionChangesTests: XCTestCase {
    private func marked(_ changes: VersionChanges) -> [String] {
        changes.marks.map { mark in
            let text = (changes.text as NSString).substring(with: mark.range).replacingOccurrences(of: "\n", with: "⏎")
            return "\(mark.kind == .added ? "+" : "-")\(mark.isLine ? "line" : "word") \(text)"
        }
    }

    func testNothingChanged() {
        let changes = VersionChanges.between("# Plan\n\nDay one\n", "# Plan\n\nDay one\n")
        XCTAssertEqual(changes.text, "# Plan\n\nDay one\n")
        XCTAssertTrue(changes.isEmpty)
    }

    func testLinesAddedAndTakenOut() {
        let changes = VersionChanges.between("Packing\n- Passport\n- Umbrella\n", "Packing\n- Passport\n- Rail pass\n- Rain jacket\n")
        XCTAssertEqual(changes.text, "Packing\n- Passport\n- Umbrella\n- Rail pass\n- Rain jacket\n")
        XCTAssertEqual(marked(changes), ["-line - Umbrella⏎", "+line - Rail pass⏎", "+line - Rain jacket⏎"])
        XCTAssertEqual(changes.addedLines, 2)
        XCTAssertEqual(changes.removedLines, 1)
    }

    func testAWordChangedInALine() {
        let changes = VersionChanges.between("Check-in is from 3 pm.\n", "Check-in is from 3 pm, dinner at 7.\n")
        XCTAssertEqual(changes.text, "Check-in is from 3 pm.\nCheck-in is from 3 pm, dinner at 7.\n")
        XCTAssertEqual(marked(changes), ["-line Check-in is from 3 pm.⏎", "-word pm.", "+line Check-in is from 3 pm, dinner at 7.⏎", "+word pm, dinner at 7."])
    }

    func testAWordPutInBetween() {
        let changes = VersionChanges.between("Pack the rain jacket", "Pack the warm rain jacket")
        XCTAssertEqual(marked(changes), ["-line Pack the rain jacket⏎", "+line Pack the warm rain jacket", "+word warm"])
    }

    func testLinesWithLittleInCommonHaveNoWordMarks() {
        let changes = VersionChanges.between("Fushimi Inari at sunrise\n", "Arashiyama bamboo grove early\n")
        XCTAssertEqual(marked(changes), ["-line Fushimi Inari at sunrise⏎", "+line Arashiyama bamboo grove early⏎"])
    }

    func testRangesCountInUTF16() {
        let changes = VersionChanges.between("Tee 🍵\n", "Tee 🍵\nKaffee ☕️\n")
        let mark = try? XCTUnwrap(changes.marks.first)
        XCTAssertEqual(mark.map { (changes.text as NSString).substring(with: $0.range) }, "Kaffee ☕️\n")
    }
}
