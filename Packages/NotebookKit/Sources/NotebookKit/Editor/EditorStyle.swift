#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Markdown punctuation that isn't drawn. `HiddenMode.untilRevealed` comes back next to the caret,
    /// `HiddenMode.always` never does.
    static let notebookHidden = NSAttributedString.Key("notebook.hidden")
    /// An `EditorObject` drawn in place of its character, on the first character of what it stands for.
    static let notebookObject = NSAttributedString.Key("notebook.object")
    /// A box drawn behind a run of text (code blocks, callouts, inline code, links to notes).
    static let notebookDecoration = NSAttributedString.Key("notebook.decoration")
    /// Where a click goes: a URL or a note.
    static let notebookLink = NSAttributedString.Key("notebook.link")
    /// A web address shown as it is written (`https://…`, `<…>`): text you see, but the link's own, which Transformations
    /// and Replace leave alone.
    static let notebookAddress = NSAttributedString.Key("notebook.address")
    /// On the first `#` of a heading: its level, shown in the margin next to the caret.
    static let notebookHeading = NSAttributedString.Key("notebook.heading")
    /// How much of a Markdown mark shows while it folds in or out (`MarkdownRevealAnimator`): its opacity, 0 to 1.
    static let notebookFade = NSAttributedString.Key("notebook.fade")
}

enum HiddenMode: Int {
    case untilRevealed = 1
    case always = 2
}

/// Fonts, colours and spacing of a note. Sizes follow the typography chosen in the settings.
@MainActor
enum EditorStyle {
    private(set) static var typography = Typography()
    /// How much the system's text size (Display & Brightness › Text Size, or Larger Text) makes the note's larger or
    /// smaller on iPhone and iPad, as it does the text of Apple's apps: 1 at the standard size, and on the Mac. The size
    /// chosen in Settings › Text is the size at the standard one.
    private(set) static var textScale: CGFloat = 1

    static var bodySize: CGFloat { (typography.size * textScale).rounded() }
    static var lineHeight: CGFloat { (bodySize * typography.spacing.factor).rounded() }
    static var codeSize: CGFloat { (bodySize * 0.87).rounded() }
    static var codeLineHeight: CGFloat { (codeSize * typography.spacing.factor * 0.96).rounded(.down) }
    /// Maths on lines of its own, larger than the text around it: 19 points at the size each platform starts with.
    static var displayMathSize: CGFloat { (bodySize * 19 / Typography().size).rounded() }
    static var contentWidth: CGFloat { typography.width.points }
    static let listIndent: CGFloat = 24
    /// A checklist's circle, as in Notes: big enough for a fingertip on iPhone and iPad, a little smaller next to the
    /// Mac's text.
    static var checkboxSide: CGFloat {
        #if os(iOS)
        (bodySize * 1.3).rounded()
        #else
        (bodySize * 1.15).rounded()
        #endif
    }
    /// The room a checkbox takes before its text.
    static var checkboxWidth: CGFloat { checkboxSide + 10 }
    static let quoteIndent: CGFloat = 18
    static let codePadding: CGFloat = 14

