import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Unfolds the Markdown marks the caret comes to and folds away those it leaves, instead of making them pop in and out:
/// a mark grows from nothing to its width as it fades in, moving the text after it aside, and shrinks back as it fades
/// out. Its glyphs are squeezed with `.expansion` and faded with `.notebookFade` (drawn by `NotebookLayoutManager`),
/// attributes that nothing else in the note sets. A mark folding away still counts as shown (`isConcealing`), so the
/// layout manager keeps its glyphs until it is gone.
@MainActor
final class MarkdownRevealAnimator: NSObject {
    /// One character of a mark: how much of it shows when the ease started, where it is going, and where it is now.
    /// 0 is folded away, 1 all of it. Characters go one by one, so one that is on its way keeps going from where it is
    /// when the marks around it start to move.
    private struct Mark {
        var from: CGFloat
        var to: CGFloat
        var value: CGFloat
    }

    /// The view the text is in, for its display's frames.
    weak var view: MarkdownTextView?
    /// Marks that have folded away, to be hidden for good.
    var onConcealed: ([NSRange]) -> Void = { _ in }
    /// For tests: folds marks in a window that isn't on screen (true), or never (false).
    var isForced: Bool?

    private weak var storage: NSTextStorage?
    private var marks: [Int: Mark] = [:]
    /// When the first frame of the ease was shown; 0 until then.
    private var started: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var fallback: Timer?

    /// Only where it can be seen: a window on screen, and Reduce Motion off. A note laid out off screen (in tests, for
    /// export) shows and hides its marks at once.
    var isEnabled: Bool {
        if let forced = isForced { return forced }
        guard MarkdownStyleAnimator.isEnabled, let window = view?.window else { return false }
        #if os(macOS)
        return window.isVisible
        #else
        return !window.isHidden
        #endif
    }

    var isRunning: Bool { !marks.isEmpty }

    /// Whether the character belongs to a mark that is folding away.
    func isConcealing(_ index: Int) -> Bool {
        marks[index]?.to == 0
    }

    /// Starts unfolding the marks in `appearing` and folding those in `disappearing`; marks already on their way
    /// turn round from where they are.
    func animate(appearing: [NSRange], disappearing: [NSRange], in storage: NSTextStorage) {
        guard isEnabled else { return }
        self.storage = storage
        for (ranges, target) in [(appearing, CGFloat(1)), (disappearing, 0)] {
            for range in ranges {
                for index in range.location..<range.upperBound {
                    marks[index, default: Mark(from: 1 - target, to: target, value: 1 - target)].to = target
                }
            }
        }
        // All start again from where they are: they share one ease.
        marks = marks.mapValues { Mark(from: $0.value, to: $0.to, value: $0.value) }
        guard !marks.isEmpty else { return }
        storage.beginEditing()
        apply(to: storage)
        storage.endEditing()
        start()
    }

    private func start() {
        started = 0
        guard displayLink == nil else { return }
        #if os(macOS)
        displayLink = view?.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        displayLink?.add(to: .main, forMode: .common)
        fallback?.invalidate()
        // A display link only runs while the view is on screen: the marks never stay half way.
        let fallback = Timer(timeInterval: Theme.markRevealDuration + 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.complete() }
        }
        RunLoop.main.add(fallback, forMode: .common)
        self.fallback = fallback
    }

    @objc private func tick(_ link: CADisplayLink) {
        if started == 0 { started = link.timestamp }
        advance(to: min(1, (link.targetTimestamp - started) / Theme.markRevealDuration))
    }

    /// Moves the ease on to `progress` (0 to 1) of its way: each mark's width and opacity, and the end once there.
    func advance(to progress: CGFloat) {
        guard let storage else { return complete() }
        let eased = 1 - pow(1 - progress, 3)
        for (index, mark) in marks {
            marks[index]?.value = mark.from + (mark.to - mark.from) * eased
        }
        guard progress < 1 else { return complete() }
        storage.beginEditing()
        apply(to: storage)
        storage.endEditing()
        caretMoved()
    }

    /// The caret moves with the text beside the marks: AppKit keeps where it drew it until told.
    private func caretMoved() {
        #if os(macOS)
        view?.updateInsertionPointStateAndRestartTimer(false)
        #endif
    }

    /// Ends the ease where it is going: unfolded marks are plain again, folded ones hidden.
    func complete() {
        displayLink?.invalidate()
        displayLink = nil
        fallback?.invalidate()
        fallback = nil
        guard !marks.isEmpty else { return }
        let finished = marks
        marks = [:]
        if let storage {
            storage.beginEditing()
            for range in Self.ranges(finished.keys) where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.expansion, range: range)
                storage.removeAttribute(.notebookFade, range: range)
            }
            storage.endEditing()
        }
        let concealed = Self.ranges(finished.filter { $0.value.to == 0 }.keys)
        if !concealed.isEmpty { onConcealed(concealed) }
        caretMoved()
    }

    /// Forgets every mark without touching the text, which is about to be replaced (another note).
    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        fallback?.invalidate()
        fallback = nil
        marks = [:]
    }

    /// The marks move with an edit; those it touched are left to the styling that follows.
    func shift(edited: NSRange, delta: Int) {
        guard !marks.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        var moved: [Int: Mark] = [:]
        for (index, mark) in marks {
            if index < edited.location { moved[index] = mark } else if index >= oldEnd { moved[index + delta] = mark }
        }
        marks = moved
    }

    /// Puts the marks' current width and opacity back after their lines were styled again, which set them anew.
    func reapply(to storage: NSTextStorage) {
        guard !marks.isEmpty, storage === self.storage else { return }
        apply(to: storage)
    }

    private func apply(to storage: NSTextStorage) {
        // Characters at the same point of the ease together, which is all of them but those that were on their way.
        for (value, indices) in Dictionary(grouping: marks.keys, by: { marks[$0]!.value }) {
            let value = max(value, 0.002)
            for range in Self.ranges(indices) where NSMaxRange(range) <= storage.length {
                // `.expansion` is the logarithm of the factor the glyphs are widened by.
                storage.addAttribute(.expansion, value: log(value), range: range)
                storage.addAttribute(.notebookFade, value: value * value, range: range)
            }
        }
    }

    /// Indices as runs of ranges.
    private static func ranges<S: Sequence<Int>>(_ indices: S) -> [NSRange] {
        IndexSet(indices).rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
    }
}
