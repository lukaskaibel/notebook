# Contributing

Thanks for wanting to help. This is a small project with one maintainer, so a little coordination up front saves
everyone time.

## Before you start

- **Bugs:** open an issue with what you did, what you expected and what happened. Screenshots or a short recording
  help a lot for anything visual, and so does the Markdown of the note, if you can share it.
- **Features and larger changes:** open an issue first and describe the idea. Notebook is deliberately small: every
  feature has to answer "do I need this to replace Apple Notes day to day?", and [PLAN.md](PLAN.md) lists what is left
  out on purpose. It is better to find out whether something fits before you write the code.
- **Small fixes** (typos, obvious bugs): a pull request without an issue is fine.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Build and run from Xcode (see the README). Try your change on the sample notes (`-NotebookLibrary <folder>
   -NotebookDemo YES`) rather than your own.
3. Run the tests: `cd Packages/NotebookKit && swift test`.
4. Open a pull request against `main`, describe what changed and how you checked it, and tick the box agreeing to the
   terms below.

Every pull request is reviewed and merged by the maintainer; nothing lands on `main` without that approval.

## Licensing your contribution

Notebook is licensed under the GNU General Public License, version 3, with one additional permission, for linking with
elk-swift (see [License](README.md#license)). Lukas Kaibel holds the copyright in it, and that is why Notebook can be on
TestFlight and the App Store: the GPL and Apple's terms don't fit together, so others can't put copies there, but the
copyright holder isn't bound by the GPL.

For that to stay true with your code in it, by opening a pull request you agree that:

1. your contribution is licensed under the same terms as the rest of Notebook, the GPL version 3 with that additional
   permission; and
2. you also grant Lukas Kaibel a perpetual, worldwide, non-exclusive, royalty-free and irrevocable licence to use,
   copy, modify and distribute your contribution under other terms, including in builds for TestFlight, the App Store
   and other stores, free or paid, and in versions that aren't open source.

You keep the copyright in what you wrote, and you confirm that it is yours to give on these terms: you wrote it, or it
comes under a licence that allows this. The pull request template has a box to tick for it. If you'd rather not agree,
open an issue that describes the change instead.

## What to keep in mind

- **The file is the truth.** The editor holds the file's Markdown character for character, and what Notebook saves is
  Markdown any other app reads the same. Don't add a database, a sidecar file or syntax only Notebook understands.
- **Never lose a change.** Saving goes through `NSFileCoordinator` and merges with what is on disk
  (`Files/NoteDocument.swift`, `Files/Diff3.swift`). Anything that writes files keeps that promise, and deleting means
  the Trash.
- **Nothing jumps.** Text never moves under a selection or the mouse, and scrolling never jumps. If you touch the
  editor's styling or layout, type in a long note and scroll it before and after; `EditorSmoothnessTests` has to pass.
- **Nothing waits.** The window never stops for the disk or for iCloud: folders, bookmarks and the search index are
  read off the main thread (`Files/FolderReader.swift`, `Files/LocationSurvey.swift`, `Index/SearchIndex.swift`), and
  what the main thread does with the result is only the part that changed. Changes to files (a new note, a rename, a
  move, the Trash) are written off the main thread too, one after another (`Workspace.changeFiles`), and show in the
  sidebar as soon as they are done, before their folder has been read again. So is saving a note
  (`NoteDocument.saveNow`): what is typed meanwhile waits for the next save, and quitting waits for it. A note or
  other file still in iCloud opens at once and fills in when it has come down (`Files/NoteDocument.swift`,
  `UI/FileLoadingView.swift`). Try a
  change with `-NotebookSlowFolders 2`, `-NotebookSlowFiles 2` and `-NotebookSlowWrites 2`. Nothing that happens as a note opens or as you type goes
  through every file or folder either: a whole iCloud Drive has a hundred thousand. Look things up by name
  (`SearchIndex.resolve`), keep sorted lists ready, and make long menus when they open (`UI/MoveToSubmenu.swift`).
  Search goes through every file, so it runs in the background on a copy made for it (`Index/SearchCorpus.swift`),
  and each letter typed stops the search before (`SearchSession`). The index is kept between launches
  (`Index/KeptIndex.swift`), so search has everything at once and the launch reads only what changed; time it on a big
  library with `NOTEBOOK_BENCH_LIBRARY=<folder> swift test --filter SearchBenchmarkTests`.
- **Markdown is a file format, not the interface.** Pictures, links and embeds are objects; marks show only next to
  the caret.
- **Use what the Mac has.** System components and layout (split view, source list, inspector, toolbar, search field,
  alerts, Quick Look) rather than custom chrome, and system colours rather than new ones.
- **Show what changed.** A change people will notice gets a line in `CHANGELOG.md` under "Unreleased", and the README
  follows: the tour, "What it does", the shortcut tables, "Not there yet", and the pictures (`Tools/readme-images.sh`).
  A feature worth a picture gets something in the sample notes (`Debug/DemoLibrary.swift`) to show it with.
- Match the style of the code around you. Comments explain why, not what.

## Releases

Versions follow semantic versioning. The version lives in `Config/Shared.xcconfig`; each release gets an entry in
`CHANGELOG.md` and a tag of the form `v0.1.0`.
