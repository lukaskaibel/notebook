#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import ImageIO
import PencilKit
import UniformTypeIdentifiers

/// The sample handwritten note: lecture notes on Cornell paper and a page of squared paper, written as a hand writes,
/// with a highlight, a ring, a sketch and a photo of the blackboard on them.
enum DemoHandwriting {
    static func writeLecture(to url: URL) {
        let size = PaperSize.a4.size
        guard let base = NotebookPaper.document(.cornell, size: size) else { return }
        let first = firstPage()
        let second = secondPage()
        var board: [PDFPicture] = []
        if let photo = boardPhoto(), let image = PictureImage.make(from: photo) {
            board.append(PDFPicture(id: "blackboard", frame: CGRect(x: 216, y: 258, width: 290, height: 174), rotation: -0.03, image: image))
        }
        let plan = PDFPlan(slots: [
            PDFPlan.Slot(origin: .base(0), size: size, content: PageContent(drawing: first, pictures: board)),
            PDFPlan.Slot(origin: .new, paper: .squared, size: size, content: PageContent(drawing: second)),
        ])
        guard let data = try? PDFPageWriter.make(plan, base: base) else { return }
        try? data.write(to: url)
    }

    /// Cornell paper: its heading line at 25 mm, then lines 8 mm apart, cues left of 30 % of the width.
    private static let millimetre: CGFloat = 72 / 25.4
    private static func line(_ number: Int) -> CGFloat { 25 * millimetre + CGFloat(number) * 8 * millimetre - 3 }

    private static func firstPage() -> PKDrawing {
        var pen = Pen()
        let ink: UInt32 = 0x1F2328, blue: UInt32 = 0x2853A8
        pen.write("Lecture 4 · Eigenvalues", size: 2.1, at: CGPoint(x: 26, y: 58), color: blue, width: 3.6, seed: 1)
        pen.write("Mon 26 Oct", size: 1.15, at: CGPoint(x: 476, y: 56), color: ink, seed: 2)
        // Cues.
        pen.write("Av = λv", size: 1.45, at: CGPoint(x: 22, y: line(1)), color: blue, seed: 3)
        pen.write("how to find λ?", size: 1.2, at: CGPoint(x: 22, y: line(4)), color: ink, seed: 4)
        pen.write("example", size: 1.2, at: CGPoint(x: 22, y: line(9)), color: ink, seed: 5)
        pen.write("check!", size: 1.2, at: CGPoint(x: 22, y: line(17)), color: ink, seed: 6)
        // Notes.
        pen.write("eigenvector v: A only stretches it", size: 1.3, at: CGPoint(x: 196, y: line(1)), color: ink, seed: 7)
        pen.write("by the factor λ, the eigenvalue", size: 1.3, at: CGPoint(x: 196, y: line(2)), color: ink, seed: 8)
        // The equation to remember, marked.
        pen.mark(from: CGPoint(x: 192, y: line(4) - 6), to: CGPoint(x: 340, y: line(4) - 7), seed: 9)
        pen.write("det(A - λI) = 0", size: 1.4, at: CGPoint(x: 196, y: line(4)), color: ink, seed: 10)
        pen.write("then solve (A - λI)v = 0 for v", size: 1.3, at: CGPoint(x: 196, y: line(5)), color: ink, seed: 11)
        pen.write("from the board:", size: 1.3, at: CGPoint(x: 196, y: line(8)), color: ink, seed: 12)
        // Under the photo of the board.
        pen.write("λ² - 4λ + 3 = 0  →  λ = 1, 3", size: 1.35, at: CGPoint(x: 196, y: line(17)), color: ink, seed: 13)
        pen.ring(center: CGPoint(x: 342, y: line(17) - 6), radii: CGSize(width: 37, height: 15), seed: 14)
        // A sketch: v, and Av along it, three times as long.
        let origin = CGPoint(x: 230, y: line(24))
        pen.stroke(pen.hand([(origin.x - 10, origin.y), (origin.x + 190, origin.y)], smooth: false, seed: 15), color: ink, width: 2.8)
        pen.stroke(pen.hand([(origin.x, origin.y + 10), (origin.x, origin.y - 110)], smooth: false, seed: 16), color: ink, width: 2.8)
        pen.arrow(from: origin, to: CGPoint(x: origin.x + 40, y: origin.y - 26), color: ink, seed: 17)
        pen.arrow(from: CGPoint(x: origin.x + 1, y: origin.y + 1), to: CGPoint(x: origin.x + 122, y: origin.y - 79), color: blue, seed: 18)
        pen.write("v", size: 1.3, at: CGPoint(x: origin.x + 24, y: origin.y - 30), color: ink, seed: 19)
        pen.write("Av = 3v", size: 1.3, at: CGPoint(x: origin.x + 126, y: origin.y - 78), color: blue, seed: 20)
        // The summary at the bottom.
        pen.write("Summary: eigenvectors keep their direction,", size: 1.3, at: CGPoint(x: 26, y: 708), color: ink, seed: 21)
        pen.write("λ says how far they stretch.", size: 1.3, at: CGPoint(x: 26, y: 732), color: ink, seed: 22)
        return PKDrawing(strokes: pen.strokes)
    }

