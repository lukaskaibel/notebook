import NotebookKit
import QuickLookThumbnailing

/// A note's thumbnail in the Finder's icon and gallery views, in Open panels and in the Files app on iPhone and iPad: the
/// top of the note as Notebook shows it (NoteThumbnail).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let size = NoteThumbnail.size(fitting: request.maximumSize)
        let scale = request.scale
        Task { @MainActor in
            do {
                let image = try await NoteThumbnail.image(of: url, size: size, scale: scale)
                handler(QLThumbnailReply(contextSize: size) { context in
                    // Quick Look's context may be in pixels, without a scale: the picture fills it either way.
                    let extent = context.convertToUserSpace(CGSize(width: context.width, height: context.height))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: abs(extent.width), height: abs(extent.height)))
                    return true
                }, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
