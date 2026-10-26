#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The debug remote's commands for version history, the same on the Mac and on iPhone and iPad.
///
///     versions                the open note's versions as listed: when, on what, and how each begins
///     browseversions          Browse All Versions… on the Mac, Version History on iPhone and iPad
///     pickversion <n>         picks the nth version in the list, 0 the newest; the iPhone opens it
///     showchanges 1|0         Show Changes on or off
///     versionstate            what the versions show: the version picked, whether its text is in, the changes
///     restoreversion          Restore, as its button
///     closeversions           Done
///     revertlastopened        File › Revert To › Last Opened
@MainActor
enum DebugVersions {
    static func run(_ command: String, _ argument: String, workspace: Workspace, log: @escaping (String) -> Void) -> Bool {
        let browser = browser(workspace)
        switch command {
        case "versions":
            guard let url = workspace.note?.url else { log("versions: no note"); break }
            Task {
                let versions = await NoteHistory.shared.versions(of: url)
                var lines: [String] = []
                for version in versions {
                    let text = await NoteHistory.shared.text(of: version) ?? "?"
                    lines.append("\(version.url.lastPathComponent): \(text.prefix(48).replacingOccurrences(of: "\n", with: "⏎"))")
                }
                log("versions (\(versions.count)):\n" + lines.joined(separator: "\n"))
            }
        case "browseversions":
            workspace.browseVersions()
        case "pickversion":
            guard let browser, let index = Int(argument), let versions = browser.versions, versions.indices.contains(index) else { log("pickversion: none"); break }
            browser.selection = versions[index].url
            browser.path = [versions[index].url]
        case "showchanges":
            browser?.showsChanges = argument == "1"
        case "versionstate":
            guard let browser else { log("versionstate: no versions open"); break }
            let changes = browser.changes.map { "\($0.addedLines) added, \($0.removedLines) taken out, \($0.marks.count) marks" } ?? "off"
            log("versionstate: \(browser.versions?.count ?? -1) versions, picked \(browser.selected.map { VersionBrowser.rowTitle($0) } ?? "none"), "
                + "text \(browser.text.map { "in (\($0.count) characters)" } ?? "not in"), changes \(changes)")
        case "restoreversion":
            browser?.restore()
            close(workspace)
        case "closeversions":
            close(workspace)
        case "revertlastopened":
            workspace.revertToLastOpened()
        default:
            return false
        }
        return true
    }

    private static func browser(_ workspace: Workspace) -> VersionBrowser? {
        #if os(macOS)
        VersionsWindow.browser(over: workspace.editor.textView.window)
        #else
        workspace.versionBrowser
        #endif
    }

    private static func close(_ workspace: Workspace) {
        #if os(macOS)
        VersionsWindow.close(over: workspace.editor.textView.window)
        #else
        workspace.versionBrowser = nil
        #endif
    }
}
#endif
