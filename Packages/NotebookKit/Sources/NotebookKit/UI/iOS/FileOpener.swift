#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Open File on iPhone and iPad: the Files app's picker for one file or several, opened in place, from wherever they
/// are (`Workspace.openChosen`). The way in for apps that give other apps single files but no folders, such as
/// Nextcloud. Shown from UIKit, so the ⋯ menus, ⌘O and the welcome screen all reach the same picker, which SwiftUI's
/// file importer can't share with the folder picker on the same screen.
@MainActor
enum FileOpener {
    /// The last picker's delegate, which the picker doesn't keep.
    private static var pick: FilesPick?

    static func choose(for workspace: Workspace) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        let pick = FilesPick { urls in
            if !urls.isEmpty { workspace.openChosen(urls) }
        }
        picker.delegate = pick
        self.pick = pick
        Task { _ = await FolderAccess.present(picker) }
    }
}

/// The picker's answer: the files chosen, none for Cancel.
@MainActor
private final class FilesPick: NSObject, UIDocumentPickerDelegate {
    private let done: ([URL]) -> Void

    init(_ done: @escaping ([URL]) -> Void) {
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        done(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        done([])
    }
}
#endif
