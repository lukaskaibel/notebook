import QuickLookThumbnailing
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The first screen on the iPhone and the sidebar on iPad and Mac are made of the same pieces, as Reminders' tiles and
// Notes' folders are the same on each device: To-dos and Favorites as tiles, what you opened last as cards with a
// picture of each file, and how much is in each folder.

/// Sizes and colours of the tiles and cards: the iPhone's and the iPad's, on their grouped grey, and the Mac's, smaller
/// and on the sidebar's material.
enum HomeStyle {
    #if os(macOS)
    static let cardFill = Color.primary.opacity(0.06)
    /// Under a tile or card under the pointer, its own fill and this one make it a shade darker, as a sidebar row under
    /// the pointer is.
    static let cardHoverFill = Color.primary.opacity(0.05)
    static let tileRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let pictureRadius: CGFloat = 6
    /// A card's picture where the card has a width of its own (Favorites on the Mac); in Recent it is as wide as a tile.
    static let picture = CGSize(width: 104, height: 78)
    /// Inside a tile or card, from its edge to what is in it: on the Mac's sidebar the tiles' symbols and the cards'
    /// pictures are then in line with Search's magnifying glass and the folders' chevrons.
    static let cardPadding: CGFloat = 6
    /// The pictures of files are made this wide and drawn at the card's width, which follows the sidebar's.
    static let thumbnailSize = CGSize(width: 160, height: 120)
    #else
    static let cardFill = Color(.secondarySystemGroupedBackground)
    static let tileRadius: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let pictureRadius: CGFloat = 12
    static let picture = CGSize(width: 128, height: 96)
    static let cardPadding: CGFloat = 8
    static let thumbnailSize = CGSize(width: 200, height: 150)
    #endif
    /// Favorites' orange, the star's colour where you swipe to add one.
    static let favoritesColor = Color.theme(.systemOrange)
    /// Between the tiles, and between Recent's cards, which are as wide as the tiles: the second card under Favorites.
    static let spacing: CGFloat = {
        #if os(macOS)
        6
        #else
        12
        #endif
    }()
}

/// A tile or card under the pointer shows it by itself, not the row it is in: on the Mac a darker fill, while the window
/// is in front, as other hover effects on the Mac; on iPad the pointer takes its shape.
private struct HomeHover: ViewModifier {
    let shape: RoundedRectangle
    var isSelected = false
    #if os(macOS)
    @State private var isHovered = false
    @Environment(\.controlActiveState) private var activeState
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background {
                if isHovered, !isSelected, activeState == .key { shape.fill(HomeStyle.cardHoverFill) }
            }
            .onHover { isHovered = $0 }
        #else
        content
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #endif
    }
}