    private static func secondPage() -> PKDrawing {
        var pen = Pen()
        let ink: UInt32 = 0x1F2328, blue: UInt32 = 0x2853A8, red: UInt32 = 0xD8432F
        pen.write("Sheet 3, task 2", size: 1.9, at: CGPoint(x: 40, y: 70), color: blue, width: 3.5, seed: 31)
        pen.write("p(λ) = (λ - 1)(λ - 3)", size: 1.4, at: CGPoint(x: 40, y: 114), color: ink, seed: 32)
        // The parabola through 1 and 3, on the squares.
        let unit: CGFloat = 5 * millimetre * 4
        let origin = CGPoint(x: 120, y: 420)
        pen.stroke(pen.hand([(origin.x - 30, origin.y), (origin.x + 5 * unit, origin.y)], smooth: false, seed: 33), color: ink, width: 2.8)
        pen.stroke(pen.hand([(origin.x, origin.y + 70), (origin.x, origin.y - 3.4 * unit)], smooth: false, seed: 34), color: ink, width: 2.8)
        let curve = stride(from: -0.2, through: 4.2, by: 0.2).map { (x: Double) -> (CGFloat, CGFloat) in
            (origin.x + CGFloat(x) * unit, origin.y - CGFloat((x - 1) * (x - 3)) * unit * 0.8)
        }
        pen.stroke(pen.hand(curve, seed: 35), color: blue, width: 3.4)
        for root in [1.0, 3.0] {
            let point = CGPoint(x: origin.x + CGFloat(root) * unit, y: origin.y)
            pen.stroke(pen.hand((0...24).map { index -> (CGFloat, CGFloat) in
                let angle = Double(index) / 22 * 2 * .pi
                return (point.x + CGFloat(cos(angle)) * 7, point.y + CGFloat(sin(angle)) * 7)
            }, seed: 36 + root), color: red, width: 3)
            pen.write(root == 1 ? "1" : "3", size: 1.3, at: CGPoint(x: point.x - 3, y: point.y + 26), color: ink, seed: 38 + root)
        }
        pen.write("λ", size: 1.4, at: CGPoint(x: origin.x + 5 * unit + 8, y: origin.y + 6), color: ink, seed: 41)
        pen.write("both roots are eigenvalues", size: 1.3, at: CGPoint(x: 40, y: 560), color: ink, seed: 42)
        return PKDrawing(strokes: pen.strokes)
    }

