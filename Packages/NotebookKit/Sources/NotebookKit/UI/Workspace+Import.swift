#if os(macOS)
import AppKit
#else
import SwiftUI
#endif
import UniformTypeIdentifiers

extension Workspace {
    /// What Import from Apple Notes asks for: the folder Notes' Markdown export makes, or the notes in it.
    static let appleNotesExportTypes: [UTType] = [.folder, UTType(filenameExtension: "md", conformingTo: .text) ?? .plainText]

    /// Import from Apple Notes: the folders and notes Notes exported, put into `folder` as Notebook keeps notes
    /// (`AppleNotesImport`), off the main thread. What it made shows in the sidebar, selected, and one Undo takes all
    /// of it to the Trash again.
    func importFromAppleNotes(_ sources: [URL], into folder: URL) {
        guard !sources.isEmpty else { return }
        var changes: [FileChange] = []
        undoTogether { changes = sources.map { _ in keepForUndo(FileChange(.make, "Import")) } }
        changeFiles { [self] follow in
            let folder = follow(folder)
            let imported = await Task.detached(priority: .userInitiated) { () -> (result: AppleNotesImport.Result, listings: [FileNode.Listing], madeFolder: Bool) in
                let accessing = sources.map { $0.startAccessingSecurityScopedResource() }
                defer { for (source, did) in zip(sources, accessing) where did { source.stopAccessingSecurityScopedResource() } }
                // The Inbox, the first time.
                let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
                if madeFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                let result = AppleNotesImport.run(sources, into: folder)
                return (result, result.made.compactMap { $0.flatMap { FileNode.listing(of: $0) } }, madeFolder)
            }.value
            for (change, made) in zip(changes, imported.result.made) { changeDone(change, to: made) }
            let made = imported.result.made.compactMap { $0 }
            let parent = folder.deletingLastPathComponent()
            showChanges(in: imported.madeFolder ? [parent, folder] : [folder],
                        adding: imported.listings + (imported.madeFolder ? [FileNode.Listing(url: folder, kind: .folder)] : []))
            if let first = made.first { reveal(first, select: true) }
            if made.count < sources.count || imported.result.failed > 0 {
                report(made.isEmpty ? "The notes couldn’t be imported." : "Some notes couldn’t be imported.",
                       "Notebook can’t read them, or can’t write in “\(folderName(folder))”.")
            }
        }
    }

    #if os(macOS)
    /// File › Import from Apple Notes…: asks for what Notes exported, over the window, then imports it where a new
    /// note would go.
    public func chooseAppleNotesExport() {
        guard let folder = folderForNewNote else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.appleNotesExportTypes
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
/// The Files app's picker for Import from Apple Notes, while the workspace asks for it (`appleNotesImportFolder`).
struct AppleNotesImporter: ViewModifier {
    @Bindable var workspace: Workspace
    /// Where the notes go, kept for when the picker is done: it may say it closed before it says what was picked.
    @State private var folder: URL?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: Binding(get: { workspace.appleNotesImportFolder != nil }, set: { if !$0 { workspace.appleNotesImportFolder = nil } }),
                          allowedContentTypes: Workspace.appleNotesExportTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, let folder else { return }
                workspace.importFromAppleNotes(urls, into: folder)
            }
            .onChange(of: workspace.appleNotesImportFolder) { _, new in
                if let new { folder = new }
            }
    }
}
#endif
