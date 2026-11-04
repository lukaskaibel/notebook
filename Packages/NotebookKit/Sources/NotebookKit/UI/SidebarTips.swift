#if os(macOS)
import AppKit
import SwiftUI
import TipKit

/// The tips at the bottom of the sidebar, one at a time: the app's icon, then Quick Look.
struct SidebarTips: View {
    @Environment(\.openSettings) private var openSettings
    @State private var tips = TipGroup(.ordered) {
        AppIconTip()
        QuickLookTip()
    }

    var body: some View {
        Group {
            if let tip = tips.currentTip as? AppIconTip {
                shown(TipView(tip, arrowEdge: nil) { _ in
                    UserDefaults.standard.set("icon", forKey: "settingsTab")
                    openSettings()
                })
            } else if let tip = tips.currentTip as? QuickLookTip {
                shown(TipView(tip, arrowEdge: nil) { _ in
                    QuickLookTip.openSettings()
                    tip.invalidate(reason: .actionPerformed)
                })
            }
        }
        .onAppear(perform: QuickLookTip.update)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in QuickLookTip.update() }
    }

    private func shown(_ tip: some View) -> some View {
        tip
            // Measured narrower than the sidebar ever gets, its text would wrap word by word and make the window tall.
            .frame(minWidth: 180)
            .padding(10)
    }
}

/// The tip that notes show in Quick Look as Notebook shows them, with the way to Quick Look's settings, where another
/// app that previews Markdown can be turned off: the Mac uses one app's preview for Markdown files and doesn't say
/// which. It goes once you close it or open the settings, and once Quick Look has shown a note with Notebook's.
struct QuickLookTip: Tip {
    var title: Text { Text("See notes in Quick Look") }
    var message: Text? { Text("Press Space on a note in the Finder to see it as here. If another app’s preview comes up, turn it off in Quick Look Settings.") }
    var image: Image? { Image(systemName: "eye") }
    var actions: [Action] { [Action(id: "settings", title: "Quick Look Settings")] }

    /// Quick Look has shown a note with Notebook's preview (NotePreview), as far as the App Group tells.
    @Parameter static var hasShownNote: Bool = false

    var rules: [Rule] {
        #Rule(Self.$hasShownNote) { $0 == false }
    }

    @MainActor static func update() {
        if NotePreview.hasShownNote, !hasShownNote { hasShownNote = true }
    }

    /// System Settings › General › Login Items & Extensions › Quick Look, the switch of each app's previews.
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview")!)
    }
}
#endif
