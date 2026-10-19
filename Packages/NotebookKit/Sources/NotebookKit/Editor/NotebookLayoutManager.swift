#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the layout manager asks the editor while it lays out and draws.
@MainActor
protocol EditorLayoutSource: AnyObject {
    /// Whether hidden punctuation at this character is shown, because the caret is next to it.
    func isRevealed(_ characterIndex: Int) -> Bool
    var isDarkAppearance: Bool { get }
    /// Something drawn later than it was laid out (a picture finished decoding): draw it again.
    func objectNeedsDisplay(_ range: NSRange)
    /// Something changed size (a diagram finished drawing): lay it out again.
    func objectNeedsLayout(_ range: NSRange)
    func noteText(for url: URL) -> String?
    /// A drawing is open in a canvas over the text, which draws it.
    func showsCanvas(for picture: URL) -> Bool
}

/// TextKit 1 layout with Notebook's live preview: hidden Markdown punctuation gets no glyph at all, objects (checkboxes,
/// pictures, tables) are laid out as an empty box of their size in place of their first character and drawn into it.
/// Because nothing is inserted or removed, every character keeps its place and the caret never jumps.
@MainActor
final class NotebookLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
    weak var source: EditorLayoutSource?
    /// The ranges the text view has selected, for drawing selected objects.
    var selectedRanges: [NSRange] = []
    /// For a copy that is printed or exported: controls for editing (a link's pencil) take no room and aren't drawn.
    var hidesEditingControls = false
    /// Where the code block with the copy button over it starts: its language label makes way for the button.
    var copyButtonBlock: Int?

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = false
        usesFontLeading = false
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showsAsObject(_ object: EditorObject, _ index: Int) -> Bool {
        !object.revealable || !(source?.isRevealed(index) ?? false)
    }

    func object(at index: Int) -> EditorObject? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return storage.attribute(.notebookObject, at: index, effectiveRange: nil) as? EditorObject
    }

    func isHidden(_ index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length,
              let mode = storage.attribute(.notebookHidden, at: index, effectiveRange: nil) as? Int else { return false }
        return mode == HiddenMode.always.rawValue || !(source?.isRevealed(index) ?? false)
    }

    // MARK: - Glyphs

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage else { return 0 }
        let count = glyphRange.length
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<count {
            let index = charIndexes[i]
            guard index < storage.length else { continue }
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            if let object = attributes[.notebookObject] as? EditorObject, showsAsObject(object, index) {
                if changed == nil { changed = Array(UnsafeBufferPointer(start: props, count: count)) }
                changed![i] = .controlCharacter
            } else if let mode = attributes[.notebookHidden] as? Int,
                      mode == HiddenMode.always.rawValue || !(source?.isRevealed(index) ?? false) {
                // A control glyph without width rather than a null glyph: null glyphs at the start of a paragraph
                // make TextKit lay its first line out as a continuation line.
                if changed == nil { changed = Array(UnsafeBufferPointer(start: props, count: count)) }
                changed![i] = .controlCharacter
            }
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let object = object(at: charIndex), showsAsObject(object, charIndex) { return .whitespace }
        if isHidden(charIndex) { return .zeroAdvancement }
        return action
    }

    /// Lines that hold a picture, table or diagram are as tall as it is, worked out when the line is laid out so
    /// the size follows the width of the window.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let (index, object) = blockObject(inGlyphRange: glyphRange) else { return false }
        let style = textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let before = style?.paragraphSpacingBefore ?? 0
        let after = style?.paragraphSpacing ?? 0
        let size = blockSize(object, at: index, width: lineFragmentRect.pointee.width - (style?.firstLineHeadIndent ?? 0))
        lineFragmentRect.pointee.size.height = before + size.height + after
        lineFragmentUsedRect.pointee.size.height = before + size.height
        lineFragmentUsedRect.pointee.size.width = max(lineFragmentUsedRect.pointee.width, size.width)
        baselineOffset.pointee = before + size.height
        return true
    }

    /// The picture, table or diagram that makes up a line, if it holds one.
    func blockObject(inGlyphRange glyphRange: NSRange) -> (Int, EditorObject)? {
        guard let storage = textStorage else { return nil }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var found: (Int, EditorObject)?
        storage.enumerateAttribute(.notebookObject, in: characters) { value, range, stop in
            if let object = value as? EditorObject, object.isBlock, showsAsObject(object, range.location) {
                found = (range.location, object)
                stop.pointee = true
            }
        }
        return found
    }

    /// The size a block object is drawn at in a line this wide.
    func blockSize(_ object: EditorObject, at index: Int, width: CGFloat) -> CGSize {
        box(for: object, at: index, width: max(40, width - 2), font: EditorStyle.body).size
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let object = object(at: charIndex) else { return .zero }
        let font = (textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? EditorStyle.body
        if object.isBlock {
            // The line is made as tall as the object in shouldSetLineFragmentRect; here it only takes the width.
            let size = blockSize(object, at: charIndex, width: proposedRect.width)
            return NSRect(x: 0, y: 0, width: size.width, height: 1)
        }
        let available = max(40, proposedRect.width - glyphPosition.x - 2)
        return box(for: object, at: charIndex, width: available, font: font)
    }

    /// The room an object takes, relative to the baseline of its line.
    private func box(for object: EditorObject, at index: Int, width: CGFloat, font: NSFont) -> NSRect {
        let objectRange = object.range(at: index)
        switch object.kind {
        case .bullet:
            return NSRect(x: 0, y: 0, width: EditorStyle.listIndent, height: 4)
        case .checkbox:
            return NSRect(x: 0, y: 0, width: EditorStyle.checkboxWidth, height: 4)
        case .quoteBar:
            return NSRect(x: 0, y: 0, width: EditorStyle.quoteIndent, height: 4)
        case .chipLead:
            return NSRect(x: 0, y: 0, width: font.pointSize + 6, height: 4)
        case .chipTrail:
            return NSRect(x: 0, y: 0, width: 6, height: 4)
        case .image(let url, _, let inline):
            let size = url.flatMap { ImageStore.shared.size(of: $0) }
            if inline {
                guard let size else { return NSRect(x: 0, y: font.descender, width: font.pointSize * 1.4, height: font.pointSize * 1.4) }
                let height = min(size.height, font.pointSize * 1.4)
                return NSRect(x: 0, y: font.descender, width: size.width * height / size.height, height: height)
            }
            guard let size else { return NSRect(x: 0, y: 0, width: min(width, 420), height: 64) }
            var display = size
            if display.width > width { display = CGSize(width: width, height: size.height * width / size.width) }
            if display.height > 560 { display = CGSize(width: display.width * 560 / display.height, height: 560) }
            return NSRect(x: 0, y: 0, width: floor(display.width), height: floor(display.height))
        case .drawing(let url):
            // As wide as the text, wherever it was drawn; as tall as that makes it.
            let size = DrawingStore.shared.size(of: url) ?? ImageStore.shared.size(of: url) ?? CGSize(width: width, height: width / 2)
            return NSRect(x: 0, y: 0, width: floor(width), height: max(24, (size.height * floor(width) / max(1, size.width)).rounded()))
        case .fileCard:
            return NSRect(x: 0, y: 0, width: min(width, 440), height: 68)
        case .noteEmbed:
            return NSRect(x: 0, y: 0, width: width, height: 116)
        case .horizontalRule:
            return NSRect(x: 0, y: 0, width: width, height: 4)
        case .table(let model):
            let size = model.layout(maxWidth: width).size
            return NSRect(x: 0, y: 0, width: min(width, size.width + 1), height: size.height + 1)
        case .mermaid(let source):
            switch DiagramStore.diagram(source, isDark: self.source?.isDarkAppearance ?? false, ready: { [weak self] in self?.source?.objectNeedsLayout(objectRange) }) {
            case .some(.some(let image)):
                var size = image.size
                if size.width > width { size = CGSize(width: width, height: size.height * width / size.width) }
                return NSRect(x: 0, y: 0, width: width, height: ceil(size.height) + 16)
            case .some(.none):
                return NSRect(x: 0, y: 0, width: width, height: 64)
            case .none:
                return NSRect(x: 0, y: 0, width: width, height: 120)
            }
        case .mathBlock(let tex):
            guard let math = MathStore.render(tex, display: true, size: 19, color: Theme.text.resolved(dark: source?.isDarkAppearance ?? false)) else {
                return NSRect(x: 0, y: 0, width: width, height: 44)
            }
            return NSRect(x: 0, y: 0, width: width, height: ceil(math.image.size.height) + 20)
        case .mathInline(let tex):
            guard let math = MathStore.render(tex, display: false, size: font.pointSize * 1.08, color: Theme.text.resolved(dark: source?.isDarkAppearance ?? false)) else {
                return NSRect(x: 0, y: 0, width: font.pointSize, height: font.pointSize)
            }
            return NSRect(x: 0, y: -math.descent, width: ceil(math.image.size.width) + 2, height: ceil(math.ascent + math.descent))
        case .callout(let type, let label):
            var width: CGFloat = 24
            if let label {
                width += ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: EditorStyle.bodySize, weight: .semibold)]).width) + 4
            }
            _ = type
            return NSRect(x: 0, y: 0, width: width, height: 4)
        case .linkEdit:
            return NSRect(x: 0, y: 0, width: hidesEditingControls ? 0 : ceil(font.pointSize * 0.85) + 3, height: 4)
        case .frontmatter(let count):
            let text = frontmatterLabel(count) as NSString
            let textWidth = ceil(text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width)
            return NSRect(x: 0, y: 0, width: textWidth + 40, height: 26)
        }
    }

    private func frontmatterLabel(_ count: Int) -> String {
        count == 1 ? "1 property" : "\(count) properties"
    }

    // MARK: - Geometry

    /// Where an object's box is, in the text view's coordinates.
    func rect(forObjectAt index: Int, origin: NSPoint) -> NSRect? {
        guard let container = textContainers.first, index < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs, propertyForGlyph(at: glyph) == .controlCharacter, let object = object(at: index), showsAsObject(object, index) else { return nil }
        return boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Where a picture, table or drawing on a line of its own is drawn, in the text view's coordinates: the whole
    /// box, which the glyph's own rectangle isn't.
    func blockObjectRect(at index: Int, origin: NSPoint) -> NSRect? {
        guard let object = object(at: index), object.isBlock, index < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs, propertyForGlyph(at: glyph) == .controlCharacter else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let size = blockSize(object, at: index, width: line.width - (style?.firstLineHeadIndent ?? 0))
        return NSRect(x: line.minX + (style?.firstLineHeadIndent ?? 0) + origin.x, y: line.minY + origin.y + (style?.paragraphSpacingBefore ?? 0),
                      width: size.width, height: size.height)
    }

    /// The baseline of the line a glyph is on, as drawn. The glyph's location is already raised by the line's baseline
    /// offset: taking it off again put checkboxes and bullets two points above the middle of their text.
    private func baseline(forGlyphAt glyph: Int, origin: NSPoint) -> CGFloat {
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return origin.y + line.minY + location(forGlyphAt: glyph).y
    }

    private func isSelected(_ range: NSRange) -> Bool {
        selectedRanges.contains { $0.length > 0 && NSIntersectionRange($0, range).length == range.length }
    }

    // MARK: - Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            var drawn = Set<ObjectIdentifier>()
            storage.enumerateAttribute(.notebookDecoration, in: characters) { value, run, _ in
                guard let decoration = value as? Decoration, !drawn.contains(ObjectIdentifier(decoration)) else { return }
                drawn.insert(ObjectIdentifier(decoration))
                drawDecoration(decoration, range: extent(of: decoration, around: run), container: container, origin: origin)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Where a heading's level shows while the caret is on it: in the margin, left of the text.
    func headingMarkRect(at index: Int, origin: NSPoint) -> NSRect? {
        guard let storage = textStorage, index < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? EditorStyle.body
        let center = baseline(forGlyphAt: glyph, origin: origin) - font.capHeight / 2
        return NSRect(x: origin.x + line.minX - 34, y: center - 9, width: 24, height: 18)
    }

    func drawHeadingMark(_ level: Int, in rect: NSRect) {
        Theme.control.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let label = NSAttributedString(string: "H\(level)", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: Theme.textTertiary])
        let size = label.size()
        label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// Selected pictures, tables and diagrams draw their own selection, so the text selection behind them is left out.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        if let storage = textStorage, charRange.length > 0, charRange.upperBound <= storage.length {
            var covered = true
            var index = charRange.location
            while index < charRange.upperBound {
                if let object = object(at: index), object.isBlock, showsAsObject(object, index) {
                    index = max(index + 1, object.range(at: index).upperBound)
                } else if let mode = storage.attribute(.notebookHidden, at: index, effectiveRange: nil) as? Int, mode == HiddenMode.always.rawValue {
                    index += 1
                } else if (storage.string as NSString).character(at: index) == 10 {
                    index += 1
                } else {
                    covered = false
                    break
                }
            }
            if covered { return }
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.notebookObject, in: characters) { value, range, _ in
            guard let object = value as? EditorObject else { return }
            for index in range.location..<range.upperBound {
                guard showsAsObject(object, index) else { continue }
                let glyph = glyphIndexForCharacter(at: index)
                guard glyph < numberOfGlyphs, propertyForGlyph(at: glyph) == .controlCharacter else { continue }
                var rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).offsetBy(dx: origin.x, dy: origin.y)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
                if object.isBlock {
                    let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
                    let indent = style?.firstLineHeadIndent ?? 0
                    let size = blockSize(object, at: index, width: line.width - indent)
                    rect = NSRect(x: line.minX + indent, y: line.minY + (style?.paragraphSpacingBefore ?? 0), width: size.width, height: size.height)
                }
                let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? EditorStyle.body
                draw(object, range: object.range(at: index), in: rect, line: line, baseline: baseline(forGlyphAt: glyph, origin: origin), font: font)
            }
        }
    }

    private func draw(_ object: EditorObject, range objectRange: NSRange, in rect: NSRect, line: NSRect, baseline: CGFloat, font: NSFont) {
        switch object.kind {
        case .bullet(let level):
            let size: CGFloat = 5.5
            let center = CGPoint(x: rect.minX + 9, y: baseline - font.xHeight / 2 - 0.5)
            let dot = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            Theme.textTertiary.set()
            switch level % 3 {
            case 0: NSBezierPath(ovalIn: dot).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            default: NSBezierPath(rect: dot.insetBy(dx: 0.5, dy: 0.5)).fill()
            }

        case .checkbox(let checked):
            // A circle, as in Notes and Reminders.
            let side = EditorStyle.checkboxSide
            let box = NSRect(x: rect.minX + 1, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side)
            if checked {
                // Done: filled with the accent colour, the tick cut out of it.
                Theme.accent.setFill()
                NSBezierPath(ovalIn: box).fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + side * 0.28, y: box.midY + side * 0.01))
                check.line(to: CGPoint(x: box.minX + side * 0.44, y: box.midY + side * 0.16))
                check.line(to: CGPoint(x: box.minX + side * 0.73, y: box.midY - side * 0.16))
                check.lineWidth = max(1.6, side * 0.09)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                Theme.panel.setStroke()
                check.stroke()
            } else {
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                Theme.faint.setStroke()
                ring.stroke()
            }

        case .quoteBar:
            Theme.cardBorder.blended(withFraction: 0.35, of: Theme.textTertiary)?.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 2, y: line.minY, width: 3, height: line.height), xRadius: 1.5, yRadius: 1.5).fill()

        case .chipLead(let icon):
            let symbol: String = switch icon {
            case .note: "doc.text"
            case .file: "doc"
            case .missing: "plus"
            case .embed: "rectangle.on.rectangle"
            }
            drawSymbol(symbol, size: font.pointSize * 0.82, color: icon == .missing ? Theme.textTertiary : Theme.accent,
                       center: CGPoint(x: rect.minX + 4 + font.pointSize * 0.45, y: baseline - font.capHeight / 2))

        case .chipTrail:
            break

        case .image(let url, let source, let inline):
            drawImage(url: url, source: source, range: objectRange, in: rect, radius: inline ? 3 : 8)

        case .drawing(let url):
            guard source?.showsCanvas(for: url) != true,
                  let image = DrawingStore.shared.image(for: url, width: rect.width, dark: source?.isDarkAppearance ?? false, ready: { [weak self] in self?.source?.objectNeedsDisplay(objectRange) })
            else { break }
            image.drawUpright(in: rect)

        case .fileCard(let url, let name):
            drawFileCard(url: url, name: name, range: objectRange, in: rect)

        case .noteEmbed(let target, let url):
            drawNoteEmbed(target: target, url: url, in: rect)

        case .horizontalRule:
            Theme.cardBorder.setFill()
            NSRect(x: line.minX, y: floor(baseline - font.xHeight / 2), width: line.width - 2, height: 1).fill()

        case .table(let model):
            model.draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width - 1, height: rect.height))

        case .mermaid(let source):
            switch DiagramStore.diagram(source, isDark: self.source?.isDarkAppearance ?? false, ready: { [weak self] in self?.source?.objectNeedsLayout(objectRange) }) {
            case .some(.some(let image)):
                var size = image.size
                if size.width > rect.width { size = CGSize(width: rect.width, height: size.height * rect.width / size.width) }
                image.drawUpright(in: NSRect(x: rect.minX, y: rect.minY + 8, width: size.width, height: size.height))
            case .some(.none):
                drawPlaceholder("Mermaid diagram couldn't be drawn. Click to edit it.", symbol: "exclamationmark.triangle", in: rect)
            case .none:
                drawPlaceholder("Drawing diagram…", symbol: "point.3.connected.trianglepath.dotted", in: rect)
            }

        case .mathBlock(let tex):
            if let math = MathStore.render(tex, display: true, size: 19, color: Theme.text.resolved(dark: source?.isDarkAppearance ?? false)) {
                let size = math.image.size
                let x = rect.minX + max(0, (rect.width - size.width) / 2)
                math.image.drawUpright(in: NSRect(x: x, y: rect.minY + 10, width: size.width, height: size.height))
            } else {
                drawPlaceholder("This formula couldn't be read. Click to edit it.", symbol: "function", in: rect)
            }

        case .mathInline(let tex):
            if let math = MathStore.render(tex, display: false, size: font.pointSize * 1.08, color: Theme.text.resolved(dark: source?.isDarkAppearance ?? false)) {
                let size = math.image.size
                math.image.drawUpright(in: NSRect(x: rect.minX + 1, y: baseline - math.ascent, width: size.width, height: size.height))
            }

        case .callout(let type, let label):
            let color = CalloutStyle.color(type)
            drawSymbol(CalloutStyle.symbol(type), size: 14, color: color, center: CGPoint(x: rect.minX + 9, y: baseline - font.capHeight / 2), weight: .semibold)
            if let label {
                let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: EditorStyle.bodySize, weight: .semibold), .foregroundColor: color])
                text.draw(at: CGPoint(x: rect.minX + 24, y: baseline - NSFont.systemFont(ofSize: EditorStyle.bodySize).ascender))
            }

        case .linkEdit:
            guard !hidesEditingControls else { break }
            drawSymbol("pencil.line", size: font.pointSize * 0.72, color: Theme.accent.withAlphaComponent(0.75),
                       center: CGPoint(x: rect.midX + 0.5, y: baseline - font.capHeight / 2 + 0.5))

        case .frontmatter(let count):
            let pill = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 26)
            Theme.control.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
            drawSymbol("list.bullet.rectangle", size: 12, color: Theme.textSecondary, center: CGPoint(x: pill.minX + 15, y: pill.midY))
            let text = NSAttributedString(string: frontmatterLabel(count), attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.textSecondary])
            text.draw(at: CGPoint(x: pill.minX + 28, y: pill.midY - 8))
        }

        if object.isBlock, isSelected(objectRange) {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            Theme.accent.withAlphaComponent(0.16).setFill()
            ring.fill()
            Theme.accent.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func drawImage(url: URL?, source: String, range: NSRange, in rect: NSRect, radius: CGFloat) {
        guard let url, ImageStore.shared.size(of: url) != nil else {
            drawPlaceholder(url == nil && source.hasPrefix("http") ? source : "Picture not found: \((source as NSString).lastPathComponent)", symbol: "photo", in: rect)
            return
        }
        let image = ImageStore.shared.image(for: url, width: rect.width) { [weak self] in self?.source?.objectNeedsDisplay(range) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        if let image {
            image.drawUpright(in: rect)
        } else {
            Theme.code.setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFileCard(url: URL?, name: String, range: NSRange, in rect: NSRect) {
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.card.setFill()
        card.fill()
        Theme.cardBorder.setStroke()
        card.lineWidth = 1
        card.stroke()
        let thumbRect = NSRect(x: rect.minX + 10, y: rect.minY + 8, width: 40, height: rect.height - 16)
        if let url, let thumb = ThumbnailStore.shared.thumbnail(for: url, size: CGSize(width: 80, height: 104), ready: { [weak self] in self?.source?.objectNeedsDisplay(range) }) {
            var size = thumb.size
            let scale = min(thumbRect.width / size.width, thumbRect.height / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
            thumb.drawUpright(in: NSRect(x: thumbRect.midX - size.width / 2, y: thumbRect.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            drawSymbol("doc", size: 22, color: url?.pathExtension.lowercased() == "pdf" ? Theme.pdf : Theme.textTertiary, center: CGPoint(x: thumbRect.midX, y: thumbRect.midY))
        }
        let title = NSAttributedString(string: url.map { $0.deletingPathExtension().lastPathComponent } ?? name,
                                       attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: url == nil ? Theme.textTertiary : Theme.text])
        title.draw(with: NSRect(x: rect.minX + 62, y: rect.minY + 13, width: rect.width - 76, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        guard let url else {
            NSAttributedString(string: "Not found", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textTertiary])
                .draw(at: CGPoint(x: rect.minX + 62, y: rect.minY + 37))
            return
        }
        // The kind as a small badge, then size and date, as Lettera shows a file.
        let kind = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
        let badgeText = NSAttributedString(string: kind, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: Theme.textSecondary])
        let badgeSize = badgeText.size()
        let badge = NSRect(x: rect.minX + 62, y: rect.minY + 37, width: ceil(badgeSize.width) + 12, height: 18)
        Theme.control.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        badgeText.draw(at: CGPoint(x: badge.minX + 6, y: badge.midY - badgeSize.height / 2))
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var details: [String] = []
        if let size = values?.fileSize { details.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = values?.contentModificationDate { details.append(date.formatted(date: .abbreviated, time: .omitted)) }
        NSAttributedString(string: details.joined(separator: " · "), attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textTertiary])
            .draw(with: NSRect(x: badge.maxX + 8, y: rect.minY + 37, width: rect.maxX - badge.maxX - 20, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawNoteEmbed(target: String, url: URL?, in rect: NSRect) {
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.card.setFill()
        card.fill()
        Theme.cardBorder.setStroke()
        card.lineWidth = 1
        card.stroke()
        drawSymbol(url == nil ? "doc.badge.plus" : "doc.text", size: 13, color: url == nil ? Theme.textTertiary : Theme.accent, center: CGPoint(x: rect.minX + 22, y: rect.minY + 22))
        NSAttributedString(string: url?.deletingPathExtension().lastPathComponent ?? target, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: url == nil ? Theme.textTertiary : Theme.text])
            .draw(with: NSRect(x: rect.minX + 36, y: rect.minY + 13, width: rect.width - 52, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        var excerpt = url == nil ? "This note doesn't exist yet. Click to create it." : ""
        if let url, let text = source?.noteText(for: url) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(4).map { line -> String in
                var line = String(line)
                while line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("- ") { line = String(line.drop(while: { "#>- ".contains($0) })) }
                return line
            }
            excerpt = lines.joined(separator: "  ")
        }
        let body = InlineRenderer.render(excerpt, font: NSFont.systemFont(ofSize: 13), color: Theme.textSecondary)
        body.draw(with: NSRect(x: rect.minX + 16, y: rect.minY + 42, width: rect.width - 32, height: rect.height - 52), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawPlaceholder(_ text: String, symbol: String, in rect: NSRect) {
        Theme.code.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        drawSymbol(symbol, size: 15, color: Theme.textTertiary, center: CGPoint(x: rect.minX + 22, y: rect.midY))
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.textTertiary])
            .draw(with: NSRect(x: rect.minX + 40, y: rect.midY - 9, width: rect.width - 52, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawSymbol(_ name: String, size: CGFloat, color: NSColor, center: CGPoint, weight: NSFont.Weight = .medium) {
        guard let image = Self.symbol(name, size: size, color: color, weight: weight) else { return }
        let imageSize = image.size
        image.drawUpright(in: NSRect(x: center.x - imageSize.width / 2, y: center.y - imageSize.height / 2, width: imageSize.width, height: imageSize.height))
    }

    private static var symbols: [String: NSImage] = [:]

    /// A symbol drawn into pixels once (at three times its size), so it looks the same on screen, in a PNG and in a
    /// PDF, where a coloured symbol drawn as such comes out as a filled box.
    static func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSImage? {
        #if os(macOS)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        #else
        let rgb = color.resolvedColor(with: UITraitCollection.current)
        #endif
        let components = rgb.rgba
        let key = "\(name)|\(size)|\(weight.rawValue)|\(components.red)|\(components.green)|\(components.blue)|\(components.alpha)"
        if let cached = symbols[key] { return cached }
        #if os(iOS)
        let symbolWeight: UIImage.SymbolWeight = weight.rawValue >= NSFont.Weight.semibold.rawValue ? .semibold : weight.rawValue >= NSFont.Weight.medium.rawValue ? .medium : .regular
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: symbolWeight).applying(UIImage.SymbolConfiguration(paletteColors: [rgb]))
        guard let vector = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: vector.size, format: format).image { _ in vector.draw(at: .zero) }
        if symbols.count > 200 { symbols.removeAll() }
        symbols[key] = image
        return image
        #else
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [rgb]))
        guard let vector = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let scale: CGFloat = 3
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(vector.size.width * scale)), pixelsHigh: Int(ceil(vector.size.height * scale)),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = vector.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        vector.draw(in: NSRect(origin: .zero, size: vector.size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: vector.size)
        image.addRepresentation(bitmap)
        if symbols.count > 200 { symbols.removeAll() }
        symbols[key] = image
        return image
        #endif
    }

    // MARK: - Decorations

    /// All the characters that carry this decoration: it moves along with the text, so its run is where it is.
    func extent(of decoration: Decoration, around run: NSRange) -> NSRange {
        guard let storage = textStorage else { return run }
        var range = run
        var start = run.location
        while start > 0, (storage.attribute(.notebookDecoration, at: start - 1, effectiveRange: &range) as AnyObject?) === decoration { start = range.location }
        var end = run.upperBound
        while end < storage.length, (storage.attribute(.notebookDecoration, at: end, effectiveRange: &range) as AnyObject?) === decoration { end = range.upperBound }
        return NSRange(location: start, length: end - start)
    }

    private func drawDecoration(_ decoration: Decoration, range decorationRange: NSRange, container: NSTextContainer, origin: NSPoint) {
        guard let storage = textStorage, decorationRange.upperBound <= storage.length else { return }
        switch decoration.kind {
        case .codeBlock(let language, _, let preview):
            guard let box = blockRect(decorationRange, container: container, origin: origin) else { return }
            let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            Theme.code.setFill()
            path.fill()
            Theme.codeBorder.setStroke()
            path.lineWidth = 1
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5).stroke()
            // The language in the corner while the fences are hidden.
            if !language.isEmpty, !(source?.isRevealed(decorationRange.location) ?? false), copyButtonBlock != decorationRange.location {
                let label = NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.textTertiary])
                let size = label.size()
                label.draw(at: CGPoint(x: box.maxX - size.width - 12, y: box.minY + 5))
            }
            if let preview { drawPreview(preview, range: decorationRange, under: box) }
        case .callout(let type):
            guard var box = blockRect(decorationRange, container: container, origin: origin) else { return }
            box = NSRect(x: box.minX, y: box.minY - 6, width: box.width, height: box.height + 12)
            let color = CalloutStyle.color(type)
            color.withAlphaComponent(source?.isDarkAppearance == true ? 0.14 : 0.09).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        case .inlineCode:
            enumerateRects(decorationRange, container: container) { rect in
                let font = (storage.attribute(.font, at: decorationRange.location, effectiveRange: nil) as? NSFont) ?? EditorStyle.inlineMono
                let height = ceil(font.ascender - font.descender) + 4
                let box = NSRect(x: rect.minX - 3, y: rect.midY - height / 2, width: rect.width + 6, height: height).offsetBy(dx: origin.x, dy: origin.y)
                Theme.inlineCode.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        case .chip(let resolved):
            enumerateRects(decorationRange, container: container) { rect in
                let box = NSRect(x: rect.minX, y: rect.midY - 11, width: rect.width, height: 22).offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                if resolved {
                    Theme.accent.withAlphaComponent(source?.isDarkAppearance == true ? 0.18 : 0.12).setFill()
                    path.fill()
                } else {
                    let dashed = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                    dashed.setLineDash([3, 2], count: 2, phase: 0)
                    dashed.lineWidth = 1
                    Theme.faint.setStroke()
                    dashed.stroke()
                }
            }
        case .highlight:
            enumerateRects(decorationRange, container: container) { rect in
                let font = (storage.attribute(.font, at: decorationRange.location, effectiveRange: nil) as? NSFont) ?? EditorStyle.body
                let height = ceil(font.ascender - font.descender) + 3
                let box = NSRect(x: rect.minX - 2, y: rect.midY - height / 2, width: rect.width + 4, height: height).offsetBy(dx: origin.x, dy: origin.y)
                Theme.highlight.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
    }

    /// The box drawn behind the block that this character is in, in the text view's coordinates.
    func blockBox(at index: Int, origin: NSPoint) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first, index < storage.length else { return nil }
        var run = NSRange()
        guard let decoration = storage.attribute(.notebookDecoration, at: index, effectiveRange: &run) as? Decoration,
              case .codeBlock = decoration.kind else { return nil }
        return blockRect(extent(of: decoration, around: run), container: container, origin: origin)
    }

    /// Whether a run of text is the end of the note without a line break after it: TextKit leaves out the spacing after
    /// that last paragraph.
    private func endsWithoutSpacing(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0, range.upperBound >= storage.length else { return false }
        return (storage.string as NSString).character(at: storage.length - 1) != 10
    }

    /// The room the text takes, with the spacing after its last paragraph that TextKit leaves out when no line break
    /// ends the note: a diagram or formula being edited there shows what it makes in it.
    override func usedRect(for container: NSTextContainer) -> NSRect {
        var rect = super.usedRect(for: container)
        guard let storage = textStorage, endsWithoutSpacing(NSRange(location: 0, length: storage.length)) else { return rect }
        let style = storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle
        rect.size.height += style?.paragraphSpacing ?? 0
        return rect
    }

    /// From the top of a block's first line to the bottom of its last, without the spacing around it, across the
    /// whole width of the text.
    private func blockRect(_ range: NSRange, container: NSTextContainer, origin: NSPoint) -> NSRect? {
        guard let storage = textStorage, range.length > 0 else { return nil }
        let firstGlyph = glyphIndexForCharacter(at: range.location)
        let lastGlyph = glyphIndexForCharacter(at: max(range.location, range.upperBound - 1))
        guard firstGlyph < numberOfGlyphs else { return nil }
        let first = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let last = lineFragmentRect(forGlyphAt: min(lastGlyph, numberOfGlyphs - 1), effectiveRange: nil)
        let firstStyle = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let lastStyle = storage.attribute(.paragraphStyle, at: max(range.location, range.upperBound - 1), effectiveRange: nil) as? NSParagraphStyle
        let top = first.minY + (firstStyle?.paragraphSpacingBefore ?? 0)
        let bottom = last.maxY - (endsWithoutSpacing(range) ? 0 : lastStyle?.paragraphSpacing ?? 0)
        let x = container.lineFragmentPadding
        return NSRect(x: origin.x + x, y: origin.y + top, width: container.size.width - x * 2, height: bottom - top)
    }

    /// A diagram or formula being edited, in the room left under its source (the last line's spacing).
    private func drawPreview(_ preview: Decoration.Preview, range decorationRange: NSRange, under box: NSRect) {
        guard let storage = textStorage else { return }
        let lastStyle = storage.attribute(.paragraphStyle, at: max(decorationRange.location, decorationRange.upperBound - 1), effectiveRange: nil) as? NSParagraphStyle
        let area = NSRect(x: box.minX, y: box.maxY + 12, width: box.width, height: max(0, (lastStyle?.paragraphSpacing ?? 0) - 22))
        switch preview {
        case .diagram(let diagram):
            if case .some(.some(let image)) = DiagramStore.diagram(diagram, isDark: source?.isDarkAppearance ?? false, ready: { [weak self] in self?.source?.objectNeedsLayout(decorationRange) }) {
                var size = image.size
                if size.width > area.width { size = CGSize(width: area.width, height: size.height * area.width / size.width) }
                image.drawUpright(in: NSRect(x: area.minX, y: area.minY, width: size.width, height: size.height))
            }
        case .math(let tex):
            if let math = MathStore.render(tex, display: true, size: 19, color: Theme.text.resolved(dark: source?.isDarkAppearance ?? false)) {
                let size = math.image.size
                math.image.drawUpright(in: NSRect(x: area.minX + max(0, (area.width - size.width) / 2), y: area.minY, width: size.width, height: size.height))
            }
        }
    }

    /// The boxes around a run of text, one per line it is on, without the spaces at a line's end (which TextKit
    /// stretches to the edge of the text).
    private func enumerateRects(_ range: NSRange, container: NSTextContainer, _ body: (NSRect) -> Void) {
        guard let storage = textStorage else { return }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let text = storage.string as NSString
        var rects: [NSRect] = []
        var glyph = glyphs.location
        while glyph < glyphs.upperBound {
            var line = NSRange()
            lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            var piece = NSIntersectionRange(line, glyphs)
            guard piece.length > 0 else { break }
            while piece.length > 0 {
                let character = characterIndexForGlyph(at: piece.upperBound - 1)
                let unit = text.character(at: character)
                if unit == 32 || unit == 10 || unit == 9 || propertyForGlyph(at: piece.upperBound - 1) == .controlCharacter && isHidden(character) {
                    piece.length -= 1
                } else {
                    break
                }
            }
            while piece.length > 0, propertyForGlyph(at: piece.location) == .controlCharacter, isHidden(characterIndexForGlyph(at: piece.location)) {
                piece.location += 1
                piece.length -= 1
            }
            if piece.length > 0 {
                let rect = boundingRect(forGlyphRange: piece, in: container)
                if rect.width > 0.5 { rects.append(rect) }
            }
            glyph = line.upperBound
        }
        rects.forEach(body)
    }
}
