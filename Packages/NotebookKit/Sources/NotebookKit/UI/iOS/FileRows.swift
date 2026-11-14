#if os(iOS)
import SwiftUI
import UIKit

/// A file or folder in a list, as the Files app shows one: its symbol in its kind's colour, the name, and a cloud for
/// a file that is still only in iCloud. Notes say when they were changed and how they start, as in Notes.
struct FileRow: View {
    let workspace: Workspace
    let url: URL
    let name: String
    let kind: FileKind
    var isInCloud = false
    /// Instead of the kind's symbol: a star for a favourite folder, a cloud for iCloud Drive.
    var symbol: String?
    /// A folder's symbol or emoji and colour, if you chose any (Customize Folder).
    var icon: FolderIcon?
    /// Shows the date and the start of a note, or the date and size of a file, under the name.
    var showsDetail = false
    /// The date to show: when the file was last edited, or when it was made while the newest made come first, as in
    /// Notes. Without one, when search last read it edited.
    var date: Date?
    /// A hidden folder, there while its location shows hidden folders.
    var isHidden = false
    /// A folder unfolded under another on the first screen: its name greyed, as the one it is in leads.
    var isQuiet = false
    /// How many files and folders a folder holds, at the row's end, as Notes counts a folder's notes.
    var count: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Hidden folders show dimmed, as hidden files in the Files app and the Finder.
        let dimmed = NotebookSettings.shared.dimsOtherFiles && kind != .folder && kind != .note || isHidden
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    // At the largest text sizes a name goes on over a few lines, as in Files, rather than losing its
                    // middle.
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                    .foregroundStyle(dimmed || isInCloud || isQuiet ? .secondary : .primary)
                if showsDetail, let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Group {
                if let emoji = icon?.emoji {
                    Text(emoji)
                } else {
                    Image(systemName: icon.flatMap { $0.symbol == nil ? nil : $0.shownSymbol } ?? symbol ?? kind.symbol)
                        .foregroundStyle(tint)
                }
            }
            .opacity(dimmed ? 0.5 : 1)
        }
        .badge(badge)
        .accessibilityLabel(accessibilityName)
        // Folders on screen are read ahead, so opening one shows its files straight away.
        .onAppear { if kind == .folder { workspace.prefetch(url) } }
    }

    private var reminder: Reminder? {
        kind == .note ? workspace.reminder(for: url) : nil
    }

    /// A reminder's bell, red once its time has passed, before the cloud of a file still in iCloud.
    private var badge: Text? {
        if kind == .folder, let count { return Text(count, format: .number) }
        if let reminder { return Text(Image(systemName: reminder.date == nil ? "location.fill" : "bell.fill")).foregroundStyle(reminder.isOverdue ? Color.red : Color.secondary) }
        return isInCloud ? Text(Image(systemName: "icloud.and.arrow.down")) : nil
    }

    private var accessibilityName: String {
        if let reminder { return "\(name), reminder \(reminder.text)" }
        return isHidden ? "\(name), hidden" : isInCloud ? "\(name), in iCloud" : name
    }

    private var tint: Color {
        icon?.color?.color ?? Color.theme(kind.tint)
    }

    /// "Yesterday  Get an ICOCA card at the airport…" for a note; "12 Oct 2026 · 84 KB" for any other file.
    private var detail: String? {
        guard kind != .folder else { return nil }
        let entry = workspace.index.entry(for: url)
        let date = (self.date ?? entry?.modified).map(Self.shortDate)
        if kind == .note {
            // Until search has read the note (on the first launch, or while it is still in iCloud), only its date:
            // "No additional text" is for a note that has none.
            guard let text = entry?.text else { return date }
            let start = NoteSyntax(url: url) == .asciidoc
                ? NotePoints.beginning(of: text, title: url.deletingPathExtension().lastPathComponent, maximumLength: 120, syntax: .asciidoc)
                    .split(separator: "\n").first.map(String.init) ?? ""
                : Self.firstLine(text)
            return [date, start.isEmpty ? "No additional text" : start].compactMap { $0 }.joined(separator: "  ")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [date, size].compactMap { $0 }.joined(separator: " · ")
    }

    /// As Notes dates a note: the time today, "Yesterday", the weekday this week, the date before that.
    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The first line of a note with words in it, as you read it: without its Markdown.
    @MainActor
    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            var plain = line.trimmingCharacters(in: .whitespaces)
            if plain.hasPrefix("---") || plain.hasPrefix("```") || plain.hasPrefix("$$") || plain.hasPrefix("![") || plain.hasPrefix("|") { continue }
            while let first = plain.first, "#>-*+ ".contains(first), plain.count > 1 { plain.removeFirst() }
            if let box = Todos.checkboxLength(Substring(plain)) { plain.removeFirst(box) }
            plain = InlineRenderer.render(plain, font: .systemFont(ofSize: 15), color: .label).string
            if !plain.trimmingCharacters(in: .whitespaces).isEmpty { return plain }
        }
        return ""
    }
}

