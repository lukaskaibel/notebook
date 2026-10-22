#if os(macOS)
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Back and Forward by swiping, as in Safari: two fingers on the trackpad (one on a Magic Mouse) slide the note
/// aside and uncover the one you go to. The system's own swipe tracking moves it, so it starts, follows and settles
/// like every other Mac app, and it follows "Swipe between pages" in System Settings. When that is set to three
/// fingers, a swipe goes back or forward in one go.
///
/// The pages you leave are kept as pictures, so the one underneath is there the moment a swipe starts.
@MainActor
final class PageSwiper {
    enum Direction { case back, forward }

    /// Marks out the note's area in the window, from under the toolbar down. The stage goes there during a swipe.
    let anchor = SwipeAnchorView()
    private let stage = SwipeStageView()
    weak var workspace: Workspace?

    private var monitor: Any?
    /// A scroll that may still become a swipe: how far it has gone, and where the note was before it started.
    private var pending: (delta: CGSize, scroll: CGFloat?)?
    /// The swipe going on, and where the note was scrolled when it started.
    private var swipe: (direction: Direction, target: URL, scroll: CGFloat?)?
    private var snapshots: [URL: PageSnapshot] = [:]
    /// Most recent last; only the last few are kept.
    private var snapshotOrder: [URL] = []
    private static let snapshotLimit = 6
    private var quickLookCapture: Task<Void, Never>?

