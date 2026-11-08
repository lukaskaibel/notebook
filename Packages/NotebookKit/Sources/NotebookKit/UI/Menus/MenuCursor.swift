import Observation
import SwiftUI

/// The row a menu lights up, under the pointer, the finger or the arrow keys, and the row whose submenu is open. A row
/// asks only about itself, so moving the light redraws the row it leaves and the row it enters and nothing else, however
/// long the menu is. As in Issues.
@MainActor @Observable
final class MenuCursor<Key: Hashable & Sendable> {
    @ObservationIgnored private var lit: Key?
    @ObservationIgnored private var opened: Key?
    /// Whether the open submenu took the keyboard: opened with the keys it did, opened under the pointer it didn't.
    @ObservationIgnored private(set) var openTakesKey = true
    /// Counts the moves made with the keys, so a list can scroll the lit row into view; the pointer is on it already
    /// when it moves.
    private(set) var keyMoves = 0

    init(_ key: Key? = nil) {
        lit = key
    }

    /// The lit row, for key presses and actions. A view that reads it in its body is redrawn on every move; rows ask
    /// `isLit` instead.
    var key: Key? {
        get {
            access(keyPath: \.key)
            return lit
        }
        set {
            guard newValue != lit else { return }
            let old = lit
            withMutation(keyPath: \.key) {
                notify([old, newValue], { \.[lit: $0] }) { lit = newValue }
            }
        }
    }

    /// The row whose submenu is open.
    var open: Key? {
        get {
            access(keyPath: \.open)
            return opened
        }
        set {
            guard newValue != opened else { return }
            let old = opened
            withMutation(keyPath: \.open) {
                notify([old, newValue], { \.[open: $0] }) { opened = newValue }
            }
        }
    }

    subscript(lit key: Key) -> Bool {
        access(keyPath: \.[lit: key])
        return lit == key
    }

    subscript(open key: Key) -> Bool {
        access(keyPath: \.[open: key])
        return opened == key
    }

    /// Whether this row shows lit: under the pointer or the keys, or with its submenu open.
    func isLit(_ key: Key) -> Bool {
        self[lit: key] || self[open: key]
    }

    /// Moves the light with the arrow keys through `keys`, wrapping around at the ends; from nothing lit, down starts
    /// at the top and up at the bottom.
    func step(_ delta: Int, through keys: [Key]) {
        guard !keys.isEmpty else { return }
        let next: Int
        if let current = lit.flatMap({ keys.firstIndex(of: $0) }) {
            next = (current + delta + keys.count) % keys.count
        } else {
            next = delta > 0 ? 0 : keys.count - 1
        }
        moveByKeys(to: keys[next])
    }

    /// Lights a row from the keys, so the list scrolls to it.
    func moveByKeys(to key: Key?) {
        self.key = key
        keyMoves += 1
    }

    /// Opens the row's submenu; `takesKey` gives the submenu the keyboard.
    func openSubmenu(_ key: Key, takesKey: Bool) {
        openTakesKey = takesKey
        open = key
    }

    private func notify(_ keys: [Key?], _ path: (Key) -> KeyPath<MenuCursor, Bool>, _ change: () -> Void) {
        let paths = keys.compactMap { $0 }.map(path)
        for path in paths { _$observationRegistrar.willSet(self, keyPath: path) }
        change()
        for path in paths { _$observationRegistrar.didSet(self, keyPath: path) }
    }
}
