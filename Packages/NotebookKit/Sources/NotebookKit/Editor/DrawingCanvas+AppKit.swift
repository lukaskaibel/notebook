#if os(macOS)
import AppKit
import PencilKit

/// The tools for drawing on the Mac, which the palette at the bottom of the note sets: a pen, a pencil or a marker,
/// each with its own colour and width, and an eraser. Kept between launches, as the iPad's tool picker keeps its own.
@MainActor
@Observable
final class DrawingTools {
    static let shared = DrawingTools()

    enum Tool: String, CaseIterable, Identifiable {
        case pen, pencil, marker, eraser
        var id: Self { self }

        var name: String {
            switch self {
            case .pen: "Pen"
            case .pencil: "Pencil"
            case .marker: "Marker"
            case .eraser: "Eraser"
            }
        }

        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .pencil: "pencil"
            case .marker: "highlighter"
            case .eraser: "eraser"
            }
        }

        var inkType: PKInk.InkType? {
            switch self {
            case .pen: .pen
            case .pencil: .pencil
            case .marker: .marker
            case .eraser: nil
            }
        }

        /// Fine, medium and bold, in points.
        var widths: [CGFloat] {
            switch self {
            case .pen: [1.5, 3, 6]
            case .pencil: [2.4, 4, 8]
            case .marker: [10, 20, 36]
            case .eraser: [8, 20, 44]
            }
        }
    }

    enum Eraser: String, CaseIterable, Identifiable {
        /// Takes away the part of a stroke it goes over.
        case pixel
        /// Takes away whole strokes.
        case object
        var id: Self { self }
        var name: String { self == .pixel ? "Pixel Eraser" : "Object Eraser" }
    }

    /// The colours to pick from at once, as in Notes; any other comes from the colour panel.
    static let palette: [NSColor] = [0x1C1C1E, 0x2F6FDE, 0x2FA84F, 0xF2C230, 0xE5483E].map { NSColor(hex: $0) }

    var tool: Tool { didSet { save() } }
    var eraser: Eraser { didSet { save() } }
    private var colors: [Tool: NSColor] { didSet { save() } }
    private var widthLevels: [Tool: Int] { didSet { save() } }

    private init() {
        let defaults = UserDefaults.standard
        tool = defaults.string(forKey: "drawingTool").flatMap(Tool.init) ?? .pen
        eraser = defaults.string(forKey: "drawingEraser").flatMap(Eraser.init) ?? .pixel
        var colors: [Tool: NSColor] = [.pen: Self.palette[0], .pencil: Self.palette[0], .marker: Self.palette[3]]
        for (key, value) in defaults.dictionary(forKey: "drawingColors") as? [String: Int] ?? [:] {
            if let tool = Tool(rawValue: key) { colors[tool] = NSColor(hex: UInt32(value)) }
        }
        self.colors = colors
        var widths: [Tool: Int] = [:]
        for (key, value) in defaults.dictionary(forKey: "drawingWidths") as? [String: Int] ?? [:] {
            if let tool = Tool(rawValue: key) { widths[tool] = min(2, max(0, value)) }
        }
        widthLevels = widths
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(tool.rawValue, forKey: "drawingTool")
        defaults.set(eraser.rawValue, forKey: "drawingEraser")
        defaults.set(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, Int($0.value.hexValue)) }), forKey: "drawingColors")
        defaults.set(Dictionary(uniqueKeysWithValues: widthLevels.map { ($0.key.rawValue, $0.value) }), forKey: "drawingWidths")
    }

    /// The colour of the pen, pencil or marker in hand.
    var color: NSColor {
        get { colors[tool] ?? Self.palette[0] }
        set { colors[tool] = newValue }
    }

    /// 0, 1 or 2: fine, medium or bold.
    var widthLevel: Int {
        get { widthLevels[tool] ?? 1 }
        set { widthLevels[tool] = newValue }
    }

    var width: CGFloat { tool.widths[widthLevel] }

    var ink: PKInk? {
        tool.inkType.map { PKInk($0, color: color) }
    }
}

