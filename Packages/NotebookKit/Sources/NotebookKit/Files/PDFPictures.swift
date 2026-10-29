import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A picture Notebook put on a PDF page: a stamp whose look is the picture, so every PDF app shows it where it was
/// put. Its entry (`/NotebookPicture`) has where it is and how far it is turned, for Notebook to move it again.
struct PDFPicture: Equatable, Sendable {
    var id: String
    /// Measured from the top left of the page's crop box, in points, before it is turned.
    var frame: CGRect
    /// Turned about its middle, clockwise as seen, in radians.
    var rotation: CGFloat = 0
    /// The picture to write. None for one already in the file, whose picture is taken from there.
    var image: PictureImage?

    /// The same place and turn, which leaves its stamp as it is.
    func isPlaced(like other: PDFPicture) -> Bool {
        abs(frame.minX - other.frame.minX) < 0.01 && abs(frame.minY - other.frame.minY) < 0.01
            && abs(frame.width - other.frame.width) < 0.01 && abs(frame.height - other.frame.height) < 0.01
            && abs(rotation - other.rotation) < 0.0001
    }
}

/// A picture as it goes into a PDF: JPEG, and the transparency of one that has some.
struct PictureImage: Equatable, Sendable {
    var jpeg: Data
    var width: Int
    var height: Int
    var isGray = false
    /// One byte for each pixel, row by row from the top, when it isn't opaque all over.
    var alpha: Data?

