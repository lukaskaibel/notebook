import MapKit
import SwiftUI

/// A to-do's day, time and place, each picked in a dropdown as Issues picks a due date: a field that has the keyboard
/// at once and reads what is typed ("thursday in 3 weeks", "evening", a place's name), the choices to click under it,
/// and for a day, a month to click in. A pick closes it. On the Mac a glass dropdown under the button, on iPhone and
/// iPad a popover.
struct TodoDatePicker: View {
    let due: TodoDue?
    var pick: (TodoDue?) -> Void
    var close: () -> Void
    @State private var query = ""

    var body: some View {
        TypedPicker(placeholder: "Type a date, like in 3 weeks", query: $query, rows: rows,
                    hint: "Try “Friday”, “in 3 weeks”, “12.11.” or “tomorrow at 9”.", close: close) {
            if query.isEmpty {
                MonthGrid(selected: due?.date()) { day in
                    choose(TodoDue(day, time: false).at(hour: due?.hour, minute: due?.minute))
                }
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pickerType)) { query = $0.object as? String ?? "" }
        #endif
    }

    private var rows: [PickRow] {
        let now = Date.now
        guard query.isEmpty else {
            // A day typed keeps the time the to-do has; a time typed is its new time.
            return ReminderTimeParser.suggestions(for: query, now: now, days: true).map { found in
                var new = TodoDue(found.date, time: found.hasTime)
                if !found.hasTime, let due, due.hasTime { new = new.at(hour: due.hour, minute: due.minute) }
                return PickRow(id: "\(found.date.timeIntervalSince1970)\(found.hasTime)", title: found.title, detail: found.detail,
                               symbol: found.symbol, isChecked: new == due) { choose(new) }
            }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var days: [(String, String, Date?)] = [("Today", "star", today), ("Tomorrow", "sunrise", calendar.date(byAdding: .day, value: 1, to: today))]
        if let weekend = calendar.nextWeekend(startingAfter: today)?.start { days.append(("This Weekend", "sofa", weekend)) }
        days.append(("Next Week", "calendar", calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)))
        var rows = days.compactMap { title, symbol, day -> PickRow? in
            guard let day else { return nil }
            let new = TodoDue(day, time: false).at(hour: due?.hour, minute: due?.minute)
            return PickRow(id: title, title: title, detail: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                           symbol: symbol, isChecked: due.map { calendar.isDate($0.date(), inSameDayAs: day) } ?? false) { choose(new) }
        }
        if due != nil {
            rows.append(PickRow(id: "remove", title: "Remove Date", symbol: "calendar.badge.minus", isDestructive: true) { choose(nil) })
        }
        return rows
    }

    private func choose(_ new: TodoDue?) {
        close()
        if new != due { pick(new) }
    }
}

/// A to-do's time on its day: the times of day at a click, or one typed ("9:30", "evening", "3pm").
struct TodoTimePicker: View {
    let due: TodoDue?
    var pick: (TodoDue?) -> Void
    var close: () -> Void
    @State private var query = ""

    /// The times of day, the words Remind Me reads too.
    static let times: [(name: String, hour: Int)] = [("Morning", 9), ("Noon", 12), ("Afternoon", 15), ("Evening", 18), ("Night", 21)]

