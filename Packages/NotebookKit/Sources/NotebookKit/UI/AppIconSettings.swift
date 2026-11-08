#if os(macOS)
import AppKit
import SwiftUI
import TipKit

/// Settings › App Icon: the notebook on the app's icon, in the leather, band and ribbon you like.
struct AppIconSettings: View {
    @Bindable private var store = AppIconStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 36) {
                    preview(store.lightIcon, "Light")
                    preview(store.darkIcon, "Dark")
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                LabeledContent("Leather") {
                    SwatchRow(swatches: NotebookLook.leathers, color: $store.look.leather)
                }
                Picker("Elastic band", selection: $store.look.band) {
                    ForEach(NotebookLook.Band.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Ribbon") {
                    SwatchRow(swatches: NotebookLook.ribbons, color: $store.look.ribbon)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your notebook shows in the Dock while the app is open, in light or dark with your Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Standard") { store.reset() }
                        .disabled(store.look == .standard)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if store.lightIcon == nil { store.renderPreviews() }
            AppIconTip().invalidate(reason: .actionPerformed)
        }
    }

    private func preview(_ image: NSImage?, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 88, height: 88)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App icon, \(caption.lowercased())")
    }
}

/// A row of colours to pick from, like the accent colours in System Settings, and a colour well for any other.
private struct SwatchRow: View {
    let swatches: [NotebookLook.Swatch]
    @Binding var color: NotebookColor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(swatches) { swatch in
                let selected = swatch.color == color
                Button {
                    color = swatch.color
                } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.color.nsColor))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ColorPicker("Other colour", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { color = NotebookColor(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Other colour")
        }
        // The row's label lines up with the middle of the colours, not their top.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

/// The tip at the bottom of the sidebar that the app's icon can be made your own. It goes once you close it or open
/// Settings › App Icon.
struct AppIconTip: Tip {
    var title: Text { Text("Make the icon yours") }
    var message: Text? { Text("Pick the notebook’s leather, band and ribbon.") }
    var image: Image? { Image(systemName: "book.closed") }
    var actions: [Action] { [Action(id: "open", title: "Open Settings")] }

    @MainActor private static var configured = false

    /// Starts TipKit, once, before any tip shows.
    @MainActor
    static func configure() {
        guard !configured else { return }
        configured = true
        #if DEBUG
        // -NotebookTips hide|show: the README pictures go without tips; `show` brings them back to look at.
        switch UserDefaults.standard.string(forKey: "NotebookTips") {
        case "hide": Tips.hideAllTipsForTesting()
        case "show": Tips.showAllTipsForTesting()
        default: break
        }
        #endif
        try? Tips.configure()
    }
}
#endif
