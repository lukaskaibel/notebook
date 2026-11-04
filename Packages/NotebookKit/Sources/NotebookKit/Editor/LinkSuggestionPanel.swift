#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

@MainActor
@Observable
final class SuggestionModel {
    var items: [LinkSuggestion] = []
    var selected = 0
    var query = ""

    /// Takes in new suggestions, keeping the one picked with the arrow keys while the query stays the same.
    func update(_ items: [LinkSuggestion], query: String) {
        if self.query != query || self.items != items {
            selected = min(selected, items.count - 1)
            if self.query != query { selected = 0 }
        }
        self.items = items
        self.query = query
    }
}

#if os(macOS)

/// The list that opens under `[[`: notes and files whose names match what you type, and a way to link a note that
/// doesn't exist yet. It floats next to the caret and never takes the focus from the text.
@MainActor
final class LinkSuggestionPanel {
    let model = SuggestionModel()
    var onPick: ((LinkSuggestion) -> Void)?
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var selected: LinkSuggestion? { model.items[safe: model.selected] }

    static let rowHeight: CGFloat = 24
    static let width: CGFloat = 340

    func show(_ items: [LinkSuggestion], query: String, at caret: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { close(); return }
        model.update(items, query: query)
        let panel = self.panel ?? makePanel()
        let height = CGFloat(items.count) * Self.rowHeight + 10
        var frame = NSRect(x: caret.minX - 18, y: caret.minY - height - 6, width: Self.width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = caret.maxY + 6 }
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func move(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        // A menu's own material and shape, so it reads as a menu of the system.
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        let list = NSHostingView(rootView: SuggestionList(model: model) { [weak self] suggestion in self?.onPick?(suggestion) })
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.topAnchor.constraint(equalTo: background.topAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

/// The rows, drawn like menu items: the chosen one filled with the accent colour.
private struct SuggestionList: View {
    var model: SuggestionModel
    var pick: (LinkSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                row(item, selected: index == model.selected)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(item) }
            }
        }
        .padding(5)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: LinkSuggestion, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon(item))
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : item.kind == .create ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(highlighted(item, selected: selected))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: LinkSuggestionPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? Color.accentColor : .clear))
    }

    private func icon(_ item: LinkSuggestion) -> String {
        switch item.kind {
        case .note: "doc.text"
        case .file: "doc"
        case .create: "plus"
        }
    }

    /// The name with the part you typed in bold.
    private func highlighted(_ item: LinkSuggestion, selected: Bool) -> AttributedString {
        var text = AttributedString(item.title)
        text.foregroundColor = selected ? .white : item.kind == .create ? .accentColor : .primary
        if item.kind != .create, !model.query.isEmpty, let range = text.range(of: model.query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .system(size: 13, weight: .semibold)
        }
        return text
    }
}

extension EditorController {
    func showSuggestions(_ items: [LinkSuggestion], query: String, anchor: Int) {
        guard let window = textView.window else { return closeSuggestions() }
        let caret = textView.firstRect(forCharacterRange: NSRange(location: anchor - 2, length: 0), actualRange: nil)
        suggestions.show(items, query: query, at: caret, in: window)
    }
}
#endif

extension EditorController {
    /// Follows the text between `[[` and `]]` as you type and shows what it could link to.
    func updateSuggestions() {
        guard let anchor = suggestionAnchor else { return }
        let text = nsText
        let selection = self.selection
        guard isFocused, selection.length == 0, anchor >= 2, anchor <= text.length,
              text.substring(with: NSRange(location: anchor - 2, length: 2)) == "[[",
              let close = closingBrackets(after: anchor),
              selection.location >= anchor, selection.location <= close else {
            closeSuggestions()
            return
        }
        let query = text.substring(with: NSRange(location: anchor, length: close - anchor))
        guard !query.contains("["), !query.contains("\n") else {
            closeSuggestions()
            return
        }
        let items = delegate?.editor(self, suggestionsFor: query) ?? []
        showSuggestions(items, query: query, anchor: anchor)
    }

    private func closingBrackets(after anchor: Int) -> Int? {
        let text = nsText
        var index = anchor
        while index + 1 < text.length {
            let character = text.character(at: index)
            if character == 10 { return nil }
            if character == 93, text.character(at: index + 1) == 93 { return index }
            index += 1
        }
        return nil
    }

    func closeSuggestions() {
        suggestionAnchor = nil
        suggestions.close()
    }

    /// Return or Tab: the suggestion picked, or none when there is nothing to pick.
    func acceptSelectedSuggestion() {
        if let suggestion = suggestions.selected { acceptSuggestion(suggestion) } else { closeSuggestions() }
    }

    func acceptSuggestion(_ suggestion: LinkSuggestion) {
        guard let anchor = suggestionAnchor, let close = closingBrackets(after: anchor) else { closeSuggestions(); return }
        let range = NSRange(location: anchor, length: close - anchor)
        closeSuggestions()
        if syntax == .asciidoc {
            // AsciiDoc has no `[[links]]` (they are anchors): an `xref:` to the note, or a link to the file, by the way
            // there from this note's folder.
            let whole = NSRange(location: anchor - 2, length: close + 2 - (anchor - 2))
            let url = suggestion.kind == .create ? nil : delegate?.editor(self, resolve: suggestion.insert)
            let path = url.map { url in folder.map { LinkUpdate.relativePath(from: $0, to: url) } ?? url.lastPathComponent }
                ?? suggestion.insert + "." + NoteSyntax.asciidoc.pathExtension
            let link = suggestion.kind == .file ? NoteMarkup.link(path, text: suggestion.title, syntax: .asciidoc)
                : NoteMarkup.noteLink(name: suggestion.title, path: path, syntax: .asciidoc)
            replace(whole, with: link, select: NSRange(location: whole.location + (link as NSString).length, length: 0), actionName: "Add Link")
            return
        }
        replace(range, with: suggestion.insert, select: NSRange(location: anchor + (suggestion.insert as NSString).length + 2, length: 0), actionName: "Add Link")
    }
}
