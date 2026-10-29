#if os(macOS)
import AppKit
import SwiftUI

/// The pencil in the toolbar, as in Notes: on while the note or the PDF is drawn on.
struct DrawingToggle: View {
    let workspace: Workspace

    var body: some View {
        Toggle(isOn: Binding(get: { workspace.isDrawingInFront }, set: { _ in workspace.toggleDrawing() })) {
            Label("Drawing", systemImage: "pencil.tip.crop.circle")
        }
        .help(workspace.isDrawingInFront ? "Stop drawing (Esc)" : workspace.note == nil ? "Draw on the PDF" : "Draw in the note")
    }
}

/// The drawing tools on the Mac, floating at the bottom of the note or the PDF while you draw, as Notes has them: what
/// draws, its width and colour, and Done. The iPad's tool picker is PencilKit's own; the Mac has none.
struct DrawingPalette: View {
    let workspace: Workspace
    @Bindable private var tools = DrawingTools.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $tools.tool) {
                ForEach(DrawingTools.Tool.allCases) { tool in
                    Label(tool.name, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help(tools.tool.name)

            Divider().frame(height: 20)

            widthMenu
            if tools.tool == .eraser {
                Picker("Eraser", selection: $tools.eraser) {
                    ForEach(DrawingTools.Eraser.allCases) { eraser in Text(eraser.name).tag(eraser) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(DrawingTools.palette.enumerated()), id: \.offset) { _, color in swatch(color) }
                    ColorPicker("Colour", selection: Binding(get: { Color(nsColor: tools.color) }, set: { tools.color = NSColor($0) }), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                        .help("Other colour")
                }
            }

            Divider().frame(height: 20)

            Button("Done") {
                if workspace.isDrawing { workspace.editor.endDrawing() } else { workspace.drawsOnPDF = nil }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var widthMenu: some View {
        Menu {
            Picker("Width", selection: $tools.widthLevel) {
                Text("Fine").tag(0)
                Text("Medium").tag(1)
                Text("Bold").tag(2)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "lineweight")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Width")
    }

    private func swatch(_ color: NSColor) -> some View {
        let selected = tools.color.hexValue == color.hexValue
        // Black ink is drawn white in dark mode, as PencilKit draws it; on a PDF's page, which is paper, it stays black.
        let rgba = color.rgba
        let shown = colorScheme == .dark && workspace.isDrawing && rgba.red + rgba.green + rgba.blue < 0.4 ? NSColor.white : color
        return Button { tools.color = color } label: {
            Circle()
                .fill(Color(nsColor: shown))
                .frame(width: 18, height: 18)
                .padding(2.5)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
