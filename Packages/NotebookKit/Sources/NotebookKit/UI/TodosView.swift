import SwiftUI

/// To-dos: every open checkbox in your notes and every note with a reminder, by when they are due, as Reminders lists
/// them. Tick one off and it goes a few seconds later; click its words to change them and the lines under it, as
/// Reminders edits a reminder in place, with a line for notes and buttons for its date, time and place coming in under
/// it; click its note's name to open the note there; drag it into another group, or choose a day in its menu, and its
/// date changes in the note. New To-do at the end of a group, or in the toolbar for today, adds one in no note
/// (`LooseTodos`), which Move to Note… puts into a note later.
struct TodosView: View {
    let workspace: Workspace
    /// On the iPad, next to the sidebar: Back and Forward in the bar, as a note has them.
    var isInSplitView = false
    /// Rows just ticked: they stay a moment, ticked, where they were, before they go, and a second click unticks them.
    /// With the rows of their group as they were then, to keep their place.
    @State private var ticked: [String: (row: TodoRow, section: TodoSection.Kind, order: [String])] = [:]
    @State private var isDragging = false
    /// The parts of groups a row is dragged over: a group lights up while one of its parts is.
    @State private var dropTargets: [String: TodoSection.Kind] = [:]
    /// The to-do being edited.
    @State private var editing: TodoEditing?
    /// The to-do just edited, while its buttons go: then its row shows it as it is now.
    @State private var closing: TodoEditing?
    @FocusState private var focus: TodoFocus?
    #if os(iOS)
    /// What shows of the list above the keyboard, and where the to-do being edited is in it.
    @State private var shown: ClosedRange<CGFloat>?
    @State private var editingFrame: CGRect?
    /// The row swiped to show Delete: one at a time.
    @State private var swiped: String?
    /// The text size of Settings: the rows are made again at the new size when it changes.
    @Environment(\.dynamicTypeSize) private var typeSize
    #else
    /// Where the to-do being edited is in the window, and what watches for a click outside it.
    @State private var editingFrame: CGRect?
    @State private var clickWatcher: Any?
    /// The row selected, as in Reminders: by a click beside a to-do's words, or left so by Return or Escape. Delete
    /// deletes it, Return edits it, ↑ and ↓ select the next.
    @State private var selected: String?
    @FocusState private var isListFocused: Bool
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            #if os(iOS)
            touch(list(proxy), proxy: proxy)
            #else
            list(proxy)
            #endif
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        let sections = shownSections
        let editingRow = rowID(of: editing, in: sections)
        let closingRow = rowID(of: closing, in: sections)
        return ScrollView {
            // Lazy: of hundreds of to-dos only those that show are made. A group's name, its rows and its New To-do are
            // rows of the list side by side, not a group of their own, which would be made whole.
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if sections.isEmpty {
                    if workspace.todos.isReady { emptyState(proxy) }
                } else {
                    ForEach(sections) { section in
                        sectionTitle(section)
                        ForEach(section.rows.map { TodoSlot(row: $0, editing: $0.id == editingRow ? editing : $0.id == closingRow ? closing : nil) }) { slot in
                            rowView(slot, in: section, proxy: proxy)
                        }
                        if section.kind != .overdue, !section.rows.isEmpty {
                            NewTodoButton(section: section) { newTodo(in: section.kind, proxy: proxy) }
                                .modifier(part(section.kind, id: "new", last: true))
                        }
                    }
                }
            }
            .animation(Theme.spring, value: sections.map { $0.rows.map(\.id) })
            .frame(maxWidth: Self.width, alignment: .leading)
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.space))
            #if os(iOS)
            .id(typeSize)
            #endif
            // A click beside the to-dos is done editing.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { endEditing() }
            }
            #if os(macOS)
            .focusable(interactions: .edit)
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { listKey($0, proxy) }
            .onDeleteCommand { deleteSelected() }
            .onChange(of: isListFocused) { _, focused in
                if !focused, focus == nil { selected = nil }
            }
            #endif
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
        .onChange(of: focus) { _, new in focusChanged(new) }
        .onChange(of: editing?.focusRequest) { applyFocus() }
        // New To-do in the toolbar: one for today.
        .onChange(of: workspace.newTodoRequest) { newTodo(in: .today, proxy: proxy) }
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
            #else
            // Done editing: Shake to Undo and ⌘Z reach the to-dos' changes, unless something else is typed in now.
            if editing == nil { workspace.takeUndoFocusIfFree() }
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.edit)) { note in
            guard let item = note.userInfo?["item"] as? TodoList.Item else { return }
            startEditing(item, at: note.userInfo?["offset"] as? Int)
        }
        .onChange(of: editing?.id) { DebugTodos.session = editing }
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.new)) { note in
            if let kind = note.object as? TodoSection.Kind { newTodo(in: kind, proxy: proxy) }
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.key)) { note in
            if note.object as? String == "return" { returned(proxy) } else { endEditing(selecting: true) }
        }
        .onChange(of: focus) { _, new in DebugTodos.focus = new }
        #if os(macOS)
        // The debug remote's clicks go to the window, past the watcher.
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.clicked)) { note in
            if let event = note.object as? NSEvent { clicked(event) }
        }
        #endif
        #endif
    }

    #if os(iOS)
    /// What the list has on iPhone and iPad: the bar above the keyboard, New To-do at the bottom, Shake to Undo, and
    /// scrolling to the to-do being edited. Apart from `list`, for the compiler to take in.
    private func touch(_ list: some View, proxy: ScrollViewProxy) -> some View {
        list
        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
            // The container is what shows between the bars, and above the keyboard: its insets are already left out.
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            return top...top + max(0, geometry.containerSize.height)
        } action: { _, area in
            shown = area
            reveal(proxy)
        }
        .onChange(of: editingFrame) { reveal(proxy) }
        // Scrolled, a row swiped open closes, as in Reminders.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
            if swiped != nil, abs(new - old) > 1 { swiped = nil }
        }
        // ⌘K closed, after Move to Note… say: Shake to Undo takes the focus, once its field, going with it, has let go.
        .onChange(of: workspace.palette == nil) { _, closed in
            guard closed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if editing == nil { workspace.takeUndoFocusIfFree() }
            }
        }
        // In the bar once the page's own title has scrolled up under it, as a note's.
        .navigationTitle(workspace.isTitleScrolledAway ? "To-dos" : "")
        .navigationBarTitleDisplayMode(.inline)
        // Shaken, Undo, as in Reminders: nothing in To-dos takes the focus but a to-do being edited.
        .onAppear { workspace.takeUndoFocusIfFree() }
        // Reminders' buttons above the keyboard: a date, a time, a place, and sub-to-dos. They come as the editing
        // begins, a moment before the keyboard, fading in as they rise with it. A date, a time or a place is typed in
        // the bar too, its choices over the list.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let shows = editing.map { !$0.isEnded } ?? false
            ZStack {
                if let editing, shows {
                    TodoKeyboardBar(editing: editing, focus: focus, room: pickerRoom) { endEditing() }
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
            // Reminders' New Reminder: at the bottom, on the left, its words with it.
            ToolbarItem(placement: .bottomBar) {
                // Side by side, not a Label: a bar shows a Label's symbol alone.
                Button { newTodo(in: .today, proxy: proxy) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("New To-do")
                    }
                    .font(.body.weight(.semibold))
                }
                .tint(Color.theme(Theme.accent))
                .accessibilityLabel("New To-do")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        // While a to-do is edited, the bar above the keyboard has its buttons, as in Reminders.
        .toolbar(editing == nil ? .automatic : .hidden, for: .bottomBar)
    }
    #endif

    // The sizes of the system's lists on each: Reminders' on the Mac and on iPhone and iPad, where they grow with the
    // text size of Settings, as Reminders' do.
    #if os(macOS)
    static let width: CGFloat = 680
    static let margin: CGFloat = 52
    static let sectionSize: CGFloat = 15
    static let titleSize: CGFloat = 14
    static let notesSize: CGFloat = 12.5
    static let metaSize: CGFloat = 12
    static let headerSize: CGFloat = 30
    static let dateSize: CGFloat = 12.5
    /// How far each level of the lines under a to-do goes in.
    static let indentStep: CGFloat = 20
    #else
    static let width: CGFloat = 680
    static let margin: CGFloat = 20
    static var sectionSize: CGFloat { scaled(19, .title3) }
    static var titleSize: CGFloat { scaled(17, .body) }
    static var notesSize: CGFloat { scaled(15, .subheadline) }
    static var metaSize: CGFloat { scaled(14, .footnote) }
    static var headerSize: CGFloat { scaled(30, .largeTitle) }
    static var dateSize: CGFloat { scaled(12.5, .footnote) }
    static var indentStep: CGFloat { scaled(24, .body) }

    /// A size at the standard text size, at the text size chosen in Settings.
    static func scaled(_ size: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        return UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits)
    }
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
            TodoGroups.keep(kept.row, in: &byKind[kept.section, default: TodoSection(kind: kept.section, rows: [])].rows, order: kept.order)
        }
        if isDragging {
            for kind in TodoSection.Kind.allCases where kind != .overdue && byKind[kind] == nil {
                byKind[kind] = TodoSection(kind: kind, rows: [])
            }
        }
        // The to-do being edited stays where it was while it is, as in Reminders: a day set from its buttons moves it
        // into its group once it is done, and the list doesn't move under the keyboard meanwhile. One just added stays
        // at the end of its group, where New To-do was.
        if let editing, let home = editing.home, let id = rowID(of: editing, in: Array(byKind.values)) {
            var edited: TodoRow?
            for kind in Array(byKind.keys) {
                guard let index = byKind[kind]?.rows.firstIndex(where: { $0.id == id }) else { continue }
                edited = byKind[kind]?.rows.remove(at: index)
                if byKind[kind]?.rows.isEmpty == true, !isDragging { byKind[kind] = nil }
            }
            if let edited {
                var rows = byKind[home.kind]?.rows ?? []
                if editing.added != nil {
                    rows.append(edited)
                } else {
                    // After the row that was above it then: its own id changes with its line.
                    let ids = rows.map(\.id)
                    let above = home.order.prefix { $0 != editing.rowID }.reversed().lazy.compactMap { ids.firstIndex(of: $0) }.first
                    rows.insert(edited, at: above.map { $0 + 1 } ?? 0)
                }
                byKind[home.kind] = TodoSection(kind: home.kind, rows: rows)
            }
        }
        return TodoSection.Kind.allCases.compactMap { byKind[$0] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To-dos")
                .font(.system(size: Self.headerSize, weight: .bold))
                .foregroundStyle(Color.theme(Theme.text))
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: Self.dateSize))
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

    private func emptyState(_ proxy: ScrollViewProxy) -> some View {
        ContentUnavailableView {
            Label("No To-dos", systemImage: "checklist")
        } description: {
            Text("Checkboxes in your notes show here, and to-dos you add here. Give one a date, a time or a place, and Notebook reminds you of it.")
        } actions: {
            Button("New To-do") { newTodo(in: .today, proxy: proxy) }
        }
        .padding(.top, 80)
    }

    // MARK: - Editing

    static let space = "todos"

    #if os(iOS)
    /// The to-do being edited above the keyboard and the bar over it, scrolled up only when they cover it.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let editing, let frame = editingFrame, let shown else { return }
        // What shows ends at the bar above the keyboard. Scrolled into sight, the row is further in than it needs to
        // be, so it isn't scrolled again by a fraction of a point.
        let gap: CGFloat = 16
        let covered = frame.maxY > shown.upperBound - gap / 2 || frame.minY < shown.lowerBound
        #if DEBUG
        DebugTodos.trace("reveal frame \(frame.minY)...\(frame.maxY) shown \(shown) covered \(covered)")
        #endif
        guard covered else { return }
        // As little as it takes, as the keyboard scrolls a field into sight: its bottom a little above the bar, or its
        // top a little under the top. A point at the same part of the row and of what shows meets there.
        let room = shown.upperBound - shown.lowerBound - frame.height
        let part = room <= gap ? 0 : frame.minY < shown.lowerBound ? gap / room : (room - gap) / room
        withAnimation(Theme.spring) { proxy.scrollTo(editing.rowID, anchor: UnitPoint(x: 0.5, y: part)) }
    }

    /// How tall the choices of a picker above the keyboard can be: up to the to-do being edited, so it stays in sight,
    /// unless that leaves too little room; never higher than the list.
    private var pickerRoom: CGFloat {
        guard let shown else { return 300 }
        // The choices start a gap above the bar.
        let bottom = shown.upperBound - 10
        let full = bottom - shown.lowerBound - 12
        guard let frame = editingFrame else { return full }
        return min(full, max(240, bottom - frame.maxY - 12))
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
    private func startEditing(_ item: TodoList.Item, at offset: Int?, added: TodoSection.Kind? = nil) {
        #if os(macOS)
        selected = nil
        #endif
        if let editing, editing.isEditing(item) { return }
        endEditing(animated: false)
        closing = nil
        let session = TodoEditing(workspace: workspace, item: item)
        session.added = added
        if let added {
            session.home = (added, [])
        } else if let section = shownSections.first(where: { $0.rows.contains { $0.id == TodoRow.todo(item).id } }) {
            session.home = (section.kind, section.rows.map(\.id))
        }
        session.move(to: .title, caret: offset)
        editing = session
    }

    /// New To-do: a to-do in no note at the end of a group, due as the group says, to type in, as Reminders' New
    /// Reminder. It comes into view first: a row that doesn't show isn't made, nor is its field.
    private func newTodo(in kind: TodoSection.Kind, proxy: ScrollViewProxy) {
        guard let day = TodoSection.day(for: kind) else { return }
        endEditing(animated: false)
        #if os(iOS)
        swiped = nil
        #endif
        guard let item = workspace.addTodo(due: day) else { return }
        startEditing(item, at: nil, added: kind)
        DispatchQueue.main.async {
            withAnimation(Theme.spring) { proxy.scrollTo(item.id, anchor: UnitPoint(x: 0.5, y: 0.6)) }
        }
    }

    /// Return in a to-do's words: done, and on the Mac it stays selected. In one just added, with words, the next comes
    /// under it.
    private func returned(_ proxy: ScrollViewProxy) {
        guard let session = editing, let added = session.added, !session.isEmpty else { return endEditing(selecting: true) }
        endEditing(animated: false)
        newTodo(in: added, proxy: proxy)
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
    /// shows the to-do as it is now. `selecting`: on the Mac the row is selected then.
    private func endEditing(animated: Bool = true, selecting: Bool = false) {
        guard let session = editing else { return }
        // A to-do just added and left without words goes again, as in Reminders; with words, Undo takes it away.
        if session.added != nil {
            guard !session.isEmpty else {
                withAnimation(animated ? Theme.spring : nil) {
                    editing = nil
                    focus = nil
                    editingFrame = nil
                    session.end()
                    workspace.dropNewTodo(session.current)
                }
                return
            }
            session.end()
            workspace.keepNewTodo(session.current)
        }
        #if os(macOS)
        if selecting {
            DispatchQueue.main.async {
                selected = rowID(of: session, in: shownSections)
                if selected != nil { isListFocused = true }
            }
        }
        #endif
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
            editing?.hasHadKeyboard = true
            // Back from the picker above the keyboard: it goes now that the to-do has the keyboard.
            editing?.closePicker()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard focus == nil, let editing, !editing.isChoosing else { return }
            // Its row is still coming: the keyboard goes there once it is.
            guard editing.hasHadKeyboard else { return editing.refocus() }
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

    /// A group's name, and while a row is dragged and the group is empty, what dropping it there does.
    private func sectionTitle(_ section: TodoSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
        }
        .modifier(part(section.kind, id: "title", first: true, last: section.rows.isEmpty))
    }

    private func rowView(_ slot: TodoSlot, in section: TodoSection, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TodoRowView(workspace: workspace, row: slot.row, section: section.kind, isTicked: ticked[slot.row.id] != nil,
                        editing: slot.editing, focus: $focus) {
                tick(slot.row, in: section.kind)
            } edit: { item, offset in
                startEditing(item, at: offset)
            } endEditing: {
                // Escape: on the Mac the row stays selected.
                endEditing(selecting: true)
            } returned: {
                returned(proxy)
            } delete: {
                delete(slot.row)
            }
            #if os(iOS)
            .modifier(TodoSwipe(id: slot.row.id, swiped: $swiped, isEnabled: slot.editing == nil && slot.row.isTodo && ticked[slot.row.id] == nil) {
                delete(slot.row)
            })
            #endif
            .modifier(TodoDragging(id: Self.dragPrefix + slot.row.id, title: title(of: slot.row), isEnabled: slot.editing == nil))
            #if os(macOS)
            .background {
                if selected == slot.row.id, slot.editing == nil {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isListFocused ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07))
                        .padding(.horizontal, -8)
                }
            }
            // A click beside its words selects it; beside the fields of one being edited, it stays edited.
            .onTapGesture { if slot.editing == nil { select(slot.row) } }
            #endif
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
        .id(slot.id)
        // Ticked, it goes a few seconds later: it fades and the rows under it close up.
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))))
        .modifier(part(section.kind, id: slot.id, last: section.kind == .overdue && slot.row.id == section.rows.last?.id))
    }

    /// A part of a group: a to-do dragged onto it goes into the group, and the group lights up while it is over it.
    private func part(_ kind: TodoSection.Kind, id: String, first: Bool = false, last: Bool = false) -> TodoGroupPart {
        let key = "\(kind.rawValue)\u{0}" + id
        return TodoGroupPart(isTarget: dropTargets.values.contains(kind), first: first, last: last) { items in
            drop(items, into: kind)
        } targeted: { targeted in
            guard kind != .overdue else { return }
            withAnimation(Theme.quick) { dropTargets[key] = targeted ? kind : nil }
        }
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
        case .todo(let item): item.todo.text.isEmpty ? (item.isLoose ? "To-do" : item.note) : item.todo.text
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
        let order = shownSections.first { $0.kind == section }?.rows.map(\.id) ?? []
        withAnimation(Theme.quick) { ticked[row.id] = (row, section, order) }
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

    // MARK: - Deleting

    /// Deletes a to-do from its note, with the lines under it: its row goes at once. What was typed in it is written
    /// first, so the line deleted is the line as it is now.
    private func delete(_ row: TodoRow) {
        guard case .todo(let item) = row else { return }
        if let editing, editing.isEditing(item) { endEditing(animated: false) }
        #if os(iOS)
        if swiped == row.id { swiped = nil }
        #endif
        ticked[row.id] = nil
        withAnimation(Theme.spring) { _ = workspace.deleteTodo(item.reference) }
    }

    #if os(macOS)
    // MARK: - The row selected

    private func select(_ row: TodoRow?) {
        endEditing()
        selected = row?.id
        if row != nil { isListFocused = true }
    }

    private func deleteSelected() {
        guard editing == nil, let selected, let row = shownSections.flatMap(\.rows).first(where: { $0.id == selected }), row.isTodo else { return beep() }
        // The one after it is selected next, as in Reminders.
        let rows = shownSections.flatMap(\.rows).filter(\.isTodo)
        let index = rows.firstIndex { $0.id == selected } ?? 0
        let next = rows[safe: index + 1] ?? rows[safe: index - 1]
        delete(row)
        self.selected = next?.id
    }

    /// The keys of the row selected; the keys of a to-do being edited are its fields'.
    private func listKey(_ press: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard editing == nil, let selected else { return .ignored }
        let rows = shownSections.flatMap(\.rows)
        guard let index = rows.firstIndex(where: { $0.id == selected }) else {
            self.selected = nil
            return .ignored
        }
        switch press.key {
        // Delete comes as U+007F on the Mac.
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
            deleteSelected()
        case .upArrow, .downArrow:
            guard let next = rows[safe: index + (press.key == .upArrow ? -1 : 1)] else { return .handled }
            withAnimation(Theme.quick) { self.selected = next.id }
            proxy.scrollTo(next.id)
        case .return:
            guard case .todo(let item) = rows[index] else { return .ignored }
            startEditing(item, at: nil)
        case .escape:
            withAnimation(Theme.quick) { self.selected = nil }
        default:
            return .ignored
        }
        return .handled
    }
    #endif

    // MARK: - Dragging

    static let dragPrefix = "notebook-todo:"

    private func drop(_ items: [String], into kind: TodoSection.Kind) -> Bool {
        dropTargets = [:]
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

/// A part of a group in To-dos: its name, a row, or its New To-do. A to-do dropped on any of them goes into the group,
/// and while one is dragged over a part, the whole group lights up, as one rounded panel.
private struct TodoGroupPart: ViewModifier {
    let isTarget: Bool
    let first: Bool
    let last: Bool
    let drop: ([String]) -> Bool
    let targeted: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: first ? 10 : 0, bottomLeadingRadius: last ? 10 : 0,
                                       bottomTrailingRadius: last ? 10 : 0, topTrailingRadius: first ? 10 : 0)
                    .fill(Color.accentColor.opacity(isTarget ? 0.1 : 0))
            }
            .padding(.horizontal, -8)
            .dropDestination(for: String.self) { items, _ in
                drop(items)
            } isTargeted: { targeted($0) }
    }
}

