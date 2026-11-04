#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A note as a PDF, a picture or on paper: a copy of it laid out as you read it (nothing of the Markdown showing),
/// always light, with its title on top.
@MainActor
public enum NoteExporter {
    public enum Format {
        case pdf, png

        var type: UTType { self == .pdf ? .pdf : .png }
    }

    /// Asks where to save, then writes the note there.
    public static func export(_ editor: EditorController, title: String, as format: Format, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = title.isEmpty ? "Untitled" : title
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let data = await self.data(for: editor, title: title, as: format)
                do {
                    try data?.write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    /// The system's print panel, with its preview and Save as PDF.
    public static func print(_ editor: EditorController, title: String, from window: NSWindow?) {
        Task { @MainActor in
            let info = printInfo()
            let copy = await layOut(editor, title: title, width: info.paperSize.width - info.leftMargin - info.rightMargin, margin: 0)
            let operation = NSPrintOperation(view: copy.view, printInfo: info)
            operation.jobTitle = title
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            if let window {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
            keepAlive(copy, for: operation)
        }
    }

    /// The note as PDF pages or one tall PNG.
    public static func data(for editor: EditorController, title: String, as format: Format) async -> Data? {
        switch format {
        case .pdf:
            // Printed to a file, so the note is set on pages of the paper size you print on.
            let info = printInfo()
            let copy = await layOut(editor, title: title, width: info.paperSize.width - info.leftMargin - info.rightMargin, margin: 0)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook export \(UUID().uuidString).pdf")
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
            let operation = NSPrintOperation(view: copy.view, printInfo: info)
            operation.jobTitle = title
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
            defer { try? FileManager.default.removeItem(at: file) }
            return try? Data(contentsOf: file)
        case .png:
            let copy = await layOut(editor, title: title, width: EditorStyle.contentWidth + 96, margin: 48)
            let view = copy.view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
    }

    // MARK: - The copy

    final class Copy {
        let editor: EditorController
        let delegate: ResolvingDelegate
        var view: MarkdownTextView { editor.textView }

        init(editor: EditorController, delegate: ResolvingDelegate) {
            self.editor = editor
            self.delegate = delegate
        }
    }

    /// Links resolve as in the note; nothing else the copy does reaches the window.
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

    static func layOut(_ editor: EditorController, title: String, width: CGFloat, margin: CGFloat) async -> Copy {
        let copy = EditorController()
        copy.layoutManager.hidesEditingControls = true
        let delegate = ResolvingDelegate(source: editor)
        copy.delegate = delegate
        let view = copy.textView
        view.appearance = NSAppearance(named: .aqua)
        view.exportMargin = margin
        view.setFrameSize(NSSize(width: width, height: 200))
        copy.load(text: editor.text, folder: editor.folder, title: title, meta: "", syntax: editor.syntax)
        // Draw once so pictures and diagrams start loading, then wait (a few seconds at most) until they are there.
        fit(copy, margin: margin)
        for _ in 0..<80 {
            render(view)
            if !ImageStore.shared.isBusy, !ThumbnailStore.shared.isBusy, !DiagramStore.isBusy, !DrawingStore.shared.isBusy { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        fit(copy, margin: margin)
        return Copy(editor: copy, delegate: delegate)
    }

    private static func fit(_ copy: EditorController, margin: CGFloat) {
        let view = copy.textView
        copy.layoutManager.ensureLayout(for: copy.container)
        let used = copy.layoutManager.usedRect(for: copy.container)
        view.setFrameSize(NSSize(width: view.frame.width, height: ceil(view.headerHeight + used.height + max(margin, 24))))
    }

    private static func render(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        return info
    }

    private static var printing: [ObjectIdentifier: Copy] = [:]

    /// The copy has to outlive the print panel, which runs after this returns.
    private static func keepAlive(_ copy: Copy, for operation: NSPrintOperation) {
        let key = ObjectIdentifier(operation)
        printing[key] = copy
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { printing[key] = nil }
    }
}
#endif
