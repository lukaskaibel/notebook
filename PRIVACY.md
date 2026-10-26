# Privacy

Notebook is a notes app for the files on your Mac, iPhone and iPad. It has no server, no accounts, no analytics and no
advertising, and it collects nothing about you.

## What the app stores, and where

- **Your notes** are the Markdown files in your own folders. Notebook reads and writes them in place. Pictures and files
  you add to a note go into a hidden `.assets` folder next to it.
- **The folders you add** as locations are remembered on your device, with the permission to open them again (a
  security-scoped bookmark). On iPhone and iPad, notes you keep on the device are in Notebook's own folder, which the
  Files app shows under On My iPhone › Notebook.
- **Favourites, recently opened files, the folders open in the sidebar and your settings** (typeface, text size,
  what the sidebar shows, the notebook on the app icon) are kept in the app's preferences on your device.
- **The folders you hide and the reminders of notes you set** are kept in the app's preferences and, in the App Store
  build, in iCloud's key-value store, which Apple syncs to your other devices signed in to the same Apple Account. A
  reminder of a note is the place of the note in your folders, its time and the place it reminds you at (a name and its
  coordinates); it is never written into the note, so it doesn't go along when you share the note.
- **Earlier versions of your notes**, for version history, are plain copies of a note's text, taken as you write and
  kept for a year. Each copy's name says when it was taken and on what kind of device, with a few letters that tell
  your devices apart. In the App Store build, the versions of notes in iCloud are kept in Notebook's own iCloud folder,
  which Apple syncs to your other devices signed in to the same Apple Account, as it syncs iCloud Drive; the folder
  doesn't show in iCloud Drive. The versions of notes anywhere else, and of every note in builds without iCloud, stay
  in the app's own folder on that device. Settings › your name › iCloud › Storage on iPhone and iPad, or System
  Settings › your name › iCloud › Manage on the Mac, shows how much Notebook keeps in iCloud, and can delete it.
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
- **Home and Work**, once you choose them for reminders, are kept in the app's preferences and, in the App Store build,
  in iCloud's key-value store, for your other devices: each an address and its coordinates. Choosing one from Contacts
  opens Apple's own contact picker; Notebook sees only the address you tap and has no access to your contacts.
- **What you share to Notebook** from another app's share sheet (text, a link, pictures, files) waits in a folder that
  Notebook and its share extension share on your device, until Notebook has written it into your notes, and is then
  deleted. For the share sheet to offer them, the name of your default folder and the place of the note you opened
  last are kept there too.
- **What the widgets show:** the to-dos due today, overdue or in the coming week, with the names of their notes, and
  the text of the notes you chose to show in a Note widget, kept by Notebook in a folder it shares with its widgets on
  your device, and a list of up to 500 of your notes' names and folders to choose from, none from folders you hid.
  A to-do you tick in the widget waits there, with the reminders it took back, until Notebook has written the tick
  into its note. It never leaves the device.
- **The search index** of file names, the text of notes and PDFs, and the words Notebook reads in pictures, scanned
  pages and handwriting is kept in the app's caches on each device, so search is ready the moment the app opens. Each
  device builds its own from your files, and it never leaves the device.
- **Spotlight** gets the name, the first lines, the folder and the text of every note in your locations, except those in
  hidden folders, so the system's search finds them. Spotlight keeps its index on your Mac, iPhone or iPad, as it does
  for Mail or Notes, and it never leaves the device. Notebook keeps a list of the notes it gave Spotlight, by their
  places in your folders, in the app's own folder on that device. A note leaves Spotlight when you delete it, hide its
  folder or remove its location. To leave Notebook's notes out of Spotlight, turn Notebook off in System Settings ›
  Spotlight on the Mac, or in Notebook's search settings in Settings on iPhone and iPad.
- **The camera** on iPhone and iPad is used only when you take a photo or scan a document into a note, and only after
  you have allowed it. **Photos** are chosen in the system's photo picker: Notebook receives only the pictures you pick.
  Either is saved next to the note, like any other picture.

On iPhone and iPad, deleting the app deletes everything it stored on the device, along with the notes kept in its own
folder there. On the Mac, the app's preferences, its search index, its list of the notes in Spotlight and the versions
of notes outside iCloud stay in its container, `~/Library/Containers/com.lukaskbl.Notebook`, until you delete that
folder too. The folders you hide, your reminders and your Home and Work stay in iCloud's key-value store for your other
devices, and the versions of notes in iCloud in Notebook's iCloud folder, until you delete it in iCloud's storage
settings. Your notes are your files and stay where they are.

## What is sent, and to whom

- **Nothing of yours, with one exception you start:** searching for a place for a reminder or a to-do asks Apple Maps,
  as the Maps app does, with the words you type; Current Location asks it for the address of where you are, an address
  you pick from Contacts for Home or Work asks it where that is, and the map in Remind Me loads from it. Notebook has no
  other code that connects to the internet. Pictures in notes that point to a web address are not downloaded; Notebook
  shows the address instead.
- When you click or tap a web link in a note, your browser opens it.
- If your notes are in iCloud Drive, Apple syncs them as it syncs every other file there; Notebook asks the system to
  download notes that aren't on your device yet, so it can show and search them. Apple syncs the earlier versions of
  those notes, in Notebook's own iCloud folder, the same way. What Apple does with iCloud Drive is
  described in [Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Sample notes

Try Sample Notes… on the first screen writes sample notes to a folder Sample Notes, in the folder you pick on the Mac
and in Notebook's own folder on iPhone and iPad; Debug builds can also write them to a folder you name
(`-NotebookDemo YES`), for the README's pictures. They are made up, and nothing about them is sent anywhere.

## Questions

Write to [notebook.app@icloud.com](mailto:notebook.app@icloud.com) or open an issue in the
[repository](https://github.com/lukaskaibel/notebook/issues). Security problems are best reported privately, as described
in [SECURITY.md](SECURITY.md).
