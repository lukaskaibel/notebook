import Foundation

/// Reads AsciiDoc the way a note uses it, into the same lines and blocks as `MarkdownParser`, so the editor draws and
/// types an `.adoc` note as it does a Markdown one: section titles, lists and checklists, description lists,
/// admonitions, listing, literal and source blocks, tables, examples, sidebars and quotes, block images and includes,
/// the header's attributes. It reads line by line, so every character keeps its place; markup it understands (a
/// block's attributes, its delimiters) is marked as such and folds away until the caret comes to it. It does not try
/// to be Asciidoctor: no conditionals, and includes show as the file they include.
enum AsciiDocParser {
    static func parse(units u: [UInt16], typing: Bool = false) -> MarkdownDocument {
        var reader = Reader(u: u, typing: typing)
        reader.read()
        return reader.document()
    }

    /// The attribute entries of a note, `:name: value`, as they stand at its end. Values are taken as written.
    static func attributes(in u: [UInt16], lines: [MarkdownLine]) -> [String: String] {
        var attributes: [String: String] = [:]
        for line in lines where line.kind == .frontmatter {
            guard let entry = attributeEntry(MarkdownParser.lineText(u, line.range)) else { continue }
            attributes[entry.name] = entry.value
        }
        return attributes
    }

    /// `:name: value`, `:name!:` or `:!name:`, with the value it sets (empty for none, nil where it unsets).
    static func attributeEntry(_ text: String) -> (name: String, value: String?)? {
        guard text.hasPrefix(":"), text.count > 2 else { return nil }
        let body = text.dropFirst()
        guard let close = body.firstIndex(of: ":") else { return nil }
        var name = body[..<close]
        let unset = name.hasPrefix("!") || name.hasSuffix("!")
        name = name.drop { $0 == "!" }
        if name.hasSuffix("!") { name = name.dropLast() }
        guard let first = name.first, first.isLetter || first.isNumber || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let rest = body[body.index(after: close)...]
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (name.lowercased(), unset ? nil : rest.trimmingCharacters(in: .whitespaces))
    }

    /// The five admonitions, as they start a paragraph or name a block.
    static let admonitions = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    // MARK: - Reading

    struct Reader {
        let u: [UInt16]
        let typing: Bool
        var lines: [MarkdownLine]
        /// The blocks read: in the order they were closed, and from the line reading started at.
        var blocks: [MarkdownBlock] = []
        var index = 0
        /// Lines of block attributes (`[source,python]`, `[[id]]`) read but not yet given to the block under them.
        var pending: [Int] = []
        /// Examples, sidebars, quotes and admonitions open around the line being read, innermost last.
        var containers: [Container] = []
        var list = ListState()
        /// The list item or term that a line of text right under it goes on with.
        var item: Int?
        /// A `+` came: the next block belongs to the item above, even after it.
        var attached = false
        var afterBlank = true
        /// The line of the note's title, `= Title`, if it has one.
        var title: Int?
        /// No line further down can be the note's title any more: there is one, or a block or text came first.
        var titleClosed = false
        /// The lines up to here are known to leave the title open.
        var titleChecked = 0
        /// The lines reading could start again at, as they were read.
        var resumePoints: [ResumePoint] = []

        struct Container {
            var delimiter: String
            var kind: MarkdownBlock.Kind?
            var first: Int
        }

        /// The markers of the list being read, outermost first (AsciiDoc nests a list by a marker it hasn't used yet),
        /// and how many items each level has counted.
        struct ListState {
            var markers: [String] = []
            var counts: [Int] = []

            mutating func reset() {
                markers = []
                counts = []
            }
        }

        init(u: [UInt16], typing: Bool) {
            self.u = u
            self.typing = typing
            lines = MarkdownParser.splitLines(u)
        }

        /// Reading again from a line where it could start again (or from the start), the lines from there on not read
        /// yet.
        init(u: [UInt16], typing: Bool, lines: [MarkdownLine], from point: ResumePoint?) {
            self.u = u
            self.typing = typing
            self.lines = lines
            guard let point else { return }
            index = point.line
            titleClosed = true
            if case .asciidoc(let afterBlank, let markers, let counts) = point.state {
                self.afterBlank = afterBlank
                list = ListState(markers: markers, counts: counts)
            }
        }

        func text(_ line: Int) -> String { MarkdownParser.lineText(u, lines[line].range) }

        func trimmed(_ line: Int) -> String { text(line).trimmingCharacters(in: .whitespaces) }

        func isBlank(_ line: Int) -> Bool { lines[line].kind == .blank }

        /// Reads to the end of the note, or to the start of a line where `stop` says what follows is known, and tells
        /// whether it stopped there. Reading can start again only where nothing is open: no container, no list item
        /// that a line could go on with, no attributes waiting for their block, and the title settled.
        @discardableResult
        mutating func read(stop: (Int, ParserState) -> Bool = { _, _ in false }) -> Bool {
            while index < lines.count {
                if !titleClosed {
                    titleClosed = title != nil || !blocks.isEmpty
                        || !(titleChecked..<index).allSatisfy { isBlank($0) || lines[$0].kind == .comment || lines[$0].kind == .markup }
                    titleChecked = index
                }
                if titleClosed, containers.isEmpty, pending.isEmpty, item == nil, !attached {
                    let state = ParserState.asciidoc(afterBlank: afterBlank, markers: list.markers, counts: list.counts)
                    if stop(index, state) { return true }
                    resumePoints.append(ResumePoint(line: index, state: state))
                }
                readLine()
            }
            while let container = containers.popLast() {
                close(container, last: lines.count - 1)
            }
            flushPending()
            return false
        }

