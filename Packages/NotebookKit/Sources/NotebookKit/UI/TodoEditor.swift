import SwiftUI

/// A to-do being edited in To-dos, as Reminders edits a reminder in place: its words, the lines under it, and on the
/// Mac buttons for its date, time and place under them (on iPhone and iPad they are above the keyboard).
///
/// Return is done; Shift-Return starts a line under the words. In a line under them Return starts the next one of
/// the same kind, and on an empty one is done; Tab and Shift-Tab move a line in and out, and `[ ] ` or `- ` typed at
/// the start of words make a sub-to-do or a point, as in a note.
struct TodoEditor: View {
    let workspace: Workspace
    @Bindable var editing: TodoEditing
    let item: TodoList.Item
    var focus: FocusState<TodoFocus?>.Binding
    var end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("To-do", text: $editing.title, selection: selection(.title), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: TodosView.titleSize))
                .foregroundStyle(Color.theme(Theme.text))
                .focused(focus, equals: .title)
                .onChange(of: editing.title) { _, title in
                    // Return on the touch keyboard: done.
                    if title.contains("\n") {
                        editing.title = title.replacingOccurrences(of: "\n", with: "")
                        end()
                    } else {
                        editing.changed()
                    }
                }
                .onKeyPress(phases: .down) { titleKey($0) }
                .onSubmit { end() }
                #if os(iOS)
                .submitLabel(.done)
                #endif
                .accessibilityLabel("To-do")
            ForEach(editing.lines) { line in
                if line.kind != .blank {
                    lineEditor(line)
                }
            }
            #if os(macOS)
            TodoEditBar(workspace: workspace, editing: editing, noteName: item.note) { open() }
                .padding(.top, 5)
            #else
            // Its date and place change from the bar above the keyboard.
            let schedule = editing.schedule
            HStack(spacing: 10) {
                if let due = schedule.due {
                    Label(ReminderText.text(due.date(), time: due.hasTime), systemImage: due.hasTime ? "bell.fill" : "calendar")
                        .foregroundStyle(due.isOverdue() ? Color.red : Color.theme(Theme.textSecondary))
                }
                if let place = schedule.place {
                    Label(place.leaving ? "Leaving " + place.name : place.name, systemImage: "location.fill")
                }
                TodoNoteLink(name: item.note) { open() }
            }
            .labelStyle(TodoMetaLabelStyle())
            .font(.system(size: TodosView.metaSize))
            .foregroundStyle(Color.theme(Theme.textTertiary))
            .padding(.top, 2)
            #endif
        }
        // Shown, or made again in another group after its date changed: the keyboard comes back.
        .onAppear { editing.refocus() }
    }

    private func lineEditor(_ value: TodoEditing.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TodoLineMarker(kind: value.kind) { editing.toggle(value.id) }
            if value.isEditable {
                TextField(placeholder(value.kind), text: words(value.id), selection: selection(.line(value.id)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: TodosView.notesSize))
                    .foregroundStyle(color(value.kind))
                    .strikethrough(value.kind == .todo(.cancelled))
                    .focused(focus, equals: .line(value.id))
                    .onChange(of: value.words) { _, words in wordsChanged(value.id, words) }
                    .onKeyPress(phases: .down) { lineKey($0, value.id) }
            } else {
                // Code, a table: kept as it is.
                Text(value.markdown.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: TodosView.notesSize, design: .monospaced))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .lineLimit(1)
            }
        }
        .padding(.leading, CGFloat(value.depth - 1) * TodosView.indentStep)
    }

    /// A line's words, found by who the line is: a field still being let go of after its line went reads nothing.
    private func words(_ id: UUID) -> Binding<String> {
        Binding {
            editing.lines.first { $0.id == id }?.words ?? ""
        } set: { words in
            if let index = editing.lines.firstIndex(where: { $0.id == id }) { editing.lines[index].words = words }
        }
    }

    /// Where the caret is in a field, while it has the keyboard. On the Mac the fields share one editor, whose caret
    /// every field would otherwise take for its own and put back in the field typed in a moment later.
    private func selection(_ field: TodoFocus) -> Binding<TextSelection?> {
        Binding {
            focus.wrappedValue == field ? editing.selection(of: field) : nil
        } set: { selection in
            if focus.wrappedValue == field { editing.fieldMoved(selection, in: field) }
        }
    }

    private func placeholder(_ kind: TodoLine.Kind) -> String {
        switch kind {
        case .todo: "Sub-to-do"
        case .text: "Notes"
        default: ""
        }
    }

    private func color(_ kind: TodoLine.Kind) -> Color {
        switch kind {
        case .todo(let mark): mark.isClosed ? Color.theme(Theme.textTertiary) : Color.theme(Theme.text)
        default: Color.theme(Theme.textSecondary)
        }
    }

    private func open() {
        end()
        workspace.openTodo(item.reference)
    }

    // MARK: - Keys

    private func titleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            if press.modifiers.contains(.shift) { editing.addLineUnderTitle() } else { end() }
            return .handled
        case .tab:
            // The words stay where they are.
            return .handled
        case .downArrow:
            guard TodoEditing.caret(in: editing.title, editing.titleSelection) == editing.title.endIndex,
                  let next = editing.neighbour(of: .title, by: 1) else { return .ignored }
            editing.move(to: next, caret: 0)
            return .handled
        case .escape:
            end()
            return .handled
        default:
            return .ignored
        }
    }

    private func lineKey(_ press: KeyPress, _ id: UUID) -> KeyPress.Result {
        guard let line = editing.lines.first(where: { $0.id == id }) else { return .ignored }
        let caret = TodoEditing.caret(in: line.words, line.selection)
        // Shift-Tab comes as its own character on the Mac.
        if press.characters == "\u{19}" {
            editing.outdent(id)
            return .handled
        }
        switch press.key {
        case .return:
            if !editing.split(id) { end() }
            return .handled
        case .tab:
            if press.modifiers.contains(.shift) { editing.outdent(id) } else { editing.indent(id) }
            return .handled
        // Delete comes as U+007F on the Mac.
        case .delete, KeyEquivalent("\u{7F}"):
            guard caret == line.words.startIndex, line.selection.map(\.isInsertion) ?? true else { return .ignored }
            editing.deleteBackward(id)
            return .handled
        case .upArrow:
            guard caret == line.words.startIndex, let previous = editing.neighbour(of: .line(id), by: -1) else { return .ignored }
            editing.move(to: previous)
            return .handled
        case .downArrow:
            guard caret == line.words.endIndex, let next = editing.neighbour(of: .line(id), by: 1) else { return .ignored }
            editing.move(to: next, caret: 0)
            return .handled
        case .escape:
            end()
            return .handled
        default:
            return .ignored
        }
    }

    /// Return on the touch keyboard comes as a line break in the words: the line is split there.
    private func wordsChanged(_ id: UUID, _ words: String) {
        guard let index = editing.lines.firstIndex(where: { $0.id == id }) else { return }
        guard let breakIndex = words.firstIndex(of: "\n") else { return editing.typed(id) }
        var joined = words
        joined.remove(at: breakIndex)
        let offset = words.distance(from: words.startIndex, to: breakIndex)
        editing.lines[index].words = joined
        editing.lines[index].selection = TextSelection(insertionPoint: joined.index(joined.startIndex, offsetBy: offset))
        if !editing.split(id) { end() }
    }
}

