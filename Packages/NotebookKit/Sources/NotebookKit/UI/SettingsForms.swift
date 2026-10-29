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
            Section {
                ForEach(FileKind.files, id: \.self) { FileColorPicker(kind: $0) }
            } header: {
                Text("Icon Colours")
            } footer: {
                Text("Every kind of file has an icon of its own, in the accent colour unless you choose another. A folder takes the colour you give it with Customize Folder.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The colour of one kind of file's icon: the accent colour, or one of the Finder's tag colours. Swatches on the Mac, as
/// System Settings has accent colours; a list of the icon in each colour on iPhone and iPad.
private struct FileColorPicker: View {
    let kind: FileKind
    @Bindable private var settings = NotebookSettings.shared

    var body: some View {
        let chosen = settings.fileColors[kind]
        #if os(macOS)
        LabeledContent {
            HStack(spacing: 2) {
                ColorSwatch(color: Color.theme(Theme.accent), name: "Accent Colour", isChosen: chosen == nil, size: 14) { settings.fileColors[kind] = nil }
                ForEach(FolderColor.allCases, id: \.self) { color in
                    ColorSwatch(color: color.color, name: color.name, isChosen: chosen == color, size: 14) { settings.fileColors[kind] = color }
                }
            }
        } label: {
            Self.icon(of: kind, kind.pluralName, color: chosen)
        }
        #else
        NavigationLink {
            FileColorList(kind: kind)
        } label: {
            LabeledContent {
                Text(chosen?.name ?? "Accent Colour")
            } label: {
                Self.icon(of: kind, kind.pluralName, color: chosen)
            }
        }
        #endif
    }

    /// The kind's name, or a colour's, next to the kind's icon in that colour.
    static func icon(of kind: FileKind, _ title: String, color: FolderColor?) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: kind.symbol)
                .foregroundStyle(color?.color ?? Color.theme(Theme.accent))
                #if os(macOS)
                // The symbols differ in width, and a form on the Mac doesn't line up its labels' icons as one on iOS does.
                .frame(width: 18)
                #endif
        }
    }
}

#if os(iOS)
/// The colours for one kind of file on iPhone and iPad, as Settings lists a choice: the kind's icon in each, the one
/// chosen ticked. Choosing one goes back.
private struct FileColorList: View {
    let kind: FileKind
    @Bindable private var settings = NotebookSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            row("Accent Colour", color: nil)
            ForEach(FolderColor.allCases, id: \.self) { row($0.name, color: $0) }
        }
        .navigationTitle(kind.pluralName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, color: FolderColor?) -> some View {
        let isChosen = settings.fileColors[kind] == color
        return Button {
            settings.fileColors[kind] = color
            dismiss()
        } label: {
            HStack {
                FileColorPicker.icon(of: kind, name, color: color)
                Spacer()
                if isChosen {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
#endif
