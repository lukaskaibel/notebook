import PDFKit
import XCTest

/// Writing on iPhone and iPad in a PDF that was drawn on and highlighted on a Mac (#284). `Fixtures/Drawn on a Mac.pdf`
/// is a handwritten note of two pages of lined paper, written by macOS PDFKit: on the first a stroke drawn as Preview's
/// Markup draws it (an ink annotation, with the Mac's own entry next to it) and a highlight, on the second strokes
/// drawn with Notebook on the Mac (#254). Saving it with pages added used to crash. The steps that are no touch of
/// their own (a picture from the library, Duplicate) go through the debug remote; the test reads the PDF it saves.
final class MacDrawnPDFUITests: XCTestCase {
    var app: XCUIApplication!
    private var library: URL!
    private let commands = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("commands-\(UUID().uuidString).txt")
    private var pdf: URL { library.appendingPathComponent("Inbox/Drawn on a Mac.pdf") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = FileManager.default.temporaryDirectory.appendingPathComponent("MacDrawnPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Drawn on a Mac", withExtension: "pdf"))
        try FileManager.default.copyItem(at: fixture, to: pdf)
        FileManager.default.createFile(atPath: commands.path, contents: nil)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: library)
        try? FileManager.default.removeItem(at: commands)
        try? FileManager.default.removeItem(at: commands.appendingPathExtension("log"))
        super.tearDown()
    }

    func testWritingInAPDFDrawnOnAMac() throws {
        let before = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(inks(before), [1, 0], "the fixture's stroke from Preview")
        XCTAssertEqual(notebookStrokes(before), [0, 1], "the fixture's strokes from Notebook on the Mac")
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", library.path, "-NotebookLibraryName", "Library", "-NotebookTips", "hide",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
        app.launch()
        remote("open Inbox/Drawn on a Mac.pdf")
        remote("wait 2")
        remote("pdfpen")
        remote("wait 3")
        // A picture on the first page, the page duplicated, a page of squared paper at the end and a picture on the page
        // drawn on with Notebook on the Mac, then the pen away: saved with pages added, which PDFKit couldn't write.
        remote("pdfpicture")
        remote("pdfduplicatepage 1")
        remote("pdfaddpage squared end")
        remote("pdfgotopage 3")
        remote("wait 1")
        remote("pdfpicture")
        remote("wait 1")
        remote("pdfpen off")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (PDFDocument(url: self.pdf)?.pageCount ?? 0) == 4 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 30), .completed, "not saved: \(PDFDocument(url: pdf)?.pageCount ?? 0) pages")
        XCTAssertEqual(app.state, .runningForeground, "Notebook quit")

        let after = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(papers(after), ["lined", "lined", "lined", "squared"])
        // Preview's stroke and the highlight stay on their page and its copy, as the Mac's PDFKit wrote them.
        XCTAssertEqual(inks(after), [1, 1, 0, 0])
        XCTAssertEqual(highlights(after), [1, 1, 0, 0])
        // The Mac's strokes, written again with the picture.
        XCTAssertEqual(notebookStrokes(after), [0, 0, 1, 0])
        XCTAssertEqual(pictures(after), [1, 1, 1, 0])
    }

    // MARK: - The file

    private func annotations(_ document: PDFDocument, _ count: (PDFAnnotation) -> Bool) -> [Int] {
        (0..<document.pageCount).map { document.page(at: $0)!.annotations.filter(count).count }
    }

    private func inks(_ document: PDFDocument) -> [Int] { annotations(document) { $0.type == "Ink" } }
    private func highlights(_ document: PDFDocument) -> [Int] { annotations(document) { $0.type == "Highlight" } }
    private func pictures(_ document: PDFDocument) -> [Int] {
        annotations(document) { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookPicture")) != nil }
    }

    private func notebookStrokes(_ document: PDFDocument) -> [Int] {
        annotations(document) { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookDrawing")) != nil }
    }

    private func papers(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { index in
            document.page(at: index)!.annotations.lazy.compactMap { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookPaper")) as? String }.first ?? "-"
        }
    }

    // MARK: - The debug remote

    /// Runs a debug remote command in the app, once it has done the ones before.
    private func remote(_ command: String, file: StaticString = #filePath, line: UInt = #line) {
        let log = commands.appendingPathExtension("log")
        let handle = try? FileHandle(forWritingTo: commands)
        handle?.seekToEndOfFile()
        handle?.write(Data((command + "\n").utf8))
        try? handle?.close()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("> \(command)\n") {
                // A wait is done once the next command runs.
                if command.hasPrefix("wait "), let seconds = Double(command.dropFirst(5)) { Thread.sleep(forTimeInterval: seconds) }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("no answer to \(command)", file: file, line: line)
    }
}