extension TextSelection {
    /// A caret, not words selected.
    var isInsertion: Bool {
        if case .selection(let range) = indices { range.isEmpty } else { false }
    }
}

#if os(macOS)
/// Reminders' buttons under a to-do being edited: its day, its time and its place, each with a few to choose from at a
/// click and Custom… for Remind Me; a sub-to-do; and the note it is in.
struct TodoEditBar: View {
    let workspace: Workspace
    let editing: TodoEditing
    let noteName: String
    var open: () -> Void
    @State private var isPicking = false

    var body: some View {
        let schedule = editing.schedule
        HStack(spacing: 6) {
            Menu {
                TodoDayChoices(workspace: workspace, editing: editing) { pick() }
            } label: {
                Label(schedule.due.map { ReminderText.day($0.date()) } ?? "Add Date", systemImage: "calendar")
                    .foregroundStyle(schedule.due?.isOverdue() == true ? Color.red : Color.primary)
            }
            if let due = schedule.due {
                Menu {
                    TodoTimeChoices(workspace: workspace, editing: editing) { pick() }
                } label: {
                    Label(due.hasTime ? due.date().formatted(date: .omitted, time: .shortened) : "Add Time", systemImage: "clock")
                }
            }
            Menu {
                TodoPlaceChoices(workspace: workspace, editing: editing) { pick() }
            } label: {
                Label(schedule.place.map { $0.leaving ? "Leaving " + $0.name : $0.name } ?? "Add Location", systemImage: "location")
                    .lineLimit(1)
            }
            Button { editing.addTodo() } label: { Label("Add Sub-to-do", systemImage: "checklist") }
            Spacer(minLength: 8)
            TodoNoteLink(name: noteName, action: open)
                .font(.system(size: TodosView.metaSize))
                .layoutPriority(-1)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            TodoReminderPicker(workspace: workspace, todo: editing.current) { isPicking = false }
        }
        .onChange(of: isPicking) { _, picking in
            editing.isChoosing = picking
            if !picking { editing.refocus() }
        }
    }

    /// Custom…: Remind Me, with what was typed written first.
    private func pick() {
        editing.commit()
        isPicking = true
    }
}
#endif

