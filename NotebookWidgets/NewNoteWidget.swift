import NotebookCapture
import SwiftUI
import WidgetKit

/// New Note as a widget: on the Home Screen and the Mac's desktop a tile with Notebook's icon, on the Lock Screen the
/// pencil, alone or with its name. A tap anywhere on it makes the note.
struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NewNote", provider: NewNoteTimeline()) { _ in
            NewNoteWidgetView()
        }
        .configurationDisplayName("New Note")
        .description("Opens Notebook with a new note in the default folder.")
        .supportedFamilies(Self.families)
        // The whole widget is the button: it keeps the margins inside.
        .contentMarginsDisabled()
    }

    #if os(iOS)
    private static let families: [WidgetFamily] = [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
    private static let families: [WidgetFamily] = [.systemSmall]
    #endif
}

/// The widget shows nothing that changes: one entry, for good.
struct NewNoteTimeline: TimelineProvider {
    func placeholder(in context: Context) -> NewNoteEntry { NewNoteEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NewNoteEntry) -> Void) {
        completion(NewNoteEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NewNoteEntry>) -> Void) {
        completion(Timeline(entries: [NewNoteEntry(date: .now)], policy: .never))
    }
}

struct NewNoteEntry: TimelineEntry {
    let date: Date
}

struct NewNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    /// The app's accent, which widgets don't take as their tint by themselves.
    private let ink = Color("AccentColor")

    var body: some View {
        Button(intent: NewNoteIntent()) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .containerBackground(.background, for: .widget)
        #if os(iOS)
        // On a locked iPhone's Lock Screen the button only opens the app; the app makes the note for this.
        .widgetURL(NewNoteIntent.widgetURL)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .medium))
                    .offset(x: 1, y: -1)
            }
            .accessibilityLabel("New Note")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 26, weight: .medium))
                VStack(alignment: .leading, spacing: 0) {
                    Text("New Note")
                        .font(.headline)
                        .widgetAccentable()
                    Text("Notebook")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .accessoryInline:
            Label("New Note", systemImage: "square.and.pencil")
        #endif
        default:
            tile
        }
    }

    /// The Home Screen's and the desktop's: Notebook's icon and the pencil at the top, New Note below, in the ink of
    /// the app, as Reminders shows a list.
    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image("NotebookIcon")
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ink)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Text("New Note")
                .font(.title3.weight(.bold))
                .foregroundStyle(ink)
                .widgetAccentable()
        }
        .padding(margins)
    }
}
