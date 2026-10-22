import AppKit
import XCTest
@testable import NotebookKit

/// An editor in an off-screen window, for tests that type, click and select like a person would.
@MainActor
final class EditorHarness: NSObject, EditorControllerDelegate {
    let editor = EditorController()
    let window: NSWindow
    let folder: URL
    var opened: [LinkTarget.Kind] = []
    /// The lines of the to-dos whose Remind Me was asked for.
    var todoReminders: [Int] = []
    var notes: [String: URL] = [:]

    init(_ text: String, width: CGFloat = 900, height: CGFloat = 900, dark: Bool = false) {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        super.init()
        editor.delegate = self
        let budget = folder.appendingPathComponent("Budget.md")
        try? "# Budget\nFlights €1,240".write(to: budget, atomically: true, encoding: .utf8)
        notes["budget"] = budget
        writeSampleImage(to: folder.appendingPathComponent(".assets/torii.png"))
        editor.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = editor.scrollView
        editor.load(text: text, folder: folder, title: "Kyoto trip", meta: "Edited today at 09:41")
        window.makeFirstResponder(editor.textView)
        settle()
    }

    var textView: MarkdownTextView { editor.textView }
    var text: String { editor.text }
    var selection: NSRange { textView.selectedRange() }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        editor.layoutManager.ensureLayout(for: editor.container)
    }

    // MARK: - Acting like a person

    func caret(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        settle(0)
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        settle(0)
    }

    func type(_ string: String) {
        for character in string {
            if character == "\n" {
                textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }
        }
        settle(0)
    }

    func command(_ selector: Selector) {
        textView.doCommand(by: selector)
        settle(0)
    }

    /// Where a character is drawn, in the text view's coordinates.
    func point(of index: Int, fraction: CGFloat = 0.5) -> NSPoint {
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container)
        let origin = textView.textContainerOrigin
        return NSPoint(x: rect.minX + rect.width * fraction + origin.x, y: rect.midY + origin.y)
    }

    /// A real click through AppKit's own mouse tracking: press, optionally drag, release.
    func click(at point: NSPoint, dragTo end: NSPoint? = nil, count: Int = 1) {
        let windowPoint = textView.convert(point, to: nil)
        let endPoint = textView.convert(end ?? point, to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        if let end {
            let steps = 6
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let location = NSPoint(x: windowPoint.x + (endPoint.x - windowPoint.x) * t, y: windowPoint.y + (endPoint.y - windowPoint.y) * t)
                NSApp.postEvent(event(.leftMouseDragged, location), atStart: false)
            }
            _ = end
        }
        NSApp.postEvent(event(.leftMouseUp, endPoint), atStart: false)
        textView.mouseDown(with: event(.leftMouseDown, windowPoint))
        // A click the editor handled itself (a checkbox, a link) leaves the release in the queue.
        while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        settle(0)
    }

    // MARK: - Looking

    /// Whether the character is drawn (not hidden Markdown).
    func isVisible(_ index: Int) -> Bool {
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.propertyForGlyph(at: glyph) != .controlCharacter
    }

    func visibleText(in range: NSRange) -> String {
        let ns = text as NSString
        var result = ""
        for index in range.location..<range.upperBound where isVisible(index) {
            result += ns.substring(with: NSRange(location: index, length: 1))
        }
        return result
    }

    func range(of string: String) -> NSRange {
        (text as NSString).range(of: string)
    }

    /// The colour drawn at a point of the text view.
    func pixel(at point: CGPoint) -> NSColor? {
        settle(0)
        let view = textView
        let rect = NSRect(x: point.x - 1, y: point.y - 1, width: 3, height: 3)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
    }

    /// The text view drawn into a PNG, for looking at.
    @discardableResult
    func snapshot(_ name: String) -> URL? {
        guard let directory = ProcessInfo.processInfo.environment["NOTEBOOK_SNAPSHOTS"] else { return nil }
        settle(0.2)
        let view = textView
        let height = min(view.frame.height, 4000)
        let rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: height)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        return url
    }

    // MARK: - EditorControllerDelegate

    func editorTextDidChange(_ editor: EditorController) {}
    func editor(_ editor: EditorController, open target: LinkTarget.Kind) { opened.append(target) }
    func editor(_ editor: EditorController, quickLook url: URL) {}
    func editor(_ editor: EditorController, commitTitle title: String) {}
    func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] {
        let names = ["Budget", "Kyoto trip", "Recipes"]
        var items = names.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.map { LinkSuggestion(kind: .note, title: $0, detail: "Travel", insert: $0) }
        if !query.isEmpty { items.append(LinkSuggestion(kind: .create, title: "Create “\(query)”", detail: "", insert: query)) }
        return items
    }
    func editor(_ editor: EditorController, resolve target: String) -> URL? { notes[target.lowercased()] }
    func editorNoteName(_ editor: EditorController) -> String { "Kyoto trip" }
    func editor(_ editor: EditorController, showTodoReminderOnLine line: Int) { todoReminders.append(line) }

    private func writeSampleImage(to url: URL) {
        let size = NSSize(width: 1200, height: 520)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(hex: 0xF3CDB0).setFill(); rect.fill()
            NSColor(hex: 0xFBE6CB).setFill(); NSBezierPath(ovalIn: NSRect(x: 820, y: 330, width: 120, height: 120)).fill()
            NSColor(hex: 0xC98F7A).setFill(); NSBezierPath(ovalIn: NSRect(x: -200, y: -300, width: 1100, height: 520)).fill()
            NSColor(hex: 0xB5321F).setFill()
            NSRect(x: 240, y: 360, width: 520, height: 30).fill()
            NSRect(x: 280, y: 300, width: 440, height: 20).fill()
            NSRect(x: 310, y: 0, width: 30, height: 380).fill()
            NSRect(x: 660, y: 0, width: 30, height: 380).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
