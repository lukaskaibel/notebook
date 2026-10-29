#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
// The editor, the renderers and the theme are written with AppKit's names. On iPhone and iPad these names are UIKit's
// types, which draw and measure the same way, so styling, layout and drawing are one piece of code on every device.
// What UIKit calls differently is added below.
typealias NSFont = UIFont
typealias NSColor = UIColor
typealias NSImage = UIImage
typealias NSBezierPath = UIBezierPath
typealias NSFontDescriptor = UIFontDescriptor
typealias NSRect = CGRect
typealias NSPoint = CGPoint
typealias NSSize = CGSize
public typealias NSTextStorageEditActions = NSTextStorage.EditActions

extension CGRect {
    /// Fills the rectangle with the colour that is set, as `NSRect.fill()` does.
    func fill() { UIRectFill(self) }
}

extension UIBezierPath {
    convenience init(roundedRect rect: CGRect, xRadius: CGFloat, yRadius: CGFloat) {
        self.init(roundedRect: rect, cornerRadius: min(xRadius, yRadius))
    }

    func line(to point: CGPoint) { addLine(to: point) }
}

/// Saving and restoring the graphics state around clipping, as on the Mac.
enum NSGraphicsContext {
    static func saveGraphicsState() { UIGraphicsGetCurrentContext()?.saveGState() }
    static func restoreGraphicsState() { UIGraphicsGetCurrentContext()?.restoreGState() }
}

extension UIColor {
    /// This colour mixed with another, as `NSColor.blended(withFraction:of:)`.
    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor? {
        UIColor { traits in
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            self.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            color.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * fraction, green: g1 + (g2 - g1) * fraction, blue: b1 + (b2 - b1) * fraction, alpha: a1 + (a2 - a1) * fraction)
        }
    }
}

extension UIFont {
    var isFixedPitch: Bool { fontDescriptor.symbolicTraits.contains(.traitMonoSpace) }
}
#endif

extension NSImage {
    /// Draws the picture upright into a view whose origin is at the top, as the text views' are.
    func drawUpright(in rect: CGRect) {
        #if os(macOS)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        #else
        draw(in: rect)
        #endif
    }

    /// A picture of pixels shown at `scale` pixels per point.
    static func make(_ cgImage: CGImage, scale: CGFloat) -> NSImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        #else
        UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #endif
    }

    /// The picture's pixels, upright.
    var pixels: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }
}

@MainActor
enum Screen {
    /// Pixels per point on the screen the app is on, for pictures decoded at the size they are shown.
    static var scale: CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? 2
        #else
        max(2, UITraitCollection.current.displayScale)
        #endif
    }
}

extension NSColor {
    /// The colour's red, green, blue and alpha in sRGB, for keys of caches and for drawing outside a view.
    var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        #if os(macOS)
        let rgb = usingColorSpace(.sRGB) ?? self
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
        #endif
    }

    /// 0xRRGGBB, in sRGB.
    var hexValue: UInt32 {
        let rgba = self.rgba
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return byte(rgba.red) << 16 | byte(rgba.green) << 8 | byte(rgba.blue)
    }
}

/// The system's alert sound where there is one: something that can't be done.
@MainActor
func beep() {
    #if os(macOS)
    NSSound.beep()
    #else
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    #endif
}

/// Opens a web address or another app's link in the app the system has for it.
@MainActor
func openExternally(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

/// Puts text on the general pasteboard.
@MainActor
func copyToPasteboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}
