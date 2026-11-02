#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

/// Every page of a PDF drawn on, small, side by side as Files shows files: drag a page to another place, touch and
/// hold one to duplicate or delete it, tap one to go to it. Undo and Redo go back through what was done here and while
/// drawing, as the tool picker's do.
struct PageOverview: View {
    let editing: PDFEditing

    var body: some View {
        NavigationStack {
            PageGrid(editing: editing)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(editing.pages.count == 1 ? "1 Page" : "\(editing.pages.count) Pages")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { editing.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .keyboardShortcut("z", modifiers: .command)
                            .disabled(!editing.canUndo)
                        Button { editing.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                            .disabled(!editing.canRedo)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .confirm) { editing.showsOverview = false }
                    }
                }
        }
    }
}

/// The grid of pages: UIKit's, which lifts a page and makes room for it as you drag it, as Files and Photos do.
private struct PageGrid: UIViewControllerRepresentable {
    let editing: PDFEditing

    func makeUIViewController(context: Context) -> PageGridController { PageGridController(editing: editing) }

    func updateUIViewController(_ controller: PageGridController, context: Context) {
        // Read here, so the grid follows every change: a page moved, added or taken out, Undo, a stroke undone.
        controller.show(editing.pages, revision: editing.revision, current: editing.pageIndex)
    }
}

