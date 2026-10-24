#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreSpotlight
import Synchronization
import SwiftUI

/// The notes in Spotlight (`SpotlightIndex`), and opening the one picked there.
extension Workspace {
    /// Spotlight gets the notes of your locations; those of a folder given on the command line only when asked
    /// (`-NotebookSpotlight YES`), so tests and the sample notes leave your Spotlight alone. Its index is a named one of
    /// its own for such a folder, as the search index is. What Spotlight has is written down in Application Support,
    /// which the system doesn't empty as it empties caches: without it every note goes to Spotlight again.
    func startSpotlight() {
        if spotlight == nil {
            guard !temporaryLocations || UserDefaults.standard.bool(forKey: "NotebookSpotlight"),
                  let record = SearchIndex.storeURL(library: temporaryLocations ? locations.first?.url.path : nil, name: "Spotlight",
                                                    in: .applicationSupportDirectory) else { return }
            spotlight = SpotlightIndex(store: CoreSpotlightStore(name: record.lastPathComponent), recordURL: record)
        }
        // Only once every file has been read since launch: a note not read yet would be taken out of Spotlight.
        spotlight?.source = { [weak self] in
            guard let self, index.hasBuilt, !index.isBuilding else { return nil }
            return SpotlightIndex.Snapshot(entries: index.byPathSnapshot, hidden: allHiddenFolderPaths, locations: locations)
        }
    }

    /// A note picked in Spotlight, or the words of its Search in App, handed over by the system; false for anything
    /// else.
    @discardableResult
    public func continueActivity(_ activity: NSUserActivity) -> Bool {
        switch activity.activityType {
        case CSSearchableItemActionType:
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
            openSpotlightItem(identifier)
        case CSQueryContinuationActionType:
            guard let query = activity.userInfo?[CSSearchQueryString] as? String else { return false }
            searchFromSpotlight(query)
        default:
            return false
        }
        return true
    }

    /// Opens the note picked in Spotlight, once the locations can be reached: the pick can be what started the app.
    public func openSpotlightItem(_ identifier: String) {
        start()
        whenSurveyed { [weak self] in
            guard let self else { return }
            guard let url = url(forSpotlightItem: identifier) else {
                spotlight?.remove(identifier)
                return beep()
            }
            comeToFront()
            open(url)
        }
    }

    /// The window, in front: what Spotlight was used for is here now.
    private func comeToFront() {
        #if DEBUG
        // A test copy driven by the debug remote stays behind the windows of whoever is using the Mac.
        if UserDefaults.standard.string(forKey: "debugCommandFile") != nil { return }
        #endif
        showWindow?()
        #if os(macOS)
        NSApp.activate()
        #endif
    }

    /// Where the note is: where its identifier says, or, moved since Spotlight last heard of it, the note of its name
    /// nearest to there in the same location.
    func url(forSpotlightItem identifier: String) -> URL? {
        guard let path = SpotlightIndex.path(of: identifier, in: locations) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let name = url.deletingPathExtension().lastPathComponent
        guard let found = index.resolve(name, from: url), FileKind(url: found, isDirectory: false) == .note,
              let location = location(containing: url), location.contains(found) else { return nil }
        return found
    }

