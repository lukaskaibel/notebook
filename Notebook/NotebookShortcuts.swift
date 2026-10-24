import AppIntents
import NotebookKit

/// New Note, in Shortcuts and Spotlight without setting anything up, for Siri, and for the Action button on iPhone.
struct NotebookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: [
                "New note in \(.applicationName)",
                "Make a note in \(.applicationName)",
                "Start a note in \(.applicationName)",
            ],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
    }
}

/// The intents are in NotebookKit; Shortcuts learns of them through the app.
struct NotebookIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [NotebookKitIntents.self] }
}
