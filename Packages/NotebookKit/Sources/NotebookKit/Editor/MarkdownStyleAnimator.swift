import CoreText
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Restyles the Markdown of a note as it is typed in, easing from the old look to the new one instead of snapping:
/// bold text thickens, a heading grows, marks fade back, a new list marker fades in. Weight and size change
/// continuously along the typeface's variation axes, so the text passes through every weight in between. The same as
/// Issues', for the typefaces a note can have.
@MainActor
final class MarkdownStyleAnimator: NSObject {
    /// How a run of text looks.
    struct Look {
        var font: NSFont?
        var color: NSColor?

        init(_ attributes: [NSAttributedString.Key: Any]) {
            font = attributes[.font] as? NSFont
            color = attributes[.foregroundColor] as? NSColor
        }

        init(font: NSFont?, color: NSColor?) {
            self.font = font
            self.color = color
        }
    }

    private struct Run {
        var range: NSRange
        var from: Look
        var to: Look
    }

    /// The view the text is in, for its appearance and its display's frames.
    weak var view: MarkdownTextView?

    private weak var storage: NSTextStorage?
    private var runs: [Run] = []
    /// When the first frame of the ease was shown; 0 until then.
    private var started: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var fallback: Timer?
    /// How the characters an edit by the typing rules keeps looked, by where they are after it.
    private var kept: [(range: NSRange, look: Look)] = []

