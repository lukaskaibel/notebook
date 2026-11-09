#if os(macOS)
import AppKit
import SwiftUI

/// Your favourites on the Mac, from their tile at the top of the sidebar, in place of the note: notes and folders you
/// starred, in the order you starred them, as cards with a picture of each file's top, as Recent shows them. A click
/// opens one; a folder shows in the sidebar.
struct FavoritesPage: View {
    let workspace: Workspace

    var body: some View {
        let favorites = workspace.favoriteURLs
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Favorites")
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HomeStyle.picture.width + 2 * HomeStyle.cardPadding), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(favorites, id: \.self) { url in
                        Button { workspace.open(url) } label: {
                            RecentCardLabel(workspace: workspace, url: url)
                                .frame(width: HomeStyle.picture.width + 2 * HomeStyle.cardPadding)
                        }
                        .buttonStyle(.plain)
                        .appContextMenu {
                            MenuEntry("Open", "arrow.up.forward.app") { workspace.open(url) }
                            MenuEntry("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            MenuEntry.divider
                            MenuEntry("Remove from Favorites", "star.slash") { withAnimation { workspace.toggleFavorite(url) } }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if favorites.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Right-click a note or folder in the sidebar and choose Add to Favorites.")
                }
            }
        }
        .animation(.default, value: favorites)
    }
}
#endif
