#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// One entry of the app's menus, which are drawn in glass as Issues draws them (and Linear before it), not as the
/// system's: rows as tall as a picker's, a symbol on the left, the keys on the right, and a field on top to type in that
/// finds any entry, also inside a submenu. The same entries make the menu on the Mac, the iPad and the iPhone.
struct MenuEntry {
    enum Kind {
        case action(@MainActor () -> Void)
        /// Opens beside the menu (Mac, iPad) or in its place (iPhone). Its entries are made when it opens, or when
        /// typing looks for something in it.
        case submenu(@MainActor () -> [MenuEntry])
        case divider
        /// A section's name, such as a location's over its folders.
        case title
    }

    enum Icon {
        case none
        case symbol(String)
        /// A symbol in a colour of its own, such as a folder's.
        case tinted(String, Color)
        case emoji(String)
        #if os(macOS)
        /// An AppKit menu item's image.
        case image(NSImage)
        #endif
    }

    var kind: Kind
    var title: String
    var icon: Icon = .none
    /// The keys that do the same, as a menu writes them: "⇧⌘C".
    var keys: String?
    var isChecked = false
    var isEnabled = true
    var isDestructive = false
    /// How many steps it is indented: a folder under the one it is in.
    var indent = 0
    /// Set as it looks, such as a text style in its own font.
    var font: Font?
    /// For a submenu: what its field says before anything is typed ("Move to…").
    var placeholder: String?
    /// Shown after the title when typing finds it, where the menu's indentation no longer says it: the folders a
    /// folder is in.
    var detail: String?
    /// What a submenu has chosen, on the right of its row: Sort By's order.
    var value: String?

    /// An entry that does something.
    init(_ title: String, _ symbol: String? = nil, keys: String? = nil, checked: Bool = false, enabled: Bool = true,
         destructive: Bool = false, action: @escaping @MainActor () -> Void) {
        kind = .action(action)
        self.title = title
        icon = symbol.map { .symbol($0) } ?? .none
        self.keys = keys
        isChecked = checked
        isEnabled = enabled
        isDestructive = destructive
    }

    init(kind: Kind, title: String, icon: Icon = .none) {
        self.kind = kind
        self.title = title
        self.icon = icon
    }

    /// An entry that opens more of them.
    static func submenu(_ title: String, _ symbol: String? = nil, enabled: Bool = true, placeholder: String? = nil,
                        @MenuContent _ content: @escaping @MainActor () -> [MenuEntry]) -> MenuEntry {
        var entry = MenuEntry(kind: .submenu(content), title: title, icon: symbol.map { .symbol($0) } ?? .none)
        entry.isEnabled = enabled
        entry.placeholder = placeholder
        return entry
    }

    static var divider: MenuEntry { MenuEntry(kind: .divider, title: "") }

    /// A section's name over the entries after it.
    static func section(_ title: String) -> MenuEntry { MenuEntry(kind: .title, title: title) }

    var isDivider: Bool {
        if case .divider = kind { true } else { false }
    }

    var isTitle: Bool {
        if case .title = kind { true } else { false }
    }

    var hasSubmenu: Bool {
        if case .submenu = kind { true } else { false }
    }

    /// Something to light up and pick: an action or a submenu, not a line or a title.
    var isChoosable: Bool {
        switch kind {
        case .action, .submenu: isEnabled
        case .divider, .title: false
        }
    }

    func with(_ change: (inout MenuEntry) -> Void) -> MenuEntry {
        var copy = self
        change(&copy)
        return copy
    }

    /// Without lines first, last or twice in a row, which come from groups left empty.
    static func tidy(_ entries: [MenuEntry]) -> [MenuEntry] {
        var tidy: [MenuEntry] = []
        for entry in entries {
            if entry.isDivider, tidy.last.map({ $0.isDivider || $0.isTitle }) ?? true { continue }
            if entry.isTitle, tidy.last?.isDivider == true { tidy.removeLast() }
            tidy.append(entry)
        }
        while tidy.last.map({ $0.isDivider || $0.isTitle }) == true { tidy.removeLast() }
        return tidy
    }
}

/// Builds entries as SwiftUI builds a menu's buttons: one after the other, with `if`, `for` and groups of them.
@resultBuilder
enum MenuContent {
    static func buildBlock(_ parts: [MenuEntry]...) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildExpression(_ entry: MenuEntry) -> [MenuEntry] { [entry] }
    static func buildExpression(_ entries: [MenuEntry]) -> [MenuEntry] { entries }
    static func buildOptional(_ entries: [MenuEntry]?) -> [MenuEntry] { entries ?? [] }
    static func buildEither(first entries: [MenuEntry]) -> [MenuEntry] { entries }
    static func buildEither(second entries: [MenuEntry]) -> [MenuEntry] { entries }
    static func buildArray(_ parts: [[MenuEntry]]) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildLimitedAvailability(_ entries: [MenuEntry]) -> [MenuEntry] { entries }
}

