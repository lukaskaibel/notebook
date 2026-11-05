import CoreGraphics
import Foundation

/// A note's thumbnail, as the Finder shows it in its icon and gallery views, Open panels do, and the Files app on iPhone
/// and iPad: the top of the note on a page, with its title, in the look set in Notebook. Used by the thumbnail extension
/// (NotebookThumbnail).
///
/// Nothing here draws a note either: the note is shown as Quick Look shows it (NotePreview), and the top of it laid out
/// as an export lays it out (NoteExporter): as File › Export as Picture on the Mac, as the first page of its PDF on
/// iPhone and iPad. Like a thumbnail of any document it is light, whatever the appearance: thumbnails are kept, and
/// shown again in either.
///
/// Only the note is read. The Finder asks for thumbnails as you scroll by, so nothing next to the note is looked at,
/// even where it could be. Pictures, and the files and notes it links to, show by their names.
@MainActor
public enum NoteThumbnail {
    /// The page: about the shape of a sheet of paper, as large as fits in `maximum`.
    public nonisolated static func size(fitting maximum: CGSize) -> CGSize {
        let height = min(maximum.height, (maximum.width * 1.3).rounded(.down))
        return CGSize(width: (height / 1.3).rounded(), height: height)
    }

    /// How much of a note a thumbnail reads: well more than its page shows, so the top is set as in the whole note, and
    /// a long note isn't laid out to its end.
    nonisolated static let length = 6000

    /// The beginning of `text`, to the end of the line `length` characters in.
    nonisolated static func top(of text: String) -> String {
        let text = text as NSString
        guard text.length > length else { return text as String }
        return text.substring(to: text.lineRange(for: NSRange(location: length, length: 0)).upperBound)
    }

    /// The thumbnail of the note at `url`, `size` points big (`size(fitting:)`) with `scale` pixels to the point.
    /// Throws when the note can't be read.
    public static func image(of url: URL, size: CGSize, scale: CGFloat) async throws -> CGImage {
        try await page(of: url, size: size, scale: scale).image
    }

    /// The thumbnail, with the copy of the editor that drew it.
    static func page(of url: URL, size: CGSize, scale: CGFloat) async throws -> (image: CGImage, editor: EditorController) {
        let preview = NotePreview(thumbnail: true)
        try await preview.show(url)
        guard let top = await NoteExporter.top(of: preview.editor, title: preview.editor.titleText, size: size, scale: scale) else {
            throw CocoaError(.fileReadUnknown)
        }
        return (top.image, top.copy.editor)
    }
}
