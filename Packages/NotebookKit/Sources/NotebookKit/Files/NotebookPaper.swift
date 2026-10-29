import CoreGraphics
import Foundation
import PDFKit
#if os(iOS)
import UIKit
#endif

/// The paper of a handwritten note's pages: lines, squares or dots, drawn into the page itself as thin lines, so that
/// every PDF app shows them exactly as Notebook does and nothing in another app can pick them up or delete them. A
/// hidden annotation on the page says which paper it is (`/NotebookPaper`), so Notebook can add more of it and change
/// it; without it the page looks the same, and is simply a page.
public enum PaperStyle: String, CaseIterable, Identifiable, Sendable {
    case blank, lined, squared, dotted, cornell

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .blank: "Blank"
        case .lined: "Lined"
        case .squared: "Squared"
        case .dotted: "Dotted"
        case .cornell: "Cornell"
        }
    }

    public var symbol: String {
        switch self {
        case .blank: "doc"
        case .lined: "line.3.horizontal"
        case .squared: "squareshape.split.3x3"
        case .dotted: "circle.grid.3x3"
        case .cornell: "rectangle.split.1x2"
        }
    }
}

/// A note to write in: typed, a Markdown file, or handwritten, a PDF of paper.
public enum NoteKind: String, CaseIterable, Identifiable, Sendable {
    case typed, handwritten

    public var id: String { rawValue }
    public var name: String { self == .typed ? "Typed" : "Handwritten" }
    public var symbol: String { self == .typed ? "text.alignleft" : "pencil.and.scribble" }
}

/// What New Note makes: always one kind, or either, asked each time.
public enum NewNoteKind: String, CaseIterable, Identifiable, Sendable {
    case ask, typed, handwritten

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .ask: "Ask Each Time"
        case .typed: "Typed Note"
        case .handwritten: "Handwritten Note"
        }
    }

    /// Asked on the iPad, where you write as much as type; a typed note on the iPhone and the Mac.
    @MainActor static var standard: NewNoteKind {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .ask : .typed
        #else
        .typed
        #endif
    }
}

/// The size of a new handwritten note's pages: A4, or US Letter where that is the paper people buy.
public enum PaperSize: String, CaseIterable, Identifiable, Sendable {
    case a4, letter

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }

    /// Upright, in points.
    public var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .letter: CGSize(width: 612, height: 792)
        }
    }

    /// Letter in the Americas that use it and the Philippines, A4 everywhere else.
    public static var regional: PaperSize {
        let letter: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PA", "DO", "PR", "SV", "BZ"]
        return letter.contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
    }
}

enum NotebookPaper {
    /// The key of the hidden annotation that says which paper a page is.
    static let key = PDFAnnotationKey(rawValue: "/NotebookPaper")

    private static let millimetre: CGFloat = 72 / 25.4
    /// Lines 8 mm apart, as in a ruled exercise book; squares and dots 5 mm, as on squared paper.
    static let lineSpacing = 8 * millimetre
    static let gridSpacing = 5 * millimetre

    /// A one-page PDF of the paper, at `size` in points.
    static func pageData(_ style: PaperStyle, size: CGSize) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        // Measured from the top left, as the pages are read.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(style, size: size, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A page of the paper, ready to go into a document. Its marker goes on once it is in there (`mark`).
    static func page(_ style: PaperStyle, size: CGSize) -> PDFPage? {
        PDFDocument(data: pageData(style, size: size))?.page(at: 0)
    }

    /// A new handwritten note: one page of the paper, its marker on it.
    static func document(_ style: PaperStyle, size: CGSize) -> Data? {
        guard let document = PDFDocument(data: pageData(style, size: size)), let page = document.page(at: 0) else { return nil }
        mark(page, as: style)
        document.documentAttributes = [PDFDocumentAttribute.creatorAttribute: "Notebook"]
        return document.dataRepresentation()
    }

    /// Says which paper the page is. A page that has the marker already keeps only the new one.
    static func mark(_ page: PDFPage, as style: PaperStyle) {
        for annotation in page.annotations where annotation.value(forAnnotationKey: key) != nil {
            page.removeAnnotation(annotation)
        }
        let crop = page.bounds(for: .cropBox)
        let marker = PaperMarker(bounds: CGRect(x: crop.minX, y: crop.minY, width: 1, height: 1), forType: .stamp, withProperties: nil)
        marker.setValue(style.rawValue as NSString, forAnnotationKey: key)
        marker.shouldDisplay = false
        marker.shouldPrint = false
        marker.userName = ""
        // Under everything drawn on the page.
        let others = page.annotations
        others.forEach { page.removeAnnotation($0) }
        page.addAnnotation(marker)
        others.forEach { page.addAnnotation($0) }
    }

