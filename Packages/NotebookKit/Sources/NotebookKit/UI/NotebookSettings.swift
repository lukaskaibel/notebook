#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation

/// How notes are set: the typeface, its size, the room between lines and how wide the text runs.
public struct Typography: Hashable, Codable {
    public enum Face: String, CaseIterable, Codable, Identifiable {
        case system, serif, rounded, mono
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .system: "San Francisco"
            case .serif: "New York"
            case .rounded: "Rounded"
            case .mono: "Monospaced"
            }
        }

        var design: NSFontDescriptor.SystemDesign? {
            switch self {
            case .system: nil
            case .serif: .serif
            case .rounded: .rounded
            case .mono: .monospaced
            }
        }

        /// This typeface at a size and weight: San Francisco, New York, SF Rounded or SF Mono.
        func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            guard let design, let descriptor = font.fontDescriptor.withDesign(design) else { return font }
            #if os(macOS)
            return NSFont(descriptor: descriptor, size: size) ?? font
            #else
            return UIFont(descriptor: descriptor, size: size)
            #endif
        }
    }

    public enum Spacing: String, CaseIterable, Codable, Identifiable {
        case compact, normal, relaxed
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
        /// Line height as a multiple of the font size.
        var factor: CGFloat {
            switch self {
            case .compact: 1.42
            case .normal: 1.6
            case .relaxed: 1.85
            }
        }
    }

    public enum Width: String, CaseIterable, Codable, Identifiable {
        case narrow, medium, wide
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
        var points: CGFloat {
            switch self {
            case .narrow: 580
            case .medium: 700
            case .wide: 880
            }
        }
    }

    public var face = Face.system
    #if os(macOS)
    public var size: CGFloat = 15
    #else
    /// iOS's size for reading, where the Mac's is smaller.
    public var size: CGFloat = 17
    #endif
    public var spacing = Spacing.normal
    public var width = Width.medium

    public static let sizes: ClosedRange<CGFloat> = 12...24
}

/// What you can set in Notebook's settings, kept in the user defaults.
@MainActor
@Observable
public final class NotebookSettings {
    public static let shared = NotebookSettings()

    public var typography: Typography {
        didSet {
            guard typography != oldValue else { return }
            save(typography, "typography")
            EditorStyle.apply(typography)
            NotificationCenter.default.post(name: .notebookTypographyChanged, object: nil)
        }
    }

    /// The sidebar shows only notes and folders.
    public var showsOnlyNotes: Bool {
        didSet { changedSidebar("showsOnlyNotes", showsOnlyNotes) }
    }

    /// PDFs, pictures and other files are greyed in the sidebar, so notes stand out.
    public var dimsOtherFiles: Bool {
        didSet { changedSidebar("dimsOtherFiles", dimsOtherFiles) }
    }

    /// Folders come before files in each folder; otherwise everything is sorted by name together.
    public var foldersFirst: Bool {
        didSet { changedSidebar("foldersFirst", foldersFirst) }
    }

    /// How a heading shows that it is one while you edit it: a level tag in the margin, its `#`s showing with a keyboard
    /// and while they are typed, or only its `#`s, in the text, on every keyboard.
    public enum HeadingMarks: String { case margin, inline }
    public var headingMarks: HeadingMarks {
        didSet {
            UserDefaults.standard.set(headingMarks.rawValue, forKey: "headingMarks")
            NotificationCenter.default.post(name: .notebookTypographyChanged, object: nil)
        }
    }

    /// Search finds the words in pictures, scans and handwriting, which Notebook reads in the background.
    public var readsTextInPictures: Bool {
        didSet {
            UserDefaults.standard.set(readsTextInPictures, forKey: "readsTextInPictures")
            Workspace.shared.readTextInPictures(readsTextInPictures)
        }
    }

    /// To-dos at the top of the sidebar, and the reminders of to-dos with a date, a time or a place. Off for those who
    /// keep their to-dos in another app.
    public var showsTodos: Bool {
        didSet {
            UserDefaults.standard.set(showsTodos, forKey: "showsTodos")
            Workspace.shared.todosSettingChanged()
            NotificationCenter.default.post(name: .notebookSidebarOptionsChanged, object: nil)
        }
    }

    /// A new note left without a title or text goes away again, as if it had never been made.
    public var deletesEmptyNewNotes: Bool {
        didSet { UserDefaults.standard.set(deletesEmptyNewNotes, forKey: "deletesEmptyNewNotes") }
    }