extension FileNode {
    /// A row for this file in a list.
    @MainActor
    func row(in workspace: Workspace, showsDetail: Bool = false, isQuiet: Bool = false, count: Int? = nil) -> FileRow {
        // The dates came with the folder's files, so they show at once, and say what the list is sorted by.
        let byCreation = showsDetail && NotebookSettings.shared.fileOrders.order(of: url.deletingLastPathComponent()) == .dateCreated
        return FileRow(workspace: workspace, url: url, name: isLinked ? name : workspace.newName(for: url) ?? (kind == .folder ? workspace.folderName(url) : name),
                       kind: kind, isInCloud: isInCloud, icon: icon, showsDetail: showsDetail, date: byCreation ? created : modified,
                       isHidden: isFolder && workspace.isHidden(url), isQuiet: isQuiet, count: count)
    }
}

extension Workspace {
    /// What a folder shows: nothing until it has been read, which happens off the main thread when first asked for
    /// (with the folders on the way to it), and again whenever files change in it. Hidden folders stay out unless their
    /// location shows them, and so do files on their way to the Trash.
    func visibleChildren(of folder: URL) -> [FileNode] {
        _ = treeVersion
        guard let node = node(for: folder, reading: false) else {
            readFolders(to: folder, including: true)
            return []
        }
        read([node])
        let children = shownChildren(of: node, in: location(containing: folder))
        return leaving.isEmpty ? children : children.filter { !isLeaving($0.url) }
    }

    /// Whether a folder has been read, so a list says "Empty" only when it is.
    func isRead(_ folder: URL) -> Bool {
        _ = treeVersion
        return hasRead(folder)
    }

    /// A row for any file, found again by its address.
    func row(for url: URL, showsDetail: Bool = false, favorite: Bool = false) -> FileRow {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind = FileKind(url: url, isDirectory: isFolder)
        let name = kind == .folder ? folderName(url) : SearchSection.displayName(url)
        let isLocation = locations.contains { $0.url == url.standardizedFileURL }
        // A favourite folder shows the look you gave it, else a star.
        let icon = kind == .folder && !isLocation ? folderIcon(for: url) : nil
        let symbol = isLocation ? (Location.isICloudDriveRoot(url) || url.path == Location.iCloudDrivePath ? "icloud" : "externaldrive") : favorite && kind == .folder && icon == nil ? "star" : nil
        return FileRow(workspace: self, url: url, name: name, kind: kind, symbol: symbol, icon: icon, showsDetail: showsDetail)
    }
}

/// A folder still being read: nothing for a wait too short to notice, then a spinner, as for files.
struct FolderLoadingIndicator: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .opacity(isShown ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isShown)
            .task {
                try? await Task.sleep(for: .seconds(0.6))
                if !Task.isCancelled { isShown = true }
            }
    }
}

