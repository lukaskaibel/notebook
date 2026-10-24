import XCTest
@testable import NotebookKit

/// Links keep pointing at the same note or file when notes, files and folders are renamed or moved: a link is
/// rewritten only when it would point somewhere else (or nowhere) afterwards, and then as short as it can be, by the
/// same rules links are followed by. Here on files on disk, read as the index reads them, without the app around them.
final class LinkUpdateTests: XCTestCase {
    private var library: URL!

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-links-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: library)
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL { library.appendingPathComponent(path) }

    private func write(_ path: String, _ text: String = "") throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    private func relative(_ url: URL) -> String {
        String(HiddenFolders.withoutPrivate(url.standardizedFileURL.path).dropFirst(HiddenFolders.withoutPrivate(library.path).count + 1))
    }

    /// Every note in the library, by its path in it, with its text.
    private func notes() -> [String: String] {
        var notes: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "md" { notes[relative(url)] = try? String(contentsOf: url, encoding: .utf8) }
        }
        return notes
    }

    private struct Result {
        var update: LinkUpdate
        /// The notes rewritten, by their paths once moved, with their new text.
        var changed: [String: String]
        var edits: [NoteLinkEdits]
    }

    /// Renames or moves files on disk as Notebook would, then rewrites the links in the notes the update says change,
    /// as Notebook does in their files. Checks on the way that every link still means what it meant (`assertMeaningKept`).
    @discardableResult
    private func move(_ moves: [(String, String)], file: StaticString = #filePath, line: UInt = #line) throws -> Result {
        let before = LinkTargets.reading(library, deep: true)
        let meanings = self.meanings(in: before)
        var list: [LinkUpdate.Move] = []
        for (from, to) in moves {
            try FileManager.default.createDirectory(at: url(to).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url(from), to: url(to))
            list.append(LinkUpdate.Move(from: url(from), to: url(to)))
        }
        let update = LinkUpdate(before: before, moves: list)
        let (changing, unread) = update.notesToChange()
        XCTAssertTrue(unread.isEmpty, "every note was read", file: file, line: line)
        var changed: [String: String] = [:]
        var edits: [NoteLinkEdits] = []
        for note in changing {
            guard let made = FileOperations.rewriteLinks(in: note, { update.rewrite($0, of: note) }) else { continue }
            changed[relative(note)] = try String(contentsOf: note, encoding: .utf8)
            edits.append(NoteLinkEdits(note: note, edits: made.edits))
        }
        XCTAssertEqual(Set(changing.map(relative)), Set(changed.keys), "a note said to change didn't", file: file, line: line)
        assertMeaningKept(meanings, update: update, file: file, line: line)
        return Result(update: update, changed: changed, edits: edits)
    }

    /// What every link in every note means: the file it finds, or nil.
    private struct Meaning {
        var note: String
        var address: String
        var target: String?
    }

    private func meanings(in targets: LinkTargets) -> [String: [Meaning]] {
        var all: [String: [Meaning]] = [:]
        for (path, text) in notes() {
            let note = url(path)
            let string = text as NSString
            all[path] = LinkUpdate.links(in: string).map { link in
                let address = string.substring(with: link.address)
                return Meaning(note: path, address: address, target: target(of: address, kind: link.kind, from: note, in: targets).map(relative))
            }
        }
        return all
    }

    private func target(of address: String, kind: LinkEdit.Kind, from note: URL, in targets: LinkTargets) -> URL? {
        switch kind {
        case .wiki:
            return targets.resolve(address, from: note)?.url
        case .markdown:
            if let url = URL(string: address), let scheme = url.scheme, scheme.count > 1 { return nil }
            let path = String(address.split(separator: "#", omittingEmptySubsequences: false).first ?? "")
            guard !path.isEmpty else { return nil }
            let found = note.deletingLastPathComponent().appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
            return FileManager.default.fileExists(atPath: found.path) ? found : nil
        }
    }

    /// Every link that found a file before the move finds the same one after it, where it went, by the library as it
    /// is now on disk; links that found nothing still say what they said. Links in `.assets` are the app's to carry
    /// along, and aren't counted.
    private func assertMeaningKept(_ before: [String: [Meaning]], update: LinkUpdate, file: StaticString, line: UInt) {
        let now = LinkTargets.reading(library, deep: true)
        let after = meanings(in: now)
        for (path, links) in before {
            let moved = relative(update.relocated(url(path)))
            guard let found = after[moved] else { XCTFail("\(path) went missing", file: file, line: line); continue }
            XCTAssertEqual(found.count, links.count, "the links in \(moved)", file: file, line: line)
            for (old, new) in zip(links, found) {
                if old.address.hasPrefix(".assets/") { continue }
                guard let target = old.target else {
                    XCTAssertEqual(new.address, old.address, "a link to nothing changed in \(moved)", file: file, line: line)
                    continue
                }
                XCTAssertEqual(new.target, relative(update.relocated(url(target))), "\(old.address) in \(path), now \(new.address)", file: file, line: line)
            }
        }
    }

    // MARK: - Moving notes

    /// A note whose name finds it wherever it is: nothing to rewrite, and no note is even written.
    func testAMoveThatChangesNoLinkRewritesNothing() throws {
        try write("Papers/Draft.md", "See [[Plan]] and [[Plan|the plan]], ![[Plan]].\n")
        try write("Papers/Plan.md", "# Plan\n")
        try write("Archive/Old.md", "No links here.\n")
        let result = try move([("Papers/Plan.md", "Archive/Plan.md")])
        XCTAssertEqual(result.changed, [:])
    }

    /// Two notes called Plan: links that found the one moved say where it is now, those to the other stay.
    func testLinksToANoteOfANameOthersHaveToo() throws {
        try write("A/Plan.md")
        try write("B/Plan.md")
        try write("A/Notes.md", "[[Plan]]")
        try write("B/Notes.md", "[[Plan]]")
        try write("Top.md", "[[Plan]]")
        let result = try move([("A/Plan.md", "C/Plan.md")])
        XCTAssertEqual(result.changed, ["A/Notes.md": "[[C/Plan]]", "Top.md": "[[C/Plan]]"])
        XCTAssertEqual(text("B/Notes.md"), "[[Plan]]")
    }

    /// Moved next to a note that linked to another note of its name, a note would take that link over: the link
    /// says which it means now. Links to the note moved by its old folder find it by its name alone.
    func testANameClashTheMoveMakes() throws {
        try write("X/Plan.md")
        try write("Z/Plan.md")
        try write("F/Note.md", "[[Plan]]")
        try write("Q/Other.md", "[[Z/Plan]]")
        let result = try move([("Z/Plan.md", "F/Plan.md")])
        XCTAssertEqual(result.changed, ["F/Note.md": "[[X/Plan]]", "Q/Other.md": "[[Plan]]"])
    }

    /// The moved note's own links look in its new folder first: one that would find another note there says which.
    func testTheMovedNotesOwnLinks() throws {
        try write("X/Plan.md")
        try write("Y/Plan.md")
        try write("Budget.md")
        try write("X/Note.md", "[[Plan]] and [[Budget]]\n")
        let result = try move([("X/Note.md", "Y/Note.md")])
        XCTAssertEqual(result.changed, ["Y/Note.md": "[[X/Plan]] and [[Budget]]\n"])
    }

    /// Moved into a folder that has a note of its name, a note gets a number, and links to it say so.
    func testMovedWhereItsNameIsTaken() throws {
        try write("Papers/Plan.md")
        try write("Archive/Plan.md")
        try write("Papers/Draft.md", "[[Plan]]")
        try write("Index.md", "[[Archive/Plan]]")
        let result = try move([("Papers/Plan.md", "Archive/Plan 2.md")])
        XCTAssertEqual(result.changed, ["Papers/Draft.md": "[[Plan 2]]"])
        XCTAssertEqual(text("Index.md"), "[[Archive/Plan]]")
    }

    /// Deeper or shallower, a note can lose or win the tie between notes of its name.
    func testDepthDecidesBetweenNamesAfterAMove() throws {
        try write("Plan.md")
        try write("Deep/Er/Plan.md")
        try write("Top.md", "[[Plan]] and [[Er/Plan]]")
        let result = try move([("Plan.md", "Deep/Er2/Even/Plan.md")])
        XCTAssertEqual(result.changed, ["Top.md": "[[Even/Plan]] and [[Er/Plan]]"])
    }

    /// How the link was written stays: its case, ".md", the spaces inside the brackets, what it shows, the heading or
    /// size after it, and whether it is an embed.
    func testEveryFormOfLink() throws {
        try write("A/Plan.md")
        try write("B/Plan.md")
        try write("A/Offer.pdf")
        try write("B/Offer.pdf")
        try write("A/photo.png")
        try write("B/photo.png")
        try write("A/Note.md", """
            [[plan]], [[Plan.md]], [[ Plan ]], [[Plan|my plan]], [[Plan#Today]], [[Plan#Today|today]], [[Plan#^block]]
            ![[Plan]] ![[Plan#Today]]
            [[Offer.pdf]] ![[Offer.pdf]] ![[photo.png|300]]
            """)
        let result = try move([("A/Plan.md", "C/Plan.md"), ("A/Offer.pdf", "C/Offer.pdf"), ("A/photo.png", "C/photo.png")])
        XCTAssertEqual(result.changed["A/Note.md"], """
            [[C/plan]], [[C/Plan.md]], [[ C/Plan ]], [[C/Plan|my plan]], [[C/Plan#Today]], [[C/Plan#Today|today]], [[C/Plan#^block]]
            ![[C/Plan]] ![[C/Plan#Today]]
            [[C/Offer.pdf]] ![[C/Offer.pdf]] ![[C/photo.png|300]]
            """)
    }

    /// Obsidian keeps links in properties too: the front matter's follow, those in code don't, as they are no links.
    func testLinksInFrontMatterFollowAndThoseInCodeStay() throws {
        try write("A/Plan.md")
        try write("B/Plan.md")
        try write("A/Note.md", """
            ---
            up: "[[Plan]]"
            related: ["[[Plan|p]]", "[[Other]]"]
            ---
            `[[Plan]]` in code
            ```
            [[Plan]]
            ```
            > [[Plan]] in a quote, - [ ] and a to-do with [[Plan]]

            | Table | [[Plan]] |
            | --- | --- |
            """)
        let result = try move([("A/Plan.md", "C/Plan.md")])
        XCTAssertEqual(result.changed["A/Note.md"], """
            ---
            up: "[[C/Plan]]"
            related: ["[[C/Plan|p]]", "[[Other]]"]
            ---
            `[[Plan]]` in code
            ```
            [[Plan]]
            ```
            > [[C/Plan]] in a quote, - [ ] and a to-do with [[C/Plan]]

            | Table | [[C/Plan]] |
            | --- | --- |
            """)
    }

    /// Links to nothing stay as they are, also when a note is renamed to their name: then they find it.
    func testLinksToNothingStay() throws {
        try write("A/Plan.md")
        try write("B/Plan.md")
        try write("Elsewhere/Sketch.md")
        try write("A/Note.md", "[[Nara]] [[Nowhere]] [[Plan]]")
        let result = try move([("A/Plan.md", "C/Plan.md"), ("Elsewhere/Sketch.md", "Elsewhere/Nara.md")])
        XCTAssertEqual(result.changed, ["A/Note.md": "[[Nara]] [[Nowhere]] [[C/Plan]]"])
        XCTAssertEqual(result.update.after.resolve("Nara", from: url("A/Note.md"))?.name, "Nara")
    }

    /// Notes without links, or with none to what moved, are left alone: not even written again.
    func testNotesWithoutLinksAreLeftAlone() throws {
        for number in 0..<30 { try write("Notes/Note \(number).md", "Nothing to see in note \(number).\n") }
        try write("Notes/Linked.md", "[[Budget]], [web](https://example.com/Plan.md)")
        try write("Plan.md", "# Plan\n")
        let dates = notes().keys.reduce(into: [String: Date]()) { $0[$1] = try? url($1).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let result = try move([("Plan.md", "Notes/Plan.md")])
        XCTAssertEqual(result.changed, [:])
        XCTAssertTrue(result.update.notesToChange().changing.isEmpty)
        for (path, date) in dates where path != "Plan.md" {
            XCTAssertEqual(try url(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date, "\(path) was written")
        }
    }

    // MARK: - Renaming

    /// A rename points the links that found the note at its new name, keeping ".md" and what follows; links to another
    /// note of its old name stay.
    func testARenameFollowsOnlyTheNoteRenamed() throws {
        try write("A/Draft.md", "[[Draft#Top]]")
        try write("B/Draft.md")
        try write("A/Other.md", "[[Draft]] [[draft.md]] ![[Draft|200]] [[Draft#Plan|plan]]")
        try write("B/Other.md", "[[Draft]]")
        let result = try move([("A/Draft.md", "A/Plan.md")])
        XCTAssertEqual(result.changed, ["A/Other.md": "[[Plan]] [[Plan.md]] ![[Plan|200]] [[Plan#Plan|plan]]", "A/Plan.md": "[[Plan#Top]]"])
        XCTAssertEqual(text("B/Other.md"), "[[Draft]]")
    }

    /// Renamed to a name another note has, links that found it say which it is.
    func testARenameToANameTaken() throws {
        try write("A/Draft.md")
        try write("B/Plan.md")
        try write("B/Notes.md", "[[Draft]] [[Plan]]")
        let result = try move([("A/Draft.md", "A/Plan.md")])
        XCTAssertEqual(result.changed, ["B/Notes.md": "[[A/Plan]] [[Plan]]"])
    }

    /// Other files follow a rename too.
    func testARenamedFile() throws {
        try write("Offer.pdf")
        try write("Note.md", "[[Offer.pdf]] ![[Offer.pdf|200]] [the offer](Offer.pdf)")
        let result = try move([("Offer.pdf", "Quote.pdf")])
        XCTAssertEqual(result.changed, ["Note.md": "[[Quote.pdf]] ![[Quote.pdf|200]] [the offer](Quote.pdf)"])
    }

    // MARK: - Folders

    /// A folder renamed: links into it by its old name find what they found, as short as they can; those that still
    /// find it stay, and the links between the notes in it too.
    func testARenamedFolderWithFoldersInIt() throws {
        try write("Projects/Alpha/Spec.md", "[[Beta/Spec]] [[Notes]] [[Projects/Beta/Spec|beta]]")
        try write("Projects/Beta/Spec.md")
        try write("Projects/Alpha/Notes.md", "[[Spec]]")
        try write("Inbox/Todo.md", "[[Projects/Alpha/Spec]], [[Alpha/Spec]], [[Beta/Spec|beta]], [[Projects/Alpha/Notes#Top]]")
        let result = try move([("Projects", "Work")])
        XCTAssertEqual(result.changed, [
            "Inbox/Todo.md": "[[Spec]], [[Alpha/Spec]], [[Beta/Spec|beta]], [[Notes#Top]]",
            "Work/Alpha/Spec.md": "[[Beta/Spec]] [[Notes]] [[Beta/Spec|beta]]",
        ])
        XCTAssertEqual(text("Work/Alpha/Notes.md"), "[[Spec]]")
    }

    /// A folder of many notes linking to each other, to notes of the same names elsewhere and in every form, renamed and
    /// then moved deeper: every link still finds what it found.
    func testAFolderOfManyNotes() throws {
        for number in 0..<60 {
            let folder = "Big/Sub \(number % 4)"
            let other = (number * 7 + 3) % 60
            try write("\(folder)/Note \(number).md", """
                [[Note \(other)]] [[Sub \(other % 4)/Note \(other)|that]] ![[Note \((number + 1) % 60)#Top]]
                [md](../Sub%20\(other % 4)/Note%20\(other).md) [[Big/Sub \(number % 4)/Note \(number)]]
                """)
            if number.isMultiple(of: 3) { try write("Elsewhere/Note \(number).md", "[[Note \(number)]] [[Big/Sub \(number % 4)/Note \(number)]]") }
        }
        try write("Index.md", (0..<60).map { "[[Note \($0)]]" }.joined(separator: " "))
        let renamed = try move([("Big", "Huge")])
        XCTAssertFalse(renamed.changed.isEmpty)
        try move([("Huge", "Archive/2026/Huge")])
    }

    // MARK: - Markdown links

    /// Markdown links and pictures with an address next to the note: those of a note moved are its way to the same
    /// files from its new folder, encoded as they were, and links to a note moved find it where it is now. Web
    /// addresses, places in the note and its own `.assets` (which go along with it) stay.
    func testMarkdownLinksAndPictures() throws {
        try write("Papers/Plan.md")
        try write("Money/Budget Sheet.md")
        try write("Papers/Other Note.md")
        try write("Papers/.assets/chart.png")
        try write("Papers/pics/photo.png")
        try write("Papers/Draft.md", """
            [Plan](Plan.md) [Budget](../Money/Budget%20Sheet.md) ![Chart](.assets/chart.png) ![Photo](pics/photo.png "A photo")
            [Web](https://example.com/Plan.md) [Mail](mailto:me@example.com) [Here](#Heading) [Other](<Other Note.md>) [Gone](Gone.md)
            [Plan's part](Plan.md#Part)
            """)
        try write("Papers/Index.md", "[Draft](Draft.md) and [the draft](./Draft.md)")
        let result = try move([("Papers/Draft.md", "Archive/Draft.md")])
        XCTAssertEqual(result.changed, [
            "Archive/Draft.md": """
                [Plan](../Papers/Plan.md) [Budget](../Money/Budget%20Sheet.md) ![Chart](.assets/chart.png) ![Photo](../Papers/pics/photo.png "A photo")
                [Web](https://example.com/Plan.md) [Mail](mailto:me@example.com) [Here](#Heading) [Other](<../Papers/Other Note.md>) [Gone](Gone.md)
                [Plan's part](../Papers/Plan.md#Part)
                """,
            "Papers/Index.md": "[Draft](../Archive/Draft.md) and [the draft](../Archive/Draft.md)",
        ])
    }

    /// A file with spaces in its name, moved: the links to it are encoded, as Notebook writes addresses.
    func testMarkdownLinksToAFileMovedAreEncoded() throws {
        try write("Money/Budget Sheet.md")
        try write("Note.md", "[Budget](Money/Budget%20Sheet.md) [Raw](<Money/Budget Sheet.md>)")
        let result = try move([("Money", "Old Money (2025)")])
        XCTAssertEqual(result.changed, ["Note.md": "[Budget](Old%20Money%20%282025%29/Budget%20Sheet.md) [Raw](<Old Money (2025)/Budget Sheet.md>)"])
    }

    // MARK: - Undo

    /// Undo puts every link back as it was written, also one longer than it had to be; Redo makes them follow again.
    func testUndoPutsTheTextBackAsItWas() throws {
        try write("Projects/Alpha/Spec.md")
        try write("Projects/Beta/Spec.md")
        try write("A/Plan.md")
        try write("B/Plan.md")
        let original = "[[Projects/Alpha/Spec]] [[Plan]] [[A/Plan|plan]] [x](../Projects/Alpha/Spec.md) [[Plan]]"
        try write("A/Note.md", original)
        let result = try move([("Projects", "Work"), ("A/Plan.md", "C/Plan.md")])
        let changed = try XCTUnwrap(result.changed["A/Note.md"])
        XCTAssertEqual(changed, "[[Spec]] [[C/Plan]] [[C/Plan|plan]] [x](../Work/Alpha/Spec.md) [[C/Plan]]")
        let edits = try XCTUnwrap(result.edits.first?.edits)
        let undone = try XCTUnwrap(LinkUpdate.replay(edits, in: changed, undoing: true))
        XCTAssertEqual(undone.text, original)
        XCTAssertEqual(LinkUpdate.replay(edits, in: undone.text, undoing: false)?.text, changed)
        // Changed since, around the links: they are found by what they say.
        let edited = "Typed first. " + changed.replacingOccurrences(of: " [[C/Plan|plan]]", with: "") + " Typed last."
        XCTAssertEqual(LinkUpdate.replay(edits, in: edited, undoing: true)?.text,
                       "Typed first. [[Projects/Alpha/Spec]] [[Plan]] [x](../Projects/Alpha/Spec.md) [[A/Plan]] Typed last.")
        XCTAssertNil(LinkUpdate.replay(edits, in: "Nothing of it is left.", undoing: true))
    }

    // MARK: - What the index hasn't read yet

    /// Files Notebook moved a moment ago are where they went, whether the index has read their folders again or not,
    /// or only one of them.
    func testMovesTheIndexHasntReadYet() throws {
        try write("A/Plan.md")
        try write("A/Folder/Inside.md")
        try write("B/Other.md")
        let before = LinkTargets.reading(library, deep: true)
        try FileManager.default.moveItem(at: url("A/Plan.md"), to: url("B/Plan.md"))
        try FileManager.default.moveItem(at: url("A/Folder"), to: url("B/Folder"))
        let recent = [LinkUpdate.Move(from: url("A/Plan.md"), to: url("B/Plan.md")), LinkUpdate.Move(from: url("A/Folder"), to: url("B/Folder"))]
        let now = Set(LinkTargets.reading(library, deep: true).byPath.keys.map(HiddenFolders.withoutPrivate))
        func paths(_ targets: LinkTargets) -> Set<String> { Set(targets.byPath.keys.map(HiddenFolders.withoutPrivate)) }
        XCTAssertEqual(paths(before.settled(recent)), now, "not read again")
        XCTAssertEqual(paths(LinkTargets.reading(library, deep: true).settled(recent)), now, "read again")
        // Only the folder they went to read again, without what is in the folder moved: the old entries go, the rest
        // come along.
        var halfway = before
        halfway.byPath[HiddenFolders.withoutPrivate(url("B/Plan.md").path)] = LinkTargets.reading(library, deep: true).entry(for: url("B/Plan.md"))
        halfway.byPath[HiddenFolders.withoutPrivate(url("B/Folder").path)] = LinkTargets.reading(library, deep: true).entry(for: url("B/Folder"))
        XCTAssertEqual(paths(halfway.settled(recent)), now, "halfway")
        XCTAssertEqual(before.settled(recent).resolve("Inside", from: url("B/Other.md"))?.url.lastPathComponent, "Inside.md")
    }
}
