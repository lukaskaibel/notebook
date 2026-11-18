#if os(iOS)
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A place Apple Pencil was at, in the text view's points.
struct PencilSample {
    var location: CGPoint
    var time: TimeInterval
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat
}

/// A stroke written outside a canvas, on its way into a drawing, and its ink on the note until then.
@MainActor
struct WaitingPencilStroke {
    var samples: [PencilSample]
    var ink: CAShapeLayer
}

/// One stroke of Apple Pencil: it begins once the tip has moved, so that a tap with it stays a tap.
final class PencilStrokeRecognizer: UIGestureRecognizer {
    private static let slop: CGFloat = 3
    private(set) var samples: [PencilSample] = []
    private var pencil: UITouch?

    private func add(_ touch: UITouch, _ event: UIEvent) {
        guard let view else { return }
        for touch in event.coalescedTouches(for: touch) ?? [touch] {
            let isPencil = touch.type == .pencil
            samples.append(PencilSample(location: touch.preciseLocation(in: view), time: touch.timestamp,
                                        force: touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0,
                                        azimuth: isPencil ? touch.azimuthAngle(in: view) : 0,
                                        altitude: isPencil ? touch.altitudeAngle : .pi / 2))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard pencil == nil, touches.count == 1, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        pencil = touch
        add(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil, touches.contains(pencil), let start = samples.first else { return }
        add(pencil, event)
        if state == .possible {
            let now = pencil.location(in: view)
            if hypot(now.x - start.location.x, now.y - start.location.y) >= Self.slop { state = .began }
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil, touches.contains(pencil) else { return }
        add(pencil, event)
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        samples = []
        pencil = nil
    }
}

/// Apple Pencil in a note: a stroke on the text starts a drawing right there, with no button to press first. The stroke
/// that started it is shown as it is written; PencilKit's canvas, which can't take a touch already under way, is there
/// for the next one. The stroke goes into the drawing once you pause, because giving a canvas a drawing makes it miss
/// the stroke that follows. A tap with Apple Pencil stays a tap.
@MainActor
final class PencilWriting: NSObject, UIGestureRecognizerDelegate {
    private weak var editor: EditorController?
    private let recognizer = PencilStrokeRecognizer()
    private var ink: CAShapeLayer?
    private var picture: URL?

    init(editor: EditorController) {
        self.editor = editor
        super.init()
        var types: [NSNumber] = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        #if DEBUG
        // A simulator has no Apple Pencil: the UI tests write with a finger.
        if UserDefaults.standard.bool(forKey: "NotebookFingerIsPencil") { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        #endif
        recognizer.allowedTouchTypes = types
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(strokeChanged))
        editor.textView.addGestureRecognizer(recognizer)
    }

    /// Not on the title, the buttons by it or the drawings, which take Apple Pencil themselves.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let editor, editor.textView.isEditable, !(touch.view is UIControl) else { return false }
        let point = touch.location(in: editor.textView)
        return point.y >= editor.textOrigin.y && editor.canvas(at: point) == nil
    }

    @objc private func strokeChanged() {
        guard let editor else { return }
        switch recognizer.state {
        case .began:
            guard let start = recognizer.samples.first, let picture = editor.drawing(forPencilAt: start.location) else {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                return
            }
            self.picture = picture
            showInk(in: editor)
        case .changed:
            updateInk()
        case .ended:
            updateInk()
            if let picture, let ink { editor.keepPencilStroke(WaitingPencilStroke(samples: recognizer.samples, ink: ink), for: picture) }
            picture = nil
            ink = nil
        default:
            picture = nil
            ink?.removeFromSuperlayer()
            ink = nil
        }
    }

    private func showInk(in editor: EditorController) {
        let tool = editor.pencilTool
        let ink = CAShapeLayer()
        ink.fillColor = nil
        ink.lineCap = .round
        ink.lineJoin = .round
        ink.zPosition = 10
        ink.strokeColor = tool?.color.resolvedColor(with: editor.textView.traitCollection).cgColor ?? Theme.text.cgColor
        ink.lineWidth = max(1.5, (tool?.width ?? 3) * 0.75)
        // In the text view's points, which is what its layer's sublayers scroll with.
        ink.frame = CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
        self.ink = ink
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        editor.textView.layer.addSublayer(ink)
        updateInk()
        CATransaction.commit()
    }

    private func updateInk() {
        let path = CGMutablePath()
        path.addLines(between: recognizer.samples.map(\.location))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink?.path = path
        CATransaction.commit()
    }
}

extension EditorController: UIScribbleInteractionDelegate {
    /// Apple Pencil draws in the note, so Scribble has no place in its text. It writes in the title, except while
    /// drawing, when a stroke near the title is meant for the drawing.
    public func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        interaction.view !== textView && !isDrawing
    }

    /// The inking tool Apple Pencil writes with: the one picked, or the first there is when the eraser or the lasso is.
    fileprivate var pencilTool: PKInkingTool? {
        guard let picker = drawingSession?.toolPicker else { return nil }
        if !(picker.selectedToolItem is PKToolPickerInkingItem), let item = picker.toolItems.first(where: { $0 is PKToolPickerInkingItem }) {
            picker.selectedToolItem = item
        }
        return (picker.selectedToolItem as? PKToolPickerInkingItem)?.inkingTool
    }

    /// The drawing a stroke of Apple Pencil starting at `point` goes into, drawing mode on: the one under it, or a new
    /// one at its line. Nil when there can't be one.
    fileprivate func drawing(forPencilAt point: CGPoint) -> URL? {
        let existing = drawingObjects().first { layoutManager.blockObjectRect(at: $0.index, origin: textOrigin)?.contains(point) == true }?.picture
        if !isDrawing {
            if let existing { beginDrawing(in: existing) } else { beginDrawing(atCharacter: drawingPlace(at: point)) }
            return drawingSession?.focused
        }
        guard let session = drawingSession else { return nil }
        if let existing {
            session.focused = existing
            return existing
        }
        let top = scrollTop
        guard let (picture, insertion) = insertDrawing(at: drawingPlace(at: point), writing: false) else { return nil }
        session.created[picture] = insertion
        session.focused = picture
        updateDrawingCanvases()
        focusCanvas(picture)
        if abs(scrollTop - top) > 0.5 { setScrollTop(min(top, maxScrollTop)) }
        return picture
    }

    /// The character whose line a drawing started at `point` goes to: after a table, a listing or another block rather
    /// than inside it.
    private func drawingPlace(at point: CGPoint) -> Int {
        let view = textView
        let index = view.closestPosition(to: point).map { view.offset(from: view.beginningOfDocument, to: $0) } ?? storage.length
        guard index < storage.length, let block = document.block(containing: index) else { return index }
        return block.range.upperBound
    }

    /// A stroke written outside a canvas waits, shown on the note, to go into `picture`.
    fileprivate func keepPencilStroke(_ stroke: WaitingPencilStroke, for picture: URL) {
        guard let session = drawingSession else { return stroke.ink.removeFromSuperlayer() }
        session.waitingStrokes[picture, default: []].append(stroke)
        // A stroke that had to move to lie on the drawing shows there already.
        if let canvas = session.canvases[picture] {
            let moved = canvas.placement(of: stroke.samples).moved
            stroke.ink.setAffineTransform(CGAffineTransform(translationX: moved.x, y: moved.y))
        }
        scheduleWaitingPencilStrokes()
    }

    /// The waiting strokes go into their drawings at the next pause in the writing.
    func scheduleWaitingPencilStrokes() {
        guard let session = drawingSession, !session.waitingStrokes.isEmpty else { return }
        session.waitingStrokesWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.drawingSession === session, !session.isStrokeUnderWay else { return }
            self.addWaitingPencilStrokes()
        }
        session.waitingStrokesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Puts the waiting strokes into the drawings that have their canvases, and takes their ink off the note a moment
    /// later, once PencilKit has drawn them.
    func addWaitingPencilStrokes() {
        guard let session = drawingSession else { return }
        session.waitingStrokesWork?.cancel()
        guard let tool = pencilTool else { return }
        for (picture, strokes) in session.waitingStrokes {
            guard let canvas = session.canvases[picture] else { continue }
            session.waitingStrokes[picture] = nil
            for stroke in strokes {
                canvas.addPencilStroke(stroke.samples, tool: tool)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { stroke.ink.removeFromSuperlayer() }
            }
        }
    }
}
#endif
