import SwiftUI

/// Remind Me for a note: changes or removes the reminder it has. A popover on the Mac, a sheet on iPhone and iPad.
struct ReminderPicker: View {
    let workspace: Workspace
    let url: URL
    var close: () -> Void

    var body: some View {
        let reminder = workspace.reminder(for: url)
        ReminderForm(subject: .note, name: SearchSection.displayName(url), due: reminder?.date.map { TodoDue($0, time: true) }, place: reminder?.place,
                     isSet: reminder != nil, close: close) { due, place in
            workspace.setReminder(for: url, at: due?.date(), place: place)
        } remove: {
            workspace.removeReminder(for: url)
        }
    }
}

/// Remind Me for a to-do: its date, time and place, written after its words in the note.
struct TodoReminderPicker: View {
    let workspace: Workspace
    let todo: TodoReference
    var close: () -> Void

    var body: some View {
        let current = workspace.schedule(of: todo)
        ReminderForm(subject: .todo, name: current.text, due: current.due, place: current.place, isSet: current.due != nil || current.place != nil, close: close) { due, place in
            workspace.setTodo(todo, due: due, place: place)
        } remove: {
            workspace.setTodo(todo, due: nil, place: nil)
        }
    }
}

/// Remind Me, as a reminder's details in Reminders: a time later today, this evening or tomorrow at a tap, a time typed
/// in a few words ("friday evening", "in 3 weeks"), or a date, a time and a place of your own. A to-do can have a day
/// without a time; a note's reminder has a time when it has a day.
struct ReminderForm: View {
    enum Subject {
        case note, todo
    }

    let subject: Subject
    /// What it reminds of: the note's name or the to-do's words.
    let name: String
    let isSet: Bool
    var close: () -> Void
    var set: (TodoDue?, TodoPlace?) -> Void
    var remove: () -> Void

    @State private var date: Date
    @State private var hasDate: Bool
    @State private var hasTime: Bool
    @State private var hasPlace: Bool
    @State private var place: TodoPlace?
    /// The time as typed. While there is some, what it could mean takes the place of the quick choices.
    @State private var query = ""
    /// The suggestion Return takes, by its place in the list; the arrow keys move it. The date and time below show it.
    @State private var lit = 0
    @FocusState private var isTyping: Bool

