import AppKit
import XCTest
@testable import NotebookKit

/// Edit › Spelling and Grammar sets spelling for every note, and so does the note's context menu.
@MainActor
final class SpellingSettingsTests: XCTestCase {
    func testSpellingAsSetGoesForEveryNote() {
        let settings = NotebookSettings.shared
        let kept = (settings.checksSpelling, settings.checksGrammar, settings.correctsSpelling)
        defer { (settings.checksSpelling, settings.checksGrammar, settings.correctsSpelling) = kept }
        let first = EditorHarness("Ths is mispeled")
        let second = EditorHarness("Another note")

        settings.checksSpelling = false
        settings.checksGrammar = true
        settings.correctsSpelling = true
        for h in [first, second] {
            XCTAssertFalse(h.textView.isContinuousSpellCheckingEnabled)
            XCTAssertTrue(h.textView.isGrammarCheckingEnabled)
            XCTAssertTrue(h.textView.isAutomaticSpellingCorrectionEnabled)
        }

        // The context menu's Check Spelling While Typing, in one note.
        first.textView.toggleContinuousSpellChecking(nil)
        XCTAssertTrue(settings.checksSpelling, "the context menu changes the setting, not just this note")
        XCTAssertTrue(second.textView.isContinuousSpellCheckingEnabled, "and the other note follows")

        // A note opened later starts as set.
        settings.correctsSpelling = false
        XCTAssertFalse(EditorHarness("Later").textView.isAutomaticSpellingCorrectionEnabled)
    }
}