/// Dragging files onto folders: within Notebook's locations they move, from other apps they are copied in.
struct FileDragAndDrop: ViewModifier {
    let workspace: Workspace
    let url: URL
    let isFolder: Bool
    var canDrag = true
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isFolder {
            dragged(content)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter { $0.isFileURL && $0.standardizedFileURL != url.standardizedFileURL }
                    guard !files.isEmpty, !files.contains(where: { url.path.hasPrefix($0.path + "/") }) else { return false }
                    withAnimation { workspace.drop(files, into: url) }
                    return true
                } isTargeted: { isTargeted = $0 }
                .listRowBackground(isTargeted ? Color.accentColor.opacity(0.18) : nil)
        } else {
            dragged(content)
        }
    }

    @ViewBuilder
    private func dragged(_ content: Content) -> some View {
        if canDrag, !workspace.isLinkedFolder(url) {
            content.draggable(url)
        } else {
            content
        }
    }
}

extension View {
    func fileDragAndDrop(_ url: URL, isFolder: Bool, workspace: Workspace, canDrag: Bool = true) -> some View {
        modifier(FileDragAndDrop(workspace: workspace, url: url, isFolder: isFolder, canDrag: canDrag))
    }
}

/// Everything you can do with a file or folder, for its menu and the ⋯ menu of an open file.
@MainActor
enum FileActions {
    /// `newFolder` asks for the name of a new folder in this one.
    @MenuContent
    static func entries(_ workspace: Workspace, _ url: URL, newFolder: ((URL) -> Void)? = nil) -> [MenuEntry] {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind = FileKind(url: url, isDirectory: isFolder)
        let isLinked = workspace.isLinkedFolder(url)
        let isLocation = workspace.locations.contains { $0.url == url.standardizedFileURL }
        // Kept on its own: Notebook has the file, not its folder, which renaming, moving, duplicating and deleting
        // need, and a link to it would find nothing, as search doesn't read it.
        let isKept = workspace.isKept(url)
        if isFolder {
            MenuEntry("New Note", "square.and.pencil") { workspace.newNote(in: url) }
            MenuEntry.submenu("New Handwritten Note", "pencil.and.scribble") {
                for paper in PaperStyle.allCases {
                    MenuEntry(paper.name, paper.symbol) { workspace.newHandwrittenNote(in: url, paper: paper) }
                }
            }
            if let newFolder {
                MenuEntry("New Folder", "folder.badge.plus") { newFolder(url) }
            }
            MenuEntry.divider
        } else if kind != .note {
            MenuEntry("Quick Look", "eye") { workspace.quickLook(url) }
            MenuEntry.divider
        }
        if kind == .note, !isKept {
            MenuEntry("Remind Me…", "bell") { workspace.askForReminder(url) }
        }
        if !isLinked, !isLocation, !isKept {
            MenuEntry("Rename", "pencil") { workspace.renaming = url }
            SharedMenus.moveTo(url, workspace: workspace)
            MenuEntry("Duplicate", "plus.square.on.square") { workspace.duplicate(url) }
        }
        let favorite = workspace.isFavorite(url)
        MenuEntry(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") {
            withAnimation { workspace.toggleFavorite(url) }
        }
        if isFolder, workspace.canCustomize(url) {
            MenuEntry("Customize Folder…", "paintpalette") { workspace.customizeFolder(url) }
        }
        if isFolder, workspace.canHide(url) {
            let isHidden = workspace.isHidden(url)
            MenuEntry(isHidden ? "Unhide Folder" : "Hide Folder", isHidden ? "eye" : "eye.slash") {
                withAnimation { workspace.setHidden(url, !isHidden) }
            }
        }
        MenuEntry.divider
        // The file itself, as Copy in Files: pasted in a note it is a link to it.
        if !isLocation {
            MenuEntry("Copy", "doc.on.doc", keys: "⇧⌘C") { workspace.copyFile(url) }
        }
        if !isFolder, !isKept {
            MenuEntry("Copy Link", "link") { workspace.copyLink(url) }
        }
        MenuEntry.share([url])
        if isLocation, let location = workspace.locations.first(where: { $0.url == url.standardizedFileURL }) {
            if workspace.hasHiddenFolders(in: location) {
                MenuEntry.divider
                ShowHiddenFolders.entry(workspace, location)
            }
            MenuEntry.divider
            MenuEntry("Remove from Notebook", "minus.circle", destructive: true) { workspace.removeLocation(location.id) }
        } else if isKept {
            MenuEntry.divider
            MenuEntry("Remove from Notebook", "minus.circle", destructive: true) { withAnimation { workspace.removeKeptFile(url) } }
        } else if !isLinked {
            MenuEntry.divider
            MenuEntry("Delete", "trash", destructive: true) { workspace.trash(url) }
        }
    }
}

