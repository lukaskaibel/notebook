#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// A command in ⌘K: what the menus and the ⋯ menu do, found by typing a few letters of it.
struct PaletteCommand: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var section: String
    /// The keys that do it without ⌘K, shown as key caps.
    var keys: [String] = []
    /// Other words it is found by: "delete" finds Move to Trash.
    var keywords: [String] = []
    var run: () -> Void

    /// How well it matches what was typed, by its title or one of its other words.
    func score(_ query: String) -> Int? {
        ([title] + keywords).compactMap { fuzzyScore(query, $0) }.max()
    }
}

/// What ⌘K needs from the window it is in, which differs between the Mac and the iPad.
struct PaletteActions {
    var openSettings: (_ tab: String?) -> Void
    var newFolder: () -> Void
    var addLocation: () -> Void
}

/// How well `text` matches `query` typed loosely: its letters in order, more for letters in a row and at the start of
/// words. Nil when they aren't all there. As in Issues.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = Array(SearchIndex.fold(query).filter { !$0.isWhitespace })
    guard !q.isEmpty else { return 0 }
    let t = Array(SearchIndex.fold(text))
    var score = 0
    var qi = 0
    var streak = 0
    for (ti, character) in t.enumerated() where qi < q.count {
        if character == q[qi] {
            streak += 1
            score += 2 + streak * 2
            if ti == 0 || !t[ti - 1].isLetter && !t[ti - 1].isNumber { score += 6 }
            qi += 1
        } else {
            streak = 0
        }
    }
    guard qi == q.count else { return nil }
    return score - t.count / 8
}

@MainActor
extension Workspace {
    /// Every command that does something now, in the order ⌘K lists them: the file that is open, making things, going
    /// places, the window, settings.
    func paletteCommands(_ actions: PaletteActions) -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        let settings = NotebookSettings.shared

        if let url = currentURL {
            let section = currentTitle
            let isNote = note != nil
            let isLoaded = note?.isLoaded == true
            if isLoaded {
                list.append(PaletteCommand(id: "rename", title: "Rename", symbol: "pencil", section: section, keywords: ["title"]) { [self] in
                    editor.focusTitle()
                })
            }
            list.append(PaletteCommand(id: "move", title: "Move To…", symbol: "folder", section: section, keywords: ["folder"]) { [self] in
                palette = .move(url)
            })
            list.append(PaletteCommand(id: "duplicate", title: "Duplicate", symbol: "plus.square.on.square", section: section, keywords: ["copy"]) { [self] in
                duplicate(url)
            })
            let favorite = isFavorite(url)
            list.append(PaletteCommand(id: "favorite", title: favorite ? "Remove from Favorites" : "Add to Favorites",
                                       symbol: favorite ? "star.slash" : "star", section: section, keywords: ["star", "pin"]) { [self] in
                toggleFavorite(url)
            })
            if isNote {
                list.append(PaletteCommand(id: "remind", title: "Remind Me…", symbol: "bell", section: section, keywords: ["reminder", "notification"]) { [self] in
                    askForReminder(url)
                })
            }
            if isLoaded {
                list.append(PaletteCommand(id: "draw", title: isDrawing ? "Stop Drawing" : "Drawing", symbol: "pencil.tip.crop.circle", section: section,
                                           keywords: ["sketch", "pencil", "handwriting"]) { [self] in
                    editor.toggleDrawing()
                })
            }
            list.append(PaletteCommand(id: "link", title: "Copy Link", symbol: "link", section: section) { [self] in copyLink(url) })
            #if os(macOS)
            list.append(PaletteCommand(id: "finder", title: "Show in Finder", symbol: "finder", section: section, keywords: ["reveal"]) { [self] in
                revealInFinder(url)
            })
            if isLoaded {
                list.append(PaletteCommand(id: "export-pdf", title: "Export as PDF…", symbol: "doc.richtext", section: section, keys: ["⌥", "⌘", "E"]) { [self] in
                    export(as: .pdf)
                })
                list.append(PaletteCommand(id: "export-png", title: "Export as PNG Image…", symbol: "photo", section: section, keywords: ["picture"]) { [self] in
                    export(as: .png)
                })
                list.append(PaletteCommand(id: "print", title: "Print…", symbol: "printer", section: section, keys: ["⌘", "P"]) { [self] in
                    printNote()
                })
            } else {
                list.append(PaletteCommand(id: "open-in", title: "Open in Its App", symbol: "arrow.up.forward.app", section: section) { [self] in
                    openOnItsOwn(url)
                })
            }
            #endif
            #if os(macOS)
            list.append(PaletteCommand(id: "trash", title: "Move to Trash", symbol: "trash", section: section, keys: ["⌘", "⌫"], keywords: ["delete", "remove"]) { [self] in
                trash(url)
            })
            #else
            // As the ⋯ menu says it: there is no Trash here, and no ⌘⌫, which deletes text in a note.
            if isLoaded {
                list.append(PaletteCommand(id: "print", title: "Print…", symbol: "printer", section: section, keys: ["⌘", "P"]) { [self] in
                    NoteExporter.print(editor, title: currentTitle)
                })
            }
            list.append(PaletteCommand(id: "trash", title: "Delete", symbol: "trash", section: section, keywords: ["trash", "remove"]) { [self] in
                trash(url)
            })
            #endif
        }

