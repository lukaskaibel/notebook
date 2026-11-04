import Foundation

/// Inline AsciiDoc inside one line, into the same spans as `InlineParser`: `*bold*` and `**bold**`, `_italics_`,
/// `` `code` ``, `#highlights#`, `^super^` and `~sub~`, roles (`[.line-through]#…#`), links (`https://…[text]`,
/// `link:`, `xref:`, `<<id,text>>`), `image:` and `image::`, `include::`, `kbd:`, `stem:`, anchors, passthroughs,
/// escapes and the ` +` of a hard line break. Constrained marks need a word's edge on their outer side, as in
/// Asciidoctor.
enum AsciiDocInlineParser {
    /// What the rest of the note says that inline AsciiDoc needs: its attributes, for `{name}` in addresses and
    /// `imagesdir` in front of pictures.
    struct Context {
        var attributes: [String: String] = [:]

        /// An address with its `{name}`s put in.
        func substituted(_ target: String) -> String {
            guard target.contains("{") else { return target }
            var result = target
            for (name, value) in attributes where result.contains("{\(name)}") {
                result = result.replacingOccurrences(of: "{\(name)}", with: value)
            }
            return result
        }

        /// A picture's address, under `imagesdir` unless it is absolute or a URL.
        func picture(_ target: String) -> String {
            let target = substituted(target)
            guard let folder = attributes["imagesdir"], !folder.isEmpty, !target.hasPrefix("/"), !target.contains("://") else { return target }
            return folder.hasSuffix("/") ? folder + target : folder + "/" + target
        }
    }

