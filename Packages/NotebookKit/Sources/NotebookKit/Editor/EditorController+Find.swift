#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where search found something in a note: the note opens there.
public enum NotePlace: Equatable, Sendable {
    /// The words searched for: all of them together if they are, else the first that is there.
    case words(String)
    case heading(String)
    /// A picture or drawing from the note's `.assets` folder, by its name there.
    case asset(String)
    /// A to-do: its line then, and what it said, to find it after the note changed.
    case todo(line: Int, source: String)
}

extension EditorController {
    /// Scrolls to a place search found and selects it, so you see at once why the note was found and can type there.
    /// Says whether the note has it.
    @discardableResult
    public func reveal(_ place: NotePlace) -> Bool {
        switch place {
        case .words(let words):
            guard let range = range(of: words) else { return false }
            reveal(range)
        case .heading(let title):
            updateOutline()
            let folded = SearchIndex.fold(title)
            guard let heading = outline.first(where: { SearchIndex.fold($0.title) == folded })
                    ?? outline.first(where: { SearchIndex.fold($0.title).contains(folded) }) else {
                return reveal(.words(title))
            }
            scroll(to: heading, animated: false)
            let line = nsText.lineRange(for: NSRange(location: heading.location, length: 0))
            var end = line.upperBound
            while end > line.location, nsText.character(at: end - 1) == 10 { end -= 1 }
            setSelection(NSRange(location: end, length: 0))
        case .asset(let name):
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            guard let reference = [".assets/" + encoded, ".assets/" + name].lazy.map({ self.nsText.range(of: $0) }).first(where: { $0.location != NSNotFound }) else { return false }
            // The whole picture: from the start of its Markdown to the end of the line it is on.
            let line = nsText.lineRange(for: reference)
            let start = nsText.range(of: "![", options: .backwards, range: NSRange(location: line.location, length: reference.location - line.location)).location
            let from = start == NSNotFound ? reference.location : start
            let close = nsText.range(of: ")", range: NSRange(location: reference.upperBound, length: line.upperBound - reference.upperBound))
            reveal(NSRange(location: from, length: (close.location == NSNotFound ? reference.upperBound : close.upperBound) - from))
        case .todo(let line, let source):
            guard let index = todoLine(source, near: line) else { return reveal(.words(source)) }
            reveal(NSRange(location: todoWordsEnd(line: index), length: 0))
        }
        return true
    }

    /// The words in the note, ignoring case and accents as search does: all of them together, or else the longest one
    /// that is there.
    func range(of words: String) -> NSRange? {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let whole = nsText.range(of: trimmed, options: options)
        if whole.location != NSNotFound { return whole }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init).sorted { $0.count > $1.count }
        return parts.lazy.map { self.nsText.range(of: $0, options: options) }.first { $0.location != NSNotFound }
    }

    /// Scrolls `range` to a third of the way down what you see, selects it and, on the Mac, makes it bounce as Find
    /// does in Safari and Notes.
    func reveal(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, range.upperBound + 1)))
        let top = -topInset
        let y = yPosition(of: range.location) + top - (visibleRect.height - topInset) / 3
        setScrollTop(min(max(top, y), maxScrollTop))
        updatePosition()
        setSelection(range)
        #if os(macOS)
        // Once the scroll has been drawn, so it bounces where the words are now.
        DispatchQueue.main.async { [weak self] in
            guard let self, range.upperBound <= self.storage.length, self.textView.window != nil else { return }
            self.textView.showFindIndicator(for: range)
        }
        #endif
    }
}
