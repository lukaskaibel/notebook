import NotebookCapture
import SwiftUI
import WidgetKit

/// New Note in Control Center, on the Lock Screen and on the Action button, as the system's own controls are.
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NewNoteControl") {
            ControlWidgetButton(action: NewNoteIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Opens Notebook with a new note in the default folder.")
    }
}
