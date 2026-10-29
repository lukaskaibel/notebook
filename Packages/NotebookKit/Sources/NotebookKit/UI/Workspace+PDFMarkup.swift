import Foundation
#if os(macOS)
import AppKit
#endif

/// Drawing on the PDF that is open, and on the Mac highlighting its text.
@MainActor
extension Workspace {
    /// The file open, when it is a PDF.
    var currentPDF: URL? {
        guard note == nil, let url = currentURL, FileKind(url: url, isDirectory: false) == .pdf else { return nil }
        return url
    }

    /// The pencil is on: in the note, or on the PDF open.
    var isDrawingInFront: Bool {
        isDrawing || (drawsOnPDF != nil && drawsOnPDF == currentURL)
    }

    /// The pencil in the toolbar, Format › Drawing and ⌘K's Drawing: drawing in the note, or on the PDF.
    func toggleDrawing() {
        if note != nil {
            editor.toggleDrawing()
        } else if let pdf = currentPDF {
            drawsOnPDF = drawsOnPDF == pdf ? nil : pdf
        }
    }

    #if os(macOS)
    /// Format › Highlight (⌃⌘H): in a note it marks the text selected as highlighted, in a PDF it highlights the text
    /// selected on its pages.
    var canHighlight: Bool {
        hasNoteInFront || (isMainWindowInFront && canHighlightPDF)
    }

    func highlight() {
        if hasNoteInFront {
            NSApp.sendAction(#selector(MarkdownTextView.toggleHighlight(_:)), to: nil, from: nil)
        } else if isMainWindowInFront {
            shownPDF?.highlightSelection(nil)
        }
    }

    /// The text selected in the PDF changed, or drawing on it started or stopped.
    func pdfSelectionChanged(_ view: NotebookPDFView) {
        guard view === shownPDF, canHighlightPDF != view.canHighlight else { return }
        canHighlightPDF = view.canHighlight
    }

    /// The PDF went from the window.
    func pdfClosed(_ view: NotebookPDFView) {
        guard view === shownPDF else { return }
        shownPDF = nil
        canHighlightPDF = false
    }
    #endif
}
