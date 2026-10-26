import NotebookKit
import SwiftUI

@main
struct NotebookApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NotebookAppDelegate.self) private var appDelegate
    #endif

    init() {
        NotebookSettings.importFolioSettings()
        QuickCapture.start()
    }

    var body: some Scene {
        NotebookScene()
    }
}
