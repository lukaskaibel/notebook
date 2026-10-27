#if os(macOS)
import AppKit
import AVFoundation

/// What Edit › Find's Replace, Transformations and Speech work on: the text you see. The Markdown that isn't drawn (marks, a
/// link's address, a picture's path) stays as it is: a picture whose path changed case, or a link whose address was
/// replaced, would no longer be found.
extension EditorController {
    /// The runs of a range that show as text: not hidden marks or addresses, nor what a picture, a table or a bullet is
    /// drawn in place of.
    func shownRuns(in range: NSRange) -> [NSRange] {
        var runs: [NSRange] = []
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.notebookHidden] == nil, attributes[.notebookObject] == nil else { return }
            if let last = runs.last, last.upperBound == run.location {
                runs[runs.count - 1].length += run.length
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    /// The text you see in a range, as Speech reads it.
    func shownText(in range: NSRange) -> String {
        let text = storage.string as NSString
        return shownRuns(in: range).map { text.substring(with: $0) }.joined()
    }

    /// All of a range shows as text.
    func isShown(_ range: NSRange) -> Bool {
        shownRuns(in: range) == [range]
    }

    /// Edit › Transformations: the words you see in the selection, or the word at the caret, changed by `transform`.
    func transformShownText(_ actionName: String, _ transform: (String) -> String) {
        var range = selection
        if range.length == 0 { range = textView.selectionRange(forProposedRange: range, granularity: .selectByWord) }
        let runs = shownRuns(in: range)
        let text = storage.string as NSString
        let shown = runs.map { text.substring(with: $0) }
        // Changed together, so Capitalize sees a word whole across a bold mark; run by run where a letter becomes two
        // (ß in upper case).
        let together = transform(shown.joined()) as NSString
        let changed: [String]
        if together.length == runs.reduce(0, { $0 + $1.length }) {
            var offset = 0
            changed = runs.map { run in
                defer { offset += run.length }
                return together.substring(with: NSRange(location: offset, length: run.length))
            }
        } else {
            changed = shown.map(transform)
        }
        let changes = zip(runs, zip(shown, changed)).filter { $1.0 != $1.1 }.map { (range: $0, replacement: $1.1) }
        guard !changes.isEmpty else { return }
        _ = replace(changes, actionName: actionName)
    }
}

extension MarkdownTextView {
    override func uppercaseWord(_ sender: Any?) { controller?.transformShownText("Make Upper Case") { $0.uppercased() } }
    override func lowercaseWord(_ sender: Any?) { controller?.transformShownText("Make Lower Case") { $0.lowercased() } }
    override func capitalizeWord(_ sender: Any?) { controller?.transformShownText("Capitalize") { $0.capitalized } }

    /// Replace and Replace All in the find bar leave alone a match that isn't all shown: in a picture's path or a link's
    /// address, replacing would lose the picture or break the link. `NSTextFinder` asks this before it replaces; with
    /// every match shown, NSTextView's own goes on, which keeps them for Undo. Otherwise the shown ones are replaced
    /// here, as one step to undo, and `NSTextFinder` replaces none.
    @objc(shouldReplaceCharactersInRanges:withStrings:)
    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        guard let controller else { return false }
        let shown = zip(ranges.map(\.rangeValue), strings).filter { controller.isShown($0.0) }
        if shown.count == ranges.count {
            let selector = #selector(shouldReplaceCharacters(inRanges:with:))
            typealias Original = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Bool
            guard let method = class_getMethodImplementation(NSTextView.self, selector) else { return true }
            return unsafeBitCast(method, to: Original.self)(self, selector, ranges as NSArray, strings as NSArray)
        }
        if !shown.isEmpty {
            _ = controller.replace(shown.map { (range: $0.0, replacement: $0.1) }, actionName: ranges.count > 1 ? "Replace All" : "Replace")
        }
        return false
    }

    private static let speech = AVSpeechSynthesizer()

    /// Edit › Speech reads the selection, or the whole note, as you see it: without Markdown's marks and addresses.
    override func startSpeaking(_ sender: Any?) {
        let range = selectedRange().length > 0 ? selectedRange() : NSRange(location: 0, length: (string as NSString).length)
        guard let text = controller?.shownText(in: range), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Self.speech.stopSpeaking(at: .immediate)
        Self.speech.speak(AVSpeechUtterance(string: text))
    }

    override func stopSpeaking(_ sender: Any?) {
        Self.speech.stopSpeaking(at: .immediate)
    }
}
#endif

