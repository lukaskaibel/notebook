import AppKit
import PDFKit
import PencilKit
import XCTest
@testable import NotebookKit

/// Marking up PDFs on the Mac: drawing on their pages and highlighting their text, saved into the PDF itself.
@MainActor
final class PDFMarkupTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-pdf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A page of text, as the sample notes' tickets are.
    private func makePDF(_ name: String = "Tickets.pdf") -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (index, text) in ["Itinerary receipt", "Booking reference K7Q2LM", "Outbound Mon 12 Oct: FRA 13:40 to KIX 08:45"].enumerated() {
            let font = CTFontCreateUIFontForLanguage(.system, index == 0 ? 26 : 13, nil)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 56, y: 766 - CGFloat(index) * 40)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func stroke(_ points: [CGPoint]) -> PKStroke {
        let path = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: path, creationDate: Date()))
    }

    private func highlights(in url: URL) -> [PDFHighlight] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap { PDFHighlight($0, page: index) } ?? []
        }
    }

    private func waitForWrites() {
        var done = false
        PDFInk.whenWritten { done = true }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done, "the PDF was written")
    }

    // MARK: - Highlights

    func testAHighlightCoversTheLinesSelectedAndIsSavedInThePDF() throws {
        let url = makePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let selection = try XCTUnwrap(page.selection(for: text.range(of: "Booking reference K7Q2LM")))
        let highlight = try XCTUnwrap(PDFHighlight(selection, on: page, number: 0, color: .green))
        XCTAssertEqual(highlight.quadrilaterals.count, 4, "one line, four corners")
        XCTAssertTrue(highlight.contains(CGPoint(x: selection.bounds(for: page).midX, y: selection.bounds(for: page).midY)))
        XCTAssertFalse(highlight.contains(CGPoint(x: 500, y: 100)))

        try PDFInk.change(url) { PDFHighlight.apply(removing: [], adding: [highlight], to: $0) }
        let saved = highlights(in: url)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.color, HighlightColor.green.hex)
        XCTAssertEqual(saved.first?.quadrilaterals.count, 4)
        XCTAssertEqual(try XCTUnwrap(saved.first?.bounds.midY), selection.bounds(for: page).midY, accuracy: 0.5, "on the line selected")
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data(NSFullUserName().utf8)), "not signed with the Mac's owner's name")

        // Another colour, then gone.
        let read = try XCTUnwrap(saved.first)
        try PDFInk.change(url) { PDFHighlight.apply(removing: [read], adding: [read.recolored(.pink)], to: $0) }
        XCTAssertEqual(highlights(in: url).map(\.color), [HighlightColor.pink.hex])
        try PDFInk.change(url) { PDFHighlight.apply(removing: [read], adding: [], to: $0) }
        XCTAssertTrue(highlights(in: url).isEmpty)
    }

    func testHighlightingSelectedTextShowsAtOnceAndUndoTakesItBack() throws {
        let url = makePDF()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NotebookPDFView(url: url, workspace: nil) { title, message in XCTFail("\(title) \(message)") }
        defer { view.leaveWindow() }
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        view.document = PDFDocument(url: url)
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        XCTAssertFalse(view.canHighlight, "nothing selected")
        view.setCurrentSelection(page.selection(for: text.range(of: "K7Q2LM")), animate: false)
        XCTAssertTrue(view.canHighlight)

        let previous = HighlightColor.current
        defer { HighlightColor.current = previous }
        view.highlight(in: .blue)
        XCTAssertNil(view.currentSelection, "the colour shows, not the selection")
        XCTAssertEqual(page.annotations.compactMap { PDFHighlight($0, page: 0) }.count, 1, "shown before it is saved")
        waitForWrites()
        XCTAssertEqual(highlights(in: url).map(\.color), [HighlightColor.blue.hex])

        // Undo, with an undo manager that groups as the window's does for each event.
        let undo = UndoManager()
        undo.groupsByEvent = false
        let highlight = try XCTUnwrap(highlights(in: url).first)
        undo.beginUndoGrouping()
        PDFHighlights.change(url, removing: [highlight], adding: [], actionName: "Remove Highlight", undo: undo) { title, message in XCTFail("\(title) \(message)") }
        undo.endUndoGrouping()
        waitForWrites()
        XCTAssertTrue(highlights(in: url).isEmpty)
        XCTAssertEqual(undo.undoActionName, "Remove Highlight")
        undo.undo()
        waitForWrites()
        XCTAssertEqual(highlights(in: url).count, 1, "Undo puts it back")
    }

    func testTheRightClickMenuHighlightsSelectedTextOrChangesAHighlight() throws {
        let url = makePDF()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NotebookPDFView(url: url, workspace: nil) { _, _ in }
        defer { view.leaveWindow() }
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        view.document = PDFDocument(url: url)
        view.layoutDocumentView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let selection = try XCTUnwrap(page.selection(for: text.range(of: "Booking reference")))
        view.setCurrentSelection(selection, animate: false)
        let onText = view.convert(view.convert(CGPoint(x: selection.bounds(for: page).midX, y: selection.bounds(for: page).midY), from: page), to: nil)
        func rightClick() -> NSMenu? {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: onText, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return view.menu(for: event)
        }

        let menu = try XCTUnwrap(rightClick())
        XCTAssertEqual(menu.items.first?.title, "Highlight")
        XCTAssertEqual(menu.items.first?.keyEquivalentModifierMask, [.command, .control])
        let palette = try XCTUnwrap(menu.items.dropFirst().first?.submenu)
        XCTAssertEqual(palette.presentationStyle, .palette)
        XCTAssertEqual(palette.items.map(\.title), HighlightColor.allCases.map(\.name))
        let previous = HighlightColor.current
        defer { HighlightColor.current = previous }
        palette.performActionForItem(at: HighlightColor.allCases.firstIndex(of: .purple)!)
        waitForWrites()
        XCTAssertEqual(highlights(in: url).map(\.color), [HighlightColor.purple.hex])
        XCTAssertEqual(HighlightColor.current, .purple, "⌃⌘H uses it next")

        // On the highlight: take it off or give it another colour.
        view.document = PDFDocument(url: url)
        view.layoutDocumentView()
        let onHighlight = try XCTUnwrap(rightClick())
        XCTAssertEqual(onHighlight.items.first?.title, "Remove Highlight")
        let colours = try XCTUnwrap(onHighlight.items.dropFirst().first?.submenu)
        XCTAssertEqual(colours.items.filter { $0.state == .on }.map(\.title), ["Purple"])
        onHighlight.performActionForItem(at: 0)
        waitForWrites()
        XCTAssertTrue(highlights(in: url).isEmpty)
    }

    // MARK: - Drawing

    func testStrokesAreSavedAsLinesAndReadBack() throws {
        let url = makePDF()
        let drawing = PKDrawing(strokes: [stroke([CGPoint(x: 60, y: 300), CGPoint(x: 200, y: 320), CGPoint(x: 320, y: 300)])])
        try PDFInk.change(url) { PDFInk.put([0: drawing], in: $0) }

        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let found = page.annotations.compactMap { MarkupDrawings.strokes(in: $0, on: page) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.drawing.strokes.count, 1)
        XCTAssertEqual(try XCTUnwrap(found.first?.drawing.bounds.midX), drawing.bounds.midX, accuracy: 0.5)
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data("/Fm1".utf8)), "drawn without a transparency layer, which other apps show empty")
        XCTAssertNil(data.range(of: Data(NSFullUserName().utf8)))
    }

    func testShiftDrawsAStraightLine() {
        let points = [CGPoint(x: 10, y: 50), CGPoint(x: 60, y: 58), CGPoint(x: 120, y: 47), CGPoint(x: 200, y: 52)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let line = StrokeCanvas.line(along: points)
        XCTAssertEqual(line.first?.location, CGPoint(x: 10, y: 50))
        XCTAssertEqual(line.last?.location, CGPoint(x: 200, y: 50), "nearly level: level")
        XCTAssertTrue(line.allSatisfy { $0.location.y == 50 })

        let steep = StrokeCanvas.line(along: [points[0], PKStrokePoint(location: CGPoint(x: 110, y: 150), timeOffset: 0, size: CGSize(width: 3, height: 3),
                                                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)])
        XCTAssertEqual(steep.last?.location, CGPoint(x: 110, y: 150), "at an angle: as drawn")
        XCTAssertEqual(steep[steep.count / 2].location.x, 60, accuracy: 3, "straight between")
    }

    func testDrawingOnThePagesWithTheMouseIsSavedIntoThePDF() throws {
        let url = makePDF()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NotebookPDFView(url: url, workspace: nil) { title, message in XCTFail("\(title) \(message)") }
        defer { view.leaveWindow() }
        view.autoScales = true
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        view.document = PDFDocument(url: url)
        view.layoutDocumentView()

        let coordinator = PDFViewCoordinator(url: url)
        var stopped = false
        DrawingTools.shared.tool = .pen
        coordinator.updateDrawing(view, isDrawing: true) { PDFDrawingSession(url: url, report: { _, _ in }) { stopped = true } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(view.isInMarkupMode)
        let canvas = try XCTUnwrap(view.canvases.first { $0.pageIndex == 0 }, "a canvas over the page")
        XCTAssertNil(view.highlight(at: .zero))

        // Shift held: a straight line, though the mouse wobbles.
        let path = [NSPoint(x: 60, y: 200), NSPoint(x: 120, y: 206), NSPoint(x: 180, y: 197), NSPoint(x: 240, y: 202)].map {
            canvas.convert(NSPoint(x: $0.x * canvas.scale, y: $0.y * canvas.scale), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        for point in path.dropFirst() { NSApp.postEvent(event(.leftMouseDragged, point), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, path.last!), atStart: false)
        canvas.mouseDown(with: event(.leftMouseDown, path[0]))
        let strokes = canvas.strokes.strokes
        XCTAssertEqual(strokes.count, 1)
        let bounds = try XCTUnwrap(strokes.first?.renderBounds)
        XCTAssertEqual(bounds.minX, 58, accuracy: 3, "where the mouse went down, in the page's points from its top left")
        XCTAssertEqual(bounds.maxX, 242, accuracy: 3)
        XCTAssertLessThan(bounds.height, 6, "level")
        XCTAssertEqual(canvas.undoManager?.undoActionName, "Draw")

        // Escape asks for drawing to end, as Done does.
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        XCTAssertTrue(stopped)
        coordinator.updateDrawing(view, isDrawing: false) { XCTFail("no new session"); return PDFDrawingSession(url: url, report: { _, _ in }) {} }
        XCTAssertFalse(view.isInMarkupMode)
        XCTAssertFalse(canvas.takesEvents, "the strokes stay shown until the PDF is read again, and clicks go through")
        waitForWrites()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let saved = page.annotations.compactMap { MarkupDrawings.strokes(in: $0, on: page) }
        XCTAssertEqual(saved.first?.drawing.strokes.count, 1, "in the PDF itself")

        // Read again: the pages draw the strokes, and the canvases go.
        MarkupDrawings.sharpen(document, fileAt: url)
        view.document = document
        coordinator.documentChanged(in: view, isDrawing: false)
        XCTAssertNil(coordinator.drawing)
        XCTAssertNil(view.pageOverlayViewProvider)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(view.canvases.isEmpty, "no canvas is left to take the clicks: \(view.canvases.map { "\($0.pageIndex) \($0.takesEvents)" })")
    }

    func testPencilOnAndOffWithoutDrawingLeavesNoCanvas() throws {
        let url = makePDF()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NotebookPDFView(url: url, workspace: nil) { _, _ in }
        defer { view.leaveWindow() }
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        view.document = PDFDocument(url: url)
        view.layoutDocumentView()
        let coordinator = PDFViewCoordinator(url: url)
        coordinator.updateDrawing(view, isDrawing: true) { PDFDrawingSession(url: url, report: { _, _ in }) {} }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(view.canvases.isEmpty)
        coordinator.updateDrawing(view, isDrawing: false) { PDFDrawingSession(url: url, report: { _, _ in }) {} }
        XCTAssertNil(coordinator.drawing, "nothing to save")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(view.canvases.isEmpty, "\(view.canvases.map { "\($0.pageIndex) \($0.takesEvents)" })")
        // Nor do they come back with the page.
        view.scaleFactor = 3
        view.go(to: PDFDestination(page: view.document!.page(at: 0)!, at: CGPoint(x: 0, y: 100)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.autoScales = true
        view.go(to: PDFDestination(page: view.document!.page(at: 0)!, at: CGPoint(x: 0, y: 842)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(view.canvases.isEmpty)
    }
}
