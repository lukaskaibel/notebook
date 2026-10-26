#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Synchronization

/// What a search result opens.
enum SearchResult: Hashable, Sendable {
    case file(URL)
    /// A note or PDF where the words are: it opens there, with the words selected.
    case text(URL, words: String, page: Int?)
    /// A note at one of its headings.
    case heading(URL, title: String)
    /// Text read in a picture: the picture, or the note that shows it (`asset` is its name in `.assets`).
    case picture(URL, asset: String?)
    case newNote(String)

    /// The file it opens, for a new note none.
    var url: URL? {
        switch self {
        case .file(let url), .text(let url, _, _), .heading(let url, _), .picture(let url, _): url
        case .newNote: nil
        }
    }
}

/// One result: a file or folder found by its name, a heading, words in a note, PDF or picture, or a new note with the
/// name searched for.
struct SearchItem: Identifiable, Hashable {
    var result: SearchResult
    var title: String
    /// Where the file is ("iCloud Drive › Travel"), or for a heading the note it is in.
    var place: String?
    var kind: FileKind?
    var isInCloud = false
    /// A symbol other than the kind's: a heading's, or how text was read from a picture.
    var symbol: String?
    /// For words found in a note, PDF or picture: the line they are in, and where they are in it.
    var snippet: String?
    var matches: [Range<String.Index>] = []

    var id: SearchResult { result }

    /// The symbol to show for it.
    var image: String {
        if let symbol { return symbol }
        if isInCloud { return "icloud.and.arrow.down" }
        return kind?.symbol ?? "square.and.pencil"
    }
}

/// The results in their sections: Recent, Files, Folders, Headings, In Notes and PDFs, In Pictures and Drawings, and
/// New Note. The Mac's search field shows them in its suggestions menu, ⌘K in its list, iPhone and iPad in a list.
struct SearchSection: Identifiable {
    var title: String?
    var items: [SearchItem]

    var id: String { title ?? "new" }

    /// With nothing typed: what was opened last.
    @MainActor
    static func recent(in workspace: Workspace, limit: Int = 6) -> [SearchSection] {
        let recent = workspace.recentURLs.prefix(limit).map { url in
            SearchItem(result: .file(url), title: displayName(url), place: workspace.index.entry(for: url)?.place, kind: FileKind(url: url, isDirectory: false))
        }
        return recent.isEmpty ? [] : [SearchSection(title: "Recent", items: Array(recent))]
    }

    static func sections(for results: SearchCorpus.Results, query: SearchCorpus.Query, newNote: Bool = true) -> [SearchSection] {
        var sections: [SearchSection] = []
        if !results.files.isEmpty {
            sections.append(SearchSection(title: "Files", items: results.files.map { item in
                SearchItem(result: .file(item.url), title: item.name, place: item.place, kind: item.kind, isInCloud: item.isInCloud)
            }))
        }
        if !results.folders.isEmpty {
            sections.append(SearchSection(title: "Folders", items: results.folders.map { item in
                SearchItem(result: .file(item.url), title: item.name, place: item.place, kind: .folder)
            }))
        }
        if !results.headings.isEmpty {
            sections.append(SearchSection(title: "Headings", items: results.headings.map { hit in
                SearchItem(result: .heading(hit.item.url, title: hit.heading.title), title: hit.heading.title,
                           place: hit.item.name, kind: .note, symbol: "number")
            }))
        }
        if !results.texts.isEmpty {
            sections.append(SearchSection(title: "In Notes and PDFs", items: results.texts.map { hit in
                var title = hit.item.kind == .note ? hit.item.name : hit.item.url.lastPathComponent
                if let page = hit.page { title += " – page \(page)" }
                return SearchItem(result: .text(hit.item.url, words: query.text, page: hit.page), title: title, place: hit.item.place,
                                  kind: hit.item.kind, snippet: hit.snippet, matches: hit.matches)
            }))
        }
        if !results.pictures.isEmpty {
            sections.append(SearchSection(title: "In Pictures and Drawings", items: results.pictures.map { hit in
                var title = hit.item.kind == .note ? hit.item.name : hit.item.url.lastPathComponent
                if let page = hit.page { title += " – page \(page)" }
                let result: SearchResult
                let symbol: String
                switch hit.source {
                case .drawing(let asset):
                    result = .picture(hit.item.url, asset: asset)
                    symbol = "pencil.and.scribble"
                case .picture(let asset):
                    result = .picture(hit.item.url, asset: asset)
                    symbol = "text.viewfinder"
                case .scan, .text:
                    result = .text(hit.item.url, words: query.text, page: hit.page)
                    symbol = "doc.viewfinder"
                }
                return SearchItem(result: result, title: title, place: hit.item.place, kind: hit.item.kind, symbol: symbol,
                                  snippet: hit.snippet, matches: hit.matches)
            }))
        }
        if newNote {
            sections.append(SearchSection(title: nil, items: [SearchItem(result: .newNote(query.text), title: "New Note “\(query.text)”")]))
        }
        return sections
    }

