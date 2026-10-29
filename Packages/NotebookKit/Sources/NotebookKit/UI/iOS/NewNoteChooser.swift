#if os(iOS)
import SwiftUI
import UIKit

/// New Note in a toolbar, in glass of the accent colour as Done is, so that it stands out from the other buttons. It
/// makes the kind of note Settings say, or asks which, in a popover: a typed note, or a handwritten one of which paper.
struct NewNoteButton: View {
    let workspace: Workspace
    /// Where the note goes; none for the folder new notes go to.
    var folder: URL?
    @State private var asks = false
    /// The window too narrow for the choices side by side: the iPhone's, or an iPad's beside another app.
    @State private var isNarrow = false

    var body: some View {
        Button {
            switch NotebookSettings.shared.newNoteKind {
            case .ask:
                // A sidebar is compact on the iPad too: the window's width says whether there is room.
                let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                isNarrow = (window?.bounds.width ?? 0) < 600
                asks = true
            case .typed: workspace.newNote(in: folder)
            case .handwritten: workspace.newHandwrittenNote(in: folder)
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .buttonStyle(.glassProminent)
        .popover(isPresented: $asks) {
            NewNoteChooser(isCompact: isNarrow) { kind, paper in
                asks = false
                if kind == .typed { workspace.newNote(in: folder) } else { workspace.newHandwrittenNote(in: folder, paper: paper) }
            }
            .presentationCompactAdaptation(.popover)
        }
        #if DEBUG
        // newnoteask: the iPhone's popover (the iPad shows two New Notes, and two popovers at once show neither).
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            if notification.userInfo?["command"] as? String == "newnoteask", UIDevice.current.userInterfaceIdiom == .phone {
                isNarrow = true
                asks = true
            }
        }
        #endif
    }
}

/// What New Note asks: a typed note, or a handwritten one of which paper, each as its first page looks. One tap makes it.
struct NewNoteChooser: View {
    /// Where it is narrow (the iPhone): the papers under the typed note, smaller. Chosen, not fitted, so that the
    /// popover is as large as what it shows.
    var isCompact = false
    let choose: (NoteKind, PaperStyle?) -> Void

    var body: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 16) {
                    typed
                    handwritten
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    typed
                    Divider()
                    handwritten
                }
            }
        }
        .padding(isCompact ? 16 : 18)
        .fixedSize()
    }

    private var tileWidth: CGFloat { isCompact ? 50 : 58 }

    private var typed: some View {
        Section(NoteKind.typed.name) {
            ChoiceTile(caption: "Note", accessibility: "Typed Note", width: tileWidth) { TypedPagePreview() } action: { choose(.typed, nil) }
        }
    }

    private var handwritten: some View {
        Section(NoteKind.handwritten.name) {
            HStack(alignment: .top, spacing: isCompact ? 10 : 12) {
                ForEach(PaperStyle.allCases) { paper in
                    ChoiceTile(caption: paper.name, accessibility: "Handwritten Note, \(paper.name)", width: tileWidth) {
                        PaperPreview(paper: paper)
                    } action: {
                        choose(.handwritten, paper)
                    }
                }
            }
        }
    }

    /// A heading over its choices, as a list's section has.
    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                content
            }
        }
    }
}

/// A page as it looks, small, with its name under it; the whole of it takes the tap.
private struct ChoiceTile<Preview: View>: View {
    let caption: String
    let accessibility: String
    /// As tall as A4 is for its width.
    let width: CGFloat
    @ViewBuilder let preview: Preview
    let action: () -> Void

    init(caption: String, accessibility: String, width: CGFloat, @ViewBuilder preview: () -> Preview, action: @escaping () -> Void) {
        self.caption = caption
        self.accessibility = accessibility
        self.width = width
        self.preview = preview()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: width, height: (width * 1.414).rounded())
                    .clipShape(.rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressedTileStyle())
        .hoverEffect(.lift)
        .accessibilityLabel(accessibility)
    }
}

/// Pressed, a tile gives a little, as the system's buttons do.
private struct PressedTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// A typed note's first page: its title, and lines of text.
private struct TypedPagePreview: View {
    var body: some View {
        Canvas { context, size in
            let side = size.width * 0.13
            var top = size.height * 0.11
            context.fill(Path(roundedRect: CGRect(x: side, y: top, width: size.width * 0.5, height: 4.5), cornerRadius: 1.5),
                         with: .color(.primary.opacity(0.85)))
            top += 11
            for width in [0.74, 0.68, 0.72, 0.46, 0, 0.7, 0.62, 0.74, 0.38] {
                if width > 0 {
                    context.fill(Path(roundedRect: CGRect(x: side, y: top, width: size.width * width, height: 2.2), cornerRadius: 1),
                                 with: .color(.secondary.opacity(0.55)))
                }
                top += 5.6
            }
        }
        .background(Color.theme(Theme.panel))
    }
}

