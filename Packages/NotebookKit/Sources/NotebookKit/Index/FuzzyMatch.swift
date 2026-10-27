import Foundation

/// A name matched to what was typed loosely, as fzf and Spotlight do: its letters in order anywhere in the name, best
/// where they start words and follow each other ("kytr" for "Kyoto trip"), or the word with a letter or two wrong
/// ("ryokna" for "ryokan"). How good a match is goes from 0 to 1, and only good ones are shown with the files; the rest
/// come last, below everything else that was found.
///
/// It reads names folded as the index keeps them, as bytes, through pointers: it runs on every name of a big library
/// for every letter typed, on every core, also in a Debug build, where every call and every checked sum costs.
enum FuzzyMatch {
    /// From here on a loose match is shown with the names that have what was typed in them.
    static let good = 0.75
    /// A loose match's score next to the exact ones' (100 for the whole name down to 30 for every word somewhere in it).
    static func score(_ quality: Double) -> Int { Int(quality * 28) }
    /// The score from which a loose match is a good one.
    static let goodScore = score(good)

    /// How good a word with one letter wrong is, and with two.
    static let oneTypo = 0.82
    static let twoTypos = 0.76
    static func quality(typos: Int) -> Double { typos == 1 ? oneTypo : twoTypos }

    /// How many letters may be wrong in a word of so many letters, as Meilisearch allows: none in one of four or
    /// fewer, where a letter wrong matches too much ("plan" would find Place to stay, "test" Tesla).
    static func typosAllowed(in letters: Int) -> Int { letters >= 9 ? 2 : letters >= 5 ? 1 : 0 }

    /// How many letters there are in folded UTF-8: its bytes but those that continue a letter.
    static func letterCount(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var count = 0
        for byte in bytes where !isContinuation(byte) { count += 1 }
        return count
    }

    /// The second, third or fourth byte of a letter of more than one.
    static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

    // fzf's weights: a letter found, more at the start of a word and after the one before, less for letters skipped.
    private static let letter: Int32 = 16
    private static let gapStart: Int32 = -3
    private static let gapExtension: Int32 = -1
    private static let together: Int32 = 4
    private static let afterSpace: Int32 = 10
    private static let afterMark: Int32 = 9
    private static let letterAndNumber: Int32 = 7
    /// Less for a letter inside a word after letters skipped in words before, which fzf doesn't have: "note" in Nothing
    /// to declare, its "e" deep in another word, is only a bit like it, while "prj" is Project's.
    private static let insideAfterGap: Int32 = -12
    private static let none = Int32.min / 2

    /// Room for working through names up to `length` bytes long, one for each thread.
    struct Scratch {
        let capacity: Int
        fileprivate let rows: UnsafeMutablePointer<Int32>
        /// The letters of a part of a name, for `typos`.
        fileprivate let letters: UnsafeMutablePointer<UInt32>

        init(length: Int) {
            capacity = max(length, 1)
            rows = .allocate(capacity: 4 * (capacity + 1))
            letters = .allocate(capacity: capacity + 1)
        }

        func free() {
            rows.deallocate()
            letters.deallocate()
        }
    }

    /// A word as typos are looked for in names: its letters, as numbers, and its first letter's bytes, which a word of
    /// a name has to start with.
    struct Typed {
        let letters: [UInt32]
        let first: [UInt8]
        let allowed: Int

        init(_ word: UnsafeBufferPointer<UInt8>) {
            var letters = [UInt32](repeating: 0, count: word.count)
            let count = word.baseAddress.map { base in
                letters.withUnsafeMutableBufferPointer { FuzzyMatch.decode(base, count: word.count, into: $0.baseAddress!, limit: word.count) }
            } ?? 0
            self.letters = Array(letters.prefix(count))
            first = Array(word.prefix(word.first.map(FuzzyMatch.length(of:)) ?? 0))
            allowed = FuzzyMatch.typosAllowed(in: count)
        }
    }

    /// How many bytes the letter starting with this byte has.
    static func length(of lead: UInt8) -> Int { lead < 0xC0 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4 }

    /// Up to `limit` letters of folded UTF-8 as numbers, one for each letter whatever its bytes. Says how many.
    static func decode(_ bytes: UnsafePointer<UInt8>, count: Int, into letters: UnsafeMutablePointer<UInt32>, limit: Int) -> Int {
        var i = 0, n = 0
        while i < count, n < limit {
            let lead = bytes[i]
            let length = length(of: lead)
            var value = UInt32(lead)
            var k = 1
            while k < length, i + k < count {
                value = value << 8 | UInt32(bytes[i + k])
                k += 1
            }
            letters[n] = value
            n += 1
            i += length
        }
        return n
    }

    /// How well one word matches `name` loosely: by its letters in order, or with `typos` letters wrong (0 when it
    /// hasn't, or that wasn't looked for). Nil when neither.
    static func quality(_ word: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>, typos: Int, _ scratch: Scratch) -> Double? {
        let found = letters(word, in: name, scratch)
        guard typos > 0 else { return found }
        let typed = quality(typos: typos)
        guard let found else { return typed }
        return found > typed ? found : typed
    }