    var body: some View {
        TypedPicker(placeholder: "Type a time, such as 9:30 or evening", query: $query, rows: rows,
                    hint: "Try “9”, “14:30”, “3pm” or “evening”.", close: close) { EmptyView() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pickerType)) { query = $0.object as? String ?? "" }
        #endif
    }

    /// Its day, or without one, today while the time is still to come and else tomorrow.
    private func day(for hour: Int, minute: Int) -> TodoDue {
        if let due { return due }
        let calendar = Calendar.current
        let passed = (calendar.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now) <= .now
        return TodoDue(passed ? calendar.date(byAdding: .day, value: 1, to: .now) ?? .now : .now, time: false)
    }

    private var rows: [PickRow] {
        let times: [(title: String, hour: Int, minute: Int)] = query.isEmpty
            ? Self.times.map { ($0.name, $0.hour, 0) }
            : ReminderTimeParser.times(for: query).map { time in
                (time.words.map { $0.replacingOccurrences(of: "at ", with: "") } ?? clock(time.hour, time.minute), time.hour, time.minute)
            }
        var rows = times.map { time in
            let new = day(for: time.hour, minute: time.minute).at(hour: time.hour, minute: time.minute)
            let symbol = time.hour < 12 ? "sunrise" : time.hour < 17 ? "sun.max" : "moon"
            let detail = clock(time.hour, time.minute)
            return PickRow(id: "\(time.hour):\(time.minute)", title: time.title, detail: detail == time.title ? "" : detail, symbol: symbol,
                           isChecked: new == due) { choose(new) }
        }
        if query.isEmpty, due?.hasTime == true {
            rows.append(PickRow(id: "remove", title: "Remove Time", symbol: "clock.badge.xmark", isDestructive: true) { choose(due?.at(hour: nil, minute: nil)) })
        }
        return rows
    }

    private func clock(_ hour: Int, _ minute: Int) -> String {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now).formatted(date: .omitted, time: .shortened)
    }

    private func choose(_ new: TodoDue?) {
        close()
        if new != due { pick(new) }
    }
}

/// A to-do's place: found by typing its name in Apple Maps, where you are now, Home or Work, or one chosen before; and
/// whether it is for arriving there or for leaving. Home and Work are chosen once, the first time they are tapped: an
/// address on your card in Contacts, where you are, or one searched for (`SavedPlaces`).
struct TodoPlaceDropdown: View {
    let place: TodoPlace?
    var pick: (TodoPlace?) -> Void
    var close: () -> Void
    @State private var query = ""
    @State private var search = PlaceSearch()
    /// The row whose place is being looked up or located.
    @State private var busy: String?
    /// Why a row found nothing: the row, and what to say under it.
    @State private var problem: (row: String, text: String)?
    @State private var leaving: Bool
    /// Home or Work, while its address is being chosen.
    @State private var choosing: SavedPlaces.Kind?
    private var saved: SavedPlaces { .shared }

    init(place: TodoPlace?, pick: @escaping (TodoPlace?) -> Void, close: @escaping () -> Void) {
        self.place = place
        self.pick = pick
        self.close = close
        _leaving = State(initialValue: place?.leaving ?? false)
    }

