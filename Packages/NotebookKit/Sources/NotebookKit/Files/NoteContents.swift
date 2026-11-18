import Foundation
import PDFKit

/// Whether there is anything in a note on disk, for asking before it is deleted. Reads the file, so not on the main
/// thread. What it can't tell counts as something: asking once too often loses nothing.
enum NoteContents {
    /// A note longer than this has more in it than spaces, and isn't read to find that out.
    private static let longestToRead = 4096

    /// A typed note with more than spaces and empty lines in it, whatever its name, as a note left empty is judged; a
    /// handwritten one with more than one page of paper, or anything on its page. No other file counts, nor a folder.
    static func hasContent(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true else { return false }
        let kind = FileKind(url: url, isDirectory: false)
        guard kind == .note || kind == .pdf else { return false }
        // Still in iCloud: reading it would wait for the download.
        if NoteDocument.wait(for: url) != nil { return true }
        return kind == .note ? typedNoteHasContent(url, size: values.fileSize) : handwrittenNoteHasContent(url)
    }

    private static func typedNoteHasContent(_ url: URL, size: Int?) -> Bool {
        if size == 0 { return false }
        if let size, size > longestToRead { return true }
        guard let data = try? Data(contentsOf: url), let text = NoteDocument.decode(data) else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A PDF that isn't Notebook's paper is a file like any other. On the paper, all that is written or placed is an
    /// annotation, beside the hidden one that says which paper it is.
    private static func handwrittenNoteHasContent(_ url: URL) -> Bool {
        guard let document = PDFDocument(url: url), let first = document.page(at: 0), NotebookPaper.style(of: first) != nil else { return false }
        if document.pageCount > 1 { return true }
        return first.annotations.contains { $0.value(forAnnotationKey: NotebookPaper.key) == nil }
    }
}
