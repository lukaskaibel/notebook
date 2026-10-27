#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Earlier versions of the open note (`NoteHistory`): File › Revert To on the Mac, Version History in the note's ⋯ menu
/// on iPhone and iPad.
extension Workspace {
    /// The note Revert To and the versions act on, with its editor: the main window's, or on the Mac a note's own
    /// window when that is the one you are working in.
    struct VersionTarget {
        let note: NoteDocument
        let editor: EditorController
        #if os(macOS)
        let window: NSWindow?
        #endif
        /// Whether the note is still the one its editor shows: another may have been opened since (from Spotlight, a
        /// reminder, a new note), and a version is never put into that one.
        let isCurrent: @MainActor () -> Bool
    }

    func versionTarget() -> VersionTarget? {
        #if os(macOS)
        // A sheet over a note's window, the versions', says nothing of its own: the window under it is the one.
        if let key = NSApp.keyWindow.map({ $0.sheetParent ?? $0 }), let controller = key.windowController as? FileWindowController {
            guard controller.isLoaded else { return nil }
            return VersionTarget(note: controller.noteDocument, editor: controller.editor, window: key) { [weak controller] in
                controller?.window?.isVisible == true
            }
        }
        guard let note, note.isLoaded else { return nil }
        return VersionTarget(note: note, editor: editor, window: editor.textView.window) { [weak self, weak note] in
            note != nil && self?.note === note
        }
        #else
        guard let note, note.isLoaded else { return nil }
        return VersionTarget(note: note, editor: editor) { [weak self, weak note] in note != nil && self?.note === note }
        #endif
    }

    /// The note Revert To acts on: on the Mac the one in the window you are working in, a note's own or the main
    /// window's.
    var revertNote: NoteDocument? {
        #if os(macOS)
        keyFileNote ?? note
        #else
        note
        #endif
    }

    /// Whether Revert To › Last Opened would change the note: something was changed since it was opened.
    var canRevertToLastOpened: Bool {
        guard let note = revertNote, note.isLoaded else { return false }
        return note.isChangedSinceOpening
    }

    /// The open note changed: the versions shown were another's, and go.
    func closeVersions() {
        #if os(macOS)
        VersionsWindow.close(over: editor.textView.window)
        #else
        versionBrowser = nil
        #endif
    }

    /// The note as it was when it was opened, as one change Undo takes back.
    func revertToLastOpened() {
        guard let target = versionTarget(), let opened = target.note.openedText, opened != target.editor.text else { return beep() }
        restore(opened, in: target, actionName: "Revert to Last Opened")
    }

    /// Browse All Versions… on the Mac, in a sheet over the note's window; Version History on iPhone and iPad.
    func browseVersions() {
        guard let target = versionTarget() else { return beep() }
        let editor = target.editor
        let browser = VersionBrowser(note: target.note.url, current: { [weak editor] in editor?.text ?? "" }) { [weak self] text in
            self?.restore(text, in: target, actionName: "Restore Version")
        }
        #if os(macOS)
        guard let window = target.window else { return beep() }
        VersionsWindow.show(browser, editor: editor, over: window)
        #else
        editor.endEditing()
        versionBrowser = browser
        #endif
    }

    /// Puts a version's text in the note as one change Undo takes back. The text there was is kept as a version first.
    /// Nothing happens when the note isn't the one open any more.
    func restore(_ text: String, in target: VersionTarget, actionName: String) {
        guard target.isCurrent(), target.note.isLoaded else { return beep() }
        target.note.update(text: target.editor.text)
        target.note.keepCopyBeforeRestoring()
        target.editor.restore(text: text, actionName: actionName)
    }
}