    /// The pixels, to show it.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let opaque = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        guard let alpha, alpha.count == width * height else { return opaque }
        // Put the transparency back: the colour as it was over white, and each pixel's alpha.
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return opaque }
        context.draw(opaque, in: CGRect(x: 0, y: 0, width: width, height: height))
        alpha.withUnsafeBytes { (mask: UnsafeRawBufferPointer) in
            for index in 0..<(width * height) {
                let a = Int(mask[index])
                let pixel = pixels + index * 4
                for channel in 0..<3 {
                    // Over white, c = a·colour + (1 − a)·255: the colour premultiplied is c − (255 − a).
                    pixel[channel] = UInt8(max(0, Int(pixel[channel]) - (255 - a)))
                }
                pixel[3] = UInt8(a)
            }
        }
        return context.makeImage() ?? opaque
    }

    /// The longest side a picture keeps: as sharp as a whole page wide on a Retina screen, without the 12 megapixels
    /// of a photo.
    static let largestSide = 2048

    /// From a picture's file: a JPEG that is upright and small enough is kept as it is, anything else drawn anew.
    static func make(from data: Data) -> PictureImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let model = properties[kCGImagePropertyColorModel] as? String
        if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, orientation == 1, model == (kCGImagePropertyColorModelRGB as String),
           width > 0, height > 0, max(width, height) <= largestSide, properties[kCGImagePropertyHasAlpha] as? Bool != true {
            return PictureImage(jpeg: data, width: width, height: height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: largestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return make(from: image)
    }

    /// From pixels, at most `largestSide` across.
    static func make(from image: CGImage) -> PictureImage? {
        let scale = min(1, CGFloat(largestSide) / CGFloat(max(image.width, image.height, 1)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let colour = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        colour.interpolationQuality = .high
        colour.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        colour.fill(rect)
        colour.draw(image, in: rect)
        var alpha: Data?
        if ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
           let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            mask.interpolationQuality = .high
            mask.draw(image, in: rect)
            if let bytes = mask.data?.assumingMemoryBound(to: UInt8.self) {
                var values = Data(count: width * height)
                var isOpaque = true
                values.withUnsafeMutableBytes { (alphas: UnsafeMutableRawBufferPointer) in
                    for index in 0..<(width * height) {
                        let value = bytes[index * 4 + 3]
                        alphas[index] = value
                        if value < 255 { isOpaque = false }
                    }
                }
                if !isOpaque { alpha = values }
            }
        }
        guard let flattened = colour.makeImage() else { return nil }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PictureImage(jpeg: jpeg as Data, width: width, height: height, alpha: alpha)
    }
}

enum PDFPictures {
    static let key = PDFAnnotationKey(rawValue: "/NotebookPicture")

    /// The pictures Notebook put on the page, and their stamps.
    static func pictures(on page: PDFPage) -> [(annotation: PDFAnnotation, picture: PDFPicture)] {
        page.annotations.compactMap { annotation in
            guard let value = annotation.value(forAnnotationKey: key) as? String, let picture = parse(value) else { return nil }
            return (annotation, picture)
        }
    }

    /// `id=…;x=…;y=…;w=…;h=…;r=…`: nothing in it a PDF string would have to escape.
    static func entry(for picture: PDFPicture) -> String {
        func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
        return "id=\(picture.id);x=\(number(picture.frame.minX));y=\(number(picture.frame.minY));w=\(number(picture.frame.width));h=\(number(picture.frame.height));r=\(String(format: "%.5f", Double(picture.rotation)))"
    }

    static func parse(_ entry: String) -> PDFPicture? {
        var values: [String: String] = [:]
        for part in entry.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let id = values["id"], !id.isEmpty,
              let x = values["x"].flatMap(Double.init), let y = values["y"].flatMap(Double.init),
              let width = values["w"].flatMap(Double.init), let height = values["h"].flatMap(Double.init), width > 0, height > 0 else { return nil }
        return PDFPicture(id: id, frame: CGRect(x: x, y: y, width: width, height: height), rotation: values["r"].flatMap(Double.init).map { CGFloat($0) } ?? 0)
    }

    /// The box a picture takes on its page once turned, measured from the top left of the crop box.
    static func bounds(of picture: PDFPicture) -> CGRect {
        guard picture.rotation != 0 else { return picture.frame }
        let center = CGPoint(x: picture.frame.midX, y: picture.frame.midY)
        let turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: picture.rotation).translatedBy(x: -center.x, y: -center.y)
        return picture.frame.applying(turn)
    }

    /// A one-page PDF with a stamp for each picture, its look the JPEG itself. PDFKit writes the looks of the
    /// annotations it makes as pictures without compression, many times the JPEG's size; one it read from a file keeps
    /// its look. So the stamps are made here and carried over (`PDFPageWriter`). `crop` is the page's crop box, which
    /// the carrier's page has too.
    static func carrier(_ pictures: [PDFPicture], crop: CGRect) -> Data {
        func number(_ value: CGFloat) -> String { String(format: "%.4f", Double(value)) }
        var objects: [Data] = []
        func add(_ object: Data) -> Int {
            objects.append(object)
            return objects.count
        }
        func add(_ text: String) -> Int { add(Data(text.utf8)) }
        func stream(_ dictionary: String, _ data: Data) -> Data {
            var object = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
            object.append(data)
            object.append(Data("\nendstream".utf8))
            return object
        }
        // 1 catalog, 2 pages, 3 page; the annotations after.
        _ = add("<< /Type /Catalog /Pages 2 0 R >>")
        _ = add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        _ = add("") // the page, once its annotations are known
        var annotations: [Int] = []
        for picture in pictures {
            guard let image = picture.image else { continue }
            var mask = ""
            if let alpha = image.alpha, let deflated = zlib(alpha) {
                let maskNumber = add(stream("/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", deflated))
                mask = " /SMask \(maskNumber) 0 R"
            }
            let imageNumber = add(stream("/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /\(image.isGray ? "DeviceGray" : "DeviceRGB") /BitsPerComponent 8 /Filter /DCTDecode\(mask)", image.jpeg))
            // In the PDF's space, y up: the box it takes, and the picture turned in its middle.
            let box = bounds(of: picture)
            let rect = CGRect(x: crop.minX + box.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height)
            let angle = -picture.rotation
            // Its corners a little round, as the canvas shows them.
            let (w, h) = (picture.frame.width / 2, picture.frame.height / 2)
            let r = min(4, w, h), k = r * 0.5523
            let corners = [
                "\(number(-w + r)) \(number(-h)) m \(number(w - r)) \(number(-h)) l",
                "\(number(w - r + k)) \(number(-h)) \(number(w)) \(number(-h + r - k)) \(number(w)) \(number(-h + r)) c \(number(w)) \(number(h - r)) l",
                "\(number(w)) \(number(h - r + k)) \(number(w - r + k)) \(number(h)) \(number(w - r)) \(number(h)) c \(number(-w + r)) \(number(h)) l",
                "\(number(-w + r - k)) \(number(h)) \(number(-w)) \(number(h - r + k)) \(number(-w)) \(number(h - r)) c \(number(-w)) \(number(-h + r)) l",
                "\(number(-w)) \(number(-h + r - k)) \(number(-w + r - k)) \(number(-h)) \(number(-w + r)) \(number(-h)) c h W n",
            ]
            let content = ([
                "q 1 0 0 1 \(number(box.width / 2)) \(number(box.height / 2)) cm",
                "\(number(cos(angle))) \(number(sin(angle))) \(number(-sin(angle))) \(number(cos(angle))) 0 0 cm",
            ] + corners + [
                "\(number(picture.frame.width)) 0 0 \(number(picture.frame.height)) \(number(-w)) \(number(-h)) cm",
                "/Im1 Do Q",
            ]).joined(separator: "\n")
            let form = add(stream("/Type /XObject /Subtype /Form /BBox [0 0 \(number(box.width)) \(number(box.height))] /Resources << /XObject << /Im1 \(imageNumber) 0 R >> >>", Data(content.utf8)))
            let annotation = add("<< /Type /Annot /Subtype /Stamp /Rect [\(number(rect.minX)) \(number(rect.minY)) \(number(rect.maxX)) \(number(rect.maxY))] /F 4 /NotebookPicture (\(entry(for: picture))) /AP << /N \(form) 0 R >> >>")
            annotations.append(annotation)
        }
        objects[2] = Data("<< /Type /Page /Parent 2 0 R /MediaBox [\(number(crop.minX)) \(number(crop.minY)) \(number(crop.maxX)) \(number(crop.maxY))] /Annots [\(annotations.map { "\($0) 0 R" }.joined(separator: " "))] >>".utf8)
        var pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let table = pdf.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        pdf.append(Data(trailer.utf8))
        return pdf
    }

    /// The pictures of the pictures Notebook put in a PDF, by their ids, read from the file's own objects: PDFKit
    /// doesn't hand out an annotation's look. A JPEG comes out as it went in.
    static func images(in document: CGPDFDocument, pages: Set<Int>? = nil) -> [String: PictureImage] {
        var found: [String: PictureImage] = [:]
        for number in 1...max(document.numberOfPages, 1) {
            guard pages?.contains(number - 1) ?? true, let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      let entry = string(in: annotation, "NotebookPicture"), let picture = parse(entry) else { continue }
                var appearances: CGPDFDictionaryRef?
                var normal: CGPDFStreamRef?
                guard CGPDFDictionaryGetDictionary(annotation, "AP", &appearances), let appearances,
                      CGPDFDictionaryGetStream(appearances, "N", &normal), let normal,
                      let image = firstImage(in: normal, depth: 0) else { continue }
                found[picture.id] = image
            }
        }
        return found
    }

    /// The first picture a look draws, looked for through the forms it draws too.
    private static func firstImage(in form: CGPDFStreamRef, depth: Int) -> PictureImage? {
        guard depth < 4, let dictionary = CGPDFStreamGetDictionary(form) else { return nil }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return nil }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        for stream in streams {
            guard let inner = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(inner, "Subtype", &subtype), let subtype else { continue }
            switch String(cString: subtype) {
            case "Image":
                if let image = image(from: stream) { return image }
            case "Form":
                if let image = firstImage(in: stream, depth: depth + 1) { return image }
            default:
                break
            }
        }
        return nil
    }

    private static func image(from stream: CGPDFStreamRef) -> PictureImage? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height), width > 0, height > 0 else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        var alpha: Data?
        var mask: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "SMask", &mask), let mask {
            var maskFormat = CGPDFDataFormat.raw
            if let values = CGPDFStreamCopyData(mask, &maskFormat) as Data?, maskFormat == .raw, values.count == Int(width * height) { alpha = values }
        }
        var space: UnsafePointer<CChar>?
        let isGray = CGPDFDictionaryGetName(dictionary, "ColorSpace", &space) && space.map { String(cString: $0) } == "DeviceGray"
        if format == .jpegEncoded {
            return PictureImage(jpeg: data, width: Int(width), height: Int(height), isGray: isGray, alpha: alpha)
        }
        // Written again by another app without its JPEG: plain pixels, eight bits each.
        let components = isGray ? 1 : 3
        guard format == .raw, data.count == Int(width * height) * components,
              let provider = CGDataProvider(data: data as CFData),
              let pixels = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: Int(width) * components,
                                   space: isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              var made = PictureImage.make(from: pixels) else { return nil }
        made.alpha = alpha
        return made
    }

    private static func string(in dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value, let text = CGPDFStringCopyTextString(value) else { return nil }
        return text as String
    }

    /// Deflated with zlib's header and checksum, as a PDF's FlateDecode wants it (`NSData`'s zlib has neither).
    static func zlib(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var result = Data([0x78, 0x9C])
        result.append(deflated)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let checksum = (b << 16) | a
        result.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return result
    }
}
