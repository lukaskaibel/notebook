import Foundation
import NotebookCapture
import UniformTypeIdentifiers

/// What another app shares: text, a link, pictures and files, read from the share sheet's items. The pictures and
/// files are copied into a folder of the extension's own while the sheet is up, for `SharedNotes` to keep.
@MainActor
@Observable
final class SharedContent {
    var text = ""
    var link: URL?
    /// The link's page, when the app sharing it says.
    var linkTitle: String?
    var files: [URL] = []
    private(set) var isLoaded = false
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shared \(UUID().uuidString)", isDirectory: true)

    /// The name a new note gets: the page's, the first line of the text, or none ("Untitled").
    var suggestedTitle: String {
        if let linkTitle, !linkTitle.isEmpty { return linkTitle }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "" }
        let words = line.split(separator: " ")
        return words.count <= 8 ? line : words.prefix(8).joined(separator: " ")
    }

    func load(_ items: [NSExtensionItem]) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var texts: [String] = []
        for item in items {
            if linkTitle == nil, let title = item.attributedTitle?.string, !title.isEmpty { linkTitle = title }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider) {
                    if link == nil { link = url }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let file = await copyFile(provider) { files.append(file) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let string = await loadText(provider) {
                    texts.append(string)
                }
            }
            // Safari gives the page's title as the item's text, next to its link.
            if let content = item.attributedContentText?.string, !content.isEmpty, content != link?.absoluteString {
                if link != nil, linkTitle == nil, texts.isEmpty { linkTitle = content } else if !texts.contains(content) { texts.append(content) }
            }
        }
        text = texts.joined(separator: "\n\n")
        isLoaded = true
    }

    /// The note as Markdown: the text, then the link, named after its page when there is one.
    var markdown: String {
        var blocks = [text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        if let link {
            let title = (linkTitle ?? "").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            // Brackets in the address would end the link early.
            let address = link.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            blocks.append(title.isEmpty ? "<\(address)>" : "[\(title)](\(address))")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Leaves it for Notebook, moving the copies of its files there off the main thread, so the sheet doesn't stop
    /// for twenty videos.
    func keep(as title: String, at destination: SharedNote.Destination) async throws {
        var names = Set<String>()
        let named = files.map { url -> (url: URL, name: String) in
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var name = url.lastPathComponent, counter = 2
            while names.contains(name.lowercased()) {
                name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                counter += 1
            }
            names.insert(name.lowercased())
            return (url, name)
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = SharedNote(destination: destination, title: title.isEmpty ? nil : title, text: markdown, files: named.map(\.name))
        try await Task.detached(priority: .userInitiated) { try SharedNotes.add(note, moving: named) }.value
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Reading the items

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }

    /// A copy of a picture or file, under the name it had. Photos are taken as JPEG when the app offers it, which any
    /// app shows, rather than HEIC.
    private func copyFile(_ provider: NSItemProvider) async -> URL? {
        let types = provider.registeredTypeIdentifiers
        let preferred = [UTType.jpeg, .png, .pdf].map(\.identifier).first(where: types.contains)
        let type = preferred ?? types.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        let folder = folder
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var name = url.lastPathComponent
                if let suggestedName, !suggestedName.isEmpty {
                    let ext = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
                    name = (suggestedName as NSString).pathExtension.isEmpty ? "\(suggestedName).\(ext)" : suggestedName
                }
                let copy = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
            }
        }
    }
}