/// The entries of one menu or submenu, with its submenus' entries made once, when they open or are searched.
@MainActor
final class MenuLevel {
    let entries: [MenuEntry]
    /// What the field says before anything is typed.
    let placeholder: String
    private var submenus: [Int: MenuLevel] = [:]

    init(_ entries: [MenuEntry], placeholder: String? = nil) {
        self.entries = MenuEntry.tidy(entries)
        self.placeholder = placeholder ?? "Type to find…"
    }

    convenience init(@MenuContent _ content: () -> [MenuEntry]) {
        self.init(content())
    }

    func submenu(at index: Int) -> MenuLevel? {
        if let made = submenus[index] { return made }
        guard entries.indices.contains(index), case .submenu(let make) = entries[index].kind else { return nil }
        let level = MenuLevel(make(), placeholder: entries[index].placeholder)
        submenus[index] = level
        return level
    }

    /// An entry as shown: one of the menu's own, or one found anywhere in it by typing, with the submenus it is in.
    struct Row: Identifiable {
        let id: Int
        let entry: MenuEntry
        /// The submenus it is in, when found by typing ("Format").
        var path: [String] = []
        /// Its place in this menu, for opening its submenu; nil for one found inside a submenu.
        var index: Int?
        /// Found by typing.
        var isFound = false
    }

    /// The menu's entries, or those typed for: every action anywhere in it whose title and submenus have all the words.
    func rows(for query: String, limit: Int = 14) -> [Row] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return entries.enumerated().map { Row(id: $0.offset, entry: $0.element, index: $0.offset) }
        }
        var found: [Row] = []
        // The menu's own entries first, then those in its submenus: typing "copy" finds Copy before Edit › Copy Style.
        var deeper: [(level: MenuLevel, path: [String])] = []
        func search(_ level: MenuLevel, path: [String]) {
            for (index, entry) in level.entries.enumerated() where found.count < limit {
                switch entry.kind {
                case .submenu:
                    if entry.isEnabled, let submenu = level.submenu(at: index) { deeper.append((submenu, path + [entry.title])) }
                case .action:
                    guard entry.isEnabled else { continue }
                    let haystack = (path + [entry.title, entry.detail ?? ""]).joined(separator: " ").lowercased()
                    if words.allSatisfy(haystack.contains) {
                        found.append(Row(id: found.count, entry: entry, path: path, index: path.isEmpty ? index : nil, isFound: true))
                    }
                case .divider, .title:
                    continue
                }
            }
        }
        search(self, path: [])
        while !deeper.isEmpty, found.count < limit {
            let next = deeper.removeFirst()
            search(next.level, path: next.path)
        }
        return found
    }

    /// Whether the menu, with its submenus, has more entries than `count`, so that a field to type in helps.
    func isLonger(than count: Int) -> Bool {
        entries.filter(\.isChoosable).count + entries.filter(\.hasSubmenu).count * 3 > count
    }

    /// Whether any entry has a symbol: a menu of words alone, such as Sort By's, leaves out the column for them.
    lazy var hasIcons: Bool = entries.contains { entry in
        if case .none = entry.icon { false } else { true }
    }
}

/// How a menu is laid out on each device: the Mac's as Issues has them, the iPad's and the iPhone's grown for fingers
/// and set in the size the text is set in.
struct MenuMetrics {
    var width: CGFloat
    var row: CGFloat
    var fontSize: CGFloat
    /// The symbols' size, and the column they stand in.
    var symbol: CGFloat
    var iconColumn: CGFloat
    /// Between the symbol and the title.
    var gap: CGFloat
    /// Inside a row, left and right.
    var padding: CGFloat
    /// Around the rows, inside the panel.
    var outer: CGFloat
    var field: CGFloat
    var divider: CGFloat
    var keySize: CGFloat
    var titleSize: CGFloat
    var cornerRadius: CGFloat
    var indent: CGFloat
    /// How tall a menu can grow before it scrolls.
    var maxHeight: CGFloat = 640

    var font: Font { .system(size: fontSize) }

    /// The radius of what sits just inside the menu's edge, its field and its rows: the menu's own less the inset, so
    /// the corners run alongside the menu's.
    var innerRadius: CGFloat { cornerRadius - outer }

