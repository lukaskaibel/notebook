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

    /// As the Finder copies a file: its address, and its name as text. A picture comes as the picture too, for apps
    /// that take only pictures, read only when one of them asks for it.
    static func writeFile(_ url: URL, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        if MarkdownStyler.isImageFile(url), let type = UTType(filenameExtension: url.pathExtension) {
            let picture = CopiedPicture(url: url)
            CopiedPicture.current = picture
            item.setDataProvider(picture, forTypes: [NSPasteboard.PasteboardType(type.identifier), .tiff])
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
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
        guard let location = location(containing: url), let base = location.folder(containing: url.path) else { return nil }
        let inside = url.path.dropFirst(base.url.path.count).split(separator: "/")
        guard !inside.isEmpty, !inside.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let isNote = !isFolder && FileKind(url: url, isDirectory: false) == .note
        let address = isFolder ? nil : index.linkAddress(for: url, from: note)
        // A name `[[` would read otherwise ("Plan #2", "[Draft]"), and a folder: the way from the note to it.
        if let address, !address.contains(where: { "#|[]".contains($0) }) {
            return FileLink(markdown: isNote ? "[[\(address)]]" : "![[\(address)]]", isBlock: !isNote)
        }
        guard let note else { return nil }
        let relative = LinkUpdate.relativePath(from: note.deletingLastPathComponent(), to: url)
        let path = LinkUpdate.encoded(relative.isEmpty ? "." : relative) + (isFolder ? "/" : "")
        let name = Self.shownName(url).replacingOccurrences(of: "]", with: "")
        if isFolder || isNote { return FileLink(markdown: "[\(name)](\(path))", isBlock: false) }
        return FileLink(markdown: MarkdownStyler.isImageFile(url) ? "![](\(path))" : "![\(name)](\(path))", isBlock: true)
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
/// A picture copied as a file, read when an app asks for it as a picture: as it is in its file, or as TIFF, which
/// every Mac app takes.
final class CopiedPicture: NSObject, NSPasteboardItemDataProvider {
    /// The last one, kept while the pasteboard may ask it.
    nonisolated(unsafe) static var current: CopiedPicture?
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .tiff {
            if let tiff = NSImage(contentsOf: url)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        } else if let data = try? Data(contentsOf: url) {
            item.setData(data, forType: type)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Self.current === self { Self.current = nil }
    }
}
#endif
