import SwiftUI

/// Sort By, as in the Finder's View menu and the ⋯ menu of the Files app: Name, Date Edited or Date Created, the one
/// chosen ticked. For the files in `folder`.
struct SortByPicker: View {
    let folder: URL?

    var body: some View {
        #if os(iOS)
        // As in Notes and Files: the order it is in now, under its name.
        Menu {
            picker.pickerStyle(.inline)
        } label: {
            Text("Sort By")
            Text(NotebookSettings.shared.fileOrders.order(of: folder).title)
            Image(systemName: "arrow.up.arrow.down")
        }
        #else
        picker.pickerStyle(.menu)
        #endif
    }

    private var picker: some View {
        let orders = NotebookSettings.shared.fileOrders
        return Picker(selection: Binding(get: { orders.order(of: folder) }, set: { order in withAnimation { orders.set(order, for: folder) } })) {
            ForEach(FileOrder.allCases) { order in
                Text(order.title).tag(order)
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
    }
}
