#if os(iOS)
import SwiftUI
import UIKit

/// A row of To-dos swiped to the left shows Delete behind it, as a reminder in Reminders does. Let go past half the
/// button and it stays open; swiped most of the way across, or Delete tapped, the to-do goes. A tap on the row, a
/// swipe back or scrolling closes it again, and one row is open at a time. The list's rows aren't a table's, so the
/// swipe is made here, from a pan that takes only sideways drags and leaves the rest to scrolling and to Back.
struct TodoSwipe: ViewModifier {
    let id: String
    /// The row open, or being swiped.
    @Binding var swiped: String?
    var isEnabled: Bool
    var delete: () -> Void
    @State private var offset: CGFloat = 0
    /// Where the row was as the finger came down: open, or not.
    @State private var start: CGFloat = 0
    @State private var width: CGFloat = 0
    /// Far enough across that letting go deletes.
    @State private var isPastEnd = false
    @State private var isDeleting = false
    /// Deleted: the row closes up, so the rows under it come up as it goes, not over it.
    @State private var isClosingUp = false
    @State private var isClosedUp = false

    /// How far the row goes to show the button, as a list's: a button and the space on either side of it.
    static let buttonWidth: CGFloat = 75
    /// The space on either side of the button, and the button's own size, as a list's.
    static let gap: CGFloat = 8
    static let pill = CGSize(width: 59, height: 42)
    /// How far the row's card reaches out beside it.
    static let cardOutset: CGFloat = 8
    /// How much of the row a swipe has to cross for letting go to delete.
    static let fullSwipe: CGFloat = 0.55
    static let animation = Animation.spring(response: 0.32, dampingFraction: 0.88)

    func body(content: Content) -> some View {
        let revealed = max(0, -offset)
        content
            .offset(x: offset)
            // Swiped, the row is a card that gets narrower, its words going under its edge, as a list's row does.
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .padding(.horizontal, -Self.cardOutset)
                    .padding(.trailing, revealed)
                    // Gone as the row goes all the way across.
                    .opacity(min(1, revealed / 24, max(0, width - revealed) / 32))
            }
            .clipShape(SwipeClip(revealed: revealed, outset: Self.cardOutset))
            // Open, a tap on what shows of the row closes it and does nothing else; the button beside it is the
            // button's.
            .overlay(alignment: .leading) {
                if offset != 0, !isDeleting {
                    Color.clear
                        .contentShape(.rect)
                        .frame(width: max(0, width - revealed))
                        .onTapGesture { close() }
                }
            }
            .overlay(alignment: .trailing) { button(revealed) }
            .frame(height: isClosedUp ? 0 : nil, alignment: .top)
            .clipShape(Rectangle().inset(by: isClosingUp ? 0 : -1000))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(TodoSwipeGesture(isEnabled: isEnabled && !isDeleting, isOpen: offset < 0) { moved($0) })
            .onChange(of: swiped) { _, row in
                if row != id, offset != 0, !isDeleting { close() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, offset != 0, !isDeleting { close() }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: isPastEnd) { _, past in past }
    }

    /// A red pill with a bin and its name under it, as a list's: it grows out of the space the row leaves, and wider
    /// as the row goes further.
    private func button(_ revealed: CGFloat) -> some View {
        let width = max(0, revealed - 2 * Self.gap)
        let shown = min(1, width / Self.pill.width)
        return Button(action: deleteNow) {
            VStack(spacing: 5) {
                Capsule()
                    .fill(Color.red)
                    .overlay {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                            .opacity(shown)
                    }
                    .frame(width: width, height: Self.pill.height * max(0.5, shown))
                Text("Delete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .opacity(shown * shown)
            }
            .frame(width: revealed)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(revealed > 0 ? 1 : 0)
        .allowsHitTesting(revealed > 0 && !isDeleting)
        .accessibilityLabel("Delete")
        .accessibilityHidden(revealed == 0)
    }

    private func moved(_ phase: TodoSwipeGesture.Phase) {
        switch phase {
        case .began:
            start = offset
            swiped = id
        case .moved(let x):
            offset = max(-width, min(0, start + x))
            let past = -offset > width * Self.fullSwipe
            if past != isPastEnd { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isPastEnd = past } }
        case .ended(let x, let velocity):
            if isPastEnd { return deleteNow() }
            let end = start + x
            // A flick opens or closes it, whatever how far it went.
            if velocity < -300 || (velocity < 300 && -end > Self.buttonWidth / 2) { open() } else { close() }
        case .cancelled:
            if offset < -Self.buttonWidth / 2, !isPastEnd { open() } else { close() }
        }
    }

    private func open() {
        withAnimation(Self.animation) {
            offset = -Self.buttonWidth
            isPastEnd = false
        }
        swiped = id
    }

    private func close() {
        withAnimation(Self.animation) {
            offset = 0
            isPastEnd = false
        }
        if swiped == id { swiped = nil }
    }

    /// The row goes across, the button filling its place, and closes up; then the to-do goes.
    private func deleteNow() {
        isDeleting = true
        withAnimation(.easeOut(duration: 0.2)) {
            offset = -width
            isPastEnd = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isClosingUp = true
            withAnimation(.easeInOut(duration: 0.25)) { isClosedUp = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            delete()
            // Not deleted after all (its note changed): it comes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard isDeleting else { return }
                withAnimation(Self.animation) { isClosedUp = false }
                isClosingUp = false
                isDeleting = false
                close()
            }
        }
    }
}

/// What shows of a row swiped: up to its card's edges, which come in from the right as the row goes; above and below
/// it, and as far as its card reaches out on the left, nothing is cut off, such as its circle as it pops.
private struct SwipeClip: Shape {
    var revealed: CGFloat
    var outset: CGFloat

    var animatableData: CGFloat {
        get { revealed }
        set { revealed = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - outset, y: rect.minY - 40, width: rect.width + 2 * outset - revealed, height: rect.height + 80))
    }
}

/// A sideways drag on a row: it fails as soon as the finger goes more up or down than across, so the list scrolls,
/// and when it goes to the right on a row that isn't open, so Back takes it.
struct TodoSwipeGesture: UIGestureRecognizerRepresentable {
    enum Phase {
        case began
        case moved(CGFloat)
        case ended(CGFloat, velocity: CGFloat)
        case cancelled
    }

    var isEnabled: Bool
    var isOpen: Bool
    var action: (Phase) -> Void

    func makeUIGestureRecognizer(context: Context) -> SidewaysPan {
        SidewaysPan()
    }

    func updateUIGestureRecognizer(_ recognizer: SidewaysPan, context: Context) {
        recognizer.isEnabled = isEnabled
        recognizer.allowsRight = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: SidewaysPan, context: Context) {
        let x = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began:
            action(.began)
            action(.moved(x))
        case .changed:
            action(.moved(x))
        case .ended:
            action(.ended(x, velocity: recognizer.velocity(in: nil).x))
        case .cancelled, .failed:
            action(.cancelled)
        default:
            break
        }
    }

    final class SidewaysPan: UIPanGestureRecognizer {
        /// A drag to the right is the row's only when it is open, to close it.
        var allowsRight = false
        private var origin: CGPoint?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            if origin == nil { origin = touches.first?.location(in: nil) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible, let origin, let point = touches.first?.location(in: nil) {
                let dx = point.x - origin.x, dy = point.y - origin.y
                if hypot(dx, dy) > 4, abs(dy) > abs(dx) || (dx > 0 && !allowsRight) {
                    state = .failed
                    return
                }
            }
            super.touchesMoved(touches, with: event)
        }

        override func reset() {
            super.reset()
            origin = nil
        }
    }
}
#endif