    /// A photo of the blackboard: chalk on green, a little turned, as a phone takes it in a lecture hall.
    private static func boardPhoto() -> Data? {
        let width = 1000, height = 600
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: 0.55, green: 0.5, blue: 0.44, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.17, green: 0.29, blue: 0.24, alpha: 1)
        context.fill(CGRect(x: 30, y: 40, width: 940, height: 540))
        // Chalk dust, wiped.
        for index in 0..<160 {
            let x = CGFloat((index * 97) % 920 + 40), y = CGFloat((index * 53) % 520 + 50)
            context.setFillColor(red: 0.9, green: 0.92, blue: 0.9, alpha: 0.03)
            context.fillEllipse(in: CGRect(x: x, y: y, width: 90, height: 30))
        }
        let font = CTFontCreateWithName("Chalkduster" as CFString, 52, nil)
        func chalk(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(red: 0.95, green: 0.96, blue: 0.93, alpha: 0.92),
            ]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        chalk("A =", 110, 425)
        chalk("2", 330, 470); chalk("1", 420, 470)
        chalk("1", 330, 380); chalk("2", 420, 380)
        chalk("det(A - λI) = (2 - λ)² - 1", 110, 250)
        chalk("λ = 1,  λ = 3", 110, 130)
        // The matrix's brackets.
        context.setStrokeColor(red: 0.95, green: 0.96, blue: 0.93, alpha: 0.9)
        context.setLineWidth(5)
        context.setLineCap(.round)
        for (x, direction) in [(CGFloat(312), CGFloat(1)), (CGFloat(472), CGFloat(-1))] {
            context.move(to: CGPoint(x: x + 12 * direction, y: 530))
            context.addQuadCurve(to: CGPoint(x: x + 12 * direction, y: 368), control: CGPoint(x: x - 14 * direction, y: 449))
        }
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writing and drawing as a hand does: through the points rounded, a little uneven, letters slanted. Point sizes
    /// as Apple Pencil leaves them: PencilKit draws a pen's line thinner than its points, and none below 2.
    private struct Pen {
        var strokes: [PKStroke] = []

        mutating func stroke(_ points: [CGPoint], _ type: PKInk.InkType = .pen, color: UInt32, width: CGFloat = 2) {
            guard points.count > 1 else { return }
            let path = points.enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) / 120, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            strokes.append(PKStroke(ink: PKInk(type, color: NSColor(hex: color)), path: PKStrokePath(controlPoints: path, creationDate: Date())))
        }