    #if os(iOS)
    /// The tools in the bar above the keyboard, in their order. Kept with the tools there were then, so that tools
    /// that come with a later version join a bar you changed (`writingBar(_:known:standard:)`).
    var writingBarTools: [WritingTool] {
        didSet { Self.keep(writingBarTools) }
    }

    private static func keep(_ tools: [WritingTool]) {
        UserDefaults.standard.set(tools.map(\.rawValue), forKey: "writingBarTools")
        UserDefaults.standard.set(WritingTool.allCases.map(\.rawValue), forKey: "writingBarKnownTools")
    }
    #endif

    /// A writing bar you changed, with the standard tools that came since (those not in `known`) put in where they
    /// stand in the standard bar: after the nearest tool before them there that it has. Tools you took out stay out.
    nonisolated static func writingBar(_ saved: [String], known: [String], standard: [String]) -> [String] {
        var bar = saved
        for (index, tool) in standard.enumerated() where !known.contains(tool) && !bar.contains(tool) {
            let before = standard[..<index].last { bar.contains($0) }
            bar.insert(tool, at: before.flatMap(bar.firstIndex(of:)).map { $0 + 1 } ?? 0)
        }
        return bar
    }

    /// The tools of the first writing bar you could change, kept without what tools there were: Drawing and Remind Me
    /// came after it.
    nonisolated static let firstWritingTools = [
        "format", "checklist", "attach", "link", "undo", "redo", "bold", "italic", "strikethrough", "highlight", "code",
        "quote", "bulletedList", "numberedList", "outdent", "indent", "camera", "scanner", "photos", "files", "hideKeyboard",
    ]

    private init() {
        let defaults = UserDefaults.standard
        typography = (defaults.data(forKey: "typography")).flatMap { try? JSONDecoder().decode(Typography.self, from: $0) } ?? Typography()
        showsOnlyNotes = defaults.bool(forKey: "showsOnlyNotes")
        dimsOtherFiles = defaults.object(forKey: "dimsOtherFiles") as? Bool ?? true
        foldersFirst = defaults.object(forKey: "foldersFirst") as? Bool ?? true
        headingMarks = HeadingMarks(rawValue: defaults.string(forKey: "headingMarks") ?? "") ?? .margin
        readsTextInPictures = defaults.object(forKey: "readsTextInPictures") as? Bool ?? true
        deletesEmptyNewNotes = defaults.object(forKey: "deletesEmptyNewNotes") as? Bool ?? true
        showsTodos = defaults.object(forKey: "showsTodos") as? Bool ?? true
        #if os(iOS)
        if let saved = defaults.stringArray(forKey: "writingBarTools") {
            let known = defaults.stringArray(forKey: "writingBarKnownTools") ?? Self.firstWritingTools
            let bar = Self.writingBar(saved, known: known, standard: WritingTool.standard.map(\.rawValue))
            writingBarTools = bar.compactMap(WritingTool.init(rawValue:))
            if bar != saved || known != WritingTool.allCases.map(\.rawValue) { Self.keep(writingBarTools) }
        } else {
            writingBarTools = WritingTool.standard
        }
        #endif
        EditorStyle.apply(typography)
    }

    private func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func changedSidebar(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .notebookSidebarOptionsChanged, object: nil)
    }

    /// ⌘+ and ⌘−.
    public func changeTextSize(by delta: CGFloat) {
        typography.size = min(Typography.sizes.upperBound, max(Typography.sizes.lowerBound, typography.size + delta))
    }
}

public extension NotebookSettings {
    /// The app was called Folio until October 2026. Takes over the settings it kept under its old bundle identifier,
    /// once, before anything reads them. A sandboxed build can't see them and starts afresh.
    nonisolated static func importFolioSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedFolioSettings"),
              let bundle = Bundle.main.bundleIdentifier else { return }
        defaults.set(true, forKey: "importedFolioSettings")
        guard let old = defaults.persistentDomain(forName: bundle.replacingOccurrences(of: "Notebook", with: "Folio")) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

public extension Notification.Name {
    static let notebookTypographyChanged = Notification.Name("NotebookTypographyChanged")
    static let notebookSidebarOptionsChanged = Notification.Name("NotebookSidebarOptionsChanged")
}