        if note?.isLoaded == true {
            let format = "Format"
            let styles: [(FormatCommand, [String])] = [
                (.title, ["⇧", "⌘", "T"]), (.heading, ["⇧", "⌘", "H"]), (.subheading, ["⇧", "⌘", "J"]), (.body, ["⇧", "⌘", "B"]),
                (.checklist, ["⇧", "⌘", "L"]), (.bulletedList, ["⇧", "⌘", "7"]), (.numberedList, ["⇧", "⌘", "9"]), (.quote, ["⌘", "'"]),
                (.bold, ["⌘", "B"]), (.italic, ["⌘", "I"]), (.strikethrough, ["⇧", "⌘", "X"]), (.highlight, ["⌃", "⌘", "H"]),
                (.code, ["⌘", "E"]), (.link, ["⌘", "L"]),
            ]
            for (command, keys) in styles {
                list.append(PaletteCommand(id: "format-\(command.name)", title: command.name, symbol: command.symbol, section: format, keys: keys,
                                           keywords: ["format", "style"]) { [self] in
                    editor.perform(command)
                })
            }
        }

        let new = "New"
        if !locations.isEmpty {
            list.append(PaletteCommand(id: "new-note", title: "New Note", symbol: "square.and.pencil", section: new, keys: ["⌘", "N"]) { [self] in
                newNote()
            })
            list.append(PaletteCommand(id: "new-folder", title: "New Folder", symbol: "folder.badge.plus", section: new, keys: ["⇧", "⌘", "N"]) {
                actions.newFolder()
            })
            list.append(PaletteCommand(id: "import-apple-notes", title: "Import from Apple Notes…", symbol: "square.and.arrow.down.on.square", section: new,
                                       keywords: ["markdown", "export", "move", "notes"]) { [self] in
                #if os(macOS)
                chooseAppleNotesExport()
                #else
                appleNotesImportFolder = selectedFolder ?? folderForNewNote
                #endif
            })
        }
        list.append(PaletteCommand(id: "add-location", title: "Add Location…", symbol: "plus.rectangle.on.folder", section: new,
                                   keywords: ["icloud", "folder", "open"]) {
            actions.addLocation()
        })
        #if os(macOS)
        list.append(PaletteCommand(id: "open", title: "Open…", symbol: "arrow.up.forward.square", section: new, keys: ["⌘", "O"], keywords: ["file"]) {
            FileWindows.shared.choose()
        })
        #endif

        let go = "Go"
        if !showsTodos, NotebookSettings.shared.showsTodos {
            list.append(PaletteCommand(id: "todos", title: "To-dos", symbol: "checklist", section: go, keys: ["⇧", "⌘", "R"],
                                       keywords: ["reminders", "tasks", "checklist", "today", "due"]) { [self] in showTodos() })
        }
        if canGoBack {
            list.append(PaletteCommand(id: "back", title: "Back", symbol: "chevron.backward", section: go, keys: ["⌘", "["]) { [self] in goBack() })
        }
        if canGoForward {
            list.append(PaletteCommand(id: "forward", title: "Forward", symbol: "chevron.forward", section: go, keys: ["⌘", "]"]) { [self] in goForward() })
        }
        #if os(macOS)
        list.append(PaletteCommand(id: "search", title: "Search in the Toolbar", symbol: "magnifyingglass", section: go, keys: ["⌥", "⌘", "F"], keywords: ["find"]) { [self] in
            search.focus()
        })
        #endif

