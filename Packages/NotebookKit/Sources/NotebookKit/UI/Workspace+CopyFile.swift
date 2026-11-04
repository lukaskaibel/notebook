#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

/// Copy File (⇧⌘C): the file itself on the pasteboard, as the Finder's Copy puts it there, for every kind of file and
/// for folders. Pasted in the Finder or Files it makes a copy, in Mail and Messages an attachment; an app for pictures
/// takes the picture. Pasted in a note it is a link to the file where it is (`libraryLink`). Nothing of the file is
/// read to copy it: a large video is copied at once, and the app it is pasted in reads it. A capsule says it was
/// copied.
extension Workspace {
    /// A file's name as Notebook shows it: a note's without ".md".
    static func shownName(_ url: URL) -> String {
        FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    func copyFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return beep() }
        #if os(macOS)
        Self.writeFile(url, to: appPasteboard)
        // A note's own window is AppKit's, which shows the capsule itself.
        if keyFileNote != nil, let window = keyFileWindow?.window {
            return CopiedCapsule.show(Self.shownName(url), in: window)
        }
        #else
        Self.writeFile(url, to: .general)
        #endif
        copied.file = CopiedFile(name: Self.shownName(url))
    }

    #if os(macOS)
    /// The file Copy File (⇧⌘C) takes: the one selected in the sidebar while it has the keyboard, else the file of the
    /// window you are working in, a note's own window or this one.
    var fileToCopy: URL? {
        if isMainWindowInFront, let sidebar, sidebar.outline.window?.firstResponder === sidebar.outline, let url = sidebar.selectedURL {
            return url
        }
        return fileInFront
    }

    /// As the Finder copies a file: its address, written as AppKit writes a file's, so that a sandboxed app such as
    /// Mail may read the file, and its name as text. A picture on this Mac comes as the picture too, as it is in its
    /// file, for apps that take only pictures: read only when one of them asks for it. One only in iCloud doesn't,
    /// which would have to come down first.
    static func writeFile(_ url: URL, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        var types: [NSPasteboard.PasteboardType] = [.string]
        if MarkdownStyler.isImageFile(url), let type = UTType(filenameExtension: url.pathExtension),
           (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus).map({ $0 == .current }) ?? true {
            types.append(NSPasteboard.PasteboardType(type.identifier))
        }
        let picture = CopiedPicture(url: url)
        CopiedPicture.current = picture
        pasteboard.addTypes(types, owner: picture)
        pasteboard.setString(url.lastPathComponent, forType: .string)
    }
    #else
    /// As Files copies a file: the file, for other apps, and its address in Notebook's own type, for a note.
    static func writeFile(_ url: URL, to pasteboard: UIPasteboard) {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        let path = url.path
        provider.registerDataRepresentation(forTypeIdentifier: EditorController.copiedFileType, visibility: .ownProcess) { done in
            done(Data(path.utf8), nil)
            return nil
        }
        pasteboard.itemProviders = [provider]
    }
    #endif

    /// What a file pasted or dropped in a note becomes, when it is in one of the locations: a link to it where it is,
    /// `[[Plan]]` for a note and `![[Kyoto.jpg]]` for any other file, which shows it as a picture or its card does;
    /// a folder, which `[[` doesn't find, as a Markdown link to it. Links follow it when it is renamed or moved. Nil
    /// for a file from elsewhere, which is copied next to the note, and for one in a folder hidden by its name, such
    /// as another note's `.assets`, which links don't find.
    func libraryLink(to url: URL, from note: URL?) -> FileLink? {
        let url = url.standardizedFileURL
        // Gone since it was copied, moved or thrown away: no link to nothing. One not brought down from iCloud yet is there.
        guard FileOperations.exists(url), let location = location(containing: url), let base = location.folder(containing: url.path) else {
            return nil
        }
        // A location's folder, or a linked one such as iCloud Drive's Desktop, is in the library too, and only what the
        // index reads: links don't find anything else.
        let isRoot = FileNode.samePath(url, base.url)
        guard isRoot || index.entry(for: url) != nil || SearchIndex.reads(url, in: base.url) else { return nil }
        let isFolder = isRoot || FileNode.isFolder(url)
        let isNote = !isFolder && FileKind(url: url, isDirectory: false) == .note
        let address = isFolder ? nil : index.linkAddress(for: url, from: note)
        // AsciiDoc has no `[[links]]`: its links go by the way from the note to the file.
        let syntax = NoteSyntax(url: note)
        // A name `[[` would read otherwise ("Plan #2", "[Draft]"), and a folder: the way from the note to it.
        if syntax == .markdown, let address, !address.contains(where: { "#|[]".contains($0) }) {
            return FileLink(markdown: isNote ? "[[\(address)]]" : "![[\(address)]]", isBlock: !isNote)
        }
        guard let note else { return nil }
        let relative = LinkUpdate.relativePath(from: note.deletingLastPathComponent(), to: url)
        let path = LinkUpdate.encoded(relative.isEmpty ? "." : relative) + (isFolder ? "/" : "")
        let name = (isFolder ? folderName(url) : Self.shownName(url)).replacingOccurrences(of: "]", with: "")
        if isNote, syntax == .asciidoc { return FileLink(markdown: NoteMarkup.noteLink(name: name, path: path, syntax: syntax), isBlock: false) }
        if isFolder || isNote { return FileLink(markdown: NoteMarkup.link(path, text: name, syntax: syntax), isBlock: false) }
        return FileLink(markdown: NoteMarkup.attachment(path, name: name, syntax: syntax), isBlock: true)
    }
}

/// What Copy File copied, for the capsule over the window.
struct CopiedFile: Equatable {
    let name: String
    let id = UUID()
}

/// The file Copy File copied a moment ago, while the capsule says so.
@MainActor
@Observable
final class CopiedNotice {
    var file: CopiedFile?
}

#if os(macOS)
/// A picture copied as a file, given to an app that asks for it as a picture as it is in its file: read then, not
/// decoded or converted.
final class CopiedPicture: NSObject, NSPasteboardTypeOwner {
    /// The last one, kept while the pasteboard may ask it.
    nonisolated(unsafe) static var current: CopiedPicture?
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { sender.setData(data, forType: type) }
    }

    func pasteboardChangedOwner(_ sender: NSPasteboard) {
        if Self.current === self { Self.current = nil }
    }
}
#endif
