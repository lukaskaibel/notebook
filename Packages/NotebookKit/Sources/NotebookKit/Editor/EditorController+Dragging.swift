#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pictures, drawings and files dragged within their note, and what dropping them does: on the Mac with the mouse
/// (below), on iPhone and iPad by touch (`PictureInteractions`). A drop in the note moves one in a single change, which
/// one undo takes back.
extension EditorController {
    /// Whether the range is exactly one picture, file card or other block drawn in place of its Markdown.
    func isWholeObject(_ range: NSRange) -> Bool {
        guard range.length > 0, range.upperBound <= storage.length, let object = layoutManager.object(at: range.location) else { return false }
        return object.isBlock && object.range(at: range.location) == range
    }

    /// What goes when an object goes: its whole line when it is alone on one, so no empty line stays behind.
    private func blockRange(of range: NSRange) -> NSRange {
        let text = nsText
        let line = text.lineRange(for: range)
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        guard content == text.substring(with: range) else { return range }
        // The last line, without a line break of its own, takes the one before it.
        if !text.substring(with: line).hasSuffix("\n"), line.location > 0 {
            return NSRange(location: line.location - 1, length: line.length + 1)
        }
        return line
    }

    func deleteObject(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        let removal = blockRange(of: range)
        replace(removal, with: "", select: NSRange(location: removal.location, length: 0), actionName: "Delete")
    }

