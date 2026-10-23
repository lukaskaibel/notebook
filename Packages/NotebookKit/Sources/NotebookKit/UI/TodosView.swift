import SwiftUI

/// To-dos: every open checkbox in your notes and every note with a reminder, by when they are due, as Reminders lists
/// them. Tick one off and it goes a moment later; click it to open its note there; drag it into another group, or
/// choose a day in its menu, and its date changes in the note.
struct TodosView: View {
    let workspace: Workspace
    /// On the iPad, next to the sidebar: Back and Forward in the bar, as a note has them.
    var isInSplitView = false
    /// Rows just ticked: they stay a moment, ticked, before they go, and a second click unticks them.
    @State private var ticked: [String: (row: TodoRow, section: TodoSection.Kind)] = [:]
    @State private var isDragging = false
    @State private var dropTarget: TodoSection.Kind?

    var body: some View {
        let sections = shownSections
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if sections.isEmpty {
                    if workspace.todos.isReady { emptyState }
                } else {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
            .frame(maxWidth: Self.width, alignment: .leading)
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        // The title goes up into the toolbar, as a note's does.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 70 } action: { _, away in
            workspace.todosTitleScrolled(away: away)
        }
        .onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active: if !isDragging { withAnimation(Theme.quick) { isDragging = true } }
            default: withAnimation(Theme.quick) { isDragging = false }
            }
        }
        #if os(iOS)
        // In the bar once the page's own title has scrolled up under it, as a note's.
        .navigationTitle(workspace.isTitleScrolledAway ? "To-dos" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isInSplitView {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(!workspace.canGoBack)
                    Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                        .disabled(!workspace.canGoForward)
                }
            }
        }
        #endif
    }

    // The sizes of the system's lists on each: Reminders' on the Mac and on iPhone and iPad.
    #if os(macOS)
    static let width: CGFloat = 680
    static let margin: CGFloat = 52
    static let sectionSize: CGFloat = 15
    static let titleSize: CGFloat = 14
    static let notesSize: CGFloat = 12.5
    static let metaSize: CGFloat = 12
    #else
    static let width: CGFloat = 680
    static let margin: CGFloat = 20
    static let sectionSize: CGFloat = 19
    static let titleSize: CGFloat = 17
    static let notesSize: CGFloat = 15
    static let metaSize: CGFloat = 14
    #endif

    // MARK: - What it shows

    private var sections: [TodoSection] {
        _ = workspace.remindersDue
        let notes = workspace.reminders.all.map { reminder in
            let url = workspace.url(for: reminder, searching: false)
            return NoteReminderRow(reminder: reminder, url: url, name: url.map(SearchSection.displayName) ?? reminder.name)
        }
        return TodoGroups.sections(todos: workspace.todos.items, notes: notes)
    }

    /// The groups with rows just ticked kept in theirs, and while a row is dragged, the empty groups it can go to.
    private var shownSections: [TodoSection] {
        var byKind = Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0) })
        for (id, kept) in ticked.sorted(by: { $0.key < $1.key }) where byKind.values.allSatisfy({ !$0.rows.contains { $0.id == id } }) {
            byKind[kept.section, default: TodoSection(kind: kept.section, rows: [])].rows.append(kept.row)
        }
        if isDragging {
            for kind in TodoSection.Kind.allCases where kind != .overdue && byKind[kind] == nil {
                byKind[kind] = TodoSection(kind: kind, rows: [])
            }
        }
        return TodoSection.Kind.allCases.compactMap { byKind[$0] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To-dos")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.theme(Theme.text))
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.theme(Theme.textTertiary))
        }
        #if os(macOS)
        .padding(.top, 44)
        #else
        .padding(.top, 12)
        #endif
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No To-dos", systemImage: "checklist")
        } description: {
            Text("Checkboxes in your notes show here. Give one a date, a time or a place, and Notebook reminds you of it.")
        }
        .padding(.top, 80)
    }

    // MARK: - Groups

    private func sectionView(_ section: TodoSection) -> some View {
        let isTarget = dropTarget == section.kind
        return VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: Self.sectionSize, weight: .semibold))
                .foregroundStyle(section.kind == .overdue ? Color.red : Color.theme(Theme.text))
                .padding(.top, 22)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if section.rows.isEmpty {
                Text(dropHint(section.kind))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.leading, TodoCircle.side + 10)
            }
            ForEach(section.rows) { row in
                TodoRowView(workspace: workspace, row: row, section: section.kind, isTicked: ticked[row.id] != nil) {
                    tick(row, in: section.kind)
                }
                .draggable(Self.dragPrefix + row.id) {
                    TodoDragPreview(title: title(of: row))
                }
                Divider().padding(.leading, TodoCircle.side + 10)
            }
        }
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(isTarget ? 0.1 : 0))
        }
        .padding(.horizontal, -8)
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: section.kind)
        } isTargeted: { targeted in
            guard section.kind != .overdue else { return }
            withAnimation(Theme.quick) { dropTarget = targeted ? section.kind : (dropTarget == section.kind ? nil : dropTarget) }
        }
        .animation(Theme.spring, value: section.rows.map(\.id))
    }

    private func dropHint(_ kind: TodoSection.Kind) -> String {
        switch kind {
        case .someday: "Drop here to take the date away"
        case .week: "Drop here for the day after tomorrow"
        case .later: "Drop here for a week from tomorrow"
        default: "Drop here"
        }
    }

    private func title(of row: TodoRow) -> String {
        switch row {
        case .todo(let item): item.todo.text.isEmpty ? item.note : item.todo.text
        case .note(let note): note.name
        }
    }

    // MARK: - Ticking

    /// Ticks a row: it shows ticked for a moment, then goes. Ticked again meanwhile, it stays.
    private func tick(_ row: TodoRow, in section: TodoSection.Kind) {
        if ticked[row.id] != nil {
            ticked[row.id] = nil
            if case .todo(let item) = row { workspace.setTodoDone(Self.done(item.reference), false) }
            return
        }
        withAnimation(Theme.quick) { ticked[row.id] = (row, section) }
        switch row {
        case .todo(let item): workspace.setTodoDone(item.reference, true)
        case .note: break
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard ticked[row.id] != nil else { return }
            if case .note(let note) = row { workspace.finishReminder(note.reminder.id) }
            withAnimation(Theme.spring) { ticked[row.id] = nil }
        }
    }

    /// The reference of a to-do once ticked: its line then says `[x]`.
    private static func done(_ todo: TodoReference) -> TodoReference {
        var done = todo
        if let range = todo.source.range(of: "[ ]") { done.source.replaceSubrange(range, with: "[x]") }
        return done
    }

    // MARK: - Dragging

    static let dragPrefix = "notebook-todo:"

    private func drop(_ items: [String], into kind: TodoSection.Kind) -> Bool {
        dropTarget = nil
        isDragging = false
        guard let day = TodoSection.day(for: kind) else { return false }
        let rows = sections.flatMap(\.rows)
        var moved = false
        for item in items where item.hasPrefix(Self.dragPrefix) {
            let id = String(item.dropFirst(Self.dragPrefix.count))
            guard let row = rows.first(where: { $0.id == id }), TodoGroups.kind(of: row, now: .now, calendar: .current) != kind else { continue }
            workspace.move(row, to: day)
            moved = true
        }
        return moved
    }
}

