#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// What Copy File shows: a capsule of glass saying what was copied, for as long as it takes to read, at the bottom of
/// the window you are working in, on iPhone and iPad above the bar at the bottom. VoiceOver says it too.
struct CopiedCapsuleView: View {
    let name: String

    var body: some View {
        Label("Copied “\(name)”", systemImage: "doc.on.doc")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 420)
            .accessibilityHidden(true)
    }

    /// How long it stays.
    static let shownFor = Duration.seconds(1.6)

    static func announce(_ name: String) {
        let text = "Copied “\(name)”"
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

/// The capsule over a SwiftUI window, the main window on the Mac, the scene on iPhone and iPad.
extension View {
    func copiedCapsule(_ workspace: Workspace) -> some View {
        modifier(CopiedCapsuleOverlay(workspace: workspace))
    }
}

private struct CopiedCapsuleOverlay: ViewModifier {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    private let bottom: CGFloat = 28
    #else
    /// Clear of the bar of buttons at the bottom of a note.
    private let bottom: CGFloat = 76
    #endif

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let copied = workspace.copied.file {
                    CopiedCapsuleView(name: copied.name)
                        .padding(.bottom, bottom)
                        .padding(.horizontal, 20)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.94)))
                        .id(copied.id)
                        .allowsHitTesting(false)
                        .task {
                            CopiedCapsuleView.announce(copied.name)
                            #if os(macOS) && DEBUG
                            CopiedCapsule.lastName = copied.name
                            #endif
                            try? await Task.sleep(for: CopiedCapsuleView.shownFor)
                            if workspace.copied.file?.id == copied.id { workspace.copied.file = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.2), value: workspace.copied.file)
    }
}

#if os(macOS)
/// The capsule over a note's own window, which is AppKit's: over the window's content, in a view of its own that
/// clicks go through.
@MainActor
enum CopiedCapsule {
    private static weak var shown: NSView?
    #if DEBUG
    /// What the last capsule said, for the debug remote and tests.
    static var lastName: String?
    #endif

    static func show(_ name: String, in window: NSWindow) {
        CopiedCapsuleView.announce(name)
        #if DEBUG
        lastName = name
        #endif
        guard let content = window.contentView else { return }
        shown?.removeFromSuperview()
        let model = Model()
        let host = PassThroughHostingView(rootView: Overlay(name: name, model: model))
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .above, relativeTo: nil)
        shown = host
        Task { @MainActor [weak host] in
            // In once it is in the window, out after a moment, then gone.
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { model.isShown = true }
            try? await Task.sleep(for: CopiedCapsuleView.shownFor)
            withAnimation(.easeOut(duration: 0.25)) { model.isShown = false }
            try? await Task.sleep(for: .milliseconds(300))
            host?.removeFromSuperview()
        }
    }

    @Observable
    final class Model {
        var isShown = false
    }

    private struct Overlay: View {
        let name: String
        let model: Model
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack {
                Spacer()
                CopiedCapsuleView(name: name)
                    .opacity(model.isShown ? 1 : 0)
                    .offset(y: model.isShown || reduceMotion ? 0 : 12)
                    .scaleEffect(model.isShown || reduceMotion ? 1 : 0.94)
            }
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
