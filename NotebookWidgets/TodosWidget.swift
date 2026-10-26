import NotebookCapture
import SwiftUI
import WidgetKit

/// Today's to-dos and the overdue ones, as Reminders' Today widget shows its reminders: the count and the first ones
/// when small, the list when larger, the count on the Lock Screen. Overdue first, in red as in To-dos. A tap on a
/// circle ticks the to-do; anywhere else opens To-dos, or the to-do in its note.
struct TodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetData.todosKind, provider: TodosTimeline()) { entry in
            TodosWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Your to-dos for today and the overdue ones.")
        .supportedFamilies(Self.families)
    }

    #if os(iOS)
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular,
                                                   .accessoryRectangular, .accessoryInline]
    #else
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    #endif
}

struct TodosEntry: TimelineEntry {
    let date: Date
    /// Overdue and today's at `date`, overdue first; nil when the app hasn't written any yet.
    let rows: [WidgetData.TodoRow]?
    /// Ticked here, on their way to the app.
    let ticked: Set<String>

    var overdue: [WidgetData.TodoRow] { rows?.filter { $0.isOverdue(at: date) } ?? [] }
    var today: [WidgetData.TodoRow] { rows?.filter { !$0.isOverdue(at: date) } ?? [] }
    /// What is still to do, without the ones just ticked.
    var count: Int { (rows ?? []).filter { !ticked.contains($0.id) }.count }

    static let sample = TodosEntry(date: .now, rows: [
        WidgetData.TodoRow(kind: .todo, text: "Pick up the dry cleaning", path: "/Errands.md", note: "Errands", line: 1, source: "",
                           due: Calendar.current.startOfDay(for: .now).addingTimeInterval(-86400), hasTime: false),
        WidgetData.TodoRow(kind: .todo, text: "Call the ryokan", path: "/Kyoto trip.md", note: "Kyoto trip", line: 2, source: "",
                           due: .now.addingTimeInterval(3600), hasTime: true),
        WidgetData.TodoRow(kind: .todo, text: "Buy a power adapter", path: "/Kyoto trip.md", note: "Kyoto trip", line: 3, source: "",
                           due: Calendar.current.startOfDay(for: .now), hasTime: false),
    ], ticked: [])
}

/// Reads what the app wrote, and moves on by itself when a to-do's time passes and at midnight.
struct TodosTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TodosEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (TodosEntry) -> Void) {
        completion(context.isPreview && WidgetData.todos == nil ? .sample : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodosEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        let times = (WidgetData.todos?.rows ?? []).filter { $0.hasTime && $0.due > now && $0.due < midnight }.map(\.due)
        let dates = [now] + Set(times + [midnight]).sorted()
        completion(Timeline(entries: dates.map(entry), policy: .after(midnight)))
    }

    private func entry(at date: Date) -> TodosEntry {
        let rows = WidgetData.todos?.rows.filter { $0.isShown(at: date) }
        let overdue = rows?.filter { $0.isOverdue(at: date) } ?? []
        let today = rows?.filter { !$0.isOverdue(at: date) } ?? []
        return TodosEntry(date: date, rows: rows.map { _ in overdue + today }, ticked: Set(WidgetData.ticked.map(\.id)))
    }
}

