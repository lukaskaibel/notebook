# Privacy

Notebook is a notes app for files on your Mac. It has no server, no accounts, no analytics and no advertising, and it
collects nothing about you.

## What the app stores, and where

- **Your notes** are the Markdown files in your own folders. Notebook reads and writes them in place. Pictures and files
  you add to a note go into a hidden `.assets` folder next to it.
- **The folders you add** as locations are remembered on your Mac, with the permission to open them again (a
  security-scoped bookmark).
- **Favourites, recently opened files, the folders open in the sidebar and your settings** (typeface, text size,
  what the sidebar shows) are kept in the app's preferences on your Mac.
- **The folders you hide and the reminders of notes you set** are kept in the app's preferences and, in the App Store
  build, in iCloud's key-value store, which Apple syncs to your other devices signed in to the same Apple Account. A
  reminder of a note is the place of the note in your folders, its time and the place it reminds you at (a name and its
  coordinates); it is never written into the note, so it doesn't go along when you share the note.
- **A to-do's date, time and place** are part of the to-do: they are written into the note after its words, a place as
  a link to it in Apple Maps, so they go along with the note like everything else in it.
- **Notifications** of reminders and to-dos are scheduled on each of your devices by the system. Their text is the
  note's name or the to-do, the time or the place, and the note's first points or the to-do's notes, read from the note
  on that device. Notebook asks whether it may send notifications when you set your first reminder, and you can turn
  them off in System Settings or Settings.
- **Your location.** When you first give a reminder a place, Notebook asks whether it may use your location while you
  use the app ("While Using", never "Always"). On iPhone and iPad it hands the place to the system, which shows the
  notification when you arrive or leave; Notebook itself isn't told where you are and keeps no record of it. Current
  Location asks once where you are, to name the place, and keeps only the place you chose. A Mac doesn't watch places.
- **The places you chose last**, to choose again at a tap, are kept in the app's preferences on that device.
- **The search index** of file names, the text of notes and PDFs and the words read in pictures is kept in the app's
  caches on each device, so search has everything as soon as Notebook opens; it can always be made again from your
  files.
- **Spotlight** gets the name, the first lines, the folder and the text of every note in your locations, except those in
  hidden folders, so the system's search finds them. Spotlight keeps its index on your Mac, iPhone or iPad, as it does
  for Mail or Notes, and Notebook keeps a list of the notes it gave it, by their places in your folders, in the app's
  own folder on that device. A note leaves Spotlight when you delete it, hide its folder or remove its location. To
  leave Notebook's notes out of Spotlight, turn Notebook off in System Settings › Spotlight on the Mac, or in
  Notebook's search settings in Settings on iPhone and iPad.

## What is sent, and to whom

- **Nothing of yours, with one exception you start:** searching for a place for a reminder asks Apple Maps, as the Maps
  app does, with the words you type; Current Location asks it for the address of where you are, and the map in Remind
  Me loads from it. Notebook has no other code that connects to the internet. Pictures in notes that point to a web
  address are not downloaded; Notebook shows the address instead.
- When you click a web link in a note, your browser opens it.
- If your notes are in iCloud Drive, Apple syncs them as it syncs every other file there; Notebook asks the system to
  download notes that aren't on your Mac yet, so it can show and search them. What Apple does with iCloud Drive is
  described in [Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Sample notes

Debug builds can create sample notes in a folder you name (`-NotebookDemo YES`), for trying the app and for the README's
pictures. They are made up, and nothing about them is sent anywhere.

## Questions

Write to [notebook.app@icloud.com](mailto:notebook.app@icloud.com) or open an issue in the
[repository](https://github.com/lukaskaibel/notebook/issues). Security problems are best reported privately, as described
in [SECURITY.md](SECURITY.md).