/// A tile: its symbol in a circle of its colour, the count across from it, the name below. Selected, on iPad and Mac
/// where what it shows is next to the sidebar, it takes its colour, as in Reminders.
struct HomeTileLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
    var isSelected = false

    #if os(macOS)
    private static let circle: CGFloat = 24
    private static let symbolSize: CGFloat = 12
    private static let countFont = Font.system(.title3, design: .rounded, weight: .bold)
    private static let titleFont = Font.callout.weight(.semibold)
    private static let padding = EdgeInsets(top: 8, leading: HomeStyle.cardPadding, bottom: 8, trailing: HomeStyle.cardPadding)
    #else
    private static let circle: CGFloat = 30
    private static let symbolSize: CGFloat = 15
    private static let countFont = Font.system(.title2, design: .rounded, weight: .bold)
    private static let titleFont = Font.subheadline.weight(.semibold)
    private static let padding = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HomeStyle.tileRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: Self.symbolSize, weight: .semibold))
                    .foregroundStyle(isSelected ? color : .white)
                    .frame(width: Self.circle, height: Self.circle)
                    .background(Circle().fill(isSelected ? .white : color))
                Spacer(minLength: 4)
                Text(count, format: .number)
                    .font(Self.countFont)
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            Text(title)
                .font(Self.titleFont)
                .foregroundStyle(isSelected ? .white : .secondary)
                .lineLimit(1)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? color : HomeStyle.cardFill, in: shape)
        .modifier(HomeHover(shape: shape, isSelected: isSelected))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(title == "To-dos" ? "\(count) due" : "\(count)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The two tiles side by side, as the iPad and the Mac show them at the top of the sidebar: a click shows To-dos or
/// your favourites next to it. Favorites is there before anything is starred too, and says how to star something.
struct HomeTileGrid: View {
    let workspace: Workspace

    var body: some View {
        let showsTodos = NotebookSettings.shared.showsTodos
        Grid(horizontalSpacing: HomeStyle.spacing) {
            GridRow {
                if showsTodos {
                    Button { workspace.showTodos() } label: {
                        HomeTileLabel(title: "To-dos", symbol: "checklist", color: .accentColor, count: workspace.dueTodoCount,
                                      isSelected: workspace.showsTodos)
                    }
                    .buttonStyle(.plain)
                }
                Button { workspace.showFavorites() } label: {
                    HomeTileLabel(title: "Favorites", symbol: "star.fill", color: HomeStyle.favoritesColor, count: workspace.favoriteURLs.count,
                                  isSelected: workspace.showsFavorites)
                }
                .buttonStyle(.plain)
                // One tile takes half the row, as one of two would.
                if !showsTodos { Color.clear.gridCellUnsizedAxes(.vertical) }
            }
        }
    }
}

/// A card of Recent: a picture of the file's top, so you see what you were working on, its name, and the folder it is
/// in, quieter. `width` is the whole card's; the picture keeps its shape.
struct RecentCardLabel: View {
    let workspace: Workspace
    let url: URL
    var width: CGFloat = HomeStyle.picture.width + 2 * HomeStyle.cardPadding
    @Environment(\.displayScale) private var scale

    #if os(macOS)
    private static let nameFont = Font.callout.weight(.semibold)
    #else
    private static let nameFont = Font.subheadline.weight(.semibold)
    #endif

    var body: some View {
        // The picture says what kind of file it is: the name goes without its extension, a PDF's as a note's.
        let name = url.deletingPathExtension().lastPathComponent
        let folder = workspace.folderName(url.deletingLastPathComponent())
        let shape = RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            let picture = HomeStyle.picture(width: width - 2 * HomeStyle.cardPadding)
            FileThumbnailView(workspace: workspace, url: url, shownSize: picture, scale: scale)
                .frame(width: picture.width, height: picture.height)
                .padding(.bottom, 6)
            Text(name)
                .font(Self.nameFont)
                .lineLimit(1)
            Text(folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width - 2 * HomeStyle.cardPadding, alignment: .leading)
        .padding(HomeStyle.cardPadding)
        .background(HomeStyle.cardFill, in: shape)
        .modifier(HomeHover(shape: shape))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint("In \(folder)")
        .accessibilityAddTraits(.isButton)
    }
}

/// What you opened last, as cards in a row that scrolls sideways, as the iPad and the Mac show them in the sidebar: a
/// click opens one next to it, and the card stays where it is until a moment after the pointer has left the row. Each
/// card is as wide as a tile, so two sit under To-dos and Favorites and the third peeks in at the edge; the row stops
/// at a card each time it is scrolled.
struct RecentCardRow: View {
    let workspace: Workspace
    /// From the row's edges to the tiles' column, where the cards stop: the Mac's row runs the sidebar's whole width.
    var margin: CGFloat = 0
    /// Asks for the name of a new folder, from a card's menu.
    var newFolder: ((URL) -> Void)?
    /// The row's width, which the cards' follows.
    @State private var rowWidth = HomeStyle.likelyRowWidth

    var body: some View {
        let recents = Array(workspace.recentCardURLs.prefix(RecentCardRow.limit))
        let cardWidth = HomeStyle.tileWidth(in: rowWidth - 2 * margin)
        ScrollView(.horizontal) {
            // Not lazy: eight cards at most, and each keeps its view as the row reorders, so it slides to its place.
            HStack(alignment: .top, spacing: HomeStyle.spacing) {
                ForEach(recents, id: \.self) { url in
                    Button { workspace.open(url) } label: { RecentCardLabel(workspace: workspace, url: url, width: cardWidth) }
                        .buttonStyle(.plain)
                        .clearsCardsBeneath()
                        .appContextMenu(cornerRadius: HomeStyle.cardRadius) { RecentCardMenu.entries(workspace, url, newFolder: newFolder) }
                        .zIndex(HomeStyle.zIndex(of: url, in: recents))
                }
            }
            .scrollTargetLayout()
            .cardsClearEachOther()
            .animation(HomeStyle.reordering, value: recents)
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        // The cards keep their order while the pointer is on them (`Workspace.holdRecentCards`).
        .onHover { workspace.holdRecentCards($0) }
        .onDisappear { workspace.holdRecentCards(false) }
    }

    /// As many as a few swipes go through.
    static let limit = 8
}

extension HomeStyle {
    /// A file you opened moves to the front of Recent a moment later: its card slides there over the others, which make
    /// way for it, as two cards trading places would.
    static let reordering = Animation.spring(duration: 0.6, bounce: 0.15)

    /// Recent's row before it has been measured: about as wide as the Mac's sidebar or an iPhone's list.
    static let likelyRowWidth: CGFloat = {
        #if os(macOS)
        250
        #else
        370
        #endif
    }()

    /// A tile's width, and so a card's of Recent, in a row `width` wide: half of it less half the space between.
    static func tileWidth(in width: CGFloat) -> CGFloat {
        max(60, (width - spacing) / 2)
    }

    /// A card's picture `width` wide, in the shape of the pictures everywhere (4 : 3).
    static func picture(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * picture.height / picture.width).rounded())
    }

    /// The front card above the others, so the one going there passes over them.
    static func zIndex(of url: URL, in cards: [URL]) -> Double {
        url == cards.first ? 1 : 0
    }
}

