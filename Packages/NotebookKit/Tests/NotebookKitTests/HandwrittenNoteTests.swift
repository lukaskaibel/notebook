import AppKit
import PDFKit
import PencilKit
import XCTest
@testable import NotebookKit

/// Handwritten notes are PDFs: pages of paper, strokes and pictures on them, written so that every PDF app shows them
/// and Notebook can change them again. These check the file, which is the same on every device.
final class HandwrittenNoteTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-handwritten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func stroke(_ points: [CGPoint], color: NSColor = .black) -> PKStroke {
        let path = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: path, creationDate: Date()))
    }

    private var drawing: PKDrawing {
        PKDrawing(strokes: [stroke([CGPoint(x: 60, y: 100), CGPoint(x: 120, y: 130), CGPoint(x: 200, y: 110)])])
    }

    /// A photo: noisy enough that a JPEG of it is much smaller than its pixels.
    private func photo(width: Int = 900, height: Int = 600, transparent: Bool = false) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            if transparent {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: rect.width / 6, dy: rect.height / 6)).fill()
            } else {
                var generator = SystemRandomNumberGenerator()
                for _ in 0..<1500 {
                    NSColor(hue: .random(in: 0...1, using: &generator), saturation: 0.6, brightness: .random(in: 0.4...1, using: &generator), alpha: 1).setFill()
                    NSRect(x: .random(in: 0...rect.width), y: .random(in: 0...rect.height), width: .random(in: 4...50), height: .random(in: 4...50)).fill()
                }
            }
            return true
        }
        let representation = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        return transparent ? representation.representation(using: .png, properties: [:])! : representation.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    private func notebook(_ paper: PaperStyle = .lined, pages: Int = 1) throws -> Data {
        var data = try XCTUnwrap(NotebookPaper.document(paper, size: PaperSize.a4.size))
        if pages > 1 {
            let plan = PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size)]
                + (1..<pages).map { _ in PDFPlan.Slot(origin: .new, paper: paper, size: PaperSize.a4.size) })
            data = try PDFPageWriter.make(plan, base: data)
        }
        return data
    }

    // MARK: - Paper

    func testEveryPaperIsAPageWithItsMarkerAndSmall() throws {
        for paper in PaperStyle.allCases {
            let data = try XCTUnwrap(NotebookPaper.document(paper, size: PaperSize.a4.size), paper.name)
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 1)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(NotebookPaper.style(of: page), paper, paper.name)
            XCTAssertEqual(page.bounds(for: .cropBox).size, PaperSize.a4.size)
            // A page of paper is a few kilobytes, however many lines or dots it has.
            XCTAssertLessThan(data.count, 20_000, "\(paper.name) is \(data.count) bytes")
            // The marker isn't seen or printed.
            let marker = try XCTUnwrap(page.annotations.first { $0.value(forAnnotationKey: NotebookPaper.key) != nil })
            XCTAssertFalse(marker.shouldDisplay)
            XCTAssertFalse(marker.shouldPrint)
        }
    }

    func testPapersLookDifferent() throws {
        // Each paper's lines are drawn into the page itself: rendered, no two are the same.
        var looks: [Data] = []
        for paper in PaperStyle.allCases {
            let page = try XCTUnwrap(PDFDocument(data: try notebook(paper))?.page(at: 0))
            let image = page.thumbnail(of: NSSize(width: 1190, height: 1684), for: .cropBox)
            looks.append(try XCTUnwrap(image.tiffRepresentation))
        }
        XCTAssertEqual(Set(looks).count, PaperStyle.allCases.count)
    }

    func testANewHandwrittenNoteIsAPDFUnderItsOwnName() throws {
        let first = try XCTUnwrap(FileOperations.createHandwrittenNote(in: folder, paper: .squared, size: PaperSize.letter.size))
        let second = try XCTUnwrap(FileOperations.createHandwrittenNote(in: folder, paper: .dotted, size: PaperSize.letter.size))
        XCTAssertEqual(first.url.lastPathComponent, "Untitled.pdf")
        XCTAssertEqual(second.url.lastPathComponent, "Untitled 2.pdf")
        let page = try XCTUnwrap(PDFDocument(url: first.url)?.page(at: 0))
        XCTAssertEqual(NotebookPaper.style(of: page), .squared)
        XCTAssertEqual(page.bounds(for: .cropBox).size, PaperSize.letter.size)
        XCTAssertEqual(FileKind(url: first.url, isDirectory: false), .pdf)
    }

    // MARK: - Pages

    func testPagesAreAddedRemovedAndGivenOtherPaper() throws {
        let base = try notebook(.lined, pages: 3)
        // The second page goes, the third gets dotted paper with its strokes, and a squared one comes at the end.
        let plan = PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size),
            PDFPlan.Slot(origin: .base(2), paper: .dotted, size: PaperSize.a4.size, content: PageContent(drawing: drawing)),
            PDFPlan.Slot(origin: .new, paper: .squared, size: PaperSize.a4.size),
        ])
        let document = try XCTUnwrap(PDFDocument(data: try PDFPageWriter.make(plan, base: base)))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual((0..<3).map { NotebookPaper.style(of: document.page(at: $0)!) }, [.lined, .dotted, .squared])
        let strokes = document.page(at: 1)!.annotations.compactMap { MarkupDrawings.strokes(in: $0, on: document.page(at: 1)!) }
        XCTAssertEqual(strokes.first?.drawing.strokes.count, 1)
    }

    func testPagesOfAnotherPDFStayAsTheyWere() throws {
        // A slide: text of its own, which a page of paper after it leaves alone.
        let slide = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 720, height: 540)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: slide)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Lecture 4", attributes: [.font: NSFont.systemFont(ofSize: 40)]))
        context.textPosition = CGPoint(x: 60, y: 400)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let plan = PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: box.size, content: PageContent(drawing: drawing)),
            PDFPlan.Slot(origin: .new, paper: .lined, size: box.size),
        ])
        let document = try XCTUnwrap(PDFDocument(data: try PDFPageWriter.make(plan, base: slide as Data)))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.string?.contains("Lecture 4"), true)
        XCTAssertNil(NotebookPaper.style(of: document.page(at: 0)!))
        // The new page is as large as the slide, landscape.
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .cropBox).size, box.size)
        XCTAssertEqual(NotebookPaper.style(of: document.page(at: 1)!), .lined)
    }

    func testAPageTakenOutAndPutBackFromTheSameBase() throws {
        // Every save starts from the PDF as it was read: Undo of Delete Page after a save puts the page back.
        let base = try notebook(.lined)
        let picture = PDFPicture(id: "a", frame: CGRect(x: 100, y: 200, width: 300, height: 200), image: PictureImage.make(from: photo()))
        let content = PageContent(drawing: drawing, pictures: [picture])
        let plans = [
            [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: content), PDFPlan.Slot(origin: .new, paper: .dotted, size: PaperSize.a4.size, content: PageContent())],
            [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: content)],
            [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: content), PDFPlan.Slot(origin: .new, paper: .dotted, size: PaperSize.a4.size, content: PageContent())],
            [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: content), PDFPlan.Slot(origin: .new, paper: .squared, size: PaperSize.a4.size, content: PageContent())],
        ]
        for (number, slots) in plans.enumerated() {
            let made = try PDFPageWriter.make(PDFPlan(slots: slots), base: base)
            let document = try XCTUnwrap(PDFDocument(data: made), "save \(number + 1)")
            XCTAssertEqual(document.pageCount, slots.count, "save \(number + 1)")
            XCTAssertEqual(PDFPictures.pictures(on: document.page(at: 0)!).count, 1, "save \(number + 1)")
        }
    }

    // MARK: - Strokes and pictures

    func testStrokesAndAPictureAreInTheFileAndReadBack() throws {
        let jpeg = photo()
        let image = try XCTUnwrap(PictureImage.make(from: jpeg))
        // A small upright JPEG goes in as it is.
        XCTAssertEqual(image.jpeg, jpeg)
        let picture = PDFPicture(id: "photo", frame: CGRect(x: 80, y: 300, width: 360, height: 240), image: image)
        let plan = PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing, pictures: [picture]))])
        let made = try PDFPageWriter.make(plan, base: try notebook())
        // The JPEG, not its pixels: the file is about as large as the photo.
        XCTAssertLessThan(made.count, jpeg.count + 30_000)
        let document = try XCTUnwrap(PDFDocument(data: made))
        let page = try XCTUnwrap(document.page(at: 0))
        let found = PDFPictures.pictures(on: page)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.picture.id, "photo")
        XCTAssertEqual(found.first?.picture.frame, picture.frame)
        // Where other apps see it: the stamp's box, measured from the bottom left.
        XCTAssertEqual(found.first?.annotation.bounds.minY ?? 0, 842 - 540, accuracy: 0.01)
        let images = PDFPictures.images(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: made as CFData)!)))
        XCTAssertEqual(images["photo"]?.jpeg, jpeg)
        // The strokes come after the picture, so they are drawn over it.
        let order = page.annotations.compactMap { annotation -> String? in
            if annotation.value(forAnnotationKey: PDFPictures.key) != nil { return "picture" }
            if MarkupDrawings.strokes(in: annotation, on: page) != nil { return "strokes" }
            return nil
        }
        XCTAssertEqual(order, ["picture", "strokes"])
    }

    func testAMovedPictureKeepsItsJPEGAndSavesDontGrow() throws {
        let jpeg = photo()
        let first = PDFPicture(id: "photo", frame: CGRect(x: 80, y: 300, width: 360, height: 240), image: PictureImage.make(from: jpeg))
        var base = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(pictures: [first]))]), base: try notebook())
        let size = base.count
        // Moved, turned and resized ten times, each saved over the last.
        for step in 1...10 {
            let moved = PDFPicture(id: "photo", frame: CGRect(x: 80 + CGFloat(step) * 5, y: 300, width: 360 - CGFloat(step), height: 240), rotation: CGFloat(step) * 0.05)
            base = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing, pictures: [moved]))]), base: base)
        }
        XCTAssertLessThan(base.count, size + 15_000, "grew from \(size) to \(base.count) bytes")
        let document = try XCTUnwrap(PDFDocument(data: base))
        let found = try XCTUnwrap(PDFPictures.pictures(on: document.page(at: 0)!).first)
        XCTAssertEqual(found.picture.frame.minX, 130, accuracy: 0.01)
        XCTAssertEqual(found.picture.rotation, 0.5, accuracy: 0.0001)
        let images = PDFPictures.images(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: base as CFData)!)))
        XCTAssertEqual(images["photo"]?.jpeg, jpeg)
    }

    func testAPictureLeftWhereItWasIsNotWrittenAgain() throws {
        let picture = PDFPicture(id: "photo", frame: CGRect(x: 80, y: 300, width: 360, height: 240), image: PictureImage.make(from: photo()))
        let base = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(pictures: [picture]))]), base: try notebook())
        var kept = picture
        kept.image = nil
        let again = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing, pictures: [kept]))]), base: base)
        XCTAssertEqual(PDFPictures.pictures(on: PDFDocument(data: again)!.page(at: 0)!).map(\.picture.id), ["photo"])
        // Taken off: gone from the page and from the file.
        let removed = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing))]), base: again)
        XCTAssertTrue(PDFPictures.pictures(on: PDFDocument(data: removed)!.page(at: 0)!).isEmpty)
        XCTAssertLessThan(removed.count, base.count / 2)
    }

    func testAPictureWithSeeThroughPartsKeepsThem() throws {
        let image = try XCTUnwrap(PictureImage.make(from: photo(width: 400, height: 300, transparent: true)))
        let alpha = try XCTUnwrap(image.alpha)
        XCTAssertEqual(alpha.count, image.width * image.height)
        XCTAssertEqual(alpha.first, 0)
        let picture = PDFPicture(id: "cutout", frame: CGRect(x: 100, y: 100, width: 200, height: 150), image: image)
        let made = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(pictures: [picture]))]), base: try notebook())
        let images = PDFPictures.images(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: made as CFData)!)))
        XCTAssertEqual(images["cutout"]?.alpha, alpha)
        let pixels = try XCTUnwrap(images["cutout"]?.cgImage)
        XCTAssertEqual(pixels.width, image.width)
        XCTAssertFalse([.none, .noneSkipLast, .noneSkipFirst].contains(pixels.alphaInfo))
    }

    func testABigPhotoIsMadeSmaller() throws {
        let image = try XCTUnwrap(PictureImage.make(from: photo(width: 4000, height: 3000)))
        XCTAssertEqual(max(image.width, image.height), PictureImage.largestSide)
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 1536)
    }

    func testPicturesAreReadForTheCanvases() throws {
        let picture = PDFPicture(id: "photo", frame: CGRect(x: 80, y: 300, width: 360, height: 240), rotation: 0.2, image: PictureImage.make(from: photo()))
        let made = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing, pictures: [picture]))]), base: try notebook())
        let url = folder.appendingPathComponent("Note.pdf")
        try made.write(to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        MarkupDrawings.sharpen(document, fileAt: url)
        let page = try XCTUnwrap(document.page(at: 0))
        let pictures = MarkupDrawings.pictures(on: page)
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.rotation ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertNotNil(pictures.first?.image?.cgImage)
        XCTAssertEqual(MarkupDrawings.drawing(on: page).strokes.count, 1)
    }

    func testThePageDrawsItsPicturesInPlaceOfTheirStamps() throws {
        // An orange oval on a see-through square, turned: its middle is orange wherever the page draws it.
        let picture = PDFPicture(id: "oval", frame: CGRect(x: 80, y: 300, width: 360, height: 240), rotation: 0.2,
                                 image: PictureImage.make(from: photo(transparent: true)))
        let made = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(pictures: [picture]))]), base: try notebook())
        let url = folder.appendingPathComponent("Note.pdf")
        try made.write(to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        MarkupDrawings.sharpen(document, fileAt: url)
        let page = try XCTUnwrap(document.page(at: 0))
        // PDFKit would draw the stamp at the page's size; the page draws the picture at the size it is shown.
        XCTAssertEqual(PDFPictures.pictures(on: page).first?.annotation.shouldDisplay, false)

        func middle() throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
            let scale = 3, crop = page.bounds(for: .cropBox)
            let (width, height) = (Int(crop.width) * scale, Int(crop.height) * scale)
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // White paper under the page, which draws only its lines.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            page.draw(with: .cropBox, to: context)
            let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
            // The picture's middle, 260 × 420 points from the top left; the bitmap's rows go from the top.
            let pixel = pixels + (420 * scale * width + 260 * scale) * 4
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3]))
        }
        let drawn = try middle()
        XCTAssertGreaterThan(drawn.red, 200)
        XCTAssertLessThan(drawn.blue, 100)
        // Not twice while a canvas shows it (iPhone and iPad), and the stamp stays hidden after.
        MarkupDrawings.setEditing(true, pictures: true, on: page)
        XCTAssertGreaterThan(try middle().blue, 200)
        MarkupDrawings.setEditing(false, on: page)
        XCTAssertEqual(PDFPictures.pictures(on: page).first?.annotation.shouldDisplay, false)
        XCTAssertLessThan(try middle().blue, 100)
        // The Mac's canvas shows only the strokes: the page goes on drawing the picture under them.
        MarkupDrawings.setEditing(true, on: page)
        XCTAssertLessThan(try middle().blue, 100)
        MarkupDrawings.setEditing(false, on: page)
    }

    func testAPictureStaysWhenTheMacWritesOnThePage() throws {
        // A handwritten note with a picture, written on with the Mac's pencil (`PDFInk`, which PDFKit writes), then
        // saved again on the iPad: the picture keeps its JPEG all the way, and the file is compact again after.
        let image = try XCTUnwrap(PictureImage.make(from: photo()))
        let picture = PDFPicture(id: "photo", frame: CGRect(x: 80, y: 300, width: 360, height: 240), image: image)
        let made = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing, pictures: [picture]))]), base: try notebook())
        let url = folder.appendingPathComponent("Note.pdf")
        try made.write(to: url)
        let mac = PKDrawing(strokes: [stroke([CGPoint(x: 300, y: 600), CGPoint(x: 400, y: 650)])])
        try PDFInk.change(url) { PDFInk.put([0: drawing.appending(mac)], in: $0) }
        let written = try Data(contentsOf: url)
        let document = try XCTUnwrap(PDFDocument(data: written))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(PDFPictures.pictures(on: page).map(\.picture.id), ["photo"])
        XCTAssertEqual(NotebookPaper.style(of: page), .lined)
        XCTAssertEqual(PDFPictures.images(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: written as CFData)!)))["photo"]?.jpeg, image.jpeg)
        XCTAssertEqual(MarkupDrawings.strokes(in: try XCTUnwrap(page.annotations.first { $0.value(forAnnotationKey: MarkupDrawings.notebookKey) != nil }), on: page)?.drawing.strokes.count, 2)
        // The iPad's next save starts from that file.
        let again = try PDFPageWriter.make(PDFPlan(slots: [PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: drawing.appending(mac), pictures: [PDFPicture(id: "photo", frame: picture.frame)]))]), base: written)
        XCTAssertEqual(PDFPictures.images(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: again as CFData)!)))["photo"]?.jpeg, image.jpeg)
        XCTAssertLessThanOrEqual(again.count, made.count + 2_000)
    }

    // MARK: - Search

    func testSearchReadsTheHandwriting() throws {
        // The sample's lecture notes, read as search reads a page without text of its own: drawn, then Live Text.
        let url = folder.appendingPathComponent("Lecture 4.pdf")
        DemoHandwriting.writeLecture(to: url)
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertTrue(page.string?.isEmpty ?? true, "no text of its own")
        let box = page.bounds(for: .mediaBox)
        let scale = 2000 / box.height
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        let text = TextRecognizer.recognize(try XCTUnwrap(context.makeImage())).lowercased()
        for word in ["lecture", "eigenvalues", "summary", "direction"] {
            XCTAssertTrue(text.contains(word), "\(word) not read in: \(text)")
        }
    }

    // MARK: - Writing anew

    func testSavingAgainAndAgainKeepsTheFileSmall() throws {
        var base = try notebook(.lined, pages: 2)
        for step in 1...15 {
            var strokes = drawing
            strokes.strokes.append(stroke([CGPoint(x: 50, y: 300 + CGFloat(step) * 10), CGPoint(x: 400, y: 310 + CGFloat(step) * 10)]))
            base = try PDFPageWriter.make(PDFPlan(slots: [
                PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size, content: PageContent(drawing: strokes)),
                PDFPlan.Slot(origin: .base(1), size: PaperSize.a4.size, content: PageContent(drawing: strokes)),
            ]), base: base)
        }
        XCTAssertLessThan(base.count, 60_000, "\(base.count) bytes after 15 saves")
        let page = try XCTUnwrap(PDFDocument(data: base)?.page(at: 1))
        XCTAssertEqual(page.annotations.compactMap { MarkupDrawings.strokes(in: $0, on: page) }.first?.drawing.strokes.count, 2)
        XCTAssertEqual(NotebookPaper.style(of: page), .lined)
    }

    func testMarkupsDrawingsOnOtherPagesStayAsTheyWere() throws {
        // A drawing made with Markup in Files or Preview: a stamp with Markup's ink in its entry.
        let document = try XCTUnwrap(PDFDocument(data: try notebook(.lined, pages: 2)))
        let page = try XCTUnwrap(document.page(at: 0))
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("AKInkAnnotation2", for: FakeMarkupInk.self)
        archiver.encode(FakeMarkupInk(drawing: drawing.dataRepresentation(), size: page.bounds(for: .cropBox).size), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let stamp = PDFAnnotation(bounds: CGRect(x: 50, y: 600, width: 200, height: 100), forType: .stamp, withProperties: nil)
        stamp.setValue(["/AAPL:AKAnnotationV2": archiver.encodedData.base64EncodedString()] as NSDictionary, forAnnotationKey: MarkupDrawings.extrasKey)
        page.addAnnotation(stamp)
        XCTAssertNotNil(MarkupDrawings.strokes(in: stamp, on: page))
        let base = try XCTUnwrap(document.dataRepresentation())
        XCTAssertNil(try PDFPageWriter.compacted(try XCTUnwrap(PDFDocument(data: base)), images: [:], carriers: .init()))
        let made = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: PaperSize.a4.size),
            PDFPlan.Slot(origin: .base(1), size: PaperSize.a4.size, content: PageContent(drawing: drawing)),
        ]), base: base)
        // Written as PDFKit writes it, the stamp stays with Markup's entry. (On the Mac, PDFKit archives that entry
        // again with Markup's own classes, which a stand-in like this one doesn't survive; only iPhone and iPad write.)
        let kept = try XCTUnwrap(PDFDocument(data: made)?.page(at: 0))
        let markup = try XCTUnwrap(kept.annotations.first { $0.value(forAnnotationKey: MarkupDrawings.extrasKey) != nil && $0.bounds.minY == 600 })
        XCTAssertEqual(markup.bounds, stamp.bounds)
    }

    func testAPDFWithAnOutlineOrAFormIsntWrittenAnew() throws {
        // What lives outside the pages would be lost: such a PDF is written as PDFKit writes it.
        let document = try XCTUnwrap(PDFDocument(data: try notebook(.lined, pages: 2)))
        XCTAssertNotNil(try PDFPageWriter.compacted(document, images: [:], carriers: .init()))
        let root = PDFOutline()
        root.insertChild(PDFOutline(), at: 0)
        document.outlineRoot = root
        XCTAssertNil(try PDFPageWriter.compacted(document, images: [:], carriers: .init()))
        document.outlineRoot = nil
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        document.page(at: 1)?.addAnnotation(field)
        XCTAssertNil(try PDFPageWriter.compacted(document, images: [:], carriers: .init()))
    }
}

/// Writes the two entries of Markup's ink that Notebook reads.
@objc(NotebookTestsFakeMarkupInk)
private final class FakeMarkupInk: NSObject, NSCoding {
    let drawing: Data
    let size: CGSize

    init(drawing: Data, size: CGSize) {
        self.drawing = drawing
        self.size = size
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(drawing as NSData, forKey: "drawing")
        coder.encode(["Width": size.width, "Height": size.height] as NSDictionary, forKey: "drawingSize")
    }
}
