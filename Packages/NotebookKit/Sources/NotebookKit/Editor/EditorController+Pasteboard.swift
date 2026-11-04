#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

/// Copy and paste as in Notes: a copied picture comes along as a picture, Markdown keeps its formatting, and pictures
/// and files dropped or pasted in are stored next to the note in `.assets`, hidden from the Finder.
extension EditorController {
    static let fragmentIdentifier = "com.lukaskbl.notebook.fragment"
    /// On the iPhone and iPad, a file Copy File copied, by its address: there the pasteboard has the file only as one
    /// to copy, and a note links to the file where it is (`Workspace.copyFile`).
    static let copiedFileType = "com.lukaskbl.notebook.file"

    typealias Clipping = (range: NSRange, markdown: String, fragment: Data?, file: URL?)

    /// What copying the selection puts on the pasteboard (`clipping(of:)`). Nil when nothing is selected.
    func clipping(cut: Bool) -> Clipping? {
        var range = expandSelection(selection)
        // A whole heading copies as a heading: its hidden #s come along.
        if !cut, range.length > 0, !document.lines.isEmpty {
            let line = document.lines[document.lineIndex(containing: range.location)]
            if case .heading(_, let marker) = line.kind, range.location == marker.upperBound, range.upperBound >= line.range.upperBound {
                range = NSRange(location: marker.location, length: range.upperBound - marker.location)
            }
        }
        guard range.length > 0 else { return nil }
        return clipping(of: range)
    }

    /// What copying or dragging part of the note takes along: its Markdown, Notebook's own fragment (the Markdown,
    /// the folder its pictures are in, and whether it is one picture or file, which goes on lines of its own where it
    /// is pasted) and, for a single picture or file, the file.
    func clipping(of range: NSRange) -> Clipping {
        let markdown = nsText.substring(with: range)
        var contents = ["markdown": markdown, "folder": folder?.path ?? ""]
        if isWholeObject(range) { contents["object"] = "1" }
        let fragment = try? JSONSerialization.data(withJSONObject: contents)
        var file: URL?
        if let object = layoutManager.object(at: range.location), object.range(at: range.location) == range {
            switch object.kind {
            case .image(let url, _, _), .fileCard(let url, _):
                file = url
            case .drawing(let url):
                file = url
            default:
                break
            }
        }
        return (range, markdown, fragment, file)
    }

    #if os(macOS)
    static let fragmentType = NSPasteboard.PasteboardType(fragmentIdentifier)