        func hand(_ points: [(CGFloat, CGFloat)], smooth: Bool = true, seed: Double, wobble: CGFloat = 0.5) -> [CGPoint] {
            let p = points.map { CGPoint(x: $0.0, y: $0.1) }
            guard p.count > 1 else { return p }
            var result: [CGPoint] = []
            for i in 0..<(p.count - 1) {
                let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
                let steps = max(2, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 1.5))
                for step in 0..<steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    var point: CGPoint
                    if smooth {
                        let t2 = t * t, t3 = t2 * t
                        func value(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                        }
                        point = CGPoint(x: value(p0.x, p1.x, p2.x, p3.x), y: value(p0.y, p1.y, p2.y, p3.y))
                    } else {
                        point = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                    }
                    let n = Double(result.count)
                    point.x += CGFloat(sin(n * 0.31 + seed)) * wobble
                    point.y += CGFloat(cos(n * 0.23 + seed * 1.7)) * wobble
                    result.append(point)
                }
            }
            result.append(p[p.count - 1])
            return result
        }

        /// Text in print, `at` the start of its baseline; `size` is a tenth of a capital's height.
        mutating func write(_ text: String, size: CGFloat, at origin: CGPoint, color: UInt32, width: CGFloat = 3, seed: Double) {
            var x = origin.x
            for (number, character) in text.enumerated() {
                guard let shape = Self.letters[character] else {
                    x += 3.2 * size
                    continue
                }
                // Each letter a little higher or lower, larger or smaller, and slanted.
                let wobble = Double(number) * 1.37 + seed
                let scale = size * (1 + CGFloat(sin(wobble)) * 0.035)
                let lift = CGFloat(cos(wobble * 0.7)) * 0.25 * size
                for (index, part) in shape.strokes.enumerated() {
                    let points = part.map { point -> (CGFloat, CGFloat) in
                        let y = (point.1 - 10) * scale
                        return (x + point.0 * scale - y * 0.14, origin.y + y + lift)
                    }
                    stroke(hand(points, seed: seed + Double(number * 7 + index), wobble: 0.18 * size), color: color, width: width)
                }
                x += (shape.width + 1.7) * scale
            }
        }

        /// A highlighter's mark under words.
        mutating func mark(from start: CGPoint, to end: CGPoint, seed: Double) {
            stroke(hand([(start.x, start.y), ((start.x + end.x) / 2, (start.y + end.y) / 2 + 1), (end.x, end.y)], seed: seed), .marker, color: 0xF5CC2E, width: 15)
        }

        /// A ring drawn round something, not quite closed.
        mutating func ring(center: CGPoint, radii: CGSize, seed: Double) {
            let points = (0...46).map { index -> (CGFloat, CGFloat) in
                let angle = Double(index) / 42 * 2 * .pi - 2.4
                return (center.x + CGFloat(cos(angle)) * radii.width, center.y + CGFloat(sin(angle)) * radii.height)
            }
            stroke(hand(points, seed: seed, wobble: 0.8), color: 0xD8432F, width: 3.2)
        }

        mutating func arrow(from start: CGPoint, to end: CGPoint, color: UInt32, seed: Double) {
            stroke(hand([(start.x, start.y), (end.x, end.y)], smooth: false, seed: seed), color: color, width: 3)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = [angle + 2.6, angle - 2.6].map { CGPoint(x: end.x + cos($0) * 11, y: end.y + sin($0) * 11) }
            stroke(hand([(head[0].x, head[0].y), (end.x, end.y), (head[1].x, head[1].y)], smooth: false, seed: seed + 0.5), color: color, width: 3)
        }

        /// Print letters as single strokes, in a box 10 high from the top of a capital to the baseline, the middle of a
        /// small letter at 4.5 and descenders below 10: (width, strokes).
        static let letters: [Character: (width: CGFloat, strokes: [[(CGFloat, CGFloat)]])] = [
            "a": (4.8, [[(4.6, 5.6), (3.4, 4.6), (1.8, 4.7), (0.4, 6.2), (0.3, 8.4), (1.4, 9.9), (3, 10), (4.6, 8.6)], [(4.8, 4.6), (4.8, 10)]]),
            "b": (4.8, [[(0, 0), (0, 10)], [(0, 6.4), (1.4, 4.8), (3, 4.5), (4.4, 5.6), (4.8, 7.4), (4.2, 9.3), (2.6, 10), (1, 9.6), (0, 8.4)]]),
            "c": (4.4, [[(4.4, 5.4), (3, 4.5), (1.4, 4.8), (0.2, 6.4), (0.2, 8.4), (1.4, 9.8), (3, 10), (4.4, 9.2)]]),
            "d": (4.8, [[(4.6, 5.6), (3.4, 4.6), (1.8, 4.7), (0.4, 6.2), (0.3, 8.4), (1.4, 9.9), (3, 10), (4.6, 8.6)], [(4.8, 0), (4.8, 10)]]),
            "e": (4.6, [[(0.3, 7.3), (4.6, 7.3), (4.4, 5.8), (3.2, 4.6), (1.6, 4.7), (0.4, 6), (0.2, 8), (1.2, 9.6), (2.8, 10), (4.4, 9.2)]]),
            "f": (3.6, [[(3.6, 0.6), (2.6, 0), (1.6, 0.3), (1.2, 1.6), (1.2, 10)], [(0, 4.6), (3.2, 4.6)]]),
            "g": (4.8, [[(4.6, 5.6), (3.4, 4.6), (1.8, 4.7), (0.4, 6.2), (0.3, 8.2), (1.4, 9.6), (3, 9.7), (4.6, 8.4)], [(4.8, 4.6), (4.8, 12), (4, 13.4), (2.4, 13.8), (0.6, 13)]]),
            "h": (4.6, [[(0, 0), (0, 10)], [(0, 6.4), (1.3, 4.8), (2.8, 4.5), (4.2, 5.4), (4.6, 7), (4.6, 10)]]),
            "i": (1, [[(0.5, 4.6), (0.5, 10)], [(0.5, 2.4), (0.6, 2.9)]]),
            "j": (1.8, [[(1.6, 4.6), (1.6, 12), (1, 13.4), (0, 13.8)], [(1.6, 2.4), (1.7, 2.9)]]),
            "k": (4.4, [[(0, 0), (0, 10)], [(4, 4.6), (0, 7.6)], [(1.2, 6.8), (4.4, 10)]]),
            "l": (1.8, [[(0.4, 0), (0.4, 9), (1.2, 10), (1.8, 9.8)]]),
            "m": (7.1, [[(0, 4.5), (0, 10)], [(0, 6.2), (1, 4.8), (2.2, 4.5), (3.2, 5.2), (3.5, 6.8), (3.5, 10)], [(3.5, 6.6), (4.5, 4.8), (5.8, 4.5), (6.8, 5.2), (7.1, 6.8), (7.1, 10)]]),
            "n": (4.6, [[(0, 4.5), (0, 10)], [(0, 6.4), (1.3, 4.8), (2.8, 4.5), (4.2, 5.4), (4.6, 7), (4.6, 10)]]),
            "o": (5, [[(2.5, 4.5), (0.8, 5.3), (0, 7.3), (0.8, 9.3), (2.5, 10), (4.2, 9.3), (5, 7.3), (4.2, 5.3), (2.5, 4.5)]]),
            "p": (4.8, [[(0, 4.5), (0, 13.8)], [(0, 6.4), (1.4, 4.8), (3, 4.5), (4.4, 5.6), (4.8, 7.4), (4.2, 9.3), (2.6, 10), (1, 9.6), (0, 8.4)]]),
            "q": (4.8, [[(4.6, 5.6), (3.4, 4.6), (1.8, 4.7), (0.4, 6.2), (0.3, 8.4), (1.4, 9.9), (3, 10), (4.6, 8.6)], [(4.8, 4.6), (4.8, 13.8)]]),
            "r": (3.4, [[(0, 4.5), (0, 10)], [(0, 6.6), (1.2, 5), (2.4, 4.5), (3.4, 4.8)]]),
            "s": (4.2, [[(4, 5.2), (2.8, 4.5), (1.2, 4.6), (0.3, 5.6), (0.8, 6.8), (2.4, 7.3), (3.8, 7.9), (4.2, 9), (3.2, 9.9), (1.6, 10), (0.2, 9.3)]]),
            "t": (3.8, [[(1.8, 1.4), (1.8, 9), (2.6, 10), (3.8, 9.7)], [(0, 4.7), (3.6, 4.7)]]),
            "u": (4.6, [[(0, 4.5), (0, 8.4), (0.8, 9.7), (2.2, 10), (3.6, 9.4), (4.6, 8)], [(4.6, 4.5), (4.6, 10)]]),
            "v": (4.6, [[(0, 4.5), (2.3, 10), (4.6, 4.5)]]),
            "w": (6.4, [[(0, 4.5), (1.6, 10), (3.2, 5.6), (4.8, 10), (6.4, 4.5)]]),
            "x": (4.4, [[(0, 4.5), (4.4, 10)], [(4.4, 4.5), (0, 10)]]),
            "y": (5, [[(0, 4.5), (2.6, 10)], [(5, 4.5), (2.6, 10), (1.6, 12.6), (0.4, 13.4)]]),
            "z": (4.4, [[(0, 4.6), (4.2, 4.6), (0, 10), (4.4, 10)]]),
            "A": (6, [[(0, 10), (3, 0), (6, 10)], [(1.2, 6.4), (4.8, 6.4)]]),
            "E": (5, [[(5, 0), (0, 0), (0, 10), (5, 10)], [(0, 5), (4, 5)]]),
            "I": (1, [[(0.5, 0), (0.5, 10)]]),
            "L": (4.8, [[(0, 0), (0, 10), (4.8, 10)]]),
            "M": (7, [[(0, 10), (0, 0), (3.5, 6.4), (7, 0), (7, 10)]]),
            "O": (6.4, [[(3.2, 0), (1, 1.4), (0, 5), (1, 8.6), (3.2, 10), (5.4, 8.6), (6.4, 5), (5.4, 1.4), (3.2, 0)]]),
            "S": (5.4, [[(5, 1.2), (3.6, 0), (1.6, 0), (0.3, 1.2), (0.6, 3.2), (2.6, 4.6), (4.6, 6), (5.4, 8), (4.4, 9.6), (2.4, 10), (0.4, 9)]]),
            "0": (5, [[(2.5, 0), (0.6, 1.2), (0, 5), (0.6, 8.8), (2.5, 10), (4.4, 8.8), (5, 5), (4.4, 1.2), (2.5, 0)]]),
            "1": (2.6, [[(0.4, 2), (2, 0), (2, 10)]]),
            "2": (5, [[(0.3, 2.2), (1.4, 0.4), (3, 0), (4.4, 0.8), (4.8, 2.6), (4, 4.6), (0, 10), (5, 10)]]),
            "3": (4.8, [[(0.4, 1.2), (2, 0), (3.8, 0.4), (4.6, 2), (3.8, 3.8), (2, 4.6)], [(2, 4.6), (4, 5.4), (4.8, 7.4), (3.8, 9.4), (2, 10), (0.2, 9)]]),
            "4": (5, [[(3.8, 10), (3.8, 0), (0, 7), (5, 7)]]),
            "6": (4.8, [[(4.2, 0.6), (2.6, 0), (1, 1), (0.1, 4), (0.2, 7.6), (1.2, 9.6), (2.6, 10), (4.2, 9.4), (4.8, 7.6), (4.2, 5.8), (2.6, 5.2), (1, 5.8), (0.2, 7.2)]]),
            "=": (4, [[(0, 5), (4, 5)], [(0, 7.4), (4, 7.4)]]),
            "-": (3.4, [[(0, 6.4), (3.4, 6.4)]]),
            "+": (4.4, [[(0, 6.2), (4.4, 6.2)], [(2.2, 4), (2.2, 8.4)]]),
            "(": (1.8, [[(1.8, 0), (0.4, 2.6), (0, 5.4), (0.4, 8.4), (1.8, 11)]]),
            ")": (1.8, [[(0, 0), (1.4, 2.6), (1.8, 5.4), (1.4, 8.4), (0, 11)]]),
            ",": (0.8, [[(0.6, 9.4), (0.6, 10.4), (0, 11.6)]]),
            ".": (0.6, [[(0.3, 9.6), (0.4, 10)]]),
            ":": (0.8, [[(0.4, 5), (0.5, 5.4)], [(0.4, 9.4), (0.5, 9.8)]]),
            "?": (4.4, [[(0.2, 1.8), (1.4, 0.2), (3, 0), (4.4, 1), (4.4, 2.8), (2.6, 4.6), (2.4, 6.8)], [(2.4, 9.4), (2.5, 9.8)]]),
            "!": (1, [[(0.5, 0), (0.5, 7)], [(0.5, 9.4), (0.6, 9.8)]]),
            "λ": (4.8, [[(0.4, 0), (1.4, 0.4), (4.8, 10)], [(2.6, 4.6), (0, 10)]]),
            "²": (2.8, [[(0, 1.2), (0.7, 0.2), (1.6, 0), (2.4, 0.5), (2.6, 1.4), (2.1, 2.4), (0, 4.6), (2.8, 4.6)]]),
            "·": (0.9, [[(0.4, 6.2), (0.5, 6.6)]]),
            "→": (6, [[(0, 6.2), (6, 6.2)], [(4, 4.6), (6, 6.2), (4, 7.8)]]),
        ]
    }
}
