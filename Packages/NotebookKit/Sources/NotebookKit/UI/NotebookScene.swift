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
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        // Open at every launch, also when it was closed as Notebook quit, which it no longer does by itself.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Notebook") { Acknowledgements.showAbout() }
            }
            CommandGroup(replacing: .importExport) {
                Button { workspace.chooseAppleNotesExport() } label: { Label("Import from Apple Notes…", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(workspace.locations.isEmpty)
                Menu {
                    Button { workspace.export(as: .pdf) } label: { Label("PDF…", systemImage: "doc.richtext") }
                        .keyboardShortcut("e", modifiers: [.command, .option])
                    Button { workspace.export(as: .png) } label: { Label("PNG Image…", systemImage: "photo") }
                } label: {
                    Label("Export As", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(!workspace.hasVisibleNote)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button { workspace.attachFiles() } label: { Label("Attach File…", systemImage: "paperclip") }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!workspace.hasNoteInFront)
            }
            CommandGroup(replacing: .textEditing) {
                TextCommands(workspace: workspace, settings: settings)
            }
            CommandGroup(replacing: .printItem) {
                Button { workspace.printNote() } label: { Label("Print…", systemImage: "printer") }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!workspace.hasVisibleNote)
            }
            CommandGroup(replacing: .newItem) {
                Button { workspace.inMainWindow { workspace.newNote() } } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                Button { workspace.inMainWindow { workspace.newFolder() } } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.locations.isEmpty)
                Button { FileWindows.shared.choose() } label: { Label("Open…", systemImage: "arrow.up.forward.square") }
                    .keyboardShortcut("o", modifiers: .command)
                Menu {
                    ForEach(workspace.recentURLs.prefix(10), id: \.self) { url in
                        let kind = FileKind(url: url, isDirectory: false)
                        Button { workspace.inMainWindow { workspace.open(url) } } label: {
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
                // The file of the window you are working in, a note's own window or this one, as in Notes.
                // Dimmed with Settings in front or the main window closed: no file to act on.
                let file = workspace.fileInFront
                MoveToMenu(workspace: workspace, url: file)
                    .disabled(file == nil)
                Button { if let file { workspace.duplicate(file) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(file == nil)
                Button { workspace.renameInFront() } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(!workspace.hasNoteInFront)
                // Without ⌘⌫, which deletes to the start of the line as you type; the sidebar takes it.
                Button { if let file { workspace.trash(file) } } label: { Label("Move to Trash", systemImage: "trash") }
                    .disabled(file == nil)
                if workspace.revertNote != nil {
                    Menu {
                        Button("Last Opened") { workspace.revertToLastOpened() }
                            .disabled(!workspace.canRevertToLastOpened)
                        Divider()
                        Button("Browse All Versions…") { workspace.browseVersions() }
                    } label: {
                        Label("Revert To", systemImage: "clock.arrow.circlepath")
                    }
                }
                Divider()
                Button { workspace.chooseLocation(iCloud: false) } label: { Label("Add Location…", systemImage: "plus.rectangle.on.folder") }
            }
            // The window's own sidebar item, bound to the same state as the toolbar button.
            CommandGroup(replacing: .sidebar) {
                Button {
                    workspace.inMainWindow { withAnimation(Theme.spring) { workspace.isSidebarVisible.toggle() } }
                } label: {
                    Label(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty)
                Button {
                    workspace.inMainWindow { withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() } }
                } label: {
                    Label(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty || workspace.showsTodos)
                Divider()
                SortByPicker(folder: workspace.folderInView)
                Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                Toggle(isOn: $settings.showsOnlyNotes) { Label("Show Only Notes", systemImage: "doc.text") }
                Toggle(isOn: $settings.dimsOtherFiles) { Label("Dim Files That Aren’t Notes", systemImage: "sun.min") }
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
                // ⌘F finds in the note, as in Notes, whose search of its list is ⌥⌘F too.
                Button { workspace.inMainWindow { workspace.search.focus() } } label: { Label("Search…", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button { workspace.inMainWindow { workspace.togglePalette() } } label: { Label("Command Palette…", systemImage: "command") }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                if settings.showsTodos {
                    Button { workspace.inMainWindow { workspace.showTodos() } } label: { Label("To-dos", systemImage: "checklist") }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(workspace.locations.isEmpty)
                }
                Divider()
                Button { workspace.inMainWindow { workspace.goBack() } } label: { Label("Back", systemImage: "chevron.backward") }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button { workspace.inMainWindow { workspace.goForward() } } label: { Label("Forward", systemImage: "chevron.forward") }
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
                .disabled(!workspace.hasNoteInFront)
                formatButton(.bulletedList, #selector(MarkdownTextView.makeBulletedList(_:)), "7", [.command, .shift])
                formatButton(.numberedList, #selector(MarkdownTextView.makeNumberedList(_:)), "9", [.command, .shift])
                formatButton(.quote, #selector(MarkdownTextView.makeQuote(_:)), "'", .command)
                Divider()
                Button { workspace.editor.toggleDrawing() } label: {
                    Label(workspace.isDrawing ? "Stop Drawing" : "Drawing", systemImage: "pencil.tip.crop.circle")
                }
                // The main window's: a note's own window has no pens to draw with.
                .disabled(!workspace.isMainWindowInFront || workspace.note == nil)
                Divider()
                formatButton(.indent, #selector(MarkdownTextView.indentLines(_:)), "]", [.command, .option], name: "Increase Indent")
                formatButton(.outdent, #selector(MarkdownTextView.outdentLines(_:)), "[", [.command, .option], name: "Decrease Indent")
            }
            // The main window, also once it was closed, as Window › Notes in Notes.
            CommandGroup(before: .windowList) {
                MainWindowItem()
                Divider()
            }
        }

        Settings {
            SettingsView(workspace: workspace)
        }
    }

    private func formatButton(_ command: FormatCommand, _ action: Selector, _ key: Character, _ modifiers: EventModifiers, name: String? = nil) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: { Label(name ?? command.name, systemImage: command.symbol) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
            .disabled(!workspace.hasNoteInFront)
    }
}

/// Edit › Find, Spelling and Grammar, Transformations and Speech, as every Mac text app has them. Find finds in the
/// note (Go › Search, ⌥⌘F, finds in every note); Substitutions are left out, as Markdown needs its quotes and
/// dashes.
private struct TextCommands: View {
    let workspace: Workspace
    @Bindable var settings: NotebookSettings

    var body: some View {
        let hasNote = workspace.hasNoteInFront
        Menu {
            Button("Find…") { workspace.find(.showFindInterface) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find and Replace…") { workspace.find(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Find Next") { workspace.find(.nextMatch) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { workspace.find(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            // Without ⌘E, which is Code.
            Button("Use Selection for Find") { workspace.find(.setSearchString) }
            Button("Jump to Selection") { workspace.jumpToSelection() }
                .keyboardShortcut("j", modifiers: .command)
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .disabled(!hasNote)
        Menu {
            Button("Show Spelling and Grammar") { workspace.sendToNote(#selector(NSText.showGuessPanel(_:))) }
                .keyboardShortcut(":", modifiers: .command)
            Button("Check Document Now") { workspace.sendToNote(#selector(NSText.checkSpelling(_:))) }
                .keyboardShortcut(";", modifiers: .command)
            Divider()
            Toggle("Check Spelling While Typing", isOn: $settings.checksSpelling)
            Toggle("Check Grammar With Spelling", isOn: $settings.checksGrammar)
            Toggle("Correct Spelling Automatically", isOn: $settings.correctsSpelling)
        } label: {
            Label("Spelling and Grammar", systemImage: "textformat.abc.dottedunderline")
        }
        Menu {
            Button("Make Upper Case") { NSApp.sendAction(#selector(NSResponder.uppercaseWord(_:)), to: nil, from: nil) }
            Button("Make Lower Case") { NSApp.sendAction(#selector(NSResponder.lowercaseWord(_:)), to: nil, from: nil) }
            Button("Capitalize") { NSApp.sendAction(#selector(NSResponder.capitalizeWord(_:)), to: nil, from: nil) }
        } label: {
            Label("Transformations", systemImage: "textformat")
        }
        .disabled(!hasNote)
        Menu {
            Button("Start Speaking") { workspace.sendToNote(#selector(NSTextView.startSpeaking(_:))) }
            Button("Stop Speaking") { workspace.sendToNote(#selector(NSTextView.stopSpeaking(_:))) }
        } label: {
            Label("Speech", systemImage: "waveform")
        }
        .disabled(!hasNote)
    }
}

/// Window › Notebook: brings the main window to the front, and opens it again after it was closed.
private struct MainWindowItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Notebook") { openWindow(id: "main") }
    }
}

/// Window › Notebook: brings the main window to the front, and opens it again after it was closed.
private struct MainWindowItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Notebook") { openWindow(id: "main") }
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