        let view = "View"
        #if os(iOS)
        let hasColumns = !showsPhoneScreens
        #else
        let hasColumns = true
        #endif
        if hasColumns {
            list.append(PaletteCommand(id: "sidebar", title: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", symbol: "sidebar.left", section: view,
                                       keys: ["⌃", "⌘", "S"]) { [self] in
                withAnimation(Theme.spring) { isSidebarVisible.toggle() }
            })
            list.append(PaletteCommand(id: "outline", title: isOutlineVisible ? "Hide Outline" : "Show Outline", symbol: "sidebar.right", section: view,
                                       keys: ["⌃", "⌘", "I"], keywords: ["inspector", "headings"]) { [self] in
                withAnimation(Theme.spring) { isOutlineVisible.toggle() }
            })
        }
        if hasHiddenFolders {
            list.append(PaletteCommand(id: "hidden", title: showsAllHiddenFolders ? "Hide Hidden Folders" : "Show Hidden Folders",
                                       symbol: showsAllHiddenFolders ? "eye.slash" : "eye", section: view, keys: ["⇧", "⌘", "."]) { [self] in
                withAnimation { toggleAllHiddenFolders() }
            })
        }
        list.append(PaletteCommand(id: "only-notes", title: settings.showsOnlyNotes ? "Show All Files" : "Show Only Notes", symbol: "doc.text",
                                   section: view, keywords: ["sidebar", "filter"]) {
            settings.showsOnlyNotes.toggle()
        })
        let folder = folderInView
        for order in FileOrder.allCases where order != settings.fileOrders.order(of: folder) {
            list.append(PaletteCommand(id: "sort-\(order.rawValue)", title: "Sort by \(order.title)", symbol: "arrow.up.arrow.down", section: view,
                                       keywords: ["order", "sidebar", "newest", "recent"]) {
                settings.fileOrders.set(order, for: folder)
            })
        }
        list.append(PaletteCommand(id: "bigger", title: "Bigger Text", symbol: "textformat.size.larger", section: view, keys: ["⌘", "+"],
                                   keywords: ["zoom", "font", "size"]) {
            settings.changeTextSize(by: 1)
        })
        list.append(PaletteCommand(id: "smaller", title: "Smaller Text", symbol: "textformat.size.smaller", section: view, keys: ["⌘", "−"],
                                   keywords: ["zoom", "font", "size"]) {
            settings.changeTextSize(by: -1)
        })

        let settingsSection = "Settings"
        for face in Typography.Face.allCases where face != settings.typography.face {
            list.append(PaletteCommand(id: "face-\(face.rawValue)", title: "Typeface: \(face.name)", symbol: "textformat", section: settingsSection,
                                       keywords: ["font"]) {
                settings.typography.face = face
            })
        }
        for spacing in Typography.Spacing.allCases where spacing != settings.typography.spacing {
            list.append(PaletteCommand(id: "spacing-\(spacing.rawValue)", title: "Line Spacing: \(spacing.name)", symbol: "text.line.spacing",
                                       section: settingsSection) {
                settings.typography.spacing = spacing
            })
        }
        for width in Typography.Width.allCases where width != settings.typography.width {
            list.append(PaletteCommand(id: "width-\(width.rawValue)", title: "Line Width: \(width.name)", symbol: "arrow.left.and.right.text.vertical",
                                       section: settingsSection) {
                settings.typography.width = width
            })
        }
        list.append(PaletteCommand(id: "pictures", title: settings.readsTextInPictures ? "Stop Finding Text in Pictures" : "Find Text in Pictures",
                                   symbol: "text.viewfinder", section: settingsSection, keywords: ["ocr", "handwriting", "scan", "live text"]) {
            settings.readsTextInPictures.toggle()
        })
        #if os(macOS)
        list.append(PaletteCommand(id: "app-icon", title: "App Icon…", symbol: "book.closed", section: settingsSection, keywords: ["leather", "dock"]) {
            actions.openSettings("icon")
        })
        list.append(PaletteCommand(id: "settings", title: "Settings…", symbol: "gearshape", section: settingsSection, keys: ["⌘", ","],
                                   keywords: ["preferences"]) {
            actions.openSettings(nil)
        })
        #else
        list.append(PaletteCommand(id: "settings", title: "Settings", symbol: "gearshape", section: settingsSection, keywords: ["preferences"]) {
            actions.openSettings(nil)
        })
        #endif
        return list
    }
}