    /// A field's or a lit row's shape: concentric with the menu around it.
    var innerShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(innerRadius)), isUniform: true)
    }

    static let mac = MenuMetrics(width: 272, row: 30, fontSize: 13, symbol: 13, iconColumn: 16, gap: 9, padding: 9, outer: 6,
                                 field: 32, divider: 11, keySize: 12, titleSize: 11, cornerRadius: 14, indent: 16)

    #if os(iOS)
    /// The iPad's: 15 pt, rows 40 pt tall, at the size the text is set in.
    static func pad(_ scale: CGFloat) -> MenuMetrics {
        MenuMetrics(width: 300 * min(scale, 1.4), row: 40 * scale, fontSize: 15 * scale, symbol: 16 * scale, iconColumn: 22 * scale, gap: 10, padding: 11,
                    outer: 7, field: 38 * scale, divider: 13, keySize: 14 * scale, titleSize: 13 * scale,
                    cornerRadius: 22, indent: 20)
    }

    /// The iPhone's: 17 pt, rows 44 pt tall, at the size the text is set in.
    static func phone(_ scale: CGFloat) -> MenuMetrics {
        MenuMetrics(width: 290 * min(scale, 1.3), row: 44 * scale, fontSize: 17 * scale, symbol: 18 * scale, iconColumn: 24 * scale, gap: 11, padding: 12,
                    outer: 7, field: 42 * scale, divider: 15, keySize: 15 * scale, titleSize: 13 * scale,
                    cornerRadius: 28, indent: 20)
    }
    #endif

    /// How tall the rows are, for a menu that scrolls.
    func height(of rows: [MenuLevel.Row]) -> CGFloat {
        rows.reduce(0) { total, row in
            total + (row.entry.isDivider ? divider : row.entry.isTitle ? titleSize + 13 : row.entry.font == nil ? self.row : self.row + 6)
        }
    }
}

/// A menu's row: its icon, its title (with the submenus it is in, when found by typing), and on the right a checkmark,
/// its keys or the arrow of a submenu. It asks the cursor only about itself, so the light moving over the menu redraws
/// two rows.
struct MenuRowLabel: View {
    let row: MenuLevel.Row
    let metrics: MenuMetrics
    let isLit: Bool
    var showsKeys = true
    /// The menu has symbols: a column for them, empty where an entry has none.
    var hasIcons = true

    var body: some View {
        let entry = row.entry
        HStack(spacing: metrics.gap) {
            if hasIcons || row.isFound {
                icon(entry.icon)
                    .frame(width: metrics.iconColumn, height: metrics.iconColumn)
                    .padding(.leading, row.isFound ? 0 : CGFloat(entry.indent) * metrics.indent)
            }
            HStack(spacing: 5) {
                ForEach(Array(row.path.enumerated()), id: \.offset) { _, step in
                    Text(step).foregroundStyle(Color.theme(Theme.menuTextTertiary))
                    Image(systemName: "chevron.right")
                        .font(.system(size: metrics.fontSize * 0.6, weight: .bold))
                        .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                }
                Text(entry.title)
                    .font(entry.font ?? metrics.font)
                    .foregroundStyle(entry.isDestructive ? Color.red : Color.theme(Theme.menuText))
                if row.isFound, let detail = entry.detail {
                    Text(detail).foregroundStyle(Color.theme(Theme.menuTextTertiary))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if entry.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: metrics.fontSize * 0.85, weight: .bold))
                    .foregroundStyle(Color.theme(Theme.accent))
            }
            if let value = entry.value {
                Text(value)
                    .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                    .lineLimit(1)
            }
            if showsKeys, let keys = entry.keys {
                Text(keys)
                    .font(.system(size: metrics.keySize))
                    .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            }
            if entry.hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.fontSize * 0.7, weight: .bold))
                    .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            }
        }
        .font(metrics.font)
        .padding(.horizontal, metrics.padding)
        .frame(height: entry.font == nil ? metrics.row : metrics.row + 6)
        .background(metrics.innerShape.fill(isLit && entry.isEnabled ? Color.theme(Theme.menuHighlight) : .clear))
        .contentShape(Rectangle())
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, metrics.outer)
    }

    @ViewBuilder
    private func icon(_ icon: MenuEntry.Icon) -> some View {
        let color = row.entry.isDestructive ? Color.red : Color.theme(Theme.menuTextSecondary)
        switch icon {
        case .none:
            Color.clear
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: metrics.symbol))
                .foregroundStyle(color)
        case .tinted(let name, let tint):
            Image(systemName: name)
                .font(.system(size: metrics.symbol))
                .foregroundStyle(tint)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: metrics.symbol))
        #if os(macOS)
        case .image(let image):
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .frame(maxWidth: metrics.symbol + 2, maxHeight: metrics.symbol + 2)
        #endif
        }
    }
}

/// The line between groups of a menu's rows.
struct MenuLine: View {
    let metrics: MenuMetrics

    var body: some View {
        Rectangle()
            .fill(Color.theme(Theme.popoverBorder))
            .frame(height: 1)
            .padding(.horizontal, metrics.outer + 9)
            .padding(.vertical, (metrics.divider - 1) / 2)
    }
}

/// A section's name, such as a location's over its folders.
struct MenuSectionTitle: View {
    let title: String
    let metrics: MenuMetrics

    var body: some View {
        Text(title)
            .font(.system(size: metrics.titleSize, weight: .semibold))
            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            .lineLimit(1)
            .padding(.horizontal, metrics.outer + metrics.padding)
            .padding(.top, 7)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The keys of a shortcut as a menu writes them: "⇧⌘C".
enum MenuKeys {
    static func text(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    #if os(macOS)
    /// An AppKit menu item's keys.
    static func text(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        switch key {
        case " ": text += "Space"
        case "\u{8}", "\u{7F}": text += "⌫"
        case "\r": text += "↩"
        default: text += key.uppercased()
        }
        return text
    }
    #endif
}
