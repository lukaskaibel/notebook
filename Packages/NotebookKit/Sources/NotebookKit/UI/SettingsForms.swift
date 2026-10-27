import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The typeface, size, line spacing and width of notes, with a sample set as you choose.
struct TextSettings: View {
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        Form {
            Section {
                // Each typeface in itself. A menu on iOS can't show them, so there they are a list of their own.
                Picker("Font", selection: $settings.typography.face) {
                    ForEach(Typography.Face.allCases) { face in
                        Text(face.name).font(Font(face.font(Self.fontSize))).tag(face)
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.typography.size, in: Typography.sizes, step: 1)
                        Text("\(Int(settings.typography.size)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Line spacing", selection: $settings.typography.spacing) {
                    ForEach(Typography.Spacing.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                if showsWidth {
                    Picker("Line width", selection: $settings.typography.width) {
                        ForEach(Typography.Width.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                #if os(iOS)
                Text("The text size you choose in the Settings app, under Display & Brightness, makes notes larger or smaller too, as it does in other apps.")
                #endif
            }
            Section("Preview") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Rise of Rococo")
                        .font(Font(EditorStyle.headingFont(2)))
                    Text("Emerging from the grandeur of Baroque, Rococo offered something more intimate and playful.")
                        .font(Font(EditorStyle.body))
                        .lineSpacing(EditorStyle.lineHeight - EditorStyle.bodySize * 1.2)
                }
                .padding(.vertical, 4)
                .id(settings.typography)
            }
        }
        .formStyle(.grouped)
    }

    /// The size of a menu's items on the Mac, of a list's rows on iOS.
    private static var fontSize: CGFloat {
        #if os(iOS)
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        NSFont.systemFontSize
        #endif
    }

    /// On the iPhone the text is as wide as the screen, whatever the setting.
    private var showsWidth: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }
}

/// Whether To-dos is there: off for those who keep their to-dos in another app.
struct TodosSetting: View {
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        Section {
            Toggle("Show To-dos", isOn: $settings.showsTodos)
        } footer: {
            #if os(macOS)
            Text("Every checkbox in your notes, by when it is due, at the top of the sidebar. Turned off, Notebook doesn’t remind you of to-dos either, for when you keep them in another app.")
                .foregroundStyle(.secondary)
            #else
            Text("Every checkbox in your notes, by when it is due, above your folders. Turned off, Notebook doesn’t remind you of to-dos either, for when you keep them in another app.")
            #endif
        }
    }
}

struct SidebarSettings: View {
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        Form {
            #if os(macOS)
            TodosSetting()
            #endif
            Section {
                Toggle("Show only notes", isOn: $settings.showsOnlyNotes)
                Toggle("Dim files that aren’t notes", isOn: $settings.dimsOtherFiles)
                    .disabled(settings.showsOnlyNotes)
                Picker("Sort by", selection: Binding(get: { settings.fileOrders.order(of: nil) }, set: { settings.fileOrders.set($0, for: nil) })) {
                    ForEach(FileOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
            } footer: {
                Text("PDFs, pictures and other files still open from search and from links in your notes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
