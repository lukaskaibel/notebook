import MapKit
import SwiftUI

/// A to-do's day, time and place, each picked in a dropdown as Issues picks a due date: a field that has the keyboard
/// at once and reads what is typed ("thursday in 3 weeks", "evening", a place's name), the choices to click under it,
/// and for a day, a month to click in. A pick closes it. On the Mac a glass dropdown under the button; on iPhone and
/// iPad, while a to-do is edited in To-dos, the field takes the place of the bar above the keyboard and the choices
/// rise above it (`PickerBar`), and from a note's pill a sheet.
struct TodoDatePicker: View {
    let due: TodoDue?
    var pick: (TodoDue?) -> Void
    var close: () -> Void
    @State private var query = ""
    /// Above the keyboard there is no room for a month under the choices: it is a page of its own.
    @State private var isChoosingDay = false
    @Environment(\.pickerBar) private var bar

    var body: some View {
        TypedPicker(placeholder: "Type a date, like next Thursday", symbol: "calendar", query: $query, rows: isChoosingDay ? [] : rows,
                    hint: "Try “Friday”, “in 3 weeks”, “12.11.” or “tomorrow at 9”.",
                    page: isChoosingDay ? PickPage(title: "Choose a Day") { withAnimation(Theme.spring) { isChoosingDay = false } } : nil,
                    close: close) {
            if query.isEmpty, bar == nil || isChoosingDay {
                MonthGrid(selected: due?.date(), showsDivider: bar == nil) { day in
                    choose(TodoDue(day, time: false).at(hour: due?.hour, minute: due?.minute))
                }
            }
        }
        // Typing leaves the month for what the words read.
        .onChange(of: query) { if !query.isEmpty, isChoosingDay { withAnimation(Theme.spring) { isChoosingDay = false } } }
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
        if bar != nil {
            rows.append(PickRow(id: "day", title: "Choose a Day…", symbol: "ellipsis.circle", opensPage: true) {
                withAnimation(Theme.spring) { isChoosingDay = true }
            })
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
        TypedPicker(placeholder: "Type a time, like 9:30 or evening", symbol: "clock", query: $query, rows: rows,
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
                    rows: rows, hint: "No places found.",
                    page: choosing.map { kind in PickPage(title: kind.name + " Address") { choose(address: nil) } }, close: close) {
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
            .padding(.horizontal, TypedPicker<EmptyView>.textInset)
            .padding(.top, TypedPicker<EmptyView>.inset)
        }
        .onChange(of: query) { search.query = query }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugTodos.pickerType)) { query = $0.object as? String ?? "" }
        #endif
    }

    /// Into choosing Home's or Work's address, or back out of it: a page further in, as a menu goes into a submenu.
    private func choose(address kind: SavedPlaces.Kind?) {
        problem = nil
        // On the Mac the dropdown's panel takes the new size at once.
        #if os(iOS)
        let animation: Animation? = Theme.spring
        #else
        let animation: Animation? = nil
        #endif
        withAnimation(animation) {
            query = ""
            choosing = kind
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            #if os(macOS)
            .font(.system(size: 11))
            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            #else
            .font(.footnote)
            .foregroundStyle(.secondary)
            #endif
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
            return PickRow(id: kind.rawValue, title: kind.name, detail: "Choose Address…", symbol: kind.symbol, detailBelow: true, opensPage: true) {
                choose(address: kind)
            }
        }
        let isChecked = saved.isPlace(place, kind)
        var row = PickRow(id: kind.rawValue, title: kind.name, detail: known.address, symbol: kind.symbol, isChecked: isChecked, detailBelow: true) {
            if isChecked { return close() }
            if let chosen = saved.place(kind, leaving: leaving) { choose(chosen) }
        }
        row.menu = [
            PickRow.Item(title: "Change Address…", symbol: "pencil") { choose(address: kind) },
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
    /// Goes to a page of its own: a chevron at its end, as a menu's row for a submenu has.
    var opensPage = false
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

/// A page of choices further in, such as Home's address to choose: its name over them, and the way back.
struct PickPage {
    let title: String
    var back: () -> Void
}

/// A typed picker in the bar above the keyboard, while a to-do is edited in To-dos on iPhone and iPad: its field takes
/// the place of the bar's buttons, grown out of the same glass, and its choices rise above it, so the keyboard never
/// goes down.
struct PickerBar {
    /// The bar's glass, for the field and the circle beside it to grow out of.
    let glass: Namespace.ID
    /// How tall the choices above it can be.
    var room: CGFloat
}

extension EnvironmentValues {
    @Entry var pickerBar: PickerBar?
}

/// A field that has the keyboard as it opens, the choices to it, and with them whatever else the picker has. ↑ and ↓
/// move the lit choice, Return takes it, Escape closes. On the Mac a dropdown with the field on top; on iPhone and iPad
/// in the bar above the keyboard (`PickerBar`), the field there and the choices on glass above it, or in a sheet.
struct TypedPicker<Below: View>: View {
    let placeholder: String
    /// What it picks, in the field.
    var symbol = "magnifyingglass"
    @Binding var query: String
    let rows: [PickRow]
    /// What to say when something is typed and nothing reads.
    let hint: String
    /// A page further in: its name and the way back over the choices.
    var page: PickPage?
    var close: () -> Void
    @ViewBuilder var below: Below
    @State private var lit = 0
    /// ↑ or ↓ lit a choice: Return takes it with nothing typed too.
    @State private var isLitByKeys = false
    @FocusState private var isTyping: Bool
    #if os(iOS)
    @Environment(\.pickerBar) private var bar
    #endif

    #if os(macOS)
    static var inset: CGFloat { 6 }
    static var rowHeight: CGFloat { 30 }
    static var width: CGFloat { 288 }
    /// Where the words of the choices start.
    static var textInset: CGFloat { inset + 4 }
    #else
    static var inset: CGFloat { 8 }
    static var rowHeight: CGFloat { 48 }
    static var width: CGFloat { 340 }
    static var textInset: CGFloat { inset + 14 }
    /// The glass the choices are on above the bar.
    static var panelRadius: CGFloat { 26 }
    #endif

    var body: some View {
        content
            // The choice it has lit, so Return keeps it; once something is typed, the first that reads.
            .onAppear { lit = rows.firstIndex(where: \.isChecked) ?? 0 }
            .onChange(of: query) {
                lit = 0
                isLitByKeys = false
            }
            // Another set of choices, such as Home's address to choose: the first is lit.
            .onChange(of: page?.title) {
                lit = 0
                isLitByKeys = false
            }
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
            .onChange(of: isTyping, initial: true) { DebugTodos.pickerState = debugState }
            .onChange(of: rows.map(\.title)) { DebugTodos.pickerState = debugState }
            .onChange(of: query) { DebugTodos.pickerState = debugState }
            .onChange(of: page?.title) { DebugTodos.pickerState = debugState }
            #endif
    }

    #if DEBUG
    private var debugState: String {
        "\(placeholder.debugDescription) query \(query.debugDescription), typing \(isTyping), page \(page?.title ?? "-"), rows: "
            + rows.map(\.title).joined(separator: " | ")
    }
    #endif

    // MARK: - On the Mac

    #if os(macOS)
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            VStack(alignment: .leading, spacing: 0) {
                if let page { header(page) }
                choices
                below
            }
            .id(page?.title)
            // As much room under the last choice as over the field: the dropdown's own inset, below.
            .padding(.top, Self.inset)
        }
        .padding(.bottom, Self.inset)
        .frame(width: Self.width)
    }

    private var field: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.theme(Theme.menuTextTertiary))
            textField
                .font(.system(size: 13))
                .focusOnAppear()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.theme(Theme.menuField), in: .rect(cornerRadius: 9, style: .continuous))
        .padding([.horizontal, .top], Self.inset)
    }

    private func header(_ page: PickPage) -> some View {
        Button(action: page.back) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(page.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color.theme(Theme.menuTextSecondary))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .padding(.horizontal, Self.inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func rowButton(_ row: PickRow, isLit: Bool) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(row.isDestructive ? Color.red : row.isChecked ? Color.accentColor : Color.theme(Theme.menuTextSecondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .foregroundStyle(row.isDestructive ? Color.red : Color.theme(Theme.menuText))
                        .lineLimit(1)
                    if row.detailBelow, !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isBusy {
                    ProgressView().controlSize(.small)
                } else if !row.detailBelow, !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                        .lineLimit(1)
                }
                if row.isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                } else if row.opensPage {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.theme(Theme.menuTextTertiary))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(minHeight: row.detailBelow && !row.detail.isEmpty ? Self.rowHeight + 8 : Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isLit ? Color.theme(Theme.menuHighlight) : .clear))
            .padding(.horizontal, Self.inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(row.isChecked ? .isSelected : [])
    }

    private var hintText: some View {
        Text(hint)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.theme(Theme.menuTextSecondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.inset + 9)
            .padding(.vertical, 8)
    }
    #endif

    // MARK: - On iPhone and iPad

    #if os(iOS)
    @ViewBuilder
    private var content: some View {
        if let bar {
            barContent(bar)
        } else {
            sheetContent
        }
    }

    /// In the bar above the keyboard: the field, a capsule of the bar's glass, and a circle to close it; the choices
    /// on glass above them.
    private func barContent(_ bar: PickerBar) -> some View {
        HStack(spacing: WritingBar.spacing) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                textField
                    .font(.body)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, height: WritingBar.barHeight)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                    .transition(.opacity)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, query.isEmpty ? 18 : 6)
            .frame(maxWidth: .infinity)
            .frame(height: WritingBar.barHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("bar", in: bar.glass)
            Button(action: close) {
                Image(systemName: "xmark")
                    .writingBarSymbol()
                    .foregroundStyle(Color.primary)
                    .frame(width: WritingBar.barHeight, height: WritingBar.barHeight)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("circle", in: bar.glass)
            .accessibilityLabel("Close")
        }
        .animation(Theme.quick, value: query.isEmpty)
        .overlay(alignment: .top) {
            // As tall as the choices, or as there is room for and scrolling.
            ViewThatFits(in: .vertical) {
                panel(pages.padding(.vertical, Self.inset), bar: bar)
                panel(ScrollView { pages.padding(.vertical, Self.inset) }.scrollBounceBehavior(.basedOnSize), bar: bar)
            }
            .frame(height: bar.room, alignment: .bottom)
            // Over the bar, its bottom a gap above the field.
            .alignmentGuide(.top) { $0.height + 10 }
        }
        // The field has the keyboard at once, taken over from the to-do: the keyboard stays up.
        .onAppear { DispatchQueue.main.async { isTyping = true } }
    }

    /// The glass the choices are on above the bar, grown out of the bar's.
    private func panel(_ content: some View, bar: PickerBar) -> some View {
        content
            .clipShape(.rect(cornerRadius: Self.panelRadius))
            .glassEffect(.regular, in: .rect(cornerRadius: Self.panelRadius))
            .glassEffectID("panel", in: bar.glass)
    }

    /// From a note's pill: the field on top as a sheet has it, the choices under it.
    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                textField
            }
            .font(.body)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
            pages
        }
        .padding(.bottom, 16)
        .frame(minWidth: 300, idealWidth: Self.width, maxWidth: .infinity)
        .onAppear { if HardwareKeyboard.shared.isAttached { isTyping = true } }
    }

    /// The choices, and a page further in sliding over them as a menu's submenu does.
    private var pages: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if let page { header(page) }
                choices
                below
            }
            .id(page?.title)
            .transition(.move(edge: page == nil ? .leading : .trailing).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ page: PickPage) -> some View {
        Button(action: page.back) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(page.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Self.inset)
        .accessibilityLabel("Back")
        .accessibilityHint(page.title)
    }

    private func rowButton(_ row: PickRow, isLit: Bool) -> some View {
        Button(action: row.action) {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .font(.body)
                    .foregroundStyle(row.isDestructive ? AnyShapeStyle(Color.red) : row.isChecked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .foregroundStyle(row.isDestructive ? Color.red : Color.primary)
                        .lineLimit(1)
                    if row.detailBelow, !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isBusy {
                    ProgressView()
                } else if !row.detailBelow, !row.detail.isEmpty {
                    Text(row.detail)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.isChecked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else if row.opensPage {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.body)
            .padding(.horizontal, 14)
            .frame(minHeight: row.detailBelow && !row.detail.isEmpty ? Self.rowHeight + 10 : Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(PickRowStyle(isLit: isLit))
        .padding(.horizontal, Self.inset)
        .accessibilityAddTraits(row.isChecked ? .isSelected : [])
    }

    private var hintText: some View {
        Text(hint)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.textInset)
            .padding(.vertical, 12)
    }
    #endif

    // MARK: - Both

    private var textField: some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .focused($isTyping)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            #endif
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onSubmit { submit() }
    }

    /// The choices, the lit one lit while Return takes it; a word when what is typed reads as none.
    private var choices: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, isLit: index == lit && showsLit)
                    .onHover { if $0 { lit = index } }
                    .transition(.opacity)
            }
            if rows.isEmpty, !query.isEmpty {
                hintText
            }
        }
        .animation(Theme.quick, value: rows.map(\.id))
    }

    /// The Mac lights a choice at once, as a menu does. A touch screen does once something is typed, or keys moved
    /// the light: until then Return closes.
    private var showsLit: Bool {
        #if os(macOS)
        true
        #else
        !query.isEmpty || isLitByKeys
        #endif
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

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        lit = min(max(lit + step, 0), rows.count - 1)
        isLitByKeys = true
    }

    /// Return: the lit choice. On a touch screen with nothing typed, and nothing lit by keys, it closes.
    private func submit() {
        guard showsLit else { return close() }
        guard rows.indices.contains(lit) else { return }
        rows[lit].action()
    }
}

