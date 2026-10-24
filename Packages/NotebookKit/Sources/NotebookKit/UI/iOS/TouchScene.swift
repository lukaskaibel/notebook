#if os(iOS)
import SwiftUI
import UIKit

/// The app's window on iPhone and iPad, and the menus of an iPad's menu bar and hardware keyboard. The app target only
/// has to show this scene.
public struct NotebookScene: Scene {
    @State private var workspace = Workspace.shared

    public init() {
        // Before a tap on a reminder's notification, which can be what started the app, reaches it.
        ReminderNotifications.activate()
        // Before the first frame, which would otherwise show the welcome screen until the locations are read.
        Workspace.shared.start()
    }

    public var body: some Scene {
        WindowGroup {
            TouchRootView(workspace: workspace)
                .onAppear {
                    #if DEBUG
                    DebugRemote.startIfRequested(workspace: workspace)
                    #endif
                }
                .onOpenURL { url in workspace.openFromOutside(url) }
                .continuesSpotlight(workspace)
        }
        .commands { TouchCommands(workspace: workspace) }
        // Reminders set on another device: iOS doesn't wake the app for them, but gives it time now and then.
        .backgroundTask(.appRefresh(Workspace.reminderRefreshTask)) {
            await Workspace.shared.refreshRemindersInBackground()
        }
    }
}

/// The welcome screen until there is a location; then the iPhone's screens, or the iPad's sidebar and page. An iPad
/// window as narrow as a phone gets the phone's screens.
struct TouchRootView: View {
    @Bindable var workspace: Workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if workspace.locations.isEmpty {
                TouchWelcomeView(workspace: workspace)
            } else if sizeClass == .compact {
                PhoneBrowser(workspace: workspace)
            } else {
                PadBrowser(workspace: workspace)
            }
        }
        .tint(Color.theme(Theme.accent))
        .quickLookPreview($workspace.quickLookURL)
        .alert(conflictTitle, isPresented: Binding(get: { workspace.note?.conflict != nil }, set: { _ in }), presenting: workspace.note?.conflict) { _ in
            Button("Keep Both") { workspace.resolveConflict(.keepBoth) }
            Button("Keep This Version") { workspace.resolveConflict(.keepThis) }
            Button("Use the Other Version") { workspace.resolveConflict(.takeOther) }
        } message: { conflict in
            Text("It changed on \(conflict.source) while you were editing it here. Keep both to have the other version as a copy next to it.")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                workspace.saveAll()
                workspace.scheduleReminderRefresh()
            case .inactive: workspace.saveAll()
            case .active: workspace.refresh()
            @unknown default: break
            }
        }
    }

    private var conflictTitle: String {
        "“\(workspace.currentTitle)” was changed somewhere else."
    }
}