/// A file to move, chosen with a swipe or from a menu.
struct MovingFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Move, as Notes and Files ask for it on the iPhone: every folder of every location, indented under its location,
/// the one the file is in greyed.
struct MoveSheet: View {
    let workspace: Workspace
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(workspace.moveTargets(for: url), id: \.location.id) { target in
                    Section(target.location.name) {
                        ForEach(target.folders, id: \.url) { folder in
                            let isHere = folder.url.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL
                            Button {
                                workspace.move(url, into: folder.url)
                                dismiss()
                            } label: {
                                Label {
                                    Text(folder.depth < 0 ? target.location.name : folder.name)
                                        .foregroundStyle(isHere ? .secondary : .primary)
                                } icon: {
                                    Image(systemName: folder.depth >= 0 ? "folder" : target.location.isICloudDrive ? "icloud" : "externaldrive")
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.leading, CGFloat(max(0, folder.depth)) * 18)
                            }
                            .tint(.primary)
                            .disabled(isHere)
                        }
                    }
                }
            }
            .navigationTitle("Move “\(SearchSection.displayName(url))”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// The search results as a list's content: Recent with an empty field, then Files, Folders, Headings, In Notes and
/// PDFs, In Pictures and Drawings, and New Note. They come from a search in the background, so typing never waits: the
/// screen with the search field hands what is typed to `workspace.searchSession`.
struct SearchResultsList: View {
    let workspace: Workspace
    let query: String
    var open: (SearchResult) -> Void

    var body: some View {
        ForEach(workspace.searchSession.sections) { section in
            // Without what was just deleted, which search finds until it has read the folder again.
            let items = section.items.filter { item in item.result.url.map { !workspace.isThrownAway($0) } ?? true }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        Button { open(item.result) } label: { row(item) }
                            .buttonStyle(.plain)
                            .appContextMenu {
                                if let url = item.result.url { FileActions.entries(workspace, url) }
                            }
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SearchItem) -> some View {
        if let kind = item.kind {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    if let snippet = item.snippet {
                        Text(highlighted(snippet, matches: item.matches))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let place = item.place {
                        Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                // A folder as the sidebar shows it: its emoji, or its symbol in its colour.
                if let emoji = item.emoji {
                    Text(emoji)
                } else {
                    Image(systemName: item.image)
                        .foregroundStyle(item.symbol != nil ? Color.secondary : item.folderIcon?.color?.color ?? Color.theme(kind.tint))
                }
            }
            .contentShape(Rectangle())
        } else {
            Label(item.title, systemImage: "square.and.pencil")
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
    }

    /// The words you searched for, in the colour of the text.
    private func highlighted(_ snippet: String, matches: [Range<String.Index>]) -> AttributedString {
        var text = AttributedString(snippet)
        for match in matches {
            guard let range = Range(match, in: text) else { continue }
            text[range].foregroundColor = .primary
            text[range].font = .subheadline.weight(.semibold)
        }
        return text
    }
}

/// The alerts every screen needs: renaming, naming a new folder, deleting for good, and things that went wrong.
struct FileAlerts: ViewModifier {
    @Bindable var workspace: Workspace
    @Binding var newFolderIn: URL?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { workspace.renaming != nil }, set: { if !$0 { workspace.renaming = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) { workspace.renaming = nil }
                Button("Rename") {
                    if let url = workspace.renaming { rename(url) }
                    workspace.renaming = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .onChange(of: workspace.renaming) { _, url in
                if let url { name = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
            }
            .alert("New Folder", isPresented: Binding(get: { newFolderIn != nil }, set: { if !$0 { newFolderIn = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) { newFolderIn = nil }
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let parent = newFolderIn { workspace.newFolder(in: parent, named: trimmed.isEmpty ? "New Folder" : trimmed) }
                    newFolderIn = nil
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("Enter a name for this folder.")
            }
            .onChange(of: newFolderIn) { _, folder in if folder != nil { name = "" } }
            .sheet(item: $workspace.reminderRequest) { request in
                ReminderPicker(workspace: workspace, url: request.url) { workspace.reminderRequest = nil }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $workspace.todoReminderRequest) { todo in
                TodoReminderPicker(workspace: workspace, todo: todo) { workspace.todoReminderRequest = nil }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $workspace.todoPickRequest) { request in
                workspace.todoPicker(for: request) { workspace.todoPickRequest = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $workspace.folderIconRequest) { request in
                FolderIconEditor(workspace: workspace, url: request.url) { workspace.folderIconRequest = nil }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $workspace.moving) { file in MoveSheet(workspace: workspace, url: file.url) }
            .sheet(item: $workspace.versionBrowser) { browser in
                // On the iPad as large as a page, for the versions and the one picked side by side.
                VersionHistorySheet(browser: browser, source: workspace.editor)
                    .presentationSizing(.page)
            }
            // Its buttons answer it, which lets it go (`answerDeleting`).
            .alert(deleteTitle, isPresented: Binding(get: { workspace.deleting != nil }, set: { _ in }),
                   presenting: workspace.deleting) { url in
                Button("Cancel", role: .cancel) { workspace.answerDeleting(url, delete: false) }
                Button("Delete", role: .destructive) { workspace.answerDeleting(url, delete: true) }
            } message: { _ in
                Text("This place has no Recently Deleted folder, so it is deleted right away.")
            }
            .alert(workspace.problem?.title ?? "", isPresented: Binding(get: { workspace.problem != nil }, set: { if !$0 { workspace.problem = nil } }), presenting: workspace.problem) { problem in
                if problem.removableLocation != nil {
                    Button("Keep", role: .cancel) { workspace.answer(problem, removing: false) }
                    Button("Remove from Notebook", role: .destructive) { workspace.answer(problem, removing: true) }
                } else {
                    Button("OK") { workspace.problem = nil }
                }
            } message: { problem in
                Text(problem.message)
            }
            // One after another; its buttons answer it, which lets it go (`answer`).
            .alert(workspace.unsavedReports.first?.title ?? "", isPresented: Binding(get: { !workspace.unsavedReports.isEmpty }, set: { _ in }),
                   presenting: workspace.unsavedReports.first) { report in
                if report.copy != nil {
                    Button("OK", role: .cancel) { workspace.answer(report, .ok) }
                    Button("Open") { workspace.answer(report, .show) }
                } else {
                    Button("Copy Text") { workspace.answer(report, .copyText) }
                    Button("Try Again") { workspace.answer(report, .tryAgain) }
                }
            } message: { report in
                Text(report.message)
            }
            // No Undo alert over these, which a shake would bring up: they take the focus, and UIKit offers the files'
            // Undo from the window behind them.
            .onChange(of: workspace.deleting != nil || workspace.problem != nil || !workspace.unsavedReports.isEmpty) { _, asks in
                UIApplication.shared.applicationSupportsShakeToEdit = !asks
            }
    }

    private var deleteTitle: String {
        guard let url = workspace.deleting else { return "" }
        return "Delete “\(SearchSection.displayName(url))” immediately?"
    }

    private func rename(_ url: URL) {
        workspace.rename(url, typed: name)
    }
}

extension Workspace {
    /// Renames a file to a name typed in the Rename alert or its title, which shows a note without its extension and
    /// any other file with it.
    func rename(_ url: URL, typed name: String) {
        var target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard !target.isEmpty, target != current else { return }
        // A name typed with the extension of a file that has one keeps just one extension.
        if !url.pathExtension.isEmpty, (target as NSString).pathExtension.lowercased() == url.pathExtension.lowercased() {
            target = (target as NSString).deletingPathExtension
        }
        rename(url, to: target)
    }
}
#endif
