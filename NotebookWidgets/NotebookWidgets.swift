import AppIntents
import NotebookCapture
import SwiftUI
import WidgetKit

/// Notebook's widgets and controls: New Note on the Home Screen, the Lock Screen and the Mac's desktop, and in
/// Control Center, which runs the New Note intent; today's to-dos; and a note of your choice. What the last two show,
/// the app keeps for them in the App Group (`WidgetData`).
@main
struct NotebookWidgets: WidgetBundle {
    var body: some Widget {
        NewNoteWidget()
        TodosWidget()
        NoteWidget()
        NewNoteControl()
    }
}

/// The intents the widgets run, from NotebookCapture, which the app has too: the system runs them in the app.
struct NotebookWidgetsIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [NotebookCaptureIntents.self] }
}
