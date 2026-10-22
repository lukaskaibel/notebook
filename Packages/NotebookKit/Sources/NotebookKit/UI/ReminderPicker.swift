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

/// Remind Me, as a reminder's details in Reminders: a time later today, this evening or tomorrow at a tap, or a date, a
/// time and a place of your own. A to-do can have a day without a time; a note's reminder has a time when it has a day.
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
                choices
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
                choices
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

    /// Later Today, This Evening and Tomorrow: each sets the reminder at once, keeping its place.
    private var choices: some View {
        Section {
            ForEach(Self.choices(after: .now), id: \.title) { choice in
                Button {
                    set(TodoDue(choice.date, time: true), hasPlace ? place : nil)
                    close()
                } label: {
                    HStack {
                        Label {
                            Text(choice.title)
                        } icon: {
                            // The sunrise is wider than the clock and the moon: the titles line up all the same.
                            Image(systemName: choice.symbol).frame(width: 22)
                        }
                        .foregroundStyle(Color.primary)
                        Spacer()
                        Text(choice.detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            #if os(iOS)
            Text(subject == .note ? "A notification with the note’s first points comes at that time." : "A notification with the to-do and its notes comes at that time.")
            #endif
        }
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

    /// Something to remind of, complete: a place chosen if Location is on, and a note's time still to come.
    private var canSet: Bool {
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
