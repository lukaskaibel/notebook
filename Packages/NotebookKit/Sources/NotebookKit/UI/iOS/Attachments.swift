#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Where a picture or file for a note comes from.
enum AttachmentSource: CaseIterable, Identifiable {
    case photos, camera, scanner, files

    var id: Self { self }

    var name: String {
        switch self {
        case .photos: "Photo Library"
        case .camera: "Take Photo"
        case .scanner: "Scan Documents"
        case .files: "Attach File"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .camera: "camera"
        case .scanner: "doc.viewfinder"
        case .files: "paperclip"
        }
    }

    /// The camera and the scanner only where the device has a camera.
    var isAvailable: Bool {
        switch self {
        case .camera: UIImagePickerController.isSourceTypeAvailable(.camera)
        case .scanner: VNDocumentCameraViewController.isSupported
        default: true
        }
    }

    static var available: [AttachmentSource] { allCases.filter(\.isAvailable) }
}

/// Brings up the system's photo picker, camera, document scanner or file browser, and puts what comes back into the
/// note at the caret: pictures saved next to it in `.assets`, other files copied there, notes as links.
@MainActor
final class AttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    VNDocumentCameraViewControllerDelegate, UIDocumentPickerDelegate {
    static let shared = AttachmentPicker()
    private weak var editor: EditorController?
    /// The note the picker was opened for: what comes back goes into it only.
    private var note = 0

    func present(_ source: AttachmentSource, for editor: EditorController) {
        guard let presenter = editor.textView.window?.rootViewController?.topmostPresented
            ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first?.topmostPresented else { return }
        self.editor = editor
        note = editor.loadCount
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
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            controller = picker
        }
        presenter.present(controller, animated: true)
    }

    private func insert(_ images: [UIImage]) {
        guard let editor, editor.loadCount == note, !images.isEmpty else { return }
        // Only now: cancelled, the picker leaves the caret where it was.
        editor.placeCaretForToolbar()
        editor.makeTextFirstResponder()
        editor.insertPictures(images)
    }

    // MARK: - Photos

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            var images: [UIImage] = []
            for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                if let image = await Self.loadImage(result.itemProvider) { images.append(image) }
            }
            insert(images)
        }
    }

    nonisolated private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    // MARK: - Camera

    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        Task { @MainActor in
            picker.dismiss(animated: true)
            insert(image.map { [$0.upright] } ?? [])
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
            insert(pages)
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
        Task { @MainActor in
            guard let editor, editor.loadCount == note else { return }
            editor.placeCaretForToolbar()
            editor.makeTextFirstResponder()
            editor.insertFiles(urls)
        }
    }
}

extension UIImage {
    /// The picture drawn the way the camera was held, so it is saved upright as PNG or JPEG.
    var upright: UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }
    }
}

/// The attachment menu of a toolbar: the photo library, the camera, the scanner and files.
struct AttachmentMenu: View {
    let editor: EditorController

    var body: some View {
        Menu {
            ForEach(AttachmentSource.available) { source in
                Button { AttachmentPicker.shared.present(source, for: editor) } label: { Label(source.name, systemImage: source.symbol) }
            }
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
    }
}
#endif
