import Foundation

/// What changed between an earlier version of a note and the note now, for Show Changes: the version's text with what
/// was taken out of it since then and what was added, line by line (`lineHunks`), and within a line that changed into
/// another, word by word. The lines taken out come first and those added after, as in a diff. Worked out off the main
/// thread: a long note takes a moment.
struct VersionChanges: Equatable, Sendable {
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
        for hunk in lineHunks(old, new) {
            // Called off: what is worked out isn't shown anyway.
            if Task.isCancelled { break }
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

    /// Where a place in the version is in `text`, after the lines added before it.
    func offset(inChanges versionOffset: Int) -> Int {
        var offset = versionOffset
        for mark in marks where mark.isLine && mark.kind == .added {
            guard mark.range.location <= offset else { break }
            offset += mark.range.length
        }
        return offset
    }

    /// Where a place in `text` is in the version: in a line added since, where that line is.
    func offset(inVersion changesOffset: Int) -> Int {
        var added = 0
        for mark in marks where mark.isLine && mark.kind == .added {
            guard mark.range.location < changesOffset else { break }
            if changesOffset < mark.range.upperBound { return mark.range.location - added }
            added += mark.range.length
        }
        return changesOffset - added
    }

    /// The changes that turn `old` into `new`, as `Diff3`'s hunks: the lines both start and end with set aside, then
    /// Myers' shortest edit for the rest, whose time and room grow with the lines times the changes, not with the lines
    /// squared, so a long note with a few changes shows just those. Past `limit` changes, the lines both have once each
    /// hold the rest together (`anchoredEdit`).
    static func lineHunks(_ old: [Substring], _ new: [Substring], limit: Int = 1000) -> [Diff3.Hunk] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        let n = a.count, m = b.count
        if n == 0, m == 0 { return [] }
        // Lines as numbers, which compare at once.
        var numbers: [Substring: Int] = [:]
        func number(_ line: Substring) -> Int {
            if let known = numbers[line] { return known }
            numbers[line] = numbers.count
            return numbers.count - 1
        }
        let x = a.map(number), y = b.map(number)
        // Past the limit, the lines both have once each hold the rest together (patience): coarser, but right.
        let (removed, added) = shortestEdit(x[...], y[...], limit: limit) ?? anchoredEdit(x, y, limit: limit)
        var hunks: [Diff3.Hunk] = []
        var i = 0, j = 0
        while i < n || j < m {
            guard removed.contains(i) || added.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let start = i, startJ = j
            while (i < n && removed.contains(i)) || (j < m && added.contains(j)) {
                if i < n, removed.contains(i) { i += 1 } else { j += 1 }
            }
            hunks.append(Diff3.Hunk(range: (prefix + start)..<(prefix + i), lines: Array(b[startJ..<j])))
        }
        return hunks
    }

    /// Myers' shortest edit between two runs of lines, as the lines taken out of `x` and put in from `y`, by their
    /// indices there; nil past `limit` changes, or when the comparison is called off.
    private static func shortestEdit(_ x: ArraySlice<Int>, _ y: ArraySlice<Int>, limit: Int) -> (removed: Set<Int>, added: Set<Int>)? {
        let n = x.count, m = y.count
        let x0 = x.startIndex, y0 = y.startIndex
        if n == 0 || m == 0 { return (Set(x.indices), Set(y.indices)) }
        let offset = n + m
        var v = [Int](repeating: 0, count: 2 * offset + 2)
        // What `v` was after each step, between -d and d: what the way back is found from.
        var trace: [[Int]] = []
        var steps: Int?
        search: for d in 0...min(offset, limit) {
            if d % 64 == 0, Task.isCancelled { return nil }
            for k in stride(from: -d, through: d, by: 2) {
                var i = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var j = i - k
                while i < n, j < m, x[x0 + i] == y[y0 + j] {
                    i += 1
                    j += 1
                }
                v[offset + k] = i
                if i >= n, j >= m {
                    trace.append(Array(v[(offset - d)...(offset + d)]))
                    steps = d
                    break search
                }
            }
            trace.append(Array(v[(offset - d)...(offset + d)]))
        }
        guard let steps else { return nil }
        var removed = Set<Int>(), added = Set<Int>()
        var i = n, j = m
        for d in stride(from: steps, to: 0, by: -1) {
            let before = trace[d - 1]
            func at(_ k: Int) -> Int { before[k + d - 1] }
            let k = i - j
            let down = k == -d || (k != d && at(k - 1) < at(k + 1))
            let previousK = down ? k + 1 : k - 1
            let previousI = at(previousK), previousJ = previousI - previousK
            if down { added.insert(y0 + previousJ) } else { removed.insert(x0 + previousI) }
            i = previousI
            j = previousJ
        }
        return (removed, added)
    }

    /// The edit when there are too many changes for the shortest: the lines that come once in each, in the same order
    /// (the longest such run), stay, and the stretches between them get the shortest edit each, or are replaced whole.
    private static func anchoredEdit(_ x: [Int], _ y: [Int], limit: Int) -> (removed: Set<Int>, added: Set<Int>) {
        var counts: [Int: (x: Int, y: Int, j: Int)] = [:]
        for line in x { counts[line, default: (0, 0, 0)].x += 1 }
        for (j, line) in y.enumerated() {
            counts[line, default: (0, 0, 0)].y += 1
            counts[line]?.j = j
        }
        let pairs = x.enumerated().compactMap { i, line -> (i: Int, j: Int)? in
            guard let count = counts[line], count.x == 1, count.y == 1 else { return nil }
            return (i, count.j)
        }
        // The longest run of them in the same order in both.
        var tails: [Int] = [], before = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].j < pair.j { low = middle + 1 } else { high = middle }
            }
            if low > 0 { before[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var anchors: [(i: Int, j: Int)] = []
        var index = tails.last ?? -1
        while index >= 0 {
            anchors.append(pairs[index])
            index = before[index]
        }
        anchors.reverse()
        var removed = Set<Int>(), added = Set<Int>()
        var i = 0, j = 0
        for anchor in anchors + [(x.count, y.count)] {
            let stretchX = x[i..<anchor.i], stretchY = y[j..<anchor.j]
            let edit = shortestEdit(stretchX, stretchY, limit: limit) ?? (Set(stretchX.indices), Set(stretchY.indices))
            removed.formUnion(edit.removed)
            added.formUnion(edit.added)
            i = anchor.i + 1
            j = anchor.j + 1
        }
        return (removed, added)
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
