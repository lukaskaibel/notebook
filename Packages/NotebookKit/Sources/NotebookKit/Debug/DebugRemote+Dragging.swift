#if DEBUG && os(macOS)
import AppKit

/// The debug remote's drag and drop commands. A drag follows the real pointer, which the remote leaves alone, so these
/// drop through the text view's own `NSDraggingDestination` methods with what AppKit would hand them:
/// - `dragtypes` tells which kinds of drag the note takes.
/// - `dragobject <object character> <to character> [copy]` drops the picture there as dragging it with the mouse does
///   (with Option held for `copy`).
/// - `dropfile <to character> <path>` drops a file from the Finder there.
/// - `dragover <object character|text> <to character|@x,y>` holds the picture (or text from another app) over a place
///   (or a point in the text view) without dropping it, so the drop caret shows; `dragover end` lets go of it outside
///   the note.
extension EditorController {
    func debugDragging(_ command: String, _ argument: String) -> String {
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        switch command {
        case "dragtypes":
            let types = textView.registeredDraggedTypes.map(\.rawValue).sorted()
            return "dragtypes \(types.count): " + types.joined(separator: ", ")
        case "dragobject":
            let numbers = argument.split(separator: " ").compactMap { Int($0) }
            guard numbers.count >= 2, numbers[0] < storage.length, let object = layoutManager.object(at: numbers[0]) else { return "dragobject: no object" }
            let range = object.range(at: numbers[0])
            let item = draggingItem(for: range, at: .zero)
            let drag = ObjectDrag(editor: self, range: range, markdown: nsText.substring(with: range), note: loadCount)
            let mask: NSDragOperation = argument.hasSuffix("copy") ? .copy : [.move, .copy]
            return drop(DebugDrop(writing: [item.item as! NSPasteboardWriting], source: drag, at: dropPoint(numbers[1]), in: textView.window, mask: mask))
        case "dropfile":
            guard words.count == 2, let index = Int(words[0]) else { return "dropfile <to character> <path>" }
            let file = URL(fileURLWithPath: words[1])
            return drop(DebugDrop(writing: [file as NSURL], source: nil, at: dropPoint(index), in: textView.window, mask: [.copy, .generic, .link]))
        case "dragover":
            if argument == "end" {
                textView.draggingExited(nil)
                return "dragover: ended, caret \(textView.dropCaret.isHidden ? "hidden" : "shown")"
            }
            let bits = argument.split(separator: " ").map(String.init)
            let point: NSPoint
            if bits.count == 2, bits[1].hasPrefix("@") {
                let xy = bits[1].dropFirst().split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { return "dragover: @x,y" }
                point = textView.convert(NSPoint(x: xy[0], y: xy[1]), to: nil)
            } else if bits.count == 2, let to = Int(bits[1]) {
                point = dropPoint(to)
            } else {
                return "dragover <object character|text> <to character|@x,y>"
            }
            let info: DebugDrop
            if let index = Int(bits[0]), index < storage.length, let object = layoutManager.object(at: index) {
                let range = object.range(at: index)
                let drag = ObjectDrag(editor: self, range: range, markdown: nsText.substring(with: range), note: loadCount)
                info = DebugDrop(writing: [draggingItem(for: range, at: .zero).item as! NSPasteboardWriting], source: drag,
                                 at: point, in: textView.window, mask: [.move, .copy])
            } else {
                info = DebugDrop(writing: [bits[0] as NSString], source: nil, at: point, in: textView.window, mask: [.copy, .generic])
            }
            _ = textView.draggingEntered(info)
            _ = textView.draggingUpdated(info)
            let caret = textView.dropCaret
            guard !caret.isHidden else { return "dragover: no caret" }
            let frame = textView.convert(caret.frame, to: nil)
            return "dragover: caret at character \(dropCaretIndex(for: info)) (pointer at \(textView.dropIndex(for: info))), view \(Int(caret.frame.minX)) \(Int(caret.frame.minY)) \(Int(caret.frame.width))×\(Int(caret.frame.height)), window \(Int(frame.minX)) \(Int(frame.minY))"
        default:
            return "unknown \(command)"
        }
    }

    /// Where the pointer is for a drop at a character, in the window: left of the first on a line, else right of the
    /// one before.
    private func dropPoint(_ index: Int) -> NSPoint {
        let text = nsText
        let index = min(index, text.length)
        let atStart = index < text.length && (index == 0 || text.character(at: index - 1) == 10)
        let character = atStart ? index : max(0, index - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = NSPoint(x: (atStart ? rect.minX : rect.maxX) + textOrigin.x, y: rect.midY + textOrigin.y)
        return textView.convert(point, to: nil)
    }

    private func drop(_ info: DebugDrop) -> String {
        let entered = textView.draggingEntered(info)
        let updated = textView.draggingUpdated(info)
        let accepted = textView.prepareForDragOperation(info) && textView.performDragOperation(info)
        textView.concludeDragOperation(info)
        textView.draggingEnded(info)
        func name(_ operation: NSDragOperation) -> String {
            operation.contains(.move) ? "move" : operation.contains(.copy) ? "copy" : operation.isEmpty ? "none" : "\(operation.rawValue)"
        }
        return "drop: \(name(entered)), \(name(updated)), \(accepted ? "dropped" : "refused")"
    }
}

/// What AppKit tells a view about a drag over it.
final class DebugDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(writing items: [NSPasteboardWriting], source: Any?, at location: NSPoint, in window: NSWindow?, mask: NSDragOperation) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-debug-drag-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(items)
        draggingSource = source
        draggingLocation = location
        draggingDestinationWindow = window
        draggingSourceOperationMask = mask
    }

    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
