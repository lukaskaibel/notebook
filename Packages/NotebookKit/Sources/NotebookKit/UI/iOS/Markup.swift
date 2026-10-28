#if os(iOS)
import QuickLook
import SwiftUI
import UIKit

/// Markup of a PDF or picture as in Files: Quick Look with its pens, and what you draw saved into the file itself,
/// in its folder. (The share sheet's Markup asks where to save a copy.) The page shows the change as the file is
/// written (see `FileLoadingView`).
@MainActor
enum Markup {
    static func canMarkUp(_ kind: FileKind) -> Bool { kind == .pdf || kind == .image }

    static func open(_ url: URL, workspace: Workspace) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
            return
        }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let session = Session(url: url, workspace: workspace)
        let controller = QLPreviewController()
        controller.dataSource = session
        controller.delegate = session
        // Quick Look holds on to neither.
        objc_setAssociatedObject(controller, &Session.key, session, .OBJC_ASSOCIATION_RETAIN)
        top.present(controller, animated: true) { startMarkup(in: controller) }
    }

    /// Quick Look opens showing the file; it goes on into Markup at once, as Markup in Files does, by its own Markup
    /// button. Without one (Quick Look changed), it waits for that button to be tapped.
    private static func startMarkup(in controller: QLPreviewController) {
        func items(_ controller: UIViewController) -> [UIBarButtonItem] {
            (controller.navigationItem.rightBarButtonItems ?? []) + (controller.navigationItem.leftBarButtonItems ?? [])
                + (controller.toolbarItems ?? []) + controller.children.flatMap(items)
        }
        guard let button = items(controller).first(where: { $0.accessibilityIdentifier == "QLOverlayMarkupButtonAccessibilityIdentifier" }),
              button.isEnabled, let action = button.action else { return }
        UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil)
    }

    private final class Session: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        let url: URL
        weak var workspace: Workspace?

        init(url: URL, workspace: Workspace) {
            self.url = url
            self.workspace = workspace
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }

        // A copy, which Notebook writes over the file itself: Quick Look's own writing over it isn't coordinated
        // with iCloud and the other apps that have it open.
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .createCopy
        }

        func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
            let url = url
            // Kept now, as a clone that takes no time: Quick Look may remove its copy once this returns.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(modifiedContentsURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: modifiedContentsURL, to: copy)
            } catch {
                workspace?.report("Your markup couldn’t be saved in “\(url.lastPathComponent)”.", error.localizedDescription)
                return
            }
            Task.detached(priority: .userInitiated) { [weak workspace] in
                defer { try? FileManager.default.removeItem(at: copy) }
                var failure: Error?
                var coordination: NSError?
                // Written in place, so the file keeps its tags, its colour and its place in the folder.
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
                    do { try Data(contentsOf: copy).write(to: url) } catch { failure = error }
                }
                if let error = failure ?? coordination {
                    await MainActor.run {
                        workspace?.report("Your markup couldn’t be saved in “\(url.lastPathComponent)”.", error.localizedDescription)
                    }
                }
            }
        }
    }
}
#endif
