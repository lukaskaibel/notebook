import Foundation
import NotebookCapture
import WidgetKit

/// What the widgets show, kept for them in the App Group (`WidgetData`): the to-dos that are overdue, today's and
/// the coming week's, the notes chosen in Note widgets, and notes to choose from. Written when they change, one file
/// after another off the main thread, and the widgets reloaded then; nothing walks the library for it. To-dos ticked
/// in a widget come back here and are written into their notes as To-dos writes them.
extension Workspace {
    /// The most notes Edit Widget offers to choose from, the ones opened last first.
    nonisolated static let widgetCatalogSize = 500
    /// The most overdue to-dos the widget is given, the oldest: the others count, but aren't listed.
    nonisolated static let widgetOverdueLimit = 50

    // MARK: - To-dos

    /// The to-dos and the notes with a reminder that are overdue or due in the coming week: the widget shows the
    /// overdue ones and today's, and moves on by itself at midnight, also on days the app doesn't run. None in a folder
    /// you hid, as To-dos leaves them out.
    func widgetTodoRows(now: Date = .now, calendar: Calendar = .current) -> [WidgetData.TodoRow] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 8, to: start) ?? .distantFuture
        let notified = Dictionary(todoJobs().map { ($0.path + "\u{0}\($0.line)\u{0}" + $0.source, $0.identifier) }) { first, _ in first }
        var rows: [WidgetData.TodoRow] = []
        for item in todos.items where !item.isNewAndEmpty {
            guard let due = item.todo.due, due.date(in: calendar) < end else { continue }
            rows.append(WidgetData.TodoRow(kind: .todo, text: item.todo.text, path: item.url.path, note: item.note,
                                           line: item.todo.line, source: item.todo.source, due: due.date(in: calendar), hasTime: due.hasTime,
                                           modified: item.modified?.timeIntervalSinceReferenceDate, notifications: notified[item.id].map { [$0] }))
        }
        for reminder in reminders.all {
            guard let date = reminder.date, date < end, let url = url(for: reminder, searching: false),
                  !SearchIndex.isHidden(url.path, in: index.hiddenPaths) else { continue }
            let name = SearchSection.displayName(url)
            rows.append(WidgetData.TodoRow(kind: .note, text: name, path: url.path, note: name, line: 0,
                                           source: reminder.id.uuidString, due: date, hasTime: true))
        }
        // By when, a day without a time first on its day, as To-dos shows them.
        return rows.enumerated().sorted { a, b in
            let aDay = calendar.startOfDay(for: a.element.due), bDay = calendar.startOfDay(for: b.element.due)
            if aDay != bDay { return aDay < bDay }
            if a.element.hasTime != b.element.hasTime { return !a.element.hasTime }
            if a.element.due != b.element.due { return a.element.due < b.element.due }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The to-dos as the widget is given them: the oldest `widgetOverdueLimit` of the overdue ones, the others counted.
    nonisolated static func widgetTodos(_ rows: [WidgetData.TodoRow], isComplete: Bool, now: Date = .now) -> WidgetData.Todos {
        let overdue = rows.filter { $0.isOverdue(at: now) }
        guard overdue.count > widgetOverdueLimit else { return WidgetData.Todos(rows: rows, isComplete: isComplete) }
        let left = Set(overdue.dropFirst(widgetOverdueLimit).map(\.id))
        return WidgetData.Todos(rows: rows.filter { !left.contains($0.id) }, isComplete: isComplete, overdueLeftOut: left.count)
    }

    /// Writes the to-dos for the widget when they changed, and reloads it. As they change, at midnight and when a
    /// reminder's time comes, and whenever the app comes to the front.
    func publishWidgetTodos() {
        guard WidgetData.folder != nil, isStarted else { return }
        let fresh = Self.widgetTodos(widgetTodoRows(), isComplete: todos.isReady)
        guard fresh != widgets.todos else { return }
        widgets.todos = fresh
        widgets.write(reloading: WidgetData.todosKind) { WidgetData.todos = fresh }
    }

    /// Writes the to-dos ticked in a widget into their notes, once the locations can be written: in the editor that
    /// shows the note, where Undo takes it back, or else in its file, merged with what is there. A tick stays until it
    /// is written: one that can't be now (its file can't be read or written) waits for the next time, and its
    /// notifications stay away meanwhile. One whose to-do is gone or changed since, or whose note is, is dropped,
    /// nothing written over it, and you're told, unless it was done meanwhile somewhere else. Each is forgotten as soon
    /// as it is written, in one step with seeing it is still there: unticked in the widget meanwhile, it is taken back.
    func takeWidgetTicks() async {
        guard WidgetData.folder != nil else { return }
        let ticks = await Task.detached(priority: .userInitiated) { WidgetData.ticks }.value
        widgets.ticks = ticks.map(\.row)
        guard !ticks.isEmpty else { return }
        start()
        await surveyed()
        var notTicked: [String] = []
        for tick in ticks {
            let row = tick.row
            // Unticked in the widget meanwhile.
            guard await Task.detached(priority: .userInitiated, operation: { WidgetData.ticks.contains { $0.row.id == row.id } }).value else { continue }
            let written = row.kind == .todo ? await writeWidgetTick(row) : (.unchanged, nil)
            guard written.outcome != .failed else { continue }
            let wasThere = await Task.detached(priority: .userInitiated) { WidgetData.removeTick(row.id) }.value
            switch written.outcome {
            case .written:
                if !wasThere, let todo = written.todo { await untickTodo(todo, to: Todos.mark(of: row.source) ?? .open)?.value }
            case .notThere:
                if wasThere, !(await isDoneElsewhere(row)) { notTicked.append("“\(row.text)”") }
            case .unchanged, .failed:
                break
            }
        }
        widgets.ticks = await Task.detached(priority: .userInitiated) { WidgetData.ticks.map(\.row) }.value
        if !notTicked.isEmpty {
            let names = ListFormatter.localizedString(byJoining: notTicked)
            reportInFront("Not Ticked", notTicked.count == 1
                          ? "\(names) changed, or its note moved, after you ticked it in the widget, so Notebook left it as it is."
                          : "\(names) changed, or their notes moved, after you ticked them in the widget, so Notebook left them as they are.")
        }
        publishWidgetTodos()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.todosKind)
    }

    /// Ticks a to-do from a widget as To-dos does, and says what became of it, and the to-do it ticked. A to-do that
    /// repeats and was ticked somewhere else meanwhile (the note changed since the widget's to-dos were written, and
    /// next to its line is that to-do ticked) isn't ticked again: when the next one says what it said, it would be
    /// found in its place.
    private func writeWidgetTick(_ row: WidgetData.TodoRow) async -> (outcome: TodoChangeOutcome, todo: TodoReference?) {
        let url = URL(fileURLWithPath: Self.rerooted(row.path))
        let todo = TodoReference(url: url, line: row.line, source: row.source)
        let modified = await Task.detached(priority: .userInitiated) {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSinceReferenceDate
        }.value
        let changed = row.modified.map { seen in modified.map { abs($0 - seen) > 0.000_001 } ?? true } ?? true
        let repeats = Todos.marking(row.source, as: .done, today: .today)?.next != nil
        var task: Task<Void, Never>?
        let outcome = await withCheckedContinuation { continuation in
            task = setTodoDone(todo, true, unless: changed && repeats ? Self.tickedNextTo(row.source) : nil) { continuation.resume(returning: $0) }
        }
        await task?.value
        return (outcome, todo)
    }

    /// Whether a line next to a to-do's is that to-do ticked, as ticking it somewhere else leaves it. Not any done one
    /// with its words: one ticked another day stays next to the one that came after it.
    nonisolated static func tickedNextTo(_ source: String) -> TodoLinesCheck {
        { text, document, index in
            [index - 1, index + 1].contains { Self.isTicked(document.lines[safe: $0], from: source, in: text) }
        }
    }

    /// Whether a to-do ticked in a widget that wasn't there to tick was done meanwhile: its note has it ticked.
    private func isDoneElsewhere(_ row: WidgetData.TodoRow) async -> Bool {
        let url = URL(fileURLWithPath: Self.rerooted(row.path))
        let shown = editorShowing(url)?.text
        return await Task.detached(priority: .utility) {
            guard let text = shown ?? NoteDocument.read(url) else { return false }
            let string = text as NSString
            return MarkdownParser.parse(string).lines.contains { Self.isTicked($0, from: row.source, in: string) }
        }.value
    }

    /// Whether a line is the to-do of `source` done (or cancelled): back to its mark, without the day it was done, it
    /// says exactly what the to-do said.
    nonisolated static func isTicked(_ line: MarkdownLine?, from source: String, in text: NSString) -> Bool {
        guard let line, case .listItem(let item) = line.kind, item.isTask, item.mark.isClosed else { return false }
        return Todos.marking(text.substring(with: line.range), as: Todos.mark(of: source) ?? .open, today: .today)?.line == source
    }

    /// The notifications of to-dos ticked in a widget and not written yet don't come back meanwhile.
    func withoutWidgetTicks(_ jobs: [ReminderNotifications.TodoJob]) -> [ReminderNotifications.TodoJob] {
        guard !widgets.ticks.isEmpty else { return jobs }
        let ticked = widgets.ticks.map { (url: URL(fileURLWithPath: Self.rerooted($0.path)), source: $0.source) }
        return jobs.filter { job in !ticked.contains { $0.source == job.source && FileNode.samePath($0.url, URL(fileURLWithPath: job.path)) } }
    }

    // MARK: - Notes

    /// The notes chosen in widgets as they are now: read from the App Group once, then kept here and written there
    /// whenever they change, with the widgets reloaded.
    var widgetNotes: [String: WidgetData.Note] {
        get {
            if let notes = widgets.notes { return notes }
            let notes = WidgetData.notes
            widgets.notes = notes
            return notes
        }
        set {
            widgets.notes = newValue
            widgets.write(reloading: WidgetData.noteKind) { WidgetData.notes = newValue }
        }
    }

    /// Writes the notes chosen in Note widgets as they are now, following those renamed or moved, and the notes to
    /// choose from (when the app goes away, not each time files change); reloads the widgets that changed.
    func publishWidgetNotes(catalog: Bool = true) {
        guard WidgetData.folder != nil, isStarted else { return }
        if catalog { publishWidgetCatalog() }
        WidgetKeeping.askWidgets { [weak self] chosen in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderWidgetNotes(chosen) } }
        }
    }

    /// Reads the notes chosen (`chosen`, or every one known when the widgets couldn't say), off the main thread, one
    /// reading at a time, and keeps what they say now. A note thrown away, outside the locations or in a folder you hid
    /// shows as such; one that can't be read now (not down from iCloud yet) shows what it showed. Notes no widget shows
    /// any more go.
    func renderWidgetNotes(_ chosen: Set<String>?) {
        guard !widgets.isRendering else {
            widgets.rendersAgain = true
            widgets.chosenNext = chosen
            return
        }
        let kept = widgetNotes
        enum Look: Sendable { case read(place: String, made: Int?), hidden, gone }
        var asked: [String: (kept: String?, path: String, look: Look)] = [:]
        for id in chosen ?? Set(kept.keys) {
            let path = Self.rerooted(kept[id]?.path ?? WidgetData.notePath(id: id))
            let url = URL(fileURLWithPath: path)
            // Gone, then a note at its path again: it must be the one chosen, made when it was, not a new one there.
            let made = kept[id]?.missing == .gone ? WidgetData.noteCreated(id: id) : nil
            let look: Look = SearchIndex.isHidden(path, in: index.hiddenPaths) ? .hidden
                : location(containing: url) == nil ? .gone : .read(place: place(of: url.deletingLastPathComponent()), made: made)
            asked[id] = (kept[id]?.path, path, look)
        }
        widgets.isRendering = true
        let asking = asked
        Task.detached(priority: .utility) { [weak self] in
            var read: [String: WidgetData.Note] = [:]
            for (id, ask) in asking {
                let url = URL(fileURLWithPath: ask.path)
                switch ask.look {
                case .hidden: read[id] = .missing(.hidden, path: ask.path)
                case .gone: read[id] = .missing(.gone, path: ask.path)
                case .read(let place, let made):
                    if let made, let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                       Int(created.timeIntervalSince1970) != made {
                        read[id] = .missing(.gone, path: ask.path)
                    } else if let text = NoteDocument.read(url) {
                        read[id] = Self.widgetNote(text, url: url, place: place)
                    } else if !FileManager.default.fileExists(atPath: ask.path) {
                        read[id] = .missing(.gone, path: ask.path)
                    }
                }
            }
            let notes = read
            await self?.keepWidgetNotes(notes, read: asking.mapValues(\.kept), chosen: chosen)
        }
    }

    /// What was read of the notes chosen, kept: merged with what changed meanwhile, as a note renamed or moved while
    /// it was read is read again where it is now.
    private func keepWidgetNotes(_ notes: [String: WidgetData.Note], read: [String: String?], chosen: Set<String>?) {
        widgets.isRendering = false
        var kept = widgetNotes
        if let chosen { kept = kept.filter { chosen.contains($0.key) } }
        var movedMeanwhile = false
        for (id, path) in read {
            if kept[id] != nil, kept[id]?.path != path {
                movedMeanwhile = true
            } else if let note = notes[id] {
                kept[id] = note
            }
        }
        if kept != widgetNotes { widgetNotes = kept }
        if widgets.rendersAgain {
            widgets.rendersAgain = false
            renderWidgetNotes(widgets.chosenNext)
        } else if movedMeanwhile {
            renderWidgetNotes(chosen)
        }
    }

    /// The notes Edit Widget offers: the ones opened last, the favourites, then the others by when they changed, none
    /// in a folder you hid or outside the locations. Each by its ID (`WidgetData.noteID`). Put in order off the main
    /// thread: a library can have a hundred thousand.
    func publishWidgetCatalog() {
        let first = (recents + favorites).map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { Self.isNote($0) && location(containing: $0) != nil }
            .map { (path: $0.path, title: SearchSection.displayName($0), place: place(of: $0.deletingLastPathComponent())) }
        let entries = index.byPathSnapshot
        let hidden = index.hiddenPaths
        let locations = Set(locations.map(\.id))
        let widgets = widgets
        Task.detached(priority: .utility) {
            var seen = Set<String>()
            var catalog: [WidgetData.CatalogEntry] = []
            func add(_ path: String, title: String, place: String) {
                guard !SearchIndex.isHidden(path, in: hidden), seen.insert(path).inserted,
                      let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey]) else { return }
                catalog.append(WidgetData.CatalogEntry(id: WidgetData.noteID(path: path, created: values.creationDate), path: path, title: title, place: place))
            }
            for note in first where catalog.count < Self.widgetCatalogSize { add(note.path, title: note.title, place: note.place) }
            let notes = entries.values.filter { $0.kind == .note && locations.contains($0.locationID) }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            for entry in notes where catalog.count < Self.widgetCatalogSize {
                add(entry.url.standardizedFileURL.path, title: entry.name, place: entry.place)
            }
            let made = catalog
            widgets.write { if made != WidgetData.catalog { WidgetData.catalog = made } }
        }
    }

    /// A note chosen in a widget renamed or moved in Notebook, or the folder it is in: the widget follows it.
    func widgetNoteMoved(from old: URL, to new: URL) {
        guard WidgetData.folder != nil else { return }
        var notes = widgetNotes
        let moved = notes.filter { FileNode.isSameOrInside(URL(fileURLWithPath: $0.value.path), old) }
        guard !moved.isEmpty else { return }
        for (id, note) in moved {
            let path = Self.relocated(note.path, from: old.path, to: new.path)
            notes[id]?.path = path
            if note.missing == nil { notes[id]?.title = SearchSection.displayName(URL(fileURLWithPath: path)) }
        }
        widgetNotes = notes
    }

    /// A note chosen in a widget thrown away in Notebook, or the folder it is in: the widget says so at once. Put back,
    /// it shows again once it is read.
    func widgetNoteThrownAway(_ url: URL) {
        guard WidgetData.folder != nil else { return }
        var notes = widgetNotes
        for (id, note) in notes where note.missing != .gone && FileNode.isSameOrInside(URL(fileURLWithPath: note.path), url) {
            notes[id] = .missing(.gone, path: note.path)
        }
        if notes != widgetNotes { widgetNotes = notes }
    }

    /// The most lines a widget can show, the largest on an iPad, and how much of a long note is read for them.
    nonisolated static let widgetNoteLines = 40
    nonisolated static let widgetNoteLength = 6000

    /// A note as a widget shows it: its lines with their styles, without front matter, code, tables, maths, pictures
    /// and embeds, and without a first heading that only says its name.
    nonisolated static func widgetNote(_ markdown: String, url: URL, place: String) -> WidgetData.Note {
        let title = url.deletingPathExtension().lastPathComponent
        let start = String(markdown.prefix(widgetNoteLength))
        let document = MarkdownParser.parse(start)
        let string = start as NSString
        var blocks: [WidgetData.Block] = []
        var cut = start.count < markdown.count
        for line in document.lines {
            let kind: WidgetData.Block.Kind
            var depth = 0
            switch line.kind {
            case .heading(let level, _): kind = .heading(level)
            case .listItem(let item):
                depth = item.level
                if item.isTask {
                    kind = .todo(done: item.mark.isClosed)
                } else if case .ordered(let number, let delimiter) = item.marker {
                    kind = .ordered("\(number)\(delimiter)")
                } else {
                    kind = .bullet
                }
            case .quote: kind = .quote
            case .paragraph: kind = .text
            default: continue
            }
            var runs = widgetRuns(line, in: string)
            guard !runs.isEmpty else { continue }
            // Struck through when cancelled, as the editor shows it; done is only grey.
            if case .listItem(let item) = line.kind, item.mark == .cancelled { runs = runs.map { var run = $0; run.struck = true; return run } }
            if blocks.isEmpty, case .heading = kind, SearchIndex.fold(runs.map(\.text).joined()) == SearchIndex.fold(title) { continue }
            guard blocks.count < widgetNoteLines else {
                cut = true
                break
            }
            blocks.append(WidgetData.Block(kind: kind, depth: depth, runs: runs))
        }
        return WidgetData.Note(path: url.path, title: title, place: place, blocks: blocks, isCut: cut)
    }

    /// The words of a line in runs of one style: its Markdown marks, pictures, embeds and a to-do's date and place
    /// left out, as `NotePoints.plain` leaves them, and a link's words kept.
    nonisolated static func widgetRuns(_ line: MarkdownLine, in string: NSString) -> [WidgetData.Run] {
        var dropped = IndexSet()
        for span in line.spans {
            switch span.kind {
            case .image, .embed, .footnoteReference, .todoMark:
                dropped.insert(integersIn: span.range.location..<span.range.upperBound)
            default:
                for marker in span.markers { dropped.insert(integersIn: marker.location..<marker.upperBound) }
            }
        }
        func style(at index: Int) -> WidgetData.Run {
            var run = WidgetData.Run("")
            for span in line.spans where NSLocationInRange(index, span.range) {
                switch span.kind {
                case .strong: run.bold = true
                case .emphasis: run.italic = true
                case .strikethrough: run.struck = true
                case .code: run.code = true
                case .highlight: run.highlight = true
                case .link, .wikiLink, .autolink: run.link = true
                default: break
                }
            }
            return run
        }
        var runs: [WidgetData.Run] = []
        var index = line.content.location
        while index < line.content.upperBound {
            // A character at a time, as you read it: an emoji is two or more units of UTF-16, a flag four.
            let character = string.rangeOfComposedCharacterSequence(at: index)
            defer { index = max(character.upperBound, index + 1) }
            guard !dropped.contains(index) else { continue }
            let text = string.substring(with: NSIntersectionRange(character, NSRange(location: index, length: line.content.upperBound - index)))
            var run = style(at: index)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.struck == run.struck,
               last.code == run.code, last.highlight == run.highlight, last.link == run.link {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                run.text = text
                runs.append(run)
            }
        }
        // Spaces where marks were taken out run together; the line's ends go.
        for index in runs.indices {
            runs[index].text = runs[index].text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        }
        if let first = runs.first { runs[0].text = String(first.text.drop { $0 == " " }) }
        if let last = runs.last { runs[runs.count - 1].text = String(last.text.reversed().drop { $0 == " " }.reversed()) }
        return runs.filter { !$0.text.isEmpty }
    }

    // MARK: - Opening

    /// Opens what a tap in a widget asks for: To-dos, a to-do in its note, or a note chosen in a widget.
    func openFromWidget(_ url: URL) -> Bool {
        // By its components: `URL.path` of "notebook-widget:todos" is empty on iOS.
        guard url.scheme == "notebook-widget", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? []) { a, _ in a }
        switch components.path {
        case "todos":
            start()
            whenSurveyed { [weak self] in self?.showTodos() }
        case "todo":
            guard let path = query["path"], let source = query["source"] else { return true }
            let todo = TodoReference(url: URL(fileURLWithPath: Self.rerooted(path)), line: Int(query["line"] ?? "") ?? 0, source: source)
            openTodo(todo, fromNotification: true)
        case "note":
            guard let id = query["id"] else { return true }
            let note = widgetNotes[id]
            let path = Self.rerooted(note?.path ?? WidgetData.notePath(id: id))
            start()
            // One in a folder you hid stays closed, as the widget doesn't show it.
            guard note?.missing != .hidden else { return true }
            whenSurveyed { [weak self] in
                guard FileManager.default.fileExists(atPath: path) else { return }
                self?.open(URL(fileURLWithPath: path))
            }
        default:
            return false
        }
        return true
    }
}

