import CoreGraphics

/// How the bar above the keyboard shares out its width: on the left the buttons for where the caret is, as many as
/// leave the tools room; then the capsule of tools, a page of them at a time, every tool as wide as the others; on the
/// right the button that hides the keyboard. Without UIKit, so it can be tried on the Mac too.
struct WritingBarLayout: Equatable {
    /// Room above the capsule, the capsule, and the gap between it and the keyboard: Notes' measures.
    static let topGap: CGFloat = 6
    static let barHeight: CGFloat = 48
    static let keyboardGap: CGFloat = 12
    static let height = topGap + barHeight + keyboardGap
    /// About a fingertip per tool; a page holds as many as fit.
    static let toolWidth: CGFloat = 53
    static let spacing: CGFloat = 8
    /// Between the buttons for where the caret is, close enough for their glass to flow together.
    static let caretSpacing: CGFloat = 6

    /// The bar spans the screen on an iPhone, less its margins; on a wider screen it stops at about ten tools.
    static func barWidth(for available: CGFloat) -> CGFloat {
        max(toolWidth, min(available - 24, 620))
    }

    /// How many of the buttons for the caret show, and how wide they are together.
    let caretCount: Int
    let caretWidth: CGFloat
    /// The capsule of tools.
    let toolsWidth: CGFloat
    let perPage: Int
    let pageCount: Int

    var slotWidth: CGFloat { toolsWidth / CGFloat(perPage) }

    init(width: CGFloat, caretTools: Int, tools: Int) {
        // Less the button that hides the keyboard.
        let full = Self.barWidth(for: width) - Self.barHeight - Self.spacing
        // As many as leave the tools room for two of theirs.
        let room = Int((full - 2 * Self.toolWidth - Self.spacing + Self.caretSpacing) / (Self.barHeight + Self.caretSpacing))
        caretCount = min(caretTools, max(0, room))
        caretWidth = caretCount == 0 ? 0 : CGFloat(caretCount) * (Self.barHeight + Self.caretSpacing) - Self.caretSpacing
        toolsWidth = full - (caretCount == 0 ? 0 : caretWidth + Self.spacing)
        perPage = max(1, Int(toolsWidth / Self.toolWidth))
        pageCount = max(1, (tools + perPage - 1) / perPage)
    }

    /// The page to show when the pages change, the one you were on while there is one.
    func page(_ page: Int) -> Int {
        min(max(0, page), pageCount - 1)
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// What the bar above the keyboard can hold. Which ones and in what order is yours to choose, in Settings › Writing
/// Bar.
enum WritingTool: String, CaseIterable, Identifiable {
    case format, checklist, attach, drawing, link, undo, redo
    case bold, italic, strikethrough, highlight, code, quote
    case bulletedList, numberedList, outdent, indent
    case camera, scanner, photos, files
    case reminder

    var id: Self { self }

    /// The bar as it comes: what Notes has first, then the formatting, then lists and pictures.
    static let standard: [WritingTool] = [
        .format, .checklist, .attach, .drawing, .link, .undo, .redo,
        .bold, .italic, .strikethrough, .highlight, .code, .quote,
        .bulletedList, .numberedList, .outdent, .indent, .camera, .scanner,
    ]

    var command: FormatCommand? {
        switch self {
        case .checklist: .checklist
        case .link: .link
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .highlight: .highlight
        case .code: .code
        case .quote: .quote
        case .bulletedList: .bulletedList
        case .numberedList: .numberedList
        case .outdent: .outdent
        case .indent: .indent
        default: nil
        }
    }

    var source: AttachmentSource? {
        switch self {
        case .camera: .camera
        case .scanner: .scanner
        case .photos: .photos
        case .files: .files
        default: nil
        }
    }

    var name: String {
        if let command { return command.name }
        if let source { return source.name }
        switch self {
        case .format: return "Format"
        case .attach: return "Attach"
        case .drawing: return "Drawing"
        case .undo: return "Undo"
        case .redo: return "Redo"
        default: return "Remind Me"
        }
    }

    var symbol: String {
        if let command { return command.symbol }
        if let source { return source == .files ? "folder" : source.symbol }
        switch self {
        case .format: return "textformat"
        case .attach: return "paperclip"
        case .drawing: return "pencil.tip.crop.circle"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        default: return "bell"
        }
    }

    /// The camera and the scanner only where there is a camera.
    var isAvailable: Bool { source?.isAvailable ?? true }
}

/// A button on the left of the bar for where the caret is: a style it is in (on, its glass tinted; a tap takes it
/// off), the to-do's reminder, moving its list item out or in, and opening the link it is on. As in Issues. A to-do is
/// ticked on its own checkbox, in the note.
enum CaretTool: CaseIterable, Identifiable {
    case bold, italic, strikethrough, highlight, code, remind, outdent, indent, openLink

    var id: Self { self }

    var style: MarkdownSyntax.Style? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .highlight: .highlight
        case .code: .code
        default: nil
        }
    }

