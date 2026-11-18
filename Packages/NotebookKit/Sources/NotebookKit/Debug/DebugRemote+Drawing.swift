#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PencilKit

/// The debug remote's drawing commands, on the Mac and on iPhone and iPad:
/// - `drawing` starts or stops drawing mode as the pencil button does; `drawing <n>` opens the note's nth drawing.
/// - `drawstroke x y x y …` draws a stroke through points in the drawing open last, in points from its top left as
///   it is on screen, with the pen in hand (a black pen on iPhone and iPad).
/// - `drawundo`, `drawredo` undo and redo in the drawing drawn in last.
/// - `drawinfo` tells what is open, how big, how many strokes and what is on disk.
extension EditorController {
    func debugDrawing(_ command: String, _ argument: String) -> String {
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "drawing":
            if let index = numbers.first.map(Int.init) {
                let drawings = drawingObjects()
                guard drawings.indices.contains(index) else { return "no drawing \(index)" }
                if isDrawing { endDrawing() }
                beginDrawing(in: drawings[index].picture)
            } else if argument == "end" {
                endDrawing()
            } else {
                toggleDrawing()
            }
            return "drawing \(isDrawing)"
        case "drawstroke":
            guard let session = drawingSession, let picture = session.focused ?? session.canvases.keys.first,
                  let canvas = session.canvases[picture] else { return "not drawing" }
            let scale = canvas.frame.width / max(1, canvas.file.size.width)
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0] / scale, y: numbers[$0 + 1] / scale) }
            guard points.count >= 1 else { return "no points" }
            #if os(macOS)
            let tools = DrawingTools.shared
            canvas.addStroke(through: points, ink: tools.ink ?? PKInk(.pen, color: .black), width: tools.ink == nil ? 3 : tools.width)
            #else
            let tool = canvas.tool as? PKInkingTool
            canvas.addStroke(through: points, ink: tool?.ink ?? PKInk(.pen, color: .black), width: tool?.width ?? 3)
            #endif
            return "stroke \(points.count) points into \(picture.lastPathComponent): \(canvas.file.drawing.strokes.count) strokes, size \(canvas.file.size)"
        case "drawundo", "drawredo":
            guard let session = drawingSession, let picture = session.focused, let canvas = session.canvases[picture] else { return "not drawing" }
            if command == "drawundo" { canvas.undoManager?.undo() } else { canvas.undoManager?.redo() }
            return "\(command): \(canvas.file.drawing.strokes.count) strokes"
        default:
            return drawingInfo()
        }
    }

    func drawingInfo() -> String {
        var lines = ["drawing mode \(isDrawing), focused \(drawingSession?.focused?.lastPathComponent ?? "none")"]
        for (index, picture) in drawingObjects() {
            let strokes = DrawingFile.read(picture: picture)
            let pictureSize = ImageStore.shared.size(of: picture)
            var line = "  [\(index)] \(picture.lastPathComponent): strokes file \(strokes.map { "\($0.drawing.strokes.count) strokes, \(Int($0.size.width))x\(Int($0.size.height))" } ?? "missing")"
            line += ", picture \(pictureSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "missing")"
            if let rect = layoutManager.blockObjectRect(at: index, origin: textOrigin) { line += ", laid out \(rect.integral)" }
            if let canvas = drawingSession?.canvases[picture] {
                line += ", canvas \(canvas.frame.integral) \(canvas.file.drawing.strokes.count) strokes \(Int(canvas.file.size.width))x\(Int(canvas.file.size.height))"
                line += canvas.hasUnsavedChanges ? " unsaved" : " saved"
                #if os(macOS)
                if textView.window?.firstResponder === canvas { line += " focus" }
                #else
                if canvas.isFirstResponder { line += " focus" }
                #endif
            }
            lines.append(line)
            #if os(iOS)
            for stroke in drawingSession?.canvases[picture]?.drawing.strokes ?? [] {
                let point = stroke.path[stroke.path.count / 2]
                lines.append("    stroke \(stroke.ink.inkType.rawValue) tool width \((drawingSession?.canvases[picture]?.tool as? PKInkingTool)?.width ?? 0), \(stroke.path.count) points, bounds \(stroke.renderBounds.integral), size \(point.size.width), force \(point.force), altitude \(point.altitude), opacity \(point.opacity)")
            }
            #endif
        }
        #if os(iOS)
        if let paused = drawingSession?.pausedGestures { lines.append("paused gestures: \(paused.map { String(describing: type(of: $0)) })") }
        if let picker = drawingSession?.toolPicker {
            lines.append("tool picker visible \(picker.isVisible), obscures \(picker.frameObscured(in: textView)), text view \(textView.bounds), inset \(textView.contentInset.bottom), pencil only \(UIPencilInteraction.prefersPencilOnlyDrawing), tool \(String(describing: picker.selectedToolItem))")
            for canvas in drawingSession?.canvases.values ?? [:].values {
                lines.append("  canvas policy \(canvas.drawingPolicy.rawValue) enabled \(canvas.isDrawingEnabled) userInteraction \(canvas.isUserInteractionEnabled) hit \(sequence(first: textView.hitTest(CGPoint(x: canvas.frame.midX, y: canvas.frame.midY), with: nil), next: { $0?.superview }).prefix(6).map { $0.map { "\(type(of: $0))" } ?? "-" }.joined(separator: " < "))")
            }
        }
        #endif
        return lines.joined(separator: "\n")
    }
}
#endif
