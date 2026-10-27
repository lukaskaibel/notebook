#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AppIntents
import NotebookCapture

/// Notes asked for from outside the window: the New Note intent, from Shortcuts, Spotlight, the Action button, the
/// widgets and Control Center, and what is shared to Notebook from other apps. The intent and what the share extension
/// leaves are in NotebookCapture, which the extensions have too; the notes are made here.
@MainActor
public enum QuickCapture {
    /// Called as the app starts, before the system hands it an intent that started it.
    public static func start() {
        NewNoteIntent.makeNote = { text in
            let workspace = Workspace.shared
            guard await workspace.newNoteFromOutside(text: text) != nil else {
                throw workspace.locations.isEmpty ? NewNoteIntentError.noLocation : .notMade
            }
        }
        takeFromExtensions()
    }

    /// What was shared, and the to-dos ticked in a widget, are written as the app starts, when it comes to the front,
    /// and at once when an extension says something is waiting, while the app runs. When it goes away, the share
    /// extension gets the places it offers and the widgets what they show.
    private static func takeFromExtensions() {
        #if DEBUG
        // A folder to take shared notes from in a build without the App Group, as the Mac's Debug build is.
        if let path = UserDefaults.standard.string(forKey: "NotebookSharedNotes") {
            SharedNotes.folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        guard SharedNotes.folder != nil || WidgetData.folder != nil else { return }
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification, resigning = NSApplication.willResignActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification, resigning = UIApplication.willResignActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { writeShared() }
        }
        NotificationCenter.default.addObserver(forName: resigning, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Workspace.shared.publishSharePlaces()
                Workspace.shared.publishWidgetNotes()
            }
        }
        for name in [SharedNotes.notification, WidgetData.notification] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickCapture.writeShared() } }
            }, name, nil, .deliverImmediately)
        }
        // Once the app is up: started in the background, as on the Mac at login, it doesn't become active.
        DispatchQueue.main.async { MainActor.assumeIsolated { writeShared() } }
    }

    private static var writing: Task<Void, Never>?
    private static var writesAgain = false

    /// One writing at a time; one asked for meanwhile follows it, for what came in since.
    private static func writeShared() {
        guard writing == nil else { return writesAgain = true }
        writing = Task {
            repeat {
                writesAgain = false
                await Workspace.shared.takeSharedNotes()
                await Workspace.shared.takeWidgetTicks()
            } while writesAgain
            // A note chosen in a widget since the app last ran shows there now, and the to-dos are as they are today.
            Workspace.shared.publishWidgetNotes(catalog: false)
            Workspace.shared.publishWidgetTodos()
            writing = nil
        }
    }

    /// A URL the app is opened with from a widget: a New Note widget's where the intent didn't run, To-dos, a to-do or
    /// a note. False for any other.
    public static func open(_ url: URL) -> Bool {
        guard url == NewNoteIntent.widgetURL else { return Workspace.shared.openFromWidget(url) }
        Task { await Workspace.shared.newNoteFromOutside() }
        return true
    }
}

/// NotebookKit's intents, for the app to take into its App Shortcuts (`NotebookShortcuts` in the app target).
public struct NotebookKitIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [NotebookCaptureIntents.self] }
}
