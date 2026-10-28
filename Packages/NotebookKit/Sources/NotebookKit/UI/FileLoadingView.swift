import SwiftUI

/// A file Notebook draws itself rather than through Quick Look, which shows a dashed box while it loads. The file is
/// read in the background; until then there is only the background, and a spinner if that takes long enough to notice
/// (`WaitingIndicator`). Then it shows, fading in if there was a wait to see. A file that can't be read this way
/// goes to Quick Look after all.
///
/// `content` is there from the start, without what was read, so a scroll view in it is already in the window (and
/// knows the toolbar's height) when the file arrives.
///
/// When the file changes (marked up in another app, or on another device) it is read again and shown in place of
/// what was there, as Preview does, unless `rereads` is off.
struct FileLoadingView<Loaded, Content: View>: View {
    let url: URL
    let background: NSColor
    var rereads = true
    let read: @Sendable (URL) async -> Loaded?
    @ViewBuilder let content: (Loaded?) -> Content

    @State private var loaded: Loaded?
    /// Whether the file is still in iCloud, known once reading it started.
    @State private var inCloud: Bool?
    @State private var failed = false
    /// Counts the changes to the file, each of which reads it again.
    @State private var changes = 0
    /// When the file shown was last changed, to see on coming back to the app whether it was changed meanwhile.
    @State private var modified: Date?
    @State private var presenter: ChangePresenter?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if failed {
            QuickLookView(url: url)
        } else {
            ZStack {
                content(loaded)
                    .opacity(loaded == nil ? 0 : 1)
                if loaded == nil, let inCloud {
                    WaitingIndicator(inCloud: inCloud)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Up under the toolbar, but not under the sidebar's and the inspector's glass, which would take on its tint.
            .background(Color.theme(background).ignoresSafeArea(.container, edges: .top))
            .animation(.easeOut(duration: 0.2), value: loaded == nil)
            .task(id: changes) { await load() }
            .onAppear {
                guard rereads, presenter == nil else { return }
                presenter = ChangePresenter(url: url) { changes += 1 }
            }
            .onDisappear {
                presenter?.stop()
                presenter = nil
            }
            .onChange(of: scenePhase) { _, phase in
                // Changed while Notebook was away, which a presenter isn't always told of.
                if rereads, phase == .active, loaded != nil, modified != Self.modificationDate(url) { changes += 1 }
            }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func load() async {
        let start = ContinuousClock.now
        let rereading = loaded != nil
        if rereading {
            // Changes come in bursts as a file is written; the last one is read.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        } else {
            inCloud = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded
        }
        modified = Self.modificationDate(url)
        let url = url, read = read
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            #if DEBUG
            if let delay = FileLoading.debugDelay { try? await Task.sleep(for: .seconds(delay)) }
            #endif
            return await read(url)
        }.value
        guard !Task.isCancelled else { return }
        if let result {
            // Read before the wait could be seen, it is simply there, as in Preview; only after one it fades in. Read
            // again, it takes the place of what was there.
            var transaction = Transaction()
            transaction.disablesAnimations = rereading || ContinuousClock.now - start < FileLoading.noticeableWait
            withTransaction(transaction) { loaded = result }
        } else if !rereading {
            failed = true
        }
    }
}

/// Tells of changes to one file, written by other apps and devices or by Notebook itself.
private final class ChangePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let changed: @MainActor () -> Void

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        presentedItemURL = url
        self.changed = changed
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedItemDidChange() {
        MainActor.assumeIsolated { changed() }
    }
}

/// A spinner for a wait long enough to notice. As everywhere on the Mac, nothing spins for a moment: it shows after
/// 0.6 s, or after 0.2 s as "Downloading from iCloud…" for a file still in iCloud.
struct WaitingIndicator: View {
    let inCloud: Bool
    @State private var isShown = false

    var body: some View {
        ZStack {
            if isShown {
                Group {
                    if inCloud {
                        ProgressView("Downloading from iCloud…")
                    } else {
                        ProgressView()
                    }
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: isShown)
        .task {
            try? await Task.sleep(for: .seconds(inCloud ? 0.2 : 0.6))
            if !Task.isCancelled { isShown = true }
        }
    }
}

/// Over a note whose text is still on its way, under its title: the wait, or that it couldn't be read. Nothing once
/// the text is in.
struct NoteWaitingView: View {
    let note: NoteDocument?

    var body: some View {
        ZStack {
            switch note?.pending {
            case .reading?:
                WaitingIndicator(inCloud: false).transition(.opacity)
            case .downloading?:
                WaitingIndicator(inCloud: true).transition(.opacity)
            case .unreadable?:
                Text("This note can’t be opened right now.")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: note?.pending)
        .allowsHitTesting(false)
    }
}

enum FileLoading {
    /// A file read within this long shows at once; one that took longer fades in.
    static let noticeableWait = Duration.milliseconds(150)

    /// Reads a file in a coordinated read, which waits for iCloud to bring it down, and for anyone still writing it.
    static func read<Result>(_ url: URL, _ body: (URL) -> Result?) -> Result? {
        var result: Result?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
            result = body(url)
        }
        return result
    }

    #if DEBUG
    /// Makes reading every note, PDF, picture and video take this long, to see the wait: `-NotebookSlowFiles <s>`
    /// at launch, or `loaddelay <s>` from the debug remote.
    nonisolated(unsafe) static var debugDelay: TimeInterval? = {
        let delay = UserDefaults.standard.double(forKey: "NotebookSlowFiles")
        return delay > 0 ? delay : nil
    }()
    #endif
}

extension FileKind {
    /// What lies around the file in the window: the grey Preview puts behind pages and pictures, or black behind a
    /// video, as in QuickTime Player.
    var pageBackground: NSColor {
        switch self {
        #if os(macOS)
        case .pdf, .image: .underPageBackgroundColor
        #else
        case .pdf, .image: .secondarySystemBackground
        #endif
        case .video: .black
        default: Theme.panel
        }
    }
}
