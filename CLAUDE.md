# Notes for Claude

[CONTRIBUTING.md](CONTRIBUTING.md) applies to you as to everyone. This file adds one duty that is easy to forget.

## Keep the repository in step with the app

The README, the changelog, the pictures and the repository's page on GitHub describe the app to people who have never
run it. When a change alters what the app does or how it looks, update them on the same branch as the change, without
being asked. Before calling such a change done, go through this list and do what applies:

- **CHANGELOG.md:** a line under `[Unreleased]` (Added, Changed or Fixed) for everything a user would notice, written
  for users and in the style of the entries already there.
- **README.md:** the tour (what a feature looks like and does), "What it does", "How notes are stored", the shortcut
  tables in "Using it", "Not there yet" (take out what now exists), the requirements and setup steps, and "For
  contributors" when folders or tools change. Plain and specific, no hype.
- **Pictures:** when a change shows in a picture the README has (the note, typing, objects, blocks, maths, search,
  Quick Look), run `Tools/readme-images.sh`. It builds the app, runs it in the background on the sample notes and lays
  out every picture and `Design/social-preview.png`; it needs Screen Recording permission for the terminal and an
  awake screen. If it can't run, say so; don't commit old pictures as if they were new.
  - Look at every image before committing it.
  - A headline feature may deserve its own picture: add a scene to `Tools/readme-images.sh` and
    `Tools/readme-images/build.py`, and a section with a light and a dark `<picture>` to the README, like the others.
- **Sample notes** (`Files/DemoLibrary.swift`): the pictures are taken on them, so a new feature needs something there
  to show it with.
- **The repository on GitHub:** when the app's scope changes (a platform, a headline feature), update the description
  and topics with `gh repo edit lukaskaibel/notebook --description "…" --add-topic …` and say that you did. When
  `Design/social-preview.png` changed, tell the user to upload it under Settings › General › Social preview; GitHub
  has no API for it.
- **Releases:** the version in `Config/Shared.xcconfig`, the version badge in the README and the changelog heading
  change together, and the release gets a `v` tag.

In the pull request, say which of these you updated and which you left alone on purpose.

## Planning

Notebook is planned in the GitHub project [Notebook](https://github.com/users/lukaskaibel/projects/4): milestones are
versions (0.1.0, 0.2.0, …), larger pieces are issues labelled `epic` with sub-issues as their steps, and Status runs
Inbox → Backlog → Todo → In Progress → In Review → Done. Work you find but don't do becomes an issue there (Inbox, or
Backlog when it's clearly wanted). Link pull requests to their issue (`Closes #12`). When a version ships, close its
milestone with what shipped and the tag in its description.