    /// A picture dropped elsewhere in its note goes before the line it was dropped on, or after it when dropped at its
    /// end, as a paragraph of its own: a blank line between it and text, and no blank line left doubled where it was.
    /// One change, which one undo takes back.
    func moveObject(_ range: NSRange, to location: Int) {
        let text = nsText
        guard range.upperBound <= text.length else { return }
        let markdown = text.substring(with: range)
        func isBlank(_ line: NSRange) -> Bool { text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func line(at index: Int) -> NSRange { text.lineRange(for: NSRange(location: index, length: 0)) }

        var removal = blockRange(of: range)
        if removal != range, removal.upperBound < text.length, isBlank(line(at: removal.upperBound)),
           removal.location == 0 || isBlank(line(at: removal.location - 1)) {
            removal.length += line(at: removal.upperBound).length
        }
        let (target, inserted, lead) = paragraph(of: markdown, droppedAt: location)
        guard target < removal.location || target > removal.upperBound else { return }

        // Both changes as one: the stretch from the first to the last, rewritten.
        let low = min(target, removal.location)
        let high = max(target, removal.upperBound)
        let span = NSRange(location: low, length: high - low)
        let stretch = NSMutableString(string: text.substring(with: span))
        let removed = NSRange(location: removal.location - low, length: removal.length)
        var start: Int
        if target < removal.location {
            stretch.replaceCharacters(in: removed, with: "")
            stretch.insert(inserted, at: target - low)
            start = target
        } else {
            stretch.insert(inserted, at: target - low)
            stretch.replaceCharacters(in: removed, with: "")
            start = target - removal.length
        }
        start += lead
        // Dropped next to where it is, such as at the end of the line before: nothing to change.
        guard stretch as String != text.substring(with: span) else { return }
        replace(span, with: stretch as String,
                select: NSRange(location: start, length: (markdown as NSString).length), actionName: "Move")
        selectionChanged()
    }

    /// A picture dragged elsewhere in its note with Option held: a copy goes where moving it would have taken it.
    func copyObject(_ range: NSRange, to location: Int) {
        guard range.upperBound <= storage.length else { return }
        let markdown = nsText.substring(with: range)
        let (target, inserted, lead) = paragraph(of: markdown, droppedAt: location)
        replace(NSRange(location: target, length: 0), with: inserted,
                select: NSRange(location: target + lead, length: (markdown as NSString).length), actionName: "Copy")
        selectionChanged()
    }

    /// Where a picture dropped at a character goes, and its Markdown as it goes in there, with the line breaks in front
    /// of it counted apart.
    private func paragraph(of markdown: String, droppedAt location: Int) -> (target: Int, text: String, lead: Int) {
        let text = nsText
        func isBlank(_ line: NSRange) -> Bool { text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func line(at index: Int) -> NSRange { text.lineRange(for: NSRange(location: index, length: 0)) }
        let dropped = line(at: min(location, text.length))
        var target = dropped.location
        // The caret of the drop shows after the line's text: the picture goes after the line.
        let textEnd = dropped.upperBound - (text.substring(with: dropped).hasSuffix("\n") ? 1 : 0)
        if location > dropped.location, location >= textEnd { target = dropped.upperBound }
        if location >= text.length, text.length > 0 { target = text.length }

        let atEnd = target == text.length
        let before = target > 0 && !isBlank(line(at: target - 1)) && !(atEnd && text.hasSuffix("\n\n"))
        var lead = before ? "\n" : ""
        if atEnd, text.length > 0, !text.hasSuffix("\n") { lead = "\n\n" }
        let after = !atEnd && !isBlank(line(at: target))
        return (target, lead + markdown + "\n" + (after ? "\n" : ""), (lead as NSString).length)
    }

    /// Text moved by dragging within the note: taken out and put in where it was dropped, in one change that one undo
    /// takes back.
    func moveText(_ range: NSRange, to location: Int) {
        let text = nsText
        guard range.upperBound <= text.length, location <= text.length, location < range.location || location > range.upperBound else { return }
        let markdown = text.substring(with: range)
        if location < range.location {
            let between = text.substring(with: NSRange(location: location, length: range.location - location))
            replace(NSRange(location: location, length: range.upperBound - location), with: markdown + between,
                    select: NSRange(location: location, length: range.length), actionName: "Move")
        } else {
            let between = text.substring(with: NSRange(location: range.upperBound, length: location - range.upperBound))
            replace(NSRange(location: range.location, length: location - range.location), with: between + markdown,
                    select: NSRange(location: range.location + (between as NSString).length, length: range.length), actionName: "Move")
        }
    }
}

#if os(macOS)
/// A picture, drawing or file dragged out of its note with the mouse. Dropped in the note it moves; anywhere else it
/// is a copy, so the Finder copies the file and the note keeps its own in `.assets`.
@MainActor
final class ObjectDrag: NSObject, NSDraggingSource {
    weak var editor: EditorController?
    /// Where it was and its Markdown then: a drop in the note moves it from there, if it is still there.
    let range: NSRange
    let markdown: String
    /// Which note it was dragged from (`EditorController.loadCount`).
    let note: Int

    init(editor: EditorController, range: NSRange, markdown: String, note: Int) {
        self.editor = editor
        self.range = range
        self.markdown = markdown
        self.note = note
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if editor?.objectDrag === self { editor?.objectDrag = nil }
    }
}

extension EditorController {
    /// A larger picture is dragged at most this size, so you still see where it goes.
    private static let dragImageSide: CGFloat = 320

    /// The button went down on a picture, which is selected: once the mouse moves with it down, the picture is
    /// dragged; if it comes up first, it was a click.
    func dragObjectIfMoved(_ range: NSRange, from event: NSEvent) {
        guard let window = textView.window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard next.type == .leftMouseDragged else { return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 3 {
                let item = draggingItem(for: range, at: textView.convert(event.locationInWindow, from: nil))
                let drag = ObjectDrag(editor: self, range: range, markdown: nsText.substring(with: range), note: loadCount)
                objectDrag = drag
                textView.beginDraggingSession(with: [item], event: event, source: drag).animatesToStartingPositionsOnCancelOrFail = true
                return
            }
        }
    }

    /// What dragging a picture carries, as copying it does: the file, for the Finder and other apps, its Markdown,
    /// and Notebook's own fragment, for another note. It looks as it does in the note, without the ring of its
    /// selection; a large one shrinks towards the pointer, which holds it where it was picked up.
    func draggingItem(for range: NSRange, at point: NSPoint) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: clipping(of: range)))
        let rect = layoutManager.blockObjectRect(at: range.location, origin: textOrigin)
            ?? layoutManager.rect(forObjectAt: range.location, origin: textOrigin) ?? NSRect(origin: point, size: .zero)
        let scale = min(1, Self.dragImageSide / max(rect.width, rect.height, 1))
        let frame = NSRect(x: point.x - (point.x - rect.minX) * scale, y: point.y - (point.y - rect.minY) * scale,
                           width: rect.width * scale, height: rect.height * scale)
        item.setDraggingFrame(frame, contents: objectImage(in: rect))
        return item
    }

    private func objectImage(in rect: NSRect) -> NSImage? {
        guard rect.width > 0, rect.height > 0, let bitmap = textView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        let selected = layoutManager.selectedRanges
        layoutManager.selectedRanges = []
        textView.cacheDisplay(in: rect, to: bitmap)
        layoutManager.selectedRanges = selected
        return NSImage(size: rect.size, flipped: false) { bounds in
            bitmap.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
        }
    }

    /// A picture of this note dragged within it, still where it was.
    private func ownObjectDrag(_ info: NSDraggingInfo) -> ObjectDrag? {
        guard let drag = info.draggingSource as? ObjectDrag, drag.editor === self, drag.note == loadCount,
              drag.range.upperBound <= storage.length, nsText.substring(with: drag.range) == drag.markdown else { return nil }
        return drag
    }

    /// What a drop here does where AppKit's text view can't tell: a picture of this note moves (Option copies it),
    /// one from another note is copied, and so are pictures that come as files written once they are dropped. Nil
    /// leaves it to the text view.
    func dropOperation(for info: NSDraggingInfo) -> NSDragOperation? {
        if info.draggingSource is ObjectDrag {
            return ownObjectDrag(info) != nil && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }
        return promisedFiles(on: info.draggingPasteboard).isEmpty ? nil : .copy
    }

    /// Drops a picture of this note where it was dragged to. Returns false for anything else.
    func dropObject(_ info: NSDraggingInfo, at index: Int) -> Bool {
        guard let drag = ownObjectDrag(info) else { return false }
        let isObject = isWholeObject(drag.range)
        if info.draggingSourceOperationMask.contains(.move) {
            isObject ? moveObject(drag.range, to: index) : moveText(drag.range, to: index)
        } else if isObject {
            copyObject(drag.range, to: index)
        } else {
            pasteText(drag.markdown, at: NSRange(location: index, length: 0))
        }
        return true
    }
}
#endif
