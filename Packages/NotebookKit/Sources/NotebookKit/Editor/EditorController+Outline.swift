#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A heading in the note, for the outline next to it.
public struct OutlineHeading: Identifiable, Equatable {
    /// Its place among the headings, so the list doesn't animate on every keystroke.
    public var id: Int
    public var level: Int
    public var title: String
    public var location: Int
}

/// How long the note is.
public struct NoteStats: Equatable {
    public var words = 0
    public var characters = 0

    /// At about 230 words a minute.
    public var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded())) }
}

extension EditorController {
    /// Reads the headings and counts the words once typing pauses.
    func scheduleOutlineUpdate() {
        outlineUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateOutline() }
        outlineUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func updateOutline() {
        outlineUpdate?.cancel()
        outlineUpdate = nil
        let text = nsText
        var headings: [OutlineHeading] = []
        for line in document.lines {
            guard case .heading(let level, _) = line.kind else { continue }
            let title = plainText(of: line).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            headings.append(OutlineHeading(id: headings.count, level: level, title: title, location: line.range.location))
        }
        var words = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let stats = NoteStats(words: words, characters: text.length)
        let changed = headings != outline || stats != self.stats
        outline = headings
        self.stats = stats
        if changed { delegate?.editorOutlineDidChange(self) }
        updatePosition(force: changed)
    }

    /// A heading's words without the Markdown around them: `**Plan** for [[Kyoto]]` reads "Plan for Kyoto".
    private func plainText(of line: MarkdownLine) -> String {
        let text = nsText
        var hidden = IndexSet()
        for span in line.spans {
            for marker in span.markers { hidden.insert(integersIn: marker.location..<marker.upperBound) }
        }
        var result = ""
        var index = line.content.location
        while index < line.content.upperBound {
            if let next = hidden.integerGreaterThanOrEqualTo(index), next < line.content.upperBound {
                result += text.substring(with: NSRange(location: index, length: next - index))
                index = hidden.rangeView.first(where: { $0.contains(next) }).map(\.upperBound) ?? next + 1
            } else {
                result += text.substring(with: NSRange(location: index, length: line.content.upperBound - index))
                break
            }
        }
        // A closing run of #s is part of the heading's punctuation.
        while result.hasSuffix("#") { result.removeLast() }
        return result
    }

    // MARK: - Where you are

    /// The top of what you see, below the toolbar, in the text view's coordinates.
    var visibleTop: CGFloat { scrollTop + topInset }

    func updatePosition(force: Bool = false) {
        let titleAway = titleFrame.midY < visibleTop
        var current: Int?
        if !outline.isEmpty, storage.length > 0 {
            // The section a reader is in is the one whose heading is above a line or two below the toolbar.
            let y = visibleTop + 40 - textOrigin.y
            var index = 0
            if y > 0 {
                let glyph = layoutManager.glyphIndex(for: NSPoint(x: 1, y: y), in: container)
                index = layoutManager.characterIndexForGlyph(at: glyph)
            }
            current = outline.lastIndex { $0.location <= index }
            // With the title in view, you are at the start of the note.
            if scrollTop <= -topInset + 1 { current = nil }
            // Scrolled to the very bottom, the last headings can't reach the top: the last one you can see counts.
            if scrollTop > -topInset + 1, scrollTop >= maxScrollTop - 2, let last = outline.indices.last,
               yPosition(of: outline[last].location) < visibleRect.maxY {
                current = last
            }
        }
        if let jump {
            if isJumping || abs(scrollTop - jump.y) < 1 { current = jump.heading } else { self.jump = nil }
        }
        guard force || titleAway != isTitleScrolledAway || current != currentHeading else { return }
        isTitleScrolledAway = titleAway
        currentHeading = current
        delegate?.editorPositionDidChange(self)
    }

    // MARK: - Scrolling

    func scrollToTop() {
        setScrollTop(-topInset)
    }

    /// Where you are in the note: how far it is scrolled and where the caret is.
    public struct Place {
        /// The top of what you saw, under the toolbar, in the text view's coordinates.
        var top: CGFloat
        var selection: NSRange
        /// The caret was put there, rather than left where the note opened.
        var caretWasPlaced = false
    }

    public var place: Place {
        Place(top: visibleTop, selection: selection, caretWasPlaced: caretWasPlaced || isFocused)
    }

    /// Comes back to a place in the note, as Back and Forward do: the same caret, scrolled to the same spot.
    public func restore(_ place: Place) {
        guard place.selection.upperBound <= storage.length else { return }
        setSelection(place.selection)
        caretWasPlaced = place.caretWasPlaced
        scroll(to: place)
        #if os(iOS)
        // The note may be on its way to another screen, whose bars come later and move it: it goes back there
        // once they have.
        pendingPlace = place
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pendingPlace = nil }
        #endif
    }

    func scroll(to place: Place) {
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: place.top + visibleRect.height), in: container)
        let top = -topInset
        setScrollTop(min(max(top, place.top - topInset), maxScrollTop))
        updatePosition()
    }

    /// Scrolls a heading up to just below the toolbar, or to the title for `nil`. The caret stays where it is.
    public func scroll(to heading: OutlineHeading?, animated: Bool = true) {
        let top = -topInset
        var y = top
        if let heading, heading.location < storage.length {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: heading.location + 1))
            y = yPosition(of: heading.location) + top - 18
        }
        let target = min(max(top, y), maxScrollTop)
        jump = (heading?.id, target)
        guard animated else {
            setScrollTop(target)
            updatePosition()
            return
        }
        isJumping = true
        updatePosition()
        animateScrollTop(to: target) { [weak self] in
            self?.isJumping = false
            self?.updatePosition()
        }
    }
}
