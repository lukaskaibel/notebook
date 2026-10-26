import AppIntents
import NotebookCapture
import SwiftUI
import WidgetKit

/// Notebook's widgets and controls: New Note on the Home Screen, the Lock Screen and the Mac's desktop, and in
/// Control Center. Each runs the New Note intent, which opens Notebook with a new note in the default folder.
@main
struct NotebookWidgets: WidgetBundle {
    var body: some Widget {
        NewNoteWidget()
        NewNoteControl()
    }
}

/// The intents the widgets run, from NotebookCapture, which the app has too: the system runs them in the app.
struct NotebookWidgetsIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [NotebookCaptureIntents.self] }
}