    var body: some View {
        TypedPicker(placeholder: choosing.map { "Search for your \($0.name.lowercased()) address" } ?? "Search for a place", query: $query,
                    rows: rows, hint: "No places found.", close: close) {
            VStack(alignment: .leading, spacing: 8) {
                if choosing == nil, query.isEmpty, let place, place.hasCoordinates {
                    // Arriving or leaving the place it has, at a click.
                    Picker("When", selection: Binding(get: { leaving }, set: { new in
                        leaving = new
                        var changed = place
                        changed.leaving = new
                        pick(changed)
                    })) {
                        Text("Arriving").tag(false)
                        Text("Leaving").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let choosing {
                    note("Notebook keeps \(choosing.name) for your reminders, on your other devices too.")
                }
                #if os(macOS)
                note("Your iPhone or iPad reminds you there.")
                #endif
            }
            .padding(.horizontal, TypedPicker<EmptyView>.inset + 4)
            .padding(.top, TypedPicker<EmptyView>.inset)
        }
        .onChange(of: query) { search.query = query }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pickerType)) { query = $0.object as? String ?? "" }
        #endif
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypedPicker<EmptyView>.rowHeight > 40 ? 13 : 11))
            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: [PickRow] {
        if let choosing { return addressRows(for: choosing) }
        guard query.isEmpty else {
            // Home or Work by name, before what Apple Maps finds.
            let typed = query.lowercased()
            let named = SavedPlaces.Kind.allCases.filter { $0.name.lowercased().hasPrefix(typed) }.map(savedRow)
            return named + searchRows { found, _ in
                var chosen = found
                chosen.leaving = leaving
                choose(chosen)
            }
        }
        var rows: [PickRow] = []
        if let place, !SavedPlaces.Kind.allCases.contains(where: { saved.isPlace(place, $0) }) {
            rows.append(PickRow(id: "current", title: place.name, symbol: "mappin.and.ellipse", isChecked: true) { close() })
        }
        rows.append(hereRow { found, _ in
            var chosen = found
            chosen.leaving = leaving
            choose(chosen)
        })
        rows += SavedPlaces.Kind.allCases.map(savedRow)
        for recent in PlaceHistory.recent where recent.name != place?.name && !saved.isSaved(recent) {
            rows.append(PickRow(id: "recent" + recent.name, title: recent.name, symbol: "clock") {
                var chosen = recent
                chosen.leaving = leaving
                choose(chosen)
            })
        }
        if place != nil {
            rows.append(PickRow(id: "remove", title: "Remove Location", symbol: "location.slash", isDestructive: true) { choose(nil) })
        }
        return rows
    }

    /// Home or Work: its place at a tap once it is known, and until then a tap to choose its address.
    private func savedRow(_ kind: SavedPlaces.Kind) -> PickRow {
        guard let known = saved.saved[kind] else {
            return PickRow(id: kind.rawValue, title: kind.name, detail: "Choose Address…", symbol: kind.symbol, detailBelow: true) {
                query = ""
                problem = nil
                choosing = kind
            }
        }
        let isChecked = saved.isPlace(place, kind)
        var row = PickRow(id: kind.rawValue, title: kind.name, detail: known.address, symbol: kind.symbol, isChecked: isChecked, detailBelow: true) {
            if isChecked { return close() }
            if let chosen = saved.place(kind, leaving: leaving) { choose(chosen) }
        }
        row.menu = [
            PickRow.Item(title: "Change Address…", symbol: "pencil") {
                query = ""
                problem = nil
                choosing = kind
            },
            PickRow.Item(title: "Forget " + kind.name, symbol: "trash", isDestructive: true) { saved.set(kind, to: nil) },
        ]
        return row
    }

    /// Choosing Home's or Work's address: where you are, one on your card in Contacts, or one typed.
    private func addressRows(for kind: SavedPlaces.Kind) -> [PickRow] {
        guard query.isEmpty else {
            return searchRows { found, address in keep(found, address: address, as: kind) }
        }
        var rows = [hereRow { found, address in keep(found, address: address, as: kind) }]
        #if os(iOS)
        rows.append(PickRow(id: "card", title: "Choose from Contacts…", detail: problem?.row == "card" ? problem?.text ?? "" : "Your own card has the \(kind.name.lowercased()) address Maps knows",
                            symbol: "person.crop.circle", isBusy: busy == "card", detailBelow: true) { fromContacts(as: kind) })
        #endif
        return rows
    }

    private func keep(_ found: TodoPlace, address: String, as kind: SavedPlaces.Kind) {
        guard var chosen = saved.set(kind, to: found, address: address) else { return }
        chosen.leaving = leaving
        choose(chosen)
    }

    /// What Apple Maps finds for what is typed.
    private func searchRows(_ found: @escaping (TodoPlace, String) -> Void) -> [PickRow] {
        search.results.prefix(6).map { result in
            let id = result.title + "\u{0}" + result.subtitle
            return PickRow(id: id, title: result.title, detail: result.subtitle, symbol: "mappin", isBusy: busy == id, detailBelow: true) {
                busy = id
                Task {
                    let place = await search.place(for: result)
                    busy = nil
                    if let place { found(place, [result.title, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")) }
                }
            }
        }
    }

    /// Current Location: where you are, named by its address.
    private func hereRow(_ found: @escaping (TodoPlace, String) -> Void) -> PickRow {
        PickRow(id: "here", title: "Current Location", detail: problem?.row == "here" ? problem?.text ?? "" : "", symbol: "location.fill",
                isBusy: busy == "here", detailBelow: true) {
            guard busy == nil else { return }
            busy = "here"
            problem = nil
            Task {
                defer { busy = nil }
                guard let location = await PlaceAccess.shared.currentLocation() else {
                    problem = ("here", PlaceAccess.shared.isDenied ? "Location access is turned off for Notebook." : "Your location couldn’t be found.")
                    return
                }
                let name = await PlaceSearch.name(of: location) ?? "Current Location"
                found(TodoPlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude), name)
            }
        }
    }

    #if os(iOS)
    /// An address tapped on a card in Contacts, found in Apple Maps.
    private func fromContacts(as kind: SavedPlaces.Kind) {
        guard busy == nil else { return }
        problem = nil
        Task {
            guard let address = await ContactAddressPicker.shared.chooseAddress() else { return }
            busy = "card"
            defer { busy = nil }
            guard let found = await SavedPlaces.locate(address) else {
                problem = ("card", "That address couldn’t be found in Maps.")
                return
            }
            keep(found.place, address: found.address, as: kind)
        }
    }
    #endif

    private func choose(_ new: TodoPlace?) {
        close()
        if new != place { pick(new) }
    }
}

/// A choice in a typed picker.
struct PickRow: Identifiable {
    let id: String
    var title: String
    var detail = ""
    var symbol: String
    var isChecked = false
    var isDestructive = false
    /// Being looked up: a spinner at its end.
    var isBusy = false
    /// The detail under the title, as a place's address, rather than at the end.
    var detailBelow = false
    var action: () -> Void
    /// What touching and holding it, or a right click, offers.
    var menu: [Item] = []

    struct Item: Identifiable {
        let title: String
        let symbol: String
        var isDestructive = false
        let action: () -> Void
        var id: String { title }
    }
}

/// A field on top that has the keyboard as it opens, the choices under it, and below them whatever else the picker
/// has. ↑ and ↓ move the lit choice, Return takes it, Escape closes.
struct TypedPicker<Below: View>: View {
    let placeholder: String
    @Binding var query: String
    let rows: [PickRow]
    /// What to say when something is typed and nothing reads.
    let hint: String
    var close: () -> Void
    @ViewBuilder var below: Below
    @State private var lit = 0
    @FocusState private var isTyping: Bool

    #if os(macOS)
    static var inset: CGFloat { 6 }
    static var rowHeight: CGFloat { 30 }
    static var width: CGFloat { 288 }
    #else
    static var inset: CGFloat { 8 }
    static var rowHeight: CGFloat { 44 }
    static var width: CGFloat { 340 }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, isLit: index == lit)
                        .onHover { if $0 { lit = index } }
                }
                if rows.isEmpty, !query.isEmpty {
                    Text(hint)
                        .font(.system(size: Self.rowHeight > 40 ? 15 : 12.5))
                        .foregroundStyle(Color.theme(Theme.menuTextSecondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.inset + 9)
                        .padding(.vertical, 8)
                }
            }
            // As much room under the last choice as over the field: the dropdown's own inset, below.
            .padding(.top, Self.inset)
            below
        }
        .padding(.bottom, Self.inset)
        #if os(macOS)
        .frame(width: Self.width)
        #else
        // As wide as a popover, or as the sheet it is on iPhone.
        .frame(minWidth: 300, idealWidth: Self.width, maxWidth: .infinity)
        #endif
        // The choice it has lit, so Return keeps it; once something is typed, the first that reads.
        .onAppear { lit = rows.firstIndex(where: \.isChecked) ?? 0 }
        .onChange(of: query) { lit = 0 }
        // Another set of choices, such as Home's address to choose: the first is lit.
        .onChange(of: placeholder) { lit = 0 }
        .onChange(of: rows.count) { _, count in if lit >= count { lit = 0 } }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pickerKey)) { note in
            switch note.object as? String {
            case "down": move(1)
            case "up": move(-1)
            case "return": submit()
            case "focus": isTyping = true
            default: close()
            }
        }
        #endif
    }

    private var field: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Self.rowHeight > 40 ? 15 : 12, weight: .medium))
                .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($isTyping)
                #if os(macOS)
                .font(.system(size: 13))
                .focusOnAppear()
                #else
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onAppear { if HardwareKeyboard.shared.isAttached { isTyping = true } }
                #endif
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onSubmit { submit() }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight > 40 ? 40 : 32)
        .background(Color.theme(Theme.menuField), in: .rect(cornerRadius: 9, style: .continuous))
        .padding([.horizontal, .top], Self.inset)
    }

    @ViewBuilder
    private func rowView(_ row: PickRow, isLit: Bool) -> some View {
        if row.menu.isEmpty {
            rowButton(row, isLit: isLit)
        } else {
            rowButton(row, isLit: isLit)
                .contextMenu {
                    ForEach(row.menu) { item in
                        Button(role: item.isDestructive ? .destructive : nil, action: item.action) { Label(item.title, systemImage: item.symbol) }
                    }
                }
        }
    }

    private func rowButton(_ row: PickRow, isLit: Bool) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: Self.rowHeight > 40 ? 16 : 12, weight: .medium))
                    .foregroundStyle(row.isDestructive ? Color.red : row.isChecked ? Color.accentColor : Color.theme(Theme.menuTextSecondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .foregroundStyle(row.isDestructive ? Color.red : Color.theme(Theme.menuText))
                        .lineLimit(1)
                    if row.detailBelow, !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: Self.rowHeight > 40 ? 13 : 11))
                            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isBusy {
                    ProgressView().controlSize(.small)
                } else if !row.detailBelow, !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: Self.rowHeight > 40 ? 15 : 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                        .lineLimit(1)
                }
                if row.isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: Self.rowHeight > 40 ? 14 : 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.system(size: Self.rowHeight > 40 ? 17 : 13))
            .padding(.horizontal, 9)
            .frame(minHeight: row.detailBelow && !row.detail.isEmpty ? Self.rowHeight + 8 : Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isLit ? Color.theme(Theme.menuHighlight) : .clear))
            .padding(.horizontal, Self.inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(row.isChecked ? .isSelected : [])
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        lit = min(max(lit + step, 0), rows.count - 1)
    }

    /// Return: the lit choice; with nothing typed and nothing lit, nothing.
    private func submit() {
        guard rows.indices.contains(lit) else { return }
        rows[lit].action()
    }
}

