#if os(macOS)
import AppKit
#else
import SwiftUI
#endif
import UniformTypeIdentifiers

extension Workspace {
    /// Import from Apple Notes: the folders Notes exported, put into `folder` as Notebook keeps notes
    /// (`AppleNotesImport`), off the main thread. What it made shows in the sidebar, selected; one Undo takes all it
    /// added to the Trash again, and what couldn't come over is named in an alert.
    func importFromAppleNotes(_ sources: [URL], into folder: URL) {
        guard !sources.isEmpty else { return }
        // Kept for Undo as it is asked for, in its place among the changes asked for around it; what it adds is known
        // once it is done.
        let change = keepForUndo(FileChange(.make, "Import"))
        changeFiles { [self] follow in
            let folder = follow(folder)
            let imported = await Task.detached(priority: .userInitiated) { () -> (result: AppleNotesImport.Result, listings: [FileNode.Listing], madeFolder: Bool) in
                let accessing = sources.map { $0.startAccessingSecurityScopedResource() }
                defer { for (source, did) in zip(sources, accessing) where did { source.stopAccessingSecurityScopedResource() } }
                // The Inbox, the first time.
                let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
                if madeFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                let result = AppleNotesImport.run(sources, into: folder)
                let shown = result.added.filter { FileNode.samePath($0.deletingLastPathComponent(), folder) }
                return (result, shown.compactMap { FileNode.listing(of: $0) }, madeFolder)
            }.value
            let added = imported.result.added
            change.parts = added.dropFirst().map { url in
                let part = FileChange(.make, "Import")
                part.after = url
                return part
            }
            changeDone(change, to: added.first)
            let parent = folder.deletingLastPathComponent()
            showChanges(in: imported.madeFolder ? [parent, folder] : [folder],
                        adding: imported.listings + (imported.madeFolder ? [FileNode.Listing(url: folder, kind: .folder)] : []))
            if let first = imported.result.made.compactMap({ $0 }).first { reveal(first, select: true) }
            let problems = imported.result.problems
            if !problems.isEmpty {
                let more = problems.count > 6 ? "\n… and \(problems.count - 6) more." : ""
                report(problems.count == 1 ? "Something couldn’t be imported." : "\(problems.count) things couldn’t be imported.",
                       problems.prefix(6).joined(separator: "\n") + more)
            }
        }
    }

    #if os(macOS)
    /// File › Import from Apple Notes…: asks for the folder Notes exported, over the window, then imports it where a
    /// new note would go. Only folders: in the App Store build, a note picked on its own comes without its Attachments
    /// folder and the notes its links point at, which the sandbox keeps out of reach.
    public func chooseAppleNotesExport() {
        guard let folder = folderForNewNote else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose the folder Notes made with File › Export as › Markdown. Its notes go into “\(place(of: folder))”, with their pictures and files."
        let done = { [self] (response: NSApplication.ModalResponse) in
            if response == .OK { importFromAppleNotes(panel.urls, into: folder) }
        }
        if let window = sidebar?.outline.window ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
    #endif
}

#if os(iOS)
/// The Files app's picker for Import from Apple Notes, while the workspace asks for it (`appleNotesImportFolder`). Only
/// folders, as on the Mac: a note picked on its own comes without its Attachments folder.
struct AppleNotesImporter: ViewModifier {
    @Bindable var workspace: Workspace
    /// Where the notes go, kept for when the picker is done: it may say it closed before it says what was picked.
    @State private var folder: URL?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: Binding(get: { workspace.appleNotesImportFolder != nil }, set: { if !$0 { workspace.appleNotesImportFolder = nil } }),
                          allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, let folder else { return }
                workspace.importFromAppleNotes(urls, into: folder)
            }
            .onChange(of: workspace.appleNotesImportFolder) { _, new in
                if let new { folder = new }
            }
    }
}
#endif
