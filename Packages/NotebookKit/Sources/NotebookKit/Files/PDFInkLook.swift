import CoreGraphics
import Foundation
import PencilKit

/// Notebook's strokes read back from their look, where nothing else of them is left.
///
/// Notebook before 1.4 kept its strokes in an entry of its own (`MarkupDrawings.notebookKey`), which Preview on iPhone
/// and iPad drops when it saves the page: all that is left is the stamp's look, the lines Notebook drew it with
/// (`InkAnnotation`). Notebook then showed the writing as PDFKit draws stamps, blurry, and couldn't change it. But the look
/// holds nearly all of the strokes: Notebook draws each one as a line through its points, a point every 1 pt, a new
/// piece where its width changes by more than 0.15 pt, a see-through one as one line, a lone point as a dot, in the
/// ink's colour. Read back, they are pens (markers where see-through) with those points and widths, which PencilKit
/// draws as before; the kind of pen, pressure, tilt and timing are gone.
///
/// Only a look that is Notebook's in every way is read: a stamp without an author, drawn with nothing but round lines and
/// dots in RGB, their points about 1 pt apart. Anyone else's stamp stays as it is.
enum PDFInkLook {
    /// The strokes Notebook drew as the look of `annotation`, a stamp at `rect` on a page with the crop box `crop`,
    /// measured from the crop box's top left. None for a look Notebook didn't draw.
    static func drawing(of annotation: CGPDFDictionaryRef, rect: CGRect, crop: CGRect) -> PKDrawing? {
        // Notebook writes no author (PDFKit would write the device owner's name).
        var author: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(annotation, "T", &author) {
            var text: CGPDFStringRef?
            guard CGPDFDictionaryGetString(annotation, "T", &text), let text, CGPDFStringGetLength(text) == 0 else { return nil }
        }
        var appearances: CGPDFDictionaryRef?
        var look: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(annotation, "AP", &appearances), let appearances,
              CGPDFDictionaryGetStream(appearances, "N", &look), let look, let form = CGPDFStreamGetDictionary(look),
              let box = numbers(in: form, "BBox", count: 4) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let content = CGPDFStreamCopyData(look, &format) as Data?, format == .raw else { return nil }
        // Where the look goes on the page: its box, turned by its matrix, fitted into the annotation's.
        let matrix = numbers(in: form, "Matrix", count: 6).map { CGAffineTransform(a: $0[0], b: $0[1], c: $0[2], d: $0[3], tx: $0[4], ty: $0[5]) } ?? .identity
        let turned = CGRect(x: min(box[0], box[2]), y: min(box[1], box[3]), width: abs(box[2] - box[0]), height: abs(box[3] - box[1])).applying(matrix)
        guard turned.width > 0, turned.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let toRect = CGAffineTransform(translationX: -turned.minX, y: -turned.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / turned.width, y: rect.height / turned.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(form, "Resources", &resources)
        var reader = Reader(placing: matrix.concatenating(toRect), crop: crop, resources: resources)
        guard reader.read([UInt8](content)) else { return nil }
        var date: Date?
        var modified: CGPDFStringRef?
        if CGPDFDictionaryGetString(annotation, "M", &modified), let modified { date = CGPDFStringCopyDate(modified) as Date? }
        return reader.drawing(createdAt: date ?? Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func numbers(in dictionary: CGPDFDictionaryRef, _ key: String, count: Int) -> [CGFloat]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == count else { return nil }
        var values = [CGPDFReal](repeating: 0, count: count)
        for index in 0..<count { guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil } }
        return values
    }

    /// Reads a look as `InkAnnotation` draws it (and PDFKit writes it), and nothing else.
    private struct Reader {
        /// A line through points, or a dot, as drawn: in the space of the drawing, with its width there.
        private struct Piece {
            var points: [CGPoint]
            var width: CGFloat
            var color: [CGFloat]
            var alpha: CGFloat
            var isDot: Bool
        }

        private struct State {
            var transform = CGAffineTransform.identity
            var width: CGFloat = 1
            var cap = 0
            var join = 0
            var strokeColor: [CGFloat] = [0, 0, 0]
            var fillColor: [CGFloat] = [0, 0, 0]
            var strokeAlpha: CGFloat = 1
            var fillAlpha: CGFloat = 1
        }

        private struct Subpath {
            var points: [CGPoint]
            var isCurved = false
            var isClosed = false
            var isRectangle = false
        }

        /// From the look's space to the page's.
        let placing: CGAffineTransform
        let crop: CGRect
        let resources: CGPDFDictionaryRef?
        private var state = State()
        private var saved: [State] = []
        private var path: [Subpath] = []
        private var pieces: [Piece] = []

        init(placing: CGAffineTransform, crop: CGRect, resources: CGPDFDictionaryRef?) {
            self.placing = placing
            self.crop = crop
            self.resources = resources
        }

        /// Whether the content is all Notebook's.
        mutating func read(_ bytes: [UInt8]) -> Bool {
            var operands: [Operand] = []
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if Self.isSpace(byte) {
                    index += 1
                } else if byte == UInt8(ascii: "%") {
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                } else if byte == UInt8(ascii: "/") {
                    let start = index + 1
                    index = start
                    while index < bytes.count, !Self.isSpace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
                    operands.append(.name(String(decoding: bytes[start..<index], as: UTF8.self)))
                } else if Self.isDelimiter(byte) {
                    // Text, arrays, dictionaries, pictures: nothing Notebook draws.
                    return false
                } else {
                    let start = index
                    while index < bytes.count, !Self.isSpace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
                    let word = String(decoding: bytes[start..<index], as: UTF8.self)
                    if let first = word.utf8.first, Array("0123456789+-.".utf8).contains(first) {
                        guard let number = Double(word) else { return false }
                        operands.append(.number(CGFloat(number)))
                    } else {
                        guard perform(word, operands) else { return false }
                        operands = []
                    }
                }
            }
            return !pieces.isEmpty && hasNotebooksSpacing
        }

        private enum Operand {
            case number(CGFloat)
            case name(String)
        }

        private mutating func perform(_ operation: String, _ operands: [Operand]) -> Bool {
            let numbers = operands.compactMap { if case let .number(value) = $0 { value } else { nil } }
            let allNumbers = numbers.count == operands.count
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(state.transform) }
            switch operation {
            case "q":
                saved.append(state)
            case "Q":
                guard let last = saved.popLast() else { return false }
                state = last
            case "cm":
                guard allNumbers, numbers.count == 6 else { return false }
                state.transform = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5]).concatenating(state.transform)
            case "w":
                guard allNumbers, numbers.count == 1 else { return false }
                state.width = numbers[0]
            case "J", "j":
                guard allNumbers, numbers.count == 1 else { return false }
                if operation == "J" { state.cap = Int(numbers[0]) } else { state.join = Int(numbers[0]) }
            case "CS", "cs":
                guard operands.count == 1, case .name = operands[0] else { return false }
            case "SC", "SCN", "RG", "sc", "scn", "rg":
                // RGB only, as Notebook writes every ink.
                guard allNumbers, numbers.count == 3 else { return false }
                if operation.first?.isUppercase == true { state.strokeColor = numbers } else { state.fillColor = numbers }
            case "gs":
                guard operands.count == 1, case let .name(name) = operands[0], let alphas = alphas(named: name) else { return false }
                (state.strokeAlpha, state.fillAlpha) = alphas
            case "m":
                guard allNumbers, numbers.count == 2 else { return false }
                path.append(Subpath(points: [point(numbers[0], numbers[1])]))
            case "l", "c":
                guard allNumbers, numbers.count == (operation == "l" ? 2 : 6), !path.isEmpty else { return false }
                path[path.count - 1].points.append(point(numbers[numbers.count - 2], numbers[numbers.count - 1]))
                if operation == "c" { path[path.count - 1].isCurved = true }
            case "h":
                guard !path.isEmpty else { return false }
                path[path.count - 1].isClosed = true
            case "re":
                guard allNumbers, numbers.count == 4 else { return false }
                path.append(Subpath(points: [point(numbers[0], numbers[1])], isRectangle: true))
            case "W", "W*":
                // The look's own box, clipped to; the path ends with `n`.
                break
            case "n":
                path = []
            case "S":
                guard stroke() else { return false }
            case "f", "f*":
                guard fill() else { return false }
            default:
                // Anything else (text, pictures, shadings, dashes, curves stroked, grey or CMYK): not Notebook's.
                return false
            }
            return true
        }

        /// The see-through of stroking and filling the graphics state of that name sets.
        private func alphas(named name: String) -> (CGFloat, CGFloat)? {
            var states: CGPDFDictionaryRef?
            var state: CGPDFDictionaryRef?
            guard let resources, CGPDFDictionaryGetDictionary(resources, "ExtGState", &states), let states,
                  CGPDFDictionaryGetDictionary(states, name, &state), let state else { return nil }
            // What it leaves out stays as it was.
            var stroke = self.state.strokeAlpha, fill = self.state.fillAlpha
            CGPDFDictionaryGetNumber(state, "CA", &stroke)
            CGPDFDictionaryGetNumber(state, "ca", &fill)
            return (stroke, fill)
        }

        /// Lines with round ends and corners, straight from point to point.
        private mutating func stroke() -> Bool {
            defer { path = [] }
            guard state.cap == 1, state.join == 1 else { return false }
            let scale = scale(of: state.transform.concatenating(placing))
            for subpath in path {
                guard !subpath.isCurved, !subpath.isClosed, !subpath.isRectangle else { return false }
                guard subpath.points.count > 1 else { continue }
                pieces.append(Piece(points: subpath.points.map(inDrawing), width: state.width * scale, color: state.strokeColor, alpha: state.strokeAlpha, isDot: false))
            }
            return true
        }

        /// Dots: round, filled.
        private mutating func fill() -> Bool {
            defer { path = [] }
            for subpath in path {
                guard subpath.isCurved, !subpath.isRectangle else { return false }
                let box = subpath.points.reduce(CGRect.null) { $0.union(CGRect(origin: inDrawing($1), size: .zero)) }
                guard box.width > 0, abs(box.width - box.height) <= max(box.width, box.height) * 0.05 + 0.01 else { return false }
                pieces.append(Piece(points: [CGPoint(x: box.midX, y: box.midY)], width: box.width, color: state.fillColor, alpha: state.fillAlpha, isDot: true))
            }
            return true
        }

        /// A point of the look (as its content draws it) on the page, measured from the crop box's top left.
        private func inDrawing(_ point: CGPoint) -> CGPoint {
            let onPage = point.applying(placing)
            return CGPoint(x: onPage.x - crop.minX, y: crop.maxY - onPage.y)
        }

        private func scale(of transform: CGAffineTransform) -> CGFloat {
            abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
        }

        /// A stroke as read: its points with their widths.
        private struct Stroke {
            var points: [(location: CGPoint, width: CGFloat)]
            var color: [CGFloat]
            var alpha: CGFloat
            var isDot: Bool
        }

        /// The pieces as Notebook drew them: one stroke is drawn in pieces where its width changes, each one going on
        /// from where the one before ended.
        private var strokes: [Stroke] {
            var strokes: [Stroke] = []
            for piece in pieces {
                let points = piece.points.map { (location: $0, width: piece.width) }
                if !piece.isDot, let last = strokes.last, !last.isDot, last.alpha == piece.alpha,
                   zip(last.color, piece.color).allSatisfy({ abs($0 - $1) < 0.0001 }),
                   let end = last.points.last?.location, let start = piece.points.first, hypot(end.x - start.x, end.y - start.y) < 0.001 {
                    // The piece starts where the last one ended, at its own width.
                    strokes[strokes.count - 1].points[last.points.count - 1].width = piece.width
                    strokes[strokes.count - 1].points += points.dropFirst()
                } else {
                    strokes.append(Stroke(points: points, color: piece.color, alpha: piece.alpha, isDot: piece.isDot))
                }
            }
            return strokes
        }

        /// Notebook puts a point every 1 pt (closer where a stroke turns, the last one wherever the stroke ends).
        private var hasNotebooksSpacing: Bool {
            var distances: [CGFloat] = []
            for piece in pieces where !piece.isDot {
                for (start, end) in zip(piece.points, piece.points.dropFirst()) { distances.append(hypot(end.x - start.x, end.y - start.y)) }
            }
            guard !distances.isEmpty else { return false }
            distances.sort()
            return (0.6...1.4).contains(distances[distances.count / 2])
        }

        func drawing(createdAt date: Date) -> PKDrawing {
            let strokes = strokes.enumerated().map { index, stroke -> PKStroke in
                // A see-through ink is a marker, which Notebook draws at half its colour's alpha.
                let isMarker = stroke.alpha < 1
                let alpha = isMarker ? min(stroke.alpha * 2, 1) : 1
                #if os(macOS)
                let color = NSColor(srgbRed: stroke.color[0], green: stroke.color[1], blue: stroke.color[2], alpha: alpha)
                #else
                let color = UIColor(red: stroke.color[0], green: stroke.color[1], blue: stroke.color[2], alpha: alpha)
                #endif
                let points = stroke.points.enumerated().map { number, point in
                    PKStrokePoint(location: point.location, timeOffset: Double(number) * 0.008, size: CGSize(width: point.width, height: point.width),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let path = PKStrokePath(controlPoints: points, creationDate: date.addingTimeInterval(Double(index) * 0.1))
                return PKStroke(ink: PKInk(isMarker ? .marker : .pen, color: color), path: path)
            }
            return PKDrawing(strokes: strokes)
        }

        private static func isSpace(_ byte: UInt8) -> Bool { [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(byte) }
        private static func isDelimiter(_ byte: UInt8) -> Bool { Array("()<>[]{}/%".utf8).contains(byte) }
    }
}