    init() {
        anchor.onWindowChange = { [weak self] in self?.windowChanged() }
        // A PDF or a picture zoomed: picture it again.
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? NSView)?.window === self.anchor.window else { return }
                self.captureQuickLook(after: 0.3)
            }
        }
    }

    private func windowChanged() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard anchor.window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            MainActor.assumeIsolated { self?.takes(event) == true } ? nil : event
        }
    }

    // MARK: - Pages

    /// Called just before another file opens: keeps a picture of the page being left. A file Quick Look shows is
    /// pictured once it has drawn.
    func willOpen(_ url: URL) {
        guard let workspace else { return }
        if workspace.note != nil, let current = workspace.currentURL, let snapshot = captureNote() { keep(snapshot, for: current) }
        if url != Workspace.todosURL, FileKind(url: url, isDirectory: false) != .note { captureQuickLook(after: 0.8) }
    }

    private func keep(_ snapshot: PageSnapshot, for url: URL) {
        snapshots[url] = snapshot
        snapshotOrder.removeAll { $0 == url }
        snapshotOrder.append(url)
        while snapshotOrder.count > Self.snapshotLimit { snapshots[snapshotOrder.removeFirst()] = nil }
    }

    /// The open note as it looks right now, under the toolbar too: its clip view, without the scrollers and the
    /// toolbar's edge effect, which stay where they are during a swipe. The layers already hold what is on screen, so
    /// this composites them instead of drawing the note again.
    private func captureNote() -> PageSnapshot? {
        guard let page = workspace?.editor.scrollView.contentView, let window = page.window, window === anchor.window,
              let layer = page.layer, !page.bounds.isEmpty else { return nil }
        let scale = window.backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(page.bounds.width * scale), height: Int(page.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // The window's layers are drawn top down, the bitmap bottom up.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: page.bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return PageSnapshot(image: image, frame: anchor.convert(page.bounds, from: page), in: anchor)
    }

    /// Quick Look draws in another process, out of reach of `cacheDisplay`, so its page is pictured from the window
    /// itself, as the screen shows it: once it has drawn, and again whenever you stop scrolling it. An app may picture
    /// its own windows without asking for permission.
    private func captureQuickLook(after delay: TimeInterval) {
        quickLookCapture?.cancel()
        quickLookCapture = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, let url = self.quickLookURL, let window = self.anchor.window else { return }
            // The page sits below the toolbar.
            let area = self.anchor.bounds.intersection(self.anchor.convert(window.contentLayoutRect, from: nil))
            let rect = self.anchor.convert(area, to: nil)
            guard area.width > 0, area.height > 0,
                  let content = try? await SCShareableContent.currentProcess,
                  let shown = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
            configuration.width = Int(rect.width * window.backingScaleFactor)
            configuration.height = Int(rect.height * window.backingScaleFactor)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shown), configuration: configuration),
                  !Task.isCancelled, self.quickLookURL == url else { return }
            // A PDF or a picture lies on the grey behind it, which reaches up under the toolbar.
            self.keep(PageSnapshot(image: image, frame: area, in: self.anchor, background: FileKind(url: url, isDirectory: false).pageBackground), for: url)
        }
    }

    /// The file Quick Look is showing, while nothing covers it.
    private var quickLookURL: URL? {
        guard let workspace, workspace.note == nil, swipe == nil, stage.superview == nil else { return nil }
        return workspace.currentURL
    }

    /// A page's picture, unless it was taken in the other appearance (light or dark).
    private func snapshot(of url: URL) -> PageSnapshot? {
        guard let snapshot = snapshots[url], snapshot.appearance == PageSnapshot.appearance(of: anchor) else { return nil }
        return snapshot
    }

    /// The page Back or Forward goes to, skipping files that are gone, as `Workspace.goBack()` does.
    private func target(_ direction: Direction) -> URL? {
        guard let workspace else { return nil }
        var index = workspace.historyIndex
        while true {
            index += direction == .back ? -1 : 1
            guard workspace.history.indices.contains(index) else { return nil }
            let url = workspace.history[index]
            if url == Workspace.todosURL || FileManager.default.fileExists(atPath: url.path) { return url }
        }
    }

    // MARK: - Gestures

    /// True when the event starts a swipe, so nothing else gets it.
    private func takes(_ event: NSEvent) -> Bool {
        guard let window = anchor.window, event.window === window, window.attachedSheet == nil, swipe == nil else { return false }
        if event.type == .swipe { return takesSwipe(event) }
        if workspace?.note == nil, event.phase.isDisjoint(with: [.began, .changed]), event.momentumPhase.isDisjoint(with: [.began, .changed]), isOverPage(event) {
            // Quick Look scrolled: picture it again once it rests.
            captureQuickLook(after: 0.3)
        }
        switch event.phase {
        case .began:
            pending = nil
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, event.hasPreciseScrollingDeltas, isOverPage(event) else { return false }
            pending = (.zero, workspace?.note != nil ? workspace?.editor.scrollView.contentView.bounds.minY : nil)
            return follow(event)
        case .changed:
            return follow(event)
        default:
            pending = nil
            return false
        }
    }

    /// Adds up a scroll until it is clearly sideways (a swipe) or clearly not, as Safari does.
    private func follow(_ event: NSEvent) -> Bool {
        guard var pending else { return false }
        pending.delta.width += event.scrollingDeltaX
        pending.delta.height += event.scrollingDeltaY
        let sideways = abs(pending.delta.width), upright = abs(pending.delta.height)
        if upright > 0 || sideways > 0, upright >= sideways / 2 {
            self.pending = nil
            return false
        }
        guard sideways >= 12 else {
            self.pending = pending
            return false
        }
        self.pending = nil
        let direction: Direction = pending.delta.width > 0 ? .back : .forward
        guard let target = target(direction), !scrollsSideways(direction, at: event), begin(direction, to: target, scroll: pending.scroll) else { return false }
        track(event, direction)
        return true
    }

    private func isOverPage(_ event: NSEvent) -> Bool {
        anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }

    /// True when the swipe should scroll something wide (a wide picture, a zoomed page) instead.
    private func scrollsSideways(_ direction: Direction, at event: NSEvent) -> Bool {
        var view = anchor.window?.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if let scrollView = current as? NSScrollView, let document = scrollView.documentView {
                let visible = scrollView.contentView.bounds
                let width = document.frame.width
                if width > visible.width + 1, direction == .back ? visible.minX > 0.5 : visible.maxX < width - 0.5 { return true }
            }
            view = current.superview
        }
        return false
    }

    private func track(_ event: NSEvent, _ direction: Direction) {
        var cancelled = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: direction == .forward ? -1 : 0, max: direction == .back ? 1 : 0) { [weak self] amount, phase, isComplete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if phase == .cancelled { cancelled = true }
                let progress = min(1, max(0, direction == .back ? amount : -amount))
                self.stage.show(progress)
                if isComplete { self.end(commit: !cancelled && progress > 0.5) }
            }
        }
    }

    /// A three-finger swipe, when that is the setting: no following the fingers, the page slides over by itself.
    private func takesSwipe(_ event: NSEvent) -> Bool {
        guard event.deltaX != 0, isOverPage(event) else { return false }
        // -1 is a swipe to the right, which goes back.
        let direction: Direction = event.deltaX < 0 ? .back : .forward
        guard let target = target(direction) else { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            go(direction)
        } else {
            play(direction, to: target)
        }
        return true
    }

    // MARK: - The swipe

    /// Lays the two pages on the stage and puts it over the note. In a note it goes inside the note's scroll view,
    /// under the toolbar's edge effect, so the toolbar looks the same while the pages slide beneath it.
    @discardableResult
    func begin(_ direction: Direction, to target: URL, scroll: CGFloat? = nil) -> Bool {
        guard let workspace, let current = workspace.currentURL, anchor.window != nil, swipe == nil else { return false }
        let scrollView = workspace.editor.scrollView
        // The first bit of the gesture, before it was clearly sideways, may have scrolled the note.
        restoreScroll(scroll)
        let page = workspace.note != nil ? captureNote() : snapshot(of: current)
        swipe = (direction, target, scroll)
        if workspace.note != nil, scrollView.window === anchor.window {
            scrollView.addSubview(stage, positioned: .above, relativeTo: scrollView.contentView)
        } else {
            anchor.addSubview(stage)
        }
        stage.frame = stage.superview?.bounds ?? anchor.bounds
        stage.begin(direction, page: page, target: snapshot(of: target))
        return true
    }

    /// Goes to the page, once the swipe has settled on it; otherwise the note is simply uncovered again.
    func end(commit: Bool) {
        guard let swipe else { return }
        self.swipe = nil
        // The note stays where it was under the stage, even if the gesture's scrolling reached it.
        restoreScroll(swipe.scroll)
        guard commit else {
            stage.hide()
            return
        }
        if FileKind(url: swipe.target, isDirectory: false) != .note, stage.superview !== anchor {
            // The note's scroll view leaves the window for Quick Look; the stage stays, over it.
            anchor.addSubview(stage)
            stage.frame = anchor.bounds
        }
        go(swipe.direction)
        // The stage shows the new page until the real one has drawn (Quick Look takes a moment), then fades.
        stage.fadeOut(after: workspace?.note != nil ? 0.05 : 0.3)
    }

    /// The page slides over by itself, for a three-finger swipe and the debug remote.
    func play(_ direction: Direction, to target: URL) {
        guard begin(direction, to: target) else { return }
        stage.show(1, animated: true) { [weak self] in self?.end(commit: true) }
    }

    private func restoreScroll(_ scroll: CGFloat?) {
        guard let scroll, let scrollView = workspace?.editor.scrollView, scrollView.contentView.bounds.minY != scroll else { return }
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: scroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func go(_ direction: Direction) {
        switch direction {
        case .back: workspace?.goBack()
        case .forward: workspace?.goForward()
        }
    }

    #if DEBUG
    /// For the debug remote: holds a swipe still part of the way, or ends it.
    func debugShow(_ direction: Direction, _ progress: CGFloat) {
        if swipe == nil, let target = target(direction) { begin(direction, to: target) }
        stage.show(progress)
    }

    func debugPlay(_ direction: Direction) {
        if let target = target(direction) { play(direction, to: target) }
    }
    #endif
}