/// A view drawn on with the mouse, the trackpad or a tablet's pen (with its pressure). PencilKit has no canvas on the
/// Mac, so this one makes PencilKit strokes from the events, and the views draw them with PencilKit, which makes them
/// look as they do on an iPad. A drawing in a note and a PDF's page are drawn on with it.
@MainActor
class StrokeCanvas: NSView, NSMenuItemValidation {
    /// Points on screen for a point of the drawing.
    var scale: CGFloat = 1
    /// The stroke being drawn.
    private(set) var live: PKStroke?

    /// The strokes as they are now. Erasing changes them as it goes, and `commit`s them when the button comes up.
    var strokes: PKDrawing {
        get { PKDrawing() }
        set {}
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// The button went down to draw or erase.
    func strokeWillBegin() {}

    /// The strokes changed, drawn, erased, undone or redone.
    func strokesDidChange() {}

    // MARK: - Mouse, trackpad and tablet

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        strokeWillBegin()
        let tools = DrawingTools.shared
        if let ink = tools.ink {
            drawStroke(from: event, ink: ink, width: tools.width)
        } else {
            erase(from: event, radius: tools.width / 2, wholeStrokes: tools.eraser == .object)
        }
    }

    /// Follows the button until it comes up, as AppKit's own controls do, and the modifier keys if asked.
    private func track(from event: NSEvent, keys: Bool = false, _ handle: (NSEvent) -> Void) {
        handle(event)
        let types: NSEvent.EventTypeMask = keys ? [.leftMouseDragged, .leftMouseUp, .flagsChanged] : [.leftMouseDragged, .leftMouseUp]
        while let window, let next = window.nextEvent(matching: types) {
            handle(next)
            if next.type == .leftMouseUp { break }
            displayIfNeeded()
        }
    }

    /// Where an event is, in the drawing's points.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    /// Points on screen around a part of the drawing.
    func viewRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// Holding Shift makes the stroke a straight line, from where it started to the pointer, as in other Mac apps:
    /// let go of Shift before the button, and it is drawn as the hand went.
    private func drawStroke(from event: NSEvent, ink: PKInk, width: CGFloat) {
        var points: [PKStrokePoint] = []
        var straight = false
        let start = event.timestamp
        let date = Date()
        track(from: event, keys: true) { event in
            straight = event.modifierFlags.contains(.shift)
            if event.type != .flagsChanged {
                let location = location(of: event)
                if let last = points.last, hypot(last.location.x - location.x, last.location.y - location.y) < 0.4 { return }
                // A tablet's pen draws thinner when pressed lightly; the mouse and trackpad draw evenly. The button
                // coming up has no pressure: it keeps the last.
                var size = width
                if event.subtype == .tabletPoint, event.type != .leftMouseUp { size = width * (0.4 + 1.2 * CGFloat(event.pressure)) }
                if event.type == .leftMouseUp, let last = points.last { size = last.size.width }
                points.append(PKStrokePoint(location: location, timeOffset: event.timestamp - start, size: CGSize(width: size, height: size),
                                            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
            }
            guard !points.isEmpty else { return }
            let old = live.map { viewRect($0.renderBounds.insetBy(dx: -3, dy: -3)) }
            let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: straight ? Self.line(along: points) : points, creationDate: date))
            live = stroke
            setNeedsDisplay(viewRect(stroke.renderBounds.insetBy(dx: -3, dy: -3)).union(old ?? .zero))
        }
        guard let stroke = live else { return }
        live = nil
        var drawing = strokes
        drawing.strokes.append(stroke)
        commit(drawing, actionName: "Draw")
    }

