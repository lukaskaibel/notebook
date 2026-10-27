#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A suggestion for the `[[` link popup.
public struct LinkSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case note, file, create }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// What goes between the brackets.
    public var insert: String

    public init(kind: Kind, title: String, detail: String, insert: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.insert = insert
    }
}

/// What the editor needs from the app: where links go and what to do when you follow one.
@MainActor
public protocol EditorControllerDelegate: AnyObject {
    func editorTextDidChange(_ editor: EditorController)
    func editor(_ editor: EditorController, open target: LinkTarget.Kind)
    func editor(_ editor: EditorController, quickLook url: URL)
    func editor(_ editor: EditorController, commitTitle title: String)
    func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion]
    func editor(_ editor: EditorController, resolve target: String) -> URL?
    /// The note's name, used to name pictures pasted into it.
    func editorNoteName(_ editor: EditorController) -> String
    /// The headings or the word count changed.
    func editorOutlineDidChange(_ editor: EditorController)
    /// You scrolled: into another section, or the title out of view.
    func editorPositionDidChange(_ editor: EditorController)
    /// Typing started or stopped, in the note or its title (on iPhone and iPad: the keyboard came up or went).
    func editorEditingDidChange(_ editor: EditorController)
    /// Drawing mode started or ended, or Undo and Redo in it have something else to do.
    func editorDrawingDidChange(_ editor: EditorController)
    /// The reminder under the title, or the writing bar's bell, was tapped: to set, change or remove the note's reminder.
    func editorShowReminder(_ editor: EditorController)
    /// A to-do's pill or bell was clicked: to set, change or remove its date or place, or with `.reminder` both.
    func editor(_ editor: EditorController, showTodoReminderOnLine line: Int, part: TodoPart)
    /// A to-do that repeats was ticked: what its line said on `line`, and the next one's line, now on that line.
    func editor(_ editor: EditorController, tickedRepeatingTodo source: String, line: Int, next: String)
    /// Whether pictures and drawings may go into the note's folder, which a note opened from the Finder in the
    /// sandboxed build has to be given first. On the Mac it asks for the folder then and there.
    func editor(_ editor: EditorController, mayWriteIn folder: URL) -> Bool
    #if os(iOS)
    /// Asks for the note's folder where `mayWriteIn` says no (a note opened from another app): true once pictures and
    /// drawings may go into it.
    func editor(_ editor: EditorController, askToWriteIn folder: URL) async -> Bool
    #endif
}

/// What of a to-do's reminder a click asks to change: its date (its date's pill, the bell), its place (its place's
/// pill), or both at once (Remind Me…).
public enum TodoPart: Sendable {
    case reminder, date, place
}

public extension EditorControllerDelegate {
    func editorOutlineDidChange(_ editor: EditorController) {}
    func editorPositionDidChange(_ editor: EditorController) {}
    func editorEditingDidChange(_ editor: EditorController) {}
    func editorDrawingDidChange(_ editor: EditorController) {}
    func editorShowReminder(_ editor: EditorController) {}
    func editor(_ editor: EditorController, showTodoReminderOnLine line: Int, part: TodoPart) {}
    func editor(_ editor: EditorController, tickedRepeatingTodo source: String, line: Int, next: String) {}
    func editor(_ editor: EditorController, mayWriteIn folder: URL) -> Bool { true }
    #if os(iOS)
    func editor(_ editor: EditorController, askToWriteIn folder: URL) async -> Bool { false }
    #endif
}

/// Notebook's editor: a TextKit 1 text view whose storage holds the note's Markdown exactly, styled so that it reads as
/// a finished document. Markdown punctuation shows only right next to a resting caret; while you select, nothing moves.
@MainActor
public final class EditorController: NSObject, @preconcurrency NSTextStorageDelegate, EditorLayoutSource {
    public weak var delegate: EditorControllerDelegate?

    let storage: NSTextStorage
    let layoutManager: NotebookLayoutManager
    let container: NSTextContainer
    /// The text view: AppKit's on the Mac, UIKit's on iPhone and iPad (`EditorController+AppKit`, `+UIKit`), both
    /// on TextKit 1 with the same storage, layout manager and container.
    let textView: MarkdownTextView
    #if os(macOS)
    public let scrollView = NSScrollView()
    /// The undo manager the text was last changed in: the window's, which keeps the changes to files too.
    weak var textUndoManager: UndoManager?
    /// The picture being dragged with the mouse, until the drag is over.
    var objectDrag: ObjectDrag?
    #endif
    /// Counts the notes loaded, so pictures that finish loading late, or are dropped after another note was opened,
    /// go only into the note they were meant for.
    var loadCount = 0