    /// Copies the selection as Markdown (and, for a single picture, as that file). Returns false when there is
    /// nothing selected.
    @discardableResult
    func copySelection(cut: Bool) -> Bool {
        guard let clipping = clipping(cut: cut) else { return false }
        let pasteboard = appPasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem(for: clipping)])
        if cut { replace(clipping.range, with: "", select: NSRange(location: clipping.range.location, length: 0), actionName: "Cut") }
        return true
    }

    func pasteboardItem(for clipping: Clipping) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(clipping.markdown, forType: .string)
        if let data = clipping.fragment { item.setData(data, forType: Self.fragmentType) }
        if let url = clipping.file { item.setString(url.absoluteString, forType: .fileURL) }
        return item
    }

    /// Pastes or drops at `index` (or over the selection). Returns false to leave it to AppKit.
    @discardableResult
    func paste(from pasteboard: NSPasteboard, at index: Int?) -> Bool {
        let target = index.map { NSRange(location: $0, length: 0) } ?? selection

        if let data = pasteboard.data(forType: Self.fragmentType), pasteFragment(data, at: target) { return true }

        // Files from the Finder or the sidebar, or copied with Copy File. Dropped with Option held, the Mac's key for a
        // copy, files of the locations are copied in rather than linked.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return pasteFiles(urls, at: target, linking: index == nil || !NSEvent.modifierFlags.contains(.option))
        }

        // Photos from Photos, pictures from Safari, attachments from Mail: files that are written once they are dropped.
        let promises = promisedFiles(on: pasteboard)
        if !promises.isEmpty {
            receive(promises, at: target)
            return true
        }

        // A picture copied from another app.
        if pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil,
           pasteboard.availableType(from: [.string]) == nil || pasteboard.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pasteboard), let stored = storeAsset(image: image) {
            insertOnOwnLines(NoteMarkup.picture(stored, syntax: syntax), at: target)
            return true
        }

        if let string = pasteboard.string(forType: .string) {
            pasteText(string, at: target)
            return true
        }
        return false
    }

    /// Files an app writes only once they are dropped. A link or text dragged from Safari promises a file too, which
    /// isn't what it is for: that goes in as text.
    func promisedFiles(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !promises.isEmpty else { return [] }
        let isMedia = promises.allSatisfy { promise in
            promise.fileTypes.contains { UTType($0).map { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) || $0.conforms(to: .pdf) } ?? false }
        }
        return isMedia || pasteboard.availableType(from: [.string, .URL]) == nil ? promises : []
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Takes promised files as files dropped from the Finder, once they have all been written: a photo in iCloud
    /// comes down first. They are asked for while the drop goes on, the only time AppKit allows it.
    private func receive(_ promises: [NSFilePromiseReceiver], at target: NSRange) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook drop \(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = loadCount
        // In the order they were dragged, each written on the promise queue.
        let received = PromisedFiles(count: promises.count)
        let group = DispatchGroup()
        for (index, promise) in promises.enumerated() {
            let expected = max(1, promise.fileTypes.count)
            var calls = 0
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) { url, error in
                calls += 1
                if error == nil { received.files[index].append(url) }
                if calls == expected { group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                defer { try? FileManager.default.removeItem(at: folder) }
                let files = received.files.flatMap { $0 }
                // By then another note may be open, which they aren't for.
                guard let self, !files.isEmpty, self.loadCount == note else { return }
                // Written for the drop in a folder of their own that goes again: copied, never linked, notes too.
                _ = self.pasteFiles(files, at: NSRange(location: min(target.location, self.storage.length), length: 0), temporary: true)
            }
        }
    }
    #endif

    /// Copied in Notebook: Markdown, with its pictures copied along when it goes to a note in another folder. A picture
    /// or file by itself goes on lines of its own.
    func pasteFragment(_ data: Data, at target: NSRange) -> Bool {
        guard let fragment = try? JSONSerialization.jsonObject(with: data) as? [String: String], let markdown = fragment["markdown"] else { return false }
        let source = fragment["folder"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let adjusted = copyAssets(in: markdown, from: source)
        if fragment["object"] == "1" {
            insertOnOwnLines(adjusted, at: target)
            return true
        }
        if pasteDocument(adjusted, at: target) { return true }
        replace(target, with: adjusted, select: NSRange(location: target.location + (adjusted as NSString).length, length: 0), actionName: "Paste")
        return true
    }

    /// The folder of the note text copied in Notebook came from, whose `.assets` its pictures are in.
    static func fragmentFolder(_ data: Data) -> URL? {
        guard let fragment = try? JSONSerialization.jsonObject(with: data) as? [String: String], let path = fragment["folder"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Files of the locations become links to them where they are (`FileLink`), so a picture copied from the sidebar
    /// isn't stored twice; so do notes from elsewhere. Other files from elsewhere, such as Downloads, which gets
    /// emptied, are copied into `.assets`; pictures and files show on lines of their own. Without `linking` (Option
    /// held while dropping), files of the locations are copied too; `temporary` files, written for a drop in a folder
    /// that goes again (Photos, Mail), are copied whatever they are, notes too. A folder is never copied, nor anything
    /// the note is in, such as the .textbundle of a note opened from the Finder: one of the locations goes in as a link,
    /// any other not at all. A package from elsewhere (an app, an .rtfd), which can be large, is copied off the main
    /// thread and goes in once it is there. A file gone since it was copied doesn't go in. True when the files were taken
    /// care of, with a beep for those that couldn't go in, so that nothing else is pasted in their place, such as their
    /// names.
    func pasteFiles(_ urls: [URL], at target: NSRange, linking: Bool = true, temporary: Bool = false) -> Bool {
        var blocks: [String] = []
        var inline: [String] = []
        var packages: [URL] = []
        var refused = false
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            // Also one iCloud hasn't brought down to this iPhone or iPad yet.
            if !FileOperations.exists(url) {
                refused = true
            } else if !temporary, linking || FileNode.isFolder(url), let link = delegate?.editor(self, linkTo: url) {
                if link.isBlock { blocks.append(link.markdown) } else { inline.append(link.markdown) }
            } else if isDirectory {
                if FileNode.isFolder(url) || folder.map({ FileNode.isSameOrInside($0, url) }) ?? true { refused = true } else { packages.append(url) }
            } else if !temporary, NoteSyntax.isNote(pathExtension: url.pathExtension), let link = noteLink(for: url) {
                inline.append(link)
            } else if let stored = storeAsset(copying: url) {
                blocks.append(NoteMarkup.attachment(stored, name: url.lastPathComponent, syntax: syntax))
            } else {
                refused = true
            }
        }
        if !inline.isEmpty {
            let text = inline.joined(separator: " ")
            // Next to a picture or a file's card, which has its line to itself, a link goes on a line of its own.
            if isOnObjectLine(target) {
                insertOnOwnLines(text, at: target)
            } else {
                replace(target, with: text, select: NSRange(location: target.location + (text as NSString).length, length: 0), actionName: "Paste")
            }
        }
        if !blocks.isEmpty { insertOnOwnLines(blocks.joined(separator: "\n"), at: inline.isEmpty ? target : selection) }
        if !packages.isEmpty { storeLater(packages, at: inline.isEmpty && blocks.isEmpty ? target.location : selection.location) }
        if refused { beep() }
        return !inline.isEmpty || !blocks.isEmpty || !packages.isEmpty || refused
    }

    /// Packages from elsewhere, copied into `.assets` off the main thread and put in at `location` once they are there,
    /// each on a line of its own, while the note is still open; otherwise the copies go again.
    private func storeLater(_ packages: [URL], at location: Int) {
        guard let folder, delegate?.editor(self, mayWriteIn: folder) ?? true else { return beep() }
        let note = loadCount
        Task { [weak self] in
            let stored = await Task.detached(priority: .userInitiated) {
                packages.compactMap { url -> URL? in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return FileOperations.storeAsset(copying: url, in: folder)
                }
            }.value
            guard let self, self.loadCount == note else {
                Task.detached { FileOperations.removeStoredAssets(stored) }
                return
            }
            if stored.count < packages.count { beep() }
            guard !stored.isEmpty else { return }
            let markdown = stored.map { NoteMarkup.file(Self.markdownPath($0.lastPathComponent), name: $0.lastPathComponent, syntax: self.syntax) }.joined(separator: "\n")
            self.insertOnOwnLines(markdown, at: NSRange(location: min(location, self.storage.length), length: 0))
        }
    }

    /// Plain text, with its line breaks made Unix ones.
    func pasteText(_ string: String, at target: NSRange) {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if pasteDocument(normalized, at: target) { return }
        // A link pasted over selected text links that text.
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.length > 0, !trimmed.contains(" "), let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme),
           !nsText.substring(with: target).contains("\n") {
            let label = nsText.substring(with: target)
            let link = NoteMarkup.link(trimmed, text: label, syntax: syntax)
            replace(target, with: link, select: NSRange(location: target.location + (link as NSString).length, length: 0), actionName: "Add Link")
            return
        }
        replace(target, with: normalized, select: NSRange(location: target.location + (normalized as NSString).length, length: 0), actionName: "Paste")
    }

    /// Puts Markdown for a picture or file on lines of its own.
    func insertOnOwnLines(_ markdown: String, at range: NSRange) {
        var text = markdown
        var range = range
        let line = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        var lineEnd = line.upperBound
        if lineEnd > line.location, lineEnd <= storage.length, nsText.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        // At the start of a heading's or list item's text, the caret is after its #s or bullet, and at the end of a
        // line maybe before the marks that close it: the picture goes before or after the whole line, not between
        // marks and their text.
        if range.length == 0, range.location > line.location, (line.location..<range.location).allSatisfy(isMark) {
            range.location = line.location
        } else if range.length == 0, range.location < lineEnd, (range.location..<lineEnd).allSatisfy(isMark) {
            range.location = lineEnd
        }
        if range.location > line.location { text = "\n" + text }
        if range.upperBound < lineEnd { text += "\n" }
        replace(range, with: text, select: NSRange(location: range.location + (text as NSString).length, length: 0), actionName: "Insert")
    }

    /// Whether a place is on the line of a picture, a file's card or another block drawn in place of its Markdown.
    private func isOnObjectLine(_ range: NSRange) -> Bool {
        let line = nsText.lineRange(for: NSRange(location: min(range.location, storage.length), length: 0))
        guard line.length > 0, line.location < storage.length else { return false }
        return layoutManager.object(at: line.location)?.isBlock == true
    }

    /// Markdown that marks a line or a span rather than being text: a heading's #s, a list item's bullet or checkbox,
    /// a quote's >, the stars around bold.
    private func isMark(_ index: Int) -> Bool {
        if storage.attribute(.notebookHidden, at: index, effectiveRange: nil) != nil { return true }
        switch layoutManager.object(at: index)?.kind {
        case .bullet, .checkbox, .quoteBar, .callout: return true
        default: return false
        }
    }

    // MARK: - Whole notes

    /// Pasted in the title, which holds one line: the first line goes there, as it reads without a heading's #s, and
    /// the rest at the start of the text, where the caret goes on to. Copied from a note in another folder (`source`),
    /// its pictures come along as they do into the text. False for a line as it is, which the title takes itself.
    func pasteInTitle(_ string: String, assetsFrom source: URL?) -> Bool {
        let pasted = PastedNote(forTitle: string)
        guard pasted.title != string || !pasted.text.isEmpty else { return false }
        insertInTitle(pasted.title)
        guard !pasted.text.isEmpty else { return true }
        let text = copyAssets(in: pasted.text, from: source)
        leaveTitle()
        if isBlank(outside: NSRange(location: 0, length: 0)) {
            replace(NSRange(location: 0, length: storage.length), with: text, select: NSRange(location: (text as NSString).length, length: 0), actionName: "Paste")
            return true
        }
        // Before what the note had, on lines of its own, after its front matter, which has to stay at the top.
        let frontMatter = document.lines.last { $0.kind == .frontmatterDelimiter }
        let start = frontMatter?.fullRange.upperBound ?? 0
        let lines = (frontMatter?.breakLength == 0 ? "\n" : "") + (text.hasSuffix("\n") ? String(text.dropLast()) : text)
        replace(NSRange(location: start, length: 0), with: lines + "\n", select: NSRange(location: start + (lines as NSString).length, length: 0), actionName: "Paste")
        return true
    }

    /// A whole document pasted in a note with nothing else in it, as a new one is: the `# Heading` it starts with is
    /// the note's title, given to a note without a name and left out under one it has, and the rest its text.
    private func pasteDocument(_ markdown: String, at target: NSRange) -> Bool {
        guard isBlank(outside: target), let pasted = PastedNote(document: markdown) else { return false }
        if !hasTitle {
            titleText = pasted.title
            commitTitle()
        }
        replace(NSRange(location: 0, length: storage.length), with: pasted.text, select: NSRange(location: (pasted.text as NSString).length, length: 0),
                actionName: "Paste")
        return true
    }

    /// Whether the note has a name: one given to it, not New Note's "Untitled", which the title of a new note shows
    /// as its placeholder.
    private var hasTitle: Bool {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.range(of: "^Untitled( [0-9]+)?$", options: .regularExpression) == nil
    }

    /// Whether the text has nothing but spaces and empty lines around `range`.
    private func isBlank(outside range: NSRange) -> Bool {
        let shown = CharacterSet.whitespacesAndNewlines.inverted
        let before = NSRange(location: 0, length: min(range.location, storage.length))
        let after = NSRange(location: min(range.upperBound, storage.length), length: storage.length - min(range.upperBound, storage.length))
        return nsText.rangeOfCharacter(from: shown, options: [], range: before).location == NSNotFound
            && nsText.rangeOfCharacter(from: shown, options: [], range: after).location == NSNotFound
    }

    // MARK: - Assets

    var assetsFolder: URL? { folder?.appendingPathComponent(".assets", isDirectory: true) }

    /// A path for Markdown: spaces and brackets encoded so the link holds together everywhere.
    static func markdownPath(_ name: String) -> String {
        FileOperations.markdownPath(name)
    }

    private func uniqueAssetURL(named name: String) -> URL? {
        guard let folder, let assets = assetsFolder, delegate?.editor(self, mayWriteIn: folder) ?? true else { return nil }
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        return FileOperations.uniqueAssetURL(named: name, in: assets)
    }

    /// Copies a file into `.assets` and returns its Markdown path. Never a folder or package, which could hold the note
    /// and so `.assets` itself, and take a while to copy (`storeLater`).
    func storeAsset(copying url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
        if let assets = assetsFolder, url.deletingLastPathComponent().standardizedFileURL == assets.standardizedFileURL {
            return Self.markdownPath(url.lastPathComponent)
        }
        guard let destination = uniqueAssetURL(named: url.lastPathComponent) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
            copied = (try? FileManager.default.copyItem(at: from, to: to)) != nil
        }
        // A drawing's strokes come along, so it can be drawn in where it goes.
        let strokes = DrawingFile.strokesURL(for: url)
        if copied, MarkdownStyler.isImageFile(url), FileManager.default.fileExists(atPath: strokes.path) {
            let copy = DrawingFile.strokesURL(for: destination)
            NSFileCoordinator().coordinate(readingItemAt: strokes, options: [], writingItemAt: copy, options: .forReplacing, error: nil) { from, to in
                try? FileManager.default.removeItem(at: to)
                try? FileManager.default.copyItem(at: from, to: to)
            }
        }
        return copied ? Self.markdownPath(destination.lastPathComponent) : nil
    }

    /// Saves a pasted picture into `.assets` as PNG (screenshots, drawings) or JPEG (photos).
    func storeAsset(image: NSImage) -> String? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let isPhoto = bitmap.pixelsWide * bitmap.pixelsHigh > 1_500_000 && !bitmap.hasAlpha
        let encoded = isPhoto ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) : bitmap.representation(using: .png, properties: [:])
        #else
        guard let pixels = image.cgImage else { return nil }
        let alpha = pixels.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let isPhoto = pixels.width * pixels.height > 1_500_000 && !hasAlpha
        let encoded = isPhoto ? image.jpegData(compressionQuality: 0.85) : image.pngData()
        #endif
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let note = delegate?.editorNoteName(self) ?? "Picture"
        let name = "\(note) \(formatter.string(from: Date())).\(isPhoto ? "jpg" : "png")"
        guard let destination = uniqueAssetURL(named: name), let data = encoded else { return nil }
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: nil) { url in
            written = (try? data.write(to: url)) != nil
        }
        return written ? Self.markdownPath(destination.lastPathComponent) : nil
    }

    /// Markdown copied from a note in another folder points at that folder's `.assets`: copy the files it uses
    /// here and point at the copies.
    private func copyAssets(in markdown: String, from source: URL?) -> String {
        guard let source, let folder, source.standardizedFileURL != folder.standardizedFileURL else { return markdown }
        return FileOperations.copyingAssets(in: markdown, from: source) { storeAsset(copying: $0) }
    }

    /// `[[Name]]` for a note dropped in from the sidebar or the Finder; in AsciiDoc an `xref:` to it.
    private func noteLink(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let path = folder.map { LinkUpdate.relativePath(from: $0, to: url) } ?? url.lastPathComponent
        return NoteMarkup.noteLink(name: name, path: path, syntax: syntax)
    }
}

#if os(macOS)
/// The files each promise of a drop was for, as they are written.
private final class PromisedFiles: @unchecked Sendable {
    var files: [[URL]]
    init(count: Int) { files = Array(repeating: [], count: count) }
}
#endif