#if os(iOS)
/// Reminders' buttons above the keyboard while a to-do is edited: its day, its time, its place, a sub-to-do, a line in
/// or out, and done.
struct TodoKeyboardBar: View {
    let workspace: Workspace
    let editing: TodoEditing
    let focus: TodoFocus?
    var done: () -> Void

    var body: some View {
        HStack {
            Menu {
                TodoDayChoices(workspace: workspace, editing: editing) { custom() }
            } label: {
                Label("Date", systemImage: "calendar")
            }
            Menu {
                TodoTimeChoices(workspace: workspace, editing: editing) { custom() }
            } label: {
                Label("Time", systemImage: "clock")
            }
            Menu {
                TodoPlaceChoices(workspace: workspace, editing: editing) { custom() }
            } label: {
                Label("Location", systemImage: "location")
            }
            Button { editing.addTodo() } label: { Label("Add Sub-to-do", systemImage: "checklist") }
            if case .line(let id) = focus {
                Button { editing.outdent(id) } label: { Label("Move Out", systemImage: "decrease.indent") }
                Button { editing.indent(id) } label: { Label("Move In", systemImage: "increase.indent") }
            }
            Spacer()
            Button(action: done) { Label("Done", systemImage: "keyboard.chevron.compact.down") }
        }
        .labelStyle(.iconOnly)
    }

    /// Custom…: Remind Me as a sheet, which takes the keyboard, so editing is done first.
    private func custom() {
        let todo = editing.beforeChanging()
        done()
        workspace.askForTodoReminder(todo)
    }
}
#endif

/// The days a to-do can get at a click, as in its menu in To-dos.
struct TodoDayChoices: View {
    let workspace: Workspace
    let editing: TodoEditing
    var custom: () -> Void

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        Button { set(today) } label: { Label("Today", systemImage: "star") }
        Button { set(calendar.date(byAdding: .day, value: 1, to: today)) } label: { Label("Tomorrow", systemImage: "sunrise") }
        if let weekend = calendar.nextWeekend(startingAfter: today)?.start {
            Button { set(weekend) } label: { Label("This Weekend", systemImage: "sofa") }
        }
        if let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) {
            Button { set(monday) } label: { Label("Next Week", systemImage: "calendar") }
        }
        Divider()
        Button { custom() } label: { Label("Custom…", systemImage: "calendar.badge.clock") }
        if editing.schedule.due != nil {
            Button { set(nil) } label: { Label("Remove Date", systemImage: "calendar.badge.minus") }
        }
    }

    /// The day, keeping the time and the place.
    private func set(_ day: Date?) {
        workspace.moveTodo(editing.beforeChanging(), to: day)
        editing.refocus()
    }
}

/// The times a to-do can get at a click, the words Remind Me reads too: in the morning, at noon, in the afternoon,
/// evening and night.
struct TodoTimeChoices: View {
    let workspace: Workspace
    let editing: TodoEditing
    var custom: () -> Void

    static let times: [(name: String, hour: Int)] = [("Morning", 9), ("Noon", 12), ("Afternoon", 15), ("Evening", 18), ("Night", 21)]

    var body: some View {
        ForEach(Self.times, id: \.hour) { time in
            Button { set(time.hour) } label: {
                Text(time.name)
                Text(Calendar.current.date(bySettingHour: time.hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "")
            }
        }
        Divider()
        Button { custom() } label: { Label("Custom…", systemImage: "clock") }
        if editing.schedule.due?.hasTime == true {
            Button { set(nil) } label: { Label("Remove Time", systemImage: "clock.badge.xmark") }
        }
    }

    /// The time on the to-do's day; without one, today if the time is still to come, else tomorrow.
    private func set(_ hour: Int?) {
        let todo = editing.beforeChanging()
        let schedule = editing.schedule
        var day = schedule.due ?? TodoDue(.now, time: false)
        if schedule.due == nil, let hour, Calendar.current.component(.hour, from: .now) >= hour,
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) {
            day = TodoDue(tomorrow, time: false)
        }
        workspace.setTodo(todo, due: day.at(hour: hour, minute: hour == nil ? nil : 0), place: schedule.place)
        editing.refocus()
    }
}

/// The places a to-do can get at a click: the last ones chosen, for arriving there.
struct TodoPlaceChoices: View {
    let workspace: Workspace
    let editing: TodoEditing
    var custom: () -> Void

    var body: some View {
        let recent = PlaceHistory.recent
        ForEach(recent, id: \.self) { place in
            Button { set(place) } label: { Label(place.name, systemImage: "mappin") }
        }
        if !recent.isEmpty { Divider() }
        Button { custom() } label: { Label("Custom…", systemImage: "location") }
        if editing.schedule.place != nil {
            Button { set(nil) } label: { Label("Remove Location", systemImage: "location.slash") }
        }
    }

    private func set(_ place: TodoPlace?) {
        let todo = editing.beforeChanging()
        workspace.setTodo(todo, due: editing.schedule.due, place: place)
        editing.refocus()
    }
}