    private(set) var document = MarkdownParser.parse("")
    private var lineSignatures: [Int] = []
    /// Character ranges whose hidden punctuation is shown, because the caret is in or next to them.
    private(set) var revealed: [NSRange] = []
    /// The block the caret is in, if it shows its Markdown then (tables, math, diagrams, frontmatter).
    private(set) var activeBlock: Int?
    private(set) var isLoading = false
    /// True while the note's text is still on its way (from iCloud): its title shows, and nothing can be typed or
    /// changed until it is loaded with its text.
    public private(set) var isWaitingForText = false
    /// Shows a note without letting it be changed: an earlier version of it, in Version History. Its text can still be
    /// selected and copied.
    public var isReadOnly = false {
        didSet { updateEditability() }
    }
    private var isApplyingStyle = false
    /// True while the editor changes the text itself, so its own changes aren't taken for typing.
    var isPerformingEdit = false
    /// True while the editor selects something exactly, which isn't grown to take Markdown whole (what a typing rule
    /// selected).
    var selectsExactly = false
    /// Whether the note is read as it is typed in: see `InlineParser.spans`.
    private(set) var isTypingIn = false
    /// What the last press of Bold (or another style) took off, for the next press to put back.
    var unwrapped: MarkdownUnwrapped?
    /// The text whose marks Delete just took off, for a mark typed next to it to put back.
    var unmarked: MarkdownUnmarked?
    /// Eases the text into its new look after an edit: bold thickens, a heading grows, typed marks fade in.
    let styleAnimator = MarkdownStyleAnimator()
    /// Unfolds the marks the caret comes to and folds away those it leaves.
    let revealAnimator = MarkdownRevealAnimator()
    /// Which marks of the lines the last edit styled again were hidden before it, for the marks it showed or hid to fold
    /// in or out (`updateReveal`).
    private var editedMarks: (scope: NSRange, hiddenBefore: IndexSet)?
    /// The start of the line whose heading #s were just typed on a touch keyboard: they show until the caret leaves the
    /// line, so you see which heading you typed.
    var typedHeading: Int?
    /// When Delete was last pressed in the text, which tells a key held down from one pressed again.
    var lastDeleteBackward: CFTimeInterval = 0
    /// For tests: marks show next to the caret as with a keyboard (true) or not, as on a touch keyboard (false).
    var marksShowOverride: Bool? {
        didSet { updateReveal() }
    }
    /// What the caret is in, for the buttons on the left of the bar above the keyboard.
    let caretContext = CaretContext()
    /// The folder of the note, which pictures and relative links start from.
    public private(set) var folder: URL?
    /// Drawing mode, while it is on (`EditorController+Drawing`).
    var drawingSession: DrawingSession?
    /// The caret was put somewhere since the note was opened, rather than left at its start.
    var caretWasPlaced = false

    let suggestions = LinkSuggestionPanel()

    /// The note's headings, for the outline next to it.
    public internal(set) var outline: [OutlineHeading] = []
    public internal(set) var stats = NoteStats()
    /// The heading whose section is at the top of the window, as an index into `outline`.
    public internal(set) var currentHeading: Int?
    /// True once the title has scrolled up under the toolbar.
    public internal(set) var isTitleScrolledAway = false
    var outlineUpdate: DispatchWorkItem?
    /// The heading picked in the outline and where that scrolled to: it stays the current one until you scroll away,
    /// even when the note ends too soon to bring it to the top.
    var jump: (heading: Int?, y: CGFloat)?
    var isJumping = false
    #if os(iOS)
    /// The selection before the last change, which tells where the caret came from.
    var previousSelection = NSRange(location: 0, length: 0)
    /// True while the editor moves the selection itself, so it isn't corrected again.
    var isSettingSelection = false
    var isWaitingForTracking = false
    /// A place restored while the note moves to another screen, kept for when it gets there.
    var pendingPlace: Place?
    enum Focus { case title, text }
    var pendingFocus: Focus?
    var requestedFocus: (Focus, Date)?
    var isMoving = false
    /// The editor's own record of changes, for undo (`EditorUndo+UIKit`).
    let undoStack = EditorUndoManager()
    var openStep: UndoStep?
    /// The last tap on a checkbox, and where it was in the window: a second one right after it, at the same place, is
    /// a double tap, not an untick.
    var lastCheckboxTap: (time: Date, point: CGPoint)?
    var isReplayingUndo = false
    /// The text as it was before the last change, which tells what a change removed.
    var shadowText = NSMutableString()
    /// What the Format panel shows: the style of the caret's line and the formatting it is in.
    let formatState = FormatState()
    /// The Format panel in place of the keyboard, made the first time Aa is tapped.
    var formatInput: UIView?
    /// The bar above the keyboard.
    var writingBar: UIView?
    /// Touching and holding pictures, and dragging them.
    var pictureInteractions: PictureInteractions?
    #endif
    /// Where the `[[` the popup completes starts (just after the brackets). While it is set, that link is drawn as
    /// the text being typed rather than as a finished link.
    var suggestionAnchor: Int? {
        didSet {
            guard oldValue != suggestionAnchor, !isLoading else { return }
            let lines = [oldValue, suggestionAnchor].compactMap { $0 }.filter { $0 <= storage.length }.map { document.lineIndex(containing: $0) }
            restyle(lines: Array(Set(lines)))
        }
    }
    /// Characters whose glyphs are to be made again once the edit going on is over (`flushGlyphs`).
    private var pendingGlyphs = IndexSet()
    private var isGlyphFlushScheduled = false

