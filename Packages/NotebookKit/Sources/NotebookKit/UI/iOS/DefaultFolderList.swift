#if os(iOS)
import SwiftUI

/// Settings' default folder on iPhone and iPad, chosen as Settings choose a default there: every folder of every
/// location, indented under its location as Move lists them, the one chosen ticked. Choosing one goes back.
struct DefaultFolderList: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chosen = workspace.defaultFolder
        List {
            ForEach(workspace.defaultFolderChoices, id: \.location.id) { target in
                Section(target.location.name) {
                    ForEach(target.folders, id: \.url) { folder in
                        let isChosen = chosen.map { FileNode.samePath($0, folder.url) } ?? false
                        Button {
                            workspace.chooseDefaultFolder(folder.url)
                            dismiss()
                        } label: {
                            HStack {
                                Label {
                                    Text(folder.depth < 0 ? target.location.name : folder.name)
                                } icon: {
                                    Image(systemName: folder.depth >= 0 ? "folder" : target.location.isICloudDrive ? "icloud" : "externaldrive")
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.leading, CGFloat(max(0, folder.depth)) * 18)
                                Spacer()
                                if isChosen {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("Default Folder")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
