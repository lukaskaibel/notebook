#if os(macOS)
import AppKit
#else
import Foundation
#endif

/// Deleting as you ask for it from a menu, a swipe or a key: a note with something in it goes only once you said so,
/// unless Settings say not to ask. Undo and Redo, and notes left empty, go by `trash` and never ask.
extension Workspace {
    /// Whether deleting this file can come with a question: only notes can, typed or handwritten. A swipe that may ask
    /// leaves the row in its place, for the question to be about.
    func mayAskBeforeTrashing(_ url: URL, isFolder: Bool = false) -> Bool {
        guard NotebookSettings.shared.asksBeforeDeletingNotes, !isFolder else { return false }
        let kind = FileKind(url: url, isDirectory: false)
        return kind == .note || kind == .pdf
    }

    /// Moves a file to the Trash, first asking if it is a note with something in it. `next` as for `trash`. Asked again
    /// for a file it is already looking at or asking about, it does nothing.
    func trashAfterAsking(_ url: URL, next: URL? = nil) {
        guard mayAskBeforeTrashing(url) else {
            trash(url, next: next)
            return
        }
        let path = url.standardizedFileURL.path
        guard askingBeforeTrashing.insert(path).inserted else { return }
        Task { [self] in
            if await asksBeforeTrashing(url) {
                askBeforeTrashing(url, next: next)
            } else {
                askingBeforeTrashing.remove(path)
                trash(url, next: next)
            }
        }
    }

    /// Whether there is something in the note to ask about. What is open counts as it is now, typed or drawn a moment
    /// ago too, and the file is looked at off the main thread.
    func asksBeforeTrashing(_ url: URL) async -> Bool {
        guard mayAskBeforeTrashing(url) else { return false }
        let documents = NoteDocument.documents(atOrInside: url)
        if documents.contains(where: { !$0.isLoaded || $0.conflict != nil || !$0.isEmpty }) { return true }
        // Open and emptied, with the old text still on disk until it is saved.
        if documents.contains(where: { !$0.isClosed }) { return false }
        await PDFDrawingSession.save(atOrInside: url)
        return await Task.detached(priority: .userInitiated) { NoteContents.hasContent(url) }.value
    }

    private func askBeforeTrashing(_ url: URL, next: URL?) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Move “\(Self.shownName(url))” to the Trash?"
        alert.informativeText = "You can put it back with Undo, or from the Trash in the Finder."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard let self else { return }
            askingBeforeTrashing.remove(url.standardizedFileURL.path)
            if response == .alertFirstButtonReturn { trash(url, next: next) }
        }
        #else
        deleteQuestions.ask(url, confirming: true)
        #endif
    }
}