    private(set) static var body = NSFont.systemFont(ofSize: 15)
    private(set) static var mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) static var inlineMono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let tiny = NSFont.systemFont(ofSize: 0.5)

    static func apply(_ typography: Typography) {
        self.typography = typography
        #if os(iOS)
        // Before there is a window to ask, at launch, the app's own traits know the text size.
        if let scale = scale(for: UITraitCollection.current.preferredContentSizeCategory) { textScale = scale }
        #endif
        makeFonts()
    }

    private static func makeFonts() {
        body = face(bodySize)
        mono = .monospacedSystemFont(ofSize: codeSize, weight: .regular)
        inlineMono = .monospacedSystemFont(ofSize: (bodySize * 0.88).rounded(), weight: .regular)
    }

    #if os(iOS)
    /// The system's text size is `category`, which changed or which a view in a window has just told: a note is set
    /// again at the size it makes, as when the size changes in Settings › Text.
    static func follow(_ category: UIContentSizeCategory) {
        guard let scale = scale(for: category), scale != textScale else { return }
        textScale = scale
        makeFonts()
        NotificationCenter.default.post(name: .notebookTypographyChanged, object: nil)
    }

    /// Runs `body` with the sizes Settings › Text gives, as if the system's text size were the standard one: a PDF or a
    /// printout of a note doesn't change with the size of the text on the screen. Nothing else runs meanwhile.
    static func unscaled<T>(_ body: () -> T) -> T {
        let scale = textScale
        guard scale != 1 else { return body() }
        textScale = 1
        makeFonts()
        defer {
            textScale = scale
            makeFonts()
        }
        return body()
    }

    /// As much as the system's text size scales body text; nil while it isn't known.
    private static func scale(for category: UIContentSizeCategory) -> CGFloat? {
        guard category != .unspecified else { return nil }
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traits) / 100
    }
    #endif

    /// The chosen typeface at a size and weight: San Francisco, New York, SF Rounded or SF Mono.
    static func face(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        typography.face.font(size, weight: weight)
    }

    /// A text style's name where you pick it, in a menu or the Format panel, set as the style is in the note: Title,
    /// Heading and Subheading larger and heavier than the text around them (`size`), though by less than in the note.
    static func styleSample(_ style: FormatCommand, size: CGFloat, face: Typography.Face) -> NSFont {
        let level = switch style {
        case .title: 1
        case .heading: 2
        case .subheading: 3
        default: 0
        }
        guard level > 0 else { return face.font(size) }
        return face.font((size * (1 + (headingScale(level) - 1) * 0.75)).rounded(), weight: level == 1 ? .bold : .semibold)
    }

    /// Heading sizes keep their proportion to the text.
    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28 / 15
        case 2: 22 / 15
        case 3: 18 / 15
        default: 16 / 15
        }
    }

    static func headingFont(_ level: Int) -> NSFont {
        face((bodySize * headingScale(level)).rounded(), weight: level == 1 ? .bold : .semibold)
    }

    static func headingLineHeight(_ level: Int) -> CGFloat {
        let normal: CGFloat = switch level {
        case 1: 36
        case 2: 30
        case 3: 26
        default: 24
        }
        return (normal / 15 * bodySize * typography.spacing.factor / 1.6).rounded()
    }

    static func headingSpacingBefore(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 14
        case 3: 10
        default: 8
        }
    }

    /// Lines of a fixed height, with the text in the middle of the line rather than at its bottom.
    static func paragraph(
        lineHeight: CGFloat? = nil,
        before: CGFloat = 0,
        after: CGFloat = 2,
        firstIndent: CGFloat = 0,
        indent: CGFloat = 0,
        tail: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let lineHeight = lineHeight ?? Self.lineHeight
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = firstIndent
        style.headIndent = indent
        style.tailIndent = tail
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// For a line that only holds a picture or a rendered block: as tall as the thing in it.
    static func objectParagraph(before: CGFloat = 6, after: CGFloat = 8, indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    /// A line folded away inside a block that is drawn as a whole.
    static let collapsedParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }()

    /// Lifts text so it sits in the middle of a line taller than the font.
    static func baselineOffset(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender
        return max(0, (lineHeight - natural) / 2) - 1
    }

    /// The same font, bolder and/or slanted. Bold makes body text semibold and headings heavy.
    static func font(_ font: NSFont, bold: Bool = false, italic: Bool = false) -> NSFont {
        var result = font
        if bold {
            if font.isFixedPitch, typography.face != .mono {
                result = .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
            } else {
                result = face(font.pointSize, weight: weight(of: font) >= NSFont.Weight.semibold.rawValue - 0.01 ? .heavy : .semibold)
            }
        }
        if italic {
            #if os(macOS)
            let traits = result.fontDescriptor.symbolicTraits.union(.italic)
            result = NSFont(descriptor: result.fontDescriptor.withSymbolicTraits(traits), size: result.pointSize) ?? result
            #else
            let traits = result.fontDescriptor.symbolicTraits.union(.traitItalic)
            if let descriptor = result.fontDescriptor.withSymbolicTraits(traits) { result = UIFont(descriptor: descriptor, size: result.pointSize) }
            #endif
        }
        return result
    }

    static func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }
}