/// A page as it looked: a picture, where it sat on the stage (from the top, centred like the note's text), what
/// was around it, and whether it was light or dark.
struct PageSnapshot {
    let image: CGImage
    let size: CGSize
    let top: CGFloat
    let centerOffset: CGFloat
    let background: CGColor
    let appearance: NSAppearance.Name?

    init(image: CGImage, frame: NSRect, in view: NSView, background: NSColor = Theme.panel) {
        self.image = image
        size = frame.size
        top = view.bounds.maxY - frame.maxY
        centerOffset = frame.midX - view.bounds.midX
        var color = background.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = background.cgColor }
        self.background = color
        appearance = Self.appearance(of: view)
    }

    static func appearance(of view: NSView) -> NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    /// Where it goes on a stage that may since have changed size.
    func frame(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX + centerOffset - size.width / 2, y: bounds.maxY - top - size.height, width: size.width, height: size.height)
    }
}

/// Where a swipe is drawn, over the note: the page that slides, the page underneath, and a soft shadow at the
/// sliding page's edge. It is only in the window during a swipe, and never takes a click.
final class SwipeStageView: NSView {
    private let lower = CALayer()
    private let lowerContent = CALayer()
    private let dimming = CALayer()
    private let upper = CALayer()
    private let upperContent = CALayer()
    private let edgeShadow = CAGradientLayer()
    private var direction: PageSwiper.Direction = .back
    /// Counts swipes, so a fade from an earlier one doesn't hide a new one.
    private var generation = 0

