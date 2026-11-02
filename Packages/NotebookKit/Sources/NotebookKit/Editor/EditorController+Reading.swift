#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Something VoiceOver reads in a note, as it shows: a line without its Markdown, a to-do with its state, a link, a
/// picture by its name, a row of a table. iPhone and iPad make an accessibility element of each
/// (`NoteAccessibility+UIKit`); what a double-tap on one does is what a tap on it does.
struct ReadingItem: Equatable {
    enum Kind: Equatable {
        case text
        case heading(level: Int)
        case todo(TaskMark)
        /// A link to a note, a file or a web page, or a note shown in the note.
        case link
        case picture
        case drawing
        /// A file shown as a card: a tap opens it.
        case file
        /// A to-do's date or place: a tap changes it.
        case pill
        /// A table's row, a diagram, a formula, the note's properties: a tap opens them for editing.
        case block
        /// After the last line: a double-tap starts writing at the end, which an empty note, or one that ends in a
        /// table or a picture, has no line for.
        case end
    }

    /// Something else it can do, for VoiceOver's actions.
    struct Action: Equatable {
        var name: String
        var hit: EditorController.Hit
    }

    var kind: Kind
    var label: String
    var value: String?
    /// The line it is on.
    var line: Int
    /// The characters it is drawn from; for a picture, a pill or a block, the one character the object is on.
    var range: NSRange
    /// The row of a table, which is drawn as one object.
    var row: Int?
    /// What a double-tap does: what a tap on it does. Nil for text, where it starts writing at `caret`.
    var hit: EditorController.Hit?
    var actions: [Action] = []
    /// Where the caret goes to write in it: the end of its words.
    var caret: Int?
    /// A to-do's words alone, without its date, place, repeat or the date it was done, which a tick adds.
    var name: String?

    /// Whether it is what `other` was, though a to-do may have been ticked, a heading's level changed or a date moved:
    /// only then does VoiceOver's element stay on it, and act. A line written over from another device is something
    /// else, which VoiceOver hasn't read.
    func isStill(_ other: ReadingItem) -> Bool {
        switch (kind, other.kind) {
        case (.todo, .todo): return (name ?? label) == (other.name ?? other.label)
        case (.heading, .heading): return label == other.label
        // A to-do's date or place, changed through it.
        case (.pill, .pill):
            guard case .todo(_, let part)? = hit, case .todo(_, let otherPart)? = other.hit else { return false }
            return part == otherPart
        default: return kind == other.kind && label == other.label
        }
    }
}

extension EditorController {
    /// What VoiceOver reads of the note, in order: each line as it shows, and after a line the links, pictures and dates
    /// in it, which can be acted on; last, where writing goes on at the end.
    func readingItems() -> [ReadingItem] {
        guard !isWaitingForText, storage.length == document.length else { return [] }
        // The text itself, not a copy of it for every line.
        let text = storage.mutableString
        var items = document.lines.indices.flatMap { readingItems(onLine: $0, in: text) }
        if textView.isEditable {
            // Its caret is where `makeRoomAtEnd` makes room.
            items.append(ReadingItem(kind: .end, label: items.isEmpty ? "Write in the note" : "Write at the end", line: document.lines.count,
                                     range: NSRange(location: storage.length, length: 0)))
        }
        return items
    }

    /// The words of a to-do's state, as Reminders says them.
    static func todoState(_ mark: TaskMark) -> String {
        switch mark {
        case .open: "Not completed"
        case .done: "Completed"
        case .cancelled: "Cancelled"
        default: mark.name == TaskMark.open.name ? "Not completed" : mark.name
        }
    }