    var name: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Code"
        case .remind: "Remind Me"
        case .outdent: "Outdent"
        case .indent: "Indent"
        case .openLink: "Open Link"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .remind: "bell"
        case .outdent: "decrease.indent"
        case .indent: "increase.indent"
        case .openLink: "arrow.up.right.square"
        }
    }

    /// No more than two, so the bar keeps room for its tools.
    static let limit = 2

    /// The buttons for a place in the text, in the order they stand in. When more would come, the link to open and the
    /// to-do's reminder go first, then the styles the caret is in, then moving the line in before moving it out.
    @MainActor
    static func tools(for caret: CaretContext) -> [CaretTool] {
        let context = caret.context
        var wanted: [CaretTool] = []
        if caret.link != nil { wanted.append(.openLink) }
        if context.isChecklist, NotebookSettings.shared.showsTodos { wanted.append(.remind) }
        wanted += allCases.filter { $0.style.map(context.styles.contains) ?? false }
        if context.canIndent { wanted.append(.indent) }
        if context.canOutdent { wanted.append(.outdent) }
        let chosen = wanted.prefix(limit)
        return allCases.filter(chosen.contains)
    }
}

/// The bar above the keyboard while you write, as in Notes: the tools float over the note in a capsule of glass, a
/// little above the keyboard, and the ones that don't fit wait on the next page. On the left, buttons for where the
/// caret is come and go, each a circle of glass of its own; on the right, always, the button that hides the keyboard.
@MainActor
final class WritingBar: UIView {
    static let topGap = WritingBarLayout.topGap
    static let barHeight = WritingBarLayout.barHeight
    static let keyboardGap = WritingBarLayout.keyboardGap
    static let height = WritingBarLayout.height
    static let spacing = WritingBarLayout.spacing
    static let caretSpacing = WritingBarLayout.caretSpacing

    static func barWidth(for available: CGFloat) -> CGFloat {
        WritingBarLayout.barWidth(for: available)
    }

    private let host: UIHostingController<WritingBarView>
    private weak var editor: EditorController?
    private let presence = WritingBarPresence()

    init(editor: EditorController) {
        self.editor = editor
        host = UIHostingController(rootView: WritingBarView(editor: editor, presence: presence))
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height))
        // As tall as it says it is, which is nothing while it steps aside.
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        // Touch and hold the bar to change it. SwiftUI's context menu doesn't come up in the keyboard's window.
        addInteraction(UIContextMenuInteraction(delegate: self))
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: HardwareKeyboard.didChange, object: nil)
        editor.textView.registerForTraitChanges([UITraitHorizontalSizeClass.self]) { [weak self] (_: UITextView, _) in self?.keyboardChanged() }
    }

    /// Put above the keyboard, now that the note has a window to know its width by, or taken away with it. The bar
    /// comes and goes as it is: its buttons for the caret change with a spring only once it has come up.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        presence.isSettled = false
        guard window != nil else { return }
        keyboardChanged()
        presence.arrivals += 1
        let arrival = presence.arrivals
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, window != nil, presence.arrivals == arrival else { return }
            presence.isSettled = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Typing on keys where the toolbar at the top has Format, Attach and Drawing, as on an iPad, the bar steps aside
    /// as Notes' does, and only the keyboard's own shortcuts stay. It is back with the touch keyboard.
    private(set) var isTucked = false {
        didSet {
            guard isTucked != oldValue else { return }
            invalidateIntrinsicContentSize()
            host.view.isHidden = isTucked
            guard !isTucked, window != nil else { return }
            // Back as the touch keyboard comes, fading in where it will be as the keyboard does on an iPad. This runs in
            // the keyboard's own animation, which would take the bar from shown to hidden as well.
            UIView.performWithoutAnimation { host.view.alpha = 0 }
            UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseInOut) { self.host.view.alpha = 1 }
        }
    }

    @objc private func keyboardChanged() {
        isTucked = HardwareKeyboard.shared.isInUse && editor?.textView.traitCollection.horizontalSizeClass == .regular
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: isTucked ? 0 : Self.height) }

    /// Only the capsule takes touches: the strip around it belongs to the note.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isTucked else { return false }
        let width = Self.barWidth(for: bounds.width)
        let capsule = CGRect(x: (bounds.width - width) / 2, y: Self.topGap, width: width, height: Self.barHeight)
        return capsule.insetBy(dx: -4, dy: -4).contains(point)
    }
}

