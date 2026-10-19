#if DEBUG && os(iOS)
import PencilKit
import SwiftUI
import UIKit

/// Development-only remote control for iPhone and iPad, as on the Mac. Launch with `-debugCommandFile <path>` (a `~`
/// is the app's home in the Simulator) and append lines to that file to drive the app: open files, type, press keys,
/// tap things in a note, search, go back. Results go to `<path>.log`. Screenshots come from `xcrun simctl io`.
@MainActor
enum DebugRemote {
    private static var processed = 0
    private static var timer: Timer?
    private static weak var workspace: Workspace?
    private static var path = ""
    private static var waitUntil: Date?

    static func startIfRequested(workspace: Workspace) {
        guard timer == nil, let file = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        self.workspace = workspace
        path = (file as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        // Every line in the file runs, also those written while the app was starting: start with an empty file.
        processed = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("ready \(path)")
    }

    private static func poll() {
        if let waitUntil, Date() < waitUntil { return }
        waitUntil = nil
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        while processed < lines.count - 1 {
            let line = lines[processed]
            processed += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            run(line)
            if waitUntil != nil { return }
        }
    }

    static func log(_ text: String) {
        let url = URL(fileURLWithPath: path + ".log")
        let line = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private static func url(_ argument: String) -> URL? {
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument) }
        return workspace?.locations.first?.url.appendingPathComponent(argument)
    }

