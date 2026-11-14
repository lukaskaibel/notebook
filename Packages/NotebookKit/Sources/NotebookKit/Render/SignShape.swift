import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The arrows no typeface of the note has a character for, made from the arrow it has, so they read as one family with
/// it: a long arrow is its arrow with a longer shaft, a double arrow two strokes as heavy as its dash under a head as
/// tall as its arrow's. Otherwise the system takes them from another font, thinner and smaller than the arrows next to
/// them (⟶ from Apple Symbols, ⇒ from a Japanese font).
enum SignShape {
    struct Shape {
        /// The outline, with the baseline at y = 0 and y going up, as a font's glyphs are.
        let path: CGPath
        let advance: CGFloat
    }

    /// The signs made here rather than taken from a font.
    static let signs: Set<String> = ["⟶", "⟵", "⟷", "⇒", "⇔"]

    /// Shapes made, by sign, font, size and weight (bold eases in along the weight axis, under one font name).
    private final class Made {
        let shape: Shape?
        init(_ shape: Shape?) { self.shape = shape }
    }

    nonisolated(unsafe) private static let made = NSCache<NSString, Made>()

    static func shape(_ sign: String, font: NSFont) -> Shape? {
        guard signs.contains(sign) else { return nil }
        let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
        let key = "\(sign)|\(font.fontName)|\(font.pointSize)|\(variation?[NSNumber(value: 0x7767_6874)]?.doubleValue ?? 0)" as NSString
        if let found = made.object(forKey: key) { return found.shape }
        let shape = make(sign, font: font)
        made.setObject(Made(shape), forKey: key)
        return shape
    }

    private static func make(_ sign: String, font: NSFont) -> Shape? {
        switch sign {
        // The end of the shaft, or for ↔ its right half, moves out.
        case "⟶": longArrow("→", font: font) { bounds, x in x > bounds.minX + bounds.width * 0.25 }
        case "⟵": longArrow("←", font: font) { bounds, x in x > bounds.maxX - bounds.width * 0.25 }
        case "⟷": longArrow("↔", font: font) { bounds, x in x > bounds.midX }
        case "⇒": doubleArrow(font: font, both: false)
        case "⇔": doubleArrow(font: font, both: true)
        default: nil
        }
    }

    /// Draws a sign's shape with its baseline at `origin`, in a view whose y goes down (as the text views' do).
    static func draw(_ shape: Shape, at origin: CGPoint, color: NSColor) {
        var flip = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: 1, y: -1)
        guard let path = shape.path.copy(using: &flip) else { return }
        color.setFill()
        NSBezierPath(cgPath: path).fill()
    }

    // MARK: - Making them

    /// The font that draws `character` at `font`'s size: the font itself, or the one the system falls back on (New York
    /// has no arrows; San Francisco's are drawn for it).
    private static func glyph(_ character: String, in font: NSFont) -> (font: CTFont, glyph: CGGlyph)? {
        var units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let base = font as CTFont
        if CTFontGetGlyphsForCharacters(base, &units, &glyphs, units.count) { return (base, glyphs[0]) }
        let fallback = CTFontCreateForString(base, character as CFString, CFRange(location: 0, length: units.count))
        guard CTFontGetGlyphsForCharacters(fallback, &units, &glyphs, units.count) else { return nil }
        return (fallback, glyphs[0])
    }

    private static func outline(_ character: String, in font: NSFont) -> (path: CGPath, advance: CGFloat, font: CTFont)? {
        guard let (face, glyph) = glyph(character, in: font), let path = CTFontCreatePathForGlyph(face, glyph, nil) else { return nil }
        var glyphs = [glyph]
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(face, .horizontal, &glyphs, &advance, 1)
        return (path, advance.width, face)
    }

    /// The font's own arrow with a longer shaft: the points `moves` picks go right, the others stay.
    private static func longArrow(_ arrow: String, font: NSFont, moves: (CGRect, CGFloat) -> Bool) -> Shape? {
        guard let (path, advance, _) = outline(arrow, in: font) else { return nil }
        let bounds = path.boundingBoxOfPath
        let extra = (bounds.width * 0.6).rounded()
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + (moves(bounds, point.x) ? extra : 0), y: point.y)
        }
        let result = CGMutablePath()
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: result.move(to: moved(e.points[0]))
            case .addLineToPoint: result.addLine(to: moved(e.points[0]))
            case .addQuadCurveToPoint: result.addQuadCurve(to: moved(e.points[1]), control: moved(e.points[0]))
            case .addCurveToPoint: result.addCurve(to: moved(e.points[2]), control1: moved(e.points[0]), control2: moved(e.points[1]))
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        return Shape(path: result, advance: advance + extra)
    }

    /// ⇒ as wide as the font's →, ⇔ a little wider than its ↔, on the same middle line: two strokes as heavy as its
    /// dash, as far apart as its `=`'s, and a head as tall as its arrow's.
    private static func doubleArrow(font: NSFont, both: Bool) -> Shape? {
        guard let arrow = outline(both ? "↔" : "→", in: font) else { return nil }
        let face = arrow.font as NSFont
        let bounds = arrow.path.boundingBoxOfPath
        let dash = outline("–", in: face)?.path.boundingBoxOfPath.height ?? face.pointSize * 0.08
        let equals = outline("=", in: face)?.path.boundingBoxOfPath.height ?? dash * 3.5
        let weight = max(dash, 0.5)
        let middle = bounds.midY
        // Each stroke's middle, above and below the middle line.
        let apart = max(equals - weight, weight * 2) / 2
        let half = max(bounds.height / 2 - weight / 2, apart * 2)
        let length = half
        // With a head at each end, a third wider, so the strokes between them show.
        let wider = both ? (bounds.width * 0.35).rounded() : 0
        let right = bounds.maxX + wider - weight / 2
        let left = bounds.minX + weight / 2
        let strokes = CGMutablePath()
        func head(tip: CGFloat, toward: CGFloat) {
            strokes.move(to: CGPoint(x: tip + toward * length, y: middle + half))
            strokes.addLine(to: CGPoint(x: tip, y: middle))
            strokes.addLine(to: CGPoint(x: tip + toward * length, y: middle - half))
        }
        head(tip: right, toward: -1)
        if both { head(tip: left, toward: 1) }
        // The strokes run into the heads, where they meet their lines.
        let inset = length * apart / half
        let start = both ? left + inset : left
        for y in [middle + apart, middle - apart] {
            strokes.move(to: CGPoint(x: start, y: y))
            strokes.addLine(to: CGPoint(x: right - inset, y: y))
        }
        let outline = strokes.copy(strokingWithWidth: weight, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return Shape(path: outline.union(outline, using: .winding), advance: arrow.advance + wider)
    }
}
