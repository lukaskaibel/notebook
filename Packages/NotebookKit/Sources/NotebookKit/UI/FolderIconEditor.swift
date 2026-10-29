#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Customize Folder, as the Finder has it: a colour, and a symbol or an emoji instead of the folder, each on the folder
/// in the sidebar as soon as it is chosen, and taken back together by one Undo. Symbols and emoji come in groups, with a
/// few suggested for the folder's name, and a search finds them by name or by what they are for. A popover on the Mac,
/// a sheet on iPhone and iPad.
struct FolderIconEditor: View {
    let workspace: Workspace
    let url: URL
    var close: () -> Void

    enum Tab: String, CaseIterable {
        case symbols = "Symbols", emoji = "Emoji"
    }

    /// The look when Customize Folder opened, for Undo.
    private let original: FolderIcon?
    @State private var icon: FolderIcon
    @State private var tab: Tab
    @State private var query = ""

    init(workspace: Workspace, url: URL, close: @escaping () -> Void) {
        self.workspace = workspace
        self.url = url
        self.close = close
        let current = workspace.folderIcon(for: url)
        original = current
        _icon = State(initialValue: current ?? FolderIcon())
        _tab = State(initialValue: current?.emoji != nil ? .emoji : .symbols)
    }

    private var name: String { workspace.folderName(url) }
    private var tint: Color { icon.color?.color ?? Color.theme(Theme.accent) }