    /// How well the letters of `word`, in order, are in `name`: 1 when they are its start, together. The best of every
    /// way to find them, as fzf's second algorithm scores it: points for each letter, more at the start of a word and
    /// for letters together, fewer for letters skipped in between.
    static func letters(_ word: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>, _ scratch: Scratch) -> Double? {
        let m = word.count
        guard m > 0, let wordBase = word.baseAddress, let base = name.baseAddress, let start = firstInOrder(word, in: name) else { return nil }
        // Longer names than the room for them are scored by their start, where the letters were found.
        let n = min(name.count, scratch.capacity)
        guard start < n else { return nil }
        // Two rows of scores (a letter of the word found at each byte of the name) and two of the bonus a run of
        // letters found together started with. Nothing is found before the word's first letter.
        var previous = scratch.rows, current = scratch.rows + (n + 1)
        var previousRun = scratch.rows + 2 * (n + 1), currentRun = scratch.rows + 3 * (n + 1)
        var j = start >= 2 ? start - 2 : 0
        while j < start {
            previous[j] = none
            current[j] = none
            j += 1
        }
        var best = none
        var i = 0
        while i < m {
            let wanted = wordBase[i]
            // The same, with only letters of one word skipped: no less for the letter inside it.
            var gapped = none, gappedInWord = none
            best = none
            j = start
            while j < n {
                // The best place for the letter before, with the letters skipped since: `gapped` is for j - 1 and earlier.
                if i > 0, j >= 2 {
                    let extended = gapped &+ gapExtension, started = previous[j &- 2] &+ gapStart
                    gapped = extended > started ? extended : started
                    if isWordByte(base[j &- 1]) {
                        let extendedInWord = gappedInWord &+ gapExtension
                        gappedInWord = extendedInWord > started ? extendedInWord : started
                    } else {
                        gappedInWord = none
                    }
                }
                if base[j] != wanted {
                    current[j] = none
                    j &+= 1
                    continue
                }
                let bonus = bonus(base, j)
                if i > 0, isContinuation(wanted) {
                    // The rest of a letter of more than one byte, straight after its start, never pieced together from
                    // other letters: "日" isn't in "早春", which has its bytes apart.
                    current[j] = j > 0 && previous[j &- 1] > none ? previous[j &- 1] &+ letter &+ together : none
                    currentRun[j] = j > 0 ? previousRun[j &- 1] : 0
                } else if i == 0 {
                    current[j] = letter &+ 2 &* bonus
                    currentRun[j] = bonus
                } else {
                    var afterPrevious = none, run = bonus
                    if j > 0, previous[j &- 1] > none {
                        run = previousRun[j &- 1] > bonus ? previousRun[j &- 1] : bonus
                        afterPrevious = previous[j &- 1] &+ letter &+ (run > together ? run : together)
                    }
                    var afterGap = gapped > none ? gapped &+ letter &+ bonus &+ (bonus == 0 ? insideAfterGap : 0) : none
                    if gappedInWord > none, gappedInWord &+ letter &+ bonus > afterGap { afterGap = gappedInWord &+ letter &+ bonus }
                    if afterPrevious > none, afterPrevious >= afterGap {
                        current[j] = afterPrevious
                        currentRun[j] = run
                    } else {
                        current[j] = afterGap
                        currentRun[j] = bonus
                    }
                }
                if current[j] > best { best = current[j] }
                j &+= 1
            }
            swap(&previous, &current)
            swap(&previousRun, &currentRun)
            i &+= 1
        }
        guard best > none else { return nil }
        // The most it can be: every letter together at the start of the name.
        let most = Double(Int32(m) * (letter + afterSpace) + afterSpace)
        return min(1, max(0, Double(best) / most))
    }

