import XCTest
@testable import NotebookKit

/// A writing bar you changed gets the tools that come with later versions, where they stand in the standard bar, and
/// the ones you took out stay out.
final class WritingBarTests: XCTestCase {
    private let standard = ["format", "checklist", "attach", "drawing", "link", "undo", "redo", "bold", "camera", "scanner"]

    func testANewToolJoinsAChangedBarWhereItStandsInTheStandardOne() {
        // Changed before drawings came: in another order, without the camera.
        let saved = ["checklist", "format", "attach", "link", "bold", "scanner"]
        let bar = NotebookSettings.writingBar(saved, known: NotebookSettings.firstWritingTools, standard: standard)
        XCTAssertEqual(bar, ["checklist", "format", "attach", "drawing", "link", "bold", "scanner"])
    }

    func testToolsTakenOutStayOut() {
        let saved = ["format", "checklist", "link"]
        let known = NotebookSettings.firstWritingTools + ["drawing", "reminder"]
        XCTAssertEqual(NotebookSettings.writingBar(saved, known: known, standard: standard), saved)
    }

    func testANewToolWithNoneBeforeItInTheBarComesFirst() {
        let bar = NotebookSettings.writingBar(["link"], known: ["format", "link"], standard: ["drawing", "format", "link"])
        XCTAssertEqual(bar, ["drawing", "link"])
    }
}

/// How the bar shares out its width, on an iPhone 17 Pro (402 pt) and an iPad: Notes' measures, and tools that keep
/// about the same width as the buttons for the caret come and go, so they slide rather than spread out.
final class WritingBarLayoutTests: XCTestCase {
    private let tools = 20

    func testTheBarIsAsTallAsNotesAndTheGlassFillsItsWidth() {
        XCTAssertEqual(WritingBarLayout.barHeight, 48)
        for width: CGFloat in [375, 390, 402, 440, 820, 1180] {
            for caret in 0...2 {
                let layout = WritingBarLayout(width: width, caretTools: caret, tools: tools)
                let gaps = CGFloat(layout.caretCount == 0 ? 1 : 2) * WritingBarLayout.spacing
                XCTAssertEqual(layout.caretWidth + layout.toolsWidth + WritingBarLayout.barHeight + gaps, WritingBarLayout.barWidth(for: width),
                               accuracy: 0.001, "\(width) pt, \(caret) for the caret")
                XCTAssertEqual(layout.slotWidth * CGFloat(layout.perPage), layout.toolsWidth, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(layout.slotWidth, WritingBarLayout.toolWidth)
            }
        }
    }

    func testAnIPhoneKeepsFourToolsNextToTwoButtonsForTheCaret() {
        let counts = (0...2).map { WritingBarLayout(width: 402, caretTools: $0, tools: tools).perPage }
        XCTAssertEqual(counts, [6, 5, 4])
        let slots = (0...2).map { WritingBarLayout(width: 402, caretTools: $0, tools: tools).slotWidth }
        XCTAssertLessThan(slots.max()! - slots.min()!, 1)
    }

    func testAnIPadBarStopsAtAboutTenTools() {
        let layout = WritingBarLayout(width: 1180, caretTools: 0, tools: tools)
        XCTAssertEqual(WritingBarLayout.barWidth(for: 1180), 620)
        XCTAssertEqual(layout.perPage, 10)
        XCTAssertEqual(layout.pageCount, 2)
    }

    func testTheLastPageCountsEvenWhenItHoldsOneTool() {
        XCTAssertEqual(WritingBarLayout(width: 402, caretTools: 0, tools: 12).pageCount, 2)
        XCTAssertEqual(WritingBarLayout(width: 402, caretTools: 0, tools: 13).pageCount, 3)
        XCTAssertEqual(WritingBarLayout(width: 402, caretTools: 0, tools: 0).pageCount, 1)
    }

    func testFewerPagesKeepYouOnOneThatIsThere() {
        let layout = WritingBarLayout(width: 402, caretTools: 0, tools: 12)
        XCTAssertEqual(layout.page(1), 1)
        XCTAssertEqual(layout.page(3), 1)
        XCTAssertEqual(layout.page(-1), 0)
    }

    func testOnANarrowBarTheToolsKeepRoomForTwoOfTheirs() {
        let layout = WritingBarLayout(width: 260, caretTools: 2, tools: tools)
        XCTAssertLessThan(layout.caretCount, 2)
        XCTAssertGreaterThanOrEqual(layout.perPage, 2)
    }
}
