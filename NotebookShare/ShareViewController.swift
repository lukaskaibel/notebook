import SwiftUI

#if os(iOS)
import UIKit

/// The share extension's sheet on iPhone and iPad.
final class ShareViewController: UIViewController {
    private let content = SharedContent()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = UIHostingController(rootView: ShareView(content: content) { [weak self] isSaving in
            self?.isModalInPresentation = isSaving
        } done: { [weak self] kept in
            self?.finish(kept)
        })
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await content.load(items) }
    }

    private var finished = false

    private func finish(_ kept: Bool) {
        guard !finished else { return }
        finished = true
        content.cleanUp()
        if kept {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }
}
#else
import AppKit

/// The share extension's sheet on the Mac.
final class ShareViewController: NSViewController {
    private let content = SharedContent()

    override func loadView() {
        let sheet = NSHostingView(rootView: ShareView(content: content) { _ in } done: { [weak self] kept in self?.finish(kept) })
        view = sheet
        preferredContentSize = sheet.fittingSize
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await content.load(items) }
    }

    private var finished = false

    private func finish(_ kept: Bool) {
        guard !finished else { return }
        finished = true
        content.cleanUp()
        if kept {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }
}
#endif