extension WritingBar: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Edit Writing Bar…", image: UIImage(systemName: "slider.horizontal.3")) { _ in self?.editor?.editWritingBar() },
            ])
        })
    }

    /// The capsule lifts, not the strip around it.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        let width = Self.barWidth(for: bounds.width)
        let capsule = CGRect(x: (bounds.width - width) / 2, y: Self.topGap, width: width, height: Self.barHeight)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: capsule, cornerRadius: Self.barHeight / 2)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: parameters)
    }
}

extension EditorController {
    /// Settings › Writing Bar in a sheet over the note, from the bar's Edit button or touching and holding the bar.
    func editWritingBar() {
        guard let presenter = textView.window?.rootViewController?.topmostPresented else { return }
        let host = UIHostingController(rootView: NavigationStack {
            WritingBarSettings { [weak presenter] in presenter?.dismiss(animated: true) }
        })
        host.sheetPresentationController?.detents = [.medium(), .large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(host, animated: true)
    }
}

/// Whether the bar is up above the keyboard, rather than coming up with it or going away.
@MainActor
@Observable
final class WritingBarPresence {
    var isSettled = false
    @ObservationIgnored var arrivals = 0
}

struct WritingBarView: View {
    let editor: EditorController
    let presence: WritingBarPresence
    @State private var page = 0
    @State private var position = ScrollPosition(x: 0)