    static func displayName(_ url: URL) -> String {
        FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}

/// A search on screen: what was typed and what it found. Every letter typed starts a search in the background and
/// stops the one before, and the results stay as they were until the new ones are there, so nothing waits and
/// nothing flickers. The toolbar's search field, ⌘K, and search on iPhone and iPad each have one.
@MainActor
@Observable
final class SearchSession {
    private(set) var query = ""
    private(set) var sections: [SearchSection] = []
    /// How many notes and files have the words in them, shown or not.
    private(set) var textCount = 0
    /// New results are on their way.
    private(set) var isSearching = false
    /// Weak, so background search that outlives a workspace (in tests) finds nothing rather than crashing.
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored var limits = SearchCorpus.Limits()
    /// Whether the last section offers a new note with the name typed.
    @ObservationIgnored var offersNewNote = true
    /// How many files opened last show with nothing typed.
    @ObservationIgnored var recentLimit = 6
    /// Called on the main thread with every new set of results.
    @ObservationIgnored var onResults: (([SearchSection]) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// How long the last search took, for the debug remote.
    @ObservationIgnored private(set) var lastDuration: Double = 0

    init(workspace: Workspace) {
        self.workspace = workspace
        workspace.index.observeCorpus(self)
    }

    /// Searches for `text`, in place of what was searched for before.
    func update(_ text: String) {
        guard let workspace else { return }
        query = text
        generation += 1
        let generation = generation
        task?.cancel()
        guard let parsed = SearchCorpus.Query(text) else {
            task = nil
            isSearching = false
            textCount = 0
            show(SearchSection.recent(in: workspace, limit: recentLimit))
            return
        }
        isSearching = true
        let corpus = workspace.index.corpus
        let limits = limits, newNote = offersNewNote
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let start = CACurrentMediaTime()
            let stop = SearchStop()
            let results = await withTaskCancellationHandler {
                corpus.search(parsed, limits: limits, isCancelled: { stop.isSet })
            } onCancel: {
                stop.set()
            }
            guard !Task.isCancelled else { return }
            let sections = SearchSection.sections(for: results, query: parsed, newNote: newNote)
            let duration = CACurrentMediaTime() - start
            await MainActor.run { [weak self] in
                guard let self, generation == self.generation else { return }
                self.isSearching = false
                self.textCount = results.textCount
                self.lastDuration = duration
                self.show(sections)
            }
        }
    }

    /// The files changed: the same search again, so what came or went shows.
    func corpusChanged() {
        if !query.isEmpty { update(query) }
    }

    /// Done searching: nothing more comes in.
    func clear() {
        task?.cancel()
        generation += 1
        query = ""
        sections = []
        isSearching = false
    }

    private func show(_ sections: [SearchSection]) {
        self.sections = sections
        onResults?(sections)
    }
}

/// Tells a search running on many threads to stop.
final class SearchStop: Sendable {
    private let stopped = Atomic<Bool>(false)
    var isSet: Bool { stopped.load(ordering: .relaxed) }
    func set() { stopped.store(true, ordering: .relaxed) }
}