        func document() -> MarkdownDocument {
            var lines = self.lines
            let blocks = Self.ordered(self.blocks, lines: &lines, in: lines.indices)
            MarkdownParser.fingerprint(&lines, u)
            let attributes = AsciiDocParser.attributes(in: u, lines: lines)
            AsciiDocParser.readSpans(&lines, u, in: lines.indices, attributes: attributes, typing: typing)
            return MarkdownDocument(lines: lines, blocks: blocks, length: u.count, syntax: .asciidoc, typing: typing,
                                    resumePoints: resumePoints, attributes: attributes)
        }

        /// Blocks in the order they start (a container closes after the blocks in it), the lines pointing at theirs,
        /// which come after `offset` others.
        static func ordered(_ blocks: [MarkdownBlock], lines: inout [MarkdownLine], in range: Range<Int>, offset: Int = 0) -> [MarkdownBlock] {
            let order = blocks.indices.sorted { (blocks[$0].lines.lowerBound, -blocks[$0].lines.count) < (blocks[$1].lines.lowerBound, -blocks[$1].lines.count) }
            var position = [Int](repeating: 0, count: blocks.count)
            for (new, old) in order.enumerated() { position[old] = new }
            for line in range {
                if let block = lines[line].block { lines[line].block = position[block] + offset }
            }
            return order.map { blocks[$0] }
        }

        // MARK: Lines