    var body: some View {
        GeometryReader { proxy in
            let wanted = CaretTool.tools(for: editor.caretContext)
            // The tools, and Edit after the last of them.
            let tools = NotebookSettings.shared.writingBarTools.filter(\.isAvailable).map(Optional.some) + [nil]
            let layout = WritingBarLayout(width: proxy.size.width, caretTools: wanted.count, tools: tools.count)
            let caretTools = Array(wanted.prefix(layout.caretCount))
            HStack(spacing: WritingBar.spacing) {
                if !caretTools.isEmpty {
                    GlassEffectContainer(spacing: WritingBar.caretSpacing) {
                        HStack(spacing: WritingBar.caretSpacing) {
                            ForEach(caretTools) { tool in
                                caretButton(tool)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            }
                        }
                    }
                    .frame(width: layout.caretWidth, height: WritingBar.barHeight)
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
                }
                self.tools(tools, layout: layout)
                HideKeyboardButton { editor.endEditing() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, WritingBar.topGap)
            .animation(!presence.isSettled || UIAccessibility.isReduceMotionEnabled ? nil : .spring(duration: Theme.keyboardBarSpring.duration, bounce: Theme.keyboardBarSpring.bounce), value: caretTools)
            // Pages as wide as the capsule is now, and fewer when the buttons for the caret take room: stay on the one
            // you were on.
            .onChange(of: layout) { _, layout in
                page = layout.page(page)
                position.scrollTo(x: CGFloat(page) * layout.toolsWidth)
            }
        }
    }

    /// The capsule of tools, a page at a time. One row of them, so a tool that moves to another page as the buttons
    /// for the caret come and go slides there rather than fading out on one page and in on the other.
    private func tools(_ tools: [WritingTool?], layout: WritingBarLayout) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    Group {
                        if let tool { button(tool) } else { editButton }
                    }
                    .frame(width: layout.slotWidth)
                }
            }
            // The last page as wide as the others, so it pages as they do.
            .frame(width: CGFloat(layout.pageCount) * layout.toolsWidth, alignment: .leading)
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Int.self) { geometry in
            Int((geometry.contentOffset.x / max(1, geometry.containerSize.width)).rounded())
        } action: { _, shown in
            page = shown
        }
        .scrollDisabled(layout.pageCount < 2)
        .frame(width: layout.toolsWidth, height: WritingBar.barHeight)
        .overlay(alignment: .bottom) {
            if layout.pageCount > 1 { dots(count: layout.pageCount) }
        }
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// A button for where the caret is, a circle of glass. A style the caret is in is on: the whole button is tinted,
    /// as Done is.
    private func caretButton(_ tool: CaretTool) -> some View {
        let isOn = tool.style != nil
        return Button { perform(tool) } label: {
            Image(systemName: tool == .remind && editor.caretContext.hasReminder ? "bell.fill" : tool.symbol)
                .writingBarSymbol()
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: WritingBar.barHeight, height: WritingBar.barHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(Color(Theme.accent)).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(tool.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func perform(_ tool: CaretTool) {
        if let style = tool.style { return editor.toggle(style) }
        switch tool {
        case .remind: editor.showTodoReminder(line: editor.document.lineIndex(containing: editor.selection.location))
        case .outdent: editor.indent(by: -1)
        case .indent: editor.indent(by: 1)
        case .openLink: if let link = editor.caretContext.link { editor.delegate?.editor(editor, open: link) }
        default: break
        }
    }

    /// Which page of tools this is, small at the capsule's lower edge.
    private func dots(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(index == page ? 0.5 : 0.15))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.bottom, 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func button(_ tool: WritingTool) -> some View {
        if tool == .attach {
            Menu {
                ForEach(AttachmentSource.available) { source in
                    Button { AttachmentPicker.shared.present(source, for: editor) } label: { Label(source.name, systemImage: source.symbol) }
                }
            } label: {
                icon(tool)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        } else {
            Button { perform(tool) } label: { icon(tool) }
                .buttonStyle(.plain)
        }
    }

    /// Which tools the bar has and in what order, as in Settings › Writing Bar.
    private var editButton: some View {
        Button { editor.editWritingBar() } label: {
            Image(systemName: "slider.horizontal.3")
                .writingBarSymbol()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .accessibilityLabel("Edit Writing Bar")
        }
        .buttonStyle(.plain)
    }

    private func icon(_ tool: WritingTool) -> some View {
        Image(systemName: tool.symbol)
            .writingBarSymbol()
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .accessibilityLabel(tool.name)
    }

    private func perform(_ tool: WritingTool) {
        if let command = tool.command { return editor.perform(command) }
        if let source = tool.source { return AttachmentPicker.shared.present(source, for: editor) }
        switch tool {
        case .format: editor.toggleFormatPanel()
        case .drawing: editor.beginDrawing()
        case .undo: editor.textView.undoManager?.undo()
        case .redo: editor.textView.undoManager?.redo()
        case .reminder: editor.delegate?.editorShowReminder(editor)
        default: break
        }
    }
}

/// Hides the keyboard: a circle of glass of its own at the right end of a bar above the keyboard, there whatever else
/// the bar holds. In a note and in To-dos.
struct HideKeyboardButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.chevron.compact.down")
                .writingBarSymbol()
                .foregroundStyle(Color.primary)
                .frame(width: WritingBar.barHeight, height: WritingBar.barHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Hide Keyboard")
    }
}

extension Image {
    /// A symbol of a bar above the keyboard, as Notes draws its tools and as toolbars draw theirs: the size of the
    /// text, at the large scale.
    func writingBarSymbol() -> some View {
        font(.system(size: 17)).imageScale(.large)
    }
}
#endif