extension Workspace {
    /// A row of To-dos to another day (nil: no date), keeping its time and place.
    func move(_ row: TodoRow, to day: Date?) {
        switch row {
        case .todo(let item):
            moveTodo(item.reference, to: day)
        case .note(let note):
            guard let url = note.url else { return beep() }
            guard let day else {
                // A note's reminder needs a time or a place: without a place it keeps its time.
                if let place = note.reminder.place { setReminder(for: url, at: nil, place: place) }
                return
            }
            let calendar = Calendar.current
            let old = note.reminder.date ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            let time = calendar.dateComponents([.hour, .minute], from: old)
            let date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
            setReminder(for: url, at: date, place: note.reminder.place)
        }
    }
}

/// A to-do or a reminded note in To-dos: a circle to tick it, its words, its notes, and when, where and in which note.
struct TodoRowView: View {
    let workspace: Workspace
    let row: TodoRow
    let section: TodoSection.Kind
    let isTicked: Bool
    var tick: () -> Void
    @State private var isHovered = false
    @State private var isPicking = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: tick) {
                TodoCircle(isTicked: isTicked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTicked ? "Done" : "Mark as Done")
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: TodosView.titleSize))
                    .foregroundStyle(isTicked ? Color.theme(Theme.textTertiary) : Color.theme(Theme.text))
                    .fixedSize(horizontal: false, vertical: true)
                if !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: TodosView.notesSize))
                        .foregroundStyle(Color.theme(Theme.textSecondary))
                        .lineLimit(3)
                }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { open() }
            #if os(macOS)
            Button { isPicking = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isPicking ? 1 : 0)
            .help("Remind Me")
            .accessibilityLabel("Remind Me")
            .popover(isPresented: $isPicking, arrowEdge: .trailing) { picker }
            #endif
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch row {
        case .todo(let item): item.todo.text.isEmpty ? "Untitled To-do" : item.todo.text
        case .note(let note): note.name
        }
    }

    private var notes: String {
        guard case .todo(let item) = row else { return "" }
        return item.todo.notes.joined(separator: "\n")
    }

    /// When (red once it has passed), where, and the note it is in.
    private var meta: some View {
        HStack(spacing: 10) {
            if let when {
                Label(when, systemImage: row.hasTime ? "bell.fill" : "calendar")
                    .foregroundStyle(row.isOverdue && !isTicked ? Color.red : Color.theme(Theme.textSecondary))
                    .onTapGesture { ask() }
            }
            if let place = row.place {
                Label(place.leaving ? "Leaving " + place.name : place.name, systemImage: "location.fill")
                    .onTapGesture { ask() }
            }
            switch row {
            case .todo(let item):
                Label(item.note, systemImage: "doc.text")
                    .lineLimit(1)
            case .note:
                Label("Note", systemImage: "doc.text")
            }
        }
        .labelStyle(TodoMetaLabelStyle())
        .font(.system(size: TodosView.metaSize))
        .foregroundStyle(Color.theme(Theme.textTertiary))
    }

    /// The day and time as the group needs them: only the time today and tomorrow, which the group already says.
    private var when: String? {
        guard let date = row.date else { return nil }
        switch section {
        case .today, .tomorrow:
            return row.hasTime ? date.formatted(date: .omitted, time: .shortened) : nil
        default:
            return ReminderText.text(date, time: row.hasTime)
        }
    }

    @ViewBuilder
    private var picker: some View {
        switch row {
        case .todo(let item):
            TodoReminderPicker(workspace: workspace, todo: item.reference) { isPicking = false }
        case .note(let note):
            if let url = note.url { ReminderPicker(workspace: workspace, url: url) { isPicking = false } }
        }
    }

    private func ask() {
        #if os(macOS)
        isPicking = true
        #else
        switch row {
        case .todo(let item): workspace.askForTodoReminder(item.reference)
        case .note(let note): if let url = note.url { workspace.askForReminder(url) }
        }
        #endif
    }

    private func open() {
        switch row {
        case .todo(let item): workspace.openTodo(item.reference)
        case .note(let note):
            if let url = note.url { workspace.open(url) } else { beep() }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button { open() } label: { Label("Open Note", systemImage: "doc.text") }
        Divider()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        Button { workspace.move(row, to: today) } label: { Label("Today", systemImage: "star") }
        Button { workspace.move(row, to: calendar.date(byAdding: .day, value: 1, to: today)) } label: { Label("Tomorrow", systemImage: "sunrise") }
        if let weekend = calendar.nextWeekend(startingAfter: today)?.start {
            Button { workspace.move(row, to: weekend) } label: { Label("This Weekend", systemImage: "sofa") }
        }
        if let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) {
            Button { workspace.move(row, to: monday) } label: { Label("Next Week", systemImage: "calendar") }
        }
        Button { ask() } label: { Label("Remind Me…", systemImage: "bell") }
        if row.date != nil, case .todo = row {
            Button { workspace.move(row, to: nil) } label: { Label("Remove Date", systemImage: "calendar.badge.minus") }
        }
        Divider()
        Button { tick() } label: { Label(isTicked ? "Not Done" : "Mark as Done", systemImage: "checkmark.circle") }
    }
}

