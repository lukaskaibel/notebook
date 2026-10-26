import SwiftUI

/// To-dos: every open checkbox in your notes and every note with a reminder, by when they are due, as Reminders lists
/// them. Tick one off and it goes a few seconds later; click its words to change them and the lines under it, as
/// Reminders edits a reminder in place, with a line for notes and buttons for its date, time and place coming in under
/// it; click its note's name to open the note there; drag it into another group, or choose a day in its menu, and its
/// date changes in the note.
struct TodosView: View {
    let workspace: Workspace
    /// On the iPad, next to the sidebar: Back and Forward in the bar, as a note has them.
    var isInSplitView = false
    /// Rows just ticked: they stay a moment, ticked, before they go, and a second click unticks them.
    @State private var ticked: [String: (row: TodoRow, section: TodoSection.Kind)] = [:]
    @State private var isDragging = false
    @State private var dropTarget: TodoSection.Kind?
    /// The to-do being edited.
    @State private var editing: TodoEditing?
    /// The to-do just edited, while its buttons go: then its row shows it as it is now.
    @State private var closing: TodoEditing?
    @FocusState private var focus: TodoFocus?
    #if os(iOS)
    /// What shows of the list above the keyboard, and where the to-do being edited is in it.
    @State private var shown: ClosedRange<CGFloat>?
    @State private var editingFrame: CGRect?
    #else
    /// Where the to-do being edited is in the window, and what watches for a click outside it.
    @State private var editingFrame: CGRect?
    @State private var clickWatcher: Any?
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        let sections = shownSections
        let editingRow = rowID(of: editing, in: sections)
        let closingRow = rowID(of: closing, in: sections)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if sections.isEmpty {
                    if workspace.todos.isReady { emptyState }
                } else {
                    ForEach(sections) { section in
                        sectionView(section, editingRow: editingRow, closingRow: closingRow)
                    }
                }
            }
            .frame(maxWidth: Self.width, alignment: .leading)
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.space))
            // A click beside the to-dos is done editing.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { endEditing() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        // The title goes up into the toolbar, as a note's does.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 70 } action: { _, away in
            workspace.todosTitleScrolled(away: away)
        }
        #if os(iOS)
        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            return top...max(top, geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom)
        } action: { _, area in
            shown = area
            reveal(proxy)
        }
        .onChange(of: editingFrame) { reveal(proxy) }
        #endif
        .onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active: if !isDragging { withAnimation(Theme.quick) { isDragging = true } }
            default: withAnimation(Theme.quick) { isDragging = false }
            }
        }
        .onChange(of: focus) { _, new in focusChanged(new) }
        .onChange(of: editing?.focusRequest) { applyFocus() }
        .onChange(of: workspace.todos.items) { _, items in
            // Done, or gone from its note: no longer edited.
            if let editing, !items.contains(where: editing.isEditing) { endEditing() }
        }
        .onDisappear {
            endEditing()
            #if os(macOS)
            watchClicks(false)
            #endif
        }
        .onChange(of: editing?.id) {
            workspace.todoEditing = editing
            #if os(macOS)
            watchClicks(editing != nil)
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.edit)) { note in
            guard let item = note.userInfo?["item"] as? TodoList.Item else { return }
            startEditing(item, at: note.userInfo?["offset"] as? Int)
        }
        .onChange(of: editing?.id) { DebugTodos.session = editing }
        .onChange(of: focus) { _, new in DebugTodos.focus = new }
        #if os(macOS)
        // The debug remote's clicks go to the window, past the watcher.
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.clicked)) { note in
            if let event = note.object as? NSEvent { clicked(event) }
        }
        #endif
        #endif
        #if os(iOS)
        // In the bar once the page's own title has scrolled up under it, as a note's.
        .navigationTitle(workspace.isTitleScrolledAway ? "To-dos" : "")
        .navigationBarTitleDisplayMode(.inline)
        // Reminders' buttons above the keyboard: a date, a time, a place, and sub-to-dos. They come as the editing
        // begins, a moment before the keyboard, fading in as they rise with it; not over the keyboard of a popover's
        // field, which is in this view too.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let shows = editing.map { !$0.isEnded && $0.picking == nil } ?? false
            ZStack {
                if let editing, shows {
                    TodoKeyboardBar(editing: editing, focus: focus) { endEditing() }
                        .transition(.opacity)
                }
            }
            .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2), value: shows)
        }
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
    /// How far each level of the lines under a to-do goes in.
    static let indentStep: CGFloat = 20
    #else
    static let width: CGFloat = 680
    static let margin: CGFloat = 20
    static let sectionSize: CGFloat = 19
    static let titleSize: CGFloat = 17
    static let notesSize: CGFloat = 15
    static let metaSize: CGFloat = 14
    static let indentStep: CGFloat = 24
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

    // MARK: - Editing

    static let space = "todos"

    #if os(iOS)
    /// The to-do being edited above the keyboard and the bar over it, scrolled up only when they cover it.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let editing, let frame = editingFrame, let shown else { return }
        // What shows ends at the bar above the keyboard.
        guard frame.maxY > shown.upperBound - 16 || frame.minY < shown.lowerBound else { return }
        withAnimation(Theme.spring) { proxy.scrollTo(editing.rowID, anchor: UnitPoint(x: 0.5, y: 0.25)) }
    }
    #endif

    /// The row of a to-do being edited or closing, the nearest to its line when its words are in a note twice.
    private func rowID(of session: TodoEditing?, in sections: [TodoSection]) -> String? {
        guard let session else { return nil }
        let items = sections.flatMap(\.rows).compactMap { row -> TodoList.Item? in
            if case .todo(let item) = row, session.shows(item) { item } else { nil }
        }
        return items.min { abs($0.todo.line - session.reference.line) < abs($1.todo.line - session.reference.line) }.map { TodoRow.todo($0).id }
    }

    /// Edits a to-do, the caret this many UTF-16 units into its words, or at their end. Its line for notes and its
    /// buttons come in once it shows (`TodoEditor`).
    private func startEditing(_ item: TodoList.Item, at offset: Int?) {
        if let editing, editing.isEditing(item) { return }
        endEditing(animated: false)
        closing = nil
        let session = TodoEditing(workspace: workspace, item: item)
        session.move(to: .title, caret: offset)
        editing = session
    }

    #if os(macOS)
    /// While a to-do is edited, a click anywhere outside it is done editing: beside the list, on a group's name, in the
    /// sidebar or the toolbar. SwiftUI hands taps on the list's empty parts to nothing.
    private func watchClicks(_ watching: Bool) {
        if let clickWatcher { NSEvent.removeMonitor(clickWatcher) }
        clickWatcher = nil
        guard watching else { return }
        clickWatcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            clicked(event)
            return event
        }
    }

    private func clicked(_ event: NSEvent) {
        // A click in a dropdown is the dropdown's; one beside it closes it and leaves the to-do as it was.
        guard let editing, !editing.isChoosing, let window = event.window, !(window is DropdownPanel),
              let content = window.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if let editingFrame, editingFrame.contains(point) { return }
        // Once the click is handled: on another to-do's words it edits that one, on its circle it ticks it.
        DispatchQueue.main.async {
            if self.editing === editing { endEditing() }
        }
    }
    #endif

    /// The keyboard where the to-do being edited asks for it. A field selects all its words as it gets the keyboard;
    /// after that the caret goes where it was asked.
    private func applyFocus() {
        guard let editing, let wanted = editing.focus else { return }
        focus = wanted
        DispatchQueue.main.async {
            DispatchQueue.main.async { editing.placeCaret(focused: focus) }
        }
    }

    /// Done editing: what was typed is written at once, and the line for notes and the buttons go before the row
    /// shows the to-do as it is now.
    private func endEditing(animated: Bool = true) {
        guard let session = editing else { return }
        guard animated else {
            editing = nil
            focus = nil
            editingFrame = nil
            session.end()
            return
        }
        // All in one animation: the row drawn again for the rest, without one, would take the buttons away at once.
        withAnimation(Theme.spring) {
            editing = nil
            focus = nil
            editingFrame = nil
            closing = session
            session.end()
            session.isExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if closing === session { closing = nil }
        }
    }

    /// The keyboard left the to-do: done editing, unless it went to Remind Me, or to the row made again in another
    /// group, which takes it back at once.
    private func focusChanged(_ new: TodoFocus?) {
        if let new {
            editing?.focus = new
            editing?.focusMoved(to: new)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard focus == nil, let editing, !editing.isChoosing else { return }
            #if os(macOS)
            // A click on something that takes no keyboard leaves it with the window, and so does SwiftUI losing a field
            // it was asked to focus: the to-do keeps it. A click beside the to-dos or on another is done editing.
            if let window = NSApp.windows.first(where: \.isKeyWindow), !(window.firstResponder is NSText), !(window.firstResponder is NSTableView) {
                editing.refocus()
                return
            }
            // Another app or window: editing waits.
            if !NSApp.windows.contains(where: \.isKeyWindow) { return }
            #endif
            endEditing()
        }
    }

    // MARK: - Groups

    private func sectionView(_ section: TodoSection, editingRow: String?, closingRow: String?) -> some View {
        let isTarget = dropTarget == section.kind
        return VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: Self.sectionSize, weight: .semibold))
                .foregroundStyle(section.kind == .overdue ? Color.red : Color.theme(Theme.text))
                .padding(.top, 22)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                // As a click beside the to-dos.
                .onTapGesture { endEditing() }
                .accessibilityAddTraits(.isHeader)
            if section.rows.isEmpty {
                Text(dropHint(section.kind))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.leading, TodoCircle.side + 10)
            }
            ForEach(section.rows.map { TodoSlot(row: $0, editing: $0.id == editingRow ? editing : $0.id == closingRow ? closing : nil) }) { slot in
                TodoRowView(workspace: workspace, row: slot.row, section: section.kind, isTicked: ticked[slot.row.id] != nil,
                            editing: slot.editing, focus: $focus) {
                    tick(slot.row, in: section.kind)
                } edit: { item, offset in
                    startEditing(item, at: offset)
                } endEditing: {
                    endEditing()
                }
                .modifier(TodoDragging(id: Self.dragPrefix + slot.row.id, title: title(of: slot.row), isEnabled: slot.editing == nil))
                .id(slot.id)
                // Ticked, it goes a few seconds later: it fades and the rows under it close up.
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))))
                #if os(iOS)
                .onGeometryChange(for: CGRect?.self) { slot.editing == nil ? nil : $0.frame(in: .named(Self.space)) } action: { frame in
                    if let frame { editingFrame = frame }
                }
                #else
                .onGeometryChange(for: CGRect?.self) { slot.editing == nil ? nil : $0.frame(in: .global) } action: { frame in
                    if let frame, slot.editing?.isEnded == false { editingFrame = frame }
                }
                #endif
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
            // Back to the mark it had: in progress stays in progress.
            if case .todo(let item) = row { workspace.untickTodo(item.reference, to: item.todo.mark) }
            return
        }
        withAnimation(Theme.quick) { ticked[row.id] = (row, section) }
        switch row {
        case .todo(let item):
            // What was typed is written first.
            if let editing, editing.isEditing(item) { endEditing() }
            workspace.setTodoDone(item.reference, true)
        case .note:
            break
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.tickedFor))
            guard ticked[row.id] != nil else { return }
            if case .note(let note) = row { workspace.finishReminder(note.reminder.id) }
            withAnimation(Theme.spring) { ticked[row.id] = nil }
        }
    }

    /// How long a row ticked off stays, ticked, before it goes: time to see it done, or to untick it.
    static let tickedFor: Double = 3

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

