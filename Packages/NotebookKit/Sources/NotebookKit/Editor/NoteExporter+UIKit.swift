#if os(iOS)
import UIKit

/// A note as a PDF or on paper: a copy of it laid out as you read it (nothing of the Markdown showing), always light,
/// with its title on top, set on pages of the paper size of your region.
@MainActor
public enum NoteExporter {
    /// A4, or US Letter where that is the paper.
    static var paper: CGRect {
        Locale.current.measurementSystem == .us ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595, height: 842)
    }

    static let margin: CGFloat = 56

    /// The note as a PDF file in the temporary folder, named after it, for the share sheet.
    public static func pdfFile(for editor: EditorController, title: String) async -> URL? {
        guard let data = await pdfData(for: editor, title: title) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent((title.isEmpty ? "Untitled" : FileOperations.fileName(from: title)) + ".pdf")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// The system's print sheet, with the note on pages.
    public static func print(_ editor: EditorController, title: String) {
        Task {
            guard let data = await pdfData(for: editor, title: title) else { return }
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo.printInfo()
            info.jobName = title
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = data
            controller.present(animated: true)
        }
    }

    public static func pdfData(for editor: EditorController, title: String) async -> Data? {
        let width = paper.width - margin * 2
        let copy = await layOut(editor, width: width)
        // At the size Settings › Text gives, whatever the system's text size is.
        return EditorStyle.unscaled { draw(copy, title: title, width: width) }
    }

    private static func draw(_ copy: Copy, title: String, width: CGFloat) -> Data? {
        let layoutManager = copy.editor.layoutManager
        let container = copy.editor.container
        let heading = settle(copy, title: title, width: width)

        // Pages end between lines: never in the middle of one, of a picture or of a table.
        var pages: [(top: CGFloat, bottom: CGFloat)] = []
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            let available = paper.height - margin * 2 - (pages.isEmpty ? heading.height : 0)
            if rect.maxY - top > available, rect.minY > top {
                pages.append((top, bottom))
                top = rect.minY
            }
            bottom = rect.maxY
        }
        pages.append((top, max(bottom, top)))

        let renderer = UIGraphicsPDFRenderer(bounds: paper, format: {
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [kCGPDFContextTitle as String: title]
            return format
        }())
        var data: Data?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            data = renderer.pdfData { context in
                for (index, page) in pages.enumerated() {
                    context.beginPage()
                    drawPage(copy, title: index == 0 ? heading : nil, lines: page.top..<page.bottom, width: width, in: context.cgContext)
                }
            }
        }
        return data
    }

    /// The top of the note on a page `size` points big, `scale` pixels to the point: its PDF's first page, cut off where
    /// the page ends, on white. For thumbnails (NoteThumbnail).
    static func top(of editor: EditorController, title: String, size: CGSize, scale: CGFloat) async -> (image: CGImage, copy: Copy)? {
        let width = paper.width - margin * 2
        let copy = await layOut(editor, width: width)
        let page = CGSize(width: paper.width, height: (paper.width * size.height / size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        // The page's points on the picture's pixels: the page drawn smaller.
        format.scale = size.width * scale / page.width
        format.opaque = true
        var image: CGImage?
        EditorStyle.unscaled {
            let heading = settle(copy, title: title, width: width)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = UIGraphicsImageRenderer(size: page, format: format).image { context in
                    Theme.panel.setFill()
                    context.fill(CGRect(origin: .zero, size: page))
                    drawPage(copy, title: heading, lines: 0..<page.height, width: width, in: context.cgContext)
                }.cgImage
            }
        }
        return image.map { ($0, copy) }
    }

    /// The copy laid out again at the size Settings › Text gives, and its title as it goes on top of the first page.
    private static func settle(_ copy: Copy, title: String, width: CGFloat) -> (text: NSAttributedString, height: CGFloat) {
        // A picture or diagram that came in while the copy waited set its lines again, at the screen's size.
        copy.editor.restyle(lines: Array(copy.editor.document.lines.indices))
        copy.editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: copy.editor.storage.length), actualCharacterRange: nil)
        copy.editor.layoutManager.ensureLayout(for: copy.editor.container)
        let titleFont = EditorStyle.face(26, weight: .bold)
        let text = NSAttributedString(string: title.isEmpty ? "Untitled" : title, attributes: [.font: titleFont, .foregroundColor: Theme.text])
        return (text, ceil(text.boundingRect(with: CGSize(width: width, height: 400), options: [.usesLineFragmentOrigin], context: nil).height) + 18)
    }

    /// A page: the title on the first, then the copy's `lines` (from the top of its text), inside the margins.
    private static func drawPage(_ copy: Copy, title: (text: NSAttributedString, height: CGFloat)?, lines: Range<CGFloat>, width: CGFloat, in cg: CGContext) {
        var y = margin
        if let title {
            title.text.draw(with: CGRect(x: margin, y: y, width: width, height: title.height), options: [.usesLineFragmentOrigin], context: nil)
            y += title.height
        }
        let height = lines.upperBound - lines.lowerBound
        let layoutManager = copy.editor.layoutManager
        cg.saveGState()
        cg.clip(to: CGRect(x: margin - 4, y: y, width: width + 8, height: height))
        let origin = CGPoint(x: margin, y: y - lines.lowerBound)
        let range = layoutManager.glyphRange(forBoundingRect: CGRect(x: 0, y: lines.lowerBound, width: width, height: height), in: copy.editor.container)
        layoutManager.drawBackground(forGlyphRange: range, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
        cg.restoreGState()
    }

    /// Links resolve as in the note; nothing else the copy does reaches the app.
    final class ResolvingDelegate: EditorControllerDelegate {
        weak var source: EditorController?
        init(source: EditorController) { self.source = source }
        func editorTextDidChange(_ editor: EditorController) {}
        func editor(_ editor: EditorController, open target: LinkTarget.Kind) {}
        func editor(_ editor: EditorController, quickLook url: URL) {}
        func editor(_ editor: EditorController, commitTitle title: String) {}
        func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] { [] }
        func editor(_ editor: EditorController, resolve target: String) -> URL? {
            guard let source else { return nil }
            return source.delegate?.editor(source, resolve: target)
        }
        func editorNoteName(_ editor: EditorController) -> String { "" }
    }

    /// The copy, with the delegate it holds weakly.
    struct Copy {
        let editor: EditorController
        let delegate: ResolvingDelegate
    }

    /// A light copy of the note, laid out `width` wide, once its pictures and diagrams are there (a few seconds at
    /// most).
    static func layOut(_ editor: EditorController, width: CGFloat) async -> Copy {
        let copy = EditorController()
        copy.layoutManager.hidesEditingControls = true
        copy.layoutManager.picturesOutOfReach = editor.layoutManager.picturesOutOfReach
        let delegate = ResolvingDelegate(source: editor)
        copy.delegate = delegate
        copy.textView.overrideUserInterfaceStyle = .light
        copy.container.widthTracksTextView = false
        copy.container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        EditorStyle.unscaled { copy.load(text: editor.text, folder: editor.folder, title: "", meta: "") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for _ in 0..<80 {
            // Drawing asks for the pictures and diagrams, which load in the background.
            EditorStyle.unscaled {
                copy.layoutManager.ensureLayout(for: copy.container)
                let used = copy.layoutManager.usedRect(for: copy.container)
                _ = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
                    let glyphs = copy.layoutManager.glyphRange(forBoundingRect: CGRect(x: 0, y: 0, width: width, height: used.height + 1), in: copy.container)
                    copy.layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
                }
            }
            if !ImageStore.shared.isBusy, !ThumbnailStore.shared.isBusy, !DiagramStore.isBusy, !DrawingStore.shared.isBusy { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Copy(editor: copy, delegate: delegate)
    }
}
#endif