/// The circle to tick, as the editor draws it: a ring, or filled with the accent colour and a tick.
struct TodoCircle: View {
    let isTicked: Bool

    #if os(macOS)
    static let side: CGFloat = 18
    static let lift: CGFloat = 5
    #else
    static let side: CGFloat = 22
    static let lift: CGFloat = 6
    #endif

    var body: some View {
        ZStack {
            if isTicked {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: Self.side * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.theme(Theme.faint), lineWidth: 1.5)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(.circle.inset(by: -6))
        // Centred on the capitals of the line beside it.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.lift }
        .animation(Theme.quick, value: isTicked)
    }
}

/// A row's details, each with a small symbol before it.
struct TodoMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// What a dragged row looks like under the pointer.
struct TodoDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            TodoCircle(isTicked: false)
            Text(title).font(.system(size: TodosView.titleSize)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }
}

#if os(iOS)
/// To-dos at the top of the list of folders, with how many are due today or overdue, as Mail counts unread mail.
struct TodosRowLabel: View {
    let count: Int

    var body: some View {
        Label {
            Text("To-dos")
        } icon: {
            Image(systemName: "checklist").foregroundStyle(.tint)
        }
        .badge(count)
        .accessibilityLabel(count > 0 ? "To-dos, \(count) due" : "To-dos")
    }
}
#endif