/// What the app last wrote for the widgets, so it writes only what changed, and the writing: one file after another,
/// in order, off the main thread, each widget reloaded once its file is written.
@MainActor
final class WidgetKeeping {
    /// The to-dos last written.
    var todos: WidgetData.Todos?
    /// The notes chosen in widgets; nil until read from the App Group.
    var notes: [String: WidgetData.Note]?
    /// The to-dos ticked in a widget and not written yet.
    var ticks: [WidgetData.TodoRow] = []
    /// Reading the notes chosen, and asked to read them again once done, for these.
    var isRendering = false
    var rendersAgain = false
    var chosenNext: Set<String>?
    /// The notes shown read again a moment after files changed.
    var refresh: DispatchWorkItem?

    nonisolated private let queue = DispatchQueue(label: "com.lukaskbl.Notebook.widgets", qos: .utility)

    /// Asks the Note widgets which notes they show, by their IDs: nil when they can't say, and then none of the notes
    /// goes. Tests answer for them.
    nonisolated(unsafe) static var askWidgets: @Sendable (@escaping @Sendable (Set<String>?) -> Void) -> Void = { answer in
        WidgetCenter.shared.getCurrentConfigurations { result in
            answer((try? result.get()).map { infos in
                Set(infos.compactMap { info -> String? in
                    guard info.kind == WidgetData.noteKind else { return nil }
                    return info.widgetConfigurationIntent(of: NoteWidgetIntent.self)?.note?.id
                })
            })
        }
    }

    nonisolated func write(reloading kind: String? = nil, _ work: @escaping @Sendable () -> Void) {
        queue.async {
            work()
            guard let kind else { return }
            DispatchQueue.main.async { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
    }

    /// Waits until what was given to write is written.
    nonisolated func written() {
        queue.sync {}
    }
}
