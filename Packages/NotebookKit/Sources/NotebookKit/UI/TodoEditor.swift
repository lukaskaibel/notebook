import SwiftUI

/// A to-do being edited in To-dos, as Reminders edits a reminder in place: its words, a line for notes under them, and
/// the lines under it; the buttons for its date, time and place are under them on the Mac (`TodoEditBar`, in the row)
/// and above the keyboard on iPhone and iPad.
///
/// Return is done; Shift-Return starts a line under the words. In a line under them Return starts the next one of
/// the same kind, and on an empty one is done; Tab and Shift-Tab move a line in and out, and `[ ] ` or `- ` typed at
/// the start of words make a sub-to-do or a point, as in a note.
struct TodoEditor: View {
    @Bindable var editing: TodoEditing
    var focus: FocusState<TodoFocus?>.Binding
    var end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("To-do", text: $editing.title, selection: selection(.title), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: TodosView.titleSize))
                .foregroundStyle(Color.theme(Theme.text))
                .focused(focus, equals: .title)
                #if os(macOS)
                // In the window you click in, SwiftUI can leave the keyboard with the window as the field appears; it
                // noticed at the next redraw, such as a move of the pointer, and the editing ended.
                .focusOnAppear(editing.focus == .title && !editing.isEnded)
                #endif
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
                // The line for notes comes with the buttons, and goes with them.
                if line.kind != .blank, editing.isExpanded || !line.isNewAndEmpty {
                    lineEditor(line)
                        .transition(TodoRowView.extra)
                }
            }
        }
        // Closing: what was typed is written, and the row is about to show it.
        .allowsHitTesting(!editing.isEnded)
        // Shown, or made again in another group after its date changed: the keyboard comes back, and the buttons.
        .onAppear {
            guard !editing.isEnded else { return }
            editing.refocus()
            if !editing.isExpanded { withAnimation(Theme.spring) { editing.isExpanded = true } }
        }
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

/// What the buttons for a to-do's date, time and place set, with what was typed written first, keeping the rest.
extension TodoEditing {
    func setDue(_ due: TodoDue?) {
        workspace.setTodo(beforeChanging(), due: due, place: schedule.place)
        refocus()
    }

    func setPlace(_ place: TodoPlace?) {
        workspace.setTodo(beforeChanging(), due: schedule.due, place: place)
        refocus()
    }
}

#if os(macOS)
/// Reminders' buttons under a to-do being edited, capsules as Reminders draws them: its day, its time and its place, in
/// the accent colour with an × to take them away once they are set and a grey symbol until then, each a dropdown to
/// type in or click, as Issues has them; a sub-to-do; and the note it is in.
struct TodoEditBar: View {
    let workspace: Workspace
    let editing: TodoEditing
    let noteName: String
    var open: () -> Void
    @State private var picking: Picking?

    enum Picking {
        case day, time, place
    }

    var body: some View {
        let schedule = editing.schedule
        HStack(spacing: 6) {
            chip(.day, "Date", value: schedule.due.map { ReminderText.day($0.date()) }, symbol: "calendar",
                 tint: schedule.due?.isOverdue() == true ? .red : .accentColor) {
                editing.setDue(nil)
            } content: {
                TodoDatePicker(due: schedule.due, pick: editing.setDue) { picking = nil }
            }
            chip(.time, "Time", value: schedule.due.flatMap { $0.hasTime ? $0.date().formatted(date: .omitted, time: .shortened) : nil },
                 symbol: "clock.fill", tint: schedule.due?.isOverdue() == true ? .red : .accentColor) {
                editing.setDue(schedule.due?.at(hour: nil, minute: nil))
            } content: {
                TodoTimePicker(due: schedule.due, pick: editing.setDue) { picking = nil }
            }
            chip(.place, "Location", value: schedule.place.map { $0.leaving ? "Leaving " + $0.name : $0.name }, symbol: "location.fill") {
                editing.setPlace(nil)
            } content: {
                TodoPlaceDropdown(place: schedule.place, pick: editing.setPlace) { picking = nil }
            }
            TodoChip(symbol: "checklist", title: "Add Sub-to-do") { editing.addTodo() }
            Spacer(minLength: 8)
            TodoNoteLink(name: noteName, action: open)
                .font(.system(size: TodosView.metaSize))
                .layoutPriority(-1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: picking) { _, new in
            // What was typed is written before a dropdown takes the keyboard; it comes back after.
            if new != nil { editing.commit() }
            editing.isChoosing = new != nil
            if new == nil { editing.refocus() }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pick)) { note in
            editing.isChoosing = true
            picking = switch note.object as? String {
            case "date": .day
            case "time": .time
            case "place": .place
            default: nil
            }
        }
        #endif
    }