    var body: some View {
        content
            .onChange(of: icon) { workspace.setFolderIcon(icon, for: url) }
            .onDisappear { workspace.keepFolderIconForUndo(from: original, to: icon.isPlain ? nil : icon, for: url) }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugFolderIcons.pick)) { notification in
                debugPick(notification.userInfo?["what"] as? String ?? "", notification.userInfo?["argument"] as? String ?? "")
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                preview(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Folder").font(.headline)
                    Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            colors
            tabs
            PopoverSearchField(text: $query, prompt: tab == .symbols ? "Search Symbols" : "Search Emoji")
            ScrollView {
                grid
                    .padding(.vertical, 2)
            }
            .frame(height: 252)
            HStack {
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 344)
        #else
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    preview(size: 76)
                        .padding(.top, 4)
                    colors
                    tabs
                    grid
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: tab == .symbols ? "Search Symbols" : "Search Emoji")
            .navigationTitle("Customize Folder")
            .navigationSubtitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { close() }
                }
            }
        }
        #endif
    }

    // MARK: - The folder

    /// The folder as the sidebar will show it, larger.
    private func preview(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(tint.opacity(0.15))
            if let emoji = icon.emoji {
                Text(emoji).font(.system(size: size * 0.56))
            } else {
                Image(systemName: icon.shownSymbol)
                    .font(.system(size: size * 0.46))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(name), \(description(of: icon))")
    }

    // MARK: - Colours

    /// No colour, which is the folder's own, then the Finder's tag colours.
    private var colors: some View {
        HStack(spacing: 0) {
            swatch(nil)
            ForEach(FolderColor.allCases, id: \.self) { color in
                Spacer(minLength: 4)
                swatch(color)
            }
        }
        // Together, as in a row of the Finder's tags, on a wide iPad sheet too.
        .frame(maxWidth: 380)
    }

    private func swatch(_ color: FolderColor?) -> some View {
        #if os(macOS)
        let size: CGFloat = 22
        #else
        let size: CGFloat = 30
        #endif
        return ColorSwatch(color: color?.color, name: color?.name ?? "No Colour", isChosen: icon.color == color, size: size) { icon.color = color }
    }

    // MARK: - Symbols and emoji

    private var tabs: some View {
        Picker("Show", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var grid: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = tab == .symbols ? FolderIconCatalog.symbols(matching: query) : FolderIconCatalog.emoji(matching: query)
            if found.isEmpty {
                Text("No \(tab == .symbols ? "Symbols" : "Emoji") for “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                section(nil, found)
            }
        } else {
            let groups = tab == .symbols ? FolderIconCatalog.symbolGroups : FolderIconCatalog.emojiGroups
            let suggested = tab == .symbols ? FolderIconCatalog.suggestedSymbols(for: name) : FolderIconCatalog.suggestedEmoji(for: name)
            LazyVStack(alignment: .leading, spacing: 14) {
                if !suggested.isEmpty { section("Suggested", suggested) }
                ForEach(groups) { group in section(group.title, group.items) }
            }
        }
    }

    private func section(_ title: String?, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell + 8), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in cell(item) }
            }
        }
    }

    #if os(macOS)
    private static let cell: CGFloat = 32
    #else
    private static let cell: CGFloat = 44
    #endif

    private func cell(_ item: String) -> some View {
        let isChosen = isChosen(item)
        return Button { choose(item) } label: {
            ZStack {
                if isChosen {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tab == .symbols ? tint : tint.opacity(0.22))
                }
                if tab == .symbols {
                    Image(systemName: item)
                        .font(.system(size: Self.cell * 0.5))
                        .foregroundStyle(isChosen ? Color.white : Color.primary.opacity(0.75))
                } else {
                    Text(item).font(.system(size: Self.cell * 0.62))
                }
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label(of: item))
        .accessibilityLabel(label(of: item))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The folder itself is the plain one: a symbol only when another is chosen.
    private func isChosen(_ item: String) -> Bool {
        tab == .symbols ? icon.emoji == nil && (icon.symbol ?? FileKind.folder.symbol) == item : icon.emoji == item
    }

    /// Chooses a symbol or an emoji instead of the other; the chosen one again gives the plain folder back.
    private func choose(_ item: String) {
        let again = isChosen(item)
        icon.emoji = nil
        icon.symbol = nil
        guard !again, item != FileKind.folder.symbol else { return }
        if tab == .symbols { icon.symbol = item } else { icon.emoji = item }
    }

    private func label(of item: String) -> String {
        tab == .symbols ? item.replacingOccurrences(of: ".", with: " ") : FolderIconCatalog.name(of: item).capitalized
    }

    private func description(of icon: FolderIcon) -> String {
        let shape = icon.emoji.map { FolderIconCatalog.name(of: $0).capitalized } ?? icon.symbol.map { $0.replacingOccurrences(of: ".", with: " ") } ?? "folder"
        return icon.color.map { "\($0.name) \(shape)" } ?? shape
    }

    #if DEBUG
    /// iconpick: the debug remote's clicks in Customize Folder.
    private func debugPick(_ what: String, _ argument: String) {
        switch what {
        case "tab": tab = Tab(rawValue: argument.capitalized) ?? .symbols
        case "search": query = argument
        case "color": icon.color = FolderColor.allCases.first { $0.name.lowercased() == argument.lowercased() }
        default:
            // In the tab it is in, as a click would be.
            tab = NSImage.hasSymbol(argument) ? .symbols : .emoji
            choose(argument)
        }
    }
    #endif
}

/// A round colour to choose, as System Settings shows accent colours and the Finder its tags, ringed while chosen.
/// Without a colour: a slash through an empty circle, as a colour well shows none.
struct ColorSwatch: View {
    let color: Color?
    let name: String
    let isChosen: Bool
    let size: CGFloat
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            ZStack {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1.5)
                    Capsule().fill(.secondary).frame(width: 1.5, height: size * 0.8).rotationEffect(.degrees(45))
                }
            }
            .frame(width: size, height: size)
            .padding(size < 20 ? 3 : 4)
            .overlay {
                if isChosen { Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: size < 20 ? 1.5 : 2) }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

#if os(macOS)
/// The system's search field, for the popover, which has no toolbar for `.searchable`.
private struct PopoverSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        // The clear button sends the action, not a change of text.
        field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func changed(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
#endif