    static var isEnabled: Bool {
        #if os(macOS)
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        !UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Before the typing rules replace `range` with `replacement`: remembers how the characters that stay looked,
    /// since the edit as a whole would count as new text.
    func keep(_ storage: NSTextStorage, replacing range: NSRange, with replacement: String) {
        let old = Array((storage.string as NSString).substring(with: range).utf16)
        let new = Array(replacement.utf16)
        kept = Self.matches(old, new).compactMap { pair in
            let look = Look(storage.attributes(at: range.location + pair.old, effectiveRange: nil))
            return (NSRange(location: range.location + pair.new, length: 1), look)
        }
    }

    /// Around the editor's styling of the lines in `scope` right after an edit (from `didProcessEditing`): starts
    /// easing every character there whose look changed from how it looked to how it looks now.
    ///
    /// Not from `willProcessEditing`: what changes there counts as part of the edit, and the Mac's text view puts the
    /// caret at the end of the edit, so styling the text after the caret would throw the caret to its end.
    func restyle(_ storage: NSTextStorage, edited: NSRange, scope: NSRange, styling: () -> Void) {
        let animates = Self.isEnabled && view?.window != nil
        let before = animates ? looks(in: storage, scope: scope, outside: edited) : []
        stop()
        defer { kept = [] }
        styling()
        if animates {
            runs = changes(from: before, in: storage, edited: NSIntersectionRange(edited, scope))
            apply(0, to: storage)
        }
        guard !runs.isEmpty else { return }
        self.storage = storage
        started = 0
        #if os(macOS)
        displayLink = view?.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        displayLink?.add(to: .main, forMode: .common)
        // A display link only runs while the view is on screen; the text never stays half way. Late enough not to
        // cut short an ease whose first frame came late.
        let fallback = Timer(timeInterval: Theme.textStyleDuration + 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(fallback, forMode: .common)
        self.fallback = fallback
    }

    /// Ends the animation where it is; the next styling sets the final look.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        fallback?.invalidate()
        fallback = nil
        runs = []
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The ease starts with the first frame: the edit and what it brings up (the caret's buttons) can keep the
        // first one waiting for a few frames, which would otherwise be taken from the start of the ease.
        if started == 0 { started = link.timestamp }
        let progress = min(1, (link.targetTimestamp - started) / Theme.textStyleDuration)
        guard progress < 1, let storage else { return finish() }
        storage.beginEditing()
        apply(1 - pow(1 - progress, 3), to: storage)
        storage.endEditing()
    }

    /// Ends the animation at its end, for styling that follows at once.
    func complete() {
        finish()
    }

    private func finish() {
        guard !runs.isEmpty else { return stop() }
        if let storage {
            storage.beginEditing()
            apply(1, to: storage)
            storage.endEditing()
        }
        stop()
    }

    // MARK: Looks

    /// How the lines about to be styled look now, outside the part just typed or replaced, plus what the typing rules
    /// kept inside it.
    private func looks(in storage: NSTextStorage, scope: NSRange, outside edited: NSRange) -> [(range: NSRange, look: Look)] {
        var looks: [(range: NSRange, look: Look)] = []
        let scope = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        let parts = [NSRange(location: scope.location, length: max(0, min(edited.location, NSMaxRange(scope)) - scope.location)),
                     NSRange(location: max(NSMaxRange(edited), scope.location), length: max(0, NSMaxRange(scope) - max(NSMaxRange(edited), scope.location)))]
        for part in parts where part.length > 0 {
            storage.enumerateAttributes(in: part) { attributes, range, _ in
                looks.append((range, Look(attributes)))
            }
        }
        return looks + kept.filter { NSMaxRange($0.range) <= storage.length }
    }

    /// Where the newly styled text looks different from before. New characters fade in when they are Markdown
    /// marks typed a few at a time; a whole new text just appears.
    private func changes(from before: [(range: NSRange, look: Look)], in storage: NSTextStorage, edited: NSRange) -> [Run] {
        var runs: [Run] = []
        for (range, old) in before {
            storage.enumerateAttributes(in: range) { attributes, subrange, _ in
                let new = Look(attributes)
                if !sameFont(old.font, new.font) || !sameColor(old.color, new.color) {
                    runs.append(Run(range: subrange, from: old, to: new))
                }
            }
        }
        let keptLocations = Set(kept.map(\.range.location))
        guard edited.length > 0, edited.length - keptLocations.count <= 12 else { return runs }
        let muted = Theme.faint
        storage.enumerateAttributes(in: edited) { attributes, range, _ in
            let new = Look(attributes)
            guard sameColor(new.color, muted) else { return }
            for location in range.location ..< NSMaxRange(range) where !keptLocations.contains(location) {
                runs.append(Run(range: NSRange(location: location, length: 1), from: Look(font: new.font, color: muted.withAlphaComponent(0)), to: new))
            }
        }
        return runs
    }

    private func apply(_ progress: CGFloat, to storage: NSTextStorage) {
        for run in runs where NSMaxRange(run.range) <= storage.length {
            if progress >= 1 {
                if let font = run.to.font { storage.addAttribute(.font, value: font, range: run.range) }
                if let color = run.to.color { storage.addAttribute(.foregroundColor, value: color, range: run.range) }
                storage.removeAttribute(.obliqueness, range: run.range)
                continue
            }
            if let from = run.from.font, let to = run.to.font {
                let (font, obliqueness) = Self.font(between: from, and: to, at: progress)
                storage.addAttribute(.font, value: font, range: run.range)
                if obliqueness != 0 { storage.addAttribute(.obliqueness, value: obliqueness, range: run.range) }
            }
            if let color = color(between: run.from.color, and: run.to.color, at: progress) {
                storage.addAttribute(.foregroundColor, value: color, range: run.range)
            }
        }
    }

    // MARK: Fonts

    private static let weightAxis = NSNumber(value: 0x7767_6874) // 'wght'
    /// What the system's italics slant by, in the obliqueness an upright font is given while it turns italic.
    private static let italicSlant: CGFloat = 0.2

    private static func weight(of font: NSFont) -> CGFloat {
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return CGFloat(variation?[weightAxis]?.doubleValue ?? 400)
    }

    private static func isItalic(_ font: NSFont) -> Bool {
        #if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    /// A font between two of the note's typeface: size and weight in between, and italics as a growing slant. Code
    /// in a typeface that isn't monospaced switches at once.
    private static func font(between from: NSFont, and to: NSFont, at progress: CGFloat) -> (NSFont, CGFloat) {
        guard from.isFixedPitch == to.isFixedPitch else { return (to, 0) }
        let size = from.pointSize + (to.pointSize - from.pointSize) * progress
        let weight = Self.weight(of: from) + (Self.weight(of: to) - Self.weight(of: from)) * progress
        if isItalic(from) == isItalic(to) {
            return (font(like: to, size: size, weight: weight), 0)
        }
        // Upright, slanting more and more on the way to italics, or less and less on the way back.
        let slant = isItalic(to) ? progress : 1 - progress
        return (font(like: isItalic(to) ? from : to, size: size, weight: weight), slant * italicSlant)
    }

    /// The font in another size and weight, keeping its typeface and the optical size the system picks for the size.
    /// It starts from the typeface's regular weight: on iPhone and iPad a semibold system font moved along the weight
    /// axis came out far heavier than asked.
    private static func font(like font: NSFont, size: CGFloat, weight: CGFloat) -> NSFont {
        let face = EditorStyle.face(size)
        var base = font.isFixedPitch && !face.isFixedPitch ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : face
        if isItalic(font) { base = EditorStyle.font(base, italic: true) }
        var variation = (CTFontCopyVariation(base) as? [NSNumber: NSNumber]) ?? [:]
        variation[weightAxis] = NSNumber(value: Double(weight))
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    private func sameFont(_ a: NSFont?, _ b: NSFont?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.pointSize == b.pointSize && a.fontName == b.fontName && Self.weight(of: a) == Self.weight(of: b)
    }

    // MARK: Colours

    private func components(_ color: NSColor?) -> [CGFloat]? {
        guard let color else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        var resolved: NSColor?
        (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let resolved = view.map { color.resolvedColor(with: $0.traitCollection) } ?? color
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        return [red, green, blue, alpha]
    }

    private func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let first = components(a), let second = components(b) else { return a == nil && b == nil }
        return zip(first, second).allSatisfy { abs($0 - $1) < 0.004 }
    }

    private func color(between from: NSColor?, and to: NSColor?, at progress: CGFloat) -> NSColor? {
        guard let first = components(from), let second = components(to) else { return to }
        let mixed = zip(first, second).map { $0 + ($1 - $0) * progress }
        return NSColor(red: mixed[0], green: mixed[1], blue: mixed[2], alpha: mixed[3])
    }

    // MARK: Matching

    /// The characters two texts share, in order (a longest common subsequence), as pairs of offsets.
    static func matches(_ old: [UInt16], _ new: [UInt16]) -> [(old: Int, new: Int)] {
        // An edit by the typing rules touches a line or two; anything bigger isn't worth the work.
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= 250_000 else { return [] }
        let width = new.count + 1
        var lengths = [Int32](repeating: 0, count: (old.count + 1) * width)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i * width + j] = old[i] == new[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var pairs: [(old: Int, new: Int)] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
