import AppKit
import PencilKit
import XCTest
@testable import NotebookKit

/// Drawings in notes: the files they are kept in, putting one in, drawing in it, and what happens to it after.
@MainActor
final class DrawingTests: XCTestCase {
    private func stroke(_ points: [CGPoint], width: CGFloat = 3) -> PKStroke {
        let path = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: path, creationDate: Date()))
    }

    private func drawings(in h: EditorHarness) -> [URL] {
        h.editor.drawingObjects().map(\.picture)
    }

    /// Drawings are written in the background: waits until they are, and the main thread has heard.
    private func written(_ h: EditorHarness) {
        DrawingFile.writing.sync {}
        h.settle(0.05)
    }

    // MARK: - Files

    func testStrokesAndPictureAreWrittenTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-drawing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("Sketch.png")
        let file = DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 90)])]), size: CGSize(width: 320, height: 160))
        XCTAssertTrue(file.write(picture: picture))

        XCTAssertTrue(DrawingFile.isDrawing(picture), "the picture has its strokes next to it")
        XCTAssertEqual(DrawingFile.strokesURL(for: picture).lastPathComponent, "Sketch.drawing")
        let read = try XCTUnwrap(DrawingFile.read(picture: picture))
        XCTAssertEqual(read.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(read.drawing.strokes.count, 1)

        // The picture: two pixels a point, marked as such, on white so it reads in dark mode elsewhere too.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(picture as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 640)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 320)
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 144)
        XCTAssertEqual(ImageStore.shared.size(of: picture), CGSize(width: 320, height: 160), "other pictures' code reads it at its size in points")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: picture)))
        let corner = try XCTUnwrap(bitmap.colorAt(x: 600, y: 300)?.usingColorSpace(.sRGB))
        XCTAssertEqual(corner.redComponent, 1, accuracy: 0.01)
        let line = try XCTUnwrap(bitmap.colorAt(x: 220, y: 108)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(line.redComponent, 0.5, "the stroke is drawn dark on the white")
    }

    func testAPictureWithoutStrokesIsNoDrawing() throws {
        let h = EditorHarness("![](.assets/torii.png)\n")
        XCTAssertFalse(DrawingFile.isDrawing(h.folder.appendingPathComponent(".assets/torii.png")))
        XCTAssertTrue(drawings(in: h).isEmpty)
        guard case .image = try XCTUnwrap(h.editor.layoutManager.object(at: 0)).kind else { return XCTFail("a picture") }
    }

    func testStrokesGoWhereTheirPictureGoes() {
        XCTAssertEqual(FileOperations.withDrawingStrokes(["a.png", "b.jpg", "c d.PNG"]), ["a.png", "b.jpg", "c d.PNG", "a.drawing", "c d.drawing"])
    }

    // MARK: - A new drawing

    func testANewDrawingGoesBelowTheCaretsLineWithoutSplittingIt() throws {
        let h = EditorHarness("Hello world\nSecond line")
        h.caret(3)
        h.editor.beginDrawing()
        XCTAssertTrue(h.editor.isDrawing)
        let picture = try XCTUnwrap(drawings(in: h).first)
        XCTAssertEqual(h.text, "Hello world\n![Drawing](\(EditorController.markdownPath(picture.lastPathComponent)))\nSecond line")
        XCTAssertTrue(picture.lastPathComponent.hasPrefix("Kyoto trip drawing "), "named after the note, as pasted pictures are")
        XCTAssertTrue(DrawingFile.isDrawing(picture), "its strokes are there before the note points at it")
        let file = try XCTUnwrap(DrawingFile.read(picture: picture))
        XCTAssertEqual(file.size.width, floor(h.editor.container.size.width - 2), "as wide as the text")

        // A canvas lies over it, and has the focus.
        let canvas = try self.canvas(h, picture)
        let index = try XCTUnwrap(h.editor.drawingObjects().first?.index)
        XCTAssertEqual(canvas.frame, h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertTrue(h.window.firstResponder === canvas)
    }

    func testANewDrawingAtTheEndOfTheNoteLeavesALineToWriteIn() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        XCTAssertEqual(h.text, "Hello\n![Drawing](\(EditorController.markdownPath(picture.lastPathComponent)))\n")
    }

    func testANewDrawingGoesAboveALineWithTheCaretAtItsStartAndOnAnEmptyLine() throws {
        let h = EditorHarness("One\nTwo\n\nThree")
        h.caret(4)
        h.editor.beginDrawing()
        let first = try XCTUnwrap(drawings(in: h).first)
        try self.canvas(h, first).addStroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)], ink: PKInk(.pen), width: 3)
        h.editor.endDrawing()
        XCTAssertEqual(h.text, "One\n![Drawing](\(EditorController.markdownPath(first.lastPathComponent)))\nTwo\n\nThree")

        h.caret((h.text as NSString).range(of: "\n\n").location + 1)
        h.editor.beginDrawing()
        let second = try XCTUnwrap(drawings(in: h).last)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(h.text, "One\n![Drawing](\(EditorController.markdownPath(first.lastPathComponent)))\nTwo\n![Drawing](\(EditorController.markdownPath(second.lastPathComponent)))\nThree")
    }

    func testANewDrawingInANoteJustOpenedGoesAtTheEnd() throws {
        let h = EditorHarness("One\nTwo")
        XCTAssertTrue(h.window.firstResponder === h.textView, "the note has the focus, the caret where opening left it")
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        XCTAssertEqual(h.text, "One\nTwo\n![Drawing](\(EditorController.markdownPath(picture.lastPathComponent)))\n")
    }

    func testDrawingStartsWhereYouAreWithoutMovingTheNote() throws {
        let before = (1...40).map { "Line \($0) of the note" }.joined(separator: "\n")
        let after = (41...90).map { "Line \($0) of the note" }.joined(separator: "\n")
        let h = EditorHarness("Before\n", height: 700)
        let picture = h.folder.appendingPathComponent(".assets/Tall.png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 80), CGPoint(x: 310, y: 900)])]), size: CGSize(width: 320, height: 1000)).write(picture: picture))
        h.editor.load(text: before + "\n![Drawing](.assets/Tall.png)\n" + after, folder: h.folder, title: "Kyoto trip", meta: "")
        h.settle()
        h.caret(h.range(of: "Line 5 ").location)

        // Scrolled into a drawing taller than the window, the caret far above: the pencil draws in that drawing.
        let index = h.range(of: "![Drawing]").location
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertGreaterThan(rect.height, 1000)
        h.editor.setScrollTop(rect.minY + 300)
        h.settle()
        var top = h.editor.scrollTop
        // As if the strokes changed on disk since they were read: they are read again, in the background.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: DrawingFile.strokesURL(for: picture).path)
        h.editor.beginDrawing()
        XCTAssertEqual(h.editor.drawingSession?.focused?.standardizedFileURL, picture.standardizedFileURL, "the drawing on screen")
        XCTAssertTrue(h.editor.drawingSession?.created.isEmpty ?? false, "no new one")
        XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the note stays where it was")

        // Its strokes are read in the background if they weren't yet: the canvas comes once they are, and the note
        // still stays where it was.
        for _ in 0..<60 where h.editor.drawingSession?.canvases.isEmpty ?? true { h.settle(0.05) }
        XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the note stays where it was once the canvas is there")

        // Two fingers on the trackpad scroll the note over the drawing.
        let canvas = try self.canvas(h)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        canvas.scrollWheel(with: wheel)
        XCTAssertGreaterThan(h.editor.scrollTop, top + 60)
        XCTAssertTrue(h.editor.isDrawing)
        h.editor.endDrawing()

        // Scrolled to text with no drawing on screen: a new drawing goes below the line in the middle of the screen,
        // not at the caret, and the note doesn't move.
        h.editor.setScrollTop(h.editor.yPosition(of: h.range(of: "Line 50 ").location) - h.editor.topInset)
        h.settle()
        top = h.editor.scrollTop
        h.editor.beginDrawing()
        let created = try XCTUnwrap(h.editor.drawingSession?.created.keys.first)
        XCTAssertEqual(h.editor.scrollTop, top, accuracy: 0.5, "the note stays where it was")
        let new = try XCTUnwrap(h.editor.drawingObjects().first { $0.picture == created }?.index)
        let onScreen = h.editor.yPosition(of: new) - h.editor.scrollTop
        XCTAssertGreaterThan(onScreen, 200)
        XCTAssertLessThan(onScreen, 500, "in the middle of the screen")
        XCTAssertTrue(h.text.contains(" of the note\n![Drawing](\(EditorController.markdownPath(created.lastPathComponent)))\nLine "), "between two lines, splitting none")
        XCTAssertFalse(h.text.contains("Line 5 of the note\n![Drawing]"), "not at the caret, off screen")
    }

    func testANewDrawingLeftEmptyGoesAwayAgain() throws {
        let h = EditorHarness("Hello world\nSecond line")
        h.caret(3)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        h.editor.endDrawing()
        XCTAssertFalse(h.editor.isDrawing)
        XCTAssertEqual(h.text, "Hello world\nSecond line")
        XCTAssertFalse(FileManager.default.fileExists(atPath: picture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DrawingFile.strokesURL(for: picture).path))
        XCTAssertTrue(h.window.firstResponder === h.textView, "the caret is back in the text")
    }

    // MARK: - Drawing in it

    func testWhatIsDrawnIsSavedAndTheDrawingIsTrimmedToIt() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        canvas.addStroke(through: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 60)], ink: PKInk(.pen), width: 3)
        XCTAssertTrue(canvas.hasUnsavedChanges)
        h.editor.endDrawing()
        written(h)

        let file = try XCTUnwrap(DrawingFile.read(picture: picture))
        XCTAssertEqual(file.drawing.strokes.count, 1)
        XCTAssertLessThan(file.size.height, 120, "no more room below the strokes than a little")
        XCTAssertGreaterThanOrEqual(file.size.height, EditorController.drawingMinimumHeight)
        XCTAssertEqual(ImageStore.shared.size(of: picture)?.height, file.size.height, "the picture is made again")
        XCTAssertTrue(h.text.contains("![Drawing]("), "a drawing with strokes stays")
        XCTAssertNil(DrawingStore.shared.liveRevision(of: picture), "once written, the files count again")

        // In the text again, the drawing is drawn there, at its new height.
        h.settle()
        let index = try XCTUnwrap(h.editor.drawingObjects().first?.index)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertEqual(rect.height, (file.size.height * rect.width / file.size.width).rounded(), accuracy: 1)
    }

    func testTheDrawingGrowsWhenYouDrawNearItsLowerEdge() throws {
        let h = EditorHarness("Hello\n\nAfter the drawing")
        h.caret(5)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        let height = canvas.file.size.height
        let after = h.range(of: "After").location
        let before = h.editor.yPosition(of: after)
        let top = canvas.frame.minY

        canvas.addStroke(through: [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 50)], ink: PKInk(.pen), width: 3)
        XCTAssertEqual(canvas.file.size.height, height, "drawing near the top leaves it as it is")

        canvas.addStroke(through: [CGPoint(x: 20, y: height - 20), CGPoint(x: 60, y: height - 10)], ink: PKInk(.pen), width: 3)
        XCTAssertGreaterThan(canvas.file.size.height, height + 100, "room to go on drawing below")
        XCTAssertGreaterThan(canvas.frame.height, height + 100, "the canvas grows with it")
        XCTAssertEqual(canvas.frame.minY, top, "and stays where it is")
        XCTAssertGreaterThan(h.editor.yPosition(of: after), before + 100, "the text below makes room")

        // Trimmed to its strokes, the lowest of which is near its edge now: a stroke higher up leaves it as it is.
        h.editor.endDrawing()
        h.editor.beginDrawing(in: picture)
        let trimmed = try self.canvas(h, picture)
        let trimmedHeight = trimmed.file.size.height
        XCTAssertLessThan(trimmedHeight, height + 100, "trimmed to its strokes")
        trimmed.addStroke(through: [CGPoint(x: 100, y: 30), CGPoint(x: 160, y: 60)], ink: PKInk(.pen), width: 3)
        XCTAssertEqual(trimmed.file.size.height, trimmedHeight, "a stroke that doesn't go further down doesn't make it grow")
        trimmed.addStroke(through: [CGPoint(x: 100, y: trimmedHeight - 4), CGPoint(x: 160, y: trimmedHeight - 2)], ink: PKInk(.pen), width: 3)
        XCTAssertGreaterThan(trimmed.file.size.height, trimmedHeight + 100, "one that does, does")
    }

    func testAtTheEndOfTheNoteTheEmptyPageBelowIsTheDrawings() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        let index = try XCTUnwrap(h.editor.drawingObjects().first?.index)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertEqual(canvas.frame.minY, rect.minY)
        XCTAssertGreaterThan(rect.maxY, rect.minY)
        XCTAssertEqual(canvas.frame.maxY, h.textView.bounds.maxY, "with nothing below it, the canvas reaches the end of the page")

        // A stroke below the drawing's own area: the drawing grows to take it, and keeps it once trimmed.
        let height = canvas.file.size.height
        canvas.addStroke(through: [CGPoint(x: 20, y: height + 40), CGPoint(x: 80, y: height + 60)], ink: PKInk(.pen), width: 3)
        XCTAssertGreaterThan(canvas.file.size.height, height + 60)
        h.editor.endDrawing()
        written(h)
        let file = try XCTUnwrap(DrawingFile.read(picture: picture))
        XCTAssertGreaterThan(file.size.height, height + 60)
        XCTAssertLessThan(file.size.height, height + 100)
    }

    func testStrokesAreUndoneOneAtATime() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        for x in [20.0, 80, 140] {
            canvas.addStroke(through: [CGPoint(x: x, y: 20), CGPoint(x: x + 40, y: 60)], ink: PKInk(.pen), width: 3)
        }
        XCTAssertEqual(canvas.file.drawing.strokes.count, 3)
        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.file.drawing.strokes.count, 2)
        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.file.drawing.strokes.count, 1)
        canvas.undoManager?.redo()
        XCTAssertEqual(canvas.file.drawing.strokes.count, 2)
        XCTAssertEqual(h.text, "Hello\n![Drawing](\(EditorController.markdownPath(picture.lastPathComponent)))\n", "the text's undo is untouched")
    }

    func testTheUndoButtonTakesBackStrokesOfTheDrawingDrawnInLast() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        h.editor.beginDrawing()
        XCTAssertFalse(h.editor.canUndoDrawing, "nothing drawn yet")
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        canvas.addStroke(through: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], ink: PKInk(.pen), width: 3)
        canvas.addStroke(through: [CGPoint(x: 80, y: 20), CGPoint(x: 120, y: 60)], ink: PKInk(.pen), width: 3)
        XCTAssertTrue(h.editor.canUndoDrawing)
        XCTAssertFalse(h.editor.canRedoDrawing)

        h.editor.undoDrawing()
        XCTAssertEqual(canvas.file.drawing.strokes.count, 1)
        XCTAssertTrue(h.editor.canRedoDrawing)
        h.editor.redoDrawing()
        XCTAssertEqual(canvas.file.drawing.strokes.count, 2)

        h.editor.endDrawing()
        XCTAssertFalse(h.editor.canUndoDrawing, "not while not drawing")
    }

    func testDrawingWithTheMouse() throws {
        let h = EditorHarness("Hello")
        h.caret(5)
        DrawingTools.shared.tool = .pen
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        let canvas = try self.canvas(h, picture)
        let start = canvas.convert(NSPoint(x: 30, y: 40), to: nil)
        let end = canvas.convert(NSPoint(x: 160, y: 90), to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        for step in 1...6 {
            let t = CGFloat(step) / 6
            NSApp.postEvent(event(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)), atStart: false)
        }
        NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
        canvas.mouseDown(with: event(.leftMouseDown, start))
        let strokes = canvas.file.drawing.strokes
        XCTAssertEqual(strokes.count, 1)
        let bounds = try XCTUnwrap(strokes.first?.renderBounds)
        XCTAssertEqual(bounds.midX, 95, accuracy: 6, "the stroke is where the mouse went")
        XCTAssertEqual(bounds.midY, 65, accuracy: 6)
    }

    func testAClickInTheTextStopsDrawingAndPutsTheCaretThere() throws {
        let h = EditorHarness("Hello world\nSecond line")
        h.caret(3)
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        try self.canvas(h, picture).addStroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)], ink: PKInk(.pen), width: 3)
        let second = h.range(of: "Second").location
        h.click(at: h.point(of: second + 2, fraction: 0.2))
        XCTAssertFalse(h.editor.isDrawing)
        XCTAssertNil(h.textView.subviews.first { $0 is DrawingCanvas }, "the canvases are gone")
        XCTAssertEqual(h.selection, NSRange(location: second + 2, length: 0), "the caret goes where the click was, though the drawing got shorter")
        XCTAssertTrue(h.window.firstResponder === h.textView)
    }

    func testTheClickedLineStaysUnderThePointerWhenDrawingStops() throws {
        let intro = (1...60).map { "Line \($0) of the note" }.joined(separator: "\n")
        let h = EditorHarness(intro + "\nLast line", height: 700)
        let caret = h.range(of: "Line 50 ").location + 3
        h.caret(caret)
        h.editor.setScrollTop(h.editor.yPosition(of: caret) - h.editor.topInset - 40)
        h.settle()
        h.editor.beginDrawing()
        let picture = try XCTUnwrap(drawings(in: h).first)
        try self.canvas(h, picture).addStroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)], ink: PKInk(.pen), width: 3)
        h.settle()
        let target = h.range(of: "Line 53 ").location
        let onScreen = h.editor.yPosition(of: target) - h.editor.scrollTop
        h.click(at: h.point(of: target + 2, fraction: 0.2))
        XCTAssertFalse(h.editor.isDrawing)
        XCTAssertEqual(h.editor.yPosition(of: target) - h.editor.scrollTop, onScreen, accuracy: 0.5, "the drawing got shorter above it, and the note scrolled by as much")
        XCTAssertEqual(h.selection, NSRange(location: target + 2, length: 0))
    }

    /// The canvas of a drawing, once its strokes are read: in the background, unless showing the drawing read them
    /// already.
    private func canvas(_ h: EditorHarness, _ picture: URL? = nil) throws -> DrawingCanvas {
        func current() -> DrawingCanvas? {
            guard let canvases = h.editor.drawingSession?.canvases else { return nil }
            return picture.map { canvases[$0] } ?? canvases.values.first
        }
        for _ in 0..<60 where current() == nil { h.settle(0.05) }
        return try XCTUnwrap(current(), "the drawing's strokes were read")
    }

    func testTypingWhileDrawingWritesBelowTheDrawing() throws {
        let h = EditorHarness("Before\n![Drawing](.assets/Map.png)\nAfter")
        let picture = h.folder.appendingPathComponent(".assets/Map.png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 150)])]), size: CGSize(width: 320, height: 160)).write(picture: picture))
        h.editor.load(text: "Before\n![Drawing](.assets/Map.png)\nAfter", folder: h.folder, title: "Kyoto trip", meta: "")
        h.settle()
        // Selected, as a double-click leaves it, and opened for drawing.
        h.select(h.range(of: "![Drawing](.assets/Map.png)"))
        h.editor.beginDrawing(in: try XCTUnwrap(drawings(in: h).first))
        let canvas = try self.canvas(h)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                                 context: nil, characters: "H", charactersIgnoringModifiers: "H", isARepeat: false, keyCode: 4))
        canvas.keyDown(with: key)
        XCTAssertFalse(h.editor.isDrawing)
        XCTAssertEqual(h.text, "Before\n![Drawing](.assets/Map.png)\nH\nAfter", "on a new line below the drawing, which stays")
    }

    // MARK: - Showing it

    func testADrawingIsShownAsWideAsTheText() throws {
        let h = EditorHarness("Before\n")
        let picture = h.folder.appendingPathComponent(".assets/Map.png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 80), CGPoint(x: 310, y: 80)], width: 8)]), size: CGSize(width: 320, height: 160)).write(picture: picture))
        h.editor.load(text: "Before\n![Drawing](.assets/Map.png)\nAfter", folder: h.folder, title: "Kyoto trip", meta: "")
        h.settle()
        let index = h.range(of: "![Drawing]").location
        guard case .drawing(let url) = try XCTUnwrap(h.editor.layoutManager.object(at: index)).kind else { return XCTFail("a drawing") }
        XCTAssertEqual(url.standardizedFileURL, picture.standardizedFileURL)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertEqual(rect.width, floor(h.editor.container.size.width - 2))
        XCTAssertEqual(rect.height, (160 * rect.width / 320).rounded(), accuracy: 1, "larger than drawn, as Notes shows drawings made on a smaller screen")

        // Drawn from its strokes, which show in the text.
        for _ in 0..<40 where DrawingStore.shared.isBusy { h.settle(0.05) }
        h.textView.display()
        let ink = try XCTUnwrap(h.pixel(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertGreaterThan(ink.alphaComponent, 0.8)
        XCTAssertLessThan(ink.redComponent, 0.5, "the stroke is drawn in the note")
        let paper = try XCTUnwrap(h.pixel(at: CGPoint(x: rect.midX, y: rect.minY + 10)))
        XCTAssertLessThan(paper.alphaComponent, 0.1, "on the page, not on a white picture")

        // A tap with the editor (a double-click on the Mac) opens it for drawing.
        h.click(at: NSPoint(x: rect.midX, y: rect.midY), count: 2)
        XCTAssertTrue(h.editor.isDrawing)
        XCTAssertEqual(h.selection.length, 0, "the drawing isn't left selected under the canvas")
        XCTAssertNotNil(h.editor.drawingSession?.canvases[url])
        XCTAssertTrue(h.editor.drawingSession?.created.isEmpty ?? false, "no new drawing")
        h.editor.endDrawing()
        XCTAssertEqual(h.text, "Before\n![Drawing](.assets/Map.png)\nAfter", "a drawing that was there stays, drawn in or not")
    }

    func testADrawingNotReadYetOpensOnceItsStrokesAreThere() throws {
        let h = EditorHarness("Before\n")
        let picture = h.folder.appendingPathComponent(".assets/Late \(UUID().uuidString).png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 150)])]), size: CGSize(width: 320, height: 160)).write(picture: picture))
        h.editor.load(text: "Before\n![Drawing](\(EditorController.markdownPath(picture.lastPathComponent)))\nAfter", folder: h.folder, title: "Kyoto trip", meta: "")
        XCTAssertNil(DrawingStore.shared.file(for: picture), "laid out from the picture's size, without reading the strokes")
        let index = try XCTUnwrap(h.editor.drawingObjects().first?.index)
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        XCTAssertEqual(rect.height, (160 * rect.width / 320).rounded(), accuracy: 1)

        h.editor.beginDrawing(in: try XCTUnwrap(drawings(in: h).first))
        XCTAssertTrue(h.editor.isDrawing)
        for _ in 0..<40 where h.editor.drawingSession?.canvases.isEmpty ?? true { h.settle(0.05) }
        let canvas = try XCTUnwrap(h.editor.drawingSession?.canvases.values.first, "the strokes were read in the background")
        XCTAssertEqual(canvas.file.drawing.strokes.count, 1)
        XCTAssertTrue(h.window.firstResponder === canvas)
        XCTAssertEqual(canvas.frame, rect)
    }

    func testDrawingsInDarkModeAreDrawnLight() throws {
        let h = EditorHarness("Before\n", dark: true)
        let picture = h.folder.appendingPathComponent(".assets/Map.png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 80), CGPoint(x: 310, y: 80)], width: 8)]), size: CGSize(width: 320, height: 160)).write(picture: picture))
        h.editor.load(text: "Before\n![Drawing](.assets/Map.png)\nAfter", folder: h.folder, title: "Kyoto trip", meta: "")
        h.settle()
        let index = h.range(of: "![Drawing]").location
        let rect = try XCTUnwrap(h.editor.layoutManager.blockObjectRect(at: index, origin: h.textView.textContainerOrigin))
        _ = h.pixel(at: CGPoint(x: rect.midX, y: rect.midY))
        for _ in 0..<40 where DrawingStore.shared.isBusy { h.settle(0.05) }
        let ink = try XCTUnwrap(h.pixel(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertGreaterThan(ink.alphaComponent, 0.8)
        XCTAssertGreaterThan(ink.redComponent, 0.7, "black ink is drawn light in dark mode, as PencilKit does in Notes")
    }

    // MARK: - Copying

    func testADrawingPastedIntoAnotherFolderTakesItsStrokesAlong() throws {
        let source = EditorHarness("Hello")
        let picture = source.folder.appendingPathComponent(".assets/Map.png")
        XCTAssertTrue(DrawingFile(drawing: PKDrawing(strokes: [stroke([CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 150)])]), size: CGSize(width: 320, height: 160)).write(picture: picture))
        let target = EditorHarness("Into here: ")
        target.caret(11)
        let fragment = try JSONSerialization.data(withJSONObject: ["markdown": "![Drawing](.assets/Map.png)", "folder": source.folder.path])
        XCTAssertTrue(target.editor.pasteFragment(fragment, at: target.selection))
        let copy = target.folder.appendingPathComponent(".assets/Map.png")
        XCTAssertTrue(DrawingFile.isDrawing(copy), "the strokes came along")
        XCTAssertEqual(DrawingFile.read(picture: copy)?.drawing.strokes.count, 1)
    }
}
