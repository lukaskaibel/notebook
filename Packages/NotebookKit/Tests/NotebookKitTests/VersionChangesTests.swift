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

    func testALongNoteWithTwoChangesShowsJustThose() {
        let lines = (1...2100).map { "Line \($0)" }
        let version = lines.joined(separator: "\n")
        let now = (["Line 1, changed"] + lines.dropFirst().dropLast() + ["Line 2100, changed"]).joined(separator: "\n")
        let start = Date()
        let changes = VersionChanges.between(version, now)
        XCTAssertEqual(changes.addedLines, 2)
        XCTAssertEqual(changes.removedLines, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testManyChangesAreFoundAndStayQuick() {
        let version = (1...2000).map { "Line \($0)" }
        var now = version
        for index in stride(from: 0, to: 2000, by: 5) { now[index] = "Changed \(index)" }
        let start = Date()
        let hunks = VersionChanges.lineHunks(version[...].map { Substring($0) }, now[...].map { Substring($0) })
        XCTAssertEqual(hunks.count, 400)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    /// Myers' hunks turn the old lines into the new ones, with as few lines changed as Diff3's longest common lines.
    func testTheLineDiffIsRightAndAsSmallAsCanBe() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let old = (0..<Int.random(in: 0...12, using: &generator)).map { _ in Substring(["a", "b", "c", "d"].randomElement(using: &generator)!) }
            let new = (0..<Int.random(in: 0...12, using: &generator)).map { _ in Substring(["a", "b", "c", "d"].randomElement(using: &generator)!) }
            let hunks = VersionChanges.lineHunks(old, new)
            var rebuilt: [Substring] = []
            var position = 0
            for hunk in hunks {
                rebuilt += old[position..<hunk.range.lowerBound]
                rebuilt += hunk.lines
                position = hunk.range.upperBound
            }
            rebuilt += old[position...]
            XCTAssertEqual(rebuilt, new, "\(old) → \(new)")
            func changed(_ hunks: [Diff3.Hunk]) -> Int { hunks.reduce(0) { $0 + $1.range.count + $1.lines.count } }
            XCTAssertEqual(changed(hunks), changed(Diff3.hunks(base: old, other: new)), "\(old) → \(new)")
        }
    }

    func testPlacesFoundBothWays() {
        let changes = VersionChanges.between("one\ntwo\nthree\n", "one\nnew\ntwo\nthree\n")
        XCTAssertEqual(changes.text, "one\nnew\ntwo\nthree\n")
        // "two" is at 4 in the version and at 8 with the line added before it.
        XCTAssertEqual(changes.offset(inChanges: 4), 8)
        XCTAssertEqual(changes.offset(inVersion: 8), 4)
        // In the added line: where it is.
        XCTAssertEqual(changes.offset(inVersion: 5), 4)
        XCTAssertEqual(changes.offset(inChanges: 0), 0)
    }

    func testRangesCountInUTF16() {
        let changes = VersionChanges.between("Tee 🍵\n", "Tee 🍵\nKaffee ☕️\n")
        let mark = try? XCTUnwrap(changes.marks.first)
        XCTAssertEqual(mark.map { (changes.text as NSString).substring(with: $0.range) }, "Kaffee ☕️\n")
    }
}