    public override init() {
        _ = NotebookSettings.shared
        let storage = NSTextStorage()
        let layoutManager = NotebookLayoutManager()
        let container = NSTextContainer(size: NSSize(width: EditorStyle.contentWidth, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        self.storage = storage
        self.layoutManager = layoutManager
        self.container = container
        #if os(macOS)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        #else
        textView = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        #endif
        super.init()
        #if os(macOS)
        textView.replaceTextContainer(container)
        #endif
        configureTextView()
        storage.delegate = self
        layoutManager.source = self
        textView.controller = self
        styleAnimator.view = textView
        revealAnimator.view = textView
        revealAnimator.onConcealed = { [weak self] ranges in self?.invalidateGlyphs(in: ranges) }
        NotificationCenter.default.addObserver(self, selector: #selector(typographyChanged), name: .notebookTypographyChanged, object: nil)
        suggestions.onPick = { [weak self] suggestion in self?.acceptSuggestion(suggestion) }
    }

    public var text: String { storage.string }
    var nsText: NSString { storage.string as NSString }

    // MARK: - Loading

    /// Shows a note. `title` is its name; `focusTitle` puts the caret in the title (for a new note). Without its
    /// `text`, which is still on its way, only the title shows, and nothing can be changed; the text fades in when the
    /// note is loaded again with it.
    public func load(text: String?, folder: URL?, title: String, meta: String, focusTitle: Bool = false) {
        endDrawing()
        if isWaitingForText, text != nil, isInWindow { fadeInNextChange() }
        let waiting = text == nil
        let text = text ?? ""
        isLoading = true
        self.folder = folder
        closeSuggestions()
        jump = nil
        revealAnimator.cancel()
        editedMarks = nil
        typedHeading = nil
        revealed = []
        activeBlock = nil
        lineSignatures = []
        // The whole text is new, and so is every glyph.
        pendingGlyphs = IndexSet()
        titleText = title
        metaText = meta
        updateLayoutMode(for: (text as NSString).length)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        setSelection(NSRange(location: 0, length: 0))
        loadCount += 1
        #if os(iOS)
        undoStack.clear()
        openStep = nil
        previousSelection = NSRange(location: 0, length: 0)
        layoutManager.selectedRanges = []
        // Another note: the keyboard goes, unless this one asks for it below.
        pendingFocus = nil
        requestedFocus = nil
        if textView.isFirstResponder || textView.titleField.isFirstResponder { textView.endEditing(true) }
        #else
        forgetTextUndo()
        // A name being typed was taken as the other note was left: this note's title isn't being typed.
        if isEditingTitle { makeTextFirstResponder() }
        #endif
        isLoading = false
        caretWasPlaced = false
        if isWaitingForText != waiting {
            isWaitingForText = waiting
            updateEditability()
        }
        scrollToTop()
        updateOutline()
        if focusTitle, !waiting {
            self.focusTitle()
        }
    }

    /// Takes in a new version of the text from disk (changed elsewhere, or merged with it). Only the part that
    /// differs is replaced, as an edit that can be undone, so the caret and the scroll position stay where they are.
    public func reload(text: String) {
        guard let change = change(to: text) else { return }
        preservingScroll {
            replace(change.range, with: change.replacement, select: change.caret, actionName: "Change from Another Device")
        }
    }

    /// What turns the text into `text`: the part between what the two share at the start and at the end, and where
    /// the caret goes. Nil when they are the same.
    func change(to text: String) -> (range: NSRange, replacement: String, caret: NSRange)? {
        let old = storage.string as NSString
        let new = text as NSString
        guard old as String != text else { return nil }
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let selection = self.selection
        let delta = (replacement as NSString).length - range.length
        var caret = selection
        if selection.location >= range.upperBound { caret.location += delta } else if selection.location > range.location { caret = NSRange(location: range.location + (replacement as NSString).length, length: 0) }
        return (range, replacement, caret)
    }

    /// Marks what changed since an earlier version in it: Show Changes in Version History.
    func showChanges(_ marks: [VersionChanges.Mark]) {
        layoutManager.changeMarks = marks
        textNeedsDisplay()
    }

    /// Notes up to a few thousand words are laid out whole, so nothing below the window ever changes size by
    /// surprise. Longer ones are laid out where you look, so every keystroke stays within a frame.
    static let wholeLayoutLimit = 20_000

    private func updateLayoutMode(for length: Int) {
        let partial = length > Self.wholeLayoutLimit
        if layoutManager.allowsNonContiguousLayout != partial { layoutManager.allowsNonContiguousLayout = partial }
    }

    public func setMeta(_ meta: String) { metaText = meta }
    /// The note's reminder in the line under the title, "Today 14:00", red once its time has passed; nil for none.
    func setReminder(_ text: String?, isOverdue: Bool) { textView.setReminder(text, isOverdue: isOverdue) }
    public func setTitle(_ title: String) {
        if !isEditingTitle { titleText = title }
    }

    public func focusText(atEnd: Bool = false) {
        makeTextFirstResponder()
        let location = atEnd ? storage.length : 0
        setSelection(NSRange(location: location, length: 0))
    }

    /// Puts the caret in the title: all of it selected, or at its end, coming from the text below it.
    public func focusTitle(caretAtEnd: Bool = false) {
        makeTitleFirstResponder()
        if caretAtEnd { putTitleCaretAtEnd() }
    }

    /// Leaves the title for the text, at its start, as Return does.
    func leaveTitle() {
        commitTitle()
        focusText()
    }

    /// Links and pictures may point somewhere else now (files were added, renamed, deleted): style them again.
    /// The note's folder was renamed or moved, or the note into another: pictures and relative links start from where
    /// it is now. The text stays as it is, with the caret and where it is scrolled to.
    public func folderMoved(to folder: URL) {
        guard folder.standardizedFileURL != self.folder?.standardizedFileURL else { return }
        self.folder = folder
        refreshLinks()
    }

    public func refreshLinks() {
        let lines = document.lines.indices.filter { index in
            document.lines[index].spans.contains { span in
                switch span.kind {
                case .wikiLink, .embed, .image: true
                default: false
                }
            }
        }
        guard !lines.isEmpty else { return }
        restyle(lines: lines)
    }

    // MARK: - Parsing and styling

    var environment: StyleEnvironment {
        StyleEnvironment(
            folder: folder,
            resolve: { [weak self] target in self.flatMap { $0.delegate?.editor($0, resolve: target) } },
            activeBlock: activeBlock,
            composing: suggestionAnchor,
            previewHeight: { [weak self] block in self?.previewHeight(for: block) ?? 0 }
        )
    }

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplyingStyle else { return }
        #if os(iOS)
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let removed = shadowText.substring(with: oldRange)
        shadowText.replaceCharacters(in: oldRange, with: (textStorage.string as NSString).substring(with: editedRange))
        recordChange(editedRange, removed: removed)
        #endif
        updateLayoutMode(for: textStorage.length)
        #if os(macOS)
        // Like the pointer, the copy button keeps out of the way while you type, and it would be left behind by a
        // block that moved.
        updateCopyButton(at: nil)
        #endif
        if !isLoading { scheduleOutlineUpdate() }
        let oldDocument = document
        let oldSignatures = lineSignatures
        document = MarkdownParser.parse(storage.mutableString, typing: isTypingIn)
        // Keep the revealed punctuation where it was until the caret settles, moved along with the edit.
        let oldEnd = editedRange.location + editedRange.length - delta
        let oldRevealed = revealed
        revealed = revealed.compactMap { range in
            if range.upperBound <= editedRange.location { return range }
            if range.location >= oldEnd { return range.shifted(by: delta) }
            let start = min(range.location, editedRange.location)
            let end = min(storage.length, max(range.upperBound + delta, editedRange.upperBound))
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
        // The open block is the one being typed in, wherever its index moved to.
        if activeBlock != nil {
            let caret = min(editedRange.upperBound, storage.length)
            let line = document.lineIndex(containing: caret)
            if let block = document.lines[safe: line]?.block, document.blocks[block].isSwappable { activeBlock = block } else { activeBlock = nil }
        }
        if let typed = typedHeading, typed > editedRange.location { typedHeading = typed >= oldEnd ? typed + delta : nil }

        let signatures = computeSignatures()
        var lines: [Int] = []
        let lineDelta = document.lines.count - oldDocument.lines.count
        for index in document.lines.indices {
            let line = document.lines[index]
            var oldIndex: Int?
            if line.fullRange.upperBound <= editedRange.location {
                oldIndex = index
            } else if line.range.location >= editedRange.upperBound {
                oldIndex = index - lineDelta
            }
            if let oldIndex, oldIndex >= 0, oldIndex < oldSignatures.count, oldSignatures[oldIndex] == signatures[index] { continue }
            lines.append(index)
        }
        lineSignatures = signatures
        isApplyingStyle = true
        if isLoading {
            MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
        } else if let first = lines.min(), let last = lines.max() {
            let start = document.lines[first].fullRange.location
            let scope = NSRange(location: start, length: document.lines[last].fullRange.upperBound - start)
            if revealAnimator.isEnabled {
                editedMarks = (scope, hiddenMarks(in: scope, edited: editedRange, delta: delta, revealedBefore: oldRevealed))
            }
            revealAnimator.shift(edited: editedRange, delta: delta)
            styleAnimator.restyle(storage, edited: editedRange, scope: scope) {
                MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
                // The edit's own fixing ran before the styling, which undid it: an emoji got the text's font.
                storage.fixAttributes(in: scope)
            }
            revealAnimator.reapply(to: storage)
        }
        isApplyingStyle = false
        if !isLoading { invalidateGlyphs(of: lines) }
    }

    /// Lines styled again get their glyphs made again: which characters are hidden is decided when glyphs are made,
    /// and a change of attributes alone, above all one made while the text view is in the middle of its own edit,
    /// leaves the old ones (a table's source stayed hidden after it opened again).
    private func invalidateGlyphs(of lines: [Int]) {
        // Line by line, so that two blocks far apart don't lay out the whole note between them again.
        for index in lines where index < document.lines.count {
            let line = document.lines[index].fullRange
            let end = min(storage.length, line.upperBound)
            if end > line.location { pendingGlyphs.insert(integersIn: line.location..<end) }
        }
        flushGlyphs()
    }

    /// The lines of these ranges get their glyphs made again (marks that finished folding away hide).
    func invalidateGlyphs(in ranges: [NSRange]) {
        for range in ranges where range.upperBound <= storage.length {
            let line = nsText.lineRange(for: range)
            if line.length > 0 { pendingGlyphs.insert(integersIn: line.location..<line.upperBound) }
        }
        flushGlyphs()
    }

    /// Makes the glyphs waiting for it again, once no edit of the text is open: the layout manager may not be asked to
    /// lay out while the text storage is still processing one (UIKit throws).
    func flushGlyphs() {
        guard !pendingGlyphs.isEmpty else { return }
        guard storage.editedMask.isEmpty else {
            if !isGlyphFlushScheduled {
                isGlyphFlushScheduled = true
                DispatchQueue.main.async { [weak self] in
                    self?.isGlyphFlushScheduled = false
                    self?.flushGlyphs()
                }
            }
            return
        }
        let pending = pendingGlyphs
        pendingGlyphs = IndexSet()
        for run in pending.rangeView where run.lowerBound < storage.length {
            let range = NSRange(location: run.lowerBound, length: min(run.upperBound, storage.length) - run.lowerBound)
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }


    /// What decides how a line looks: its text, what kind of line it is, the block it is in and whether that block is
    /// being edited. Lines whose signature didn't change keep their attributes.
    private func computeSignatures() -> [Int] {
        var blockHashes: [Int] = []
        for (index, block) in document.blocks.enumerated() {
            var hasher = Hasher()
            for line in block.lines { hasher.combine(document.lines[line].textHash) }
            hasher.combine(index == activeBlock)
            hasher.combine(block.kind)
            blockHashes.append(hasher.finalize())
        }
        return document.lines.enumerated().map { index, line in
            var hasher = Hasher()
            hasher.combine(line.textHash)
            Self.combineShape(of: line, into: &hasher)
            if let block = line.block {
                hasher.combine(blockHashes[block])
                hasher.combine(index - document.blocks[block].lines.lowerBound)
            }
            hasher.combine(index == 0)
            return hasher.finalize()
        }
    }

    /// A line's kind without where it is in the note, so lines that only moved don't count as changed.
    private static func combineShape(of line: MarkdownLine, into hasher: inout Hasher) {
        let start = line.range.location
        func relative(_ range: NSRange) -> Int { (range.location - start) << 16 | range.length }
        switch line.kind {
        case .heading(let level, let marker):
            hasher.combine(1); hasher.combine(level); hasher.combine(relative(marker))
        case .listItem(let item):
            hasher.combine(2); hasher.combine(item.indent); hasher.combine(item.level); hasher.combine(item.marker)
            hasher.combine(relative(item.markerRange)); hasher.combine(relative(item.prefix)); hasher.combine(item.mark)
            hasher.combine(item.checkbox.map(relative) ?? -1)
        case .quote(let depth, let prefix):
            hasher.combine(3); hasher.combine(depth); hasher.combine(relative(prefix))
        case .footnoteDefinition(let label):
            hasher.combine(4); hasher.combine(relative(label))
        case .blank: hasher.combine(10)
        case .paragraph: hasher.combine(11)
        case .thematicBreak: hasher.combine(12)
        case .fence: hasher.combine(13)
        case .code: hasher.combine(14)
        case .mathDelimiter: hasher.combine(15)
        case .math: hasher.combine(16)
        case .tableHeader: hasher.combine(17)
        case .tableDelimiter: hasher.combine(18)
        case .tableRow: hasher.combine(19)
        case .frontmatterDelimiter: hasher.combine(20)
        case .frontmatter: hasher.combine(21)
        }
    }

    /// Styles lines again outside of an edit (the caret entered a block, a link's target appeared).
    func restyle(lines: [Int]) {
        guard !lines.isEmpty else { return }
        // An ease still under way would overwrite the new look with the old one's last.
        styleAnimator.complete()
        isApplyingStyle = true
        storage.beginEditing()
        MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
        revealAnimator.reapply(to: storage)
        storage.endEditing()
        isApplyingStyle = false
        lineSignatures = computeSignatures()
        invalidateGlyphs(of: lines)
    }

    /// The typeface, size, spacing or width changed in the settings: the whole note is set again, keeping the line
    /// you are on where it is.
    @objc func typographyChanged() {
        textView.typingAttributes = MarkdownStyler.baseAttributes
        #if os(macOS)
        textView.defaultParagraphStyle = EditorStyle.paragraph()
        #endif
        textView.applyTypography()
        preservingScroll {
            // The title and the line under it grow with the text: the note starts lower, by that much, at once.
            textView.updateInsets()
            restyle(lines: Array(document.lines.indices))
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
        updateDrawingCanvases()
    }

    func lines(of block: Int) -> [Int] {
        guard let block = document.blocks[safe: block] else { return [] }
        return Array(block.lines)
    }

    private func previewHeight(for block: MarkdownBlock) -> CGFloat {
        let width = container.size.width
        switch block.kind {
        case .mermaid:
            let source = MarkdownStyler.diagramSource(nsText, document, block)
            if case .some(.some(let image)) = DiagramStore.diagram(source, isDark: isDarkAppearance, ready: { [weak self] in
                guard let self, let index = self.document.blocks.firstIndex(where: { $0.range == block.range }) else { return }
                self.preservingScroll { self.restyle(lines: self.lines(of: index)) }
            }) {
                let scale = image.size.width > width ? width / image.size.width : 1
                return ceil(image.size.height * scale)
            }
            return 80
        case .math:
            let tex = MarkdownStyler.mathSource(nsText, document, block)
            if let math = MathStore.render(tex, display: true, size: 19, color: Theme.text.resolved(dark: isDarkAppearance)) {
                return ceil(math.image.size.height)
            }
            return 30
        default:
            return 0
        }
    }

    // MARK: - Revealing Markdown next to the caret

    /// The punctuation to show and the block to open for the caret where it is: none while text is selected or the
    /// note doesn't have the focus.
    func revealTarget() -> (ranges: [NSRange], block: Int?) {
        let selection = self.selection
        guard isFocused, !document.lines.isEmpty else { return ([], nil) }
        // While text is selected nothing appears or disappears, so the selection never moves under the pointer:
        // what showed next to the caret before stays until the caret rests somewhere again.
        if selection.length > 0 { return (revealed, activeBlock) }
        let caret = selection.location
        let lineIndex = document.lineIndex(containing: caret)
        let line = document.lines[lineIndex]
        var ranges: [NSRange] = []
        var block: Int?
        if let index = line.block {
            let found = document.blocks[index]
            if found.isSwappable { block = index }
            if case .code = found.kind { ranges.append(found.range) }
            if case .callout = found.kind, lineIndex == found.lines.lowerBound { ranges.append(line.range) }
        }
        switch line.kind {
        case .heading(_, let marker): if showsHeadingMarks(marker, of: line) { ranges.append(marker) }
        case .thematicBreak: ranges.append(line.range)
        default: break
        }
        for span in line.spans where !isAtomic(span) && span.range.touches(caret) {
            // On a touch keyboard the bar above it shows the styles the caret is in and turns them off.
            if !showsMarks, span.kind.isStyle { continue }
            ranges.append(span.range)
        }
        return (merged(ranges), block)
    }

    /// Whether marks show next to the caret: with a keyboard, which reaches them with the arrow keys and deletes them
    /// with ease (the Mac, an iPad or iPhone with a keyboard attached). On a touch keyboard the bar above it turns
    /// styles on and off, and only marks being typed show.
    var showsMarks: Bool {
        if let marksShowOverride { return marksShowOverride }
        #if os(macOS)
        return true
        #else
        return HardwareKeyboard.shared.isInUse
        #endif
    }

    /// A heading's #s show while the caret is on it with a keyboard, or where the settings put them in the text; on a
    /// touch keyboard while they are typed, until the caret leaves the line.
    private func showsHeadingMarks(_ marker: NSRange, of line: MarkdownLine) -> Bool {
        if showsMarks || NotebookSettings.shared.headingMarks == .inline || typedHeading == line.range.location { return true }
        // Without their space yet, they are being typed.
        guard marker.length > 0 else { return false }
        let last = nsText.character(at: marker.upperBound - 1)
        return last != 32 && last != 9
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, range.location <= last.upperBound {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    func isRevealed(_ characterIndex: Int) -> Bool {
        Self.contains(revealed, characterIndex) || revealAnimator.isConcealing(characterIndex)
    }

    /// Whether sorted ranges that don't overlap contain an index.
    private static func contains(_ ranges: [NSRange], _ index: Int) -> Bool {
        var low = 0, high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if index < range.location { high = mid - 1 } else if index >= range.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }

    /// Shows the punctuation next to the caret and opens the block it is in, keeping the caret's line still on screen.
    /// Marks that come or go fold in or out.
    func updateReveal(anchor: Int? = nil) {
        guard !isLoading, !isTracking else { return }
        let target = revealTarget()
        let edited = editedMarks
        editedMarks = nil
        guard target.ranges != revealed || target.block != activeBlock || edited != nil else { return }
        preservingScroll(anchor: anchor) {
            let old = revealed
            revealed = target.ranges
            if target.block != activeBlock {
                let previous = activeBlock
                activeBlock = target.block
                var lines: [Int] = []
                if let previous { lines += self.lines(of: previous) }
                if let block = target.block { lines += self.lines(of: block) }
                restyle(lines: lines)
            }
            let folding = foldingMarks(from: old, to: revealed, edited: edited)
            revealAnimator.animate(appearing: folding.appearing, disappearing: folding.disappearing, in: storage)
            for range in old + target.ranges + folding.appearing + folding.disappearing where range.upperBound <= storage.length {
                let lineRange = nsText.lineRange(for: range)
                layoutManager.invalidateGlyphs(forCharacterRange: lineRange, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: lineRange, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: lineRange)
            }
        }
        marginNeedsDisplay()
    }

    /// The marks in the lines an edit is about to style again that were hidden before it, where they are after it.
    /// What was typed showed as it was typed; what came in all at once (pasted, undone) counts as hidden, so it
    /// doesn't fold away mark by mark.
    private func hiddenMarks(in scope: NSRange, edited: NSRange, delta: Int, revealedBefore: [NSRange]) -> IndexSet {
        var hidden = IndexSet()
        let scope = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        // Not styled yet, the new text has whatever attributes it came with: all of it counts as one or the other.
        if edited.length > 12 { hidden.insert(integersIn: edited.location..<edited.upperBound) }
        storage.enumerateAttribute(.notebookHidden, in: scope) { value, run, _ in
            guard let mode = value as? Int else { return }
            for index in run.location..<run.upperBound where !NSLocationInRange(index, edited) {
                // Where the character was before the edit.
                let old = index < edited.location ? index : index - delta
                if mode == HiddenMode.always.rawValue || !(Self.contains(revealedBefore, old) || revealAnimator.isConcealing(old)) {
                    hidden.insert(index)
                }
            }
        }
        return hidden
    }

    /// The marks that come and go between two sets of revealed ranges, and those an edit showed or hid, as runs to fold
    /// in and out.
    private func foldingMarks(from old: [NSRange], to new: [NSRange], edited: (scope: NSRange, hiddenBefore: IndexSet)?) -> (appearing: [NSRange], disappearing: [NSRange]) {
        guard revealAnimator.isEnabled else { return ([], []) }
        var candidates = IndexSet()
        for range in old + new + [edited?.scope].compactMap({ $0 }) where range.length > 0 {
            candidates.insert(integersIn: range.location..<min(range.upperBound, storage.length))
        }
        var appearing = IndexSet()
        var disappearing = IndexSet()
        for run in candidates.rangeView {
            storage.enumerateAttribute(.notebookHidden, in: NSRange(location: run.lowerBound, length: run.count)) { value, range, _ in
                guard (value as? Int) == HiddenMode.untilRevealed.rawValue else { return }
                for index in range.location..<range.upperBound {
                    let before = edited.map { NSLocationInRange(index, $0.scope) ? !$0.hiddenBefore.contains(index) : nil } ?? nil
                    let shownBefore = before ?? Self.contains(old, index)
                    let shown = Self.contains(new, index)
                    if shown, !shownBefore { appearing.insert(index) }
                    if !shown, shownBefore { disappearing.insert(index) }
                }
            }
        }
        func runs(_ set: IndexSet) -> [NSRange] { set.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) } }
        return (runs(appearing), runs(disappearing))
    }

    /// Runs a change that may make lines taller or shorter and scrolls so that the caret (or the top line, when the
    /// caret is off screen) stays exactly where it was on screen.
    /// Keeps what is at `anchor` (or the caret, or the first line in view) where it is on the screen through `change`;
    /// with `movedTo`, where that is once the change is made.
    func preservingScroll(anchor: Int? = nil, movedTo: Int? = nil, _ change: () -> Void) {
        guard isInWindow, storage.length > 0 else { change(); return }
        let visible = visibleRect
        var index = anchor ?? selection.location
        // Laid out first: right after an edit the lines below it may not be yet, and the caret on a new line would
        // be measured where the line above it was (Return after a heading scrolled the note by a line).
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, index + 1)))
        var y = yPosition(of: index)
        if anchor == nil, y < visible.minY + topInset || y > visible.maxY {
            index = firstVisibleCharacter()
            y = yPosition(of: index)
        }
        let before = y - visible.minY
        change()
        if anchor != nil, let movedTo { index = movedTo }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, index + 1)))
        let after = yPosition(of: index) - visible.minY
        let delta = after - before
        if abs(delta) > 0.5 {
            setScrollTop(max(-topInset, visible.minY + delta))
        }
    }

    func yPosition(of index: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, storage.length - 1))
        guard glyph < layoutManager.numberOfGlyphs else { return 0 }
        if index >= storage.length, layoutManager.extraLineFragmentTextContainer != nil {
            return layoutManager.extraLineFragmentRect.minY + textOrigin.y
        }
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textOrigin.y
    }

    /// Puts other text in where you are: the line at the top of what shows, found in the new text by `map`, stays where
    /// it was, rather than the text starting again at its top. Show Changes, turned on and off.
    func load(text: String, folder: URL?, title: String, meta: String, keepingPlace map: (Int) -> Int) {
        guard isInWindow, storage.length > 0 else { return load(text: text, folder: folder, title: title, meta: meta) }
        let index = firstVisibleCharacter()
        let offset = yPosition(of: index) - visibleRect.minY
        load(text: text, folder: folder, title: title, meta: meta)
        let mapped = min(max(0, map(index)), storage.length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, mapped + 1)))
        setScrollTop(max(-topInset, yPosition(of: mapped) - offset))
    }

    func firstVisibleCharacter() -> Int {
        let visible = visibleRect
        let point = NSPoint(x: visible.minX + 1, y: max(0, visible.minY + topInset - textOrigin.y + 1))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    // MARK: - EditorLayoutSource

    func objectNeedsDisplay(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        layoutManager.invalidateDisplay(forCharacterRange: range)
    }

    func objectNeedsLayout(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        preservingScroll {
            layoutManager.invalidateLayout(forCharacterRange: nsText.lineRange(for: range), actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: nsText.lineRange(for: range))
        }
    }

    func noteText(for url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Selection and focus

    /// The selection moved: show the Markdown next to the caret, follow a link being typed.
    func selectionChanged() {
        flushGlyphs()
        if !isLoading { caretWasPlaced = true }
        layoutManager.selectedRanges = selectedRanges
        // The #s typed on a touch keyboard go once the caret is on another line.
        if let typed = typedHeading, document.lines.isEmpty || document.lines[document.lineIndex(containing: selection.location)].range.location != typed {
            typedHeading = nil
        }
        if !isTracking { updateReveal() }
        updateSuggestions()
        textNeedsDisplay()
        // The heading's level tag follows the caret, whether or not its #s show.
        marginNeedsDisplay()
        updateCaretContext()
    }

    func textChanged() {
        guard !isLoading else { return }
        flushGlyphs()
        // An edit that didn't move the caret: the marks it showed or hid fold in or out now.
        if editedMarks != nil, !isTracking { updateReveal() }
        delegate?.editorTextDidChange(self)
        updateSuggestions()
        updateCaretContext()
        // A change from another device, or an undo, may have moved the drawings or taken one away.
        if isDrawing { DispatchQueue.main.async { [weak self] in self?.updateDrawingCanvases() } }
    }

    func mouseTrackingEnded() {
        layoutManager.selectedRanges = selectedRanges
        updateReveal()
    }

    func focusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let focused = self.isFocused
            if !focused { self.unwrapped = nil }
            if self.isTypingIn != focused { self.readForTyping(focused) }
            self.updateReveal()
            if !focused { self.closeSuggestions() }
            self.updateCaretContext()
        }
    }

    /// Reads the note again for typing in it or for reading it, and styles the lines that read differently now.
    private func readForTyping(_ typing: Bool) {
        isTypingIn = typing
        guard !isLoading else { return }
        let old = document
        document = MarkdownParser.parse(storage.mutableString, typing: typing)
        let changed = document.lines.indices.filter { $0 >= old.lines.count || old.lines[$0].spans != document.lines[$0].spans }
        if !changed.isEmpty { restyle(lines: changed) }
    }

    /// The title field was left: its text becomes the note's name.
    func commitTitle() {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        delegate?.editor(self, commitTitle: title)
    }

    // MARK: - Caret

    /// The caret drawn from the baseline up to the top of the text, rather than over the whole line.
    func caretRect(proposed rect: NSRect) -> NSRect {
        let selection = self.selection
        guard selection.length == 0, storage.length > 0, let line = caretLine(of: selection.location, at: rect.midY) else {
            return shortCaret(rect, line: rect, font: EditorStyle.body)
        }
        let index = selection.location
        guard let character = line.character else {
            // An empty line: the caret where its text will go.
            return shortCaret(rect, line: line.used, font: index < storage.length ? font(at: index) : EditorStyle.body)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // The glyph's location is already raised by the line's baseline offset: taking it off again put the caret
        // two points above the text.
        let baseline = textOrigin.y + fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        return caret(rect, baseline: baseline, font: font(at: character))
    }

    /// The line the caret is on: the part of it its text takes, without the spacing around it, and the character the
    /// caret takes its height from, the nearest one shown on the line, the one after the caret first. Line breaks and
    /// hidden Markdown aren't laid out on the baseline, and an empty line has none.
    private func caretLine(of index: Int, at y: CGFloat) -> (used: NSRect, character: Int?)? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y - textOrigin.y), in: container)
        var glyphs = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        guard y >= textOrigin.y + line.minY, y < textOrigin.y + line.maxY else {
            // Below the last line, on the empty one after a final line break.
            guard layoutManager.extraLineFragmentTextContainer != nil else { return nil }
            return (layoutManager.extraLineFragmentUsedRect.offsetBy(dx: textOrigin.x, dy: textOrigin.y), nil)
        }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: textOrigin.x, dy: textOrigin.y)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caret = min(max(index, characters.location), NSMaxRange(characters))
        let after = caret..<NSMaxRange(characters)
        let nearest = Array(after.prefix(1)) + (characters.location..<caret).reversed() + after.dropFirst()
        return (used, nearest.first { nsText.character(at: $0) != 10 && !layoutManager.isHidden($0) })
    }

    private func font(at index: Int) -> NSFont {
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        return font.map { $0.pointSize < 4 ? EditorStyle.body : $0 } ?? EditorStyle.body
    }

    /// The caret where text in this font would sit on a line without any: TextKit puts the baseline the font's descent
    /// above the bottom of the line's text, and `EditorStyle.baselineOffset` lifts it from there. The rect UIKit
    /// proposes takes in the spacing around the line, so the line is the part its text takes.
    private func shortCaret(_ rect: NSRect, line: NSRect, font: NSFont) -> NSRect {
        #if os(macOS)
        // AppKit lays text out with the font's metrics rounded to whole points.
        let descent = layoutManager.defaultLineHeight(for: font) - layoutManager.defaultBaselineOffset(for: font)
        #else
        let descent = -font.descender
        #endif
        let baseline = line.maxY - descent - EditorStyle.baselineOffset(for: font, lineHeight: line.height)
        return caret(rect, baseline: baseline, font: font)
    }

    /// From a point above the font's ascender to a point below its descender.
    private func caret(_ rect: NSRect, baseline: CGFloat, font: NSFont) -> NSRect {
        fitted(NSRect(x: rect.minX, y: baseline - font.ascender - 1, width: rect.width, height: font.ascender - font.descender + 2), in: rect)
    }

    /// Kept inside the caret the text view proposed. On the Mac only that is redrawn when the caret blinks, so a caret
    /// reaching past it leaves a piece of itself on screen.
    private func fitted(_ caret: NSRect, in rect: NSRect) -> NSRect {
        let height = min(caret.height, rect.height)
        return NSRect(x: caret.minX, y: min(max(caret.minY, rect.minY), rect.maxY - height), width: caret.width, height: height)
    }
}

