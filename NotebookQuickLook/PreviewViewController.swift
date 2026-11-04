import NotebookKit

#if os(iOS)
import QuickLook
import UIKit

/// A note in Quick Look on iPhone and iPad (the Files app, Mail, Messages): as Notebook shows it, read only.
final class PreviewViewController: UIViewController, QLPreviewingController {
    private let preview = NotePreview()

    override func viewDidLoad() {
        super.viewDidLoad()
        let note = preview.view
        note.frame = view.bounds
        note.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(note)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        try await preview.show(url)
    }
}
#else
import AppKit
import Quartz

/// A note in Quick Look on the Mac (Space in the Finder, its column view and Get Info): as Notebook shows it, read
/// only.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let preview = NotePreview()

    override func loadView() {
        view = preview.view
        preferredContentSize = NSSize(width: 820, height: 1000)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        try await preview.show(url)
    }
}
#endif
