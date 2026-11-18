#if DEBUG && os(iOS)
import UIKit

/// `scribblefuzz <seed> <steps>`: the calls Scribble makes on the text view, in random order at random places, each
/// logged before it runs, so that a crash names the call. Apple Pencil can't be simulated; these calls can.
extension EditorController {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func debugScribbleFuzz(seed: Int, steps: Int, log: @escaping @MainActor (String) -> Void) {
        Task { @MainActor [weak self] in
            var random = Generator(state: UInt64(truncatingIfNeeded: seed))
            let phrases = ["Sehr gut", "a", "word", " two words ", "ÄÖü", "*", "#", "1. x", "- y", "|", "`", "[[", "![", "\n", "gut.", "😀"]
            var placeholder: UITextPlaceholder?
            for step in 0..<steps {
                guard let self else { return }
                let view = self.textView
                let height = max(view.contentSize.height, view.bounds.height)
                let point = CGPoint(x: .random(in: 0...view.bounds.width, using: &random), y: .random(in: 0...height, using: &random))
                let phrase = phrases.randomElement(using: &random)!
                let operation = Int.random(in: 0...11, using: &random)
                log("scribble \(step) op \(operation) at \(Int(point.x)),\(Int(point.y)) length \(self.storage.length) selection \(view.selectedRange) drawing \(self.isDrawing) \(phrase.debugDescription)")
                let position = view.closestPosition(to: point) ?? view.endOfDocument
                let word = view.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward))
                    ?? view.textRange(from: position, to: position)!
                switch operation {
                case 0:
                    _ = view.caretRect(for: position)
                    _ = view.firstRect(for: word)
                    _ = view.selectionRects(for: word)
                    _ = view.characterRange(at: point)
                case 1:
                    _ = view.becomeFirstResponder()
                    view.selectedTextRange = view.textRange(from: position, to: position)
                    if self.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: phrase) { view.insertText(phrase) }
                case 2:
                    _ = view.becomeFirstResponder()
                    view.replace(word, withText: phrase)
                case 3:
                    _ = view.becomeFirstResponder()
                    view.replace(word, withText: "")
                case 4:
                    let other = view.closestPosition(to: CGPoint(x: point.x, y: point.y + .random(in: -80...80, using: &random))) ?? position
                    let ordered = view.compare(position, to: other) == .orderedAscending
                    view.selectedTextRange = view.textRange(from: ordered ? position : other, to: ordered ? other : position)
                case 5:
                    _ = view.becomeFirstResponder()
                    view.selectedTextRange = view.textRange(from: position, to: position)
                    if let placeholder { view.remove(placeholder) }
                    let tall = Bool.random(using: &random)
                    placeholder = view.insertTextPlaceholder(with: CGSize(width: 120, height: tall ? 60 : 0))
                    _ = placeholder?.rects
                case 6:
                    if let old = placeholder {
                        view.remove(old)
                        placeholder = nil
                        view.insertText(phrase)
                    }
                case 7:
                    _ = view.becomeFirstResponder()
                    view.selectedTextRange = view.textRange(from: position, to: position)
                    view.setMarkedText(phrase, selectedRange: NSRange(location: (phrase as NSString).length, length: 0))
                case 8:
                    if view.markedTextRange != nil { view.unmarkText() }
                case 9:
                    if self.isDrawing { self.endDrawing() } else if view.markedTextRange == nil, placeholder == nil { self.beginDrawing() }
                case 10:
                    if view.markedTextRange == nil, placeholder == nil, self.undoStack.canUndoText { self.undoStack.undo() }
                default:
                    view.deleteBackward()
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            if let self, let placeholder { self.textView.remove(placeholder) }
            self?.textView.unmarkText()
            log("scribblefuzz done, length \(self?.storage.length ?? -1)")
        }
    }
}
#endif