#if DEBUG
extension EditorController {
    /// Where the character after `index` is drawn on each of the next frames, and how far the marks before it show,
    /// to see marks fold in or out (`select` or a key right before it).
    func debugSampleFold(at index: Int, log: @escaping (String) -> Void) {
        var samples: [String] = []
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, index < self.storage.length else { return timer.invalidate() }
                self.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: index + 1))
                let glyph = self.layoutManager.glyphIndexForCharacter(at: index)
                let x = self.layoutManager.location(forGlyphAt: glyph).x
                let fade = index > 0 ? self.storage.attribute(.notebookFade, at: index - 1, effectiveRange: nil) as? CGFloat : nil
                samples.append(String(format: "%.0fms x %.1f%@", (CACurrentMediaTime() - start) * 1000, x, fade.map { String(format: " fade %.2f", $0) } ?? ""))
                if samples.count == 16 {
                    timer.invalidate()
                    log("fold " + samples.joined(separator: ", "))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The caret's line as it shows, for the debug remotes: hidden marks left out, marks folding in or out in braces, the
    /// caret as `|`, and what decides it.
    var debugSeenLine: String {
        guard !document.lines.isEmpty else { return "seen: (empty) title “\(titleText)” editingTitle \(isEditingTitle)" }
        let caret = selection.location
        let line = document.lines[document.lineIndex(containing: caret)]
        var seen = ""
        for index in line.range.location...line.range.upperBound {
            if index == caret { seen += "|" }
            guard index < line.range.upperBound else { break }
            let character = nsText.substring(with: NSRange(location: index, length: 1))
            if layoutManager.isHidden(index) { continue }
            seen += storage.attribute(.notebookFade, at: index, effectiveRange: nil) != nil ? "{\(character)}" : character
        }
        let tag = headingMarkLevel.map { "H\($0.level)" } ?? "none"
        return "seen: \(seen)  text: \(nsText.substring(with: line.range))  caret \(caret) marks \(showsMarks ? "shown" : "hidden") tag \(tag) typedHeading \(typedHeading.map(String.init) ?? "none") folding \(revealAnimator.isRunning) editingTitle \(isEditingTitle)"
    }
}
#endif

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
