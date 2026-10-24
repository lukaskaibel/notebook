#if os(macOS)
import AppKit
import SwiftUI

/// The app's window, its settings and its menus. The app target only has to show this scene.
public struct NotebookScene: Scene {
    @State private var workspace = Workspace.shared
    @State private var settings = NotebookSettings.shared

    public init() {
        AppIconTip.configure()
        ReminderNotifications.activate()
    }

    public var body: some Scene {
        Window("Notebook", id: "main") {
            RootView()
                .onAppear {
                    workspace.start()
                    AppIconStore.shared.start()
                    #if DEBUG
                    DebugRemote.startIfRequested(workspace: workspace)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in workspace.saveAll() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.saveAll(quitting: true) }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .importExport) {
                Menu {
                    Button { workspace.export(as: .pdf) } label: { Label("PDF…", systemImage: "doc.richtext") }
                        .keyboardShortcut("e", modifiers: [.command, .option])
                    Button { workspace.export(as: .png) } label: { Label("PNG Image…", systemImage: "photo") }
                } label: {
                    Label("Export As", systemImage: "square.and.arrow.up.on.square")
                }
            }
            CommandGroup(replacing: .printItem) {
                Button { workspace.printNote() } label: { Label("Print…", systemImage: "printer") }
                    .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button { workspace.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                Button { workspace.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.locations.isEmpty)
                Button { FileWindows.shared.choose() } label: { Label("Open…", systemImage: "arrow.up.forward.square") }
                    .keyboardShortcut("o", modifiers: .command)
                Menu {
                    ForEach(workspace.recentURLs.prefix(10), id: \.self) { url in
                        let kind = FileKind(url: url, isDirectory: false)
                        Button { workspace.open(url) } label: {
                            Label(kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent, systemImage: kind.symbol)
                        }
                    }
                    Divider()
                    Button("Clear Menu") { workspace.clearRecents() }
                        .disabled(workspace.recentURLs.isEmpty)
                } label: {
                    Label("Open Recent", systemImage: "clock")
                }
                Divider()
                if let url = workspace.currentURL {
                    MoveToMenu(workspace: workspace, url: url)
                }
                Divider()
                Button { workspace.chooseLocation(iCloud: false) } label: { Label("Add Location…", systemImage: "plus.rectangle.on.folder") }
            }
            // The window's own sidebar item, bound to the same state as the toolbar button.
            CommandGroup(replacing: .sidebar) {
                Button {
                    withAnimation(Theme.spring) { workspace.isSidebarVisible.toggle() }
                } label: {
                    Label(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty)
                Button {
                    withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() }
                } label: {
                    Label(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty || workspace.showsTodos)
                Divider()
                Toggle(isOn: $settings.showsOnlyNotes) { Label("Show Only Notes", systemImage: "doc.text") }
                Toggle(isOn: $settings.dimsOtherFiles) { Label("Dim Files That Aren’t Notes", systemImage: "sun.min") }
                Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                // The Finder's shortcut for its hidden files.
                Button { workspace.toggleAllHiddenFolders() } label: {
                    Label(workspace.showsAllHiddenFolders ? "Hide Hidden Folders" : "Show Hidden Folders",
                          systemImage: workspace.showsAllHiddenFolders ? "eye.slash" : "eye")
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!workspace.hasHiddenFolders)
                Divider()
                Button { settings.changeTextSize(by: 1) } label: { Label("Bigger", systemImage: "textformat.size.larger") }
                    .keyboardShortcut("+", modifiers: .command)
                Button { settings.changeTextSize(by: -1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut("-", modifiers: .command)
                Button { settings.typography.size = 15 } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Go") {
                Button { workspace.search.focus() } label: { Label("Search…", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                Button { workspace.togglePalette() } label: { Label("Command Palette…", systemImage: "command") }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                if settings.showsTodos {
                    Button { workspace.showTodos() } label: { Label("To-dos", systemImage: "checklist") }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(workspace.locations.isEmpty)
                }
                Divider()
                Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!workspace.canGoForward)
            }
            CommandMenu("Format") {
                formatButton(.bold, #selector(MarkdownTextView.toggleBoldface(_:)), "b", .command)
                formatButton(.italic, #selector(MarkdownTextView.toggleItalics(_:)), "i", .command)
                formatButton(.strikethrough, #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
                formatButton(.highlight, #selector(MarkdownTextView.toggleHighlight(_:)), "h", [.command, .control])
                formatButton(.code, #selector(MarkdownTextView.toggleInlineCode(_:)), "e", .command)
                formatButton(.link, #selector(MarkdownTextView.addLink(_:)), "l", .command)
                Divider()
                formatButton(.title, #selector(MarkdownTextView.makeTitle(_:)), "t", [.command, .shift])
                formatButton(.heading, #selector(MarkdownTextView.makeHeading(_:)), "h", [.command, .shift])
                formatButton(.subheading, #selector(MarkdownTextView.makeSubheading(_:)), "j", [.command, .shift])
                formatButton(.body, #selector(MarkdownTextView.makeBody(_:)), "b", [.command, .shift])
                Divider()
                formatButton(.checklist, #selector(MarkdownTextView.makeChecklist(_:)), "l", [.command, .shift])
                Button { NSApp.sendAction(#selector(MarkdownTextView.markChecked(_:)), to: nil, from: nil) } label: {
                    Label("Mark as Checked", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                formatButton(.bulletedList, #selector(MarkdownTextView.makeBulletedList(_:)), "7", [.command, .shift])
                formatButton(.numberedList, #selector(MarkdownTextView.makeNumberedList(_:)), "9", [.command, .shift])
                formatButton(.quote, #selector(MarkdownTextView.makeQuote(_:)), "'", .command)
                Divider()
                Button { workspace.editor.toggleDrawing() } label: {
                    Label(workspace.isDrawing ? "Stop Drawing" : "Drawing", systemImage: "pencil.tip.crop.circle")
                }
                .disabled(workspace.note == nil)
                Divider()
                formatButton(.indent, #selector(MarkdownTextView.indentLines(_:)), "]", [.command, .option], name: "Increase Indent")
                formatButton(.outdent, #selector(MarkdownTextView.outdentLines(_:)), "[", [.command, .option], name: "Decrease Indent")
            }
        }

        Settings {
            SettingsView(workspace: workspace)
        }
    }

    private func formatButton(_ command: FormatCommand, _ action: Selector, _ key: Character, _ modifiers: EventModifiers, name: String? = nil) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: { Label(name ?? command.name, systemImage: command.symbol) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

/// Settings, in the system's tabbed window: where notes live, how they are set, what the sidebar shows, the app icon.
struct SettingsView: View {
    let workspace: Workspace
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(workspace: workspace) }
            Tab("Text", systemImage: "textformat", value: "text") { TextSettings() }
            Tab("Sidebar", systemImage: "sidebar.left", value: "sidebar") { SidebarSettings() }
            Tab("App Icon", systemImage: "book.closed", value: "icon") { AppIconSettings() }
        }
        .frame(width: 540, height: 460)
    }
}

struct GeneralSettings: View {
    let workspace: Workspace

    var body: some View {
        Form {
            Section("Locations") {
                ForEach(workspace.locations) { location in
                    HStack {
                        Image(systemName: location.isICloudDrive ? "icloud" : "folder")
                            .foregroundStyle(Color.theme(Theme.accent))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name)
                            Text(location.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { workspace.removeLocation(location.id) }
                    }
                }
                Button("Add Location…") { workspace.chooseLocation(iCloud: false) }
            }
            Section("New notes") {
                let folder = workspace.defaultFolder
                LabeledContent("Default folder") {
                    if folder != nil {
                        DefaultFolderPopUp(workspace: workspace, folder: folder)
                            .fixedSize()
                    } else {
                        Text("Add a location first").foregroundStyle(.secondary)
                    }
                }
                Text("Notes made with ⌘N go next to the note you have open, or into the folder you selected in the sidebar. Without either, they go to \(folder.map(workspace.place(of:)) ?? "the default folder").")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Toggle("Delete new notes left empty", isOn: Bindable(NotebookSettings.shared).deletesEmptyNewNotes)
                Text("A new note you leave or quit without giving it a title or text goes to the Trash.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Section("Search") {
                LabeledContent("Indexed") {
                    Text(workspace.index.isBuilding ? "Reading your files…" : "\(workspace.index.count) files")
                        .foregroundStyle(.secondary)
                }
                Toggle("Find text in pictures and handwriting", isOn: Bindable(NotebookSettings.shared).readsTextInPictures)
                Text("Notebook reads the words in pictures, scanned PDFs and drawings on this Mac, in the background, so search finds them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