    private static func run(_ line: String) {
        guard let workspace else { return log("no workspace for \(line)") }
        log("> \(line)")
        let editor = workspace.editor
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "wait":
            waitUntil = Date().addingTimeInterval(numbers.first ?? 0.5)
        case "open":
            if let url = url(argument) { workspace.open(url) }
        case "close":
            workspace.closeFile()
        case "newnote":
            workspace.newNote(title: argument.isEmpty ? nil : argument)
        case "focus":
            editor.focusText(atEnd: argument == "end")
        case "focustitle":
            editor.focusTitle()
        case "blur":
            editor.endEditing()
        case "type":
            for character in argument.replacingOccurrences(of: "\\n", with: "\n") { editor.debugType(String(character)) }
        case "key":
            switch argument {
            case "return": editor.debugType("\n")
            case "backspace": editor.debugBackspace()
            case "tab": editor.debugType("\t")
            case "up": _ = editor.moveUpIntoTitle()
            default: log("unknown key \(argument)")
            }
        case "select":
            if numbers.count == 2 { editor.setSelection(NSRange(location: Int(numbers[0]), length: Int(numbers[1]))) }
        case "find":
            // Puts the caret at the start of some text in the note.
            let range = (editor.text as NSString).range(of: argument)
            if range.location != NSNotFound { editor.setSelection(NSRange(location: range.location, length: 0)) }
        case "tapobject":
            // A tap on whatever is drawn at the start of some text (a checkbox, a link, a picture).
            let range = (editor.text as NSString).range(of: argument)
            guard range.location != NSNotFound else { return log("not found: \(argument)") }
            if let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) {
                editor.debugTap(at: CGPoint(x: rect.midX, y: rect.midY))
            } else {
                let glyph = editor.layoutManager.glyphIndexForCharacter(at: range.location)
                let rect = editor.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container)
                editor.debugTap(at: CGPoint(x: rect.midX + editor.textOrigin.x, y: rect.midY + editor.textOrigin.y))
            }
        case "format":
            if let format = FormatCommand.allCases.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == argument.lowercased() }) {
                editor.perform(format)
            }
        case "pictures", "selectpicture", "movepicture", "deletepicture":
            // The pictures of the note, by their order: `selectpicture 0`, `movepicture 0 <offset>`.
            let pattern = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)")
            let ranges = pattern.matches(in: editor.text, range: NSRange(location: 0, length: editor.nsText.length)).map(\.range).filter(editor.isWholeObject)
            let index = Int(numbers.first ?? 0)
            guard command == "pictures" || ranges.indices.contains(index) else { return log("no picture \(index)") }
            switch command {
            case "selectpicture": editor.selectObject(ranges[index])
            case "movepicture": editor.moveObject(ranges[index], to: Int(numbers.count > 1 ? numbers[1] : 0))
            case "deletepicture": editor.deleteObject(ranges[index])
            default: log("pictures \(ranges)")
            }
        case "movetext":
            // movetext <location> <length> <to>: text dragged within the note.
            if numbers.count == 3 { editor.moveText(NSRange(location: Int(numbers[0]), length: Int(numbers[1])), to: Int(numbers[2])) }
        case "formatpanel":
            argument == "hide" ? editor.hideFormatPanel() : editor.showFormatPanel()
        case "scroll":
            editor.setScrollTop((numbers.first ?? 0) - editor.topInset)
        case "scrollto":
            editor.scroll(to: editor.outline[safe: Int(numbers.first ?? 0)], animated: false)
        case "undo":
            // As ⌘Z or shaking does: in whatever has the focus.
            (editor.isEditingTitle ? editor.textView.titleField.undoManager : editor.textView.undoManager)?.undo()
        case "redo":
            (editor.isEditingTitle ? editor.textView.titleField.undoManager : editor.textView.undoManager)?.redo()
        case "titlereturn":
            // Return in the title, as the keyboard sends it: the field lets go, then says so.
            _ = editor.textView.titleField.resignFirstResponder()
            editor.textView.titleField.sendActions(for: .editingDidEndOnExit)
        case "typetitle":
            editor.textView.titleField.insertText(argument)
        case "title":
            log("title “\(editor.titleText)” editing \(editor.isEditingTitle) text \(editor.textView.isFirstResponder)")
        case "outline":
            workspace.isOutlineVisible.toggle()
        case "sidebar":
            workspace.columnVisibility = argument == "hide" ? .detailOnly : .all
        case "favorite":
            if let url = url(argument) ?? workspace.currentURL { workspace.toggleFavorite(url) }
        case "rename":
            if let url = workspace.currentURL { workspace.rename(url, to: argument) }
        case "renamealert":
            workspace.renaming = url(argument) ?? workspace.currentURL
        case "makefolder":
            // makefolder <folder> > <name>: what Create in the New Folder alert does (`newfolder` brings the alert up).
            let parts = argument.components(separatedBy: " > ")
            workspace.newFolder(in: parts.count == 2 ? url(parts[0]) : workspace.locations.first?.url, named: parts.last)
        case "typebench":
            // Types into the note as fast as it takes it, and says how long each keystroke took.
            let count = Int(numbers.first ?? 50)
            var times: [Double] = []
            for index in 0..<count {
                let start = CACurrentMediaTime()
                editor.debugType(index % 7 == 6 ? " " : "a")
                editor.textView.layoutIfNeeded()
                times.append((CACurrentMediaTime() - start) * 1000)
            }
            log(String(format: "typing in a %d character note: average %.1f ms, worst %.1f ms", editor.text.utf16.count, times.reduce(0, +) / Double(times.count), times.max() ?? 0))
        case "makelong":
            // A long note to try typing in: the sample notes many times over.
            guard let root = workspace.locations.first?.url else { return }
            let parts = ["Travel/Kyoto trip.md", "Projects/Notebook roadmap.md", "University/Linear algebra/Week 3.md", "Travel/Budget.md"]
            let text = parts.compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n\n")
            let long = Array(repeating: text, count: Int(numbers.first ?? 20)).joined(separator: "\n\n## Again\n\n")
            try? long.write(to: root.appendingPathComponent("Long note.md"), atomically: true, encoding: .utf8)
            workspace.readAgain([root])
        case "dismiss":
            log("dismissing renaming \(workspace.renaming?.lastPathComponent ?? "-") deleting \(workspace.deleting?.lastPathComponent ?? "-") problem \(workspace.problem?.title ?? "-")")
            workspace.renaming = nil
            workspace.deleting = nil
            workspace.problem = nil
        case "deletenow":
            if let url = workspace.deleting { workspace.deleteImmediately(url) }
            workspace.deleting = nil
        case "trash":
            if let url = url(argument) { workspace.moveToTrash(url) }
        case "move":
            // move <file> > <folder>
            let paths = argument.components(separatedBy: " > ")
            if paths.count == 2, let file = url(paths[0]), let folder = url(paths[1]) { workspace.drop([file], into: folder) }
        case "hide", "unhide":
            // hide <path>, unhide <path>: what Hide Folder and Unhide Folder in a folder's menu do.
            if let url = url(argument) { withAnimation { workspace.setHidden(url, command == "hide") } }
            log("\(command) \(argument): \(workspace.hidden.keys.sorted())")
        case "showhidden":
            // showhidden <location name> <1|0>: the eye on that location's header; showhidden all: ⇧⌘. and the ⋯ menu.
            if argument == "all" {
                withAnimation { workspace.toggleAllHiddenFolders() }
            } else if let space = argument.lastIndex(of: " "), let location = workspace.locations.first(where: { $0.name == argument[..<space] }) {
                withAnimation { workspace.showHiddenFolders(argument[argument.index(after: space)...] == "1", in: location) }
            }
            log("showhidden \(argument): \(workspace.locations.filter(workspace.showsHiddenFolders(in:)).map(\.name))")
        case "rows":
            // rows [folder]: the folders and files a list shows for a folder (a location's top without one), hidden ones marked.
            guard let folder = url(argument) ?? workspace.locations.first?.url else { break }
            let rows = workspace.visibleChildren(of: folder).map { $0.name + ($0.isFolder && workspace.isHidden($0.url) ? " (hidden)" : "") }
            log("rows \(argument): \(rows.joined(separator: ", "))")
        case "exists":
            log("exists \(argument): \(url(argument).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
        case "ls":
            let folder = url(argument) ?? URL(fileURLWithPath: "/")
            log("ls \(argument): \((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted().joined(separator: ", ") ?? "-")")
        case "export":
            Task {
                let file = await NoteExporter.pdfFile(for: editor, title: workspace.currentTitle)
                log("exported \(file?.path ?? "nothing")")
            }
        case "dump":
            log("current \(workspace.currentURL?.path ?? "none") editing \(workspace.isEditing) selection \(editor.selection) scroll \(editor.scrollTop) top \(editor.topInset) titleAway \(workspace.isTitleScrolledAway) heading \(String(describing: workspace.currentHeading))")
        case "text":
            log(editor.text)
        case "caretinfo":
            // caretinfo: the caret UIKit proposes and the one drawn, next to the baseline and font of the text there.
            caretInfo(editor)
        case "autocorrect":
            // The keyboard putting a word right: `autocorrect teh the` replaces the last "teh" through UITextInput.
            let words = argument.split(separator: " ").map(String.init)
            let range = (editor.text as NSString).range(of: words[0], options: .backwards)
            guard words.count == 2, range.location != NSNotFound,
                  let start = editor.textView.position(from: editor.textView.beginningOfDocument, offset: range.location),
                  let end = editor.textView.position(from: start, offset: range.length),
                  let textRange = editor.textView.textRange(from: start, to: end) else { return }
            if editor.textView(editor.textView, shouldChangeTextIn: range, replacementText: words[1]) { editor.textView.replace(textRange, withText: words[1]) }
        case "qlclose":
            workspace.quickLookURL = nil
        case "index":
            // index: how the index was built and kept since launch, and what search has now.
            let index = workspace.index
            log("index files=\(index.count) building=\(index.isBuilding) search=\(index.corpus.items.count) | " + index.history.joined(separator: " | "))
        case "resolve":
            log("resolve \(argument): \(workspace.index.resolve(argument, from: workspace.currentURL)?.path ?? "nothing") building \(workspace.index.isBuilding) entries \(workspace.index.count)")
        case "suggestions":
            log("suggestions \(editor.suggestions.isVisible) \(editor.suggestions.model.items.map(\.title))")
        case "views":
            if let window = editor.textView.window { log(describe(window, depth: 0, limit: Int(numbers.first ?? 6))) }
        case "drawing", "drawstroke", "drawinfo", "drawundo", "drawredo":
            log(editor.debugDrawing(command, argument))
        case "drawpolicy":
            // drawpolicy any|pencil|default: who draws in the open canvases.
            let policy: PKCanvasViewDrawingPolicy = argument == "any" ? .anyInput : argument == "pencil" ? .pencilOnly : .default
            editor.drawingSession?.canvases.values.forEach { $0.drawingPolicy = policy }
            log("policy \(policy.rawValue)")
        case "drawrefresh":
            for canvas in editor.drawingSession?.canvases.values ?? [:].values {
                switch argument {
                case "layout": canvas.setNeedsLayout(); canvas.layoutIfNeeded()
                case "offset": canvas.contentOffset = CGPoint(x: 0, y: 1); canvas.contentOffset = .zero
                case "zoom": let zoom = canvas.zoomScale; canvas.zoomScale = zoom * 0.999; canvas.zoomScale = zoom
                default: let drawing = canvas.drawing; canvas.drawing = PKDrawing(); canvas.drawing = drawing
                }
            }
            log("refreshed \(argument)")
        case "palette":
            // palette: opens or closes ⌘K; palette rows: what its search found.
            if argument == "rows" {
                log("palette \(String(describing: workspace.palette)): " + workspace.paletteSearch.sections.map { "[\($0.title ?? "")] " + $0.items.map(\.title).joined(separator: " | ") }.joined(separator: " "))
            } else {
                workspace.togglePalette()
            }
        case "tapdrawing":
            // A tap on the note's nth drawing, as a finger's.
            let drawings = editor.drawingObjects()
            guard let found = drawings[safe: Int(numbers.first ?? 0)],
                  let rect = editor.layoutManager.blockObjectRect(at: found.index, origin: editor.textOrigin) else { return log("no drawing") }
            editor.debugTap(at: CGPoint(x: rect.midX, y: rect.midY))
        default:
            if DebugReminders.run(command, argument, workspace: workspace, url: url, log: log) { break }
            // Everything else is the screens': going back, searching, showing settings.
            NotificationCenter.default.post(name: .notebookDebug, object: nil, userInfo: ["command": command, "argument": argument])
        }
    }

    /// The caret UIKit proposes and the one drawn, next to the baseline and font of the nearest text on its line, in
    /// window points.
    private static func caretInfo(_ editor: EditorController) {
        let view = editor.textView, layout = editor.layoutManager, origin = view.textContainerOrigin
        let index = editor.selection.location
        guard let position = view.position(from: view.beginningOfDocument, offset: index) else { return }
        func inWindow(_ rect: CGRect) -> String {
            let r = view.convert(rect, to: nil)
            return String(format: "y %.2f–%.2f (h %.2f) x %.1f", r.minY, r.maxY, r.height, r.minX)
        }
        log("caretinfo \(index): proposed \(inWindow(view.proposedCaretRect(for: position))) → caret \(inWindow(view.caretRect(for: position)))")
        guard editor.storage.length > 0 else { return }
        var glyphs = NSRange()
        let glyph = layout.glyphIndexForCharacter(at: min(index, editor.storage.length - 1))
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = editor.nsText
        log("caretinfo \(index): used \(inWindow(used.offsetBy(dx: origin.x, dy: origin.y)))")
        if let character = (characters.location..<NSMaxRange(characters)).first(where: { text.character(at: $0) != 10 && !layout.isHidden($0) }) {
            let g = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let baseline = origin.y + line.minY + layout.location(forGlyphAt: g).y
            let font = editor.storage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? EditorStyle.body
            let offset = editor.storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat ?? 0
            log(String(format: "caretinfo \(index): text '%@' %@ %.1f pt, ascender %.2f descender %.2f offset %.2f, line \(inWindow(CGRect(x: 0, y: origin.y + line.minY, width: 1, height: line.height))), ascender–descender \(inWindow(CGRect(x: 0, y: baseline - font.ascender, width: 1, height: font.ascender - font.descender)))",
                       text.substring(with: NSRange(location: character, length: 1)), font.fontName, font.pointSize, font.ascender, font.descender, offset))
        }
    }

    private static func describe(_ view: UIView, depth: Int, limit: Int) -> String {
        guard depth <= limit else { return "" }
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral)"
        if let label = view.accessibilityLabel { line += " “\(label)”" }
        return ([line] + view.subviews.map { describe($0, depth: depth + 1, limit: limit) }.filter { !$0.isEmpty }).joined(separator: "\n")
    }
}

extension Notification.Name {
    /// A debug remote command for the screens.
    static let notebookDebug = Notification.Name("NotebookDebug")
}

extension EditorController {
    /// A key of the keyboard: the keyboard asks the text view's delegate before it types, as this does.
    func debugType(_ text: String) {
        let range = selection
        if textView(textView, shouldChangeTextIn: range, replacementText: text) { textView.insertText(text) }
    }

    func debugBackspace() {
        let selection = selection
        let range = selection.length > 0 ? selection : (nsText as NSString).rangeOfComposedCharacterSequence(at: max(0, selection.location - 1))
        guard selection.length > 0 || selection.location > 0 else { return }
        if textView(textView, shouldChangeTextIn: range, replacementText: "") { textView.deleteBackward() }
    }

    /// A tap at a point in the text view, as the tap recognizer gets one.
    func debugTap(at point: CGPoint) {
        guard let hit = hitTest(point) else { return DebugRemote.log("nothing at \(point)") }
        DebugRemote.log("tap \(hit)")
        handleTap(hit, at: point)
    }
}
#endif