        mutating func readLine() {
            let line = index
            let range = lines[line].range
            if isBlank(line) {
                flushPending()
                if !attached { item = nil }
                afterBlank = true
                index += 1
                return
            }
            defer { afterBlank = false }
            let text = self.text(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let indent = MarkdownParser.leadingIndent(u, range)

            // Comments: a `////` block, or a line of its own.
            if indent.units == 0, trimmed.count >= 4, trimmed.allSatisfy({ $0 == "/" }) {
                let close = ((line + 1)..<lines.count).first { trimmed == self.trimmed($0) } ?? lines.count - 1
                for comment in line...close { lines[comment].kind = .comment }
                index = close + 1
                return
            }
            if indent.units == 0, text.hasPrefix("//"), !text.hasPrefix("///") {
                lines[line].kind = .comment
                index += 1
                return
            }

            if indent.units == 0, let delimiter = Delimiter(trimmed, typing: typing) {
                readDelimited(delimiter, at: line)
                return
            }

            // A block's attributes and anchors, kept for the block under them.
            if indent.units == 0, Self.isAttributeLine(trimmed) {
                lines[line].kind = .markup
                pending.append(line)
                index += 1
                return
            }
            if indent.units == 0, Self.isBlockTitle(text) {
                lines[line].kind = .blockTitle(marker: NSRange(location: range.location, length: 1))
                lines[line].content = NSRange(location: range.location + 1, length: range.length - 1)
                pending.append(line)
                index += 1
                return
            }

            if indent.units == 0, ["'''", "<<<", "---", "***", "- - -", "* * *"].contains(trimmed) {
                flushPending()
                endList()
                lines[line].kind = .thematicBreak
                index += 1
                return
            }

            if indent.units == 0, let marker = sectionMarker(line) {
                flushPending()
                endList()
                let level = marker.level
                lines[line].kind = .heading(level: level, marker: marker.range)
                lines[line].content = NSRange(location: marker.range.upperBound, length: range.upperBound - marker.range.upperBound)
                index += 1
                if level == 1, !titleClosed, title == nil, blocks.isEmpty, (0..<line).allSatisfy({ isBlank($0) || lines[$0].kind == .comment || lines[$0].kind == .markup }) {
                    title = line
                    readHeader()
                }
                return
            }

            if indent.units == 0, AsciiDocParser.attributeEntry(text) != nil {
                flushPending()
                var last = line
                while last + 1 < lines.count, AsciiDocParser.attributeEntry(self.text(last + 1)) != nil { last += 1 }
                for entry in line...last { lines[entry].kind = .frontmatter }
                addBlock(.frontmatter, from: line, to: last)
                index = last + 1
                return
            }

            if trimmed == "+", item != nil {
                lines[line].kind = .markup
                attached = true
                index += 1
                return
            }

            if indent.units == 0, let admonition = Self.admonitionMarker(text) {
                readParagraph(at: line, as: .callout(type: admonition.type), marker: NSRange(location: range.location, length: admonition.length))
                return
            }

            if let found = listItem(at: line, indent: indent) {
                flushPending()
                lines[line].kind = .listItem(found)
                lines[line].content = NSRange(location: found.prefix.upperBound, length: range.upperBound - found.prefix.upperBound)
                item = line
                attached = false
                index += 1
                return
            }

            if let definition = definition(at: line, indent: indent) {
                flushPending()
                lines[line].kind = .definition(term: definition.term, marker: definition.marker)
                lines[line].content = NSRange(location: range.location + indent.units, length: range.length - indent.units)
                item = line
                attached = false
                index += 1
                return
            }

            if indent.units == 0, trimmed.hasPrefix("toc::") {
                lines[line].kind = .markup
                pending.append(line)
                flushPending()
                index += 1
                return
            }

            // Quotes as Markdown writes them, which Asciidoctor reads too.
            if indent.columns <= 3, MarkdownParser.quotePrefix(u, range) != nil {
                flushPending()
                var last = line
                while last < lines.count, let prefix = MarkdownParser.quotePrefix(u, lines[last].range) {
                    lines[last].kind = .quote(depth: prefix.depth, prefix: prefix.range)
                    lines[last].content = NSRange(location: prefix.range.upperBound, length: lines[last].range.upperBound - prefix.range.upperBound)
                    last += 1
                }
                addBlock(.quote, from: line, to: last - 1)
                index = last
                return
            }

            // Text that goes on with the list item or term above it.
            if let owner = item, !afterBlank || attached {
                flushPending()
                lines[line].kind = .continuation(item: owner, indent: NSRange(location: range.location, length: indent.units))
                lines[line].content = NSRange(location: range.location + indent.units, length: range.length - indent.units)
                attached = false
                index += 1
                return
            }

            // An indented paragraph is literal, as is one whose attributes say so.
            let style = pendingStyle
            if indent.columns > 0 || ["source", "listing", "literal"].contains(style ?? "") {
                readParagraph(at: line, as: .code(language: style == "source" ? language(of: pendingAttributes) : ""))
                return
            }
            if let style, AsciiDocParser.admonitions.contains(style.uppercased()) {
                readParagraph(at: line, as: .callout(type: style.lowercased()))
                return
            }
            if style == "quote" || style == "verse" {
                readParagraph(at: line, as: .callout(type: "quote"))
                return
            }

            if afterBlank { endList() }
            flushPending()
            lines[line].kind = .paragraph
            index += 1
        }

        /// The lines under the title up to the first blank line: an author, a revision and attribute entries.
        mutating func readHeader() {
            var last = index - 1
            var line = index
            while line < lines.count, !isBlank(line) {
                let text = self.text(line)
                if AsciiDocParser.attributeEntry(text) != nil || (line - index < 2 && !text.hasPrefix(":") && !text.hasPrefix("//") && Delimiter(text, typing: typing) == nil && !Self.isAttributeLine(text)) {
                    lines[line].kind = .frontmatter
                } else if text.hasPrefix("//") {
                    lines[line].kind = .comment
                } else {
                    break
                }
                last = line
                line += 1
            }
            guard last >= index else { return }
            addBlock(.frontmatter, from: index, to: last)
            index = last + 1
        }

        /// A paragraph that is a block of its own: an admonition (`NOTE: `, `[NOTE]`), a literal or source paragraph, a
        /// quote. It runs to the next blank line.
        mutating func readParagraph(at line: Int, as kind: MarkdownBlock.Kind, marker: NSRange? = nil) {
            // A titled admonition or quote keeps its title in its box; code shows it above.
            let first = takePending(above: line, titles: !isCode(kind))
            var last = line
            while last + 1 < lines.count, !isBlank(last + 1), !startsBlock(last + 1) { last += 1 }
            for paragraph in line...last {
                if isCode(kind) {
                    lines[paragraph].kind = .code
                } else {
                    lines[paragraph].kind = .paragraph
                    lines[paragraph].content = lines[paragraph].range
                }
            }
            if let marker {
                lines[line].kind = .admonition(marker: marker)
                lines[line].content = NSRange(location: marker.upperBound, length: lines[line].range.upperBound - marker.upperBound)
            }
            addBlock(kind, from: first, to: last, opens: first < line)
            endList()
            index = last + 1
        }

        func isCode(_ kind: MarkdownBlock.Kind) -> Bool {
            if case .code = kind { true } else { false }
        }

        /// Whether a line ends the paragraph above it.
        func startsBlock(_ line: Int) -> Bool {
            let text = self.text(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if Delimiter(trimmed, typing: typing) != nil || Self.isAttributeLine(trimmed) || text.hasPrefix("//") { return true }
            if sectionMarker(line) != nil { return true }
            var state = list
            return listItem(at: line, indent: MarkdownParser.leadingIndent(u, lines[line].range), state: &state) != nil
        }

        // MARK: Blocks

        mutating func readDelimited(_ delimiter: Delimiter, at line: Int) {
            if delimiter.isContainer {
                // The delimiter of a block that is open closes it, and any opened inside it and left open.
                if let open = containers.lastIndex(where: { $0.delimiter == delimiter.text }) {
                    lines[line].kind = .markup
                    while containers.count > open {
                        let container = containers.removeLast()
                        close(container, last: line)
                    }
                    flushPending()
                    endList()
                    item = nil
                    index = line + 1
                    return
                }
                lines[line].kind = .markup
                let attributes = pendingAttributes
                let style = attributes.first.flatMap { Self.style(of: $0) }
                var kind: MarkdownBlock.Kind?
                if let style, AsciiDocParser.admonitions.contains(style.uppercased()) {
                    kind = .callout(type: style.lowercased())
                } else if style == "quote" || style == "verse" {
                    kind = .callout(type: "quote")
                } else {
                    switch delimiter.kind {
                    case .example: kind = .callout(type: "example")
                    case .sidebar: kind = .callout(type: "sidebar")
                    case .quote: kind = .callout(type: "quote")
                    default: kind = nil
                    }
                }
                let first = kind == nil ? line : takePending(above: line, titles: true)
                if kind == nil { flushPending() }
                containers.append(Container(delimiter: delimiter.text, kind: kind, first: first))
                endList()
                if !attached { item = nil }
                attached = false
                index = line + 1
                return
            }

            let close = ((line + 1)..<lines.count).first { trimmed($0) == delimiter.text }
            let last = close ?? lines.count - 1
            let attributes = pendingAttributes
            if case .table(let separator) = delimiter.kind {
                readTable(from: line, to: last, closed: close != nil, separator: separator, attributes: attributes)
                return
            }
            lines[line].kind = .fence
            if line < last {
                for inner in (line + 1)...last { lines[inner].kind = .code }
            }
            if let close { lines[close].kind = .fence }
            var language: String
            switch delimiter.kind {
            case .fenced(let info): language = info
            case .listing: language = self.language(of: attributes)
            case .passthrough: language = "html"
            default: language = ""
            }
            if let style = attributes.first.flatMap({ Self.style(of: $0) }), !["source", "listing", "literal", "subs"].contains(style) {
                // A diagram: `[plantuml]`, `[mermaid]`, `[graphviz]`.
                language = style
            }
            let first = takePending(above: line, titles: false)
            addBlock(language == "mermaid" ? .mermaid : .code(language: language), from: first, to: last, opens: first < line)
            if !attached { endList() }
            attached = false
            index = last + 1
        }

        mutating func readTable(from line: Int, to last: Int, closed: Bool, separator: UInt16, attributes: [String]) {
            lines[line].kind = .tableDelimiter
            if closed { lines[last].kind = .tableDelimiter }
            let inner = closed ? line + 1..<last : line + 1..<last + 1
            for row in inner where !isBlank(row) { lines[row].kind = .tableRow }
            let spec = AsciiDocTable.Spec(attributes: attributes)
            let rows = AsciiDocTable.rows(u, lines: lines, inner: inner, separator: separator, columns: spec.columns)
            // The first row is the header when the attributes say so, or when it is one line with a blank line under it.
            var header = spec.header
            if header == nil, let firstRow = rows.first, let firstLine = firstRow.lines.first, firstRow.lines.count == 1,
               firstLine + 1 < lines.count, inner.contains(firstLine + 1), isBlank(firstLine + 1) {
                header = true
            }
            if header == true, let firstRow = rows.first {
                for row in firstRow.lines where lines[row].kind == .tableRow { lines[row].kind = .tableHeader }
            }
            let columns = spec.columns ?? rows.first?.cells.count ?? 1
            var alignments = spec.alignments
            if alignments.count < columns { alignments += Array(repeating: .leading, count: columns - alignments.count) }
            let first = takePending(above: line, titles: false)
            addBlock(.table(alignments: Array(alignments.prefix(max(1, columns)))), from: first, to: last, opens: true)
            if !attached { endList() }
            attached = false
            index = last + 1
        }

        /// Closes a container: its lines that are in no other block are its own.
        mutating func close(_ container: Container, last: Int) {
            guard let kind = container.kind else {
                // An open block (`--`) only holds the blocks in it: its delimiters fold away on their own.
                addBlock(.markup, from: container.first, to: container.first)
                if lines[last].kind == .markup, last != container.first { addBlock(.markup, from: last, to: last) }
                return
            }
            addBlock(kind, from: container.first, to: last, opens: true, claimingFreeLines: true)
        }

        mutating func addBlock(_ kind: MarkdownBlock.Kind, from first: Int, to last: Int, opens: Bool = false, claimingFreeLines: Bool = false) {
            let start = lines[first].range.location
            let end = lines[last].range.upperBound
            var block = MarkdownBlock(kind: kind, lines: first...last, range: NSRange(location: start, length: end - start))
            block.opens = opens
            blocks.append(block)
            for line in first...last where !claimingFreeLines || lines[line].block == nil {
                lines[line].block = blocks.count - 1
            }
        }

        // MARK: Pending attributes

        /// The attribute lines waiting for a block, without their brackets.
        var pendingAttributes: [String] {
            pending.filter { lines[$0].kind == .markup }.reversed().compactMap { line in
                let trimmed = self.trimmed(line)
                guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), trimmed.hasSuffix("]") else { return nil }
                return String(trimmed.dropFirst().dropLast())
            }
        }

        /// The style the attributes right above give the next block: `source`, `NOTE`, `quote`.
        var pendingStyle: String? {
            pendingAttributes.first.flatMap { Self.style(of: $0) }
        }

        /// The first line of the attributes (and titles, where `titles`) right above a block, which become part of
        /// it; those further up fold away on their own.
        mutating func takePending(above line: Int, titles: Bool) -> Int {
            var first = line
            while let last = pending.last, last == first - 1, lines[last].kind == .markup || (titles && isTitle(last)) {
                first = last
                pending.removeLast()
            }
            flushPending()
            return first
        }

        func isTitle(_ line: Int) -> Bool {
            if case .blockTitle = lines[line].kind { true } else { false }
        }

        /// Attribute lines no block took fold away on their own; a title stays a line of text.
        mutating func flushPending() {
            var run: ClosedRange<Int>?
            for line in pending where lines[line].kind == .markup {
                if let current = run, current.upperBound == line - 1 {
                    run = current.lowerBound...line
                } else {
                    if let current = run { addBlock(.markup, from: current.lowerBound, to: current.upperBound) }
                    run = line...line
                }
            }
            if let run { addBlock(.markup, from: run.lowerBound, to: run.upperBound) }
            pending = []
        }

        func language(of attributes: [String]) -> String {
            guard let first = attributes.first else { return "" }
            let parts = first.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard Self.style(of: first) == "source" else { return "" }
            return parts.count > 1 && !parts[1].contains("=") ? parts[1].lowercased() : ""
        }

        /// The first positional attribute, without its id, roles and options: `source` of `[source,python]`.
        static func style(of attributes: String) -> String? {
            let first = attributes.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !first.contains("=") else { return nil }
            let style = first.prefix { $0 != "#" && $0 != "." && $0 != "%" }
            return style.isEmpty ? nil : String(style)
        }

        // MARK: Lists

        mutating func endList() {
            list.reset()
            item = nil
        }

        mutating func listItem(at line: Int, indent: (columns: Int, units: Int)) -> ListItem? {
            listItem(at: line, indent: indent, state: &list)
        }

        func listItem(at line: Int, indent: (columns: Int, units: Int), state: inout ListState) -> ListItem? {
            let range = lines[line].range
            let start = range.location + indent.units
            let end = range.upperBound
            guard start < end else { return nil }
            var i = start
            let key: String
            var marker: ListItem.Marker
            var counted = false
            switch u[i] {
            case 42, 46: // * .
                let character = u[i]
                while i < end, u[i] == character { i += 1 }
                guard i - start <= 5 else { return nil }
                key = String(repeating: character == 42 ? "*" : ".", count: i - start)
                marker = character == 42 ? .bullet("*") : .ordered(1, ".")
                counted = character == 46
            case 45: // -
                i += 1
                key = "-"
                marker = .bullet("-")
            case 48...57:
                var number = 0
                while i < end, u[i] >= 48, u[i] <= 57, i - start < 9 { number = number * 10 + Int(u[i] - 48); i += 1 }
                guard i < end, u[i] == 46 || u[i] == 41 else { return nil }
                key = "1" + String(UnicodeScalar(u[i])!)
                marker = .ordered(number, Character(UnicodeScalar(u[i])!))
                i += 1
            case 65...90, 97...122:
                // `a.`, `B.` and roman numerals `iv)`.
                var letters = i
                while letters < end, (65...90).contains(u[letters]) || (97...122).contains(u[letters]) { letters += 1 }
                guard letters < end, letters - i <= 6 else { return nil }
                let word = MarkdownParser.lineText(u, NSRange(location: i, length: letters - i))
                if u[letters] == 46, letters - i == 1 {
                    let value = Int(u[i]) - ((65...90).contains(u[i]) ? 64 : 96)
                    key = (65...90).contains(u[i]) ? "A." : "a."
                    marker = .ordered(value, ".")
                } else if u[letters] == 41, let value = Self.roman(word) {
                    key = word.first!.isUppercase ? "I)" : "i)"
                    marker = .ordered(value, ")")
                } else {
                    return nil
                }
                i = letters + 1
            default:
                return nil
            }
            let markerRange = NSRange(location: start, length: i - start)
            guard i == end || u[i] == 32 || u[i] == 9 else { return nil }
            while i < end, u[i] == 32 || u[i] == 9 { i += 1 }

            var checkbox: NSRange?
            var mark = TaskMark.open
            if case .bullet = marker, i + 3 <= end, u[i] == 91, u[i + 2] == 93, [32, 120, 88, 42].contains(u[i + 1]) || TaskMark(u[i + 1]) != nil,
               i + 3 == end || u[i + 3] == 32 || u[i + 3] == 9 {
                checkbox = NSRange(location: i, length: 3)
                mark = u[i + 1] == 42 ? .done : TaskMark(u[i + 1]) ?? .open
                i += 3
                while i < end, u[i] == 32 || u[i] == 9 { i += 1 }
            }

            let level: Int
            if let found = state.markers.firstIndex(of: key) {
                state.markers.removeSubrange((found + 1)...)
                state.counts.removeSubrange((found + 1)...)
                level = found
            } else {
                state.markers.append(key)
                state.counts.append(0)
                level = state.markers.count - 1
            }
            if case .ordered(let number, let delimiter) = marker {
                state.counts[level] = counted ? state.counts[level] + 1 : number
                marker = .ordered(state.counts[level], delimiter)
            }

            return ListItem(
                // AsciiDoc nests by marker, not by spaces: an indent that says the level, for what compares indents
                // (to-dos and the lines under them).
                indent: level * 2,
                level: level,
                indentRange: NSRange(location: range.location, length: indent.units),
                marker: marker,
                markerRange: markerRange,
                prefix: NSRange(location: range.location, length: i - range.location),
                checkbox: checkbox,
                checked: checkbox != nil && mark.isClosed,
                mark: mark,
                counted: counted
            )
        }

        static func roman(_ word: String) -> Int? {
            let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
            var total = 0
            var previous = 0
            for character in word.lowercased().reversed() {
                guard let value = values[character] else { return nil }
                total += value < previous ? -value : value
                previous = max(previous, value)
            }
            return total > 0 ? total : nil
        }

        /// `Term:: description`: the term and the marker, `::` (or `:::`, `::::`, `;;`) followed by a space or nothing.
        func definition(at line: Int, indent: (columns: Int, units: Int)) -> (term: NSRange, marker: NSRange)? {
            let range = lines[line].range
            let start = range.location + indent.units
            let end = range.upperBound
            var i = start + 1
            while i + 1 < end {
                let c = u[i]
                if (c == 58 || c == 59), u[i + 1] == c {
                    var j = i
                    while j < end, u[j] == c, j - i < 4 { j += 1 }
                    let length = j - i
                    let fits = c == 58 ? (2...4).contains(length) : length == 2
                    if fits, j == end || u[j] == 32 || u[j] == 9, u[i - 1] != 32, u[i - 1] != 58 {
                        var markerEnd = j
                        while markerEnd < end, u[markerEnd] == 32 || u[markerEnd] == 9 { markerEnd += 1 }
                        return (NSRange(location: start, length: i - start), NSRange(location: i, length: markerEnd - i))
                    }
                    i = j
                    continue
                }
                i += 1
            }
            return nil
        }

        // MARK: Line shapes

        /// `== Title` (or Markdown's `## Title`): its level, and the marks with the spaces after them.
        func sectionMarker(_ line: Int) -> (level: Int, range: NSRange)? {
            let range = lines[line].range
            guard range.length > 1 else { return nil }
            let character = u[range.location]
            guard character == 61 || character == 35 else { return nil }
            var i = range.location
            while i < range.upperBound, u[i] == character { i += 1 }
            let count = i - range.location
            guard count <= 6, i < range.upperBound, u[i] == 32 || u[i] == 9 else { return nil }
            while i < range.upperBound, u[i] == 32 || u[i] == 9 { i += 1 }
            guard i < range.upperBound else { return nil }
            return (count, NSRange(location: range.location, length: i - range.location))
        }

        /// `[source,python]`, `[[id]]`, `[#id.role]`, `[NOTE]`: a line in brackets.
        static func isAttributeLine(_ trimmed: String) -> Bool {
            guard trimmed.count >= 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return false }
            // A checkbox written alone, `[ ]`, is no attribute.
            return trimmed != "[ ]" && trimmed != "[x]"
        }

