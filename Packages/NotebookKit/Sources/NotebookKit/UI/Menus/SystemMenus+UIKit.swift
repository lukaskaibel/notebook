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

/// The same menu laid over a view in a list's section header, such as a location's name, and opened with a tap or by
/// touching and holding it. SwiftUI's `Menu` and `.contextMenu` there open with a tap at most: the header takes the touch
/// and hold first and does nothing with it, so it has to be a UIKit button, whose own menu gets the touch first.
struct HeaderMenuButton: UIViewRepresentable {
    /// What VoiceOver reads for it, as the view under it is hidden from VoiceOver.
    let label: String
    @MenuContent var entries: () -> [MenuEntry]

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = label
        let entries = entries
        // Made when it opens, so it says what is true then, such as whether the folder is a favourite.
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button] done in
            done(MainActor.assumeIsolated { SystemMenuElements.elements(of: entries(), from: button) })
        }])
    }
}

/// Entries as UIKit's menus take them, laid out as `SystemMenuItems` lays them out for SwiftUI's.
@MainActor
enum SystemMenuElements {
    static func elements(of entries: [MenuEntry], from source: UIView?) -> [UIMenuElement] {
        SystemMenuItems.groups(of: MenuEntry.tidy(entries)).map { group in
            UIMenu(title: group.title ?? "", options: .displayInline, children: group.entries.compactMap { element($0, from: source) })
        }
    }

    private static func element(_ entry: MenuEntry, from source: UIView?) -> UIMenuElement? {
        let image = SystemMenuItems.image(of: entry.icon)
        var attributes: UIMenuElement.Attributes = entry.isEnabled ? [] : .disabled
        if entry.isDestructive { attributes.insert(.destructive) }
        switch entry.kind {
        case .action(let action):
            let shares = entry.shares
            return UIAction(title: entry.title, subtitle: entry.value, image: image, attributes: attributes, state: entry.isChecked ? .on : .off) { _ in
                MainActor.assumeIsolated { shares.isEmpty ? action() : share(shares, from: source) }
            }
        case .submenu(let make):
            if let instead = entry.insteadOfSubmenu {
                return UIAction(title: entry.title, subtitle: entry.value, image: image, attributes: attributes) { _ in
                    MainActor.assumeIsolated { instead() }
                }
            }
            guard entry.isEnabled else { return UIAction(title: entry.title, subtitle: entry.value, image: image, attributes: attributes) { _ in } }
            return UIMenu(title: entry.title, subtitle: entry.value, image: image, children: [UIDeferredMenuElement.uncached { done in
                done(MainActor.assumeIsolated { elements(of: make(), from: source) })
            }])
        case .divider, .title:
            return nil
        }
    }

    /// The share sheet, coming from where the menu was, as SwiftUI's `ShareLink` brings it up.
    private static func share(_ urls: [URL], from source: UIView?) {
        guard let source, let presenter = source.window?.rootViewController?.topmostPresented else { return }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        presenter.present(sheet, animated: true)
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

/// A view in a list's row next to others with menus of their own, such as one of Recent's cards. A list lifts its whole
/// row for a menu touched and held anywhere in it (`appContextMenu`), so every card would come out for the one held.
/// Hosted apart from the list, the view has a menu of its own, the system's, which lifts it alone, with its own
/// corners, and leaves the others in place; SwiftUI's own menus don't open there. As big as `content` is. Out of the
/// list's reach, `content` gets neither its environment nor its navigation links: what it needs comes in as arguments,
/// and its buttons open screens through the workspace.
struct HostedWithMenu<Content: View>: UIViewControllerRepresentable {
    let cornerRadius: CGFloat
    @MenuContent var entries: () -> [MenuEntry]
    @ViewBuilder var content: Content

    func makeCoordinator() -> ViewMenu { ViewMenu() }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        // In a row, not at the screen's edges: keeping clear of the bars and the keyboard is the list's.
        host.safeAreaRegions = []
        host.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
        context.coordinator.entries = entries
        context.coordinator.cornerRadius = cornerRadius
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController host: UIHostingController<Content>, context: Context) -> CGSize? {
        host.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: .infinity))
    }
}

/// The menu of a `HostedWithMenu`: its entries, made when it opens, and the view lifted out with its corners.
@MainActor
final class ViewMenu: NSObject, UIContextMenuInteractionDelegate {
    var entries: () -> [MenuEntry] = { [] }
    var cornerRadius: CGFloat = 0

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let entries = entries
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak view = interaction.view] _ in
            MainActor.assumeIsolated { UIMenu(children: SystemMenuElements.elements(of: entries(), from: view)) }
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(in: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(in: interaction)
    }

    private func preview(in interaction: UIContextMenuInteraction) -> UITargetedPreview? {
        guard let view = interaction.view, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: view, parameters: parameters)
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

    /// The symbol or emoji beside an entry, for UIKit's menus.
    static func image(of icon: MenuEntry.Icon) -> UIImage? {
        switch icon {
        case .none: nil
        case .symbol(let name): UIImage(systemName: name)
        case .tinted(let name, let color): UIImage(systemName: name)?.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
        case .emoji(let emoji): picture(of: emoji)
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
