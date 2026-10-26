import Foundation
import NotebookCapture
import WidgetKit

/// What the widgets show, kept for them in the App Group (`WidgetData`): the to-dos that are overdue, today's and
/// tomorrow's, the notes chosen in Note widgets, and notes to choose from. Written when they change, and the widgets
/// reloaded then; nothing walks the library for it. To-dos ticked in a widget come back here and are written into
/// their notes as To-dos writes them.
extension Workspace {
    /// The most notes Edit Widget offers to choose from, the ones opened last first.
    nonisolated static let widgetCatalogSize = 500

    // MARK: - To-dos

    /// The to-dos and the notes with a reminder that are overdue or due in the coming week: the widget shows the
    /// overdue ones and today's, and moves on by itself at midnight, also on days the app doesn't run.
    func widgetTodoRows(now: Date = .now, calendar: Calendar = .current) -> [WidgetData.TodoRow] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 8, to: start) ?? .distantFuture
        var rows: [WidgetData.TodoRow] = []
        for item in todos.items {
            guard let due = item.todo.due, due.date(in: calendar) < end else { continue }
            rows.append(WidgetData.TodoRow(kind: .todo, text: item.todo.text, path: item.url.path, note: item.note,
                                           line: item.todo.line, source: item.todo.source, due: due.date(in: calendar), hasTime: due.hasTime))
        }
        for reminder in reminders.all {
            guard let date = reminder.date, date < end, let url = url(for: reminder, searching: false) else { continue }
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

    /// Writes the to-dos for the widget when they changed, and reloads it.
    func publishWidgetTodos() {
        guard WidgetData.folder != nil, isStarted else { return }
        let fresh = WidgetData.Todos(rows: widgetTodoRows(), isComplete: todos.isReady)
        guard fresh != WidgetData.todos else { return }
        WidgetData.todos = fresh
        // A tick the to-dos have caught up with is done.
        let ticked = WidgetData.ticked
        let waiting = ticked.filter { tick in fresh.rows.contains { $0.id == tick.id } }
        if waiting.count != ticked.count { WidgetData.ticked = waiting }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.todosKind)
    }

    /// Writes the to-dos ticked in a widget into their notes, once the locations can be written: in the editor that
    /// shows the note, where Undo takes it back, or else in its file, merged with what is there. One that changed
    /// since (its line says something else now) is left as it is.
    func takeWidgetTicks() async {
        guard WidgetData.folder != nil else { return }
        let ticked = WidgetData.ticked
        guard !ticked.isEmpty else { return }
        start()
        await surveyed()
        for tick in ticked where tick.kind == .todo {
            let todo = TodoReference(url: URL(fileURLWithPath: Self.widgetPath(tick.path)), line: tick.line, source: tick.source)
            await setTodoDone(todo, true)?.value
        }
        // What was written shows once the to-dos are read again; a tick that couldn't be is dropped then.
        let left = WidgetData.ticked.filter { tick in !ticked.contains(tick) }
        WidgetData.ticked = left
        publishWidgetTodos()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.todosKind)
    }

    // MARK: - Notes

    /// Writes the notes chosen in Note widgets as they are now, following those renamed or moved, and the notes to
    /// choose from (when the app goes away, not each time files change); reloads the widgets that changed.
    func publishWidgetNotes(catalog: Bool = true) {
        guard WidgetData.folder != nil, isStarted else { return }
        if catalog { publishWidgetCatalog() }
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let ids = (try? result.get())?.compactMap { info -> String? in
                guard info.kind == WidgetData.noteKind else { return nil }
                return info.widgetConfigurationIntent(of: NoteWidgetIntent.self)?.note?.id
            } ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderWidgetNotes(Set(ids)) } }
        }
    }

    private func renderWidgetNotes(_ ids: Set<String>) {
        let kept = WidgetData.notes
        let paths = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.widgetPath(kept[$0]?.path ?? $0)) })
        let places = Dictionary(paths.values.map { ($0, place(of: URL(fileURLWithPath: $0).deletingLastPathComponent())) }) { a, _ in a }
        Task.detached(priority: .utility) {
            var read: [String: WidgetData.Note] = [:]
            for (id, path) in paths {
                let url = URL(fileURLWithPath: path)
                guard let text = NoteDocument.read(url) else {
                    // Gone, or not down from iCloud yet: what it showed stays.
                    if let old = kept[id] { read[id] = old }
                    continue
                }
                read[id] = Self.widgetNote(text, url: url, place: places[path] ?? "")
            }
            let notes = read
            await MainActor.run {
                guard notes != WidgetData.notes else { return }
                WidgetData.notes = notes
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.noteKind)
            }
        }
    }

    /// The notes Edit Widget offers: the ones opened last, the favourites, then the others by when they changed. Put
    /// in order off the main thread: a library can have a hundred thousand.
    private func publishWidgetCatalog() {
        let first = (recents + favorites).map { URL(fileURLWithPath: $0) }.filter { $0.pathExtension == "md" }
            .map { WidgetData.CatalogEntry(path: $0.standardizedFileURL.path, title: SearchSection.displayName($0), place: place(of: $0.deletingLastPathComponent())) }
        let entries = index.byPathSnapshot
        Task.detached(priority: .utility) {
            var seen = Set<String>()
            var catalog: [WidgetData.CatalogEntry] = []
            func add(_ entry: WidgetData.CatalogEntry) {
                guard seen.insert(entry.path).inserted else { return }
                catalog.append(entry)
            }
            first.filter { FileManager.default.fileExists(atPath: $0.path) }.forEach(add)
            let notes = entries.values.filter { $0.kind == .note }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            for entry in notes.prefix(Self.widgetCatalogSize) {
                add(WidgetData.CatalogEntry(path: entry.url.standardizedFileURL.path, title: entry.name, place: entry.place))
            }
            let made = Array(catalog.prefix(Self.widgetCatalogSize))
            if made != WidgetData.catalog { WidgetData.catalog = made }
        }
    }

    /// A note chosen in a widget renamed or moved in Notebook, or the folder it is in: the widget follows it.
    func widgetNoteMoved(from old: URL, to new: URL) {
        guard WidgetData.folder != nil else { return }
        var notes = WidgetData.notes
        let moved = notes.filter { FileNode.isSameOrInside(URL(fileURLWithPath: $0.value.path), old) }
        guard !moved.isEmpty else { return }
        for (id, note) in moved {
            let path = Self.relocated(note.path, from: old.path, to: new.path)
            notes[id]?.path = path
            notes[id]?.title = SearchSection.displayName(URL(fileURLWithPath: path))
        }
        WidgetData.notes = notes
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.noteKind)
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
                    kind = .todo(done: item.checked)
                } else if case .ordered(let number, let delimiter) = item.marker {
                    kind = .ordered("\(number)\(delimiter)")
                } else {
                    kind = .bullet
                }
            case .quote: kind = .quote
            case .paragraph: kind = .text
            default: continue
            }
            let runs = widgetRuns(line, in: string)
            guard !runs.isEmpty else { continue }
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
            defer { index += 1 }
            guard !dropped.contains(index) else { continue }
            let character = string.substring(with: NSRange(location: index, length: 1))
            var run = style(at: index)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.struck == run.struck,
               last.code == run.code, last.highlight == run.highlight, last.link == run.link {
                last.text += character
                runs[runs.count - 1] = last
            } else {
                run.text = character
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

    /// Where a file written down for a widget is now. On iPhone and iPad the app's own folder moves with each update
    /// of the app, and a note kept on the device moves with it: its place in that folder stays the same.
    nonisolated static func widgetPath(_ path: String) -> String {
        #if os(iOS)
        guard !FileManager.default.fileExists(atPath: path), let container = path.range(of: "/Data/Application/"),
              let documents = path.range(of: "/Documents/", range: container.upperBound..<path.endIndex) else { return path }
        let moved = onDeviceFolder.standardizedFileURL.path + "/" + path[documents.upperBound...]
        return FileManager.default.fileExists(atPath: moved) ? moved : path
        #else
        return path
        #endif
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
            let todo = TodoReference(url: URL(fileURLWithPath: Self.widgetPath(path)), line: Int(query["line"] ?? "") ?? 0, source: source)
            openTodo(todo, fromNotification: true)
        case "note":
            guard let id = query["id"] else { return true }
            let path = Self.widgetPath(WidgetData.notes[id]?.path ?? id)
            start()
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
