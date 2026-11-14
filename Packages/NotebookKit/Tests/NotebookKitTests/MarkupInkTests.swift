import PDFKit
import PencilKit
import XCTest
@testable import NotebookKit

/// Handwriting written back and forth between Notebook and Apple's apps stays ink on both sides. Apple's apps (Preview,
/// Files, Quick Look) read strokes only from Markup's entry, and only while a copy of the annotation next to it still
/// matches it; anything else is a picture to them, drawn again as pixels with every save of theirs, so the writing
/// got blurrier with every turn. And Preview on iPhone and iPad saves PencilKit drawings as squares whose entry PDFKit
/// doesn't hand out, so Notebook showed those as Preview's picture.
///
/// `NOTEBOOK_KEEP_PDFS=<folder>` keeps the PDFs written, to try them in Preview.
final class MarkupInkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-markup-ink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let keep = ProcessInfo.processInfo.environment["NOTEBOOK_KEEP_PDFS"] {
            let target = URL(fileURLWithPath: keep).appendingPathComponent(name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test")
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: folder, to: target)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Notebook's strokes

    func testStrokesSavedOnTheMacAreMarkupInkWithTheCopyApplesAppsCheck() throws {
        let url = try blankPDF(pages: 2)
        try PDFInk.change(url) { PDFInk.put([1: self.drawing], in: $0) }
        let data = try Data(contentsOf: url)
        let entries = try notebookEntries(in: data)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.page, 1)
        XCTAssertEqual(entry.subtype, "Stamp")
        try assertMatchingCopy(entry)
        // Apple's ink class, the strokes measured on the crop box, which is the entry's box.
        XCTAssertEqual(entry.ink.drawing.strokes.count, 2)
        XCTAssertEqual(entry.ink.canvas, CGSize(width: 595, height: 842))
        XCTAssertEqual(entry.ink.rectangle, CGRect(x: 0, y: 0, width: 595, height: 842))
        XCTAssertEqual(entry.className, "AKInkAnnotation")
        // And read back by Notebook where they were drawn.
        let page = try XCTUnwrap(readDocument(data).page(at: 1))
        let read = try XCTUnwrap(page.annotations.lazy.compactMap { MarkupDrawings.strokes(in: $0, on: page) }.first)
        XCTAssertEqual(read.area, page.bounds(for: .cropBox))
        XCTAssertEqual(read.drawing.bounds, drawing.bounds)
        XCTAssertTrue(page.annotations.contains(where: MarkupDrawings.isNotebookInk))
    }

    func testStrokesSavedOnTheIPadAreMarkupInkToo() throws {
        let base = try Data(contentsOf: try blankPDF(pages: 2))
        let made = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: CGSize(width: 595, height: 842), content: PageContent(drawing: drawing)),
            PDFPlan.Slot(origin: .base(1), size: CGSize(width: 595, height: 842)),
        ]), base: base)
        try keep(made, as: "iPad.pdf")
        let entry = try XCTUnwrap(try notebookEntries(in: made).first)
        XCTAssertEqual(entry.page, 0)
        try assertMatchingCopy(entry)
        // Saved again on the iPad and then on the Mac: the copy is made again each time, and still matches.
        var again = try PDFPageWriter.make(PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: CGSize(width: 595, height: 842)),
            PDFPlan.Slot(origin: .base(1), size: CGSize(width: 595, height: 842), content: PageContent(drawing: drawing)),
        ]), base: made)
        let url = folder.appendingPathComponent("Again.pdf")
        try again.write(to: url)
        try PDFInk.change(url) { _ in }
        again = try Data(contentsOf: url)
        let entries = try notebookEntries(in: again)
        XCTAssertEqual(entries.map(\.page), [0, 1])
        for entry in entries { try assertMatchingCopy(entry) }
        // Completing what is complete changes nothing.
        XCTAssertEqual(PDFMarkupEntries.completed(again), again)
    }

    func testStrokesOfEarlierVersionsBecomeMarkupInkWithTheNextSave() throws {
        // As Notebook 1.3 wrote them: a stamp with Notebook's own entry, which Apple's apps take for a picture.
        let url = try blankPDF(pages: 2)
        let document = try XCTUnwrap(PDFDocument(url: url))
        for index in 0..<2 {
            let page = try XCTUnwrap(document.page(at: index))
            let stamp = PDFAnnotation(bounds: CGRect(x: 40, y: 600, width: 300, height: 100), forType: .stamp, withProperties: nil)
            stamp.setValue(drawing.dataRepresentation().base64EncodedString() as NSString, forAnnotationKey: MarkupDrawings.notebookKey)
            page.addAnnotation(stamp)
        }
        XCTAssertTrue(document.write(to: url))
        // Drawn on the second page only: the first one's strokes are written anew too.
        try PDFInk.change(url) { PDFInk.put([1: self.drawing.appending(PKDrawing(strokes: [self.stroke([CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 60)])]))], in: $0) }
        let data = try Data(contentsOf: url)
        let entries = try notebookEntries(in: data)
        XCTAssertEqual(entries.map(\.page), [0, 1])
        XCTAssertEqual(entries.map { $0.ink.drawing.strokes.count }, [2, 3])
        for entry in entries { try assertMatchingCopy(entry) }
        let read = try readDocument(data)
        for index in 0..<2 {
            let page = try XCTUnwrap(read.page(at: index))
            XCTAssertFalse(page.annotations.contains { $0.value(forAnnotationKey: MarkupDrawings.notebookKey) != nil }, "page \(index + 1)")
        }
    }

    // MARK: - Preview's strokes

    func testAPencilKitDrawingSavedByPreviewShowsWhereItIsAndSharp() throws {
        let data = previewPDF()
        let document = try readDocument(data)
        let page = try XCTUnwrap(document.page(at: 0))
        let square = try XCTUnwrap(page.annotations.first { $0.type == "Square" })
        let read = try XCTUnwrap(MarkupDrawings.strokes(in: square, on: page))
        // Fitted into the square, as PDFKit draws it: the box (50, 300, 400, 300), the strokes as wide as it, in its middle.
        XCTAssertEqual(read.area, CGRect(x: 50, y: 300, width: 400, height: 300))
        XCTAssertEqual(read.drawing.strokes.count, 1)
        // (PDFKit's own look of it has the ink from 1 to 398, 135 to 165.)
        XCTAssertEqual(read.drawing.bounds.minX, 0, accuracy: 1.5)
        XCTAssertEqual(read.drawing.bounds.maxX, 400, accuracy: 1.5)
        XCTAssertEqual(read.drawing.bounds.midY, 150, accuracy: 1)
        // Opened, the square is hidden and its page draws the strokes instead.
        let url = folder.appendingPathComponent("Preview.pdf")
        try data.write(to: url)
        let shown = try XCTUnwrap(PDFDocument(url: url))
        MarkupDrawings.sharpen(shown, fileAt: url)
        let shownPage = try XCTUnwrap(shown.page(at: 0))
        XCTAssertEqual(MarkupDrawings.drawing(on: shownPage).strokes.count, 1)
        XCTAssertEqual(shownPage.annotations.first { $0.type == "Square" }?.shouldDisplay, false)
    }

    func testWritingOnAPageWithPreviewsStrokesKeepsThemInkAndChangeable() throws {
        let url = folder.appendingPathComponent("Preview.pdf")
        try previewPDF().write(to: url)
        let original = try readDocument(previewPDF())
        let previewStrokes = try XCTUnwrap(original.page(at: 0)?.annotations.lazy.compactMap { MarkupDrawings.strokes(in: $0, on: original.page(at: 0)!) }.first)
        // As a canvas over the page starts: Preview's strokes, measured from the crop box; one more drawn.
        let shown = try XCTUnwrap(PDFDocument(url: url))
        MarkupDrawings.sharpen(shown, fileAt: url)
        let canvas = MarkupDrawings.drawing(on: try XCTUnwrap(shown.page(at: 0)))
        XCTAssertEqual(canvas.strokes.count, 1)
        try PDFInk.change(url) { PDFInk.put([0: canvas.appending(self.drawing)], in: $0) }
        let data = try Data(contentsOf: url)
        let page = try XCTUnwrap(readDocument(data).page(at: 0))
        XCTAssertFalse(page.annotations.contains { $0.type == "Square" }, "Preview's square is in Notebook's strokes now")
        let entry = try XCTUnwrap(try notebookEntries(in: data).first)
        XCTAssertEqual(entry.ink.drawing.strokes.count, 3)
        try assertMatchingCopy(entry)
        // Preview's stroke stays where it was on the page.
        let crop = page.bounds(for: .cropBox)
        let expected = previewStrokes.drawing.bounds.offsetBy(dx: previewStrokes.area.minX - crop.minX, dy: crop.maxY - previewStrokes.area.maxY)
        XCTAssertEqual(PKDrawing(strokes: [entry.ink.drawing.strokes[0]]).bounds.midX, expected.midX, accuracy: 0.5)
        XCTAssertEqual(PKDrawing(strokes: [entry.ink.drawing.strokes[0]]).bounds.midY, expected.midY, accuracy: 0.5)
    }

    func testPreviewsStrokesOnPagesNotWrittenOnStayAsPreviewSavedThem() throws {
        // Preview's drawing on the first page, a page added after it, Notebook writing on that one only.
        let url = folder.appendingPathComponent("Preview.pdf")
        try previewPDF().write(to: url)
        try PDFInk.change(url) { document in
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
            document.insert(page, at: 1)
            PDFInk.put([1: self.drawing], in: document)
        }
        let data = try Data(contentsOf: url)
        try keep(data, as: "Preview and Notebook.pdf")
        let found = PDFMarkupEntries.inks(in: try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!)))
        XCTAssertEqual(found[0]?.map(\.subtype), ["Square"])
        XCTAssertEqual(found[0]?.first?.ink.drawing.strokes.count, 1)
        XCTAssertEqual(found[1]?.map(\.subtype), ["Stamp"])
        // PDFKit leaves the entry out of a square it writes again: it is put back as it was, with a copy that matches
        // the square as written, and the square stays Preview's (no tag).
        let entries = try inkEntries(in: data)
        let preview = try XCTUnwrap(entries.first { $0.page == 0 })
        XCTAssertFalse(preview.isNotebook)
        XCTAssertEqual(preview.subtype, "Square")
        XCTAssertEqual(preview.archive, Self.previewArchive)
        try assertMatchingCopy(preview)
        try assertMatchingCopy(try XCTUnwrap(entries.first { $0.page == 1 && $0.isNotebook }))
        // Its look, Preview's picture, stays too: other apps show that.
        let page = try XCTUnwrap(readDocument(data).page(at: 0))
        XCTAssertNotNil(page.annotations.first { $0.type == "Square" })
    }

    // MARK: - Completing the entries

    func testWhatCantBeReadAsPDFKitWritesItIsLeftAsItIs() throws {
        XCTAssertEqual(PDFMarkupEntries.completed(Data()), Data())
        let garbage = Data("%PDF-1.7 NotebookInk startxref 999999 %%EOF".utf8)
        XCTAssertEqual(PDFMarkupEntries.completed(garbage), garbage)
        // Notebook's entry in a PDF with an incremental update: kept as it is.
        var data = try Data(contentsOf: try blankPDF(pages: 1))
        let url = folder.appendingPathComponent("Updated.pdf")
        try data.write(to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 0)?.addAnnotation(InkAnnotation(drawing: drawing, on: try XCTUnwrap(document.page(at: 0))))
        XCTAssertTrue(document.write(to: url))
        data = try Data(contentsOf: url)
        data.append(Data("\ntrailer\n<< /Size 1 /Prev 10 >>\nstartxref\n10\n%%EOF\n".utf8))
        XCTAssertEqual(PDFMarkupEntries.completed(data), data)
    }

    func testAnArchiveIsReadBackAsWritten() throws {
        let box = CGRect(x: 10, y: 20, width: 500, height: 700)
        let ink = try XCTUnwrap(MarkupInkArchive.decoded(try XCTUnwrap(MarkupInkArchive.encoded(drawing, in: box))))
        XCTAssertEqual(ink.drawing.strokes.count, 2)
        XCTAssertEqual(ink.drawing.bounds, drawing.bounds)
        XCTAssertEqual(ink.rectangle, box)
        XCTAssertEqual(ink.canvas, box.size)
        // Apple's own: PDFKit's square of a PencilKit drawing.
        let apple = try XCTUnwrap(MarkupInkArchive.decoded(Self.previewArchive))
        XCTAssertEqual(apple.canvas, .zero)
        XCTAssertEqual(apple.rectangle, CGRect(x: 50, y: 300, width: 400, height: 300))
        XCTAssertEqual(apple.drawing.strokes.count, 1)
    }

    // MARK: - Helpers

    private func stroke(_ points: [CGPoint]) -> PKStroke {
        var dense: [CGPoint] = []
        for (start, end) in zip(points, points.dropFirst()) {
            for step in 0..<20 { dense.append(CGPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 20, y: start.y + (end.y - start.y) * CGFloat(step) / 20)) }
        }
        dense.append(points[points.count - 1])
        let path = PKStrokePath(controlPoints: dense.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    private var drawing: PKDrawing {
        PKDrawing(strokes: [stroke([CGPoint(x: 80, y: 120), CGPoint(x: 260, y: 140)]), stroke([CGPoint(x: 90, y: 200), CGPoint(x: 300, y: 260)])])
    }

    private func blankPDF(pages: Int) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = folder.appendingPathComponent("Blank \(UUID().uuidString).pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func readDocument(_ data: Data) throws -> PDFDocument {
        let document = try XCTUnwrap(PDFDocument(data: data))
        MarkupDrawings.readInk(from: data, into: document)
        return document
    }

    private func keep(_ data: Data, as name: String) throws {
        try data.write(to: folder.appendingPathComponent(name))
    }

    /// Ink annotations in the file's bytes, with their entry and the copy next to it.
    private struct Entry {
        /// Keeps the dictionaries alive.
        var file: CGPDFDocument
        var isNotebook: Bool
        var archive: String
        var page: Int
        var subtype: String
        var annotation: CGPDFDictionaryRef
        var copy: CGPDFDictionaryRef?
        var ink: MarkupInkArchive.Ink
        var className: String
    }

    private func notebookEntries(in data: Data) throws -> [Entry] {
        try inkEntries(in: data).filter(\.isNotebook)
    }

    private func inkEntries(in data: Data) throws -> [Entry] {
        let file = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        var entries: [Entry] = []
        for number in 1...file.numberOfPages {
            var annotations: CGPDFArrayRef?
            guard let page = file.page(at: number)?.dictionary, CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var extras: CGPDFDictionaryRef?
                var copy: CGPDFDictionaryRef?
                var text: CGPDFStringRef?
                var subtype: UnsafePointer<CChar>?
                var marker: CGPDFObjectRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
                let isNotebook = CGPDFDictionaryGetObject(annotation, PDFMarkupEntries.notebookMarker, &marker)
                XCTAssertTrue(CGPDFDictionaryGetName(annotation, "Subtype", &subtype))
                guard CGPDFDictionaryGetDictionary(annotation, "AAPL:AKExtras", &extras), let extras else {
                    XCTAssertFalse(isNotebook, "Markup's entry on Notebook's strokes")
                    continue
                }
                guard CGPDFDictionaryGetString(extras, "AAPL:AKAnnotationV2", &text), let text,
                      let encoded = CGPDFStringCopyTextString(text) as String? else {
                    XCTAssertFalse(isNotebook, "ink in the entry of Notebook's strokes")
                    continue
                }
                CGPDFDictionaryGetDictionary(extras, "AAPL:AKPDFAnnotationDictionary", &copy)
                let archive = try XCTUnwrap(Data(base64Encoded: encoded))
                let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any])
                let classes = (plist["$objects"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["$classname"] as? String }
                entries.append(Entry(file: file, isNotebook: isNotebook, archive: encoded, page: number - 1, subtype: subtype.map { String(cString: $0) } ?? "", annotation: annotation, copy: copy,
                                     ink: try XCTUnwrap(MarkupInkArchive.decoded(encoded)), className: classes.first { $0.hasPrefix("AK") } ?? ""))
            }
        }
        return entries
    }

    /// Apple's apps use the ink only while the copy next to it is the annotation's dictionary, every key of it but its
    /// look and the entry: the same keys, the same kinds of values (a text isn't a name), the same values.
    private func assertMatchingCopy(_ entry: Entry, file: StaticString = #filePath, line: UInt = #line) throws {
        let copy = try XCTUnwrap(entry.copy, "the copy of the annotation next to Markup's entry", file: file, line: line)
        let annotation = describe(entry.annotation, skipping: ["AP", "AAPL:AKExtras"])
        XCTAssertFalse(annotation.isEmpty)
        XCTAssertEqual(describe(copy, skipping: []), annotation, file: file, line: line)
    }

    /// A dictionary's entries as text, with the kind of each value, references followed.
    private func describe(_ dictionary: CGPDFDictionaryRef, skipping: Set<String>, depth: Int = 0) -> [String: String] {
        var result: [String: String] = [:]
        CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
            let name = String(cString: key)
            if !skipping.contains(name) { result[name] = self.describe(object, depth: depth) }
            return true
        }, nil)
        return result
    }

    private func describe(_ object: CGPDFObjectRef, depth: Int) -> String {
        switch CGPDFObjectGetType(object) {
        case .name:
            var value: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &value)
            return "name " + (value.map { String(cString: $0) } ?? "")
        case .string:
            var value: CGPDFStringRef?
            CGPDFObjectGetValue(object, .string, &value)
            return "string " + (value.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "")
        case .integer, .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return "number \(value)"
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return "boolean \(value)"
        case .array:
            var array: CGPDFArrayRef?
            CGPDFObjectGetValue(object, .array, &array)
            guard let array else { return "array" }
            return "array [" + (0..<CGPDFArrayGetCount(array)).map { index -> String in
                var item: CGPDFObjectRef?
                CGPDFArrayGetObject(array, index, &item)
                return item.map { describe($0, depth: depth + 1) } ?? "?"
            }.joined(separator: ", ") + "]"
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            CGPDFObjectGetValue(object, .dictionary, &dictionary)
            guard let dictionary, depth < 3 else { return "dictionary" }
            return "dictionary " + describe(dictionary, skipping: [], depth: depth + 1).sorted { $0.key < $1.key }.description
        case .stream:
            return "stream"
        default:
            return "null"
        }
    }

    /// A PDF as Preview on iPhone and iPad saves a PencilKit drawing: PDFKit's square, with Markup's entry in the form
    /// PDFKit writes it (no canvas, the strokes fitted into the box) and the copy of the square next to it, laid out as
    /// PDFKit lays it out (Apple's apps take this one for ink). The entry is the one PDFKit made of a drawing put into
    /// the box (50, 300, 400, 300), its strokes at (98, 118, 238, 20).
    private func previewPDF() -> Data {
        let square = "/Type /Annot /T () /BS 5 0 R /Border [ 0 0 0 ] /Rect [ 50 300 450 600 ] /M (D:20261114154854Z00'00') /DA (/Helvetica 12 Tf 0 g) /F 708 /Subtype /Square"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [ 3 0 R ] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 595 842 ] /Annots [ 4 0 R ] >>",
            "<< \(square) /AAPL:AKExtras 6 0 R >>",
            "<< /W 0 >>",
            "<< /AAPL:AKAnnotationV2 (\(Self.previewArchive)) /AAPL:AKPDFAnnotationDictionary 7 0 R >>",
            "<< \(square) >>",
        ]
        var data = Data("%PDF-1.3\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let table = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n".utf8))
        return data
    }

    /// The entry PDFKit (macOS 27) writes for a PencilKit drawing put on a page in the box (50, 300, 400, 300).
    private static let previewArchive = """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBAL\
    DC4vPT4/QEFCQ0RLTB9UVSRudWxs3xARDQ4PEBESExQVFhcYGRobHB0eHyAhIiMeJSYnHiknHiwtI18QEXRleHRJc0ZpeGVkSGVpZ2h0XxAcb3JpZ2lu\
    YWxNb2RlbEJhc2VTY2FsZUZhY3RvcldkcmF3aW5nVmFrUGxhdFZha1ZlcnNfEA9mb3JtQ29udGVudFR5cGVfEBBBS0lzRm9ybUZpZWxkS2V5VFVVSURZ\
    cmVjdGFuZ2xlXxAYc2hvdWxkVXNlUGxhY2Vob2xkZXJUZXh0XXRleHRJc0NsaXBwZWRbZHJhd2luZ1NpemVfEB5lZGl0c0Rpc2FibGVBcHBlYXJhbmNl\
    T3ZlcnJpZGVfEBB0ZXh0SXNGaXhlZFdpZHRoXxAVY3VzdG9tUGxhY2Vob2xkZXJUZXh0ViRjbGFzc18QF29yaWdpbmFsRXhpZk9yaWVudGF0aW9uCCMA\
    AAAAAAAAAIAMEAEQAhAACIACgAMJCIANCQiAAIAPXxAkNjcxNTBGMjMtMDQ5Qy00MEQ1LTg4REMtQjIyQTdDNjEyMTU30zAxHDI3PFdOUy5rZXlzWk5T\
    Lm9iamVjdHOkMzQ1NoAEgAWABoAHpDg5OTuACIAJgAmACoALVVdpZHRoVkhlaWdodFFZUVgjQHkAAAAAAAAjQHLAAAAAAAAjQEkAAAAAAADSRUZHSFok\
    Y2xhc3NuYW1lWCRjbGFzc2VzXxATTlNNdXRhYmxlRGljdGlvbmFyeaNHSUpcTlNEaWN0aW9uYXJ5WE5TT2JqZWN0TxECKB+LCAAAAAAAABNt1G9IE3Ec\
    x/HvnNR1atwdLtZgIgdJrBjkKISc4u4WoUJRGSQaVDjs3xoRDBRJCEQjNIXAmYi5bHBCD5IimFCBlA9uPdKHGz6SHsQMEbIn1ueHPaj7bmN38Nru3vvd\
    7+4nkZY+IMmK7JvGTlMeWxWftw61h958yAy5xseimkKOl2+f5FLI68KeFJeX9GNydZX4wiM2frE5QjTYrKk37t0NXksk7vQEb8ZvBxM9ca87MC3J4jgc\
    r+3t8a49Gvi4f+/kKxGiH5Ea+uYmfH4/pN2R4eFGolX4jsOlMNE6nIx/PWe3w7/Dyw3HecLiHETSf75gWfAyw9nN2XZY/NbZ3SwW4QcNZxf/p4mo2nB2\
    p1KH4T6DdwPwWtZdyp6G17EuxgU/zrqFfDe8nnU3i3F4A+tiauBNrIvrAzdZV1XH4a2sO5VKwc+zrq7PwS+XGK8F72LdUGgRfp11l7JZeC/rmuYyPM66\
    mC/4A9bt6FiD97FuIZ+HD7JuLLYBf8S6mHf4EOsmkz/hIyWuMzUTPWFd0yyHj7Eu7h/4BOvm7Er4M9ZVVRU+WWK8Hvhz1sV9CJ9h3ULeD3/Burquw1+y\
    bixWB8+wbr1YBJYjHvHs+cUEYRGYbTlLV/rb3L3dl1ZabinyJyv65WT067uFtbJzc4uj9xV5IDOxfeLMq3Ro/urWKft1q/I2O/u+ImnsjP66mH462dV5\
    4e8q8wfNgMwFqAQAANMwMRxNUDyiMzSABIAFolFRgA6ADoAL0kVGVVZfEA9BS0lua0Fubm90YXRpb26jV1hKXxAPQUtJbmtBbm5vdGF0aW9uXEFLQW5u\
    b3RhdGlvbgAIABEAGgAkACkAMgA3AEkATABRAFMAZgBsAJEApQDEAMwA0wDaAOwA/wEEAQ4BKQE3AUMBZAF3AY8BlgGwAbEBugG8Ab4BwAHCAcMBxQHH\
    AcgByQHLAcwBzQHPAdEB+AH/AgcCEgIXAhkCGwIdAh8CJAImAigCKgIsAi4CNAI7Aj0CPwJIAlECWgJfAmoCcwKJAo0CmgKjBM8E1gTZBNsE3QTgBOIE\
    5ATmBOsE/QUBBRMAAAAAAAACAQAAAAAAAABZAAAAAAAAAAAAAAAAAAAFIA==
    """
}