    /// A straight line from the first point to the last, level or upright when it nearly is.
    static func line(along points: [PKStrokePoint]) -> [PKStrokePoint] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        var end = last.location
        let dx = end.x - first.location.x, dy = end.y - first.location.y
        let angle = abs(atan2(dy, dx)) * 180 / .pi
        let snap: CGFloat = 4
        if angle < snap || angle > 180 - snap {
            end.y = first.location.y
        } else if abs(angle - 90) < snap {
            end.x = first.location.x
        }
        let length = hypot(end.x - first.location.x, end.y - first.location.y)
        // A point every few points, as wide as the stroke was where it started: PencilKit draws a line of points.
        let count = max(2, Int(length / 4) + 1)
        return (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count - 1)
            return PKStrokePoint(location: CGPoint(x: first.location.x + (end.x - first.location.x) * t, y: first.location.y + (end.y - first.location.y) * t),
                                 timeOffset: last.timeOffset * t, size: first.size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
    }

    private func erase(from event: NSEvent, radius: CGFloat, wholeStrokes: Bool) {
        let before = strokes
        var previous: CGPoint?
        let start = event.timestamp
        track(from: event) { event in
            let point = location(of: event)
            let from = previous ?? point
            previous = point
            let reach = radius / scale
            var drawing = strokes
            if wholeStrokes {
                drawing.strokes.removeAll { Self.stroke($0, isWithin: reach, ofSegmentFrom: from, to: point) }
            } else {
                let size = CGSize(width: reach * 2, height: reach * 2)
                let path = PKStrokePath(controlPoints: [
                    PKStrokePoint(location: from, timeOffset: 0, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
                    PKStrokePoint(location: point, timeOffset: max(0.001, event.timestamp - start), size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
                ], creationDate: Date())
                drawing.erasePath(path)
            }
            if drawing != strokes { strokes = drawing }
        }
        guard strokes != before else { return }
        let after = strokes
        strokes = before
        commit(after, actionName: "Erase")
    }

    /// Whether any part of a stroke comes within `reach` of a line segment.
    private static func stroke(_ stroke: PKStroke, isWithin reach: CGFloat, ofSegmentFrom a: CGPoint, to b: CGPoint) -> Bool {
        let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard stroke.renderBounds.insetBy(dx: -reach, dy: -reach).intersects(segment) else { return false }
        for point in stroke.path.interpolatedPoints(by: .distance(2)) {
            let p = point.location.applying(stroke.transform)
            if distance(from: p, toSegmentFrom: a, to: b) <= reach + point.size.width / 2 { return true }
        }
        return false
    }

    private static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Changes and undo

    /// Makes `drawing` the strokes, as a step of its own that Undo takes back.
    func commit(_ drawing: PKDrawing, actionName: String) {
        guard let undo = undoManager else { return }
        let old = strokes
        let grouped = !undo.isUndoing && !undo.isRedoing
        if grouped { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated { canvas.commit(old, actionName: actionName) }
        }
        undo.setActionName(actionName)
        if grouped { undo.endUndoGrouping() }
        strokes = drawing
        strokesDidChange()
    }

    /// Adds a stroke as if it had been drawn, through `points` in the drawing's points (the debug remote's).
    func addStroke(through points: [CGPoint], ink: PKInk, width: CGFloat) {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var drawing = strokes
        drawing.strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date())))
        commit(drawing, actionName: "Draw")
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let undo = undoManager else { return false }
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = undo.undoMenuItemTitle
            return undo.canUndo
        case #selector(redo(_:)):
            menuItem.title = undo.redoMenuItemTitle
            return undo.canRedo
        default:
            return true
        }
    }
}