    private func readingItems(onLine index: Int, in text: NSString) -> [ReadingItem] {
        let line = document.lines[index]
        guard line.range.length > 0, line.range.upperBound <= text.length else { return [] }
        var words = ""
        // The words without a to-do's dates and place, which say which to-do it is.
        var name = ""
        // The shown characters, for where the line is drawn and where writing in it goes on.
        var shown: NSRange?
        var extras: [ReadingItem] = []
        // The link being read, which may take several runs of text (a bold word in it).
        var link: (target: LinkTarget, item: ReadingItem)?

        func endLink() {
            guard let open = link else { return }
            link = nil
            var item = open.item
            item.label = Self.tidy(item.label)
            if !item.label.isEmpty { extras.append(item) }
        }

        storage.enumerateAttributes(in: line.range, options: .longestEffectiveRangeNotRequired) { attributes, run, _ in
            if let object = attributes[.notebookObject] as? EditorObject {
                if let extra = readingItem(for: object, at: run.location, line: index, words: &words, name: &name) {
                    endLink()
                    extras += extra
                }
                return
            }
            guard attributes[.notebookHidden] == nil else { return }
            let piece = text.substring(with: run)
            words += piece
            name += piece
            shown = shown.map { NSUnionRange($0, run) } ?? run
            if let target = attributes[.notebookLink] as? LinkTarget {
                if link?.target !== target {
                    endLink()
                    var item = ReadingItem(kind: .link, label: "", line: index, range: run, hit: .link(target.kind))
                    // A link written as [words](address) changes where it goes with the pencil after it.
                    if let span = line.spans.first(where: { NSLocationInRange(run.location, $0.content) }), case .link = span.kind {
                        item.actions = [.init(name: "Edit Link", hit: .editLink(range: span.range))]
                    }
                    link = (target, item)
                }
                link?.item.label += piece
                if let range = link?.item.range { link?.item.range = NSUnionRange(range, run) }
            } else {
                endLink()
            }
        }
        endLink()

        let label = Self.tidy(words)
        var main: ReadingItem?
        switch line.kind {
        case .heading(let level, _):
            if !label.isEmpty { main = ReadingItem(kind: .heading(level: level), label: label, line: index, range: shown ?? line.range) }
        case .listItem(let item) where item.isTask:
            let start = item.checkbox?.location ?? line.range.location
            let end = max(start + 1, shown?.upperBound ?? 0)
            var todo = ReadingItem(kind: .todo(item.mark), label: label.isEmpty ? "To-do" : label, value: Self.todoState(item.mark), line: index,
                                   range: NSRange(location: start, length: end - start), hit: .checkbox(line: index), caret: todoWordsEnd(line, in: text))
            todo.name = Self.tidy(name)
            if NotebookSettings.shared.showsTodos { todo.actions = [.init(name: "Remind Me", hit: .todo(line: index, part: .reminder))] }
            main = todo
        default:
            guard !label.isEmpty else { break }
            // A line that is only a link is the link.
            if extras.count == 1, let only = extras.first, only.kind == .link, only.label == label { return extras }
            main = ReadingItem(kind: .text, label: label, line: index, range: shown ?? line.range)
        }
        if let kind = main?.kind, kind == .text || kind.isHeading { main?.caret = shown?.upperBound }
        return (main.map { [$0] } ?? []) + extras
    }