    init(subject: Subject, name: String, due: TodoDue?, place: TodoPlace?, isSet: Bool, close: @escaping () -> Void,
         set: @escaping (TodoDue?, TodoPlace?) -> Void, remove: @escaping () -> Void) {
        self.subject = subject
        self.name = name
        self.isSet = isSet
        self.close = close
        self.set = set
        self.remove = remove
        // Nothing set yet: the next full hour, as a start.
        let fresh = !isSet
        var start = Self.nextHour(after: .now)
        if let due {
            start = due.hasTime ? due.date() : Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: start), minute: 0, second: 0, of: due.date()) ?? due.date()
        }
        _date = State(initialValue: start)
        _hasDate = State(initialValue: due != nil || fresh)
        _hasTime = State(initialValue: due?.hasTime ?? fresh)
        _hasPlace = State(initialValue: place != nil)
        _place = State(initialValue: place)
    }

    private var suggestions: [ReminderTimeParser.Suggestion] { ReminderTimeParser.suggestions(for: query, now: .now) }
    /// Typed, but nothing that reads as a time: Return does nothing.
    private var isUnreadable: Bool { !query.isEmpty && suggestions.isEmpty }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remind Me").font(.headline)
                Text(name).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                field
                if query.isEmpty { choices } else { found }
                when
                whereSection
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isSet {
                    Button("Remove Reminder", role: .destructive) { removeAndClose() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                // Also Return in the field, which takes the suggestion the date and time show.
                Button(isSet ? "Change" : "Remind Me") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSet)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        #else
        NavigationStack {
            Form {
                field
                if query.isEmpty { choices } else { found }
                when
                whereSection
                if isSet {
                    Section {
                        Button("Remove Reminder", role: .destructive) { removeAndClose() }
                    }
                }
            }
            .navigationTitle("Remind Me")
            .navigationSubtitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSet ? "Change" : "Remind Me", role: .confirm) { commit() }
                        .disabled(!canSet)
                }
            }
        }
        #endif
    }

    /// Where a time is typed, focused as Remind Me opens on the Mac, and on iPhone and iPad with a keyboard attached.
    private var field: some View {
        Section {
            TextField("Type a time", text: $query, prompt: Text("Type a time, such as Friday evening"))
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($isTyping)
                #if os(macOS)
                .focusOnAppear()
                #else
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onAppear { if HardwareKeyboard.shared.isAttached { isTyping = true } }
                #endif
                .onKeyPress(.downArrow) { light(lit + 1); return .handled }
                .onKeyPress(.upArrow) { light(lit - 1); return .handled }
                // On the Mac, Return is the Remind Me button's, which sets the date and time that show the suggestion.
                .onSubmit { submit() }
                .onChange(of: query) { light(0) }
        }
        #if DEBUG
        // remindtype <text>, remindkey down|up|return: the keyboard, for the debug remote.
        .onReceive(NotificationCenter.default.publisher(for: DebugReminders.keyboard)) { notification in
            let argument = notification.userInfo?["argument"] as? String ?? ""
            switch notification.userInfo?["command"] as? String {
            case "remindtype": query = argument
            case "remindkey":
                switch argument {
                case "down": light(lit + 1)
                case "up": light(lit - 1)
                default: submit()
                }
            default: break
            }
        }
        #endif
    }

    /// Later Today, This Evening and Tomorrow: each sets the reminder at once, keeping its place.
    private var choices: some View {
        Section {
            ForEach(Self.choices(after: .now), id: \.title) { choice in
                row(choice.title, symbol: choice.symbol, detail: choice.detail) { setNow(choice.date) }
            }
        } footer: {
            footer
        }
    }

    /// What the typed time could mean, the one Return takes lit. A click or a tap sets the reminder at once.
    private var found: some View {
        Section {
            let suggestions = suggestions
            ForEach(Array(suggestions.enumerated()), id: \.element.date) { index, suggestion in
                row(suggestion.title, symbol: suggestion.symbol, detail: suggestion.detail, isLit: index == lit) { setNow(suggestion.date) }
            }
            if suggestions.isEmpty {
                Text("Try “tomorrow at 9”, “Friday evening” or “in 3 weeks”.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        #if os(iOS)
        Text(subject == .note ? "A notification with the note’s first points comes at that time." : "A notification with the to-do and its notes comes at that time.")
        #endif
    }

    private func row(_ title: String, symbol: String, detail: String, isLit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    // The sunrise is wider than the clock and the moon: the titles line up all the same.
                    Image(systemName: symbol).frame(width: 22)
                }
                .foregroundStyle(Color.primary)
                Spacer()
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(.rect)
            #if os(macOS)
            // A Mac form takes no row backgrounds: the lit row's is drawn behind it.
            .background {
                if isLit {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -5)
                }
            }
            #endif
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .listRowBackground(isLit ? Color.accentColor.opacity(0.18) : nil)
        #endif
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }

    /// A choice or a suggestion: that day and time at once, keeping the place.
    private func setNow(_ date: Date) {
        set(TodoDue(date, time: true), hasPlace ? place : nil)
        close()
    }

    /// Return in the field: the lit suggestion, whose date and time show below. Nothing while nothing is typed, so the
    /// touch keyboard's Done only puts the keyboard away.
    private func submit() {
        guard !query.isEmpty, !isUnreadable, canSet else { return }
        commit()
    }

    /// Lights a suggestion, and shows its date and time below, both turned on.
    private func light(_ index: Int) {
        let suggestions = suggestions
        lit = min(max(index, 0), max(suggestions.count - 1, 0))
        guard !suggestions.isEmpty else { return }
        date = suggestions[lit].date
        hasDate = true
        hasTime = true
    }

    /// The day and the time, each turned on and off as in Reminders.
    private var when: some View {
        Section {
            Toggle(isOn: Binding(get: { hasDate }, set: { on in
                withAnimation(Theme.quick) {
                    hasDate = on
                    if subject == .note { hasTime = on } else if !on { hasTime = false }
                }
            })) {
                Label("Date", systemImage: "calendar")
            }
            if hasDate {
                DatePicker("Day", selection: $date, displayedComponents: .date)
            }
            if subject == .todo {
                Toggle(isOn: Binding(get: { hasTime }, set: { on in
                    withAnimation(Theme.quick) {
                        hasTime = on
                        if on { hasDate = true }
                    }
                })) {
                    Label("Time", systemImage: "clock")
                }
            }
            if hasTime {
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
            }
        }
    }

    /// A place to arrive at or leave.
    private var whereSection: some View {
        Section {
            Toggle(isOn: Binding(get: { hasPlace }, set: { on in withAnimation(Theme.quick) { hasPlace = on } })) {
                Label("Location", systemImage: "location")
            }
            if hasPlace {
                PlacePicker(place: $place)
            }
        } footer: {
            #if os(macOS)
            if hasPlace {
                Text("A Mac can’t tell where you are going: your iPhone or iPad reminds you there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
    }

    private var due: TodoDue? {
        hasDate ? TodoDue(date, time: hasTime) : nil
    }

    /// Something to remind of, complete: a place chosen if Location is on, a typed time that reads as one, and a note's
    /// time still to come.
    private var canSet: Bool {
        if isUnreadable { return false }
        if hasPlace, place == nil { return false }
        if !hasDate, !hasPlace { return false }
        if subject == .note, hasDate, date <= .now { return false }
        return true
    }

    private func commit() {
        set(due, hasPlace ? place : nil)
        close()
    }

    private func removeAndClose() {
        remove()
        close()
    }

    // MARK: - Times

    struct Choice {
        var title: String
        var symbol: String
        var date: Date
        var detail: String
    }

    /// As Mail's Remind Me: in about three hours, on the hour; at six in the evening while it is still afternoon; and
    /// tomorrow at nine.
    static func choices(after now: Date, calendar: Calendar = .current) -> [Choice] {
        var choices: [Choice] = []
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        let later = nextHour(after: now.addingTimeInterval(2 * 60 * 60), calendar: calendar)
        if calendar.isDate(later, inSameDayAs: now), calendar.component(.hour, from: later) <= 21, later != evening {
            choices.append(Choice(title: "Later Today", symbol: "clock", date: later, detail: time(later)))
        }
        if let evening, evening.timeIntervalSince(now) >= 60 * 60 {
            choices.append(Choice(title: "This Evening", symbol: "moon", date: evening, detail: time(evening)))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            choices.append(Choice(title: "Tomorrow", symbol: "sunrise", date: morning, detail: morning.formatted(.dateTime.weekday(.abbreviated)) + " " + time(morning)))
        }
        return choices
    }

    /// The next full hour after a time.
    static func nextHour(after date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? date
    }
}