/// A drawing open for drawing on the Mac, over its place in the text. The drawing is the same file on the iPad.
@MainActor
final class DrawingCanvas: StrokeCanvas {
    let picture: URL
    var file: DrawingFile {
        didSet {
            if file.drawing != oldValue.drawing { strokesImage = nil }
            needsDisplay = true
        }
    }
    /// Drawn in since drawing mode started.
    var isEdited = false
    var hasUnsavedChanges = false
    private weak var editor: EditorController?
    private var strokesImage: (image: NSImage, dark: Bool, scale: CGFloat)?
    /// Strokes and erasing are undone here, while drawing; the text has its own undo. Each is a step of its own.
    private let strokeUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    init(picture: URL, file: DrawingFile, editor: EditorController) {
        self.picture = picture
        self.file = file
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drawing")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { strokeUndo }

    override var strokes: PKDrawing {
        get { file.drawing }
        set { file.drawing = newValue }
    }

    /// The drawing is shown as wide as the text.
    func place(in rect: NSRect) {
        if frame != rect { frame = rect }
        let scale = rect.width / max(1, file.size.width)
        if abs(scale - self.scale) > 0.0001 {
            self.scale = scale
            strokesImage = nil
            needsDisplay = true
        }
    }

    override func strokeWillBegin() {
        editor?.canvasDidBeginStroke(self)
    }

    override func strokesDidChange() {
        editor?.drawingDidChange(self)
    }

    // MARK: - Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Only the strokes, with no edge around them, as in Notes: the text around shows where you can draw, and the
    /// crosshair.
    override func draw(_ dirtyRect: NSRect) {
        let backing = window?.backingScaleFactor ?? 2
        let dark = isDark
        if !file.drawing.strokes.isEmpty {
            if strokesImage == nil || strokesImage?.dark != dark || strokesImage?.scale != scale * backing,
               let pixels = DrawingFile.render(file.drawing, in: CGRect(origin: .zero, size: file.size), scale: scale * backing, dark: dark) {
                strokesImage = (NSImage.make(pixels, scale: backing), dark, scale * backing)
            }
            strokesImage?.image.drawUpright(in: NSRect(x: 0, y: 0, width: file.size.width * scale, height: file.size.height * scale))
        }
        if let live {
            let area = live.renderBounds.insetBy(dx: -2, dy: -2)
            if let pixels = DrawingFile.render(PKDrawing(strokes: [live]), in: area, scale: scale * backing, dark: dark) {
                NSImage.make(pixels, scale: backing).drawUpright(in: viewRect(area))
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Keys

    /// Escape stops drawing; typing stops it too and goes on in the text, below the drawing.
    override func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53:
            editor.endDrawing()
        case 51, 117, 123, 124, 125, 126:
            break
        default:
            guard let characters = event.characters, !characters.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty else {
                return super.keyDown(with: event)
            }
            editor.endDrawingToWrite()
            editor.textView.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.endDrawing()
    }
}

/// What the shared drawing mode asks of the Mac: canvases are views over the text, the palette is SwiftUI's.
extension EditorController {
    func startDrawingInput() {
        updateCopyButton(at: nil)
    }

    func stopDrawingInput(_ session: DrawingSession) {
        let hadFocus = session.canvases.values.contains { textView.window?.firstResponder === $0 }
        for canvas in session.canvases.values { canvas.removeFromSuperview() }
        if hadFocus { textView.window?.makeFirstResponder(textView) }
        textView.window?.invalidateCursorRects(for: textView)
    }

    func attachCanvas(_ canvas: DrawingCanvas) {
        textView.addSubview(canvas, positioned: .below, relativeTo: textView.copyButton)
    }

    func detachCanvas(_ canvas: DrawingCanvas) {
        canvas.removeFromSuperview()
    }

    func focusCanvas(_ picture: URL) {
        guard let canvas = drawingSession?.canvases[picture] else { return }
        textView.window?.makeFirstResponder(canvas)
    }

    /// The palette, floating at the bottom of the note.
    var drawingToolsHeight: CGFloat { 80 }

    /// Where the note's page ends: the text view is at least as tall as the window shows.
    var pageBottom: CGFloat { textView.bounds.maxY }
}
#endif
