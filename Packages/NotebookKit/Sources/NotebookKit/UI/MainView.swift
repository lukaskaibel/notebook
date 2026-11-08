#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

/// The window: the welcome screen until there is a location, then the sidebar, the open file and its outline.
public struct RootView: View {
    @State private var workspace = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Group {
            if workspace.locations.isEmpty {
                WelcomeView(workspace: workspace)
            } else {
                MainView(workspace: workspace)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .copiedCapsule(workspace)
        .onAppear {
            // Opening a folder from a file window, or with this one closed, brings this window back.
            workspace.showWindow = { [openWindow] in openWindow(id: "main") }
            workspace.mainWindowOpened()
        }
        .onDisappear { workspace.isMainWindowOpen = false }
    }
}

/// A Mac window like the system's own: a sidebar of files, the note, and an inspector with the note's outline.
struct MainView: View {
    @Bindable var workspace: Workspace
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            VStack(spacing: 0) {
                SidebarOutline(workspace: workspace)
                SidebarTips()
                AddLocationButton(workspace: workspace)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            DetailColumn(workspace: workspace)
                .inspector(isPresented: $workspace.showsOutline) {
                    OutlinePanel(workspace: workspace)
                        .inspectorColumnWidth(min: 200, ideal: 240, max: 360)
                }
                .toolbar { DocumentToolbar(workspace: workspace) }
                .toolbar(removing: .title)
        }
        .navigationTitle(workspace.currentTitle)
        .overlay { PaletteHost(workspace: workspace, actions: paletteActions) }
        .alert(conflictTitle, isPresented: Binding(get: { workspace.note?.conflict != nil }, set: { _ in }), presenting: workspace.note?.conflict) { _ in
            Button("Keep Both") { workspace.resolveConflict(.keepBoth) }
            Button("Keep This Version") { workspace.resolveConflict(.keepThis) }
            Button("Use the Other Version") { workspace.resolveConflict(.takeOther) }
        } message: { conflict in
            Text("It changed on \(conflict.source) while you were editing it here. Keep both to have the other version as a copy next to it.")
        }
    }

    private var paletteActions: PaletteActions {
        PaletteActions(
            openSettings: { tab in
                if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
                openSettings()
            },
            newFolder: { workspace.newFolder() },
            addLocation: { workspace.chooseLocation(iCloud: false) }
        )
    }

    private var conflictTitle: String {
        "“\(workspace.currentTitle)” was changed somewhere else."
    }
}

// MARK: - Toolbar

/// Back, forward and a new note on the left; formatting, sharing, more, search and the outline on the right.
struct DocumentToolbar: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!workspace.canGoBack)
                .help("Back")
            Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!workspace.canGoForward)
                .help("Forward")
        }
        // Plain, like the buttons around it, and there with the sidebar hidden too. In a circle of its own: the toolbar
        // draws neighbouring buttons in one capsule, and on this side a ToolbarSpacer doesn't part them, so the button
        // brings its own glass.
        ToolbarItem(placement: .navigation) {
            Button { workspace.newNote() } label: {
                // The symbol as large and as high as the toolbar draws its own, in its 36 pt circle: the glass adds
                // 10 pt around the label.
                Label("New Note", systemImage: "square.and.pencil")
                    .imageScale(.large)
                    .offset(y: -1.5)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("New note (⌘N)")
        }
        .sharedBackgroundVisibility(.hidden)
        // The note's name, once its title has scrolled up under the toolbar. At most so wide that a long name never
        // pushes the search field into the toolbar's overflow menu.
        ToolbarItem(placement: .navigation) {
            Text(workspace.currentTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.leading, 6)
                .opacity(workspace.showsTodos ? (workspace.isTitleScrolledAway ? 1 : 0) : workspace.currentURL != nil && (workspace.isTitleScrolledAway || workspace.note == nil) ? 1 : 0)
                .animation(Theme.quick, value: workspace.isTitleScrolledAway)
                .accessibilityAddTraits(.isHeader)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)
        if let url = workspace.currentURL {
            if let note = workspace.note {
                ToolbarItemGroup {
                    FormatMenu(workspace: workspace).disabled(!note.isLoaded)
                    DrawingToggle(workspace: workspace).disabled(!note.isLoaded)
                }
                ToolbarSpacer(.fixed)
            } else {
                ToolbarItem {
                    Button("Open in \(workspace.appName(opening: url) ?? "App")") { workspace.openOnItsOwn(url) }
                }
                ToolbarSpacer(.fixed)
            }
            ToolbarItemGroup {
                // As on the iPad: on, the pages are drawn on right there; off again, what was drawn is in the PDF.
                if workspace.currentPDF != nil {
                    DrawingToggle(workspace: workspace)
                }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share")
                MoreMenu(workspace: workspace, url: url)
            }
            ToolbarSpacer(.fixed)
        }
        if workspace.showsTodos {
            ToolbarItem {
                Button { workspace.newTodoRequest += 1 } label: { Label("New To-do", systemImage: "plus") }
                    .help("New to-do for today")
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            SearchFieldItem(controller: workspace.search)
                .frame(width: 190, height: 36)
                .padding(.horizontal, 6)
                .help("Search notes, files and pictures (⌥⌘F)")
        }
        if !workspace.showsTodos {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() }
                } label: {
                    Label(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "sidebar.right")
                }
                .help(workspace.isOutlineVisible ? "Hide outline (⌃⌘I)" : "Show outline (⌃⌘I)")
            }
        }
    }
}

