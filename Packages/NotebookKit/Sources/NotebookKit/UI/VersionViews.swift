#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// MARK: - The version picked

/// The version picked, in the note's look, in an editor of its own that can't be changed: its text can still be
/// selected and copied. Links in it find what they find in the note.
@MainActor
final class VersionReader: EditorControllerDelegate {
    let editor = EditorController()
    weak var source: EditorController?
    /// What is shown, so the same isn't laid out again, and the changes it shows, to find places in it.
    private var shown: (text: String, marks: [VersionChanges.Mark], meta: String)?
    private var shownChanges: VersionChanges?

    init(source: EditorController) {
        self.source = source
        editor.delegate = self
        editor.isReadOnly = true
        editor.layoutManager.hidesEditingControls = true
    }

    /// Shows a version as it was, or with `changes`. Show Changes turned on or off keeps the place you were at.
    func show(_ version: String, changes: VersionChanges?, title: String, meta: String, folder: URL) {
        let text = changes?.text ?? version
        let marks = changes?.marks ?? []
        if let shown, shown.text == text, shown.marks == marks, shown.meta == meta { return }
        if let shown, shown.meta == meta, shown.text != text {
            let before = shownChanges
            editor.load(text: text, folder: folder, title: title, meta: meta) { index in
                let inVersion = before?.offset(inVersion: index) ?? index
                return changes?.offset(inChanges: inVersion) ?? inVersion
            }
        } else if shown?.text != text || shown?.meta != meta {
            editor.load(text: text, folder: folder, title: title, meta: meta)
        }
        editor.showChanges(marks)
        shown = (text, marks, meta)
        shownChanges = changes
    }

    func editorTextDidChange(_ editor: EditorController) {}
    func editor(_ editor: EditorController, open target: LinkTarget.Kind) {}
    func editor(_ editor: EditorController, quickLook url: URL) {}
    func editor(_ editor: EditorController, commitTitle title: String) {}
    func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] { [] }
    func editor(_ editor: EditorController, resolve target: String) -> URL? {
        guard let source else { return nil }
        return source.delegate?.editor(source, resolve: target)
    }
    func editorNoteName(_ editor: EditorController) -> String { "" }
    func editor(_ editor: EditorController, mayWriteIn folder: URL) -> Bool { false }
}