extension View {
    /// On the Mac a card's fill lets the sidebar through, and would let the card it passes over through as Recent
    /// reorders: the card first clears what is under it in its row (`cardsClearEachOther`), so it covers the other as
    /// an iPhone's or iPad's card, which is opaque, does.
    func clearsCardsBeneath() -> some View {
        #if os(macOS)
        background {
            RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous)
                .fill(.black)
                .blendMode(.destinationOut)
        }
        #else
        self
        #endif
    }

    /// The row in which cards clear what is under them: drawn as one layer, so a card clears only the cards before it,
    /// not the sidebar.
    func cardsClearEachOther() -> some View {
        #if os(macOS)
        compositingGroup()
        #else
        self
        #endif
    }
}

/// A card's menu: the file's own, as its row has it.
@MainActor
private enum RecentCardMenu {
    static func entries(_ workspace: Workspace, _ url: URL, newFolder: ((URL) -> Void)?) -> [MenuEntry] {
        #if os(iOS)
        FileActions.entries(workspace, url, newFolder: newFolder)
        #else
        [
            MenuEntry("Open", "arrow.up.forward.app") { workspace.open(url) },
            MenuEntry("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
        ]
        #endif
    }
}

/// A file's picture, filling its frame from the top: until it is made, a white page with the file's symbol. Made at
/// one size (`HomeStyle.thumbnailSize`) and drawn at the frame's, so resizing the sidebar doesn't make it again.
struct FileThumbnailView: View {
    let workspace: Workspace
    let url: URL
    /// The frame it fills.
    let shownSize: CGSize
    let scale: CGFloat
    @State private var image: CGImage?
    private var size: CGSize { HomeStyle.thumbnailSize }

    var body: some View {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isFolder {
            folder
        } else {
            page
        }
    }

    /// A favourite folder: its symbol or emoji in its colour, as the sidebar shows it, large.
    private var folder: some View {
        let look = workspace.folderIcon(for: url)
        return ZStack {
            RoundedRectangle(cornerRadius: HomeStyle.pictureRadius, style: .continuous).fill(.quaternary)
            if let emoji = look?.emoji {
                Text(emoji).font(.system(size: 36))
            } else {
                Image(systemName: look.flatMap { $0.symbol == nil ? nil : $0.shownSymbol } ?? "folder")
                    .font(.system(size: 34))
                    .foregroundStyle(look?.color?.color ?? Color.theme(FileKind.folder.tint))
            }
        }
    }