/// A row of To-dos as the list lays it out: the row being edited keeps who it was when editing began while its line
/// changes and while it closes, so the keyboard stays in it and its buttons come and go in place.
private struct TodoSlot: Identifiable {
    let row: TodoRow
    let editing: TodoEditing?

    var id: String { editing?.rowID ?? row.id }
}

/// A row is dragged to another group, except while it is edited: then a drag selects words.
private struct TodoDragging: ViewModifier {
    let id: String
    let title: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(id) { TodoDragPreview(title: title) }
        } else {
            content
        }
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

    /// Ticks a line under a to-do in To-dos, or unticks it. One that repeats gets the next one above it, as in a note.
    func toggle(_ line: Int, under item: TodoList.Item) {
        guard item.todo.lines.indices.contains(line), case .todo(let mark) = item.todo.lines[line].kind else { return }
        let before = [item.todo.source] + item.todo.lines.map(\.source)
        var after = before
        guard let marked = Todos.marking(before[line + 1], as: mark.isClosed ? .open : .done, today: .today) else { return }
        after[line + 1] = marked.line
        if let next = marked.next, before[line] != next, before[safe: line + 2] != next { after.insert(next, at: line + 1) }
        changeTodoLines(item.reference, from: before, to: after, actionName: mark.isClosed ? "Uncheck" : "Check")
    }
}