    static func spans(in u: [UInt16], range: NSRange, context: Context = Context(), typing: Bool = false) -> [InlineSpan] {
        guard range.length > 0 else { return [] }
        var result = Scanner(u: u, context: context, typing: typing).parse(range, lineStart: range.location)
        result.sort { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.range.length > $1.range.length) }
        return result
    }

    private struct Scanner {
        let u: [UInt16]
        let context: Context
        let typing: Bool

        func parse(_ range: NSRange, lineStart: Int) -> [InlineSpan] {
            var spans: [InlineSpan] = []
            let end = range.upperBound
            var i = range.location
            while i < end {
                let c = u[i]
                switch c {
                case 45, 40, 46, 60, 61: // -- -> ... (C) <- => <=
                    if let span = replacement(at: i, in: range) {
                        spans.append(span)
                        i = span.range.upperBound
                        continue
                    }
                    if c == 60, let span = crossReference(at: i, end: end) {
                        spans.append(span)
                        i = span.range.upperBound
                    } else {
                        i += 1
                    }

                case 92: // \ escape of markup
                    if i + 1 < end, isEscapable(u[i + 1]) {
                        spans.append(InlineSpan(kind: .escape, range: NSRange(location: i, length: 2), markers: [NSRange(location: i, length: 1)], content: NSRange(location: i + 1, length: 1)))
                        i += 2
                        continue
                    }
                    i += 1

                case 96: // ` code
                    if let span = pair(at: i, mark: 96, kind: .code, in: range, nested: false) {
                        spans.append(literal(span))
                        i = span.range.upperBound
                    } else {
                        i += 1
                    }

                case 42, 95, 35: // * _ #
                    let kind: InlineSpan.Kind = c == 42 ? .strong : c == 95 ? .emphasis : .highlight
                    if let span = pair(at: i, mark: c, kind: kind, in: range, nested: true) {
                        spans.append(span)
                        spans.append(contentsOf: parse(span.content, lineStart: lineStart))
                        i = span.range.upperBound
                    } else {
                        i += 1
                    }

                case 94, 126: // ^super^ ~sub~
                    if let close = ((i + 1)..<end).first(where: { u[$0] == c || isWhitespace(u[$0]) }), u[close] == c, close > i + 1 {
                        spans.append(InlineSpan(
                            kind: c == 94 ? .superscript : .subscript,
                            range: NSRange(location: i, length: close + 1 - i),
                            markers: [NSRange(location: i, length: 1), NSRange(location: close, length: 1)],
                            content: NSRange(location: i + 1, length: close - i - 1)
                        ))
                        i = close + 1
                    } else {
                        i += 1
                    }

                case 91: // [[anchor]] or [.role]#text#
                    if let span = anchor(at: i, end: end) ?? role(at: i, in: range) {
                        spans.append(span)
                        if span.content.length > 0, span.kind != .code { spans.append(contentsOf: parse(span.content, lineStart: lineStart)) }
                        i = span.range.upperBound
                    } else {
                        i += 1
                    }

                case 43: // + a hard line break at the end, +passthrough+, +++passthrough+++
                    if i == end - 1, i > lineStart, isWhitespace(u[i - 1]) {
                        spans.append(InlineSpan(kind: .escape, range: NSRange(location: i, length: 1), markers: [NSRange(location: i, length: 1)], content: NSRange(location: i + 1, length: 0)))
                        i += 1
                    } else if let span = passthrough(at: i, in: range) {
                        spans.append(span)
                        i = span.range.upperBound
                    } else {
                        i += 1
                    }

                case 97...122: // macros and addresses, which start a word
                    if i > range.location, isWordCharacter(u[i - 1]) {
                        i += 1
                    } else if let found = macro(at: i, in: range) {
                        spans.append(contentsOf: found)
                        i = found.map(\.range.upperBound).max() ?? i + 1
                    } else {
                        i += 1
                    }

                default:
                    i += 1
                }
            }
            return spans
        }

        // MARK: Quotes

        /// `**x**` anywhere, or `*x*` at a word's edges: the mark doubled, or alone with no word character outside it.
        func pair(at i: Int, mark c: UInt16, kind: InlineSpan.Kind, in range: NSRange, nested: Bool) -> InlineSpan? {
            let end = range.upperBound
            if i + 1 < end, u[i + 1] == c, let close = closingDouble(c, from: i + 2, end: end) {
                return InlineSpan(
                    kind: kind,
                    range: NSRange(location: i, length: close + 2 - i),
                    markers: [NSRange(location: i, length: 2), NSRange(location: close, length: 2)],
                    content: NSRange(location: i + 2, length: close - i - 2)
                )
            }
            // Constrained: nothing of a word before the opening mark, no space after it.
            if i > range.location {
                let before = u[i - 1]
                if isWordCharacter(before) || before == c || [59, 58, 125].contains(before) { return nil }
                if c == 96, [34, 39].contains(before) { return nil }
            }
            guard i + 1 < end, !isWhitespace(u[i + 1]), u[i + 1] != c else { return nil }
            var j = i + 2
            while j < end {
                if u[j] == c, u[j - 1] != 92 {
                    let after: UInt16? = j + 1 < end ? u[j + 1] : nil
                    let edge = after.map { !isWordCharacter($0) && $0 != c } ?? true
                    let tight = !isWhitespace(u[j - 1]) || (typing && (after.map(isWhitespace) ?? true))
                    if edge, tight, j > i + 1 {
                        return InlineSpan(
                            kind: kind,
                            range: NSRange(location: i, length: j + 1 - i),
                            markers: [NSRange(location: i, length: 1), NSRange(location: j, length: 1)],
                            content: NSRange(location: i + 1, length: j - i - 1)
                        )
                    }
                }
                // Code is closed only by its own mark, and nothing in it counts.
                j += 1
            }
            // `*x*` with x one character.
            if i + 2 < end, u[i + 2] == c, !isWhitespace(u[i + 1]), i + 3 >= end || !isWordCharacter(u[i + 3]) {
                return InlineSpan(kind: kind, range: NSRange(location: i, length: 3), markers: [NSRange(location: i, length: 1), NSRange(location: i + 2, length: 1)], content: NSRange(location: i + 1, length: 1))
            }
            return nil
        }

        func closingDouble(_ c: UInt16, from start: Int, end: Int) -> Int? {
            var j = start + 1
            while j + 1 < end {
                if u[j] == c, u[j + 1] == c, u[j - 1] != 92 { return j }
                j += 1
            }
            return nil
        }

        /// Code whose text starts and ends with `+` shows it as written: the pluses are marks too.
        func literal(_ span: InlineSpan) -> InlineSpan {
            let content = span.content
            guard content.length >= 2, u[content.location] == 43, u[content.upperBound - 1] == 43 else { return span }
            var result = span
            result.markers = [
                NSRange(location: span.range.location, length: content.location - span.range.location + 1),
                NSRange(location: content.upperBound - 1, length: span.range.upperBound - content.upperBound + 1),
            ]
            result.content = NSRange(location: content.location + 1, length: content.length - 2)
            return result
        }

        // MARK: Brackets

        /// `[[id]]` or `[[id, text]]`: an anchor, which shows nothing.
        func anchor(at i: Int, end: Int) -> InlineSpan? {
            guard i + 4 < end, u[i + 1] == 91 else { return nil }
            var j = i + 2
            while j + 1 < end, !(u[j] == 93 && u[j + 1] == 93) {
                if u[j] == 91 || isWhitespace(u[j]) && j == i + 2 { return nil }
                j += 1
            }
            guard j + 1 < end, j > i + 2 else { return nil }
            let range = NSRange(location: i, length: j + 2 - i)
            return InlineSpan(kind: .escape, range: range, markers: [range], content: NSRange(location: range.upperBound, length: 0))
        }

        /// `[.role]#text#`, `[#id]##text##`: what the role says (`line-through`, `mark`, `underline`), else just the text.
        func role(at i: Int, in range: NSRange) -> InlineSpan? {
            let end = range.upperBound
            guard let close = ((i + 1)..<end).first(where: { u[$0] == 93 || u[$0] == 91 }), u[close] == 93, close + 1 < end, u[close + 1] == 35 else { return nil }
            let attributes = string(NSRange(location: i + 1, length: close - i - 1))
            guard attributes.hasPrefix(".") || attributes.hasPrefix("#") || attributes.hasPrefix("%") else { return nil }
            let roles = attributes.split(separator: ".", omittingEmptySubsequences: false).dropFirst().map(String.init)
            let kind: InlineSpan.Kind = roles.contains("line-through") ? .strikethrough : roles.contains("mark") ? .highlight : .escape
            // The text between the hashes, as a highlight would be read from the first one on.
            let inner = NSRange(location: close + 1, length: end - close - 1)
            guard let marked = pair(at: close + 1, mark: 35, kind: kind, in: NSRange(location: inner.location, length: inner.length), nested: true) else { return nil }
            return InlineSpan(
                kind: kind,
                range: NSRange(location: i, length: marked.range.upperBound - i),
                markers: [NSRange(location: i, length: marked.markers[0].upperBound - i), marked.markers[1]],
                content: marked.content
            )
        }

        /// `<<id>>`, `<<id,text>>`, `<<file.adoc#id,text>>`.
        func crossReference(at i: Int, end: Int) -> InlineSpan? {
            guard i + 4 < end, u[i + 1] == 60 else { return nil }
            var j = i + 2
            while j + 1 < end, !(u[j] == 62 && u[j + 1] == 62) {
                if u[j] == 60 { return nil }
                j += 1
            }
            guard j + 1 < end, j > i + 2, !isWhitespace(u[i + 2]) else { return nil }
            let inner = NSRange(location: i + 2, length: j - i - 2)
            let comma = (inner.location..<inner.upperBound).first { u[$0] == 44 }
            let target = string(NSRange(location: inner.location, length: (comma ?? inner.upperBound) - inner.location)).trimmingCharacters(in: .whitespaces)
            var content = inner
            var opening = NSRange(location: i, length: 2)
            if let comma {
                var start = comma + 1
                while start < inner.upperBound, isWhitespace(u[start]) { start += 1 }
                content = NSRange(location: start, length: inner.upperBound - start)
                opening = NSRange(location: i, length: start - i)
            }
            return InlineSpan(
                kind: .link(destination: Self.destination(of: target)),
                range: NSRange(location: i, length: j + 2 - i),
                markers: [opening, NSRange(location: j, length: 2)],
                content: content
            )
        }

        /// Where a cross reference goes: another file, a place in one, or (`#id`) a place in this one.
        static func destination(of target: String) -> String {
            if target.contains("#") || target.hasSuffix(".adoc") || target.hasSuffix(".asciidoc") { return target }
            return "#" + target
        }

        /// `+text+` and `+++text+++`: shown as written.
        func passthrough(at i: Int, in range: NSRange) -> InlineSpan? {
            let end = range.upperBound
            let run = i + 2 < end && u[i + 1] == 43 && u[i + 2] == 43 ? 3 : 1
            if run == 1, i > range.location, isWordCharacter(u[i - 1]) { return nil }
            guard i + run < end, !isWhitespace(u[i + run]) else { return nil }
            var j = i + run + 1
            while j + run <= end {
                if (0..<run).allSatisfy({ u[j + $0] == 43 }), !isWhitespace(u[j - 1]), run == 3 || j + 1 >= end || !isWordCharacter(u[j + 1]) {
                    return InlineSpan(
                        kind: .escape,
                        range: NSRange(location: i, length: j + run - i),
                        markers: [NSRange(location: i, length: run), NSRange(location: j, length: run)],
                        content: NSRange(location: i + run, length: j - i - run)
                    )
                }
                j += 1
            }
            return nil
        }

        // MARK: Replacements

        /// What Asciidoctor puts in for some characters: `--` between words or spaces is an em dash, `...` an ellipsis,
        /// `->`, `<-`, `=>` and `<=` arrows, `(C)`, `(R)` and `(TM)` their signs.
        func replacement(at i: Int, in range: NSRange) -> InlineSpan? {
            let end = range.upperBound
            func next(_ offset: Int) -> UInt16? { i + offset < end ? u[i + offset] : nil }
            let before: UInt16? = i > range.location ? u[i - 1] : nil
            let pairs: [(String, String)] = [("(TM)", "™"), ("(C)", "©"), ("(R)", "®"), ("...", "…"), ("->", "→"), ("<-", "←"), ("=>", "⇒"), ("<=", "⇐")]
            for (written, shown) in pairs {
                let units = Array(written.utf16)
                guard i + units.count <= end, (0..<units.count).allSatisfy({ u[i + $0] == units[$0] }) else { continue }
                // Not part of a longer run: `-->`, `<=>`, `....`.
                if let after = next(units.count), "-=<>.".utf16.contains(after), written != "(C)", written != "(R)", written != "(TM)" { return nil }
                if let before, "-=<>.".utf16.contains(before) { return nil }
                return InlineSpan(kind: .replacement(shown), range: NSRange(location: i, length: units.count), markers: [NSRange(location: i, length: units.count)],
                                  content: NSRange(location: i + units.count, length: 0))
            }
            // `--` alone between spaces, or between two words.
            guard u[i] == 45, next(1) == 45, next(2) != 45, before != 45 else { return nil }
            let after = next(2)
            let spaced = (before.map(isWhitespace) ?? true) && (after.map(isWhitespace) ?? true)
            let joined = before.map(isWordCharacter) == true && after.map(isWordCharacter) == true
            guard spaced || joined, !(before == nil && after == nil) else { return nil }
            return InlineSpan(kind: .replacement("—"), range: NSRange(location: i, length: 2), markers: [NSRange(location: i, length: 2)],
                              content: NSRange(location: i + 2, length: 0))
        }

        // MARK: Macros

        /// A macro or an address at a word's start: `https://…`, `mailto:`, `link:`, `xref:`, `image:`, `include::`,
        /// `kbd:[…]`, `stem:[…]`, `footnote:[…]`, `pass:[…]`.
        func macro(at i: Int, in range: NSRange) -> [InlineSpan]? {
            let end = range.upperBound
            var name = i
            while name < end, (97...122).contains(u[name]) { name += 1 }
            guard name < end, u[name] == 58 else { return nil }
            let word = string(NSRange(location: i, length: name - i))
            switch word {
            case "http", "https", "ftp", "irc", "mailto":
                return address(at: i, in: range, scheme: word)
            case "link", "xref", "image", "include", "video", "audio":
                var targetStart = name + 1
                if u[targetStart - 1] == 58, targetStart < end, u[targetStart] == 58 { targetStart += 1 }
                let isBlock = targetStart == name + 2
                guard targetStart < end, !isWhitespace(u[targetStart]), let open = ((targetStart)..<end).first(where: { u[$0] == 91 || isWhitespace(u[$0]) }), u[open] == 91,
                      let close = closingBracket(from: open + 1, end: end) else { return nil }
                let target = string(NSRange(location: targetStart, length: open - targetStart))
                let text = NSRange(location: open + 1, length: close - open - 1)
                let whole = NSRange(location: i, length: close + 1 - i)
                switch word {
                case "image":
                    let alt = string(text).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                    return [InlineSpan(kind: .image(source: context.picture(target), alt: alt), range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: text)]
                case "include", "video", "audio":
                    guard isBlock else { return nil }
                    let source = context.substituted(target)
                    let kind: InlineSpan.Kind = word == "include" ? .embed(target: source) : .image(source: source, alt: "")
                    return [InlineSpan(kind: kind, range: whole, markers: [NSRange(location: i, length: targetStart - i), NSRange(location: open, length: close + 1 - open)], content: NSRange(location: targetStart, length: open - targetStart))]
                default:
                    guard !isBlock else { return nil }
                    let destination = word == "xref" ? Self.destination(of: target) : target
                    if text.length == 0 {
                        // No text: the address shows.
                        return [InlineSpan(kind: .link(destination: context.substituted(destination)), range: whole, markers: [NSRange(location: i, length: targetStart - i), NSRange(location: open, length: 2)], content: NSRange(location: targetStart, length: open - targetStart))]
                    }
                    var spans = [InlineSpan(kind: .link(destination: context.substituted(destination)), range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: text)]
                    spans.append(contentsOf: parse(text, lineStart: range.location))
                    return spans
                }
            case "kbd", "btn", "stem", "latexmath", "asciimath", "footnote", "pass", "menu":
                // `name:[text]`, or `footnote:id[text]`, `menu:File[Save]`.
                guard let open = ((name + 1)..<end).first(where: { u[$0] == 91 || isWhitespace(u[$0]) }), u[open] == 91,
                      let close = closingBracket(from: open + 1, end: end) else { return nil }
                if word != "footnote", word != "menu", word != "pass", open != name + 1 { return nil }
                let inner = NSRange(location: open + 1, length: close - open - 1)
                let whole = NSRange(location: i, length: close + 1 - i)
                switch word {
                case "stem", "latexmath":
                    return [InlineSpan(kind: .math(tex: string(inner)), range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: inner)]
                case "footnote":
                    return [InlineSpan(kind: .footnoteReference(label: string(inner)), range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: inner)]
                case "pass":
                    return [InlineSpan(kind: .escape, range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: inner)]
                case "menu":
                    let content = NSRange(location: name + 1, length: close + 1 - name - 1)
                    return [InlineSpan(kind: .code, range: whole, markers: [NSRange(location: i, length: name + 1 - i)], content: content)]
                default:
                    return [InlineSpan(kind: .code, range: whole, markers: [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: 1)], content: inner)]
                }
            default:
                return nil
            }
        }

        /// An address, with its text in brackets after it or without.
        func address(at i: Int, in range: NSRange, scheme: String) -> [InlineSpan]? {
            let end = range.upperBound
            var j = i + scheme.utf16.count + 1
            if scheme != "mailto" {
                guard j + 1 < end, u[j] == 47, u[j + 1] == 47 else { return nil }
                j += 2
            }
            let start = j
            while j < end, !isWhitespace(u[j]), u[j] != 91, u[j] != 60, u[j] != 62, u[j] != 34 { j += 1 }
            guard j > start else { return nil }
            if j < end, u[j] == 91, let close = closingBracket(from: j + 1, end: end) {
                let url = string(NSRange(location: i, length: j - i))
                let text = NSRange(location: j + 1, length: close - j - 1)
                let whole = NSRange(location: i, length: close + 1 - i)
                if text.length == 0 {
                    return [InlineSpan(kind: .autolink(url: context.substituted(url)), range: whole, markers: [NSRange(location: j, length: 2)], content: NSRange(location: i, length: j - i))]
                }
                var spans = [InlineSpan(kind: .link(destination: context.substituted(url)), range: whole, markers: [NSRange(location: i, length: j + 1 - i), NSRange(location: close, length: 1)], content: text)]
                spans.append(contentsOf: parse(text, lineStart: range.location))
                return spans
            }
            // A bare address ends before punctuation that ends a sentence.
            while j > start, [46, 44, 59, 58, 33, 63, 41, 39].contains(u[j - 1]) {
                if u[j - 1] == 41, string(NSRange(location: i, length: j - i)).filter({ $0 == "(" }).count >= string(NSRange(location: i, length: j - i)).filter({ $0 == ")" }).count { break }
                j -= 1
            }
            let content = NSRange(location: i, length: j - i)
            return [InlineSpan(kind: .autolink(url: string(content)), range: content, markers: [], content: content)]
        }

        func closingBracket(from start: Int, end: Int) -> Int? {
            var depth = 0
            var j = start
            while j < end {
                if u[j] == 92 { j += 2; continue }
                if u[j] == 91 { depth += 1 } else if u[j] == 93 {
                    if depth == 0 { return j }
                    depth -= 1
                }
                j += 1
            }
            return nil
        }

        // MARK: Characters

        func string(_ range: NSRange) -> String {
            String(decoding: u[range.location..<range.upperBound], as: UTF16.self)
        }

        func isWhitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

        func isEscapable(_ c: UInt16) -> Bool {
            [42, 95, 96, 35, 94, 126, 43, 60, 91, 123, 92, 58].contains(c)
        }

        /// A letter, a digit or `_`, as Asciidoctor's `\p{Word}`.
        func isWordCharacter(_ c: UInt16) -> Bool {
            if (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95 { return true }
            guard c > 127, let scalar = UnicodeScalar(c) else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }
}
