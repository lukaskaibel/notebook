#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the styler needs to know beyond the text.
struct StyleEnvironment {
    /// The folder of the note, which relative paths start from.
    var folder: URL?
    /// The file a `[[link]]` goes to, if there is one.
    var resolve: (String) -> URL? = { _ in nil }
    /// The block the caret is in: tables, math, diagrams and frontmatter show their Markdown then.
    var activeBlock: Int?
    /// Where a link being typed starts (after its `[[`): it shows as text until it is finished.
    var composing: Int?
    /// A rendered preview's height, for diagrams and math shown under their source while you edit them.
    var previewHeight: (MarkdownBlock) -> CGFloat = { _ in 0 }
}

/// Turns a parsed note into attributes: fonts, colours, line heights, which punctuation hides and which objects are
/// drawn in place of Markdown. It only ever sets attributes; the characters stay exactly as they are in the file.
@MainActor
enum MarkdownStyler {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: EditorStyle.body,
            .foregroundColor: Theme.textBody,
            .paragraphStyle: EditorStyle.paragraph(),
            .baselineOffset: EditorStyle.baselineOffset(for: EditorStyle.body, lineHeight: EditorStyle.lineHeight),
        ]
    }

    /// One decoration per block, shared by all its lines, so the box behind a block is one run of text.
    private static var blockDecorations: [NSRange: Decoration] = [:]

    private static func decoration(for block: MarkdownBlock, _ kind: Decoration.Kind) -> Decoration {
        if let existing = blockDecorations[block.range], existing.kind == kind { return existing }
        let decoration = Decoration(kind)
        blockDecorations[block.range] = decoration
        return decoration
    }

    static func style(_ storage: NSTextStorage, document doc: MarkdownDocument, lines: [Int], environment env: StyleEnvironment) {
        let text = storage.string as NSString
        guard text.length == doc.length else { return }
        blockDecorations = [:]
        defer { blockDecorations = [:] }
        for index in lines where index < doc.lines.count {
            styleLine(storage, text: text, doc: doc, index: index, env: env)
        }
    }

    // MARK: - Lines

    private static func styleLine(_ s: NSTextStorage, text: NSString, doc: MarkdownDocument, index: Int, env: StyleEnvironment) {
        let line = doc.lines[index]
        let full = line.fullRange
        guard full.upperBound <= s.length else { return }
        s.setAttributes(baseAttributes, range: full)

        if let blockIndex = line.block {
            let block = doc.blocks[blockIndex]
            let active = env.activeBlock == blockIndex
            switch block.kind {
            case .code(let language):
                styleCode(s, text: text, doc: doc, line: line, index: index, block: block, language: language)
                return
            case .mermaid:
                if active {
                    styleCode(s, text: text, doc: doc, line: line, index: index, block: block, language: "mermaid", preview: env.previewHeight(block), previewKind: .diagram(source: diagramSource(text, doc, block)))
                } else {
                    styleSwapped(s, line: line, index: index, block: block, object: .mermaid(source: blockContent(text, doc, block)))
                }
                return
            case .table(let alignments):
                if active {
                    styleTableSource(s, text: text, line: line, index: index, block: block)
                } else {
                    let lines = Array(doc.lines[block.lines])
                    styleSwapped(s, line: line, index: index, block: block, object: .table(TableModel(text: text, lines: lines, alignments: alignments)))
                }
                return
            case .math:
                if active {
                    styleCode(s, text: text, doc: doc, line: line, index: index, block: block, language: "tex", preview: env.previewHeight(block), previewKind: .math(tex: mathSource(text, doc, block)))
                } else {
                    styleSwapped(s, line: line, index: index, block: block, object: .mathBlock(tex: mathSource(text, doc, block)))
                }
                return
            case .frontmatter:
                if active {
                    styleCode(s, text: text, doc: doc, line: line, index: index, block: block, language: "yaml")
                } else {
                    let count = max(0, block.lines.count - 2)
                    styleSwapped(s, line: line, index: index, block: block, object: .frontmatter(count: count))
                }
                return
            case .callout(let type):
                styleCallout(s, text: text, doc: doc, line: line, index: index, block: block, type: type, env: env)
                return
            case .quote:
                break
            }
        }

        switch line.kind {
        case .blank:
            return
        case .heading(let level, let marker):
            let font = EditorStyle.headingFont(level)
            let height = EditorStyle.headingLineHeight(level)
            let before = index == 0 ? 0 : EditorStyle.headingSpacingBefore(level)
            s.addAttributes([
                .font: font,
                .foregroundColor: Theme.text,
                .paragraphStyle: EditorStyle.paragraph(lineHeight: height, before: before, after: 4),
                .baselineOffset: EditorStyle.baselineOffset(for: font, lineHeight: height),
            ], range: full)
            // The #s show next to the caret with a keyboard, and while they are typed (`EditorController.revealTarget`).
            s.addAttribute(.foregroundColor, value: Theme.faint, range: marker)
            hide(s, marker, .untilRevealed)
            // Next to the caret the level shows in the margin, once the #s can only make a heading: with their space, or
            // two or more of them, which no tag starts with.
            let hasSpace = marker.length > 0 && [32, 9].contains(text.character(at: marker.upperBound - 1))
            if NotebookSettings.shared.headingMarks == .margin, hasSpace || level > 1 {
                s.addAttribute(.notebookHeading, value: level, range: NSRange(location: marker.location, length: 1))
            }
        case .listItem(let item):
            styleListItem(s, text: text, line: line, item: item, env: env)
        case .quote(let depth, let prefix):
            let indent = CGFloat(depth) * EditorStyle.quoteIndent
            s.addAttributes([
                .paragraphStyle: EditorStyle.paragraph(after: 2, firstIndent: 0, indent: indent),
                .foregroundColor: Theme.textSecondary,
            ], range: full)
            for i in prefix.location..<prefix.upperBound {
                if text.character(at: i) == 62 {
                    s.addAttribute(.notebookObject, value: EditorObject(.quoteBar, range: prefix, at: i), range: NSRange(location: i, length: 1))
                } else {
                    hide(s, NSRange(location: i, length: 1), .always)
                }
            }
        case .thematicBreak:
            s.addAttribute(.notebookObject, value: EditorObject(.horizontalRule, range: line.range, revealable: true), range: NSRange(location: line.range.location, length: 1))
            s.addAttribute(.foregroundColor, value: Theme.faint, range: line.range)
            hide(s, NSRange(location: line.range.location + 1, length: line.range.length - 1), .untilRevealed)
            s.addAttribute(.paragraphStyle, value: EditorStyle.paragraph(before: 4, after: 6), range: full)
        case .footnoteDefinition(let label):
            let font = NSFont.systemFont(ofSize: 13)
            s.addAttributes([.font: font, .foregroundColor: Theme.textSecondary, .paragraphStyle: EditorStyle.paragraph(lineHeight: 20)], range: full)
            s.addAttributes([.foregroundColor: Theme.faint], range: label)
        default:
            break
        }

        // A line that only holds a picture or an embed shows it as a block.
        if line.kind == .paragraph, let only = soleObjectSpan(text, line) {
            styleBlockObject(s, span: only, line: line, env: env)
            return
        }
        styleInline(s, text: text, line: line, env: env)
    }

    // MARK: - Lists

    private static func styleListItem(_ s: NSTextStorage, text: NSString, line: MarkdownLine, item: ListItem, env: StyleEnvironment) {
        let first = CGFloat(item.level) * EditorStyle.listIndent
        let full = line.fullRange
        hide(s, item.indentRange, .always)
        var prefixWidth = EditorStyle.listIndent
        switch item.marker {
        case .bullet:
            if item.checkbox == nil {
                s.addAttribute(.notebookObject, value: EditorObject(.bullet(level: item.level), range: item.prefix, at: item.markerRange.location), range: item.markerRange)
            } else {
                hide(s, item.markerRange, .always)
            }
            hide(s, NSRange(location: item.markerRange.upperBound, length: (item.checkbox?.location ?? item.prefix.upperBound) - item.markerRange.upperBound), .always)
        case .ordered:
            let marker = text.substring(with: NSRange(location: item.markerRange.location, length: item.prefix.upperBound - item.markerRange.location))
            let numberFont = EditorStyle.typography.face == .system ? NSFont.monospacedDigitSystemFont(ofSize: EditorStyle.bodySize, weight: .regular) : EditorStyle.body
            s.addAttributes([.foregroundColor: Theme.textTertiary, .font: numberFont], range: item.markerRange)
            if item.checkbox == nil {
                // The number and the space after it stay text; wrapped lines line up with the text after them.
                let spaces = NSRange(location: item.markerRange.upperBound, length: item.prefix.upperBound - item.markerRange.upperBound)
                if spaces.length > 1 { hide(s, NSRange(location: spaces.location + 1, length: spaces.length - 1), .always) }
                let shown = String(marker.prefix(item.markerRange.length + min(1, spaces.length)))
                prefixWidth = ceil((shown as NSString).size(withAttributes: [.font: numberFont]).width)
            } else {
                hide(s, NSRange(location: item.markerRange.location, length: (item.checkbox?.location ?? item.prefix.upperBound) - item.markerRange.location), .always)
            }
        }
        if let checkbox = item.checkbox {
            s.addAttribute(.notebookObject, value: EditorObject(.checkbox(checked: item.checked), range: item.prefix, at: checkbox.location), range: NSRange(location: checkbox.location, length: 1))
            hide(s, NSRange(location: checkbox.location + 1, length: item.prefix.upperBound - checkbox.location - 1), .always)
            prefixWidth = EditorStyle.checkboxWidth
            if item.checked {
                // Done: greyed out, as in Reminders, without striking it through.
                s.addAttribute(.foregroundColor, value: Theme.textTertiary, range: line.content)
            }
        }
        s.addAttribute(.paragraphStyle, value: EditorStyle.paragraph(after: 3, firstIndent: first, indent: first + prefixWidth), range: full)
        styleInlineSpans(s, text: text, line: line, env: env)
    }

    // MARK: - Blocks

    private static func styleCode(
        _ s: NSTextStorage, text: NSString, doc: MarkdownDocument, line: MarkdownLine, index: Int, block: MarkdownBlock,
        language: String, preview: CGFloat = 0, previewKind: Decoration.Preview? = nil
    ) {
        let full = line.fullRange
        let isFirst = index == block.lines.lowerBound
        let isLast = index == block.lines.upperBound
        let pad = EditorStyle.codePadding
        let style = EditorStyle.paragraph(
            lineHeight: EditorStyle.codeLineHeight,
            before: isFirst ? 8 : 0,
            after: isLast ? 10 + (preview > 0 ? preview + 12 : 0) : 0,
            firstIndent: pad, indent: pad, tail: -pad
        )
        s.addAttributes([
            .font: EditorStyle.mono,
            .foregroundColor: Theme.textBody,
            .paragraphStyle: style,
            .baselineOffset: EditorStyle.baselineOffset(for: EditorStyle.mono, lineHeight: EditorStyle.codeLineHeight),
            // The preview belongs to the box, so the box goes round the closing fence too and the preview hangs below it.
            .notebookDecoration: decoration(for: block, .codeBlock(language: language, active: previewKind != nil || language == "yaml" || language == "tex", preview: previewKind)),
        ], range: full)
        switch line.kind {
        case .fence, .frontmatterDelimiter, .mathDelimiter:
            s.addAttribute(.foregroundColor, value: Theme.faint, range: line.range)
            // Plain code blocks hide their fences until you edit them; the line keeps its height, so nothing moves.
            if case .code = block.kind { hide(s, line.range, .untilRevealed) }
        case .code:
            for (range, token) in highlights(text, doc, block, language) {
                let clipped = NSIntersectionRange(range, line.range)
                guard clipped.length > 0 else { continue }
                s.addAttribute(.foregroundColor, value: CodeHighlighter.color(token), range: clipped)
                if token == .comment {
                    s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: EditorStyle.codeSize, weight: .regular).withItalic, range: clipped)
                }
            }
        default:
            break
        }
    }

    private static func styleTableSource(_ s: NSTextStorage, text: NSString, line: MarkdownLine, index: Int, block: MarkdownBlock) {
        let isFirst = index == block.lines.lowerBound
        let isLast = index == block.lines.upperBound
        let pad = EditorStyle.codePadding
        s.addAttributes([
            .font: EditorStyle.mono,
            .paragraphStyle: EditorStyle.paragraph(lineHeight: 22, before: isFirst ? 8 : 0, after: isLast ? 10 : 0, firstIndent: pad, indent: pad, tail: -pad),
            .baselineOffset: EditorStyle.baselineOffset(for: EditorStyle.mono, lineHeight: 22),
            .notebookDecoration: decoration(for: block, .codeBlock(language: "", active: true)),
        ], range: line.fullRange)
        if line.kind == .tableDelimiter {
            s.addAttribute(.foregroundColor, value: Theme.faint, range: line.range)
            return
        }
        if line.kind == .tableHeader { s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: EditorStyle.codeSize, weight: .semibold), range: line.range) }
        for i in line.range.location..<line.range.upperBound where text.character(at: i) == 124 {
            s.addAttribute(.foregroundColor, value: Theme.faint, range: NSRange(location: i, length: 1))
        }
    }

    /// A block drawn as a whole: the object on its first character, everything else hidden and its other lines
    /// folded away.
    private static func styleSwapped(_ s: NSTextStorage, line: MarkdownLine, index: Int, block: MarkdownBlock, object kind: EditorObject.Kind) {
        if index == block.lines.lowerBound {
            s.addAttribute(.paragraphStyle, value: EditorStyle.objectParagraph(), range: line.fullRange)
            if line.range.length > 0 {
                s.addAttribute(.notebookObject, value: EditorObject(kind, range: block.range), range: NSRange(location: line.range.location, length: 1))
                hide(s, NSRange(location: line.range.location + 1, length: line.range.length - 1), .always)
            }
        } else {
            s.addAttributes([.paragraphStyle: EditorStyle.collapsedParagraph, .font: EditorStyle.tiny], range: line.fullRange)
            hide(s, line.range, .always)
        }
    }

    private static func styleCallout(
        _ s: NSTextStorage, text: NSString, doc: MarkdownDocument, line: MarkdownLine, index: Int, block: MarkdownBlock,
        type: String, env: StyleEnvironment
    ) {
        let isFirst = index == block.lines.lowerBound
        let isLast = index == block.lines.upperBound
        let pad: CGFloat = 16
        s.addAttributes([
            .paragraphStyle: EditorStyle.paragraph(before: isFirst ? 10 : 0, after: isLast ? 14 : 0, firstIndent: pad, indent: pad, tail: -pad),
            .notebookDecoration: decoration(for: block, .callout(type: type)),
        ], range: line.fullRange)
        guard case .quote(_, let prefix) = line.kind else { return }
        hide(s, prefix, .always)
        if isFirst {
            // "[!tip] Title": the type becomes an icon (and its name when there is no title), the title is bold.
            let content = text.substring(with: line.content)
            if let close = content.firstIndex(of: "]") {
                var markerLength = content.distance(from: content.startIndex, to: close) + 1
                if markerLength < content.count, ["+", "-"].contains(content[content.index(content.startIndex, offsetBy: markerLength)]) { markerLength += 1 }
                let rest = content.dropFirst(markerLength)
                let spaces = rest.prefix { $0 == " " }.count
                let title = rest.dropFirst(spaces).trimmingCharacters(in: .whitespaces)
                let marker = NSRange(location: line.content.location, length: markerLength + spaces)
                s.addAttribute(.notebookObject, value: EditorObject(.callout(type: type, label: title.isEmpty ? CalloutStyle.title(type) : nil), range: marker, revealable: true),
                               range: NSRange(location: marker.location, length: 1))
                s.addAttribute(.foregroundColor, value: Theme.faint, range: marker)
                hide(s, NSRange(location: marker.location + 1, length: marker.length - 1), .untilRevealed)
                let titleRange = NSRange(location: marker.upperBound, length: line.range.upperBound - marker.upperBound)
                if titleRange.length > 0 {
                    s.addAttributes([.font: EditorStyle.face(EditorStyle.bodySize, weight: .semibold), .foregroundColor: CalloutStyle.color(type)], range: titleRange)
                }
                return
            }
        }
        styleInlineSpans(s, text: text, line: line, env: env)
    }

    // MARK: - Inline

    private static func soleObjectSpan(_ text: NSString, _ line: MarkdownLine) -> InlineSpan? {
        let objects = line.spans.filter {
            switch $0.kind {
            case .image, .embed: true
            default: false
            }
        }
        guard objects.count == 1, let span = objects.first else { return nil }
        let before = text.substring(with: NSRange(location: line.range.location, length: span.range.location - line.range.location))
        let after = text.substring(with: NSRange(location: span.range.upperBound, length: line.range.upperBound - span.range.upperBound))
        guard before.allSatisfy(\.isWhitespace), after.allSatisfy(\.isWhitespace) else { return nil }
        return span
    }

    private static func styleBlockObject(_ s: NSTextStorage, span: InlineSpan, line: MarkdownLine, env: StyleEnvironment) {
        let kind: EditorObject.Kind
        switch span.kind {
        case .image(let source, _):
            let url = fileURL(source, env: env)
            if let url, !isImageFile(url) {
                kind = .fileCard(url: url, name: url.lastPathComponent)
            } else if let url, DrawingFile.isDrawing(url) {
                kind = .drawing(url: url)
            } else {
                kind = .image(url: url, source: source, inline: false)
            }
        case .embed(let target):
            let url = env.resolve(target)
            if let url, DrawingFile.isDrawing(url) {
                kind = .drawing(url: url)
            } else if let url, isImageFile(url) {
                kind = .image(url: url, source: target, inline: false)
            } else if let url, url.pathExtension.lowercased() != "md" {
                kind = .fileCard(url: url, name: url.lastPathComponent)
            } else if url == nil, isImageName(target) {
                kind = .image(url: nil, source: target, inline: false)
            } else {
                kind = .noteEmbed(target: target, url: url)
            }
        default:
            return
        }
        s.addAttribute(.paragraphStyle, value: EditorStyle.objectParagraph(), range: line.fullRange)
        hide(s, NSRange(location: line.range.location, length: span.range.location - line.range.location), .always)
        s.addAttribute(.notebookObject, value: EditorObject(kind, range: span.range), range: NSRange(location: span.range.location, length: 1))
        hide(s, NSRange(location: span.range.location + 1, length: line.range.upperBound - span.range.location - 1), .always)
        if case .fileCard(let url, _) = kind, let url { s.addAttribute(.notebookLink, value: LinkTarget(.file(url)), range: span.range) }
        if case .noteEmbed(let target, _) = kind { s.addAttribute(.notebookLink, value: LinkTarget(.note(target)), range: span.range) }
    }

    private static func styleInline(_ s: NSTextStorage, text: NSString, line: MarkdownLine, env: StyleEnvironment) {
        styleInlineSpans(s, text: text, line: line, env: env)
    }

    static func styleInlineSpans(_ s: NSTextStorage, text: NSString, line: MarkdownLine, env: StyleEnvironment) {
        for span in line.spans {
            switch span.kind {
            case .strong:
                restyleFont(s, span.content) { EditorStyle.font($0, bold: true) }
                markers(s, span)
            case .emphasis:
                restyleFont(s, span.content) { EditorStyle.font($0, italic: true) }
                markers(s, span)
            case .strikethrough:
                s.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Theme.textTertiary,
                    .foregroundColor: Theme.textTertiary,
                ], range: span.content)
                markers(s, span)
            case .highlight:
                s.addAttribute(.notebookDecoration, value: Decoration(.highlight), range: span.content)
                markers(s, span)
            case .code:
                restyleFont(s, span.range) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.88, weight: EditorStyle.weight(of: $0) > 0.2 ? .semibold : .regular) }
                s.addAttribute(.notebookDecoration, value: Decoration(.inlineCode), range: span.content)
                markers(s, span)
            case .link(let destination):
                // The text reads and edits like text; the address stays behind a pencil after it, as in Lettera.
                s.addAttribute(.foregroundColor, value: Theme.accent, range: span.content)
                #if os(macOS)
                s.addAttribute(.toolTip, value: destination, range: span.content)
                #endif
                s.addAttribute(.notebookLink, value: LinkTarget(linkKind(destination, env: env)), range: span.content)
                if let open = span.markers.first { hide(s, open, .always) }
                if span.markers.count > 1, let close = span.markers.last, close.length > 0 {
                    s.addAttribute(.notebookObject, value: EditorObject(.linkEdit, range: span.range, at: close.location), range: NSRange(location: close.location, length: 1))
                    hide(s, NSRange(location: close.location + 1, length: close.length - 1), .always)
                }
            case .autolink(let url):
                s.addAttributes([
                    .foregroundColor: Theme.accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Theme.accent.withAlphaComponent(0.35),
                ], range: span.content)
                s.addAttribute(.notebookLink, value: LinkTarget(.url(url)), range: span.range)
                markers(s, span)
            case .image(let source, _):
                let url = fileURL(source, env: env)
                s.addAttribute(.notebookObject, value: EditorObject(.image(url: url, source: source, inline: true), range: span.range), range: NSRange(location: span.range.location, length: 1))
                hide(s, NSRange(location: span.range.location + 1, length: span.range.length - 1), .always)
            case .wikiLink(let target, _):
                if let composing = env.composing, span.range.location == composing - 2 {
                    s.addAttribute(.foregroundColor, value: Theme.accent, range: span.content)
                    markers(s, span)
                    continue
                }
                let resolved = env.resolve(target) != nil
                chip(s, span: span, icon: resolved ? .note : .missing, resolved: resolved)
                s.addAttribute(.notebookLink, value: LinkTarget(.note(target)), range: span.range)
            case .embed(let target):
                let resolved = env.resolve(target) != nil
                chip(s, span: span, icon: resolved ? .embed : .missing, resolved: resolved)
                s.addAttribute(.notebookLink, value: LinkTarget(.note(target)), range: span.range)
            case .math(let tex):
                s.addAttribute(.notebookObject, value: EditorObject(.mathInline(tex: tex), range: span.range, revealable: true), range: NSRange(location: span.range.location, length: 1))
                hide(s, NSRange(location: span.range.location + 1, length: span.range.length - 1), .untilRevealed)
                restyleFont(s, span.range) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.88, weight: .regular) }
                s.addAttribute(.foregroundColor, value: Theme.faint, range: span.markers.first ?? span.range)
                if let last = span.markers.last { s.addAttribute(.foregroundColor, value: Theme.faint, range: last) }
            case .footnoteReference:
                s.addAttributes([.foregroundColor: Theme.accent, .font: NSFont.systemFont(ofSize: 11, weight: .medium), .baselineOffset: 9], range: span.content)
                markers(s, span)
            case .escape:
                markers(s, span)
            case .todoMark(let mark):
                guard case .listItem(let item) = line.kind else { continue }
                todoPill(s, text: text, span: span, mark: mark, done: item.checked, line: line)
            }
        }
    }

    /// A to-do's date or place, drawn as a pill in place of its first character. The rest of it, and the spaces in
    /// front of it, are hidden: the pill keeps its own room.
    private static func todoPill(_ s: NSTextStorage, text: NSString, span: InlineSpan, mark: TodoMark.Kind, done: Bool, line: MarkdownLine) {
        let range = span.range
        s.addAttribute(.notebookObject, value: EditorObject(.todoPill(TodoPill(mark, done: done)), range: range), range: NSRange(location: range.location, length: 1))
        hide(s, NSRange(location: range.location + 1, length: range.length - 1), .always)
        var start = range.location
        while start > line.content.location, [32, 9].contains(text.character(at: start - 1)) { start -= 1 }
        hide(s, NSRange(location: start, length: range.location - start), .always)
    }

    /// A link to a note drawn as a chip: an icon in front, the name, a little room after, a tinted box behind.
    private static func chip(_ s: NSTextStorage, span: InlineSpan, icon: EditorObject.ChipIcon, resolved: Bool) {
        let range = span.range
        s.addAttributes([
            .foregroundColor: resolved ? Theme.accent : Theme.textTertiary,
            .notebookDecoration: Decoration(.chip(resolved: resolved)),
        ], range: range)
        restyleFont(s, span.content) { EditorStyle.weight(of: $0) < 0.2 ? EditorStyle.face($0.pointSize, weight: .medium) : $0 }
        let lead = span.markers.first ?? NSRange(location: range.location, length: 0)
        let trail = span.markers.last ?? NSRange(location: range.upperBound, length: 0)
        s.addAttribute(.notebookObject, value: EditorObject(.chipLead(icon: icon), range: range), range: NSRange(location: lead.location, length: 1))
        hide(s, NSRange(location: lead.location + 1, length: span.content.location - lead.location - 1), .always)
        s.addAttribute(.notebookObject, value: EditorObject(.chipTrail, range: range, at: trail.location), range: NSRange(location: trail.location, length: 1))
        hide(s, NSRange(location: trail.location + 1, length: range.upperBound - trail.location - 1), .always)
    }

    private static func markers(_ s: NSTextStorage, _ span: InlineSpan) {
        for marker in span.markers {
            s.addAttribute(.foregroundColor, value: Theme.faint, range: marker)
            hide(s, marker, .untilRevealed)
        }
    }

    // MARK: - Helpers

    static func hide(_ s: NSTextStorage, _ range: NSRange, _ mode: HiddenMode) {
        guard range.length > 0, range.upperBound <= s.length else { return }
        s.addAttribute(.notebookHidden, value: mode.rawValue, range: range)
    }

    private static func restyleFont(_ s: NSTextStorage, _ range: NSRange, _ change: (NSFont) -> NSFont) {
        guard range.length > 0 else { return }
        s.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { s.addAttribute(.font, value: change(font), range: run) }
        }
    }

    static func fileURL(_ source: String, env: StyleEnvironment) -> URL? {
        if let url = URL(string: source), let scheme = url.scheme, scheme.count > 1 {
            return scheme == "file" ? url : nil
        }
        let path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return env.folder?.appendingPathComponent(path).standardizedFileURL
    }

    private static func linkKind(_ destination: String, env: StyleEnvironment) -> LinkTarget.Kind {
        if let url = URL(string: destination), let scheme = url.scheme, scheme.count > 1 { return .url(destination) }
        if destination.hasPrefix("#") { return .url(destination) }
        if let url = fileURL(destination, env: env) { return .file(url) }
        return .url(destination)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg"]

    static func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    static func isImageName(_ name: String) -> Bool { imageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// The code between a block's fences, as it is copied.
    static func blockContent(_ text: NSString, _ doc: MarkdownDocument, _ block: MarkdownBlock) -> String {
        let inner = block.lines.dropFirst().filter { doc.lines[$0].kind == .code }
        return inner.map { text.substring(with: doc.lines[$0].range) }.joined(separator: "\n")
    }

    static func mathSource(_ text: NSString, _ doc: MarkdownDocument, _ block: MarkdownBlock) -> String {
        if block.lines.count == 1 {
            let line = text.substring(with: doc.lines[block.lines.lowerBound].range).trimmingCharacters(in: .whitespaces)
            return String(line.dropFirst(2).dropLast(2))
        }
        return block.lines.filter { doc.lines[$0].kind == .math }.map { text.substring(with: doc.lines[$0].range) }.joined(separator: "\n")
    }

    static func diagramSource(_ text: NSString, _ doc: MarkdownDocument, _ block: MarkdownBlock) -> String {
        blockContent(text, doc, block)
    }

    private static var highlightCache: [String: [(NSRange, CodeHighlighter.Token)]] = [:]

    /// The code block's colours, worked out for the whole block at once (a comment can span lines) and kept until
    /// its text changes.
    private static func highlights(_ text: NSString, _ doc: MarkdownDocument, _ block: MarkdownBlock, _ language: String) -> [(NSRange, CodeHighlighter.Token)] {
        let codeLines = block.lines.filter { doc.lines[$0].kind == .code }
        guard let first = codeLines.first, let last = codeLines.last else { return [] }
        let range = NSRange(location: doc.lines[first].range.location, length: doc.lines[last].range.upperBound - doc.lines[first].range.location)
        let code = text.substring(with: range)
        let key = language + "\u{0}" + code
        if let cached = highlightCache[key] { return cached.map { ($0.0.shifted(by: range.location), $0.1) } }
        let tokens = CodeHighlighter.tokens(in: code, language: language)
        if highlightCache.count > 200 { highlightCache.removeAll() }
        highlightCache[key] = tokens
        return tokens.map { ($0.0.shifted(by: range.location), $0.1) }
    }
}

extension NSFont {
    var withItalic: NSFont {
        #if os(macOS)
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.italic)), size: pointSize) ?? self
        #else
        fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)).map { UIFont(descriptor: $0, size: pointSize) } ?? self
        #endif
    }
}
