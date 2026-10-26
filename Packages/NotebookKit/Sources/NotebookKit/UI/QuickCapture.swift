import AppIntents
import NotebookCapture

/// Notes asked for from outside the window: the New Note intent, from Shortcuts, Spotlight, the Action button, the
/// widgets and Control Center. The intent is in NotebookCapture, which the widgets' extension has too; it runs in the
/// app, and makes its notes here.
@MainActor
public enum QuickCapture {
    /// Called as the app starts, before the system hands it an intent that started it.
    public static func start() {
        NewNoteIntent.makeNote = { text in
            let workspace = Workspace.shared
            guard await workspace.newNoteFromOutside(text: text) != nil else {
                throw workspace.locations.isEmpty ? NewNoteIntentError.noLocation : .notMade
            }
        }
    }

    /// A URL the app is opened with that asks for a note: a New Note widget's where the intent didn't run. False for
    /// any other.
    public static func open(_ url: URL) -> Bool {
        guard url == NewNoteIntent.widgetURL else { return false }
        Task { await Workspace.shared.newNoteFromOutside() }
        return true
    }
}

/// NotebookKit's intents, for the app to take into its App Shortcuts (`NotebookShortcuts` in the app target).
public struct NotebookKitIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [NotebookCaptureIntents.self] }
}
