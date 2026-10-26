#if os(iOS)
import SwiftUI
import UIKit

/// A file on its own screen: a note in the editor, a PDF, picture or video as the system shows them, anything else
/// in Quick Look. The iPhone pushes one for every file you open; the iPad shows one next to the sidebar.
struct DocumentScreen: View {
    @Bindable var workspace: Workspace
    let url: URL
    /// The iPad's: Back and Forward through what you opened, and the outline in the inspector.
    var isInSplitView = false
    @State private var showsOutline = false
    @State private var exportedPDF: ExportedFile?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var kind: FileKind { FileKind(url: url, isDirectory: false) }
    private var isNote: Bool { kind == .note }
    private var isOpen: Bool { workspace.currentURL == url }
    /// The note's text is in, so it can be changed: until then only its title shows.
    private var isLoaded: Bool { isOpen && workspace.note?.isLoaded == true }
    private var name: String { SearchSection.displayName(url) }

    var body: some View {
        content
            .navigationTitle(showsTitle ? name : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(isInSplitView ? .editor : .automatic)
            .toolbar { toolbar }
            .sheet(isPresented: $showsOutline) {
                NavigationStack {
                    OutlinePanel(workspace: workspace, showsHeader: false)
                        .navigationTitle(isNote ? "Outline" : "Info")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showsOutline = false } }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $exportedPDF) { file in
                ShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
                guard isOpen else { return }
                switch notification.userInfo?["command"] as? String {
                case "showoutline": showsOutline = notification.userInfo?["argument"] as? String != "hide"
                case "exportsheet": export()
                default: break
                }
            }
            #endif
            .onChange(of: workspace.currentHeading) { _, _ in
                // Picking a heading in the outline sheet takes you there and puts the sheet away.
                if showsOutline, workspace.editor.isJumping { showsOutline = false }
            }
    }

