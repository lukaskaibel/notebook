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
        let pasteboard = NSPasteboard.general
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

        // Files from the Finder or the sidebar.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return pasteFiles(urls, at: target)
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
            insertOnOwnLines("![](\(stored))", at: target)
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
                _ = self.pasteFiles(files, at: NSRange(location: min(target.location, self.storage.length), length: 0))
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
        replace(target, with: adjusted, select: NSRange(location: target.location + (adjusted as NSString).length, length: 0), actionName: "Paste")
        return true
    }

    /// Notes become links to them; pictures and other files are copied into `.assets` and shown on lines of their own.
    func pasteFiles(_ urls: [URL], at target: NSRange) -> Bool {
        var blocks: [String] = []
        var inline: [String] = []
        for url in urls {
            if url.pathExtension.lowercased() == "md", let link = noteLink(for: url) {
                inline.append(link)
            } else if let stored = storeAsset(copying: url) {
                let name = url.lastPathComponent
                blocks.append(MarkdownStyler.isImageFile(url) ? "![](\(stored))" : "![\(name)](\(stored))")
            }
        }
        if !inline.isEmpty {
            let text = inline.joined(separator: " ")
            replace(target, with: text, select: NSRange(location: target.location + (text as NSString).length, length: 0), actionName: "Paste")
        }
        if !blocks.isEmpty { insertOnOwnLines(blocks.joined(separator: "\n"), at: inline.isEmpty ? target : selection) }
        return !inline.isEmpty || !blocks.isEmpty
    }

    /// Plain text, with its line breaks made Unix ones.
    func pasteText(_ string: String, at target: NSRange) {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A link pasted over selected text links that text.
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.length > 0, !trimmed.contains(" "), let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme),
           !nsText.substring(with: target).contains("\n") {
            let label = nsText.substring(with: target)
            let link = "[\(label)](\(trimmed))"
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

    /// Markdown that marks a line or a span rather than being text: a heading's #s, a list item's bullet or checkbox,
    /// a quote's >, the stars around bold.
    private func isMark(_ index: Int) -> Bool {
        if storage.attribute(.notebookHidden, at: index, effectiveRange: nil) != nil { return true }
        switch layoutManager.object(at: index)?.kind {
        case .bullet, .checkbox, .quoteBar, .callout: return true
        default: return false
        }
    }

    // MARK: - Assets

    var assetsFolder: URL? { folder?.appendingPathComponent(".assets", isDirectory: true) }

    /// A path for Markdown: spaces and brackets encoded so the link holds together everywhere.
    static func markdownPath(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return ".assets/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    private func uniqueAssetURL(named name: String) -> URL? {
        guard let folder, let assets = assetsFolder, delegate?.editor(self, mayWriteIn: folder) ?? true else { return nil }
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = assets.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || FileManager.default.fileExists(atPath: DrawingFile.strokesURL(for: candidate).path) {
            candidate = assets.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Copies a file into `.assets` and returns its Markdown path.
    func storeAsset(copying url: URL) -> String? {
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
        guard let expression = try? NSRegularExpression(pattern: "\\]\\((\\.assets/[^)\\s]+)\\)") else { return markdown }
        var result = markdown
        let matches = expression.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length)).reversed()
        for match in matches {
            let path = (markdown as NSString).substring(with: match.range(at: 1))
            let decoded = path.removingPercentEncoding ?? path
            let file = source.appendingPathComponent(decoded)
            guard FileManager.default.fileExists(atPath: file.path), let stored = storeAsset(copying: file) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: stored)
        }
        return result
    }

    /// `[[Name]]` for a note dropped in from the sidebar or the Finder.
    private func noteLink(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return "[[\(name)]]"
    }
}

#if os(macOS)
/// The files each promise of a drop was for, as they are written.
private final class PromisedFiles: @unchecked Sendable {
    var files: [[URL]]
    init(count: Int) { files = Array(repeating: [], count: count) }
}
#endif