    private var page: some View {
        let key = FileThumbnails.Key(path: url.standardizedFileURL.path, modified: workspace.index.entry(for: url)?.modified, width: size.width)
        let shape = RoundedRectangle(cornerRadius: HomeStyle.pictureRadius, style: .continuous)
        return ZStack(alignment: .top) {
            // A page is white, as thumbnails are in either appearance.
            Color.white
            if let image = image ?? FileThumbnails.shared.cached(key) {
                Image(decorative: image, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: shownSize.width, height: shownSize.height, alignment: .top)
            } else {
                Image(systemName: FileKind(url: url, isDirectory: false).symbol)
                    .font(.title2)
                    .foregroundStyle(Color(white: 0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 1 / scale))
        .task(id: key) {
            image = await FileThumbnails.shared.image(for: url, key: key, size: size, scale: scale)
        }
    }
}

/// Pictures of files for the cards of Recent: the top of a note as the Finder and the Files app show it (NoteThumbnail,
/// which draws it as the app does), and anything else as Quick Look draws it, off the main thread: a PDF's first page,
/// a picture itself. Made once for each version of a file, and kept while the app runs.
@MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()

    /// A file as it was when it was pictured (`modified` as search last read it), at one width.
    struct Key: Hashable {
        let path: String
        let modified: Date?
        let width: CGFloat
    }

    private var images: [Key: CGImage] = [:]
    private var making: [Key: Task<CGImage?, Never>] = [:]
    /// The last note's picture asked for: the next waits for it.
    private var notes: Task<Void, Never>?

    func cached(_ key: Key) -> CGImage? { images[key] }

    func image(for url: URL, key: Key, size: CGSize, scale: CGFloat) async -> CGImage? {
        if let image = images[key] { return image }
        if let task = making[key] { return await task.value }
        // A note's picture is laid out on the main thread, about 30 ms: one at a time, a frame apart, so a row of them
        // coming in never holds up scrolling.
        let isNote = FileKind(url: url, isDirectory: false) == .note
        let previous = isNote ? notes : nil
        let task = Task { () -> CGImage? in
            if let previous {
                await previous.value
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await Self.make(url, size: size, scale: scale)
        }
        if isNote { notes = Task { _ = await task.value } }
        making[key] = task
        let image = await task.value
        making[key] = nil
        if let image {
            // The picture of an older version goes.
            images = images.filter { $0.key.path != key.path || $0.key.width != key.width }
            images[key] = image
        }
        return image
    }

    private static func make(_ url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        if FileKind(url: url, isDirectory: false) == .note {
            // The page is as wide as the card, and as tall as a page that wide.
            let page = CGSize(width: size.width, height: (size.width * 1.3).rounded())
            // The app can read what is next to the note, as the Finder's thumbnails don't: its pictures show.
            return try? await NoteThumbnail.image(of: url, size: page, scale: scale, withPictures: true)
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size.width, height: size.width * 1.4), scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

extension Workspace {
    /// The folders in a folder as its list shows them, or nil until it has been read. Asks for no reading: the rows of
    /// folders read theirs ahead as they come on screen.
    func shownSubfolders(of folder: URL) -> [FileNode]? {
        shownChildrenIfRead(of: folder)?.filter(\.isFolder)
    }

    /// How many files and folders a folder's list shows, or nil until it has been read.
    func shownCount(of folder: URL) -> Int? {
        shownChildrenIfRead(of: folder)?.count
    }

    private func shownChildrenIfRead(of folder: URL) -> [FileNode]? {
        // On iPhone and iPad the lists watch this to show changes; the Mac's sidebar reloads its rows itself.
        #if os(iOS)
        _ = treeVersion
        #endif
        guard let node = node(for: folder, reading: false), node.hasLoadedChildren else { return nil }
        let children = shownChildren(of: node, in: location(containing: folder))
        return leaving.isEmpty ? children : children.filter { !isLeaving($0.url) }
    }
}