        /// `.Title`: a dot, then a character that is no dot or space.
        static func isBlockTitle(_ text: String) -> Bool {
            let characters = text.utf16
            guard characters.count > 1, characters.first == 46 else { return false }
            let second = characters[characters.index(after: characters.startIndex)]
            return second != 46 && second != 32 && second != 9
        }

        /// `NOTE: `, `TIP: ` and the others at the start of a paragraph: the type, and the marker with the spaces.
        static func admonitionMarker(_ text: String) -> (type: String, length: Int)? {
            for admonition in AsciiDocParser.admonitions where text.hasPrefix(admonition + ":") {
                let rest = text.utf16.dropFirst(admonition.count + 1)
                guard let first = rest.first, first == 32 || first == 9 else { return nil }
                let spaces = rest.prefix { $0 == 32 || $0 == 9 }.count
                return (admonition.lowercased(), admonition.count + 1 + spaces)
            }
            return nil
        }
    }

    /// Inline AsciiDoc in the lines that hold text.
    static func readSpans(_ lines: inout [MarkdownLine], _ u: [UInt16], in range: Range<Int>, attributes: [String: String], typing: Bool) {
        let context = AsciiDocInlineParser.Context(attributes: attributes)
        for line in range {
            switch lines[line].kind {
            case .paragraph, .heading, .listItem, .quote, .tableHeader, .tableRow, .blockTitle, .admonition, .definition, .continuation:
                lines[line].spans = AsciiDocInlineParser.spans(in: u, range: lines[line].content, context: context, typing: typing)
                if case .listItem(let item) = lines[line].kind, item.isTask {
                    let marks = TodoMarks.spans(in: u, range: lines[line].content)
                    if !marks.isEmpty {
                        lines[line].spans.removeAll { span in marks.contains { NSIntersectionRange($0.range, span.range).length > 0 } }
                        lines[line].spans = (lines[line].spans + marks).sorted { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.range.length > $1.range.length) }
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Delimiters

    struct Delimiter: Equatable {
        enum Kind: Equatable {
            case listing, literal, passthrough, example, sidebar, quote, open
            case fenced(language: String)
            case table(separator: UInt16)
        }

        var kind: Kind
        var text: String

        /// Blocks that hold other blocks, whose lines are read as usual.
        var isContainer: Bool {
            switch kind {
            case .example, .sidebar, .quote, .open: true
            default: false
            }
        }

        init?(_ trimmed: String, typing: Bool = false) {
            text = trimmed
            let characters = Array(trimmed.utf16)
            guard let first = characters.first else { return nil }
            if trimmed == "--" {
                kind = .open
                return
            }
            if characters.count >= 3, first == 96, characters.prefix(3).allSatisfy({ $0 == 96 }) {
                let info = trimmed.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces)
                guard !info.contains("`") else { return nil }
                kind = .fenced(language: info.split(separator: " ").first.map { String($0).lowercased() } ?? "")
                text = String(trimmed.prefix { $0 == "`" })
                return
            }
            if characters.count >= 4, [124, 33, 44, 58].contains(first), characters.dropFirst().allSatisfy({ $0 == 61 }) {
                kind = .table(separator: first)
                return
            }
            guard characters.count >= 4, characters.allSatisfy({ $0 == first }) else { return nil }
            switch first {
            case 45: kind = .listing
            case 46: kind = .literal
            case 43: kind = .passthrough
            case 61: kind = .example
            // Four stars alone make a sidebar, but while the note is typed in they are the empty pair of bold marks
            // that typing `**` puts in, waiting for their text.
            case 42 where !(typing && characters.count == 4): kind = .sidebar
            case 95: kind = .quote
            default: return nil
            }
        }
    }
}

// MARK: - Soft line breaks

extension MarkdownDocument {
    /// AsciiDoc: whether the line break after a line only wraps its paragraph, as AsciiDoc's line breaks in a paragraph
    /// do (they read as a space): between lines of one paragraph, and between a list item and the lines of text that
    /// go on with it. Not after ` +`, AsciiDoc's line break, nor between a term and its description.
    func isSoftBreak(after index: Int, in text: NSString) -> Bool {
        guard syntax == .asciidoc, index + 1 < lines.count else { return false }
        let line = lines[index]
        let next = lines[index + 1]
        guard line.breakLength > 0, line.range.length > 0, next.range.length > 0, line.range.upperBound <= text.length else { return false }
        if line.range.length >= 2, text.character(at: line.range.upperBound - 1) == 43, text.character(at: line.range.upperBound - 2) == 32 { return false }
        switch (line.kind, next.kind) {
        case (.paragraph, .paragraph), (.admonition, .paragraph):
            return line.block == next.block
        case (.listItem, .continuation(let item, _)):
            return item == index
        case (.continuation(let item, _), .continuation(let other, _)):
            return item == other
        default:
            return false
        }
    }

    /// The last line of the paragraph a line starts or is in, following its soft line breaks.
    func endOfParagraph(from index: Int, in text: NSString) -> Int {
        var end = index
        while isSoftBreak(after: end, in: text) { end += 1 }
        return end
    }
}

// MARK: - Tables

/// AsciiDoc's tables: the columns their attributes give, and the cells of their rows, which may run over several lines.
enum AsciiDocTable {
    struct Spec: Equatable {
        /// From `cols`: how many there are, how they align, how wide they are relative to each other.
        var columns: Int?
        var alignments: [TableAlignment] = []
        var weights: [Double] = []
        /// From `options`: true for `header`, false for `noheader`, nil when they don't say.
        var header: Bool?

        init(attributes: [String]) {
            for list in attributes {
                for (name, value) in Self.namedAttributes(list) {
                    switch name {
                    case "cols": readColumns(value)
                    case "options", "opts":
                        if value.contains("noheader") { header = false } else if value.contains("header") { header = true }
                    default: break
                    }
                }
                // `%header` in the first positional attribute.
                let first = list.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                if first.contains("%noheader") { header = false } else if first.contains("%header") { header = true }
            }
        }

        mutating func readColumns(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // `cols=3` or `cols="3"`: three columns alike.
            if let count = Int(trimmed) {
                columns = count
                alignments = Array(repeating: .leading, count: count)
                weights = Array(repeating: 1, count: count)
                return
            }
            var alignments: [TableAlignment] = []
            var weights: [Double] = []
            for part in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                var spec = part.trimmingCharacters(in: .whitespaces)
                var repeats = 1
                if let star = spec.firstIndex(of: "*"), let count = Int(spec[..<star]) {
                    repeats = count
                    spec = String(spec[spec.index(after: star)...])
                }
                var alignment = TableAlignment.leading
                if spec.hasPrefix("^") { alignment = .center } else if spec.hasPrefix(">") { alignment = .trailing }
                let digits = spec.drop { !$0.isNumber }.prefix { $0.isNumber }
                let weight = Double(digits).map { max(1, $0) } ?? 1
                alignments += Array(repeating: alignment, count: repeats)
                weights += Array(repeating: weight, count: repeats)
            }
            guard !alignments.isEmpty else { return }
            columns = alignments.count
            self.alignments = alignments
            self.weights = weights
        }

        /// `name=value` and `name="value"` pairs of an attribute list.
        static func namedAttributes(_ list: String) -> [(String, String)] {
            var result: [(String, String)] = []
            var i = list.startIndex
            while i < list.endIndex {
                guard let equals = list[i...].firstIndex(of: "=") else { break }
                let name = list[i..<equals].split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                var valueStart = list.index(after: equals)
                var value: Substring
                if valueStart < list.endIndex, list[valueStart] == "\"" || list[valueStart] == "'" {
                    let quote = list[valueStart]
                    valueStart = list.index(after: valueStart)
                    let close = list[valueStart...].firstIndex(of: quote) ?? list.endIndex
                    value = list[valueStart..<close]
                    i = close < list.endIndex ? list.index(after: close) : close
                } else {
                    let close = list[valueStart...].firstIndex(of: ",") ?? list.endIndex
                    value = list[valueStart..<close]
                    i = close
                }
                if i < list.endIndex, list[i] == "," { i = list.index(after: i) }
                result.append((name.lowercased(), String(value)))
            }
            return result
        }
    }

    struct Cell: Equatable {
        /// The cell's text, without its separator and spaces around it.
        var range: NSRange
        /// How many columns it spans (`2+|`).
        var span: Int
        /// Its specifier says its text is AsciiDoc of its own (`a|`) or literal (`l|`).
        var style: Character?
    }

    struct Row: Equatable {
        var cells: [Cell]
        /// The lines it is written on.
        var lines: [Int]
    }

    /// The rows of a table: its cells in order, a row as many as there are columns (from `cols`, or else as many as
    /// the first line of cells has). A cell runs from its separator to the next one's specifier, over lines if need be.
    static func rows(_ u: [UInt16], lines: [MarkdownLine], inner: Range<Int>, separator: UInt16, columns: Int?) -> [Row] {
        let filled = inner.filter { !MarkdownParser.isBlank(u, lines[$0].range) }
        guard let firstLine = filled.first, let lastLine = filled.last else { return [] }
        if separator == 44 || separator == 58 {
            // CSV and DSV: a row a line.
            return filled.map { line in
                let range = lines[line].range
                var row: [Cell] = []
                var start = range.location
                for i in range.location...range.upperBound where i == range.upperBound || u[i] == separator {
                    row.append(Cell(range: trimmedRange(u, NSRange(location: start, length: i - start)), span: 1, style: nil))
                    start = i + 1
                }
                return Row(cells: row, lines: [line])
            }
        }
        let start = lines[firstLine].range.location
        let end = lines[lastLine].range.upperBound
        var separators: [Int] = []
        var i = start
        while i < end {
            if u[i] == 92, i + 1 < end, u[i + 1] == separator { i += 2; continue }
            if u[i] == separator { separators.append(i) }
            i += 1
        }
        func line(of position: Int) -> Int {
            filled.last { lines[$0].range.location <= position } ?? firstLine
        }
        var cells: [(cell: Cell, line: Int)] = []
        for (k, at) in separators.enumerated() {
            let lowerBound = k == 0 ? start : separators[k - 1] + 1
            let spec = specifier(u, at, lowerBound: lowerBound)
            let contentEnd = k + 1 < separators.count ? specifier(u, separators[k + 1], lowerBound: at + 1).start : end
            cells.append((Cell(range: trimmedRange(u, NSRange(location: at + 1, length: max(0, contentEnd - at - 1))), span: spec.span, style: spec.style), line(of: at)))
        }
        let firstLineCells = cells.filter { $0.line == cells.first?.line }.count
        let width = max(1, columns ?? firstLineCells)
        var rows: [Row] = []
        var current: [(cell: Cell, line: Int)] = []
        var taken = 0
        func finish() {
            guard let first = current.first?.line, let lastCell = current.last?.cell.range else { return }
            let last = max(first, line(of: max(lastCell.location, lastCell.upperBound - 1)))
            rows.append(Row(cells: current.map(\.cell), lines: filled.filter { $0 >= first && $0 <= last }))
            current = []
            taken = 0
        }
        for entry in cells {
            current.append(entry)
            taken += entry.cell.span
            if taken >= width { finish() }
        }
        finish()
        return rows
    }

    /// The specifier written right before a separator, `2+`, `.3+`, `^.^`, `3*`, `a`: where it starts, how many
    /// columns the cell spans, and its style. Only a whole word that reads as one counts: `Version 2|` has none.
    static func specifier(_ u: [UInt16], _ separator: Int, lowerBound: Int) -> (start: Int, span: Int, style: Character?) {
        var i = separator
        while i > lowerBound, !isSpace(u[i - 1]) { i -= 1 }
        guard i < separator else { return (separator, 1, nil) }
        let spec = String(decoding: u[i..<separator], as: UTF16.self)
        guard let parsed = parse(spec) else { return (separator, 1, nil) }
        return (i, parsed.span, parsed.style)
    }

    /// `[n*][n+ or .n+ or n.n+][<^>][.<^>][adehlmsv]`.
    private static func parse(_ spec: String) -> (span: Int, style: Character?)? {
        var rest = Substring(spec)
        func number() -> Int? {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { return nil }
            rest = rest.dropFirst(digits.count)
            return Int(digits)
        }
        var span = 1
        let saved = rest
        if number() != nil, rest.first == "*" {
            rest = rest.dropFirst()
        } else {
            rest = saved
        }
        let beforeSpan = rest
        let columns = number()
        if rest.first == "." {
            rest = rest.dropFirst()
            _ = number()
        }
        if rest.first == "+" {
            rest = rest.dropFirst()
            // `.3+` spans rows, not columns.
            if let columns, !beforeSpan.hasPrefix(".") { span = columns }
        } else {
            rest = beforeSpan
        }
        if let first = rest.first, "<^>".contains(first) { rest = rest.dropFirst() }
        if rest.first == ".", rest.count > 1, "<^>".contains(rest[rest.index(after: rest.startIndex)]) { rest = rest.dropFirst(2) }
        var style: Character?
        if let first = rest.first, "adehlmsv".contains(first) {
            style = first
            rest = rest.dropFirst()
        }
        guard rest.isEmpty, spec != "" else { return nil }
        return (span, style)
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    static func trimmedRange(_ u: [UInt16], _ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.upperBound
        while start < end, u[start] == 32 || u[start] == 9 || u[start] == 10 || u[start] == 13 { start += 1 }
        while end > start, u[end - 1] == 32 || u[end - 1] == 9 || u[end - 1] == 10 || u[end - 1] == 13 { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
