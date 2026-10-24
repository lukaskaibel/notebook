import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import NotebookKit

/// Pictures dragged with the mouse on the Mac: what a drag carries, and what a drop in the note, in another note or
/// from another app does. The drag itself needs the real pointer, so drops go through the text view's own
/// `NSDraggingDestination` methods with what AppKit would hand them.
@MainActor
final class DragAndDropTests: XCTestCase {
    private let picture = "![](.assets/torii.png)"
    private let note = "First line\n\n![](.assets/torii.png)\n\nSecond line\n\nThird line"

    // MARK: - Dragging

    func testADraggedPictureCarriesItsFileMarkdownAndFragment() throws {
        let h = EditorHarness(note)
        let image = h.range(of: picture)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: image.location, origin: h.textView.textContainerOrigin))
        let item = h.editor.draggingItem(for: image, at: NSPoint(x: rect.midX, y: rect.midY))
        let pasteboard = Self.pasteboard(with: [try XCTUnwrap(item.item as? NSPasteboardWriting)])
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(files?.map(\.lastPathComponent), ["torii.png"], "the Finder and other apps get the file")
        XCTAssertEqual(pasteboard.string(forType: .string), picture)
        let fragment = try XCTUnwrap(pasteboard.data(forType: EditorController.fragmentType))
        let contents = try XCTUnwrap(try JSONSerialization.jsonObject(with: fragment) as? [String: String])
        XCTAssertEqual(contents["markdown"], picture)
        XCTAssertEqual(contents["object"], "1")
        // A wide picture is dragged smaller, still under the pointer where it was picked up.
        XCTAssertLessThanOrEqual(max(item.draggingFrame.width, item.draggingFrame.height), 320.5)
        XCTAssertTrue(item.draggingFrame.contains(NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(item.draggingFrame.width / item.draggingFrame.height, rect.width / rect.height, accuracy: 0.01)
        XCTAssertNotNil(item.imageComponents?.first?.contents, "it is dragged as it looks")
    }

    func testAClickOnAPictureSelectsItWithoutADrag() throws {
        let h = EditorHarness(note)
        let image = h.range(of: picture)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: image.location, origin: h.textView.textContainerOrigin))
        h.click(at: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(h.selection, image)
        XCTAssertNil(h.editor.objectDrag)
        XCTAssertEqual(h.text, note)
    }

    func testPressingInTextSelectedAroundAPictureLeavesTheSelectionToTheTextView() throws {
        let h = EditorHarness(note)
        let image = h.range(of: picture)
        let all = NSRange(location: 0, length: h.range(of: "Second line").upperBound)
        h.select(all)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: image.location, origin: h.textView.textContainerOrigin))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: h.textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(h.editor.handleMouseDown(down), "AppKit drags selected text, pictures and all")
        XCTAssertEqual(h.selection, all)
    }

    func testDraggedTextBringsItsPicturesToAnotherNote() throws {
        let h = EditorHarness(note)
        h.select(NSRange(location: 0, length: h.range(of: "Second line").upperBound))
        XCTAssertTrue(h.textView.writablePasteboardTypes.contains(EditorController.fragmentType))
        let pasteboard = Self.pasteboard(with: [])
        pasteboard.declareTypes([EditorController.fragmentType], owner: nil)
        XCTAssertTrue(h.textView.writeSelection(to: pasteboard, type: EditorController.fragmentType))
        let contents = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(pasteboard.data(forType: EditorController.fragmentType))) as? [String: String])
        XCTAssertEqual(contents["folder"], h.folder.path)
        XCTAssertNil(contents["object"], "text goes in where it is dropped, not on lines of its own")
    }

    // MARK: - Dropping in its note

    func testAPictureDroppedOnALineGoesBeforeIt() {
        let h = EditorHarness(note)
        let drop = ownDrop(h, at: h.range(of: "Third line").location)
        XCTAssertEqual(h.textView.draggingUpdated(drop), .move)
        XCTAssertTrue(h.textView.performDragOperation(drop))
        h.settle(0)
        XCTAssertEqual(h.text, "First line\n\nSecond line\n\n![](.assets/torii.png)\n\nThird line")
        XCTAssertEqual(h.selection, h.range(of: picture), "it stays selected where it went")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, note, "one undo puts it back")
    }

    func testAPictureDroppedAtTheEndOfALineGoesAfterIt() {
        let h = EditorHarness(note)
        let drop = ownDrop(h, at: h.range(of: "First line").upperBound)
        XCTAssertTrue(h.textView.performDragOperation(drop))
        XCTAssertEqual(h.text, note, "after the first line is where it already is")
        XCTAssertFalse(h.textView.undoManager?.canUndo ?? false, "nothing changed")
        XCTAssertTrue(h.textView.performDragOperation(ownDrop(h, at: h.range(of: "Second line").upperBound)))
        XCTAssertEqual(h.text, "First line\n\nSecond line\n\n![](.assets/torii.png)\n\nThird line")
    }

    func testAPictureDroppedBelowTheTextGoesToTheEnd() {
        let h = EditorHarness(note)
        let below = NSPoint(x: h.textView.textContainerOrigin.x + 20, y: h.textView.bounds.maxY - 10)
        let drop = ownDrop(h, at: below)
        XCTAssertTrue(h.textView.performDragOperation(drop))
        XCTAssertEqual(h.text, "First line\n\nSecond line\n\nThird line\n\n![](.assets/torii.png)\n")
    }

    func testOptionDraggingAPictureCopiesIt() {
        let h = EditorHarness(note)
        let drop = ownDrop(h, at: h.range(of: "Third line").location, mask: .copy)
        XCTAssertEqual(h.textView.draggingUpdated(drop), .copy)
        XCTAssertTrue(h.textView.performDragOperation(drop))
        XCTAssertEqual(h.text, "First line\n\n![](.assets/torii.png)\n\nSecond line\n\n![](.assets/torii.png)\n\nThird line",
                       "the copy goes where moving it would have taken it")
        XCTAssertEqual(h.selection, (h.text as NSString).range(of: picture, options: .backwards))
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.text, note)
    }

    func testADragFromANoteSinceClosedIsNoMove() {
        let h = EditorHarness(note)
        let drop = ownDrop(h, at: h.range(of: "Third line").location)
        h.editor.load(text: note, folder: h.folder, title: "Kyoto trip", meta: "")
        h.settle()
        XCTAssertEqual(h.textView.draggingUpdated(drop), .copy, "it comes from a note that isn't open any more")
    }

    // MARK: - Dropping in another note

    func testAPictureDroppedInAnotherNoteIsCopiedOnALineOfItsOwn() throws {
        let source = EditorHarness(note)
        let image = source.range(of: picture)
        let item = source.editor.draggingItem(for: image, at: .zero)
        let target = EditorHarness("Into here: and more")
        try FileManager.default.removeItem(at: target.folder.appendingPathComponent(".assets/torii.png"))
        let drop = FakeDrop(pasteboard: Self.pasteboard(with: [try XCTUnwrap(item.item as? NSPasteboardWriting)]),
                            source: ObjectDrag(editor: source.editor, range: image, markdown: picture, note: source.editor.loadCount),
                            location: target.textView.convert(target.point(of: 11, fraction: 0), to: nil), window: target.window)
        XCTAssertEqual(target.textView.draggingUpdated(drop), .copy)
        XCTAssertTrue(target.textView.performDragOperation(drop))
        XCTAssertEqual(target.text, "Into here: \n![](.assets/torii.png)\nand more")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.folder.appendingPathComponent(".assets/torii.png").path), "the picture came along")
        XCTAssertEqual(source.text, note, "the note it came from keeps it")
    }

    func testAPictureCopiedAndPastedInTheMiddleOfALineGetsItsOwnLine() {
        let h = EditorHarness(note)
        h.select(h.range(of: picture))
        h.textView.copy(nil)
        h.caret(h.range(of: "Third").upperBound)
        h.textView.paste(nil)
        XCTAssertTrue(h.text.hasSuffix("Third\n![](.assets/torii.png)\n line"), h.text)
    }

    // MARK: - Dropping from other apps

    func testANoteTakesDropsAsSoonAsItIsInAWindow() {
        let h = EditorHarness("Text")
        let types = Set(h.textView.registeredDraggedTypes)
        for type in [NSPasteboard.PasteboardType("NSFilenamesPboardType"), NSPasteboard.PasteboardType("NSStringPboardType")] {
            XCTAssertTrue(types.contains(type), "\(type.rawValue) in \(types.map(\.rawValue))")
        }
    }

    func testFilesFromTheFinderAreTakenAsBefore() throws {
        let h = EditorHarness("Text")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook drop \(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: outside)
        let drop = FakeDrop(pasteboard: Self.pasteboard(with: [outside as NSURL]), source: nil,
                            location: h.textView.convert(h.point(of: 3, fraction: 1), to: nil), window: h.window, mask: [.copy, .generic, .link])
        XCTAssertNotEqual(h.textView.draggingUpdated(drop), [])
        XCTAssertTrue(h.textView.performDragOperation(drop))
        XCTAssertTrue(h.text.contains("![\(outside.lastPathComponent)](.assets/"), h.text)
    }

    // AppKit hands out the files only during a real drop, so taking them is left to trying it in the app.
    func testAFileDroppedAtTheStartOfAHeadingOrListItemGoesBeforeIt() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Packing list \(UUID().uuidString.prefix(6)).pdf")
        try Data("%PDF-1.4".utf8).write(to: outside)
        let card = "![\(outside.lastPathComponent)](\(EditorController.markdownPath(outside.lastPathComponent)))"
        for (line, word) in [("## Packing", "Packing"), ("- [ ] Rain jacket", "Rain")] {
            let h = EditorHarness("Five days in October.\n\(line)\nMore")
            let start = h.range(of: word).location
            let drop = FakeDrop(pasteboard: Self.pasteboard(with: [outside as NSURL]), source: nil,
                                location: h.textView.convert(h.point(of: start, fraction: 0), to: nil), window: h.window, mask: [.copy, .generic])
            XCTAssertTrue(h.textView.performDragOperation(drop))
            XCTAssertEqual(h.text, "Five days in October.\n\(card)\n\(line)\nMore", "not between the marks and the text")
        }
    }

    func testAPictureAtTheEndOfBoldTextGoesAfterTheLine() {
        let h = EditorHarness("Check-in is **from 3 pm**\nDinner at 7")
        h.caret(h.range(of: "pm").upperBound)
        h.editor.insertOnOwnLines(picture, at: h.selection)
        XCTAssertEqual(h.text, "Check-in is **from 3 pm**\n\(picture)\nDinner at 7")
    }

    func testPhotosPromisedByAnotherAppAreAccepted() throws {
        let h = EditorHarness("Text")
        let promiser = Promiser()
        let pasteboard = Self.pasteboard(with: [NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: promiser)])
        XCTAssertEqual(h.editor.promisedFiles(on: pasteboard).count, 1)
        XCTAssertTrue(NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { h.textView.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0)) })
        let drop = FakeDrop(pasteboard: pasteboard, source: nil, location: h.textView.convert(h.point(of: 3, fraction: 1), to: nil), window: h.window, mask: .copy)
        XCTAssertEqual(h.textView.draggingUpdated(drop), .copy)
    }

    func testALinkFromSafariStaysText() {
        let h = EditorHarness("Text")
        let promiser = Promiser()
        let provider = NSFilePromiseProvider(fileType: "com.apple.web-internet-location", delegate: promiser)
        let link = NSPasteboardItem()
        link.setString("https://example.com", forType: .string)
        let pasteboard = Self.pasteboard(with: [provider, link])
        XCTAssertTrue(h.editor.promisedFiles(on: pasteboard).isEmpty, "a link isn't a file to keep")
    }

    // MARK: - Helpers

    /// The picture of the note dragged to a place in the text view.
    private func ownDrop(_ h: EditorHarness, at point: NSPoint, mask: NSDragOperation = [.move, .copy]) -> FakeDrop {
        let image = h.range(of: picture)
        let item = h.editor.draggingItem(for: image, at: .zero)
        let drag = ObjectDrag(editor: h.editor, range: image, markdown: picture, note: h.editor.loadCount)
        h.editor.objectDrag = drag
        return FakeDrop(pasteboard: Self.pasteboard(with: [item.item as! NSPasteboardWriting]), source: drag,
                        location: h.textView.convert(point, to: nil), window: h.window, mask: mask)
    }

    private func ownDrop(_ h: EditorHarness, at index: Int, mask: NSDragOperation = [.move, .copy]) -> FakeDrop {
        ownDrop(h, at: point(h, at: index), mask: mask)
    }

    /// Where the pointer is for a drop at a character: on the left of the first on a line, else on the right of the
    /// one before.
    private func point(_ h: EditorHarness, at index: Int) -> NSPoint {
        let text = h.text as NSString
        if index < text.length, index == 0 || text.character(at: index - 1) == 10 { return h.point(of: index, fraction: 0) }
        return h.point(of: index - 1, fraction: 1)
    }

    static func pasteboard(with items: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return pasteboard
    }
}

/// What AppKit tells a view a drag over it is.
private final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, source: Any?, location: NSPoint, window: NSWindow, mask: NSDragOperation = [.move, .copy]) {
        draggingPasteboard = pasteboard
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

/// An app that writes its file only once it is dropped, as Photos does.
private final class Promiser: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "IMG_0001.jpg" }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(CocoaError(.fileWriteUnknown))
    }
}