/// A to-do or a reminded note in To-dos: a circle to tick it, its words, the lines under it, and when, where and in
/// which note. A click on a to-do's words edits it in place: the words and lines become fields where they are, and a
/// line for notes and the buttons for its date, time and place come in under them.
struct TodoRowView: View {
    let workspace: Workspace
    let row: TodoRow
    let section: TodoSection.Kind
    let isTicked: Bool
    /// The to-do as it is being edited, while it is.
    let editing: TodoEditing?
    var focus: FocusState<TodoFocus?>.Binding
    var tick: () -> Void
    /// A click on a to-do's words: edit it, the caret this many UTF-16 units in, or at the end.
    var edit: (TodoList.Item, Int?) -> Void
    var endEditing: () -> Void
    @State private var isHovered = false
    @State private var isPicking = false
    @State private var titleWidth: CGFloat = 0

    /// At most this many lines under a to-do show while it isn't edited.
    static let shownLines = 6

    /// How the line for notes and the buttons come in under a to-do being edited, and go.
    static let extra: AnyTransition = .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)).combined(with: .offset(y: -4))

    var body: some View {
        let isExpanded = editing?.isExpanded ?? false
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: tick) {
                TodoCircle(mark: isTicked ? .done : mark)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTicked ? "Done" : "Mark as Done")
            VStack(alignment: .leading, spacing: 3) {
                // The fields take the place of the words and lines where they are, without a fade: they look the same.
                if let editing, case .todo = row {
                    TodoEditor(editing: editing, focus: focus, end: endEditing)
                        .transition(.identity)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        titleText
                        lines
                    }
                    .transition(.identity)
                }
                #if os(macOS)
                if isExpanded, let editing, case .todo(let item) = row {
                    TodoEditBar(workspace: workspace, editing: editing, noteName: item.note) { open() }
                        .padding(.top, 5)
                        .transition(Self.extra)
                } else {
                    meta
                        .transition(.opacity)
                }
                #else
                meta
                    .modifier(TodoPickPopover(editing: editing?.isEnded == false ? editing : nil))
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .onChange(of: isPicking) { _, picking in
                // What was typed is written first; afterwards the keyboard goes back.
                if picking { editing?.commit() } else { editing?.refocus() }
                editing?.isChoosing = picking
            }
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

    private var mark: TaskMark {
        if case .todo(let item) = row { item.todo.mark } else { .open }
    }

    private var title: String {
        switch row {
        case .todo(let item): item.todo.text.isEmpty ? "Untitled To-do" : item.todo.text
        case .note(let note): note.name
        }
    }

    /// The words: a click puts the caret where it was, as in Reminders. A reminded note's name opens it.
    private var titleText: some View {
        Text(title)
            .font(.system(size: TodosView.titleSize))
            .foregroundStyle(isTicked || mark == .cancelled ? Color.theme(Theme.textTertiary) : Color.theme(Theme.text))
            .strikethrough(mark == .cancelled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { point in
                switch row {
                case .todo(let item):
                    // The words read as they are written, unless they have Markdown in them: then the caret goes to the end.
                    let plain = Todos.parts(of: item.todo.source)?.words == item.todo.text
                    edit(item, plain ? TodoText.offset(at: point, in: item.todo.text, width: titleWidth, size: TodosView.titleSize) : nil)
                case .note:
                    open()
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(row.isNote ? "Opens the note" : "Edits the to-do")
    }

    /// The lines under a to-do: sub-to-dos with a circle to tick, points, words.
    @ViewBuilder
    private var lines: some View {
        if case .todo(let item) = row {
            let shown = Array(item.todo.lines.enumerated().filter { $0.element.kind != .blank && $0.element.kind != .other && !$0.element.text.isEmpty })
            ForEach(shown.prefix(Self.shownLines), id: \.offset) { entry in
                TodoLineRow(line: entry.element) {
                    workspace.toggle(entry.offset, under: item)
                }
                .contentShape(.rect)
                .onTapGesture { edit(item, nil) }
            }
            if shown.count > Self.shownLines {
                Text("\(shown.count - Self.shownLines) more")
                    .font(.system(size: TodosView.notesSize))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .onTapGesture { edit(item, nil) }
            }
        }
    }

    /// When (red once it has passed), where, how important, and the note it is in, a link to it.
    private var meta: some View {
        HStack(spacing: 10) {
            if let when {
                Label(when, systemImage: row.hasTime ? "bell.fill" : "calendar")
                    .foregroundStyle(row.isOverdue && !isTicked ? Color.red : Color.theme(Theme.textSecondary))
                    .onTapGesture { ask() }
            }
            if let place = row.place {
                Label(place.leaving ? "Leaving " + place.name : place.name, systemImage: "location.fill")
                    .onTapGesture { ask(.place) }
            }
            if case .todo(let item) = row {
                ForEach(item.todo.fields.filter { [.priority, .repeats, .scheduled, .start].contains($0.kind) }, id: \.self) { field in
                    Label(field.label(), systemImage: field.symbol)
                        .lineLimit(1)
                }
            }
            switch row {
            case .todo(let item):
                TodoNoteLink(name: item.note) { open() }
            case .note:
                TodoNoteLink(name: "Note") { open() }
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
            TodoReminderPicker(workspace: workspace, todo: editing?.current ?? item.reference) { isPicking = false }
        case .note(let note):
            if let url = note.url { ReminderPicker(workspace: workspace, url: url) { isPicking = false } }
        }
    }

    private func ask(_ kind: TodoEditing.Pick = .day) {
        #if os(macOS)
        isPicking = true
        #else
        // Being edited: the popover for what was tapped, as from the bar above the keyboard.
        if let editing, !editing.isEnded { return editing.pick(kind) }
        switch row {
        case .todo(let item): workspace.askForTodoReminder(item.reference)
        case .note(let note): if let url = note.url { workspace.askForReminder(url) }
        }
        #endif
    }

    private func open() {
        endEditing()
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
        if case .todo(let item) = row, !isTicked {
            // Obsidian's `[/]` and `[-]`.
            if item.todo.mark == .inProgress {
                Button { workspace.setTodoMark(item.reference, .open) } label: { Label("Not Started", systemImage: "circle") }
            } else {
                Button { workspace.setTodoMark(item.reference, .inProgress) } label: { Label("Mark as In Progress", systemImage: "circle.righthalf.filled") }
            }
            Button { workspace.setTodoMark(item.reference, .cancelled) } label: { Label("Mark as Cancelled", systemImage: "xmark.circle") }
        }
    }
}

extension TodoRow {
    var isNote: Bool { if case .note = self { true } else { false } }
}

/// A line under a to-do as To-dos shows it: a sub-to-do with a circle to tick, a point, a number, or words.
struct TodoLineRow: View {
    let line: TodoLine
    var toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TodoLineMarker(kind: line.kind, toggle: toggle)
            Text(line.text)
                .font(.system(size: TodosView.notesSize))
                .foregroundStyle(color)
                .strikethrough(line.kind == .todo(.cancelled))
                .lineLimit(line.kind == .text ? 3 : 2)
        }
        .padding(.leading, CGFloat(line.depth - 1) * TodosView.indentStep)
    }

    /// Sub-to-dos as the to-dos they are, points and words as notes.
    private var color: Color {
        switch line.kind {
        case .todo(let mark): mark.isClosed ? Color.theme(Theme.textTertiary) : Color.theme(Theme.text)
        default: Color.theme(Theme.textSecondary)
        }
    }
}

/// What a line under a to-do starts with: a small circle to tick, a bullet or a number; words start with nothing.
struct TodoLineMarker: View {
    let kind: TodoLine.Kind
    var toggle: () -> Void

    var body: some View {
        switch kind {
        case .todo(let mark):
            Button(action: toggle) { TodoCircle(mark: mark, side: TodoCircle.side * 0.78) }
                .buttonStyle(.plain)
                .accessibilityLabel(mark.isClosed ? "Done" : "Mark as Done")
        case .bullet:
            Text("•")
                .font(.system(size: TodosView.notesSize, weight: .bold))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .frame(width: TodoCircle.side * 0.78)
        case .ordered(let number):
            Text(number)
                .font(.system(size: TodosView.notesSize).monospacedDigit())
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .frame(minWidth: TodoCircle.side * 0.78, alignment: .trailing)
        default:
            EmptyView()
        }
    }
}

/// The note a to-do is in, after its date and place: a click opens it, the pointer over it lights it up.
struct TodoNoteLink: View {
    let name: String
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(name, systemImage: "doc.text")
                .labelStyle(TodoMetaLabelStyle())
                .lineLimit(1)
                .foregroundStyle(isHovered ? Color.accentColor : Color.theme(Theme.textTertiary))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(isHovered ? 0.07 : 0), in: .rect(cornerRadius: 5))
                .padding(.horizontal, -5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { isHovered = hovering } }
        #if os(macOS)
        .pointerStyle(.link)
        .help("Open “\(name)”")
        #else
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel("Open \(name)")
    }
}

