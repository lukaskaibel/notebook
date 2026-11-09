#if os(iOS)
import SwiftUI
import UIKit

// The iPhone's and the iPad's menus are the system's own, built from the same entries as the Mac's glass ones, with a
// symbol beside each entry: touched and held on a row, and from the bars' buttons such as ⋯ and Attach. A finger slides
// over them from entry to entry and picks the one it lets go on, and the system lifts a row and blurs the app, as in
// Files and Notes.

/// A button that opens its menu, as the bars' ⋯ and Attach do: the system's, with the entries the Mac shows in glass.
/// Touched and held, a finger can slide down to an entry and let go on it.
struct AppMenuButton<Label: View>: View {
    @MenuContent var entries: () -> [MenuEntry]
    @ViewBuilder var label: Label

    var body: some View {
        Menu { SystemMenuItems(make: entries) } label: { label }
    }
}

extension MenuEntry {
    /// Share, which the system's menus hand to the share sheet themselves, coming from where the menu was.
    static func share(_ urls: [URL]) -> MenuEntry {
        MenuEntry("Share", "square.and.arrow.up") {}.with { $0.shares = urls }
    }
}

// MARK: - Context menus

extension View {
    /// The view's menu, touched and held or clicked with the pointer's other button: the system's own, with the same
    /// entries and symbols as the Mac's in glass. The system lifts the view out over the blurred app, lets the finger
    /// slide to an entry and pick it, or drag the view away. `cornerRadius` rounds the lifted view where it isn't a
    /// list's row, as its own corners are.
    @ViewBuilder
    func appContextMenu(cornerRadius: CGFloat? = nil, @MenuContent _ entries: @escaping () -> [MenuEntry]) -> some View {
        if let cornerRadius {
            contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contextMenu { SystemMenuItems(make: entries) }
        } else {
            contextMenu { SystemMenuItems(make: entries) }
        }
    }

    /// The same, lifting `preview` out in the view's place.
    func appContextMenu<Preview: View>(@MenuContent _ entries: @escaping () -> [MenuEntry],
                                         @ViewBuilder preview: () -> Preview) -> some View {
        contextMenu { SystemMenuItems(make: entries) } preview: { preview() }
    }
}

/// Entries as the system's menus show them: the groups between lines as sections, a section's name over its group, a
/// submenu as a menu in the menu. Made when the menu opens.
private struct SystemMenuItems: View {
    let make: () -> [MenuEntry]

    var body: some View {
        let groups = Self.groups(of: MenuEntry.tidy(make()))
        ForEach(groups.indices, id: \.self) { index in
            Section {
                ForEach(groups[index].entries.indices, id: \.self) { item(groups[index].entries[$0]) }
            } header: {
                if let title = groups[index].title { Text(title) }
            }
        }
    }

    /// The entries between the lines and under the sections' names.
    static func groups(of entries: [MenuEntry]) -> [(title: String?, entries: [MenuEntry])] {
        var groups: [(title: String?, entries: [MenuEntry])] = [(nil, [])]
        for entry in entries {
            switch entry.kind {
            case .divider: groups.append((nil, []))
            case .title: groups.append((entry.title, []))
            case .action, .submenu: groups[groups.count - 1].entries.append(entry)
            }
        }
        return groups.filter { !$0.entries.isEmpty }
    }

    @ViewBuilder
    private func item(_ entry: MenuEntry) -> some View {
        switch entry.kind {
        case .action(let action):
            if !entry.shares.isEmpty {
                ShareLink(items: entry.shares) { label(entry) }
            } else if entry.isChecked {
                // Ticked, as the system ticks a menu's entries.
                Toggle(isOn: Binding(get: { true }, set: { _ in action() })) { label(entry) }
                    .disabled(!entry.isEnabled)
            } else {
                Button(role: entry.isDestructive ? .destructive : nil, action: action) { label(entry) }
                    .disabled(!entry.isEnabled)
            }
        case .submenu(let make):
            if let instead = entry.insteadOfSubmenu {
                Button(action: instead) { label(entry) }
                    .disabled(!entry.isEnabled)
            } else {
                Menu { SystemMenuItems(make: make) } label: { label(entry) }
                    .disabled(!entry.isEnabled)
            }
        case .divider, .title:
            EmptyView()
        }
    }

    /// Its title, what a submenu has chosen under it, as Sort By has the order in Files, and its symbol. Two texts and a
    /// picture, which a menu takes as title, subtitle and symbol; a `Label` would lose the subtitle.
    @ViewBuilder
    private func label(_ entry: MenuEntry) -> some View {
        Text(entry.title)
        if let value = entry.value { Text(value) }
        switch entry.icon {
        case .none: EmptyView()
        case .symbol(let name): Image(systemName: name)
        case .tinted(let name, let color):
            // The system's menus draw symbols in the text's colour, unless they have their own.
            Image(uiImage: UIImage(systemName: name)?.withTintColor(UIColor(color), renderingMode: .alwaysOriginal) ?? UIImage())
        case .emoji(let emoji): Image(uiImage: Self.picture(of: emoji))
        }
    }

    /// An emoji as a picture, which is all the system's menus take beside an entry.
    private static func picture(of emoji: String) -> UIImage {
        let text = emoji as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
        return UIGraphicsImageRenderer(size: text.size(withAttributes: attributes)).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }
    }
}
#endif