/// One month of days to click, starting on the week's first day as the device has it, as in Issues.
struct MonthGrid: View {
    var selected: Date?
    var pick: (Date) -> Void
    @State private var month: Date

    init(selected: Date?, pick: @escaping (Date) -> Void) {
        self.selected = selected
        self.pick = pick
        let calendar = Calendar.current
        _month = State(initialValue: calendar.dateInterval(of: .month, for: selected ?? .now)?.start ?? .now)
    }

    #if os(macOS)
    private let cell: CGFloat = 26
    private let size: CGFloat = 12
    #else
    private let cell: CGFloat = 36
    private let size: CGFloat = 16
    #endif

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let weeks = (offset + length + 6) / 7
        let first = calendar.date(byAdding: .day, value: -offset, to: month) ?? month
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        VStack(spacing: 4) {
            Divider().padding(.top, 6).padding(.bottom, 4)
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: size + 0.5, weight: .semibold))
                    .foregroundStyle(Color.theme(Theme.menuText))
                Spacer()
                step("chevron.left", "Previous Month", by: -1)
                step("chevron.right", "Next Month", by: 1)
            }
            .padding(.leading, 6)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(0..<7, id: \.self) { column in
                        Text(symbols[(column + calendar.firstWeekday - 1) % 7])
                            .font(.system(size: size - 1.5))
                            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<weeks, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            dayButton(calendar.date(byAdding: .day, value: week * 7 + column, to: first) ?? first, today: today, calendar: calendar)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func dayButton(_ day: Date, today: Date, calendar: Calendar) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = day == today
        return Button { pick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: size, weight: isToday || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : inMonth ? Color.theme(Theme.menuText) : Color.theme(Theme.menuTextTertiary))
                .opacity(inMonth || isSelected ? 1 : 0.6)
                .frame(maxWidth: .infinity)
                .frame(height: cell)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(DayButtonStyle())
        .disabled(day < today)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func step(_ symbol: String, _ label: String, by months: Int) -> some View {
        Button {
            withAnimation(Theme.quick) { month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size - 2, weight: .semibold))
                .foregroundStyle(Color.theme(Theme.menuTextSecondary))
                .frame(width: cell - 4, height: cell - 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A day lit under the pointer, as a picker's rows are.
private struct DayButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered || configuration.isPressed ? Color.theme(Theme.menuHighlight) : .clear))
            .onHover { isHovered = $0 }
    }
}