    /// The paper Notebook made the page with, if it did.
    static func style(of page: PDFPage) -> PaperStyle? {
        for annotation in page.annotations {
            if let value = annotation.value(forAnnotationKey: key) as? String { return PaperStyle(rawValue: value) }
        }
        return nil
    }

    /// Draws the paper's lines, measured from the top left.
    static func draw(_ style: PaperStyle, size: CGSize, in context: CGContext) {
        let rgb = CGColorSpaceCreateDeviceRGB()
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(colorSpace: rgb, components: [red, green, blue, 1]) ?? CGColor(gray: 0.7, alpha: 1)
        }
        // Light blue-grey, as printed exercise books are, and a red margin.
        let line = color(0.70, 0.78, 0.87)
        let margin = color(0.93, 0.56, 0.56)
        let dot = color(0.60, 0.65, 0.72)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.butt)
        switch style {
        case .blank:
            break
        case .lined:
            let top = 30 * millimetre
            context.setStrokeColor(line)
            context.setLineWidth(0.6)
            var y = top
            while y <= size.height - 12 * millimetre {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                y += lineSpacing
            }
            context.strokePath()
            context.setStrokeColor(margin)
            context.setLineWidth(0.8)
            context.move(to: CGPoint(x: 25 * millimetre, y: 0))
            context.addLine(to: CGPoint(x: 25 * millimetre, y: size.height))
            context.strokePath()
        case .squared, .dotted:
            // Whole squares, in the middle of the page with at least 8 mm around them.
            let columns = floor((size.width - 16 * millimetre) / gridSpacing)
            let rows = floor((size.height - 16 * millimetre) / gridSpacing)
            let left = (size.width - columns * gridSpacing) / 2
            let top = (size.height - rows * gridSpacing) / 2
            if style == .squared {
                context.setStrokeColor(line)
                context.setLineWidth(0.45)
                for column in 0...Int(columns) {
                    let x = left + CGFloat(column) * gridSpacing
                    context.move(to: CGPoint(x: x, y: top))
                    context.addLine(to: CGPoint(x: x, y: top + rows * gridSpacing))
                }
                for row in 0...Int(rows) {
                    let y = top + CGFloat(row) * gridSpacing
                    context.move(to: CGPoint(x: left, y: y))
                    context.addLine(to: CGPoint(x: left + columns * gridSpacing, y: y))
                }
                context.strokePath()
            } else {
                // A row of dots is one dashed line, its dashes of no length with round ends: a few lines, where a
                // circle for each dot would make the page a hundred kilobytes.
                context.setStrokeColor(dot)
                context.setLineWidth(1.5)
                context.setLineCap(.round)
                context.setLineDash(phase: 0, lengths: [0, gridSpacing])
                for row in 0...Int(rows) {
                    let y = top + CGFloat(row) * gridSpacing
                    context.move(to: CGPoint(x: left, y: y))
                    context.addLine(to: CGPoint(x: left + columns * gridSpacing + 0.5, y: y))
                }
                context.strokePath()
            }
        case .cornell:
            // A heading at the top, cues on the left, notes on the right, and a summary at the bottom.
            let heading = 25 * millimetre
            let summary = size.height - max(45 * millimetre, size.height * 0.2)
            let cues = (size.width * 0.3).rounded()
            context.setStrokeColor(line)
            context.setLineWidth(0.6)
            var y = heading + lineSpacing
            while y < summary - 2 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                y += lineSpacing
            }
            context.strokePath()
            context.setLineWidth(1.2)
            context.move(to: CGPoint(x: 0, y: heading))
            context.addLine(to: CGPoint(x: size.width, y: heading))
            context.move(to: CGPoint(x: cues, y: heading))
            context.addLine(to: CGPoint(x: cues, y: summary))
            context.move(to: CGPoint(x: 0, y: summary))
            context.addLine(to: CGPoint(x: size.width, y: summary))
            context.strokePath()
        }
    }
}

/// The hidden annotation that says which paper a page is. It has no look of its own.
private final class PaperMarker: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {}
}
