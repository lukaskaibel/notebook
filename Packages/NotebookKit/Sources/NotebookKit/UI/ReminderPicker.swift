import SwiftUI

/// Remind Me, as a reminder's details in Reminders: a time later today, this evening or tomorrow at a tap, a time typed
/// in a few words ("friday evening", "in 3 weeks"), or a date and a time of your own. A note with a reminder changes or
/// removes it here. A popover on the Mac, a sheet on iPhone and iPad.
struct ReminderPicker: View {
    let workspace: Workspace
    let url: URL
    var close: () -> Void
    @State private var date: Date
    /// The time as typed. While there is some, what it could mean takes the place of the quick choices.
    @State private var query = ""
    /// The suggestion Return takes, by its place in the list; the arrow keys move it. The date and time below show it.
    @State private var lit = 0
    @FocusState private var isTyping: Bool

    init(workspace: Workspace, url: URL, close: @escaping () -> Void) {
        self.workspace = workspace
        self.url = url
        self.close = close
        _date = State(initialValue: workspace.reminder(for: url)?.date ?? Self.nextHour(after: .now))
    }

    private var reminder: Reminder? { workspace.reminder(for: url) }
    private var name: String { SearchSection.displayName(url) }
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
                pickers
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if reminder != nil {
                    Button("Remove Reminder", role: .destructive) { remove() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                // Also Return in the field, which takes the suggestion the date and time show.
                Button(reminder == nil ? "Remind Me" : "Change") { set(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= .now || isUnreadable)
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
                pickers
                if reminder != nil {
                    Section {
                        Button("Remove Reminder", role: .destructive) { remove() }
                    }
                }
            }
            .navigationTitle("Remind Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reminder == nil ? "Remind Me" : "Change", role: .confirm) { set(date) }
                        .disabled(date <= .now || isUnreadable)
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

    /// Later Today, This Evening and Tomorrow: each sets the reminder at once.
    private var choices: some View {
        Section {
            ForEach(Self.choices(after: .now), id: \.title) { choice in
                row(choice.title, symbol: choice.symbol, detail: choice.detail) { set(choice.date) }
            }
        } footer: {
            #if os(iOS)
            Text("A notification with the note’s first points comes at that time.")
            #endif
        }
    }

    /// What the typed time could mean, the one Return takes lit. A click or a tap sets the reminder at once.
    private var found: some View {
        Section {
            let suggestions = suggestions
            ForEach(Array(suggestions.enumerated()), id: \.element.date) { index, suggestion in
                row(suggestion.title, symbol: suggestion.symbol, detail: suggestion.detail, isLit: index == lit) { set(suggestion.date) }
            }
            if suggestions.isEmpty {
                Text("Try “tomorrow at 9”, “Friday evening” or “in 3 weeks”.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            #if os(iOS)
            Text("A notification with the note’s first points comes at that time.")
            #endif
        }
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

    /// Return in the field: the lit suggestion, whose date and time show below. Nothing while nothing is typed, so the
    /// touch keyboard's Done only puts the keyboard away.
    private func submit() {
        guard !query.isEmpty, !isUnreadable, date > .now else { return }
        set(date)
    }

    /// Lights a suggestion, and shows its date and time below.
    private func light(_ index: Int) {
        let suggestions = suggestions
        lit = min(max(index, 0), max(suggestions.count - 1, 0))
        guard !suggestions.isEmpty else { return }
        date = suggestions[lit].date
    }

    private var pickers: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
        }
    }

    private func set(_ date: Date) {
        workspace.setReminder(for: url, at: date)
        close()
    }

    private func remove() {
        workspace.removeReminder(for: url)
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