    /// What VoiceOver reads for an object drawn in place of Markdown: nothing for what only shows the line's kind (a
    /// bullet, a checkbox, a quote's bar), words that go into the line for a formula or a callout's type, an item of
    /// its own for what can be tapped.
    private func readingItem(for object: EditorObject, at index: Int, line: Int, words: inout String, name: inout String) -> [ReadingItem]? {
        let range = NSRange(location: index, length: 1)
        let source = object.range(at: index)
        switch object.kind {
        case .bullet, .checkbox, .quoteBar, .chipLead, .chipTrail, .linkEdit, .horizontalRule:
            return nil
        case .mathInline(let tex):
            words += " \(tex) "
            name += " \(tex) "
            return nil
        case .callout(let type, let label):
            // An icon for its type, and its name when it has no title.
            words += label ?? "\(CalloutStyle.title(type)): "
            name += label ?? "\(CalloutStyle.title(type)): "
            return nil
        case .todoPill(let pill):
            // In words, as the To-dos list says them: a place whole, where the pill shortens a long name.
            var label = pill.label
            if let span = document.lines[safe: line]?.spans.first(where: { $0.range == source }), case .todoMark(let mark) = span.kind {
                switch mark {
                case .due: label = pill.tone == .overdue ? "Overdue, \(pill.label)" : pill.label
                case .place(let place): label = place.leaving ? "Leaving " + place.name : "Arriving at " + place.name
                case .field(let field): label = field.kind == .repeats ? "Repeats " + pill.label : pill.label
                }
            }
            guard NotebookSettings.shared.showsTodos, !pill.isField else {
                words += ", \(label) "
                return nil
            }
            return [ReadingItem(kind: .pill, label: label, line: line, range: range, hit: .todo(line: line, part: pill.isPlace ? .place : .date))]
        case .image(let url, let path, _):
            return [ReadingItem(kind: .picture, label: pictureName(at: source, line: line, url: url, path: path), line: line, range: range, hit: .picture(range: source, url: url))]
        case .drawing(let url):
            let alt = altText(at: source, line: line)
            return [ReadingItem(kind: .drawing, label: alt.isEmpty ? "Drawing" : alt, line: line, range: range, hit: .picture(range: source, url: url))]
        case .fileCard(let url, let name):
            return [ReadingItem(kind: .file, label: name, line: line, range: range, hit: .picture(range: source, url: url))]
        case .noteEmbed(let target, _):
            return [ReadingItem(kind: .link, label: target, line: line, range: range, hit: .link(.note(target)))]
        case .table(let model):
            guard let block = document.lines[safe: line]?.block else { return nil }
            let header = model.rows.first?.map { Self.tidy($0.string) } ?? []
            return model.rows.enumerated().map { row, cells in
                let words = cells.map { Self.tidy($0.string) }
                let label = row == 0
                    ? words.joined(separator: ", ")
                    : zip(header + Array(repeating: "", count: max(0, words.count - header.count)), words)
                        .map { $0.isEmpty ? $1 : "\($0): \($1)" }.joined(separator: ", ")
                let caret = model.cellRanges[safe: row]?.first?.upperBound ?? document.blocks[block].range.location
                return ReadingItem(kind: .block, label: label, value: row == 0 ? "Table, \(model.rows.count) rows" : nil, line: line, range: range, row: row,
                                   hit: .block(index: block, caret: caret))
            }
        case .mermaid:
            return blockItem("Diagram", value: nil, at: range, line: line)
        case .mathBlock(let tex):
            return blockItem("Formula", value: tex, at: range, line: line)
        case .frontmatter(let count):
            return blockItem("Properties", value: layoutManager.frontmatterLabel(count), at: range, line: line)
        }
    }