@MainActor
private final class PageGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    private let pdf: PDFEditing
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ObjectIdentifier>!
    private var pages: [ObjectIdentifier: PDFPage] = [:]
    private var order: [ObjectIdentifier] = []
    private var current = 0
    /// How tall the room for each page is, for its width: as tall as the tallest page, so slides sit in a row of
    /// their own height and paper in one of its.
    private var aspect: CGFloat = 1.414
    /// The pictures of the pages drawn so far, with what they show (their page's revision) and how wide they are.
    private var thumbnails: [ObjectIdentifier: (image: UIImage, revision: Int, width: CGFloat)] = [:]
    private var waiting: [ObjectIdentifier] = []
    private var isDrawing = false
    private var hasScrolled = false

    init(editing: PDFEditing) {
        self.pdf = editing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "All Pages"
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        // Also on the iPhone, where dragging is off unless asked for.
        collectionView.dragInteractionEnabled = true
        collectionView.reorderingCadence = .fast
        view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<PageCell, ObjectIdentifier> { [weak self] cell, indexPath, id in
            self?.configure(cell, id: id, index: indexPath.item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        // A page dropped in another place: the grid has moved it, and the PDF follows.
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in (self?.order.count ?? 0) > 1 }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            var from: Int?, to: Int?
            for change in transaction.difference {
                switch change {
                case .remove(let offset, _, _): from = offset
                case .insert(let offset, _, _): to = offset
                }
            }
            self.order = transaction.finalSnapshot.itemIdentifiers
            guard let from, let to, from != to else { return }
            self.pdf.movePage(at: from, to: to)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The page in view, where the overview opens.
        guard !hasScrolled, collectionView.bounds.height > 0, current < order.count else { return }
        hasScrolled = true
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: current, section: 0), at: .centeredVertically, animated: false)
    }

    /// As many columns as fit pages about as wide as Files' icons, a little wider on the iPad.
    private func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            let compact = environment.traitCollection.horizontalSizeClass == .compact
            let margin: CGFloat = compact ? 20 : 28, spacing: CGFloat = compact ? 16 : 24, smallest: CGFloat = compact ? 96 : 160
            let width = environment.container.effectiveContentSize.width - 2 * margin
            let columns = max(2, Int((width + spacing) / (smallest + spacing)))
            let itemWidth = ((width - CGFloat(columns - 1) * spacing) / CGFloat(columns)).rounded(.down)
            let height = (itemWidth * (self?.aspect ?? 1.414)).rounded() + PageCell.labelRoom
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(itemWidth), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                                                           repeatingSubitem: item, count: columns)
            group.interItemSpacing = .flexible(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: spacing, leading: margin, bottom: spacing + 20, trailing: margin)
            return section
        }
    }

    // MARK: - Pages

    func show(_ pages: [PDFPage], revision: Int, current: Int) {
        loadViewIfNeeded()
        let ids = pages.map(ObjectIdentifier.init)
        self.pages = Dictionary(zip(ids, pages)) { first, _ in first }
        self.current = current
        let tallest = pages.map { page -> CGFloat in
            let box = page.bounds(for: .cropBox)
            return box.width > 0 ? box.height / box.width : 1.414
        }.max() ?? 1.414
        let aspect = min(max(tallest, 0.5), 1.6)
        if abs(aspect - self.aspect) > 0.001 {
            self.aspect = aspect
            collectionView.collectionViewLayout.invalidateLayout()
        }
        order = ids
        thumbnails = thumbnails.filter { self.pages[$0.key] != nil }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ObjectIdentifier>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // The numbers, the page in view and the pictures of pages changed.
        snapshot.reconfigureItems(ids)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func configure(_ cell: PageCell, id: ObjectIdentifier, index: Int) {
        guard let page = pages[id] else { return }
        cell.show(number: index + 1, of: order.count, pageSize: page.bounds(for: .cropBox).size, isCurrent: index == current)
        let thumbnail = thumbnails[id]
        cell.picture.image = thumbnail?.image
        if thumbnail?.revision != pdf.session?.revision(of: page) || (thumbnail?.width ?? 0) < cell.bounds.width - 1 {
            draw(id)
        }
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move Earlier") { [weak self] _ in self?.move(id, by: -1) ?? false },
            UIAccessibilityCustomAction(name: "Move Later") { [weak self] _ in self?.move(id, by: 1) ?? false },
            UIAccessibilityCustomAction(name: "Duplicate") { [weak self] _ in
                self?.duplicate(id)
                return true
            },
            UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in
                self?.delete(id)
                return true
            },
        ]
    }

    /// Draws the pictures of the pages asked for, one at a time, those still on the screen.
    private func draw(_ id: ObjectIdentifier) {
        if !waiting.contains(id) { waiting.append(id) }
        guard !isDrawing else { return }
        isDrawing = true
        Task { @MainActor [weak self] in
            while let self, !self.waiting.isEmpty {
                let id = self.waiting.removeFirst()
                guard let page = self.pages[id], let session = self.pdf.session, let indexPath = self.dataSource.indexPath(for: id),
                      let cell = self.collectionView.cellForItem(at: indexPath) as? PageCell else { continue }
                let width = max(cell.bounds.width, 60), revision = session.revision(of: page)
                guard let image = await session.thumbnail(of: page, width: width, scale: self.traitCollection.displayScale) else { continue }
                self.thumbnails[id] = (image, revision, width)
                if let indexPath = self.dataSource.indexPath(for: id), let cell = self.collectionView.cellForItem(at: indexPath) as? PageCell {
                    cell.picture.image = image
                }
            }
            self?.isDrawing = false
        }
    }

    private func index(of id: ObjectIdentifier) -> Int? { order.firstIndex(of: id) }

    private func move(_ id: ObjectIdentifier, by offset: Int) -> Bool {
        guard let index = index(of: id), order.indices.contains(index + offset) else { return false }
        pdf.movePage(at: index, to: index + offset)
        return true
    }

    private func duplicate(_ id: ObjectIdentifier) {
        guard let index = index(of: id) else { return }
        pdf.duplicatePage(at: index)
    }

    private func delete(_ id: ObjectIdentifier) {
        guard let index = index(of: id), order.count > 1 else { return }
        pdf.deletePage(at: index)
    }

    // MARK: - Tapping and touching and holding

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        pdf.goToPage(at: indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let duplicate = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in self?.duplicate(id) }
            var deleting: UIMenuElement.Attributes = .destructive
            if (self?.order.count ?? 0) < 2 { deleting.insert(.disabled) }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: deleting) { _ in self?.delete(id) }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [duplicate]), delete])
        }
    }

    /// The page alone lifts, without its number.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        pagePreview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        pagePreview(at: indexPath)
    }

    private func pagePreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? PageCell else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.paper.bounds, cornerRadius: PageCell.cornerRadius)
        return UITargetedPreview(view: cell.paper, parameters: parameters)
    }

    // MARK: - Dragging

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? PageCell else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.paper.frame, cornerRadius: PageCell.cornerRadius)
        return parameters
    }

    /// Pages move within the grid only.
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard collectionView.hasActiveDrag, session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// The data source moves the page itself (its reordering handlers), and tells the PDF.
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {}
}