    /// The note's name shows in the bar once its title has scrolled up under it; other files always show theirs.
    private var showsTitle: Bool {
        !isNote || (isOpen && workspace.isTitleScrolledAway)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .note:
            ZStack {
                Group {
                    if isOpen, workspace.note != nil {
                        NoteEditorHost(editor: workspace.editor)
                    } else if let snapshot = workspace.pageSnapshots[url] {
                        SnapshotView(snapshot: snapshot)
                    } else {
                        Color.theme(Theme.panel)
                    }
                }
                .background(Color.theme(Theme.panel))
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .ignoresSafeArea(.keyboard)
                // The wait for a note still in iCloud, between the bars, as a PDF's.
                if isOpen {
                    NoteWaitingView(note: workspace.note)
                }
            }
        case .pdf: PDFFileView(url: url, find: workspace.find(in: url)).id(url)
        case .image: PictureFileView(url: url).id(url)
        case .video: VideoFileView(url: url).id(url)
        default: QuickLookView(url: url).id(url).ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isInSplitView {
            ToolbarItemGroup(placement: .topBarLeading) {
                // ⌘[ and ⌘] are the Go menu's.
                Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!workspace.canGoBack)
                Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!workspace.canGoForward)
            }
        }
        if isNote, isInSplitView || sizeClass == .regular {
            ToolbarItemGroup(placement: .primaryAction) {
                FormatMenu(editor: workspace.editor)
                    .disabled(!isLoaded)
                AttachmentMenu(editor: workspace.editor)
                    .disabled(!isLoaded)
                DrawingButton(workspace: workspace)
                    .disabled(!isLoaded)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Undo while drawing, as in Notes on the iPhone. The iPad's tool picker has Undo and Redo of its own, but
            // not where it is narrow.
            if isNote, workspace.isDrawing, sizeClass == .compact {
                DrawingUndoButton(workspace: workspace)
            }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            moreMenu
        }
        if isNote, workspace.isEditing || workspace.isDrawing, !isInSplitView {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if workspace.isDrawing { workspace.editor.endDrawing() } else { workspace.editor.endEditing() }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
            }
        }
        if isInSplitView {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() }
                } label: {
                    Label(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
            }
        }
        // While drawing, the tool picker takes the bottom of the screen.
        if isNote, !isInSplitView, sizeClass == .compact, !workspace.isEditing, !workspace.isDrawing {
            ToolbarItem(placement: .bottomBar) {
                Button { workspace.editor.beginEditing(then: .checklist) } label: { Label("Checklist", systemImage: "checklist") }
                    .disabled(!isLoaded)
            }
            ToolbarItem(placement: .bottomBar) {
                AttachmentMenu(editor: workspace.editor)
                    .disabled(!isLoaded)
            }
            ToolbarItem(placement: .bottomBar) {
                DrawingButton(workspace: workspace)
                    .disabled(!isLoaded)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                NewNoteButton { workspace.newNote(in: url.deletingLastPathComponent()) }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if isNote {
                Section {
                    Button { workspace.editor.findInNote() } label: { Label("Find in Note", systemImage: "magnifyingglass") }
                        .disabled(!isLoaded)
                    if !isInSplitView {
                        Button { showsOutline = true } label: { Label("Outline", systemImage: "list.bullet.indent") }
                    }
                    Button { workspace.browseVersions() } label: { Label("Version History", systemImage: "clock.arrow.circlepath") }
                        .disabled(!isLoaded)
                }
                Section {
                    let favorite = workspace.isFavorite(url)
                    Button { workspace.toggleFavorite(url) } label: {
                        Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star")
                    }
                    Button { workspace.askForReminder(url) } label: { Label("Remind Me…", systemImage: "bell") }
                    Button { workspace.editor.focusTitle() } label: { Label("Rename", systemImage: "pencil") }
                        .disabled(!isLoaded)
                    MoveToMenu(workspace: workspace, url: url)
                    Button { workspace.duplicate(url) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                }
                Section {
                    Button { workspace.copyLink(url) } label: { Label("Copy Link", systemImage: "link") }
                    Button { export() } label: { Label("Export as PDF", systemImage: "doc.richtext") }
                        .disabled(!isLoaded)
                    Button { NoteExporter.print(workspace.editor, title: name) } label: { Label("Print", systemImage: "printer") }
                        .disabled(!isLoaded)
                }
                Section {
                    Button(role: .destructive) { workspace.moveToTrash(url) } label: { Label("Delete", systemImage: "trash") }
                }
            } else {
                if !isInSplitView {
                    Button { showsOutline = true } label: { Label("Info", systemImage: "info.circle") }
                }
                FileActions(workspace: workspace, url: url)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func export() {
        Task {
            guard let file = await NoteExporter.pdfFile(for: workspace.editor, title: name) else { return }
            exportedPDF = ExportedFile(url: file)
        }
    }
}

/// A file made to be shared, such as a note exported as PDF.
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system's share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The toolbar's Aa button: the Format panel the bar above the keyboard has, in a popover.
struct FormatMenu: View {
    let editor: EditorController
    @State private var isShown = false

    var body: some View {
        Button {
            editor.beginEditing()
            isShown = true
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .popover(isPresented: $isShown) {
            FormatPanelView(editor: editor) { isShown = false }
                .frame(width: 390)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The pencil, as in Notes: draws in the note, in the drawing at the caret or a new one; filled while drawing.
/// Takes back the last stroke; touch and hold it for Redo, which keeps the bar as it is.
struct DrawingUndoButton: View {
    let workspace: Workspace

    var body: some View {
        Menu {
            Button { workspace.editor.redoDrawing() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!workspace.canRedoDrawing)
        } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        } primaryAction: {
            workspace.editor.undoDrawing()
        }
        .disabled(!workspace.canUndoDrawing && !workspace.canRedoDrawing)
    }
}

struct DrawingButton: View {
    let workspace: Workspace

    var body: some View {
        Button { workspace.editor.toggleDrawing() } label: {
            Label(workspace.isDrawing ? "Stop Drawing" : "Drawing", systemImage: workspace.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
    }
}

/// The one editor, moved into whichever screen shows the open note.
struct NoteEditorHost: UIViewRepresentable {
    let editor: EditorController

    func makeUIView(context: Context) -> EditorContainer { EditorContainer(editor: editor) }

    func updateUIView(_ view: EditorContainer, context: Context) {
        view.claim()
    }
}

final class EditorContainer: UIView {
    let editor: EditorController

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the editor from the screen that had it, with the keyboard if it was up (a new note made from a note
    /// gets its title focused while still on the old screen).
    func claim() {
        let view = editor.view
        guard window != nil, view.superview !== self else { return }
        editor.beginMove()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        editor.endMove()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claim()
    }

    /// The screen with the editor goes, often before the next one takes the editor: the keyboard is kept for it.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil, editor.view.superview === self else { return }
        editor.beginMove()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [editor] in editor.finishMoveIfNowhere() }
    }
}

/// A note as it looked when you went on from it.
struct SnapshotView: UIViewRepresentable {
    let snapshot: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard snapshot.superview !== container else { return }
        snapshot.removeFromSuperview()
        snapshot.frame.origin = .zero
        snapshot.autoresizingMask = []
        container.addSubview(snapshot)
    }
}

extension EditorController {
    /// Puts the caret back where it was and does something there, from a button of a toolbar: the keyboard comes up
    /// as it would for a tap in the text.
    func beginEditing(then command: FormatCommand? = nil) {
        if !isFocused {
            makeTextFirstResponder()
        }
        if let command { perform(command) }
    }

    /// The Done button: the keyboard goes away, the note is saved as you type anyway.
    func endEditing() {
        textView.endEditing(true)
    }

    func findInNote() {
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
    }
}
#endif
