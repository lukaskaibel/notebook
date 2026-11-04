#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Paste in the sidebar, as in the Finder: what was copied goes in a folder. Files are copied there; text becomes a
/// note of its own, which the `# Heading` of a Markdown file's contents names.
extension Workspace {
    /// Text pasted as a note in `folder`: a whole Markdown document gives its `# Heading` for the note's name and the
    /// rest for its text, as pasted in a new note; other text is the text of a note to name, as New Note's is.
    @discardableResult
    func pasteNote(_ markdown: String, assetsFrom source: URL? = nil, into folder: URL) -> Task<URL?, Never> {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let pasted = PastedNote(document: text)
        return newNote(in: folder, title: pasted?.title, text: pasted?.text ?? text, assetsFrom: source, actionName: "Paste")
    }

    #if os(macOS)
    /// Paste (⌘V) with the sidebar's keyboard: files as copies, as the Finder pastes them, never a folder into itself;
    /// else text as a note. Copied in Notebook, the pictures it shows come along.
    func paste(from pasteboard: NSPasteboard, into folder: URL) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.filter { !FileNode.isSameOrInside(folder, $0) }
            if files.count < urls.count { beep() }
            if !files.isEmpty { drop(files, into: folder, copying: true) }
            return
        }
        guard let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return beep() }
        let source = pasteboard.data(forType: EditorController.fragmentType).flatMap(EditorController.fragmentFolder)
        pasteNote(string, assetsFrom: source, into: folder)
    }

    /// Whether the pasteboard has files or text, which Paste in the sidebar takes.
    static func canPaste(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .string]) != nil
    }
    #endif
}