/// New To-do at the end of a group, as Reminders adds a reminder on a day: quiet until pointed at.
private struct NewTodoButton: View {
    let section: TodoSection
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: TodosView.titleSize * 0.85, weight: .medium))
                    .frame(width: TodoCircle.side)
                Text("New To-do")
                    .font(.system(size: TodosView.titleSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(isHovered ? Color.accentColor : Color.theme(Theme.textTertiary))
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { isHovered = hovering } }
        .accessibilityLabel("New To-do in \(section.title)")
    }
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
    /// Return in its words: done, or for a to-do just added, the next one.
    var returned: () -> Void
    /// Deletes the to-do from its note.
    var delete: () -> Void
    @State private var isHovered = false
    @State private var isPicking = false
    @State private var titleWidth: CGFloat = 0
    #if os(iOS)
    @State private var rowWidth: CGFloat = 0
    #endif

    /// At most this many lines under a to-do show while it isn't edited.
    static let shownLines = 6
    /// Move to Note….
    static let moveSymbol = "arrow.right.doc.on.clipboard"

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
                    TodoEditor(editing: editing, focus: focus, end: endEditing, returned: returned)
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
                    TodoEditBar(workspace: workspace, editing: editing, noteName: item.isLoose ? nil : item.note) {
                        if item.isLoose { moveToNote() } else { open() }
                    }
                        .padding(.top, 5)
                        .transition(Self.extra)
                } else {
                    meta
                        .transition(.opacity)
                }
                #else
                meta
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
        .contextMenu { menu }
        #else
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .contextMenu { menu } preview: { preview }
        #endif
        .accessibilityElement(children: .contain)
    }

    #if os(iOS)
    /// Touched and held, the row lifts on a card of its own, as a reminder does, rather than its words alone over the
    /// list.
    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TodoCircle(mark: isTicked ? .done : mark)
            VStack(alignment: .leading, spacing: 3) {
                titleText
                lines
                meta
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: rowWidth + 28, alignment: .leading)
        .background(Color.theme(Theme.panel))
    }
    #endif

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
            // Swiping, for VoiceOver.
            .accessibilityActions {
                if row.isTodo { Button("Delete", role: .destructive, action: delete) }
            }
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
                    .todoMetaLabel(row.isOverdue && !isTicked ? "Overdue, " + when : when, opensPicker: true)
            }
            if let place = row.place {
                Label(place.leaving ? "Leaving " + place.name : place.name, systemImage: "location.fill")
                    .onTapGesture { ask(.place) }
                    .todoMetaLabel(place.leaving ? "Leaving " + place.name : "Arriving at " + place.name, opensPicker: true)
            }
            if case .todo(let item) = row {
                ForEach(item.todo.fields.filter { [.priority, .repeats, .scheduled, .start].contains($0.kind) }, id: \.self) { field in
                    Label(field.label(), systemImage: field.symbol)
                        .lineLimit(1)
                        .todoMetaLabel(field.kind == .repeats ? "Repeats " + field.label() : field.label())
                }
            }
            switch row {
            case .todo(let item):
                // One in no note shows none.
                if !item.isLoose { TodoNoteLink(name: item.note) { open() } }
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
        // Being edited: the picker above the keyboard for what was tapped, as from the bar there.
        if let editing, !editing.isEnded { return editing.pick(kind) }
        switch row {
        case .todo(let item): workspace.askForTodoReminder(item.reference)
        case .note(let note): if let url = note.url { workspace.askForReminder(url) }
        }
        #endif
    }

    /// Into a note, picked in ⌘K: what was typed is written first.
    private func moveToNote() {
        guard case .todo(let item) = row else { return }
        endEditing()
        workspace.palette = .moveTodo(workspace.current(item.reference))
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
        if case .todo(let item) = row, item.isLoose {
            Button { moveToNote() } label: { Label("Move to Note…", systemImage: Self.moveSymbol) }
        } else {
            Button { open() } label: { Label("Open Note", systemImage: "doc.text") }
        }
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
        if row.isTodo {
            Divider()
            Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
        }
    }
}

extension TodoRow {
    var isNote: Bool { if case .note = self { true } else { false } }
    var isTodo: Bool { !isNote }
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
    /// Move to Note… for a to-do in no note, rather than its note's name.
    var isMove = false
    @State private var isHovered = false

    init(name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    init(moving action: @escaping () -> Void) {
        name = "Move to Note…"
        self.action = action
        isMove = true
    }

    var body: some View {
        Button(action: action) {
            Label(name, systemImage: isMove ? TodoRowView.moveSymbol : "doc.text")
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
        .help(isMove ? "Move it into a note" : "Open “\(name)”")
        #else
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(isMove ? name : "Open \(name)")
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
    static var side: CGFloat { TodosView.scaled(22, .body) }
    static var lift: CGFloat { TodosView.scaled(6, .body) }
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

extension View {
    /// Read by VoiceOver as these words, without the symbol before them: it would read a bell as "Notifications" and
    /// a calendar as "Calendar".
    func todoMetaLabel(_ words: String, opensPicker: Bool = false) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(words)
            .accessibilityAddTraits(opensPicker ? .isButton : [])
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