    #if DEBUG
    /// spotlight: what Spotlight was given; id <path>: a note's identifier; open <path>, openid <identifier>: opening
    /// it as a pick in Spotlight does; continue <path>, continuesearch <words>: a pick or Search in App handed to the
    /// app as the system hands it; search <words>: Search in App; query <word>: what Spotlight itself finds; clear:
    /// everything out of Spotlight again.
    func spotlightCommand(_ argument: String) -> String {
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        func identifier(_ path: String) -> String? {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            return location(containing: url).flatMap { SpotlightIndex.identifier(of: url.path, in: $0) }
        }
        switch words.first {
        case "id": return "spotlight id \(identifier(rest) ?? "none")"
        case "open":
            guard let id = identifier(rest) else { return "spotlight open: not in a location" }
            openSpotlightItem(id)
            return "spotlight open \(id)"
        case "openid":
            openSpotlightItem(rest)
            return "spotlight openid \(rest)"
        case "continue", "continuesearch":
            // The pick, or Search in App, as the system hands it to the app: to the app's delegate on the Mac, to the
            // scene's on iPhone and iPad.
            let activity: NSUserActivity
            if words.first == "continue" {
                guard let id = identifier(rest) else { return "spotlight continue: not in a location" }
                activity = NSUserActivity(activityType: CSSearchableItemActionType)
                activity.userInfo = [CSSearchableItemActivityIdentifier: id]
            } else {
                activity = NSUserActivity(activityType: CSQueryContinuationActionType)
                activity.userInfo = [CSSearchQueryString: rest]
            }
            #if os(macOS)
            let taken = NSApp.delegate?.application?(NSApp, continue: activity, restorationHandler: { _ in }) ?? false
            #else
            guard let scene = UIApplication.shared.connectedScenes.first else { return "spotlight continue: no scene" }
            scene.delegate?.scene?(scene, continue: activity)
            let taken = scene.delegate?.responds(to: #selector(UISceneDelegate.scene(_:continue:))) ?? false
            #endif
            return "spotlight \(words[0]) \(activity.activityType) taken=\(taken)"
        case "search":
            searchFromSpotlight(rest)
            return "spotlight search \(rest)"
        case "clear":
            Task { await spotlight?.clear() }
            return "spotlight clear"
        case "query":
            // What Spotlight itself finds of Notebook's for a word, logged when it is done.
            let word = rest.replacingOccurrences(of: "\"", with: "")
            let context = CSSearchQueryContext()
            context.fetchAttributes = ["title", "contentDescription", "containerDisplayName", "contentURL"]
            let query = CSSearchQuery(queryString: "title == \"*\(word)*\"cd || textContent == \"*\(word)*\"cd", queryContext: context)
            let found = Mutex<[String]>([])
            query.foundItemsHandler = { items in
                let lines = items.map { item in
                    let set = item.attributeSet
                    return "\(set.title ?? "") [\(set.containerDisplayName ?? "")] \(item.uniqueIdentifier): \((set.contentDescription ?? "").replacingOccurrences(of: "\n", with: " / "))"
                }
                found.withLock { $0 += lines }
            }
            query.completionHandler = { error in
                let lines = found.withLock { $0 }
                DebugRemote.log("spotlight query \(word): \(lines.count) found" + (error.map { " (\($0.localizedDescription))" } ?? "") + " | " + lines.joined(separator: " | "))
            }
            query.start()
            return "spotlight query \(word)…"
        default:
            guard let spotlight else { return "spotlight off" }
            let last = spotlight.lastUpdate
            return String(format: "spotlight items=%d updates=%d updating=%@ last given=%d taken=%d failed=%@ in %.2f s", spotlight.donated.count, spotlight.updates,
                          spotlight.isUpdating ? "yes" : "no", last.given, last.taken, last.failed ? "yes" : "no", spotlight.lastDuration)
        }
    }
    #endif

    /// Spotlight's Search in App: the words typed there, searched for in ⌘K.
    public func searchFromSpotlight(_ query: String) {
        start()
        comeToFront()
        guard !locations.isEmpty else { return }
        paletteStart = (query, UUID())
        palette = .search
    }
}

#if os(iOS)
extension View {
    /// Opens the note picked in Spotlight, and searches for the words of Search in App. On the Mac the app's delegate
    /// does it: SwiftUI hands a window of its own (`Window`) none of them.
    public func continuesSpotlight(_ workspace: Workspace) -> some View {
        onContinueUserActivity(CSSearchableItemActionType) { workspace.continueActivity($0) }
            .onContinueUserActivity(CSQueryContinuationActionType) { workspace.continueActivity($0) }
    }
}
#endif