struct TodosWidgetView: View {
    let entry: TodosEntry
    @Environment(\.widgetFamily) private var family
    private let ink = Color("AccentColor")

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
            .widgetURL(WidgetData.todosURL)
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Image(systemName: "checklist").font(.system(size: 13, weight: .semibold))
                    Text("\(entry.count)").font(.system(size: 22, weight: .semibold, design: .rounded))
                }
            }
            .accessibilityLabel("\(entry.count) to-dos today")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Today", systemImage: "checklist")
                    .font(.headline)
                    .widgetAccentable()
                ForEach(rows(2)) { row in
                    Text(row.text).font(.subheadline).lineLimit(1)
                }
                if entry.rows?.isEmpty == true {
                    Text("Nothing to do").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(entry.count == 1 ? "1 to-do today" : "\(entry.count) to-dos today", systemImage: "checklist")
        #endif
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                header
                list(3, compact: true)
                Spacer(minLength: 0)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading) {
                    badge
                    Spacer(minLength: 0)
                    Text("\(entry.count)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Today")
                        .font(.headline)
                        .foregroundStyle(ink)
                        .widgetAccentable()
                }
                .frame(width: 76, alignment: .leading)
                list(4, compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                header
                sectioned(10)
                Spacer(minLength: 0)
            }
        }
    }

    private var badge: some View {
        Image(systemName: "checklist")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(ink, in: .circle)
            .widgetAccentable()
    }

    private var header: some View {
        HStack(alignment: .top) {
            badge
            Spacer()
            Text("\(entry.count)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
        }
    }

    private func rows(_ limit: Int) -> [WidgetData.TodoRow] {
        Array((entry.rows ?? []).prefix(limit))
    }

    @ViewBuilder private func list(_ limit: Int, compact: Bool) -> some View {
        if let rows = entry.rows {
            if rows.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                    ForEach(rows.prefix(limit)) { row in
                        TodoRowView(row: row, date: entry.date, isTicked: entry.ticked.contains(row.id), compact: compact)
                    }
                    if rows.count > limit {
                        Text("\(rows.count - limit) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("Open Notebook to see your to-dos here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Overdue, then Today, each under its name, as To-dos shows them.
    @ViewBuilder private func sectioned(_ limit: Int) -> some View {
        if entry.rows == nil || entry.rows?.isEmpty == true {
            list(limit, compact: false)
        } else {
            let overdue = entry.overdue
            let today = entry.today
            let shownOverdue = Array(overdue.prefix(limit))
            let shownToday = Array(today.prefix(max(0, limit - shownOverdue.count)))
            VStack(alignment: .leading, spacing: 7) {
                if !shownOverdue.isEmpty {
                    Text("Overdue").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    ForEach(shownOverdue) { row in
                        TodoRowView(row: row, date: entry.date, isTicked: entry.ticked.contains(row.id), compact: false)
                    }
                }
                if !shownToday.isEmpty {
                    Text("Today").font(.subheadline.weight(.semibold)).foregroundStyle(ink).widgetAccentable()
                    ForEach(shownToday) { row in
                        TodoRowView(row: row, date: entry.date, isTicked: entry.ticked.contains(row.id), compact: false)
                    }
                }
                let left = overdue.count + today.count - shownOverdue.count - shownToday.count
                if left > 0 {
                    Text("\(left) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var empty: some View {
        Label("Nothing to do", systemImage: "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// A to-do with its circle, which ticks it, and when it is due or the note it is in; a note with a reminder, its bell.
struct TodoRowView: View {
    let row: WidgetData.TodoRow
    let date: Date
    let isTicked: Bool
    let compact: Bool
    private let ink = Color("AccentColor")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 5 : 8) {
            if row.kind == .todo {
                Button(intent: TickTodoIntent(row)) {
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .font(compact ? .caption : .body)
                        .foregroundStyle(isTicked ? ink : .secondary)
                        .widgetAccentable(isTicked)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTicked ? "Ticked" : "Tick")
            } else {
                Image(systemName: "bell")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(.secondary)
            }
            Link(destination: WidgetData.url(todo: row)) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.text)
                        .font(compact ? .caption : .subheadline)
                        .strikethrough(isTicked)
                        .foregroundStyle(isTicked ? .secondary : .primary)
                        .lineLimit(compact ? 1 : 2)
                    if !compact {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(row.isOverdue(at: date) ? .red : .secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// When it is due, unless that is simply today, and the note it is in.
    private var detail: String {
        var parts: [String] = []
        if row.hasTime {
            parts.append(Calendar.current.isDate(row.due, inSameDayAs: date) ? row.due.formatted(date: .omitted, time: .shortened)
                         : row.due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        } else if row.isOverdue(at: date) {
            let days = Calendar.current.dateComponents([.day], from: row.due, to: date).day ?? 0
            parts.append(days < 7 ? row.due.formatted(.dateTime.weekday(.wide)) : row.due.formatted(.dateTime.day().month()))
        }
        if row.kind == .todo { parts.append(row.note) }
        return parts.joined(separator: " · ")
    }
}
