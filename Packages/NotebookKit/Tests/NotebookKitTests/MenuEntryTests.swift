import XCTest
@testable import NotebookKit

@MainActor
final class MenuEntryTests: XCTestCase {
    func testLinesNeverComeFirstLastOrTwice() {
        let level = MenuLevel {
            MenuEntry.divider
            MenuEntry("Rename") {}
            MenuEntry.divider
            MenuEntry.divider
            MenuEntry("Duplicate") {}
            MenuEntry.divider
        }
        XCTAssertEqual(level.entries.map { $0.isDivider ? "—" : $0.title }, ["Rename", "—", "Duplicate"])
    }

    func testTypingFindsEntriesInSubmenusWithTheirPath() {
        var built = 0
        let level = MenuLevel {
            MenuEntry("Copy") {}
            MenuEntry.submenu("Export As") {
                MenuEntry("PDF…") {}
                MenuEntry("PNG Image…") {}
            }
            MenuEntry.submenu("Format") {
                MenuEntry("Copy Style", enabled: false) {}
                MenuEntry("Code") { built += 1 }
            }
        }
        let pdf = level.rows(for: "pdf")
        XCTAssertEqual(pdf.map(\.entry.title), ["PDF…"])
        XCTAssertEqual(pdf.first?.path, ["Export As"])
        XCTAssertTrue(pdf.first?.isFound == true)
        // The submenu's name finds what is in it; what is dimmed is left out.
        XCTAssertEqual(level.rows(for: "export").map(\.entry.title), ["PDF…", "PNG Image…"])
        XCTAssertEqual(level.rows(for: "copy").map(\.entry.title), ["Copy"])
        // Every word has to be there.
        XCTAssertEqual(level.rows(for: "format co").map(\.entry.title), ["Code"])
        XCTAssertTrue(level.rows(for: "zebra").isEmpty)
        // Nothing typed: the menu's own entries, its submenus among them.
        XCTAssertEqual(level.rows(for: "").map(\.entry.title), ["Copy", "Export As", "Format"])
        XCTAssertEqual(built, 0, "searching runs nothing")
    }

    func testSubmenusAreMadeOnceAndKeepTheirPlaceholder() {
        var made = 0
        let level = MenuLevel {
            MenuEntry.submenu("Move To", placeholder: "Move to…") {
                made += 1
                return [MenuEntry("Inbox") {}]
            }
        }
        XCTAssertEqual(made, 0, "made when it opens, not with the menu")
        let first = level.submenu(at: 0)
        XCTAssertEqual(first?.placeholder, "Move to…")
        XCTAssertTrue(level.submenu(at: 0) === first)
        _ = level.rows(for: "inbox")
        XCTAssertEqual(made, 1)
    }

    func testAShortMenuNeedsNoField() {
        let short = MenuLevel { for name in ["Name", "Date Edited", "Date Created"] { MenuEntry(name) {} } }
        XCTAssertFalse(short.isLonger(than: 7))
        let long = MenuLevel {
            for name in ["A", "B", "C", "D", "E"] { MenuEntry(name) {} }
            MenuEntry.submenu("Move To") { MenuEntry("Inbox") {} }
        }
        XCTAssertTrue(long.isLonger(than: 7))
        XCTAssertFalse(long.isLonger(than: 11))
        XCTAssertFalse(short.hasIcons)
        XCTAssertTrue(MenuLevel { MenuEntry("Rename", "pencil") {} }.hasIcons)
    }
}
