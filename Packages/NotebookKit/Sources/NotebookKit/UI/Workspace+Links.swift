#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Synchronization

/// The links one rename or move rewrote, kept as each note is written, for Undo to put back; and whether to go on,
/// which Undo says no to when it comes first. Notes still in iCloud come down with `iCloud`, which stopping (or half
/// a minute) calls off.
final class LinkFollowing: @unchecked Sendable {
    private struct State {
        var edits: [NoteLinkEdits] = []
        var isStopped = false
    }

    private let state = Mutex(State())
    /// File coordinators may be used and cancelled from any thread; the rest is behind the lock.
    let iCloud = NSFileCoordinator()

    var edits: [NoteLinkEdits] { state.withLock { $0.edits } }
    var isStopped: Bool { state.withLock { $0.isStopped } }

    func keep(_ edits: [LinkEdit], in note: URL) {
        state.withLock { $0.edits.append(NoteLinkEdits(note: note, edits: edits)) }
    }

    /// Nothing more is rewritten.
    func stop() {
        state.withLock { $0.isStopped = true }
        iCloud.cancel()
    }
}

extension Workspace {
    /// What links mean as a rename or move is about to be made: the index's lookups as they are, and what Notebook
    /// renamed and moved a moment ago, which the index may not have read again yet.
    struct LinkSnapshot: Sendable {
        var targets: LinkTargets
        var recent: [LinkUpdate.Move] = []
        /// The text Notebook gave notes a moment ago, by their paths, which the index may not have read yet.
        var texts: [String: String] = [:]
        /// The folders to read instead, while the index has nothing yet (the first time Notebook opens them).
        var reading: [URL]?

        /// What links mean before the move: what the index knew, as Notebook changed it since.
        var before: LinkTargets { targets.settled(recent).withTexts(texts) }
    }

    func linkSnapshot() -> LinkSnapshot {
        let now = Date()
        // The oldest go once the index has them where they went, or after a while anyway; the texts once the index has
        // them, or after a while too.
        while let first = recentMoves.first,
              now.timeIntervalSince(first.date) > 20 || (index.entry(for: first.move.to) != nil && index.entry(for: first.move.from) == nil) {
            recentMoves.removeFirst()
        }
        recentLinkTexts = recentLinkTexts.filter { path, written in
            now.timeIntervalSince(written.date) < 20 && index.entry(for: URL(fileURLWithPath: path))?.text != written.text
        }
        guard index.count > 0 else { return LinkSnapshot(targets: .empty, reading: locations.flatMap { $0.folders.map(\.url) }) }
        return LinkSnapshot(targets: index.linkTargets, recent: recentMoves.map(\.move), texts: recentLinkTexts.mapValues(\.text))
    }

    /// After a file or folder was renamed or moved, the links in notes that would point somewhere else now are
    /// rewritten to point where they did (`LinkUpdate`): links to it, to what is in it, and in the notes that went
    /// with it. Off the main thread, after the rewriting before it is done; in notes shown in an editor as an edit of
    /// their text, which is saved from there, in the others in their files. What it rewrites is kept for Undo
    /// (`takeBackLinks`).
    @discardableResult
    func followLinks(_ move: LinkUpdate.Move, from snapshot: LinkSnapshot) -> LinkFollowing {
        let following = LinkFollowing()
        let previous = lastLinkChange
        lastLinkChange = Task { [weak self] in
            await previous?.value
            guard let self, !following.isStopped else { return }
            // What the rewriting before this one wrote, where it was before this move.
            var snapshot = snapshot
            for (path, written) in recentLinkTexts { snapshot.texts[Self.relocated(path, from: move.to.path, to: move.from.path)] = written.text }
            let update = await Task.detached(priority: .utility) { [snapshot] in
                // Without the index, the files as they are now, with the move taken back.
                guard let folders = snapshot.reading else { return LinkUpdate(before: snapshot.before, moves: [move]) }
                return LinkUpdate(before: LinkTargets.reading(folders, deep: true).moving([move.reversed]), moves: [move])
            }.value
            await rewriteLinks(update, following: following)
        }
        return following
    }

    private func rewriteLinks(_ update: LinkUpdate, following: LinkFollowing) async {
        // The text of the notes shown is what they say, saved yet or not. Only those the index knows read links its way.
        let shown = notesShown()
        let found = await Task.detached(priority: .utility) { () -> (changing: [URL], unread: [URL], inEditors: [NoteLinkEdits]) in
            let (changing, unread) = update.notesToChange()
            let inEditors = shown.compactMap { note -> NoteLinkEdits? in
                guard update.knows(note.url), let rewritten = update.rewrite(note.text, of: note.url) else { return nil }
                return NoteLinkEdits(note: note.url, edits: rewritten.edits)
            }
            return (changing, unread, inEditors)
        }.value
        guard !following.isStopped else { return }
        for note in found.inEditors {
            if let edits = changeLinksInEditor(showing: note.note, note.edits, undoing: false) { following.keep(edits, in: note.note) }
        }
        let skipping = shown.map(\.url)
        let written = await Task.detached(priority: .utility) {
            Self.writeLinks(changing: found.changing, unread: found.unread, skipping: skipping, update: update, following: following)
        }.value
        notesRewritten(written)
    }

