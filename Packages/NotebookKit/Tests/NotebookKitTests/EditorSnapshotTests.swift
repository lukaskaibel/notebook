import AppKit
import XCTest
@testable import NotebookKit

/// Draws sample notes to PNGs (when NOTEBOOK_SNAPSHOTS names a folder) so the live preview can be looked at.
@MainActor
final class EditorSnapshotTests: XCTestCase {
    static let sample = """
    Five days in **October**. Flights and the *ryokan* are booked, see [[Budget]] and [the site](https://example.com). Run `brew install` and ~~skip~~ this. A missing [[Lisbon plans]] link.

    ![](.assets/torii.png)

    ## Packing
    - [x] Passport
    - [ ] Power adapter, type A
    - Bullet one
      - Nested bullet
    1. First
    2. Second

    > [!tip] Good to know
    > Get an ICOCA card at the airport.

    > A plain quote that is long enough to wrap onto a second line in the editor so we can see the bar.

    ```swift
    let trip = Trip(days: 5) // a comment
    print("hello")
    ```

    | Day | Area | Note |
    | --- | :-: | --- |
    | 1 | Fushimi | **Early** start |
    | 2 | Arashiyama | Bamboo grove |

    $$
    \\int_0^1 x^2 dx = \\frac{1}{3}
    $$

    Inline math $e^{i\\pi} + 1 = 0$ here, and a footnote[^1].

    ---

    ```mermaid
    graph LR
      A[Files] --> B[Index]
      B --> C[Search]
    ```
    """

    func testSampleLight() {
        let harness = EditorHarness(Self.sample)
        harness.settle(1.5)
        harness.snapshot("sample-light")
    }

    func testSampleDark() {
        let harness = EditorHarness(Self.sample, dark: true)
        harness.settle(1.5)
        harness.snapshot("sample-dark")
    }

    func testCaretInBoldRevealsOnlyThatSpan() {
        let harness = EditorHarness(Self.sample)
        let bold = harness.range(of: "October")
        harness.caret(bold.location + 2)
        harness.snapshot("caret-in-bold")
        XCTAssertEqual(harness.visibleText(in: NSRange(location: bold.location - 2, length: bold.length + 4)), "**October**")
        let italic = harness.range(of: "ryokan")
        XCTAssertEqual(harness.visibleText(in: NSRange(location: italic.location - 1, length: italic.length + 2)), "ryokan")
    }

    func testCaretInTableShowsMarkdownWhenSet() {
        EditorHarness.withTablesAsMarkdown {
            let harness = EditorHarness(Self.sample)
            let cell = harness.range(of: "Fushimi")
            harness.caret(cell.location)
            harness.settle(0.3)
            harness.snapshot("caret-in-table")
            XCTAssertTrue(harness.isVisible(harness.range(of: "| --- |").location))
        }
    }

    func testCaretInTableKeepsTheGrid() {
        let harness = EditorHarness(Self.sample)
        let cell = harness.range(of: "Fushimi")
        harness.caret(cell.location)
        harness.settle(0.3)
        harness.snapshot("caret-in-table-grid")
        XCTAssertFalse(harness.isVisible(harness.range(of: "| --- |").location))
        XCTAssertFalse(harness.isVisible(cell.location), "the cell's text is drawn by the grid")
    }
}
