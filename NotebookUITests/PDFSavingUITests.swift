import PDFKit
import XCTest

/// What is written in a PDF on iPhone and iPad goes into it wherever it goes meanwhile: renamed or moved a moment after
/// a change, while that change is being saved (`-NotebookSlowDrawingSaves` makes a save take 3 s), it is in the file
/// under its new name or in its new folder, and no file comes back under the old one (#288). Changes after the move go
/// there too. And Undo after the PDF changed on another device (here the test, which puts a square on it) brings back
/// a page or a picture as it was (#291). The steps that are no touch of their own (a picture from the library, the
/// rename) go through the debug remote; the test reads the files.
final class PDFSavingUITests: XCTestCase {
    var app: XCUIApplication!
    private var library: URL!
    private let commands = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("commands-\(UUID().uuidString).txt")
    private var folder: URL { library.appendingPathComponent("University/Linear algebra") }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        library = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSaving-\(UUID().uuidString)", isDirectory: true)
        FileManager.default.createFile(atPath: commands.path, contents: nil)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: library)
        try? FileManager.default.removeItem(at: commands)
        try? FileManager.default.removeItem(at: commands.appendingPathExtension("log"))
        super.tearDown()
    }

    func testAPDFRenamedWhileItIsSavedKeepsWhatWasWritten() throws {
        launch()
        let old = folder.appendingPathComponent("Lecture 4.pdf"), new = folder.appendingPathComponent("Eigenvalues.pdf")
        let before = pictures(old)
        remote("open University/Linear algebra/Lecture 4.pdf")
        remote("wait 2")
        remote("pdfpen")
        remote("wait 3")
        // A picture, and the PDF renamed while that is being saved.
        remote("pdfpicture")
        remote("wait 2.5")
        remote("rename Eigenvalues")
        waitFor("the picture in the renamed PDF") { self.pictures(new) == before + 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "written again under its old name")
        // Written in after the rename: that goes into it too.
        remote("wait 1")
        remote("pdfpicture")
        waitFor("the second picture in the renamed PDF") { self.pictures(new) == before + 2 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "written again under its old name")
    }

    func testAPDFMovedWhileItIsSavedKeepsWhatWasWritten() throws {
        launch()
        let old = folder.appendingPathComponent("Lecture 4.pdf"), new = library.appendingPathComponent("Archive/Lecture 4.pdf")
        let before = pictures(old)
        remote("open University/Linear algebra/Lecture 4.pdf")
        remote("wait 2")
        remote("pdfpen")
        remote("wait 3")
        remote("pdfpicture")
        remote("wait 2.5")
        remote("move University/Linear algebra/Lecture 4.pdf > Archive")
        waitFor("the picture in the moved PDF") { self.pictures(new) == before + 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "written again where it was")
    }

    func testUndoOfDeletePageAfterAChangeElsewhereBringsThePageBack() throws {
        launch()
        let pdf = folder.appendingPathComponent("Lecture 4.pdf")
        let strokes = notebookStrokes(pdf)
        XCTAssertGreaterThan(strokes[2], 0, "the third page has writing")
        remote("open University/Linear algebra/Lecture 4.pdf")
        remote("wait 2")
        remote("pdfpen")
        remote("wait 3")
        remote("pdfdeletepage 3")
        waitFor("saved without the page") { self.papers(pdf).count == 4 }
        Thread.sleep(forTimeInterval: 1)
        try changeElsewhere(pdf)
        remote("pdfundo")
        waitFor("saved with the page back") { self.papers(pdf).count == 5 }
        XCTAssertEqual(papers(pdf), ["cornell", "squared", "lined", "dotted", "cornell"])
        XCTAssertEqual(notebookStrokes(pdf), strokes)
        XCTAssertEqual(squares(pdf), [1, 0, 0, 0, 0], "what the other device wrote")
    }

    func testAPictureTakenOffAndPutBackAfterAChangeElsewhereIsSaved() throws {
        launch()
        let pdf = folder.appendingPathComponent("Lecture 4.pdf")
        let before = pictures(pdf)
        remote("open University/Linear algebra/Lecture 4.pdf")
        remote("wait 2")
        remote("pdfpen")
        remote("wait 3")
        // The photo of the board on the first page, which was in the file when the pen went on.
        remote("pdfdeletepicture")
        waitFor("saved without the photo") { self.pictures(pdf) == before - 1 }
        Thread.sleep(forTimeInterval: 1)
        try changeElsewhere(pdf)
        remote("pdfundo")
        waitFor("saved with the photo back") { self.pictures(pdf) == before }
        XCTAssertEqual(squares(pdf).first, 1, "what the other device wrote")
    }

    // MARK: -

    /// Another device puts a square on the first page. Notebook's own entries are read first, which PDFKit writes
    /// again only then.
    private func changeElsewhere(_ url: URL) throws {
        let document = try XCTUnwrap(PDFDocument(url: url))
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)!.annotations {
                for key in ["/NotebookDrawing", "/NotebookPicture", "/NotebookPaper"] { _ = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) }
            }
        }
        let square = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 80, height: 40), forType: .square, withProperties: nil)
        square.color = .red
        document.page(at: 0)!.addAnnotation(square)
        XCTAssertTrue(document.write(to: url))
    }

    private func annotations(_ url: URL, _ count: (PDFAnnotation) -> Bool) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)!.annotations.filter(count).count }
    }

    private func notebookStrokes(_ url: URL) -> [Int] {
        annotations(url) { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookDrawing")) != nil }
    }

    private func squares(_ url: URL) -> [Int] { annotations(url) { $0.type == "Square" } }

    private func papers(_ url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { index in
            document.page(at: index)!.annotations.lazy.compactMap { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookPaper")) as? String }.first ?? "-"
        }
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-NotebookLibrary", library.path, "-NotebookLibraryName", "Library", "-NotebookDemo", "YES", "-NotebookTips", "hide",
                               "-NotebookSlowDrawingSaves", "3", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debugCommandFile", commands.path]
        app.launch()
    }

    /// The pictures Notebook put in the PDF; -1 when there is no PDF there.
    private func pictures(_ url: URL) -> Int {
        guard let document = PDFDocument(url: url) else { return -1 }
        return (0..<document.pageCount).reduce(0) { count, index in
            count + document.page(at: index)!.annotations.filter { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NotebookPicture")) != nil }.count
        }
    }

    private func waitFor(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed, "never: \(what)", file: file, line: line)
    }

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