    /// Where a to-do's words end, before its date and place: `todoWordsEnd(line:)` on the text read once.
    private func todoWordsEnd(_ line: MarkdownLine, in text: NSString) -> Int {
        guard let first = line.spans.first(where: { if case .todoMark = $0.kind { true } else { false } }) else { return line.range.upperBound }
        var end = first.range.location
        while end > line.content.location, [32, 9].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// A diagram, a formula or the properties: a tap opens them where their Markdown starts, as a click does.
    private func blockItem(_ label: String, value: String?, at range: NSRange, line: Int) -> [ReadingItem]? {
        guard let blockIndex = document.lines[safe: line]?.block else { return nil }
        let block = document.blocks[blockIndex]
        let first = block.lines.count > 1 ? document.lines[block.lines.lowerBound + 1] : document.lines[block.lines.lowerBound]
        return [ReadingItem(kind: .block, label: label, value: value, line: line, range: range, hit: .block(index: blockIndex, caret: first.range.upperBound))]
    }

    /// What a picture's Markdown says it shows, else its file's name, else "Picture".
    private func pictureName(at source: NSRange, line: Int, url: URL?, path: String) -> String {
        let alt = altText(at: source, line: line)
        if !alt.isEmpty { return alt }
        let file = url?.lastPathComponent ?? (path.removingPercentEncoding ?? path)
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? "Picture" : name
    }

    private func altText(at source: NSRange, line: Int) -> String {
        guard let span = document.lines[safe: line]?.spans.first(where: { $0.range == source }), case .image(_, let alt) = span.kind else { return "" }
        return Self.tidy(alt)
    }

    /// Words with the room hidden marks and pills leave between them taken out.
    private static func tidy(_ words: String) -> String {
        words.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
    }

    /// Makes room to write after everything in the note, as "Write at the end" does, and gives where the caret goes: a
    /// line of its own after a last line with anything on it (a table's last row, a code block's closing fence, a
    /// to-do's hidden date), and a blank line under a table, which other apps would take the next line into.
    @discardableResult
    func makeRoomAtEnd() -> Int {
        let text = nsText
        func isBlank(_ line: MarkdownLine) -> Bool { text.substring(with: line.range).allSatisfy(\.isWhitespace) }
        var addition = ""
        if let last = document.lines.last, !isBlank(last) { addition = "\n" }
        if let row = document.lines.lastIndex(where: { !isBlank($0) }), [.tableHeader, .tableDelimiter, .tableRow].contains(document.lines[row].kind),
           document.lines.count - 1 - row + addition.count < 2 {
            addition += "\n"
        }
        if !addition.isEmpty { replace(NSRange(location: storage.length, length: 0), with: addition, actionName: "Typing") }
        return storage.length
    }

    /// Where an item is drawn, in the text view's coordinates.
    func readingFrame(of item: ReadingItem) -> CGRect? {
        let origin = textOrigin
        if item.kind == .end {
            // The empty line after a last line break, or the room under the last line: as wide as the text and tall
            // enough for a fingertip.
            if storage.length == 0 {
                layoutManager.ensureLayout(for: container)
            } else {
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: storage.length - 1, length: 1))
            }
            let top = layoutManager.extraLineFragmentTextContainer != nil ? layoutManager.extraLineFragmentRect.minY : layoutManager.usedRect(for: container).maxY
            return CGRect(x: origin.x, y: origin.y + top, width: container.size.width, height: 44)
        }
        guard item.range.upperBound <= storage.length, item.range.length > 0 else { return nil }
        // A picture, a pill, a block, or an empty to-do's circle: the object's box.
        if item.range.length == 1, let object = layoutManager.object(at: item.range.location) {
            guard let rect = object.isBlock && item.row == nil ? layoutManager.blockObjectRect(at: item.range.location, origin: origin)
                    : layoutManager.rect(forObjectAt: item.range.location, origin: origin) else { return nil }
            if let row = item.row, case .table(let model) = object.kind { return model.rowRect(row, in: rect) }
            if item.kind == .pill { return CGRect(x: rect.minX + TodoPill.gap, y: rect.minY, width: max(1, rect.width - TodoPill.gap), height: rect.height) }
            return rect
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
    }
}

/// Where the lines of a text went in one edit of it, so that what VoiceOver is on stays with its line: a line above the
/// edit stays, one below it moves by the lines the edit added or took away, one it changed only within stays too (the
/// edited range `didProcessEditing` has takes in the whole line, its line break too), and of the lines it went through
/// those that came out the same are found again: another device's to-do above one that starts the same, `- [ ] `,
/// cuts into that one. So is a to-do ticked from another device, which comes with the day it was done and its next one
/// above it. Any other line is gone.
struct LineMoves {
    private let old: MarkdownDocument
    private let new: MarkdownDocument
    private let text: NSString
    private let edited: NSRange
    private let removed: NSString
    private var delta: Int { edited.length - removed.length }
    /// The lines the edit went through that came out the same, old to new.
    private var found: [Int: Int] = [:]

