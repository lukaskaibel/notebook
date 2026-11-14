import Foundation
import PencilKit
import zlib

/// Handwriting in the entry Apple's Markup keeps it in (`/AAPL:AKExtras` › `/AAPL:AKAnnotationV2`): an archived ink
/// annotation with the strokes as a PencilKit drawing. Preview, Files and Quick Look read strokes kept there as ink
/// they can change stroke by stroke, and draw them sharp. Strokes kept anywhere else are a picture to them, which they
/// draw again as pixels whenever they save the page: written back and forth, the writing got blurrier every time.
///
/// Apple writes it two ways: with the page as the canvas, the strokes measured from its top left and the box the
/// annotation's own, tight around them (Markup in Preview, Files and Quick Look); or with no canvas size, the strokes
/// fitted into the box (PencilKit drawings that PDFKit puts on a page). Apple's editors place the strokes by both the
/// canvas and the box, so the box has to be the strokes' own: with the page's box in it, Quick Look put them off the
/// page.
enum MarkupInkArchive {
    /// What an entry holds: the strokes, where on the page they go, and how.
    struct Ink {
        var drawing: PKDrawing
        /// The annotation's box on the page, in PDF points (y up).
        var rectangle: CGRect?
        /// The canvas the strokes are measured on, from the box's top left; zero when they are fitted into the box.
        var canvas: CGSize
    }

    /// Apple's ink classes: the one Markup writes now and the one before it.
    static let classNames = ["AKInkAnnotation", "AKInkAnnotation2"]

    /// The entry for strokes measured from the top left of `page` (the page's crop box, for Notebook), in PDF points,
    /// as Apple writes it: the page is the canvas, the box is the strokes' own. Base64.
    static func encoded(_ drawing: PKDrawing, on page: CGRect) -> String? {
        guard let compressed = gzip(drawing.dataRepresentation()) else { return nil }
        let strokes = drawing.bounds
        let box = strokes.isNull || strokes.isEmpty ? CGRect(x: page.minX, y: page.maxY, width: 0, height: 0)
            : CGRect(x: page.minX + strokes.minX, y: page.maxY - strokes.maxY, width: strokes.width, height: strokes.height)
        let writer = Writer(drawing: compressed, rectangle: box, canvas: page.size)
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("AKInkAnnotation", for: Writer.self)
        archiver.encode(writer, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData.base64EncodedString()
    }

    /// The ink in an entry, from any of Apple's ink classes. None for an entry of anything else (a picture, a shape).
    nonisolated static func decoded(_ encoded: String) -> Ink? {
        guard let archive = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = false
        // Apple's own classes aren't here; one of ours reads the entries needed.
        for name in classNames { unarchiver.setClass(Reader.self, forClassName: name) }
        defer { unarchiver.finishDecoding() }
        guard let reader = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? Reader,
              let data = reader.drawing, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        return Ink(drawing: drawing, rectangle: reader.rectangle, canvas: reader.canvas)
    }

    // MARK: - Archiving

    /// Writes what Apple's ink annotation writes, every entry it has.
    @objc(NotebookMarkupInkWriter)
    private final class Writer: NSObject, NSCoding {
        let drawing: Data
        let rectangle: CGRect
        let canvas: CGSize

        init(drawing: Data, rectangle: CGRect, canvas: CGSize) {
            self.drawing = drawing
            self.rectangle = rectangle
            self.canvas = canvas
        }

        required init?(coder: NSCoder) { nil }

        func encode(with coder: NSCoder) {
            coder.encode(UUID().uuidString as NSString, forKey: "UUID")
            coder.encode(2, forKey: "akVers")
            #if os(macOS)
            coder.encode(1, forKey: "akPlat")
            #else
            coder.encode(2, forKey: "akPlat")
            #endif
            coder.encode(NSMutableDictionary(dictionary: [
                "X": rectangle.minX, "Y": rectangle.minY, "Width": rectangle.width, "Height": rectangle.height,
            ]), forKey: "rectangle")
            coder.encode(drawing as NSData, forKey: "drawing")
            coder.encode(NSMutableDictionary(dictionary: ["Width": canvas.width, "Height": canvas.height]), forKey: "drawingSize")
            coder.encode(false, forKey: "AKIsFormFieldKey")
            coder.encode(nil as NSString?, forKey: "customPlaceholderText")
            // Apple's apps show the look written in the PDF (Notebook's, made of lines) until the strokes are changed.
            coder.encode(true, forKey: "editsDisableAppearanceOverride")
            coder.encode(0, forKey: "formContentType")
            coder.encode(0, forKey: "originalExifOrientation")
            // A double: Apple's decoder gives up on the whole entry for an integer here.
            coder.encode(0.0 as Double, forKey: "originalModelBaseScaleFactor")
            coder.encode(true, forKey: "shouldUsePlaceholderText")
            coder.encode(false, forKey: "textIsClipped")
            coder.encode(false, forKey: "textIsFixedHeight")
            coder.encode(false, forKey: "textIsFixedWidth")
        }
    }

    /// Reads what Notebook needs of Apple's ink annotation.
    @objc(NotebookMarkupInk)
    private final class Reader: NSObject, NSCoding {
        let drawing: Data?
        let rectangle: CGRect?
        let canvas: CGSize

        init?(coder: NSCoder) {
            drawing = coder.decodeObject(forKey: "drawing") as? Data
            let numbers = { (key: String) -> [String: Double] in
                ((coder.decodeObject(forKey: key) as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            }
            let size = numbers("drawingSize")
            canvas = CGSize(width: size["Width"] ?? 0, height: size["Height"] ?? 0)
            let box = numbers("rectangle")
            if let x = box["X"], let y = box["Y"], let width = box["Width"], let height = box["Height"], width > 0, height > 0 {
                rectangle = CGRect(x: x, y: y, width: width, height: height)
            } else {
                rectangle = nil
            }
        }

        func encode(with coder: NSCoder) {}
    }

    // MARK: - Compressing

    /// The data gzip'd, as Apple keeps its drawings. (PencilKit reads them either way.)
    private static func gzip(_ data: Data) -> Data? {
        var stream = z_stream()
        // 15 + 16: a gzip header and trailer around the deflated data.
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, UInt(data.count))) + 32)
        let status: Int32 = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }
}