/// The iPad's menu bar and keyboard shortcuts, as on the Mac. Bold and italic are the text view's own (⌘B, ⌘I).
struct TouchCommands: Commands {
    let workspace: Workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button { workspace.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace.locations.isEmpty)
        }
        // The system's own reach only what has the focus; these reach the changes to files too (`Workspace+Undo`).
        CommandGroup(replacing: .undoRedo) {
            Button { workspace.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
            Button { workspace.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // The Finder's shortcut for its hidden files, as on the Mac.
        CommandGroup(after: .sidebar) {
            Button { withAnimation { workspace.toggleAllHiddenFolders() } } label: {
                Label(workspace.showsAllHiddenFolders ? "Hide Hidden Folders" : "Show Hidden Folders",
                      systemImage: workspace.showsAllHiddenFolders ? "eye.slash" : "eye")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!workspace.hasHiddenFolders)
        }
        CommandMenu("Go") {
            Button { workspace.searchRequest += 1 } label: { Label("Search", systemImage: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
            Button { workspace.togglePalette() } label: { Label("Command Palette", systemImage: "command") }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(workspace.locations.isEmpty)
            if NotebookSettings.shared.showsTodos {
                Button { workspace.showTodos() } label: { Label("To-dos", systemImage: "checklist") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(workspace.locations.isEmpty)
            }
            Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!workspace.canGoBack)
            Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!workspace.canGoForward)
        }
        // In the system's Format menu, after its Bold and Italic, which the text view turns into Markdown. The keys
        // themselves reach the note through its text view (`FormatShortcut`).
        CommandGroup(after: .textFormatting) {
            ForEach(Array(FormatShortcut.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.name) { shortcut in format(shortcut) }
            }
        }
    }

    private func format(_ shortcut: FormatShortcut) -> some View {
        Button { workspace.editor.perform(shortcut) } label: { Label(shortcut.name, systemImage: shortcut.symbol) }
            .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.modifiers)
            .disabled(workspace.note == nil)
    }
}

/// The first screen: where your notes are. Notebook reads the folders you pick; it keeps no notes of its own.
struct TouchWelcomeView: View {
    let workspace: Workspace
    @State private var picksFolder = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(uiImage: Self.appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 56)
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
                Text("Your notes live in your folders")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
                Text("Notebook opens the folders you already use. Notes are Markdown files next to your PDFs and photos.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 36)
                VStack(alignment: .leading, spacing: 22) {
                    point("folder", "Plain files", "Every note is a .md file. Move it in Files, open it anywhere.")
                    point("magnifyingglass", "Find anything", "Search finds names, notes, PDFs and text in pictures.")
                    point("icloud", "On every device", "iCloud Drive keeps your iPhone, iPad and Mac in step.")
                }
                .padding(.bottom, 40)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button { picksFolder = true } label: {
                    Label("Choose a Folder", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Keep Notes on This \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")") {
                    workspace.addLocation(Workspace.onDeviceFolder)
                }
                .font(.subheadline)
                Text("Pick iCloud Drive to have the notes you write on your Mac here too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .folderImporter(isPresented: $picksFolder, workspace: workspace)
    }

    /// The app's icon, as the Home Screen shows it.
    static var appIcon: UIImage {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (primary?["CFBundleIconFiles"] as? [String])?.last ?? primary?["CFBundleIconName"] as? String ?? "AppIcon"
        return UIImage(named: name) ?? UIImage(systemName: "book.closed.fill") ?? UIImage()
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings, as a sheet: where notes live, how they are set, and what the lists show.
struct TouchSettings: View {
    @Bindable var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var addsLocation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(workspace.locations) { location in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(location.name)
                                Text(location.place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: location.isICloudDrive ? "icloud" : "folder")
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { workspace.removeLocation(location.id) }
                        }
                    }
                    Button { addsLocation = true } label: { Label("Add Location", systemImage: "plus") }
                } header: {
                    Text("Locations")
                } footer: {
                    Text("Notebook shows the folders you add here and works on their files in place. Removing one leaves its files where they are.")
                }
                Section {
                    NavigationLink { TextSettings().navigationTitle("Text") } label: { Label("Text", systemImage: "textformat") }
                    NavigationLink { SidebarSettings().navigationTitle("Files") } label: { Label("Files", systemImage: "folder") }
                    NavigationLink { WritingBarSettings() } label: { Label("Writing Bar", systemImage: "keyboard") }
                    if let folder = workspace.defaultFolder {
                        NavigationLink { DefaultFolderList(workspace: workspace) } label: {
                            LabeledContent("Default Folder", value: workspace.folderName(folder))
                        }
                    } else {
                        LabeledContent("Default Folder", value: "–")
                    }
                    Toggle("Delete New Notes Left Empty", isOn: Bindable(NotebookSettings.shared).deletesEmptyNewNotes)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("New notes go into the folder you’re in; made anywhere else, they go to the default folder. A new note you leave without giving it a title or text is deleted.")
                }
                TodosSetting()
                Section {
                    LabeledContent("Indexed") {
                        Text(workspace.index.isBuilding ? "Reading your files…" : "\(workspace.index.count) files")
                    }
                    Toggle("Find Text in Pictures", isOn: Bindable(NotebookSettings.shared).readsTextInPictures)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Notebook reads the words in pictures, scanned PDFs and handwriting on this device, in the background, so search finds them.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .folderImporter(isPresented: $addsLocation, workspace: workspace)
        }
    }
}
/// Which tools the bar above the keyboard has, and in what order.
struct WritingBarSettings: View {
    @Bindable private var settings = NotebookSettings.shared
    /// Closes the list where it is a sheet of its own, opened from the bar.
    var done: (() -> Void)?

    private var others: [WritingTool] {
        WritingTool.allCases.filter { $0.isAvailable && !settings.writingBarTools.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(settings.writingBarTools) { tool in
                    Label(tool.name, systemImage: tool.symbol)
                }
                .onMove { settings.writingBarTools.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.writingBarTools.remove(atOffsets: $0) }
            } header: {
                Text("In the Bar")
            } footer: {
                Text("The bar shows as many as fit; swipe it for the next page.")
            }
            if !others.isEmpty {
                Section("More Tools") {
                    ForEach(others) { tool in
                        Button {
                            withAnimation { settings.writingBarTools.append(tool) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "plus.circle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .foregroundStyle(.green)
                                    .font(.title3)
                                Label(tool.name, systemImage: tool.symbol)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .accessibilityLabel("Add \(tool.name)")
                    }
                }
            }
            Section {
                Button("Reset to Default") {
                    withAnimation { settings.writingBarTools = WritingTool.standard }
                }
                .disabled(settings.writingBarTools == WritingTool.standard)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Writing Bar")
        .navigationBarTitleDisplayMode(done == nil ? .automatic : .inline)
        .toolbar {
            if let done {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
    }
}
#endif