    private func chip<Content: View>(_ kind: Picking, _ name: String, value: String?, symbol: String, tint: Color = .accentColor,
                                     clear: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) -> some View {
        TodoChip(symbol: symbol, title: (value == nil ? "Add " : "Change ") + name, value: value, tint: tint, isOpen: picking == kind,
                 clearTitle: "Remove " + name, clear: clear) {
            // Before the dropdown takes the keyboard.
            if picking == nil { editing.isChoosing = true }
            picking = picking == kind ? nil : kind
        }
        .dropdown(isPresented: Binding(get: { picking == kind }, set: { if !$0, picking == kind { picking = nil } })) { _ in
            content()
        }
    }
}

/// A capsule in the bar under a to-do, as Reminders has them: a grey symbol while there is nothing set, and once there
/// is, the symbol and the value in the accent colour, with an × that takes it away. Drawn by SwiftUI, so it fades with
/// the bar.
struct TodoChip: View {
    let symbol: String
    /// What a click does, for the pointer resting on it and for VoiceOver: "Add Date", "Change Date".
    let title: String
    var value: String?
    var tint: Color = .accentColor
    var isOpen = false
    var clearTitle = ""
    var clear: (() -> Void)?
    var action: () -> Void
    @State private var isHovered = false

    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                    if let value {
                        // A shade heavier than the words around it, so the ink of the accent reads as a colour.
                        Text(value)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                // Neutral greys, as Reminders has them, not the page's bluish ones.
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .frame(minWidth: 20, minHeight: Self.height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(value.map { title + ", " + $0 } ?? title)
            if value != nil, let clear {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: Self.height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(clearTitle)
                .accessibilityLabel(clearTitle)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, value == nil ? 7 : 10)
        .background(Capsule().fill(Color.theme(isOpen ? Theme.chipOpen : isHovered ? Theme.chipHover : Theme.chip)))
        .contentShape(.capsule)
        .onHover { hovering in withAnimation(Theme.quick) { isHovered = hovering } }
        .animation(Theme.spring, value: value)
    }
}
#endif

#if os(iOS)
/// Reminders' buttons above the keyboard while a to-do is edited, laid out as the bar in a note is: across the screen
/// in a capsule of glass, its day, its time and its place, each a grey symbol until it is set and then what it is set
/// to, in the accent colour as the note's pills show it; each opens a popover from the to-do's row to type in or tap
/// (a sheet on iPhone). Then a sub-to-do, and in a line under the words, moving that line out or in. At the right end,
/// on its own, the button that hides the keyboard, which is done.
struct TodoKeyboardBar: View {
    let editing: TodoEditing
    let focus: TodoFocus?
    var done: () -> Void

    /// What can show its value in words.
    private enum Part {
        case day, time, place
    }

