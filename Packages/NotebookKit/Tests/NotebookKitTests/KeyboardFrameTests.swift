import XCTest
@testable import NotebookKit

/// What the keyboard's frame says on an iPhone 17 Pro (402 × 874 pt) and an 11-inch iPad on its side (1194 × 834 pt):
/// the touch keyboard, or only the shortcuts a keyboard with keys leaves, and nothing from a frame that tells nothing.
final class KeyboardFrameTests: XCTestCase {
    private let iPhone = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let iPad = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let bar = WritingBarLayout.height

    func testTheTouchKeyboardUnderTheBar() {
        let keyboard = CGRect(x: 0, y: 874 - 291 - bar, width: 402, height: 291 + bar)
        let reading = KeyboardFrame(frame: keyboard, in: iPhone, bar: bar, isHiding: false)
        XCTAssertTrue(reading.isOnScreen)
        XCTAssertTrue(reading.isTouchKeyboardShown)
        XCTAssertFalse(reading.isShortcutsAlone)
    }

    func testTheShortcutsAloneUnderTheBarOrWithItTuckedAway() {
        for bar in [bar, 0] {
            let shortcuts = CGRect(x: 0, y: 834 - 55 - bar, width: 1194, height: 55 + bar)
            let reading = KeyboardFrame(frame: shortcuts, in: iPad, bar: bar, isHiding: false)
            XCTAssertFalse(reading.isTouchKeyboardShown)
            XCTAssertTrue(reading.isShortcutsAlone)
        }
    }

    func testAKeyboardGoingTellsNeither() {
        let keyboard = CGRect(x: 0, y: 874 - 291 - bar, width: 402, height: 291 + bar)
        XCTAssertEqual(KeyboardFrame(frame: keyboard, in: iPhone, bar: bar, isHiding: true), KeyboardFrame(frame: .zero, in: iPhone, bar: bar, isHiding: true))
        let reading = KeyboardFrame(frame: keyboard, in: iPhone, bar: bar, isHiding: true)
        XCTAssertFalse(reading.isOnScreen)
        XCTAssertFalse(reading.isTouchKeyboardShown)
        XCTAssertFalse(reading.isShortcutsAlone)
    }

    /// The floating keyboard on an iPad and some other keyboards end at no frame at all, inside the window or not: no
    /// room to make under it either, rather than the whole window's.
    func testNoFrameTellsNothing() {
        for frame in [CGRect.zero, CGRect(x: 300, y: 400, width: 0, height: 0), CGRect(x: 0, y: 834, width: 1194, height: 0)] {
            let reading = KeyboardFrame(frame: frame, in: iPad, bar: bar, isHiding: false)
            XCTAssertFalse(reading.isOnScreen, "\(frame)")
            XCTAssertFalse(reading.isTouchKeyboardShown, "\(frame)")
            XCTAssertFalse(reading.isShortcutsAlone, "\(frame)")
        }
    }

    func testAKeyboardBelowTheWindowTellsNeither() {
        let keyboard = CGRect(x: 0, y: 874, width: 402, height: 291 + bar)
        let reading = KeyboardFrame(frame: keyboard, in: iPhone, bar: bar, isHiding: false)
        XCTAssertFalse(reading.isOnScreen)
        XCTAssertFalse(reading.isTouchKeyboardShown)
        XCTAssertFalse(reading.isShortcutsAlone)
    }
}