    /// Writes the links an update changes into the notes' files, one after another until Undo says stop, and those of
    /// notes still in iCloud last, each once it has come down, giving up on them after half a minute. The notes shown
    /// in an editor are left to it. The notes written.
    nonisolated private static func writeLinks(changing: [URL], unread: [URL], skipping shown: [URL], update: LinkUpdate,
                                               following: LinkFollowing) -> [(url: URL, text: String)] {
        var written: [(url: URL, text: String)] = []
        func write(_ url: URL) {
            guard !shown.contains(where: { FileNode.samePath($0, url) }) else { return }
            if let rewritten = FileOperations.rewriteLinks(in: url, { update.rewrite($0, of: url) }) {
                following.keep(rewritten.edits, in: url)
                written.append((url, rewritten.text))
            }
        }
        for url in changing {
            guard !following.isStopped else { return written }
            write(url)
        }
        guard !unread.isEmpty else { return written }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak following] in following?.iCloud.cancel() }
        for url in unread {
            guard !following.isStopped else { break }
            // Written only when there is something to change, as for the others.
            guard let text = FileOperations.read(url, coordinator: following.iCloud), update.rewrite(text, of: url) != nil else { continue }
            write(url)
        }
        return written
    }

    /// Undo of a rename or move: the links it rewrote say again what they said, wherever they still say what it made
    /// them say. What was still being rewritten stops first. `from` and `to`: where the file went back from and to, for
    /// the notes that went with it.
    func takeBackLinks(_ following: LinkFollowing?, from: URL, to: URL) {
        guard let following else { return }
        following.stop()
        let previous = lastLinkChange
        lastLinkChange = Task { [weak self] in
            await previous?.value
            let notes = following.edits.map { NoteLinkEdits(note: Self.relocated($0.note, from: from, to: to), edits: $0.edits) }
            guard let self, !notes.isEmpty else { return }
            var inFiles: [NoteLinkEdits] = []
            for note in notes {
                if editorShowing(note.note) != nil {
                    changeLinksInEditor(showing: note.note, note.edits, undoing: true)
                } else {
                    inFiles.append(note)
                }
            }
            let written = await Task.detached(priority: .userInitiated) {
                inFiles.compactMap { note -> (url: URL, text: String)? in
                    FileOperations.rewriteLinks(in: note.note) { LinkUpdate.replay(note.edits, in: $0, undoing: true) }.map { (note.note, $0.text) }
                }
            }.value
            notesRewritten(written)
        }
    }

    /// Waits until the links of every rename and move asked for so far have been rewritten (or put back).
    func linksFollowed() async {
        while let task = lastLinkChange {
            await task.value
            if lastLinkChange == task { return }
        }
    }

    /// The notes shown in an editor with their text in, saved yet or not: this window's, and on the Mac the windows
    /// of their own.
    func notesShown() -> [(url: URL, text: String)] {
        var shown: [(url: URL, text: String)] = []
        if let note, note.isLoaded { shown.append((note.url, editor.text)) }
        #if os(macOS)
        shown += FileWindows.shared.notesShown()
        #endif
        return shown
    }

    /// Changes the links in the note an editor shows as an edit of its text, back to what they said when `undoing`,
    /// and saves it. The links changed, as the rewrite made them, or nil when there was none to change there.
    @discardableResult
    private func changeLinksInEditor(showing url: URL, _ edits: [LinkEdit], undoing: Bool) -> [LinkEdit]? {
        guard let editor = editorShowing(url) else { return nil }
        let changes = LinkUpdate.replayChanges(edits, in: editor.nsText, undoing: undoing)
        guard !changes.isEmpty, editor.changeLinks(changes.map { ($0.range, $0.edit.new) }, actionName: "Update Links") else { return nil }
        saveNote(showing: url)
        recentLinkTexts[HiddenFolders.withoutPrivate(url.standardizedFileURL.path)] = (editor.text, Date())
        return changes.map { undoing ? LinkEdit(kind: $0.edit.kind, old: $0.edit.new, new: $0.edit.old) : $0.edit }
    }

    #if DEBUG
    /// The links in the open note and what clicking each opens, for the debug remotes: "[[Plan]] → Papers/Plan.md".
    func debugLinks() -> String {
        guard let url = currentURL, note?.isLoaded == true else { return "no note" }
        let root = location(containing: url)?.url.path ?? ""
        let string = editor.nsText
        return LinkUpdate.links(in: string).map { link -> String in
            let address = string.substring(with: link.address)
            let target: URL? = switch link.kind {
            case .wiki: index.resolve(address, from: url)
            case .markdown: {
                let path = String(address.split(separator: "#", omittingEmptySubsequences: false).first ?? "")
                let found = url.deletingLastPathComponent().appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
                return !path.isEmpty && FileManager.default.fileExists(atPath: found.path) ? found : nil
            }()
            }
            let shown = target.map { HiddenFolders.withoutPrivate($0.path).replacingOccurrences(of: HiddenFolders.withoutPrivate(root) + "/", with: "") } ?? "nothing"
            return (link.kind == .wiki ? "[[\(address)]]" : "(\(address))") + " → " + shown
        }.joined(separator: " | ")
    }
    #endif

    /// Notes whose links were rewritten in their files, with their new text: search reads them again, and until it
    /// has, the next rename or move goes by what they say now. A note open somewhere else takes the change in as one
    /// made elsewhere.
    private func notesRewritten(_ notes: [(url: URL, text: String)]) {
        var folders: [URL] = []
        for note in notes {
            recentLinkTexts[HiddenFolders.withoutPrivate(note.url.standardizedFileURL.path)] = (note.text, Date())
            let folder = note.url.deletingLastPathComponent()
            if !folders.contains(where: { FileNode.samePath($0, folder) }) { folders.append(folder) }
        }
        if !folders.isEmpty { index.refresh(folders: folders, locations: locations) }
    }
}
