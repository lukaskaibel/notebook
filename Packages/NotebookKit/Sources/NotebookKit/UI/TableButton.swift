import SwiftUI

/// Table in the toolbar, as in Notes: a table to type in; with the caret in one, that table's menu, to add and delete
/// its rows and columns.
struct TableButton: View {
    let editor: EditorController

    var body: some View {
        if editor.caretContext.isInTable {
            AppMenuButton {
                editor.tableEntries()
            } label: {
                Label("Table", systemImage: "tablecells")
            }
            .help("Table")
        } else {
            Button { editor.beginEditing(then: .table) } label: { Label("Table", systemImage: "tablecells") }
                .help(editor.syntax == .markdown ? "Table (⌥⌘T)" : "Tables in AsciiDoc notes are typed")
                .disabled(editor.syntax != .markdown)
        }
    }
}
