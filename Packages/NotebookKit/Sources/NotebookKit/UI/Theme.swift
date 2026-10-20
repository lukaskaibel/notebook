#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Design tokens, the same as in Issues. Every colour has a light and a dark value.
public enum Theme {
    #if os(macOS)
    /// The page a note is written on: the system's text background, white or dark grey.
    static let panel = NSColor.textBackgroundColor
    static let separator = NSColor.separatorColor
    #else
    /// The page a note is written on: white, or black in the dark, as in Notes.
    static let panel = UIColor.systemBackground
    static let separator = UIColor.separator
    #endif
    static let panelBorder = NSColor(light: 0xE3E4E8, dark: 0x343437)
    static let card = NSColor(light: 0xFFFFFF, dark: 0x262628)
    static let cardBorder = NSColor(light: 0xE6E7EB, dark: 0x343437)
    static let hover = NSColor(light: 0xE8E9ED, dark: 0x2A2A2D)
    static let selected = NSColor(light: 0xE3E4E8, dark: 0x303033)
    static let control = NSColor(light: 0xE7E8EC, dark: 0x2A2A2D)
    static let popover = NSColor(light: 0xFFFFFF, dark: 0x2A2A2C)
    static let popoverBorder = NSColor(light: 0xDDDEE3, dark: 0x3A3A3D)
    static let popoverSelected = NSColor(light: 0xEEEFF2, dark: 0x38383B)
    static let keycap = NSColor(light: 0xD0D2D8, dark: 0x4A4A4E)

    static let text = NSColor(light: 0x1A1B1E, dark: 0xE8E9EB)
    static let textSecondary = NSColor(light: 0x5F636B, dark: 0x9A9FA8)
    static let textTertiary = NSColor(light: 0x6E727B, dark: 0x7C818A)
    static let textBody = NSColor(light: 0x2E3035, dark: 0xC9CCD1)
    /// Markdown punctuation shown next to the caret.
    static let faint = NSColor(light: 0xA3A7AF, dark: 0x5A5E66)

    #if os(macOS)
    /// The accent colour chosen in System Settings, or Notebook's ink blue (`AccentColor`) when it is set to Multicolour.
    static let accent = NSColor.controlAccentColor
    #else
    /// Notebook's ink blue (`AccentColor`), the app's accent colour (the system has no accent of its own to choose on
    /// iPhone and iPad).
    static let accent = UIColor(named: "AccentColor") ?? NSColor(light: 0x34508F, dark: 0x93ABE3)
    #endif
    static let positive = NSColor(light: 0x2F9B67, dark: 0x4CB782)
    static let warning = NSColor(light: 0xB8791C, dark: 0xE5A84B)
    static let red = NSColor(light: 0xD64545, dark: 0xEB6A6A)
    static let blue = NSColor(light: 0x2F86B5, dark: 0x5AB0D8)
    static let purple = NSColor(light: 0x6E56CF, dark: 0xA08CF2)
    static let pdf = NSColor(light: 0xD64545, dark: 0xEB6A6A)
    static let image = NSColor(light: 0x2F86B5, dark: 0x5AB0D8)
    static let video = NSColor(light: 0x7C5CC4, dark: 0xA08CF2)

    static let code = NSColor(light: 0xF5F5F7, dark: 0x262628)
    static let codeBorder = NSColor(light: 0xE8E8EB, dark: 0x313134)
    static let inlineCode = NSColor(light: 0xEFEFF2, dark: 0x2E2E31)
    static let tableHeader = NSColor(light: 0xEDEEF2, dark: 0x333336)
    static let tableStripe = NSColor(light: 0xF4F5F8, dark: 0x2A2A2D)
    /// Behind `==highlighted==` text.
    static let highlight = NSColor(light: 0xFCEFA1, dark: 0x6B5A12)
    static let searchMark = NSColor(hex: 0xF0B429, alpha: 0.38)


    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let quick = Animation.easeOut(duration: 0.14)
    /// Text easing into a new look while you type: bold thickening, a heading growing, marks fading.
    static let textStyleDuration: TimeInterval = 0.18
    /// Markdown marks unfolding next to the caret and folding away behind it.
    static let markRevealDuration: TimeInterval = 0.16
    /// The buttons for where the caret is, coming and going in the bar above the keyboard.
    static let keyboardBarSpring: (duration: TimeInterval, bounce: CGFloat) = (0.32, 0.16)
}

extension NSColor {
    /// A colour that follows the appearance it is drawn in.
    convenience init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
        #else
        self.init { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
        #endif
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        #if os(macOS)
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
        #else
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
        #endif
    }

    #if os(macOS)
    var swiftUI: Color { Color(nsColor: self) }
    #else
    var swiftUI: Color { Color(uiColor: self) }
    #endif
}

extension Color {
    #if os(macOS)
    static func theme(_ color: NSColor) -> Color { Color(nsColor: color) }
    #else
    static func theme(_ color: NSColor) -> Color { Color(uiColor: color) }
    #endif
}

extension Font {
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let uiSemibold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11)
}
