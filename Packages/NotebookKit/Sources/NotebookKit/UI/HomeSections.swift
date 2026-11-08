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
    static let tileRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let pictureRadius: CGFloat = 6
    static let picture = CGSize(width: 104, height: 78)
    static let cardPadding: CGFloat = 6
    #else
    static let cardFill = Color(.secondarySystemGroupedBackground)
    static let tileRadius: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let pictureRadius: CGFloat = 12
    static let picture = CGSize(width: 128, height: 96)
    static let cardPadding: CGFloat = 8
    #endif
    static let spacing: CGFloat = {
        #if os(macOS)
        8
        #else
        12
        #endif
    }()
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
    private static let padding: CGFloat = 8
    #else
    private static let circle: CGFloat = 30
    private static let symbolSize: CGFloat = 15
    private static let countFont = Font.system(.title2, design: .rounded, weight: .bold)
    private static let titleFont = Font.subheadline.weight(.semibold)
    private static let padding: CGFloat = 12
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
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(title == "To-dos" ? "\(count) due" : "\(count)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The two tiles side by side, as the iPad and the Mac show them at the top of the sidebar: a click shows To-dos or
/// your favourites next to it. Favorites only once something is starred.
struct HomeTileGrid: View {
    let workspace: Workspace

    var body: some View {
        let showsTodos = NotebookSettings.shared.showsTodos
        let favorites = workspace.favoriteURLs.count
        if showsTodos || favorites > 0 {
            Grid(horizontalSpacing: HomeStyle.spacing) {
                GridRow {
                    if showsTodos {
                        Button { workspace.showTodos() } label: {
                            HomeTileLabel(title: "To-dos", symbol: "checklist", color: .accentColor, count: workspace.dueTodoCount,
                                          isSelected: workspace.showsTodos)
                        }
                        .buttonStyle(.plain)
                    }
                    if favorites > 0 {
                        Button { workspace.showFavorites() } label: {
                            HomeTileLabel(title: "Favorites", symbol: "star.fill", color: .orange, count: favorites,
                                          isSelected: workspace.showsFavorites)
                        }
                        .buttonStyle(.plain)
                    }
                    // One tile takes half the row, as one of two would.
                    if !showsTodos || favorites == 0 { Color.clear.gridCellUnsizedAxes(.vertical) }
                }
            }
        }
    }
}

/// A card of Recent: a picture of the file's top, so you see what you were working on, its name, and the folder it is
/// in, quieter.
struct RecentCardLabel: View {
    let workspace: Workspace
    let url: URL
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
            FileThumbnailView(workspace: workspace, url: url, size: HomeStyle.picture, scale: scale)
                .frame(width: HomeStyle.picture.width, height: HomeStyle.picture.height)
                .padding(.bottom, 6)
            Text(name)
                .font(Self.nameFont)
                .lineLimit(1)
            Text(folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: HomeStyle.picture.width, alignment: .leading)
        .padding(HomeStyle.cardPadding)
        .background(HomeStyle.cardFill, in: shape)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), in \(folder)")
        .accessibilityAddTraits(.isButton)
    }
}

/// What you opened last, as cards in a row that scrolls sideways, as the iPad and the Mac show them in the sidebar: a
/// click opens one next to it.
struct RecentCardRow: View {
    let workspace: Workspace
    var leadingInset: CGFloat = 0
    /// Asks for the name of a new folder, from a card's menu.
    var newFolder: ((URL) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: HomeStyle.spacing) {
                ForEach(Array(workspace.recentURLs(includingOpen: true).prefix(RecentCardRow.limit)), id: \.self) { url in
                    Button { workspace.open(url) } label: { RecentCardLabel(workspace: workspace, url: url) }
                        .buttonStyle(.plain)
                        .contextMenu { RecentCardMenu(workspace: workspace, url: url, newFolder: newFolder) }
                }
            }
            .padding(.horizontal, leadingInset)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    /// As many as a few swipes go through.
    static let limit = 8
}

/// A card's menu: the file's own, as its row has it.
private struct RecentCardMenu: View {
    let workspace: Workspace
    let url: URL
    var newFolder: ((URL) -> Void)?

    var body: some View {
        #if os(iOS)
        FileActions(workspace: workspace, url: url, newFolder: newFolder)
        #else
        Button("Open") { workspace.open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        #endif
    }
}

/// A file's picture, filling its frame from the top: until it is made, a white page with the file's symbol.
struct FileThumbnailView: View {
    let workspace: Workspace
    let url: URL
    let size: CGSize
    let scale: CGFloat
    @State private var image: CGImage?

    var body: some View {
        let key = FileThumbnails.Key(path: url.standardizedFileURL.path, modified: workspace.index.entry(for: url)?.modified, width: size.width)
        let shape = RoundedRectangle(cornerRadius: HomeStyle.pictureRadius, style: .continuous)
        ZStack(alignment: .top) {
            // A page is white, as thumbnails are in either appearance.
            Color.white
            if let image = image ?? FileThumbnails.shared.cached(key) {
                Image(decorative: image, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
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
            return try? await NoteThumbnail.image(of: url, size: page, scale: scale)
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
        _ = treeVersion
        guard let node = node(for: folder, reading: false), node.hasLoadedChildren else { return nil }
        let children = shownChildren(of: node, in: location(containing: folder))
        return leaving.isEmpty ? children : children.filter { !isLeaving($0.url) }
    }
}