    /// `text` is the new text, `edited` the range in it the edit wrote, and `removed` what was there before, as
    /// `didProcessEditing` has them.
    init(from old: MarkdownDocument, to new: MarkdownDocument, in text: NSString, edited: NSRange, removed: String) {
        self.old = old
        self.new = new
        self.text = text
        self.edited = edited
        self.removed = removed as NSString
        guard !old.lines.isEmpty, !new.lines.isEmpty else { return }
        let gone = (old.lineIndex(containing: edited.location)...old.lineIndex(containing: edited.upperBound - delta)).filter { kept($0) == nil }
        var came = (new.lineIndex(containing: edited.location)...new.lineIndex(containing: edited.upperBound)).filter { !isKept(new: $0) }
        guard !gone.isEmpty, !came.isEmpty else { return }
        // In order: the first of the same words for the first line that had them.
        var lines: [Int: [Int]] = [:]
        for line in came.reversed() { lines[new.lines[line].textHash, default: []].append(line) }
        var next = 0
        for line in gone {
            let hash = old.lines[line].textHash
            while let first = lines[hash]?.last, first < next { lines[hash]?.removeLast() }
            guard let match = lines[hash]?.popLast(), new.lines[match].range.length == old.lines[line].range.length else { continue }
            found[line] = match
            next = match + 1
        }
        // To-dos that read the same whatever their tick: ticked, one keeps its day and gets the day it was done, and
        // its next one, above it, has the next day.
        came.removeAll { found.values.contains($0) }
        var unticked = came.map { Self.untickedText(of: new.lines[$0]) { text.substring(with: $0) } }
        for line in gone where found[line] == nil {
            guard let words = Self.untickedText(of: old.lines[line], in: oldText), let index = unticked.firstIndex(of: words) else { continue }
            found[line] = came[index]
            unticked[index] = nil
        }
    }

    /// Where a line of the old text is in the new one; nil when the edit made it into others.
    func callAsFunction(_ line: Int) -> Int? { kept(line) ?? found[line] }

    private var lineDelta: Int { new.lines.count - old.lines.count }

    /// The line the same, moved, or changed only within it.
    private func kept(_ index: Int) -> Int? {
        guard let line = old.lines[safe: index] else { return nil }
        let oldEnd = edited.upperBound - delta
        if line.fullRange.upperBound <= edited.location { return index }
        // Wholly after the edit, and a line of its own there still.
        if line.range.location >= oldEnd, new.lines[safe: index + lineDelta]?.range.location == line.range.location + delta { return index + lineDelta }
        // A to-do ticked, a word put right.
        if lineDelta == 0, edited.location >= line.range.location, oldEnd <= line.fullRange.upperBound { return index }
        return nil
    }

    /// Whether a line of the new text is one `kept` gives.
    private func isKept(new index: Int) -> Bool {
        let line = new.lines[index]
        if line.fullRange.upperBound <= edited.location { return true }
        if line.range.location >= edited.upperBound, old.lines[safe: index - lineDelta]?.range.location == line.range.location - delta { return true }
        return lineDelta == 0 && edited.location >= line.range.location && edited.upperBound <= line.fullRange.upperBound
    }

    /// Characters of the old text: the new one's before and after the edit, what it took out in between.
    private func oldText(_ range: NSRange) -> String {
        let oldEnd = edited.location + removed.length
        var result = ""
        if range.location < min(range.upperBound, edited.location) {
            result += text.substring(with: NSRange(location: range.location, length: min(range.upperBound, edited.location) - range.location))
        }
        let inside = (start: max(range.location, edited.location), end: min(range.upperBound, oldEnd))
        if inside.start < inside.end { result += removed.substring(with: NSRange(location: inside.start - edited.location, length: inside.end - inside.start)) }
        let after = max(range.location, oldEnd)
        if after < range.upperBound { result += text.substring(with: NSRange(location: after + delta, length: range.upperBound - after)) }
        return result
    }

    /// A to-do's line without what a tick changes in it: its mark, and the day it was done or cancelled.
    private static func untickedText(of line: MarkdownLine, in text: (NSRange) -> String) -> String? {
        guard case .listItem(let item) = line.kind, item.isTask, let box = item.checkbox else { return nil }
        var cuts = [NSRange(location: box.location + 1, length: 1)]
        for span in line.spans {
            if case .todoMark(.field(let field)) = span.kind, field.kind == .done || field.kind == .cancelled { cuts.append(span.range) }
        }
        let words = NSMutableString(string: text(line.range))
        for cut in cuts.sorted(by: { $0.location > $1.location }) {
            let local = cut.shifted(by: -line.range.location)
            guard local.location >= 0, local.upperBound <= words.length else { return nil }
            words.replaceCharacters(in: local, with: "")
        }
        return words.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private extension ReadingItem.Kind {
    var isHeading: Bool { if case .heading = self { true } else { false } }
}