#if os(macOS)
private struct VersionEditorHost: NSViewRepresentable {
    let editor: EditorController
    func makeNSView(context: Context) -> NSView { editor.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
private struct VersionEditorHost: UIViewRepresentable {
    let editor: EditorController
    func makeUIView(context: Context) -> UIView { editor.view }
    func updateUIView(_ view: UIView, context: Context) {}
}
#endif

/// The version picked, as it was or with the changes since then (`VersionBrowser.showsChanges`), and the wait while
/// it is read: "Downloading from iCloud…" for one iCloud hasn't brought down yet.
struct VersionPreview: View {
    let browser: VersionBrowser
    let reader: VersionReader

    var body: some View {
        ZStack {
            VersionEditorHost(editor: reader.editor)
                .opacity(browser.text == nil ? 0 : 1)
            if let version = browser.selected {
                if browser.isUnreadable {
                    ContentUnavailableView("This Version Can’t Be Read", systemImage: "exclamationmark.triangle",
                                           description: Text("It may not have come from iCloud yet. Try again later."))
                } else if browser.text == nil {
                    WaitingIndicator(inCloud: !version.isDownloaded)
                        .id(version.url)
                }
            } else if browser.versions != nil {
                ContentUnavailableView("No Earlier Versions", systemImage: "clock.arrow.circlepath",
                                       description: Text("Notebook keeps a version when you start changing a note, every ten minutes while you write, and when you stop."))
            }
        }
        .background(Color.theme(Theme.panel))
        .onAppear(perform: update)
        .onChange(of: browser.text) { _, _ in update() }
        .onChange(of: browser.changes) { _, _ in update() }
    }

    private func update() {
        guard let text = browser.text, let version = browser.selected else { return }
        reader.show(text, changes: browser.changes, title: browser.title, meta: VersionBrowser.longTitle(version),
                    folder: browser.note.deletingLastPathComponent())
    }
}

/// What Show Changes found, in a few words: "3 lines added, 1 taken out", or where there is little room "+3 −1".
struct VersionChangeSummary: View {
    let changes: VersionChanges?
    var isShort = false

    var body: some View {
        if let changes {
            Group {
                if isShort, !changes.isEmpty {
                    Text("+\(changes.addedLines)").foregroundStyle(.green) + Text("  −\(changes.removedLines)").foregroundStyle(.red)
                } else {
                    Text(summary(changes)).foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .lineLimit(1)
            .accessibilityLabel(summary(changes))
        }
    }

    private func summary(_ changes: VersionChanges) -> String {
        if changes.isEmpty { return "The same as now" }
        var parts: [String] = []
        if changes.addedLines > 0 { parts.append(changes.addedLines == 1 ? "1 line added" : "\(changes.addedLines) lines added") }
        if changes.removedLines > 0 { parts.append("\(changes.removedLines) taken out") }
        return parts.joined(separator: ", ") + " since"
    }
}

/// One version in the list: when, and on what.
struct VersionRow: View {
    let version: NoteHistory.Version

    var body: some View {
        Label {
            Text(version.date.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
            + Text(" · " + version.device).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: Self.symbol(for: version.device))
        }
    }

    static func symbol(for device: String) -> String {
        switch device {
        case "iPhone": "iphone"
        case "iPad": "ipad"
        default: "laptopcomputer"
        }
    }
}

#if os(macOS)
// MARK: - The Mac

/// Browse All Versions…: a sheet with the versions on the left, grouped by day, and the one picked on the right. The
/// closest thing to Apple's own version browser, which only NSDocument apps have.
struct VersionsSheet: View {
    @Bindable var browser: VersionBrowser
    let reader: VersionReader
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $browser.selection) {
                    ForEach(browser.days) { day in
                        Section(day.title) {
                            ForEach(day.versions) { version in
                                VersionRow(version: version).tag(version.url)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 230)
                Divider()
                VersionPreview(browser: browser, reader: reader)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Show Changes", isOn: $browser.showsChanges)
                    .toggleStyle(.checkbox)
                    .disabled(browser.text == nil)
                VersionChangeSummary(changes: browser.changes)
                Spacer()
                Button("Copy Text") { browser.copyText() }
                    .disabled(browser.text == nil)
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Restore") {
                    browser.restore()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(browser.text == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 480, idealHeight: 660)
        .task { await browser.load() }
    }
}

/// Puts the versions sheet over a window: the main window's, or a note's own.
@MainActor
enum VersionsWindow {
    private static var open: [ObjectIdentifier: (sheet: NSWindow, reader: VersionReader)] = [:]

    /// The sheet, held weakly by what its Done and Restore close: held by the view, it would hold the sheet, its
    /// editor, the browser and the note for good.
    private final class Sheet {
        weak var window: NSWindow?
    }

    static func show(_ browser: VersionBrowser, editor: EditorController, over window: NSWindow) {
        guard window.attachedSheet == nil else { return NSSound.beep() }
        let reader = VersionReader(source: editor)
        let sheet = Sheet()
        let view = VersionsSheet(browser: browser, reader: reader) { [weak window] in
            guard let made = sheet.window else { return }
            window?.endSheet(made)
        }
        let controller = NSHostingController(rootView: view)
        let made = NSWindow(contentViewController: controller)
        made.isReleasedWhenClosed = false
        sheet.window = made
        let size = NSSize(width: min(940, window.frame.width - 60), height: min(660, window.frame.height - 80))
        made.setContentSize(NSSize(width: max(size.width, 760), height: max(size.height, 480)))
        let key = ObjectIdentifier(made)
        open[key] = (made, reader)
        window.beginSheet(made) { _ in open[key] = nil }
    }

    /// The sheet over a window, for the debug remote.
    static func browser(over window: NSWindow?) -> VersionBrowser? {
        guard let sheet = window?.attachedSheet, let host = sheet.contentViewController as? NSHostingController<VersionsSheet> else { return nil }
        return host.rootView.browser
    }

    static func close(over window: NSWindow?) {
        guard let window, let sheet = window.attachedSheet, sheet.contentViewController is NSHostingController<VersionsSheet> else { return }
        window.endSheet(sheet)
    }
}
#else
// MARK: - iPhone and iPad

/// Version History, from the note's ⋯ menu. On the iPhone a list grouped by day, where a tap opens a version with
/// Restore and Copy in the bottom bar; on the iPad (and wherever there is room) the same split view as on the Mac.
struct VersionHistorySheet: View {
    @Bindable var browser: VersionBrowser
    @State private var reader: VersionReader
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    init(browser: VersionBrowser, source: EditorController) {
        self.browser = browser
        _reader = State(initialValue: VersionReader(source: source))
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    list(selecting: true)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                        // The versions always show next to the one picked.
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $browser.path) {
                    list(selecting: false)
                        .navigationDestination(for: URL.self) { _ in detail }
                }
            }
        }
        .task { await browser.load() }
    }

    private func list(selecting: Bool) -> some View {
        List(selection: selecting ? $browser.selection : .constant(nil)) {
            ForEach(browser.days) { day in
                Section(day.title) {
                    ForEach(day.versions) { version in
                        if selecting {
                            VersionRow(version: version).tag(version.url)
                        } else {
                            NavigationLink(value: version.url) { VersionRow(version: version) }
                        }
                    }
                }
            }
        }
        .overlay {
            if browser.versions?.isEmpty == true {
                ContentUnavailableView("No Earlier Versions", systemImage: "clock.arrow.circlepath",
                                       description: Text("Notebook keeps a version when you start changing a note, every ten minutes while you write, and when you stop."))
            }
        }
        .navigationTitle("Version History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var detail: some View {
        VersionPreview(browser: browser, reader: reader)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(browser.selected.map { VersionBrowser.dayTitle($0.date) + ", " + $0.date.formatted(date: .omitted, time: .shortened) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $browser.showsChanges) { Label("Show Changes", systemImage: "plusminus") }
                        .disabled(browser.text == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { browser.copyText() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(browser.text == nil)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    VersionChangeSummary(changes: browser.changes, isShort: sizeClass != .regular)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Restore") {
                        browser.restore()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.text == nil)
                }
            }
    }
}
#endif
