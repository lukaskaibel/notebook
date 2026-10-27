import CoreGraphics

/// What a keyboard notification on an iPhone or iPad says about the keyboard: whether the touch keyboard is on screen,
/// or only the bar above it and the keyboard's shortcuts, which come up alone for a keyboard with keys. Without UIKit,
/// so it can be tried on the Mac too.
struct KeyboardFrame: Equatable {
    /// The keyboard covers part of the window: there is room to make under it.
    let isOnScreen: Bool
    let isTouchKeyboardShown: Bool
    let isShortcutsAlone: Bool

    /// - Parameters:
    ///   - frame: where the keyboard ends up, in the window's coordinates.
    ///   - bar: how tall the bar above the keyboard is, which the frame includes.
    init(frame: CGRect, in bounds: CGRect, bar: CGFloat, isHiding: Bool) {
        // No frame at all is what the floating keyboard on an iPad and some other keyboards send: nothing to go by.
        isOnScreen = !isHiding && !frame.isEmpty && frame.intersects(bounds)
        // Taller than the bar above it: the touch keyboard, not just the shortcuts a keyboard with keys leaves.
        isTouchKeyboardShown = isOnScreen && frame.height - bar > 120
        isShortcutsAlone = isOnScreen && !isTouchKeyboardShown
    }
}
