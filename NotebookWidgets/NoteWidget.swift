import NotebookCapture
import SwiftUI
import WidgetKit

/// A note of your choice, to read on the Home Screen, the Lock Screen or the desktop: its name and as much of its text
/// as fits, styled as in the note. Chosen in Edit Widget; a tap opens it. The app keeps what it says for the widget,
/// and follows the note when it is renamed or moved.
struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetData.noteKind, intent: NoteWidgetIntent.self, provider: NoteTimeline()) { entry in
            NoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Note")
        .description("Shows a note of your choice.")
        .supportedFamilies(Self.families)
    }

    #if os(iOS)
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
    #else
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    #endif
}

struct NoteEntry: TimelineEntry {
    let date: Date
    /// The ID the note was chosen by; nil until one is.
    let id: String?
    /// What the app last wrote of it.
    let note: WidgetData.Note?

    static let sample = NoteEntry(date: .now, id: "sample", note: WidgetData.Note(path: "", title: "Kyoto trip", place: "Travel", blocks: [
        WidgetData.Block(kind: .text, runs: [WidgetData.Run("Five days in October. Flights and the ryokan are booked, everything else stays loose.")]),
        WidgetData.Block(kind: .heading(2), runs: [WidgetData.Run("Packing")]),
        WidgetData.Block(kind: .todo(done: true), runs: [WidgetData.Run("Passport")]),
        WidgetData.Block(kind: .todo(done: false), runs: [WidgetData.Run("Power adapter, type A")]),
        WidgetData.Block(kind: .todo(done: false), runs: [WidgetData.Run("Rain jacket")]),
    ], isCut: false))
}

/// One entry: the app reloads the widget when the note changes.
struct NoteTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NoteEntry { .sample }

    func snapshot(for configuration: NoteWidgetIntent, in context: Context) async -> NoteEntry {
        configuration.note == nil && context.isPreview ? .sample : entry(for: configuration)
    }

    func timeline(for configuration: NoteWidgetIntent, in context: Context) async -> Timeline<NoteEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: NoteWidgetIntent) -> NoteEntry {
        let id = configuration.note?.id
        return NoteEntry(date: .now, id: id, note: id.flatMap { WidgetData.notes[$0] })
    }
}

struct NoteWidgetView: View {
    let entry: NoteEntry
    @Environment(\.widgetFamily) private var family
    private let ink = Color("AccentColor")

    var body: some View {
        // A long note is cut off at the bottom, its start always in view.
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .containerBackground(.background, for: .widget)
            .widgetURL(entry.id.map { WidgetData.url(note: $0) })
    }

    @ViewBuilder private var content: some View {
        if let note = entry.note {
            #if os(iOS)
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 0) {
                    Text(note.title).font(.headline).lineLimit(1).widgetAccentable()
                    Text(note.blocks.prefix(3).map { $0.runs.map(\.text).joined() }.joined(separator: " · "))
                        .font(.subheadline)
                        .lineLimit(2)
                }
            } else {
                page(note)
            }
            #else
            page(note)
            #endif
        } else if entry.id != nil {
            message("Open Notebook to show this note here.")
        } else {
            message("Touch and hold the widget, then choose Edit Widget to pick a note.")
        }
    }

    private func message(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(ink)
                .widgetAccentable()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The note's name, then its lines until the widget is full; what doesn't fit is cut off at the bottom.
    private func page(_ note: WidgetData.Note) -> some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            Text(note.title)
                .font(titleFont)
                .lineLimit(2)
                .padding(.bottom, 2)
            ForEach(Array(note.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, size: textSize, ink: ink)
            }
        }
    }

    private var textSize: CGFloat {
        switch family {
        case .systemSmall: 11
        case .systemMedium: 12
        default: 13
        }
    }

    private var lineSpacing: CGFloat { family == .systemSmall ? 2 : 3 }

    private var titleFont: Font {
        family == .systemSmall ? .system(size: 15, weight: .bold) : .system(size: 18, weight: .bold)
    }
}

/// A line of the note as the editor shows it: a heading bigger and bold, a point after its bullet or number, a to-do
/// after its circle, a quote after its bar.
struct BlockView: View {
    let block: WidgetData.Block
    let size: CGFloat
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.4) {
            switch block.kind {
            case .bullet:
                Text("•").foregroundStyle(.secondary)
            case .ordered(let number):
                Text(number).foregroundStyle(.secondary).monospacedDigit()
            case .todo(let done):
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? ink : .secondary)
                    .widgetAccentable(done)
            case .quote:
                Rectangle().fill(.tertiary).frame(width: 2.5).frame(maxHeight: .infinity)
            default:
                EmptyView()
            }
            Text(text)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(isHeading ? 1 : 3)
        }
        .font(font)
        .padding(.leading, CGFloat(block.depth) * size * 1.2)
        .padding(.top, isHeading ? size * 0.3 : 0)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isHeading: Bool { if case .heading = block.kind { true } else { false } }
    private var isDone: Bool { if case .todo(true) = block.kind { true } else { false } }

    private var font: Font {
        if case .heading(let level) = block.kind {
            return .system(size: level == 1 ? size * 1.3 : level == 2 ? size * 1.15 : size, weight: .bold)
        }
        return .system(size: size)
    }

    /// The runs with their styles: bold, italic, struck through, code, highlighted, a link in the app's ink.
    private var text: AttributedString {
        var text = AttributedString()
        for run in block.runs {
            var part = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.struck || isDone { intent.insert(.strikethrough) }
            if run.code { intent.insert(.code) }
            if !intent.isEmpty { part.inlinePresentationIntent = intent }
            if run.link { part.foregroundColor = ink }
            if run.highlight { part.backgroundColor = .yellow.opacity(0.35) }
            text += part
        }
        return text
    }
}
