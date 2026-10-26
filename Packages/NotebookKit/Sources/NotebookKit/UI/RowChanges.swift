import Foundation

/// The steps that take a list's rows from one order to another, for a list to animate: rows that went fade out, rows
/// that came fade in, and as few rows as can be slide to new places, the others staying where they are among
/// themselves. Each step counts on the rows as the steps before it left them, as `NSOutlineView` does between
/// `beginUpdates` and `endUpdates`.
struct RowChanges<ID: Hashable> {
    enum Step: Equatable {
        case remove(Int)
        /// From one place to another: the row is taken out and put back in at the second.
        case move(Int, Int)
        case insert(Int)
    }

    let steps: [Step]

    /// Nil when it would take more than `limit` steps, for a list to show all at once instead: a folder of thousands
    /// sorted another way.
    init?(from old: [ID], to new: [ID], limit: Int = .max) {
        let newIDs = Set(new)
        let oldIDs = Set(old)
        let gone = old.indices.filter { !newIDs.contains(old[$0]) }
        var rows = old.filter { newIDs.contains($0) }
        // The rows that stay, in their new order. Those in the longest run that is in the old order already stay put;
        // each of the others goes right after the row it follows in the new order, which is in its place by then.
        let kept = new.filter { oldIDs.contains($0) }
        var place: [ID: Int] = [:]
        for (index, id) in rows.enumerated() { place[id] = index }
        let staying = Self.longestRising(kept.map { place[$0] ?? 0 })
        guard gone.count + (new.count - kept.count) + (kept.count - staying.count) <= limit else { return nil }
        var steps = gone.reversed().map { Step.remove($0) }
        for position in kept.indices where !staying.contains(position) {
            let id = kept[position]
            guard let from = rows.firstIndex(of: id) else { continue }
            rows.remove(at: from)
            let to = position == 0 ? 0 : (rows.firstIndex(of: kept[position - 1]) ?? -1) + 1
            rows.insert(id, at: to)
            steps.append(.move(from, to))
        }
        for (index, id) in new.enumerated() where !oldIDs.contains(id) {
            steps.append(.insert(index))
        }
        self.steps = steps
    }

    var count: Int { steps.count }

    /// The places of the longest run of numbers rising from left to right.
    private static func longestRising(_ numbers: [Int]) -> Set<Int> {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: numbers.count)
        for (index, number) in numbers.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if numbers[tails[middle]] < number { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>()
        var index = tails.last ?? -1
        while index >= 0 {
            run.insert(index)
            index = previous[index]
        }
        return run
    }
}