/// The circle to tick, as the editor draws it: a ring; filled with the accent colour and a tick when done; grey with a
/// cross when cancelled; half filled in progress; with the symbol of another of Obsidian's marks in it.
struct TodoCircle: View {
    let mark: TaskMark
    var side: CGFloat = TodoCircle.side
    /// Counts the ticks: each pops the circle.
    @State private var ticks = 0

    #if os(macOS)
    static let side: CGFloat = 18
    static let lift: CGFloat = 5
    #else
    static let side: CGFloat = 22
    static let lift: CGFloat = 6
    #endif

    var body: some View {
        ZStack {
            switch mark {
            case .done, .cancelled:
                Circle().fill(mark == .done ? Color.accentColor : Color.theme(Theme.faint))
                Image(systemName: mark == .done ? "checkmark" : "xmark")
                    .font(.system(size: side * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            case .inProgress:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                // Its right half filled, as a pie half eaten.
                Circle()
                    .inset(by: 3)
                    .fill(Color.accentColor)
                    .mask(alignment: .trailing) { Rectangle().frame(width: side / 2) }
            default:
                Circle().strokeBorder(Color.theme(Theme.faint), lineWidth: 1.5)
                if let symbol = mark.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.5, weight: .bold))
                        .foregroundStyle(Color.theme(Theme.textSecondary))
                } else if case .other(let character) = mark {
                    Text(String(character))
                        .font(.system(size: side * 0.6, weight: .semibold))
                        .foregroundStyle(Color.theme(Theme.textSecondary))
                }
            }
        }
        .frame(width: side, height: side)
        // Ticked, it pops a little, as Reminders' circles do.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: ticks) { circle, scale in
            circle.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.22, duration: 0.11)
            SpringKeyframe(1, duration: 0.32, spring: .bouncy)
        }
        .onChange(of: mark) { old, new in if new == .done, old != .done { ticks += 1 } }
        .sensoryFeedback(.success, trigger: ticks)
        .contentShape(.circle.inset(by: -6))
        // Centred on the capitals of the line beside it.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.lift * side / Self.side }
        .animation(Theme.quick, value: mark)
        .accessibilityValue(mark.name)
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
            TodoCircle(mark: .open)
            Text(title).font(.system(size: TodosView.titleSize)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }
}

/// Where in some words a click falls.
enum TodoText {
    /// The UTF-16 offset of the caret a click at `point` puts in `text`, laid out `width` wide in the system font, as
    /// a label shows it.
    static func offset(at point: CGPoint, in text: String, width: CGFloat, size: CGFloat) -> Int {
        guard width > 0, !text.isEmpty else { return text.utf16.count }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(text.utf16.count, fraction > 0.5 ? index + 1 : index)
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