/// The formatting commands, as in Notes' Aa button: the text styles each set as it is in the note, the rest with
/// their symbols and keys, in glass like every menu of the app. They go to the note, which keeps the caret.
struct FormatMenu: View {
    let workspace: Workspace

    var body: some View {
        GlassMenuButton {
            SharedMenus.format(workspace.editor, styleSize: MenuMetrics.mac.fontSize)
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .help("Format")
    }
}

struct MoreMenu: View {
    let workspace: Workspace
    let url: URL

    var body: some View {
        GlassMenuButton {
            let favorite = workspace.isFavorite(url)
            MenuEntry(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") { workspace.toggleFavorite(url) }
            if workspace.note != nil {
                MenuEntry("Remind Me…", "bell") { workspace.askForReminder(url) }
            }
            MenuEntry.divider
            MenuEntry("Rename", "pencil", enabled: workspace.note?.isLoaded == true) { workspace.editor.focusTitle() }
            SharedMenus.moveTo(url, workspace: workspace)
            MenuEntry("Duplicate", "plus.square.on.square", keys: "⌘D") { workspace.duplicate(url) }
            MenuEntry.divider
            MenuEntry("Copy File", "doc.on.doc", keys: "⇧⌘C") { workspace.copyFile(url) }
            MenuEntry("Copy Link", "link") { workspace.copyLink(url) }
            MenuEntry("Show in Finder", "finder") { workspace.revealInFinder(url) }
            if let note = workspace.note {
                MenuEntry.divider
                MenuEntry.submenu("Export As", "square.and.arrow.up.on.square", enabled: note.isLoaded) {
                    MenuEntry("PDF…", "doc.richtext", keys: "⌥⌘E") { workspace.export(as: .pdf) }
                    MenuEntry("PNG Image…", "photo") { workspace.export(as: .png) }
                }
                MenuEntry("Print…", "printer", keys: "⌘P", enabled: note.isLoaded) { workspace.printNote() }
            }
            MenuEntry.divider
            MenuEntry("Move to Trash", "trash", destructive: true) { workspace.trash(url) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .help("More")
    }
}

// MARK: - The note

struct DetailColumn: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if workspace.showsTodos {
                TodosView(workspace: workspace)
            } else if let url = workspace.currentURL {
                if workspace.note != nil {
                    // The wait for a note still in iCloud shows below the toolbar, as a PDF's does.
                    ZStack {
                        NoteEditorView(editor: workspace.editor)
                            .ignoresSafeArea(.container, edges: .top)
                        NoteWaitingView(note: workspace.note)
                    }
                } else {
                    // What Preview and QuickTime Player open, Notebook draws itself; everything else is Quick Look's.
                    switch FileKind(url: url, isDirectory: false) {
                    case .pdf:
                        PDFFileView(url: url, find: workspace.find(in: url), isDrawing: workspace.drawsOnPDF == url, workspace: workspace) { workspace.report($0, $1) }
                            .id(url)
                    case .image: PictureFileView(url: url).id(url)
                    case .video: VideoFileView(url: url).id(url)
                    default: QuickLookView(url: url).id(url)
                    }
                }
            } else {
                EmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if workspace.isDrawingInFront {
                DrawingPalette(workspace: workspace)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: workspace.isDrawingInFront)
        .overlay {
            SwipeAnchor(swiper: workspace.pages)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }
}

/// The note fills the column and scrolls under the toolbar; AppKit starts it just below.
struct NoteEditorView: NSViewRepresentable {
    let editor: EditorController

    func makeNSView(context: Context) -> NSView { editor.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Outline

// MARK: - Welcome

struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .padding(.bottom, 18)
            Text("Your notes live in your folders")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 10)
            Text("Notebook opens the folders you already use. Notes are Markdown files next to your PDFs and photos, and everything else opens in Quick Look.")
                .font(.system(size: 15))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.bottom, 40)
            HStack(alignment: .top, spacing: 28) {
                point("folder", "Plain files", "Every note is a .md file. Move it in Finder, open it anywhere.")
                point("magnifyingglass", "Find anything", "⌥⌘F finds names, words in notes and PDFs, and text in pictures.")
                point("icloud", "On every device", "iCloud Drive keeps your Mac, iPhone and iPad in step.")
            }
            .frame(maxWidth: 820)
            .padding(.bottom, 48)
            Button {
                workspace.chooseLocation(iCloud: true)
            } label: {
                Label("Open iCloud Drive", systemImage: "icloud")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            Button("Choose another folder…") { workspace.chooseLocation(iCloud: false) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .padding(.top, 14)
            Button("Try Sample Notes…") { workspace.chooseSampleNotesFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .padding(.top, 8)
            Spacer()
            Text("You can add more folders later with Add Location at the bottom of the sidebar. Notebook only sees the folders you choose.")
                .font(.system(size: 12))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// A line of what Notebook does, as on the system's own welcome screens.
    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
