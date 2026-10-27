import Foundation

/// The files to ask "Delete immediately?" about, where a place has no Recently Deleted: one alert at a time, in the
/// order they couldn't go to the Trash. The next one waits until the alert before it has gone, as an alert asked for
/// while another is still going away doesn't show.
struct DeleteQuestions {
    /// The file asked about now.
    private(set) var asking: URL?
    /// The files to ask about next, in order.
    private(set) var waiting: [URL] = []
    /// Alerts answered and still going away.
    private var going = 0

    /// Asks about a file now, or once the question asked now is answered and its alert has gone.
    mutating func ask(_ url: URL) {
        if asking == nil, going == 0 { asking = url } else { waiting.append(url) }
    }

    /// The question about a file answered: its alert starts going away, and `gone()` says when it has.
    mutating func answered(_ url: URL) {
        if asking == url { asking = nil }
        going += 1
    }

    /// An alert answered has gone: the next question, if any.
    mutating func gone() {
        going = max(going - 1, 0)
        if asking == nil, going == 0, !waiting.isEmpty { asking = waiting.removeFirst() }
    }
}
