#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit
import SwiftUI

/// Move To, as in Notes: every folder, indented under its location.
struct MoveToMenu: View {
    let workspace: Workspace
    let url: URL

    var body: some View {
        Menu {
            #if os(macOS)
            // The folders go in when the menu opens (`MoveToSubmenu`). Made here, an item for each of them would be
            // made again every time a note opens.
            Text("Folders")
            #else
            ForEach(workspace.moveTargets(for: url), id: \.location.id) { target in
                Section(target.location.name) {
                    ForEach(target.folders, id: \.url) { folder in
                        Button {
                            workspace.move(url, into: folder.url)
                        } label: {
                            Label(String(repeating: "    ", count: max(0, folder.depth)) + (folder.depth < 0 ? "Top Level" : folder.name), systemImage: "folder")
                        }
                        .disabled(folder.url.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL)
                    }
                }
            }
            #endif
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }
}

/// New Note in a toolbar, in glass of the accent colour as Done is, so that it stands out from the other buttons.
struct NewNoteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("New Note", systemImage: "square.and.pencil") }
            .buttonStyle(.glassProminent)
    }
}

struct EmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Note Open", systemImage: "doc.text")
        } description: {
            #if os(macOS)
            Text("Pick a note in the sidebar, press ⌘N for a new one, ⌘F to search or ⌘K to run a command.")
            #else
            Text("Pick a note in the sidebar, or start a new one.")
            #endif
        }
    }
}

/// The inspector: the note's headings, the one you are reading selected, and how long the note is.
struct OutlinePanel: View {
    let workspace: Workspace
    /// In a sheet titled "Outline", the list doesn't say it again.
    var showsHeader = true

    var body: some View {
        if workspace.note == nil {
            if let url = workspace.currentURL {
                FileInfoPanel(url: url, place: workspace.index.entry(for: url)?.place ?? "")
                    .id(url)
            } else {
                ContentUnavailableView {
                    Label("No Outline", systemImage: "list.bullet.indent")
                } description: {
                    Text("Notes show their headings here.")
                }
            }
        } else {
            let base = workspace.outline.map(\.level).min() ?? 1
            ScrollViewReader { proxy in
                List(selection: selection) {
                    if let url = workspace.currentURL {
                        Section("Reminder") {
                            ReminderRow(workspace: workspace, url: url)
                        }
                    }
                    Section {
                        Text(workspace.currentTitle)
                            .fontWeight(.medium)
                            .tag(-1)
                            .id(-1)
                        ForEach(workspace.outline) { heading in
                            Text(heading.title)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(heading.level - base + 1) * 12)
                                .tag(heading.id)
                                .id(heading.id)
                        }
                    } header: {
                        if showsHeader { Text("Outline") }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: workspace.currentHeading) { _, current in
                    withAnimation(Theme.quick) { proxy.scrollTo(current ?? -1) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("\(workspace.stats.words.formatted()) \(workspace.stats.words == 1 ? "word" : "words") · \(workspace.stats.readingMinutes) min read")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    /// The section you are reading, and the one you pick to go to.
    private var selection: Binding<Int?> {
        Binding(get: { workspace.currentHeading ?? -1 }, set: { id in
            guard let id else { return }
            workspace.editor.scroll(to: workspace.outline.first { $0.id == id })
        })
    }
}

/// The note's reminder in the inspector, or Remind Me… for a note without one. Either opens the times to choose from.
struct ReminderRow: View {
    let workspace: Workspace
    let url: URL
    @State private var isPicking = false

    var body: some View {
        let reminder = workspace.reminder(for: url)
        Button { isPicking = true } label: {
            Label {
                Text(reminder.map { Workspace.reminderText($0.date) } ?? "Remind Me…")
                    .foregroundStyle(reminder == nil ? Color.secondary : Color.primary)
            } icon: {
                Image(systemName: reminder == nil ? "bell" : "bell.fill")
                    .foregroundStyle(reminder.map { $0.date <= .now ? Color.red : Color.accentColor } ?? Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPicking, arrowEdge: .leading) {
            ReminderPicker(workspace: workspace, url: url) { isPicking = false }
                #if os(iOS)
                .frame(minWidth: 340, idealHeight: 520)
                .presentationDetents([.medium, .large])
                #endif
        }
    }
}

/// For a PDF, picture or any other file: what it is, as the Finder's Get Info has it.
struct FileInfoPanel: View {
    let url: URL
    let place: String
    @State private var facts: [(String, String)] = []

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    #if os(macOS)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                    #else
                    FileIcon(url: url)
                        .frame(width: 64, height: 64)
                    #endif
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Info") {
                ForEach(facts, id: \.0) { fact in
                    LabeledContent(fact.0, value: fact.1)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: url) { facts = await Self.facts(for: url, place: place) }
    }

    private static func facts(for url: URL, place: String) async -> [(String, String)] {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        var facts: [(String, String)] = []
        if let kind = values?.localizedTypeDescription { facts.append(("Kind", kind)) }
        if let size = values?.fileSize { facts.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        let detail = await Task.detached(priority: .utility) { () -> (String, String)? in
            if url.pathExtension.lowercased() == "pdf", let pages = PDFDocument(url: url)?.pageCount {
                return ("Pages", "\(pages)")
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                // As the picture shows: orientations 5 to 8 turn it a quarter.
                let turned = (properties[kCGImagePropertyOrientation] as? UInt32 ?? 1) >= 5
                return ("Dimensions", turned ? "\(height) × \(width)" : "\(width) × \(height)")
            }
            return nil
        }.value
        if let detail { facts.append(detail) }
        if let created = values?.creationDate { facts.append(("Created", created.formatted(date: .abbreviated, time: .shortened))) }
        if let modified = values?.contentModificationDate { facts.append(("Modified", modified.formatted(date: .abbreviated, time: .shortened))) }
        if !place.isEmpty { facts.append(("Where", place)) }
        return facts
    }
}