/// A handwritten note's paper, drawn as `NotebookPaper` draws it, with fewer lines: at this size its own would be grey.
private struct PaperPreview: View {
    let paper: PaperStyle

    private static let line = Color(red: 0.70, green: 0.78, blue: 0.87)
    private static let margin = Color(red: 0.93, green: 0.56, blue: 0.56)
    private static let dot = Color(red: 0.60, green: 0.65, blue: 0.72)

    var body: some View {
        Canvas { context, size in
            let (w, h) = (size.width, size.height)
            let spacing: CGFloat = 5.5
            func horizontal(_ y: CGFloat, from x0: CGFloat = 0, to x1: CGFloat? = nil, color: Color = Self.line, width: CGFloat = 0.6) {
                var path = Path()
                path.move(to: CGPoint(x: x0, y: y))
                path.addLine(to: CGPoint(x: x1 ?? w, y: y))
                context.stroke(path, with: .color(color), lineWidth: width)
            }
            func vertical(_ x: CGFloat, from y0: CGFloat = 0, to y1: CGFloat? = nil, color: Color = Self.line, width: CGFloat = 0.6) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y0))
                path.addLine(to: CGPoint(x: x, y: y1 ?? h))
                context.stroke(path, with: .color(color), lineWidth: width)
            }
            switch paper {
            case .blank:
                break
            case .lined:
                // From a tenth of the way down, as from 30 mm; the margin an eighth of the way in, as at 25 mm.
                for y in stride(from: h * 0.1, to: h - 2, by: spacing) { horizontal(y) }
                vertical(w * 0.12, color: Self.margin, width: 0.75)
            case .squared:
                let inset: CGFloat = 3, cell: CGFloat = 4.6
                let columns = Int((w - 2 * inset) / cell), rows = Int((h - 2 * inset) / cell)
                let x0 = (w - CGFloat(columns) * cell) / 2, y0 = (h - CGFloat(rows) * cell) / 2
                for column in 0...columns { vertical(x0 + CGFloat(column) * cell, from: y0, to: y0 + CGFloat(rows) * cell, width: 0.45) }
                for row in 0...rows { horizontal(y0 + CGFloat(row) * cell, from: x0, to: x0 + CGFloat(columns) * cell, width: 0.45) }
            case .dotted:
                let inset: CGFloat = 4, cell: CGFloat = 4.6
                for x in stride(from: inset, through: w - inset, by: cell) {
                    for y in stride(from: inset, through: h - inset, by: cell) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.55, y: y - 0.55, width: 1.1, height: 1.1)), with: .color(Self.dot))
                    }
                }
            case .cornell:
                // The heading, the cues on the left, notes on the right, the summary at the bottom.
                let heading = h * 0.09, summary = h * 0.8
                horizontal(heading, width: 0.75)
                for y in stride(from: heading + spacing, to: summary, by: spacing) { horizontal(y, width: 0.45) }
                vertical(w * 0.3, from: heading, to: summary, width: 0.75)
                horizontal(summary, width: 0.75)
            }
        }
        // Paper, white in Dark Mode too, as the pages are.
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}

/// Typed or Handwritten, for a new note with nothing in it yet: one tap makes it the other kind. It goes once a title
/// or anything else is written in it.
struct NoteKindSwitch: View {
    let workspace: Workspace
    let kind: NoteKind
    /// Symbols only, where the bar is narrow.
    let isCompact: Bool

    var body: some View {
        Picker("Kind of Note", selection: Binding(get: { kind }, set: { workspace.switchNewNote(to: $0) })) {
            ForEach(NoteKind.allCases) { kind in
                if isCompact {
                    Image(systemName: kind.symbol)
                        .accessibilityLabel(kind.name)
                        .tag(kind)
                } else {
                    Text(kind.name).tag(kind)
                }
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        // A title typed makes it a note to keep, as text does (`Workspace.editorTextDidChange`).
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { _ in
            if workspace.editor.isEditingTitle, !workspace.editor.titleText.isEmpty { workspace.freshNote = nil }
        }
    }
}
#endif