    /// The fewest letters wrong, at most `allowed`, for a word of these `letters` to be the start of the `available`
    /// bytes at `text`: a letter changed, left out, one too many, or two swapped, letter by letter, so a letter of more
    /// than one byte is one. The table of edits is worked out only near its diagonal, as further away there would be
    /// more than `allowed`, and given up once a row has none that few.
    static func typos(_ letters: UnsafeBufferPointer<UInt32>, allowed: Int, at text: UnsafePointer<UInt8>, length available: Int, _ scratch: Scratch) -> Int? {
        let m = letters.count
        guard m > 0, allowed > 0, let w = letters.baseAddress else { return nil }
        // The text's letters: as many as the word's, and those it may have too many.
        let t = UnsafePointer(scratch.letters)
        let length = decode(text, count: available, into: scratch.letters, limit: min(m + allowed, scratch.capacity))
        guard length >= m - allowed, length >= 1 else { return nil }
        let width = length + 1
        guard 3 * width <= 4 * (scratch.capacity + 1) else { return nil }
        let over = Int32(allowed + 1)
        var twoBack = scratch.rows, back = scratch.rows + width, row = scratch.rows + 2 * width
        var j = 0
        while j <= length {
            back[j] = j <= allowed ? Int32(j) : over
            j += 1
        }
        var i = 1
        while i <= m {
            let low = max(1, i - allowed), high = min(length, i + allowed)
            if low > high { return nil }
            row[0] = i <= allowed ? Int32(i) : over
            if low > 1 { row[low - 1] = over }
            if high < length { row[high + 1] = over }
            var smallest = over
            let letter = w[i - 1]
            j = low
            while j <= high {
                var value = back[j - 1] &+ (letter == t[j - 1] ? 0 : 1)
                let left = row[j - 1] &+ 1, up = back[j] &+ 1
                if left < value { value = left }
                if up < value { value = up }
                if i > 1, j > 1, letter == t[j - 2], w[i - 2] == t[j - 1] {
                    let swapped = twoBack[j - 2] &+ 1
                    if swapped < value { value = swapped }
                }
                if value > over { value = over }
                row[j] = value
                if value < smallest { smallest = value }
                j += 1
            }
            if smallest >= over { return nil }
            let oldest = twoBack
            twoBack = back
            back = row
            row = oldest
            i += 1
        }
        // `back` is the last row: the word against every start of the text as long as it, give or take.
        var fewest = over
        j = max(1, m - allowed)
        while j <= length {
            if back[j] < fewest { fewest = back[j] }
            j += 1
        }
        return fewest < over ? Int(fewest) : nil
    }

    /// Whether a word of a name could be the word with letters wrong: it starts at `offset`, and with the word's
    /// whole first letter, which almost always is right.
    static func couldBe(_ first: UnsafeBufferPointer<UInt8>, at offset: Int, in name: UnsafePointer<UInt8>, length: Int) -> Bool {
        guard let firstBase = first.baseAddress, first.count <= length - offset, isWordStart(name, offset) else { return false }
        return memcmp(name + offset, firstBase, first.count) == 0
    }

    /// `typos(_:allowed:at:…)` at each word of `name` that starts with the word's first letter.
    static func typos(_ word: Typed, in name: UnsafeBufferPointer<UInt8>, _ scratch: Scratch) -> Int? {
        guard word.allowed > 0, let lead = word.first.first, let base = name.baseAddress else { return nil }
        return word.letters.withUnsafeBufferPointer { letters in
            word.first.withUnsafeBufferPointer { first in
                var fewest: Int?
                var position = 0
                while position < name.count, let found = memchr(base + position, Int32(lead), name.count - position) {
                    let s = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    position = s + 1
                    guard couldBe(first, at: s, in: base, length: name.count) else { continue }
                    if let wrong = typos(letters, allowed: word.allowed, at: base + s, length: name.count - s, scratch), wrong < (fewest ?? .max) {
                        fewest = wrong
                        if wrong == 1 { break }
                    }
                }
                return fewest
            }
        }
    }

    /// Where the first letter of `word` is in `name` when all its letters are there in order: a quick look, before
    /// scoring the ways they are.
    static func firstInOrder(_ word: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = name.baseAddress else { return nil }
        var position = 0
        var first: Int?
        for byte in word {
            guard position < name.count, let found = memchr(base + position, Int32(byte), name.count - position) else { return nil }
            let at = UnsafeRawPointer(found) - UnsafeRawPointer(base)
            if first == nil { first = at }
            position = at + 1
        }
        return first
    }

    /// Whether a word starts at `j`: the name's start, or after a space or another mark.
    static func isWordStart(_ name: UnsafePointer<UInt8>, _ j: Int) -> Bool {
        j == 0 || !isWordByte(name[j - 1])
    }

    /// How much more a letter found at `j` counts: at the start of the name or after a space most, after other marks
    /// almost as much, where letters turn into numbers or back a little.
    private static func bonus(_ name: UnsafePointer<UInt8>, _ j: Int) -> Int32 {
        guard j > 0 else { return afterSpace }
        let before = name[j - 1], byte = name[j]
        if before == 32 { return afterSpace }
        if !isWordByte(before) { return afterMark }
        if before < 128, byte < 128, isDigit(before) != isDigit(byte) { return letterAndNumber }
        return 0
    }

    /// A letter or number, or part of a letter of more than one byte.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 128 || (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || isDigit(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    // MARK: Strings

    /// How well a folded name matches every word loosely, as well as the word matching worst; 1 for a word in it as it
    /// is. For what is matched a few at a time: ⌘K's commands, tests.
    static func quality(_ words: [String], in name: String) -> Double? {
        var name = name
        return name.withUTF8 { name in
            let scratch = Scratch(length: name.count + 16)
            defer { scratch.free() }
            var worst = 1.0
            for var word in words {
                let quality = word.withUTF8 { word -> Double? in
                    guard let base = name.baseAddress, let wordBase = word.baseAddress, !word.isEmpty else { return nil }
                    if word.count <= name.count, memmem(base, name.count, wordBase, word.count) != nil { return 1 }
                    return self.quality(word, in: name, typos: typos(Typed(word), in: name, scratch) ?? 0, scratch)
                }
                guard let quality else { return nil }
                worst = min(worst, quality)
            }
            return worst
        }
    }
}
