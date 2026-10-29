#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Brings up the system's photo picker, camera, document scanner or file browser for a PDF drawn on, and puts the
/// pictures that come back on the page in view.
@MainActor
final class PagePicturePicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    VNDocumentCameraViewControllerDelegate, UIDocumentPickerDelegate {
    static let shared = PagePicturePicker()
    private weak var session: PDFDrawingSession?

    func present(_ source: AttachmentSource, for session: PDFDrawingSession) {
        guard let presenter = session.window?.rootViewController?.topmostPresented else { return }
        self.session = session
        let controller: UIViewController
        switch source {
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 0
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            controller = picker
        case .camera:
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = self
            controller = picker
        case .scanner:
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = self
            controller = scanner
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            controller = picker
        }
        presenter.present(controller, animated: true)
    }

    /// Made ready in the background: a photo can be twelve megapixels.
    private func place(_ files: [Data] = [], images: [UIImage] = []) {
        Task {
            let pictures = await Task.detached(priority: .userInitiated) {
                files.compactMap(PictureImage.make(from:)) + images.compactMap { $0.upright.cgImage.flatMap(PictureImage.make(from:)) }
            }.value
            session?.insert(pictures)
        }
    }

    // MARK: - Photos

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            var files: [Data] = []
            for result in results {
                if let data = await Self.loadData(result.itemProvider) { files.append(data) }
            }
            place(files)
        }
    }

    nonisolated private static func loadData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Camera

    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        Task { @MainActor in
            picker.dismiss(animated: true)
            place(images: image.map { [$0] } ?? [])
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        Task { @MainActor in picker.dismiss(animated: true) }
    }

    // MARK: - Scanner

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        Task { @MainActor in
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true)
            place(images: pages)
        }
    }

    nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    // MARK: - Files

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let files = urls.compactMap { try? Data(contentsOf: $0) }
        Task { @MainActor in place(files) }
    }
}
#endif
