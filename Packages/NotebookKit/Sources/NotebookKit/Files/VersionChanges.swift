import Foundation

/// What changed between an earlier version of a note and the note now, for Show Changes: the version's text with what
/// was taken out of it since then and what was added, line by line as `Diff3` compares them, and within a line that
/// changed into another, word by word. The lines taken out come first and those added after, as in a diff.
struct VersionChanges: Equatable {
    enum Kind: Equatable { case added, removed }

    /// A stretch of `text` that was added since the version, or taken out. A line's mark covers it with its line break;
    /// a word's only the word.
    struct Mark: Equatable {
        var range: NSRange
        var kind: Kind
        var isLine: Bool
    }

    var text: String
    var marks: [Mark]
    /// How many lines with something on them were added and taken out.
    var addedLines = 0
    var removedLines = 0

    var isEmpty: Bool { marks.isEmpty }

    /// The version as it reads with the changes made since then marked in it.
    static func between(_ version: String, _ now: String) -> VersionChanges {
        let old = Diff3.normalize(version).split(separator: "\n", omittingEmptySubsequences: false)
        let new = Diff3.normalize(now).split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [(text: Substring, kind: Kind?, words: [NSRange])] = []
        var position = 0
        for hunk in Diff3.hunks(base: old, other: new) {
            lines += old[position..<hunk.range.lowerBound].map { ($0, nil, []) }
            let removed = Array(old[hunk.range])
            // A line changed into another: the words that changed in it show too.
            let paired = removed.count == hunk.lines.count
            for (index, line) in removed.enumerated() {
                lines.append((line, .removed, paired ? words(in: line, notIn: hunk.lines[index]) : []))
            }
            for (index, line) in hunk.lines.enumerated() {
                lines.append((line, .added, paired ? words(in: line, notIn: removed[index]) : []))
            }
            position = hunk.range.upperBound
        }
        lines += old[position...].map { ($0, nil, []) }

        var text = ""
        var marks: [Mark] = []
        var counts: [Kind: Int] = [:]
        var offset = 0
        for (index, line) in lines.enumerated() {
            let length = (String(line.text) as NSString).length
            let isLast = index == lines.count - 1
            text += line.text
            if !isLast { text += "\n" }
            if let kind = line.kind {
                if !line.text.allSatisfy(\.isWhitespace) { counts[kind, default: 0] += 1 }
                marks.append(Mark(range: NSRange(location: offset, length: length + (isLast ? 0 : 1)), kind: kind, isLine: true))
                marks += line.words.map { Mark(range: NSRange(location: offset + $0.location, length: $0.length), kind: kind, isLine: false) }
            }
            offset += length + (isLast ? 0 : 1)
        }
        // A version that ended without a line break, where the note now has one, differs by nothing to see.
        return VersionChanges(text: text, marks: marks.filter { !$0.isLine || $0.range.length > 0 },
                              addedLines: counts[.added] ?? 0, removedLines: counts[.removed] ?? 0)
    }

    /// The stretches of `line` that `other` hasn't, by word: nothing when the two have too little in common for that
    /// to help, or are too long to compare quickly.
    static func words(in line: Substring, notIn other: Substring) -> [NSRange] {
        let mine = tokens(line)
        let theirs = tokens(other)
        let n = mine.count, m = theirs.count
        guard n > 0, m > 0, n * m <= 250_000 else { return [] }
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[at(i, j)] = mine[i].text == theirs[j].text ? table[at(i + 1, j + 1)] + 1 : max(table[at(i + 1, j)], table[at(i, j + 1)])
            }
        }
        // Words, not the spaces between them, count for how much the lines share.
        var kept = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if mine[i].text == theirs[j].text {
                kept.insert(i)
                i += 1
                j += 1
            } else if table[at(i + 1, j)] >= table[at(i, j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }
        let words = mine.indices.filter { !mine[$0].isSpace }
        let shared = words.filter(kept.contains).count
        guard !words.isEmpty, Double(shared) / Double(max(words.count, theirs.filter { !$0.isSpace }.count)) >= 0.3 else { return [] }
        var ranges: [NSRange] = []
        for index in mine.indices where !kept.contains(index) {
            let range = mine[index].range
            // Spaces between two changed words join them.
            if let last = ranges.last, last.upperBound == range.location {
                ranges[ranges.count - 1].length += range.length
            } else if !mine[index].isSpace {
                ranges.append(range)
            }
        }
        // A space at the end of a stretch isn't a change of its own.
        return ranges.map { range in
            var range = range
            while range.length > 0, let token = mine.first(where: { $0.range.upperBound == range.upperBound }), token.isSpace {
                range.length -= token.range.length
            }
            return range
        }.filter { $0.length > 0 }
    }

    /// A line in words and the spaces between them, with where each is in it.
    private static func tokens(_ line: Substring) -> [(text: Substring, range: NSRange, isSpace: Bool)] {
        var tokens: [(text: Substring, range: NSRange, isSpace: Bool)] = []
        var start = line.startIndex
        var offset = 0
        while start < line.endIndex {
            let isSpace = line[start].isWhitespace
            var end = line.index(after: start)
            while end < line.endIndex, line[end].isWhitespace == isSpace { end = line.index(after: end) }
            let text = line[start..<end]
            let length = text.utf16.count
            tokens.append((text, NSRange(location: offset, length: length), isSpace))
            offset += length
            start = end
        }
        return tokens
    }
}
