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
            // On a view of its own: a title of another kind makes that view anew, not the file's (a PDF being drawn on).
            .background { Color.clear.modifier(DocumentTitle(workspace: workspace, url: url, title: showsTitle ? name : "", isNote: isNote, hasMenu: !isFresh)) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(isInSplitView || !isNote ? .editor : .automatic)
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
            .sheet(isPresented: Binding(get: { workspace.pdfEditing.showsOverview && workspace.drawsOnPDF == url },
                                        set: { workspace.pdfEditing.showsOverview = $0 }),
                   onDismiss: { workspace.pdfEditing.overviewClosed() }) {
                PageOverview(editing: workspace.pdfEditing)
                    // On the iPad, room for a lecture's pages at a time.
                    .presentationSizing(.page)
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

    /// The note's name shows in the bar once its title has scrolled up under it; other files always show theirs. A new
    /// note with nothing in it yet shows Typed and Handwritten there instead.
    private var showsTitle: Bool {
        !isFresh && (!isNote || (isOpen && workspace.isTitleScrolledAway))
    }

    /// A new note made a moment ago with nothing in it yet, which can still become the other kind.
    private var isFresh: Bool {
        isOpen && workspace.freshNote.map { FileNode.samePath($0, url) } == true
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
        case .pdf:
            PDFFileView(url: url, find: workspace.find(in: url), isDrawing: workspace.drawsOnPDF == url, report: { workspace.report($0, $1) },
                        editing: workspace.pdfEditing)
                .id(url)
        case .image: PictureFileView(url: url).id(url)
        case .video: VideoFileView(url: url).id(url)
        default: QuickLookView(url: url).id(url).ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isFresh {
            ToolbarItem(placement: .principal) {
                NoteKindSwitch(workspace: workspace, kind: isNote ? .typed : .handwritten, isCompact: sizeClass == .compact)
            }
        }
        if isInSplitView {
            ToolbarItemGroup(placement: .topBarLeading) {
                // ⌘[ and ⌘] are the Go menu's.
                Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!workspace.canGoBack)
                Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!workspace.canGoForward)
            }
            // As on the Mac, in a circle of its own; while the sidebar shows, New Note is at its top.
            if workspace.columnVisibility == .detailOnly {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                ToolbarItem(placement: .topBarLeading) {
                    NewNoteButton(workspace: workspace, isProminent: false)
                }
            }
        }
        if isNote, isInSplitView {
            // In the middle of the bar, as in Notes: the editor role puts secondary actions there on the iPad, and in its
            // ••• where the bar is too narrow for them.
            ToolbarItemGroup(placement: .secondaryAction) {
                FormatMenu(editor: workspace.editor)
                    .disabled(!isLoaded)
                Button { workspace.editor.beginEditing(then: .checklist) } label: { Label("Checklist", systemImage: "checklist") }
                    .disabled(!isLoaded)
                TableButton(editor: workspace.editor)
                    .disabled(!isLoaded)
                AttachmentMenu(editor: workspace.editor)
                    .disabled(!isLoaded)
                DrawingButton(workspace: workspace)
                    .disabled(!isLoaded)
            }
        } else if isNote, sizeClass == .regular {
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
            if kind == .pdf {
                // On, the pages are drawn on right there; off again, what was drawn is in the PDF.
                let drawing = workspace.drawsOnPDF == url
                if drawing, workspace.pdfEditing.pageCount > 0 {
                    // Where it is narrow, one menu, which leaves room for Done Drawing.
                    if sizeClass != .compact {
                        Button { workspace.pdfEditing.showOverview() } label: { Label("All Pages", systemImage: "square.grid.2x2") }
                    }
                    PDFAddMenu(editing: workspace.pdfEditing, hasPage: sizeClass == .compact)
                    if sizeClass != .compact { PDFPageMenu(editing: workspace.pdfEditing) }
                }
                Button { workspace.drawsOnPDF = drawing ? nil : url } label: {
                    Label(drawing ? "Done Drawing" : "Draw", systemImage: drawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
            } else if Markup.canMarkUp(kind) {
                Button { Markup.open(url, workspace: workspace) } label: { Label("Markup", systemImage: "pencil.tip.crop.circle") }
            }
            if !(kind == .pdf && workspace.drawsOnPDF == url && sizeClass == .compact) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
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
                // Next to this file, unless it is kept on its own, without its folder: then where new notes go.
                NewNoteButton(workspace: workspace, folder: workspace.isKept(url) ? nil : url.deletingLastPathComponent())
            }
        }
    }

    private var moreMenu: some View {
        AppMenuButton {
            if isNote {
                MenuEntry("Find in Note", "magnifyingglass", keys: "⌘F", enabled: isLoaded) { workspace.editor.findInNote() }
                if !isInSplitView {
                    MenuEntry("Outline", "list.bullet.indent") { showsOutline = true }
                }
                MenuEntry("Version History", "clock.arrow.circlepath", enabled: isLoaded) { workspace.browseVersions() }
                MenuEntry.divider
                let favorite = workspace.isFavorite(url)
                MenuEntry(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") { workspace.toggleFavorite(url) }
                // Kept on its own, without its folder: as in its row's menu (`FileActions`).
                let isKept = workspace.isKept(url)
                if !isKept {
                    MenuEntry("Remind Me…", "bell") { workspace.askForReminder(url) }
                    MenuEntry("Rename", "pencil", enabled: isLoaded) { workspace.editor.focusTitle() }
                    SharedMenus.moveTo(url, workspace: workspace)
                    MenuEntry("Duplicate", "plus.square.on.square") { workspace.duplicate(url) }
                }
                MenuEntry.divider
                MenuEntry("Copy", "doc.on.doc", keys: "⇧⌘C") { workspace.copyFile(url) }
                if !isKept {
                    MenuEntry("Copy Link", "link") { workspace.copyLink(url) }
                }
                MenuEntry("Export as PDF", "doc.richtext", enabled: isLoaded) { export() }
                MenuEntry("Print", "printer", keys: "⌘P", enabled: isLoaded) { NoteExporter.print(workspace.editor, title: name) }
                MenuEntry.divider
                if isKept {
                    MenuEntry("Remove from Notebook", "minus.circle", destructive: true) { workspace.removeKeptFile(url) }
                } else {
                    MenuEntry("Delete", "trash", destructive: true) { workspace.trash(url) }
                }
            } else {
                if !isInSplitView {
                    MenuEntry("Info", "info.circle") { showsOutline = true }
                }
                FileActions.entries(workspace, url)
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

/// The bar's title. A note is renamed in its own title, in the page; any other file by tapping its name in the bar,
/// as in Files and Pages.
private struct DocumentTitle: ViewModifier {
    let workspace: Workspace
    let url: URL
    let title: String
    let isNote: Bool
    /// Rename, for a file's name; not while a new note shows Typed and Handwritten in its place.
    let hasMenu: Bool

    func body(content: Content) -> some View {
        if isNote || !hasMenu {
            content.navigationTitle(title)
        } else {
            content
                .navigationTitle(Binding(get: { title }, set: { workspace.rename(url, typed: $0) }))
                .toolbarTitleMenu { RenameButton() }
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
            // As Attach does: in a note you haven't put the caret in, the styles are for its last line.
            editor.placeCaretForToolbar()
            editor.beginEditing()
            isShown = true
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .popover(isPresented: $isShown) {
            FormatPanelView(editor: editor) { isShown = false }
                // Room for Title, Heading, Subheading and Body side by side in every typeface, SF Mono's the widest;
                // at 390 Body was cut off.
                .frame(width: 460)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Pictures for the page in view, and new pages, while drawing on a PDF; where it is narrow, the page's paper too.
struct PDFAddMenu: View {
    let editing: PDFEditing
    var hasPage = false

    var body: some View {
        AppMenuButton {
            for source in AttachmentSource.available {
                MenuEntry(source == .files ? "Choose File" : source.name, source == .files ? "folder" : source.symbol) { editing.addPictures(from: source) }
            }
            MenuEntry.divider
            if hasPage {
                MenuEntry("All Pages", "square.grid.2x2") { editing.showOverview() }
                PDFPageMenu.entries(editing)
            } else {
                PDFPageMenu.papers("Add Page", "doc.badge.plus") { editing.addPage($0) }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }
}

/// The page in view: a page after it, its paper, and taking it out.
struct PDFPageMenu: View {
    let editing: PDFEditing

    var body: some View {
        AppMenuButton {
            Self.entries(editing)
        } label: {
            Label("Page", systemImage: "doc.on.doc")
        }
    }

    @MenuContent
    static func entries(_ editing: PDFEditing) -> [MenuEntry] {
        MenuEntry.section("Page \(editing.pageIndex + 1) of \(editing.pageCount)")
        papers("Add Page After", "doc.badge.plus") { editing.addPage($0) }
        // Only paper Notebook made: under a page of another PDF is what it shows.
        if let paper = editing.paper {
            papers("Paper", "doc.richtext", checked: paper) { editing.changePaper(to: $0) }
        }
        MenuEntry.divider
        MenuEntry("Delete Page", "trash", enabled: editing.pageCount >= 2, destructive: true) { editing.deletePage() }
    }

    /// A submenu of the papers, for a new page or a handwritten note; the one a page has ticked.
    static func papers(_ title: String, _ symbol: String, checked: PaperStyle? = nil, action: @escaping (PaperStyle) -> Void) -> MenuEntry {
        .submenu(title, symbol) {
            for paper in PaperStyle.allCases {
                MenuEntry(paper.name, paper.symbol, checked: paper == checked) { action(paper) }
            }
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
    /// The screen whose bars follow the text view, while this has the editor.
    private weak var barsController: UIViewController?

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
        becomeContentScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Back from a screen pushed over the note that left it the editor (a folder from a link): its bars follow the
        // text view again, which they stopped doing when it went.
        if window != nil, editor.view.superview === self { becomeContentScrollView() }
        claim()
    }

    /// The bars blur and fade what scrolls under them, as in Notes, only over the scroll view their screen names, and
    /// SwiftUI names none for a text view of UIKit's: without this the toolbar's buttons sit on sharp text and the
    /// navigation bar draws a hard edge.
    private func becomeContentScrollView() {
        let textView = editor.textView
        textView.topEdgeEffect.style = .soft
        textView.bottomEdgeEffect.style = .soft
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController, controller.parent is UINavigationController {
                controller.setContentScrollView(textView, for: [.top, .bottom])
                barsController = controller
                return
            }
            responder = next
        }
    }

    /// The iPad's page shows a PDF, a picture or To-dos where the note was, on the same screen: its bars go back to
    /// what that shows, rather than following a text view that isn't there. A screen that took the editor already
    /// named it for itself.
    private func resignContentScrollView() {
        guard let controller = barsController, controller.contentScrollView(for: .top) === editor.textView else { return }
        controller.setContentScrollView(nil, for: [.top, .bottom])
        barsController = nil
    }

    /// The screen with the editor goes, often before the next one takes the editor: the keyboard is kept for it.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil, editor.view.superview === self else { return }
        resignContentScrollView()
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
    /// The Done button: the keyboard goes away, the note is saved as you type anyway.
    func endEditing() {
        textView.endEditing(true)
    }

    func findInNote(replacing: Bool = false) {
        textView.findInteraction?.presentFindNavigator(showingReplace: replacing)
    }
}
#endif
