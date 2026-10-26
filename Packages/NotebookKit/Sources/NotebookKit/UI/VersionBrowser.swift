#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Browse All Versions… on the Mac and Version History on iPhone and iPad: a note's earlier versions, listed from their
/// names at once, and the one picked, read in the background and shown as it was, or with what changed since then
/// marked in it (Show Changes). Restore puts it in the note as one change Undo takes back.
@MainActor
@Observable
final class VersionBrowser: Identifiable {
    let id = UUID()
    let note: URL
    @ObservationIgnored let history: NoteHistory
    /// The note's text now, for Show Changes.
    @ObservationIgnored private let current: () -> String
    @ObservationIgnored private let restoreAction: (String) -> Void
    /// The versions, newest first; nil until they have been listed.
    private(set) var versions: [NoteHistory.Version]?
    var selection: URL? {
        didSet { if selection != oldValue { read() } }
    }
    /// The picked version's text, once read.
    private(set) var text: String?
    private(set) var isUnreadable = false
    var showsChanges = false {
        didSet { if showsChanges != oldValue { updateChanges() } }
    }
    /// The picked version with what changed since then, while Show Changes is on.
    private(set) var changes: VersionChanges?
    @ObservationIgnored private var reading = 0

    init(note: URL, history: NoteHistory = .shared, current: @escaping () -> String, restore: @escaping (String) -> Void) {
        self.note = note
        self.history = history
        self.current = current
        restoreAction = restore
    }

    var title: String { note.deletingPathExtension().lastPathComponent }
    var selected: NoteHistory.Version? { versions?.first { $0.url == selection } }

    /// Lists the versions, and picks the newest when none is picked.
    func load() async {
        let found = await history.versions(of: note)
        versions = found
        if selection == nil || !found.contains(where: { $0.url == selection }) { selection = found.first?.url }
    }

    private func read() {
        reading += 1
        let attempt = reading
        text = nil
        changes = nil
        isUnreadable = false
        guard let version = selected else { return }
        Task {
            let read = await history.text(of: version)
            guard attempt == reading else { return }
            text = read
            isUnreadable = read == nil
            updateChanges()
        }
    }

    private func updateChanges() {
        changes = showsChanges ? text.map { VersionChanges.between($0, current()) } : nil
    }

    func restore() {
        guard let text else { return }
        restoreAction(text)
    }

    func copyText() {
        guard let text else { return }
        copyToPasteboard(text)
    }

    // MARK: - How versions are named

    struct Day: Identifiable {
        var title: String
        var versions: [NoteHistory.Version]
        var id: String { title }
    }

    /// The versions by day, newest first: Today, Yesterday, then the date.
    var days: [Day] {
        var days: [Day] = []
        for version in versions ?? [] {
            let title = Self.dayTitle(version.date)
            if days.last?.title == title { days[days.count - 1].versions.append(version) } else { days.append(Day(title: title, versions: [version])) }
        }
        return days
    }

    static func dayTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.day().month(.wide).year())
    }

    /// "15:32 · iPhone"
    static func rowTitle(_ version: NoteHistory.Version) -> String {
        version.date.formatted(date: .omitted, time: .shortened) + " · " + version.device
    }

    /// "Saturday, 24 October 2026 at 15:32 · iPhone", under the version's title.
    static func longTitle(_ version: NoteHistory.Version) -> String {
        version.date.formatted(date: .complete, time: .shortened) + " · " + version.device
    }
}