/// A page: its picture on white, as paper, with a shadow, and its number under it, as Files puts a name under a file.
private final class PageCell: UICollectionViewCell {
    static let labelRoom: CGFloat = 30
    static let cornerRadius: CGFloat = 3
    let paper = UIView()
    let picture = UIImageView()
    private let ring = UIView()
    private let number = UILabel()
    private var pageSize = CGSize(width: 1, height: 1.414)

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.backgroundColor = .white
        paper.layer.cornerRadius = Self.cornerRadius
        paper.layer.cornerCurve = .continuous
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.18
        paper.layer.shadowRadius = 3
        paper.layer.shadowOffset = CGSize(width: 0, height: 1)
        paper.layer.borderColor = UIColor.separator.cgColor
        picture.contentMode = .scaleAspectFit
        picture.layer.cornerRadius = Self.cornerRadius
        picture.layer.cornerCurve = .continuous
        picture.clipsToBounds = true
        picture.accessibilityIgnoresInvertColors = true
        paper.addSubview(picture)
        ring.isUserInteractionEnabled = false
        ring.layer.borderWidth = 3
        ring.layer.cornerRadius = Self.cornerRadius + 4
        ring.layer.cornerCurve = .continuous
        number.adjustsFontForContentSizeCategory = true
        number.textAlignment = .center
        contentView.addSubview(ring)
        contentView.addSubview(paper)
        contentView.addSubview(number)
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: PageCell, _) in cell.updateColors() }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(number: Int, of count: Int, pageSize: CGSize, isCurrent: Bool) {
        self.number.text = "\(number)"
        self.pageSize = pageSize.width > 0 && pageSize.height > 0 ? pageSize : CGSize(width: 1, height: 1.414)
        ring.isHidden = !isCurrent
        self.number.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular))
        self.number.textColor = isCurrent ? tintColor : .secondaryLabel
        accessibilityLabel = "Page \(number) of \(count)"
        accessibilityValue = isCurrent ? "In view" : nil
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        ring.layer.borderColor = tintColor.cgColor
        if !ring.isHidden { number.textColor = tintColor }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        picture.image = nil
    }

    override var isHighlighted: Bool {
        didSet { paper.alpha = isHighlighted ? 0.7 : 1 }
    }

    /// Dark Mode keeps the page white; a thin edge sets it off the dark behind it, where a shadow doesn't show.
    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        paper.layer.shadowOpacity = dark ? 0 : 0.18
        paper.layer.borderWidth = dark ? 1 / max(traitCollection.displayScale, 1) : 0
        ring.layer.borderColor = tintColor.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The page as large as fits the room above the number, standing on the same line as the others in its row.
        let room = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.labelRoom)
        let scale = min(room.width / pageSize.width, room.height / pageSize.height)
        let size = CGSize(width: (pageSize.width * scale).rounded(), height: (pageSize.height * scale).rounded())
        paper.frame = CGRect(x: ((room.width - size.width) / 2).rounded(), y: room.maxY - size.height, width: size.width, height: size.height)
        paper.layer.shadowPath = UIBezierPath(roundedRect: paper.bounds, cornerRadius: Self.cornerRadius).cgPath
        picture.frame = paper.bounds
        ring.frame = paper.frame.insetBy(dx: -5, dy: -5)
        number.frame = CGRect(x: 0, y: room.maxY + 6, width: bounds.width, height: Self.labelRoom - 6)
    }
}
#endif