    /// How dark the page underneath is while it is still mostly covered, and the width of the shadow, as in Safari.
    private static let dimmingOpacity: Float = 0.1
    private static let shadowWidth: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        dimming.backgroundColor = NSColor.black.cgColor
        edgeShadow.startPoint = CGPoint(x: 0, y: 0.5)
        edgeShadow.endPoint = CGPoint(x: 1, y: 0.5)
        edgeShadow.colors = [0, 0.012, 0.035, 0.07].map { NSColor.black.withAlphaComponent($0).cgColor }
        edgeShadow.locations = [0, 0.45, 0.8, 1]
        for page in [lower, upper] { page.masksToBounds = false }
        lower.addSublayer(lowerContent)
        upper.addSublayer(upperContent)
        upper.addSublayer(edgeShadow)
        for sublayer in [lower, dimming, upper] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Lays out the page you are on and the one you go to: going back, yours lies on top and slides off to the right;
    /// going forward, the next one slides in from the right over yours.
    func begin(_ direction: PageSwiper.Direction, page: PageSnapshot?, target: PageSnapshot?) {
        generation += 1
        self.direction = direction
        var background = NSColor.textBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { background = Theme.panel.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAllAnimations()
        layer?.opacity = 1
        for (side, content, snapshot) in [(lower, lowerContent, direction == .back ? target : page), (upper, upperContent, direction == .back ? page : target)] {
            side.removeAllAnimations()
            side.frame = bounds
            side.backgroundColor = snapshot?.background ?? background
            content.contents = snapshot?.image
            content.frame = snapshot?.frame(in: bounds) ?? .zero
        }
        dimming.frame = bounds
        edgeShadow.frame = NSRect(x: -Self.shadowWidth, y: 0, width: Self.shadowWidth, height: bounds.height)
        place(0)
        CATransaction.commit()
    }

    /// How far the swipe has gone, from 0 (where it started) to 1 (on the other page).
    func show(_ progress: CGFloat, animated: Bool = false, completion: (() -> Void)? = nil) {
        let from = (x: upper.position.x, dimming: dimming.opacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        place(progress)
        if animated {
            // The system's spring, without a bounce, as a page settles at the end of a swipe.
            for (moving, keyPath, value) in [(upper, "position.x", from.x as Any), (dimming, "opacity", from.dimming as Any)] {
                let spring = CASpringAnimation(perceptualDuration: 0.35, bounce: 0)
                spring.keyPath = keyPath
                spring.fromValue = value
                spring.toValue = moving.value(forKeyPath: keyPath)
                spring.duration = spring.settlingDuration
                moving.add(spring, forKey: keyPath)
            }
        }
        CATransaction.commit()
    }

    private func place(_ progress: CGFloat) {
        let width = bounds.width
        switch direction {
        case .back:
            upper.frame.origin.x = (width * progress).rounded()
            dimming.opacity = Self.dimmingOpacity * Float(1 - progress)
        case .forward:
            upper.frame.origin.x = (width * (1 - progress)).rounded()
            dimming.opacity = Self.dimmingOpacity * Float(progress)
        }
    }

    /// Fades the stage away once the page it shows is really there underneath.
    func fadeOut(after delay: TimeInterval) {
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation, self.superview != nil, let layer = self.layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.18
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == generation else { return }
                self.hide()
            }
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    func hide() {
        removeFromSuperview()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lowerContent.contents = nil
        upperContent.contents = nil
        layer?.opacity = 1
        CATransaction.commit()
    }
}

/// The note's area, reaching up under the toolbar as the note does. Empty, and it never takes a click.
final class SwipeAnchorView: NSView {
    var onWindowChange: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

/// Puts the swipe's anchor over the note.
struct SwipeAnchor: NSViewRepresentable {
    let swiper: PageSwiper

    func makeNSView(context: Context) -> SwipeAnchorView { swiper.anchor }
    func updateNSView(_ view: SwipeAnchorView, context: Context) {}
}
#endif