#if os(iOS)
/// A choice lit under the finger, as a menu's rows are, or while Return takes it.
private struct PickRowStyle: ButtonStyle {
    let isLit: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.quaternary) : isLit ? AnyShapeStyle(Color.theme(Theme.menuHighlight)) : AnyShapeStyle(.clear))
            }
    }
}
#endif

/// One month of days to click, starting on the week's first day as the device has it, as in Issues.
struct MonthGrid: View {
    var selected: Date?
    /// A line over it, under the choices; none on a page of its own.
    var showsDivider = true
    var pick: (Date) -> Void
    @State private var month: Date

    init(selected: Date?, showsDivider: Bool = true, pick: @escaping (Date) -> Void) {
        self.selected = selected
        self.showsDivider = showsDivider
        self.pick = pick
        let calendar = Calendar.current
        _month = State(initialValue: calendar.dateInterval(of: .month, for: selected ?? .now)?.start ?? .now)
    }

    #if os(macOS)
    private let cell: CGFloat = 26
    private let size: CGFloat = 12
    private let margin: CGFloat = 10
    #else
    private let cell: CGFloat = 40
    private let size: CGFloat = 17
    /// The month's name in line with the words of the choices.
    private let margin: CGFloat = 16
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
            if showsDivider { Divider().padding(.top, 6).padding(.bottom, 4) }
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
        .padding(.horizontal, margin)
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
