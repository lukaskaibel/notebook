#if DEBUG && os(macOS)
import AppKit

/// The debug remote's drag and drop commands. A drag follows the real pointer, which the remote leaves alone, so these
/// drop through the text view's own `NSDraggingDestination` methods with what AppKit would hand them:
/// - `dragtypes` tells which kinds of drag the note takes.
/// - `dragobject <object character> <to character> [copy]` drops the picture there as dragging it with the mouse does
///   (with Option held for `copy`).
/// - `dropfile <to character> <path>` drops a file from the Finder there.
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
