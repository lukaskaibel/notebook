#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// A link's address is never part of the text you see: the pencil after it opens this popover to change it, open it
/// or take the link off. The heading tag in the margin opens a menu of heading levels.
extension EditorController {
    #if os(macOS)
    /// `range` is the whole link, `[text](address)`, as it is now.
    func editLink(at range: NSRange, isNew: Bool = false) {
        guard let link = linkSpan(at: range.location) else { return }
        let address = isNew ? "" : nsText.substring(with: destinationRange(of: link))
        let model = LinkEditorModel(address: address.removingPercentEncoding ?? address)
        let popover = NSPopover()
        popover.behavior = .transient
        #if DEBUG
        // Recordings run in a window in the background, where a transient popover closes right away.
        if MarkdownTextView.drawsCaretAlways { popover.behavior = .applicationDefined }
        #endif
        popover.animates = true
        var finished = false
        let finish: (LinkEditorModel.Outcome) -> Void = { [weak self, weak popover] outcome in
            guard !finished else { return }
            finished = true
            popover?.performClose(nil)
            self?.finishEditingLink(at: range.location, outcome: outcome, isNew: isNew)
        }
        model.finish = finish
        #if DEBUG
        LinkEditorModel.current = model
        #endif
        popover.contentViewController = NSHostingController(rootView: LinkEditor(model: model))
        let anchor = layoutManager.rect(forObjectAt: link.markers.last?.location ?? link.range.location, origin: textView.textContainerOrigin)
            ?? textView.firstRect(forCharacterRange: link.content, actualRange: nil).offsetBy(dx: 0, dy: 0)
        popover.show(relativeTo: anchor.insetBy(dx: -2, dy: -2), of: textView, preferredEdge: .maxY)
        // Closing by clicking elsewhere keeps what was typed.
        NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: popover, queue: .main) { _ in
            MainActor.assumeIsolated { finish(.save(model.address)) }
        }
    }
    #endif

    /// A link clicked or tapped. One to a place in this note (`#goals`, AsciiDoc's `<<goals>>`) scrolls there; the app
    /// opens anything else.
    func follow(_ kind: LinkTarget.Kind) {
        if case .url(let address) = kind, address.hasPrefix("#"), let location = anchorLocation(String(address.dropFirst())) {
            scroll(to: OutlineHeading(id: -1, level: 0, title: "", location: location))
            return
        }
        delegate?.editor(self, open: kind)
    }

    /// Where an id points in the note: an anchor (`[[goals]]`, `[#goals]`), or a heading it is the id of, as
    /// Asciidoctor makes one (`_goals_and_scope`) or GitHub (`goals-and-scope`).
    func anchorLocation(_ id: String) -> Int? {
        let text = nsText
        func folded(_ string: String) -> String { String(string.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        let wanted = folded(id)
        guard !wanted.isEmpty else { return nil }
        for (index, line) in document.lines.enumerated() {
            let source = text.substring(with: line.range)
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            let isAnchor = source.contains("[[\(id)]]") || source.contains("[[\(id),") || ["]", ".", ","].contains { trimmed.hasPrefix("[#\(id)" + $0) }
            if isAnchor {
                // An anchor on a line of its own points at the line under it.
                guard line.kind == .markup else { return line.range.location }
                return document.lines[(index + 1)...].first { $0.kind != .markup }?.range.location ?? line.range.location
            }
            if case .heading = line.kind, folded(text.substring(with: line.content)) == wanted { return line.range.location }
        }
        return nil
    }

    func linkSpan(at location: Int) -> InlineSpan? {
        guard !document.lines.isEmpty, location < storage.length else { return nil }
        return document.lines[document.lineIndex(containing: location)].spans.first {
            if case .link = $0.kind { return $0.range.location == location }
            return false
        }
    }

    /// Between `](` and `)`; in AsciiDoc the address before `[` (after `link:` or `xref:`), or in `<<` before `,`.
    func destinationRange(of link: InlineSpan) -> NSRange {
        if syntax == .asciidoc, let open = link.markers.first {
            let written = nsText.substring(with: open)
            if written.hasPrefix("<<") {
                let comma = (written as NSString).range(of: ",")
                return NSRange(location: open.location + 2, length: (comma.location == NSNotFound ? open.length : comma.location) - 2)
            }
            let prefix = ["link:", "xref:"].first { written.hasPrefix($0) }?.utf16.count ?? 0
            let end = written.hasSuffix("[") ? open.length - 1 : open.length
            return NSRange(location: open.location + prefix, length: max(0, end - prefix))
        }
        let close = link.markers.last ?? NSRange(location: link.range.upperBound, length: 0)
        return NSRange(location: close.location + 2, length: max(0, close.length - 3))
    }

    func finishEditingLink(at location: Int, outcome: LinkEditorModel.Outcome, isNew: Bool) {
        guard let link = linkSpan(at: location) else { return }
        let text = nsText.substring(with: link.content)
        switch outcome {
        case .save(let address):
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, isNew {
                replace(link.range, with: text, select: NSRange(location: link.range.location + (text as NSString).length, length: 0), actionName: "Add Link")
            } else if trimmed != nsText.substring(with: destinationRange(of: link)) {
                let encoded = trimmed.replacingOccurrences(of: " ", with: "%20")
                replace(destinationRange(of: link), with: encoded, select: NSRange(location: link.content.upperBound, length: 0), actionName: "Edit Link")
            }
        case .open(let address):
            if let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil { openExternally(url) }
        case .remove:
            replace(link.range, with: text, select: NSRange(location: link.range.location + (text as NSString).length, length: 0), actionName: "Remove Link")
        }
        makeTextFirstResponder()
    }

    /// The level of the heading the caret is on, while the caret rests on a heading whose level shows in the margin.
    var headingMarkLevel: (level: Int, marker: NSRange)? {
        guard isFocused, !isTracking, !document.lines.isEmpty, selection.length == 0 else { return nil }
        let line = document.lines[document.lineIndex(containing: selection.location)]
        guard case .heading(let level, let marker) = line.kind, marker.location < storage.length,
              storage.attribute(.notebookHeading, at: marker.location, effectiveRange: nil) != nil else { return nil }
        return (level, marker)
    }

    #if os(macOS)
    /// The level of the heading the caret is on, in the margin next to it, and what changed since a version, which
    /// reaches into the margin.
    func drawMarginMarks(in dirtyRect: NSRect) {
        if !layoutManager.changeMarks.isEmpty {
            let origin = textView.textContainerOrigin
            let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            layoutManager.drawChangeMarks(in: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), container: container, origin: origin)
        }
        guard let (level, marker) = headingMarkLevel,
              let rect = layoutManager.headingMarkRect(at: marker.location, origin: textView.textContainerOrigin),
              rect.intersects(dirtyRect) else { return }
        layoutManager.drawHeadingMark(level, in: rect)
        shownHeadingMark = rect
    }

    /// Title, Heading, Subheading or Body, for the heading the caret is on, each set as it is in the note, in glass as
    /// the Aa menu has them.
    func showHeadingMenu(at point: NSPoint) {
        let line = document.lines[document.lineIndex(containing: selection.location)]
        guard case .heading = line.kind else { return }
        let entries = FormatCommand.styles.map { style in
            MenuEntry(style.name, style.symbol, keys: style.keys, checked: currentLineFormat == style) { [weak self] in self?.perform(style) }
                .with { $0.font = Font(EditorStyle.styleSample(style, size: MenuMetrics.mac.fontSize, face: EditorStyle.typography.face)) }
        }
        GlassMenu.show(entries, at: NSRect(x: point.x, y: point.y + 4, width: 1, height: 8), in: textView)
    }
    #endif
}

@MainActor
@Observable
final class LinkEditorModel {
    enum Outcome {
        case save(String)
        case open(String)
        case remove
    }

    var address: String
    var finish: (Outcome) -> Void = { _ in }
    #if DEBUG
    /// The open link editor, for the debug remote.
    @ObservationIgnored static weak var current: LinkEditorModel?
    #endif

    init(address: String) {
        self.address = address
    }
}

#if os(macOS)
/// The popover: the address, and buttons to open it or take the link off.
private struct LinkEditor: View {
    @Bindable var model: LinkEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Link", text: $model.address, prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.finish(.save(model.address)) }
                .frame(width: 300)
            HStack {
                Button("Remove Link", role: .destructive) { model.finish(.remove) }
                Spacer()
                Button("Open") { model.finish(.open(model.address)) }
                    .disabled(URL(string: model.address)?.scheme == nil)
                Button("Done") { model.finish(.save(model.address)) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .onAppear { focused = true }
    }
}
#endif
