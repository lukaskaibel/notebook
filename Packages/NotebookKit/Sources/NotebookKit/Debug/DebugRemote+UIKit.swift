#if DEBUG && os(iOS)
import PDFKit
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
        case "timeopen":
            // timeopen <path>: opens a note and logs how long the main thread was busy with it, until the screen had
            // been made and the main thread was free again, as on the Mac.
            guard let url = url(argument) else { return }
            let start = CACurrentMediaTime()
            workspace.open(url)
            let opened = CACurrentMediaTime()
            let timer = Timer(timeInterval: 0.001, repeats: false) { _ in
                let done = CACurrentMediaTime()
                MainActor.assumeIsolated { log(String(format: "timeopen %@: open %.1f ms, until free %.1f ms", url.lastPathComponent, (opened - start) * 1000, (done - start) * 1000)) }
            }
            RunLoop.main.add(timer, forMode: .common)
        case "close":
            workspace.closeFile()
        case "pdfpen":
            // pdfpen [off]: the pen above the open PDF, on or off.
            workspace.drawsOnPDF = argument == "off" ? nil : workspace.currentURL
        case "openoutside":
            // openoutside <path>: what a file handed over by the Files app's Open With or a share does.
            workspace.openFromOutside(URL(fileURLWithPath: argument))
        case "insertpicture":
            // insertpicture [closing]: what a photo from the photo library does, with a red square; `closing` puts it in
            // as a picker in front closes, as the camera and the scanner do.
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.systemRed.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            guard argument == "closing", let root = editor.textView.window?.rootViewController else { editor.insertPictures([picture]); break }
            let picker = UIViewController()
            picker.view.backgroundColor = .systemGray
            root.topmostPresented.present(picker, animated: true) {
                picker.dismiss(animated: true)
                editor.insertPictures([picture])
            }
        case "locations":
            // locations: each location's name and place, as Settings shows them.
            log("locations: " + workspace.locations.map { "\($0.name) (\($0.place)) \($0.path)" }.joined(separator: " | "))
        case "newnote":
            workspace.newNote(title: argument.isEmpty ? nil : argument)
        case "samplenotes":
            // samplenotes: what Try Sample Notes does on the first screen.
            workspace.addSampleNotes(in: Workspace.onDeviceFolder)
        case "defaultfolder":
            // defaultfolder [<path>|inbox]: chooses Settings' default folder, then says which it is.
            if argument == "inbox" { workspace.chooseDefaultFolder(nil) } else if !argument.isEmpty, let url = url(argument) { workspace.chooseDefaultFolder(url) }
            log("defaultfolder: \(workspace.defaultFolder?.path ?? "none") (chosen \(workspace.chosenDefaultFolder ?? "none"))")
        case "focus":
            editor.focusText(atEnd: argument == "end")
        case "focustitle":
            editor.focusTitle()
        case "seen":
            log(editor.debugSeenLine)
        case "fold":
            // fold <index>: where the character at index is drawn over the next frames (see debugSampleFold).
            if let index = numbers.first { editor.debugSampleFold(at: Int(index), log: log) }
        case "keyboard":
            // keyboard on|off|auto: as if a keyboard were attached to the iPhone or iPad, or not.
            HardwareKeyboard.shared.override = argument == "on" ? true : argument == "off" ? false : nil
            let keyboard = HardwareKeyboard.shared
            log("keyboard \(keyboard.isInUse ? "in use" : "not in use"): attached \(keyboard.isAttached), touch keyboard shown \(keyboard.isTouchKeyboardShown), shortcuts alone \(keyboard.isShortcutsAlone), bottom inset \(editor.textView.contentInset.bottom), bar \((editor.textView.inputAccessoryView as? WritingBar)?.isTucked == true ? "tucked" : "up")")
        case "touchkeyboard":
            // touchkeyboard hide|show: no touch keyboard and no shortcuts bar under the note, as on an iPad with a
            // keyboard attached and its shortcuts turned off, which a simulator without the Simulator app's window
            // can't have otherwise; with `keyboard on` for the rest of the app.
            let view = editor.textView
            view.inputView = argument == "hide" ? UIView(frame: .zero) : nil
            if argument == "hide" {
                view.inputAssistantItem.leadingBarButtonGroups = []
                view.inputAssistantItem.trailingBarButtonGroups = []
            }
            view.reloadInputViews()
        case "keyboardframe":
            // keyboardframe <height>: a keyboard notification ending that tall at the bottom of the screen, 0 for none
            // at all, as a keyboard with keys or a floating one sends; then what the app makes of it.
            guard let screen = editor.textView.window?.screen.bounds, let height = numbers.first else { return }
            let frame = height == 0 ? CGRect.zero : CGRect(x: 0, y: screen.height - height, width: screen.width, height: height)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
            let keyboard = HardwareKeyboard.shared
            log("keyboard \(keyboard.isInUse ? "in use" : "not in use"): attached \(keyboard.isAttached), touch keyboard shown \(keyboard.isTouchKeyboardShown), shortcuts alone \(keyboard.isShortcutsAlone), bottom inset \(editor.textView.contentInset.bottom), bar \((editor.textView.inputAccessoryView as? WritingBar)?.isTucked == true ? "tucked" : "up")")
        case "tapcaret":
            // tapcaret <index>: the caret put there by a tap, which the editor may move (unlike `select`).
            if let index = numbers.first.map(Int.init) { editor.textView.selectedRange = NSRange(location: index, length: 0) }
        case "presskey":
            // presskey <input>: a key of a hardware keyboard (tab, down, right, left, up) in the title or the text,
            // through their key commands.
            let inputs = ["tab": "\t", "down": UIKeyCommand.inputDownArrow, "up": UIKeyCommand.inputUpArrow, "left": UIKeyCommand.inputLeftArrow, "right": UIKeyCommand.inputRightArrow]
            let responder: UIResponder = editor.isEditingTitle ? editor.textView.titleField : editor.textView
            if let input = inputs[argument], let command = responder.keyCommands?.first(where: { $0.input == input && $0.modifierFlags.isEmpty }), let action = command.action {
                responder.perform(action, with: command)
                log("presskey \(argument): \(action)")
            } else {
                log("presskey \(argument): no command, the text field or view takes it")
            }
        case "deletekey":
            // The keyboard's Delete, as it reaches the text view.
            if editor.isEditingTitle { editor.textView.titleField.deleteBackward() } else if editor.selection == NSRange(location: 0, length: 0) { editor.textView.deleteBackward() } else { editor.debugBackspace() }
        case "blur":
            editor.endEditing()
        case "findinnote":
            // Find in Note's bar; `blurall` then takes the keyboard away from its field and leaves the bar docked.
            editor.findInNote()
        case "blurall":
            editor.textView.window?.endEditing(true)
        case "resign":
            // Puts the keyboard away from whatever has it, such as the search field, leaving what was typed.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        case "doubletapobject":
            // Two taps on what is drawn at the start of some text, right after each other at the same place on the
            // screen, as a double tap is, though the note may move under the first.
            let range = (editor.text as NSString).range(of: argument)
            guard range.location != NSNotFound, let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) else {
                return log("no object at: \(argument)")
            }
            let onScreen = editor.textView.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            editor.debugTap(at: CGPoint(x: rect.midX, y: rect.midY))
            editor.debugTap(at: editor.textView.convert(onScreen, from: nil))
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
        case "place":
            // place [index]: the first character showing (or that one), and how far below the bars its line starts:
            // what a change of text size keeps.
            let index = numbers.first.map { Int($0) } ?? editor.firstVisibleCharacter()
            let text = (editor.text as NSString).substring(from: index).prefix(16).replacingOccurrences(of: "\n", with: "⏎")
            log("place \(index) “\(text)” at \(Int((editor.yPosition(of: index) - editor.visibleRect.minY - editor.topInset).rounded())) header \(Int(editor.textView.headerHeight))")
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
            // rename <name>: the open file; rename <file> > <name>: any file or folder.
            let parts = argument.components(separatedBy: " > ")
            if parts.count == 2, let url = url(parts[0]) { workspace.rename(url, to: parts[1]) } else if let url = workspace.currentURL { workspace.rename(url, to: argument) }
        case "links":
            // links: every link in the open note and the file a tap on it opens.
            log("links: " + workspace.debugLinks())
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
            if let url = workspace.deleting { workspace.answerDeleting(url, delete: false) }
            workspace.problem = nil
        case "deletenow":
            if let url = workspace.deleting { workspace.answerDeleting(url, delete: true) }
        case "notrash":
            // notrash on|off: every place as one without Recently Deleted, or as it is.
            UserDefaults.standard.set(argument != "off", forKey: "NotebookNoRecentlyDeleted")
        case "asking":
            // asking: the file "Delete immediately?" asks about now, and those after it.
            log("asking \(workspace.deleting?.lastPathComponent ?? "-") then \(workspace.deleteQuestions.waiting.map(\.lastPathComponent))")
        case "trash":
            if let url = url(argument) { workspace.trash(url) }
        case "keyundo", "keyredo":
            // keyundo, keyredo: ⌘Z and ⇧⌘Z on a keyboard, as UIKit sends them: from the first responder, or the window
            // without one, up to what takes them. Says where they went and what Undo would have said.
            let action = Selector((command == "keyundo" ? "undo:" : "redo:"))
            UIResponder.debugFirstResponder = nil
            UIApplication.shared.sendAction(#selector(UIResponder.debugBecomeFound(_:)), to: nil, from: nil, for: nil)
            let window = editor.textView.window ?? UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            guard let start = UIResponder.debugFirstResponder ?? window, let target = start.target(forAction: action, withSender: nil) as? UIResponder else {
                log("\(command): nothing takes it"); break
            }
            let manager = target is UIWindow ? (UIResponder.debugFirstResponder?.undoManager ?? target.undoManager) : target.undoManager
            let title = command == "keyundo" ? manager?.undoMenuItemTitle : manager?.redoMenuItemTitle
            log("\(command): from \(type(of: start)) to \(type(of: target)), “\(title ?? "")”")
            target.perform(action, with: nil)
        case "menuundo":
            // menuundo, menuredo: Edit › Undo and Redo, ⌘Z and ⇧⌘Z.
            workspace.undo()
        case "menuredo":
            workspace.redo()
        case "undoinfo":
            // undoinfo: what Undo and Redo would take back in the files and in the note.
            let files = workspace.fileUndoManager
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            let window = windows.first { $0.undoManager === files }
            log("undoinfo files “\(files.undoMenuItemTitle)” “\(files.redoMenuItemTitle)” note “\(editor.undoStack.undoMenuItemTitle)” “\(editor.undoStack.redoMenuItemTitle)” text first responder \(editor.textView.isFirstResponder)")
            log("undoinfo \(editor.undoStack.debugOrders)")
            log("undoinfo files kept in \(window.map { "\(type(of: $0)) key=\($0.isKeyWindow) takes undo=\($0.canPerformAction(Selector(("undo:")), withSender: nil))" } ?? "no window") of \(windows.map { "\(type(of: $0)) key=\($0.isKeyWindow)" })")
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
        case "activate":
            // activate <label>: what VoiceOver's double tap does on the view with that label, in any of the app's
            // windows. UIKit's views only: SwiftUI's and menu items have their labels only while VoiceOver runs (for a
            // toolbar's menu, menuat).
            var seen: [String] = []
            func find(_ object: NSObject, depth: Int) -> NSObject? {
                if object.accessibilityLabel == argument, !(object is UIWindow) { return object }
                if let label = object.accessibilityLabel, !label.isEmpty { seen.append("\(type(of: object)):\(label)") }
                guard depth < 40 else { return nil }
                if let view = object as? UIView {
                    for subview in view.subviews { if let found = find(subview, depth: depth + 1) { return found } }
                }
                for case let element as NSObject in object.accessibilityElements ?? [] where !(element is UIView) {
                    if let found = find(element, depth: depth + 1) { return found }
                }
                return nil
            }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).reversed()
            if let found = windows.lazy.compactMap({ find($0, depth: 0) }).first {
                log("activate \(argument): \(type(of: found)) \(found.accessibilityActivate())")
            } else {
                log("activate \(argument): nothing, only \(seen.prefix(60))")
            }
        case "menuat":
            // menuat <x> <y>: opens the menu of the button with one at that point of the window (a toolbar's ⋯), as a tap
            // would, without a touch: the Simulator's touches need someone to allow them first.
            let point = CGPoint(x: numbers.first ?? 0, y: numbers.count > 1 ? numbers[1] : 0)
            var buttons: [UIView] = []
            func collect(_ view: UIView) {
                if view.interactions.contains(where: { $0 is UIContextMenuInteraction }) { buttons.append(view) }
                view.subviews.forEach(collect)
            }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            windows.forEach(collect)
            let selector = NSSelectorFromString("_presentMenuAtLocation:")
            guard let button = buttons.last(where: { $0.convert($0.bounds, to: nil).contains(point) }),
                  let interaction = button.interactions.first(where: { $0 is UIContextMenuInteraction }) as? UIContextMenuInteraction,
                  interaction.responds(to: selector) else {
                log("menuat \(argument): none of \(buttons.map { "\(type(of: $0)) \($0.convert($0.bounds, to: nil))" })"); break
            }
            typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            unsafeBitCast(interaction.method(for: selector), to: Present.self)(interaction, selector, CGPoint(x: button.bounds.midX, y: button.bounds.midY))
            log("menuat \(argument): \(type(of: button))")
        case "order":
            // order <name|dateEdited|dateCreated> [foldersfirst 1|0]: what Sort By and Keep Folders on Top in the ⋯ menus do.
            let bits = argument.split(separator: " ").map(String.init)
            if let order = bits.first.flatMap(FileOrder.init(rawValue:)) { withAnimation { NotebookSettings.shared.fileOrders.set(order, for: workspace.folderInView) } }
            if bits.count == 3, bits[1] == "foldersfirst" { NotebookSettings.shared.foldersFirst = bits[2] == "1" }
            log("order \(NotebookSettings.shared.fileOrders.order(of: workspace.folderInView).rawValue) foldersFirst=\(NotebookSettings.shared.foldersFirst)")
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
        case "easing":
            // easing <text>: the weight and size of the text's first letter on each of the next 20 frames, to see a
            // change of style ease in (`format bold` right before it).
            let range = (editor.text as NSString).range(of: argument)
            guard range.location != NSNotFound else { return log("not found: \(argument)") }
            var samples: [String] = []
            let start = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let font = editor.storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
                    let variation = font.flatMap { CTFontCopyVariation($0) as? [NSNumber: NSNumber] }
                    let weight = variation?[NSNumber(value: 0x7767_6874)]?.doubleValue ?? 400
                    samples.append(String(format: "%.0fms %.0f %.1f", (CACurrentMediaTime() - start) * 1000, weight, font?.pointSize ?? 0))
                    if samples.count == 20 {
                        timer.invalidate()
                        log("easing " + samples.joined(separator: ", "))
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
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
        case "spotlight":
            // spotlight […]: see `Workspace.spotlightCommand`.
            log(workspace.spotlightCommand(argument))
        case "resolve":
            log("resolve \(argument): \(workspace.index.resolve(argument, from: workspace.currentURL)?.path ?? "nothing") building \(workspace.index.isBuilding) entries \(workspace.index.count)")
        case "suggestions":
            log("suggestions \(editor.suggestions.isVisible) \(editor.suggestions.model.items.map(\.title))")
        case "cursorview":
            // Where UIKit draws the caret, next to where the editor says it is.
            func cursors(in view: UIView) -> [UIView] {
                (String(describing: type(of: view)).contains("Cursor") ? [view] : []) + view.subviews.flatMap(cursors)
            }
            let view = editor.textView
            let drawn = cursors(in: view.window ?? view).map { "\(type(of: $0)) \($0.convert($0.bounds, to: view).integral) hidden \($0.isHidden) alpha \($0.alpha)" }
            let position = view.position(from: view.beginningOfDocument, offset: editor.selection.location)
            log("cursorview caret \(position.map { view.caretRect(for: $0).integral } ?? .null): \(drawn.joined(separator: "; "))")
        case "views":
            if let window = editor.textView.window { log(describe(window, depth: 0, limit: Int(numbers.first ?? 6))) }
        case "exportpdf":
            // exportpdf <path>: the open note as Share › PDF and Print make it; its pages and the size of its text there.
            Task {
                guard let data = await NoteExporter.pdfData(for: editor, title: editor.titleText) else { return log("exportpdf failed") }
                try? data.write(to: URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
                let page = PDFDocument(data: data)?.page(at: 0)?.attributedString
                let body = page.flatMap { text in (text.string as NSString).range(of: "\n").location < text.length - 1 ? text.attribute(.font, at: (text.string as NSString).range(of: "\n").location + 1, effectiveRange: nil) as? UIFont : nil }
                log("exportpdf pages \(PDFDocument(data: data)?.pageCount ?? 0) text \(body?.pointSize ?? 0) on screen \(EditorStyle.bodySize)")
            }
        case "searchrequest":
            // searchrequest: what Go › Search (⌥⌘F) asks for: the caret in the sidebar's search field.
            workspace.searchRequest += 1
        case "focused":
            // focused: what has the keyboard, and how many times Search was asked for.
            log("focused \(UIResponder.focused.map { String(describing: type(of: $0)) } ?? "nothing") searches \(workspace.searchRequest) findBar \(editor.textView.findInteraction?.isFindNavigatorVisible == true)")
        case "barscroll":
            // Which scroll view the bars of each screen follow: the note's text view, another, or none.
            let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            func screens(_ controller: UIViewController) -> [UIViewController] {
                [controller] + controller.children.flatMap(screens) + (controller.presentedViewController.map(screens) ?? [])
            }
            for controller in windows.compactMap(\.rootViewController).flatMap(screens) where controller.parent is UINavigationController {
                let view = controller.contentScrollView(for: .top)
                log("barscroll \(type(of: controller)): \(view === editor.textView ? "the note's text view" : view.map { "\(type(of: $0))" } ?? "none")"
                    + (view === editor.textView && editor.textView.window == nil ? ", not in a window" : ""))
            }
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
            if DebugFolderIcons.run(command, argument, workspace: workspace, url: url, log: log) { break }
            if DebugTodos.run(command, argument, workspace: workspace, log: log) { break }
            if DebugVersions.run(command, argument, workspace: workspace, log: log) { break }
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

extension UIResponder {
    /// The first responder, which UIKit doesn't name: an action sent to it says who it is.
    static weak var debugFirstResponder: UIResponder?

    @objc func debugBecomeFound(_ sender: Any?) {
        UIResponder.debugFirstResponder = self
    }
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
