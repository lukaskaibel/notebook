#if os(macOS)
import AppKit

/// What the File and Edit menus do with the note in the window you are working in, a note's own window or this one,
/// as Notes' menus do: find in it, check its spelling, attach files to it, duplicate, rename or trash it.
extension Workspace {
    /// The file of the window you are working in.
    var fileInFront: URL? {
        keyFileNote?.url ?? (showsTodos ? nil : currentURL)
    }

    /// A note to type in is in the window you are working in: what Format, Find and Attach File need.
    var hasNoteInFront: Bool {
        (keyFileNote ?? (showsTodos ? nil : note))?.isLoaded == true
    }

    /// Edit › Find, in the note's find bar, as in TextEdit: wherever the keyboard is, it finds in the note in front.
    func find(_ action: NSTextFinder.Action) {
        guard let textView = activeEditor()?.editor.textView else { return beep() }
        // The find bar's field takes the keyboard; Find Next and the others go on from the note.
        if action != .showFindInterface, action != .showReplaceInterface { textView.window?.makeFirstResponder(textView) }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    /// Edit › Find › Jump to Selection.
    func jumpToSelection() {
        guard let textView = activeEditor()?.editor.textView else { return beep() }
        textView.window?.makeFirstResponder(textView)
        textView.centerSelectionInVisibleArea(nil)
    }

    /// Edit › Spelling and Grammar's Show Spelling and Grammar and Check Document Now, and Speech: for the note in
    /// front, also while the sidebar has the keyboard.
    func sendToNote(_ action: Selector) {
        guard let textView = activeEditor()?.editor.textView else { return beep() }
        if action != #selector(NSTextView.stopSpeaking(_:)) { textView.window?.makeFirstResponder(textView) }
        NSApp.sendAction(action, to: textView, from: nil)
    }

    /// Edit › Attach File…: pictures, PDFs and other files chosen in the Open panel go in at the caret, stored next to
    /// the note as if they were dropped there; notes go in as links.
    func attachFiles() {
        guard let active = activeEditor(), let window = active.window else { return beep() }
        let editor = active.editor
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Pictures, PDFs and other files go in the note; notes go in as links."
        panel.beginSheetModal(for: window) { [weak editor] response in
            MainActor.assumeIsolated {
                guard response == .OK, let editor, !panel.urls.isEmpty else { return }
                window.makeFirstResponder(editor.textView)
                _ = editor.pasteFiles(panel.urls, at: editor.selection)
            }
        }
    }

    /// File › Rename: the note's title takes the keyboard, its name selected, as Rename in the ⋯ menu.
    func renameInFront() {
        guard let active = activeEditor() else { return beep() }
        active.window?.makeFirstResponder(active.editor.textView)
        active.editor.focusTitle()
    }
}
#endif