    var body: some View {
        let schedule = editing.schedule
        HStack(spacing: WritingBar.spacing) {
            // The values in words while they fit; a place's name gives way first, then the day and the time.
            ViewThatFits(in: .horizontal) {
                buttons(due: schedule.due, place: schedule.place, words: [.day, .time, .place])
                buttons(due: schedule.due, place: schedule.place, words: [.day, .time])
                buttons(due: schedule.due, place: schedule.place, words: [])
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: WritingBar.barHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            HideKeyboardButton(action: done)
        }
        .frame(maxWidth: WritingBar.barWidth(for: .infinity))
        .padding(.horizontal, 12)
        .padding(.top, WritingBar.topGap)
        .padding(.bottom, WritingBar.keyboardGap)
        .frame(maxWidth: .infinity)
        .animation(UIAccessibility.isReduceMotionEnabled ? nil : Theme.spring, value: schedule.due)
        .animation(UIAccessibility.isReduceMotionEnabled ? nil : Theme.spring, value: schedule.place)
        .animation(UIAccessibility.isReduceMotionEnabled ? nil : Theme.spring, value: focus)
    }

    private func buttons(due: TodoDue?, place: TodoPlace?, words: Set<Part>) -> some View {
        let tint = due?.isOverdue() == true ? Color.red : Color.theme(Theme.accent)
        return HStack(spacing: 4) {
            button("Date", symbol: "calendar", value: due.map { ReminderText.day($0.date()) }, inWords: words.contains(.day), tint: tint) {
                editing.pick(.day)
            }
            button("Time", symbol: due?.hasTime == true ? "clock.fill" : "clock",
                   value: due.flatMap { $0.hasTime ? $0.date().formatted(date: .omitted, time: .shortened) : nil }, inWords: words.contains(.time), tint: tint) {
                editing.pick(.time)
            }
            button("Location", symbol: place == nil ? "location" : "location.fill",
                   value: place.map { $0.leaving ? "Leaving " + $0.name : $0.name }, inWords: words.contains(.place)) {
                editing.pick(.place)
            }
            button("Add Sub-to-do", symbol: "checklist") { editing.addTodo() }
            if case .line(let id) = focus {
                button("Move Out", symbol: "decrease.indent") { editing.outdent(id) }
                button("Move In", symbol: "increase.indent") { editing.indent(id) }
            }
        }
    }

    /// A slot of the bar. A value set is on a tint of its colour, in words as long as it takes; the other buttons share
    /// the room that is left.
    private func button(_ name: String, symbol: String, value: String? = nil, inWords: Bool = false, tint: Color = .theme(Theme.accent),
                        action: @escaping () -> Void) -> some View {
        let words = inWords ? value : nil
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    // Unset, as big as the tools of the bar in a note.
                    .font(.system(size: value == nil ? 17 : words == nil ? 15 : 13, weight: value == nil ? .regular : .semibold))
                    .imageScale(value == nil ? .large : .medium)
                if let words {
                    // A place's long name, cut short.
                    Text(words)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 130)
                }
            }
            .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, words == nil ? 0 : 9)
            .frame(minWidth: value != nil && words == nil ? 40 : nil)
            .frame(height: value == nil ? WritingBar.barHeight : 32)
            .background {
                if value != nil { Capsule().fill(tint.opacity(0.13)) }
            }
            .frame(minWidth: WritingBar.barHeight, maxWidth: words == nil ? .infinity : nil, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // In words only when they fit, not squeezed by the buttons around it.
        .fixedSize(horizontal: words != nil, vertical: false)
        .accessibilityLabel(name)
        .accessibilityValue(value ?? "")
        .transition(.opacity)
    }
}

/// The popover for a to-do's day, time or place, from its row while it is edited: it outlives the bar above the
/// keyboard, which goes as soon as the popover's field takes the keyboard. On iPhone a sheet.
struct TodoPickPopover: ViewModifier {
    let editing: TodoEditing?

    func body(content: Content) -> some View {
        content
            .popover(item: Binding(get: { editing?.picking }, set: { editing?.picking = $0 })) { kind in
                if let editing {
                    let schedule = editing.schedule
                    ScrollView {
                        switch kind {
                        case .day: TodoDatePicker(due: schedule.due, pick: editing.setDue) { editing.picking = nil }
                        case .time: TodoTimePicker(due: schedule.due, pick: editing.setDue) { editing.picking = nil }
                        case .place: TodoPlaceDropdown(place: schedule.place, pick: editing.setPlace) { editing.picking = nil }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .onChange(of: editing?.picking) { _, new in
                // The keyboard goes back to the to-do once the popover is closed.
                guard let editing, new == nil else { return }
                editing.isChoosing = false
                editing.refocus()
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pick)) { note in
                guard let editing, !editing.isEnded else { return }
                switch note.object as? String {
                case "date": editing.pick(.day)
                case "time": editing.pick(.time)
                case "place": editing.pick(.place)
                default: editing.picking = nil
                }
            }
            #endif
    }
}
#endif
