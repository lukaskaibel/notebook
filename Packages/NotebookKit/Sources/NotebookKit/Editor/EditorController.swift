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
}

public extension EditorControllerDelegate {
    func editorOutlineDidChange(_ editor: EditorController) {}
    func editorPositionDidChange(_ editor: EditorController) {}
    func editorEditingDidChange(_ editor: EditorController) {}
    func editorDrawingDidChange(_ editor: EditorController) {}
    func editorShowReminder(_ editor: EditorController) {}
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
    #endif

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
    /// Counts the notes loaded, so pictures that finish loading late go only into the note they were meant for.
    var loadCount = 0
    /// The editor's own record of changes, for undo (`EditorUndo+UIKit`).
    let undoStack = EditorUndoManager()
    var openStep: UndoStep?
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
        #if os(iOS)
        undoStack.clear()
        openStep = nil
        previousSelection = NSRange(location: 0, length: 0)
        layoutManager.selectedRanges = []
        loadCount += 1
        // Another note: the keyboard goes, unless this one asks for it below.
        pendingFocus = nil
        requestedFocus = nil
        if textView.isFirstResponder || textView.titleField.isFirstResponder { textView.endEditing(true) }
        #else
        textView.undoManager?.removeAllActions()
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
        let old = storage.string as NSString
        let new = text as NSString
        guard old as String != text else { return }
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
        preservingScroll {
            replace(range, with: replacement, select: caret, actionName: "Change from Another Device")
        }
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

    public func focusTitle() {
        makeTitleFirstResponder()
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
            styleAnimator.restyle(storage, edited: editedRange, scope: scope) {
                MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
                // The edit's own fixing ran before the styling, which undid it: an emoji got the text's font.
                storage.fixAttributes(in: scope)
            }
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
            hasher.combine(relative(item.markerRange)); hasher.combine(relative(item.prefix)); hasher.combine(item.checked)
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
        case .heading(_, let marker): ranges.append(marker)
        case .thematicBreak: ranges.append(line.range)
        default: break
        }
        for span in line.spans where !isAtomic(span) && span.range.touches(caret) {
            ranges.append(span.range)
        }
        return (merged(ranges), block)
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
        var low = 0, high = revealed.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = revealed[mid]
            if characterIndex < range.location { high = mid - 1 } else if characterIndex >= range.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }

    /// Shows the punctuation next to the caret and opens the block it is in, keeping the caret's line still on screen.
    func updateReveal(anchor: Int? = nil) {
        guard !isLoading, !isTracking else { return }
        let target = revealTarget()
        guard target.ranges != revealed || target.block != activeBlock else { return }
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
            for range in old + target.ranges where range.upperBound <= storage.length {
                let lineRange = nsText.lineRange(for: range)
                layoutManager.invalidateGlyphs(forCharacterRange: lineRange, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: lineRange, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: lineRange)
            }
        }
        // A heading's level tag is drawn in the margin, outside the text the layout manager invalidates.
        marginNeedsDisplay()
    }

    /// Runs a change that may make lines taller or shorter and scrolls so that the caret (or the top line, when the
    /// caret is off screen) stays exactly where it was on screen.
    func preservingScroll(anchor: Int? = nil, _ change: () -> Void) {
        guard isInWindow, storage.length > 0 else { change(); return }
        let visible = visibleRect
        var index = anchor ?? selection.location
        var y = yPosition(of: index)
        if anchor == nil, y < visible.minY + topInset || y > visible.maxY {
            index = firstVisibleCharacter()
            y = yPosition(of: index)
        }
        let before = y - visible.minY
        change()
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

    private func firstVisibleCharacter() -> Int {
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
        if !isTracking { updateReveal() }
        updateSuggestions()
        textNeedsDisplay()
        updateCaretContext()
    }

    func textChanged() {
        guard !isLoading else { return }
        flushGlyphs()
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

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
