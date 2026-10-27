# Changelog

Everything users would notice, newest first. The format follows [Keep a Changelog](https://keepachangelog.com), and
versions follow [semantic versioning](https://semver.org).

## [Unreleased]

### Added

- New Note as a widget and a control: the widget on the Home Screen and the Lock Screen of iPhone and iPad and on the
  Mac's desktop, the control in Control Center, on the Lock Screen and on the iPhone's Action button. A tap opens
  Notebook with a new note in your default folder and the caret in its title, as New Note in Shortcuts does. The
  widget shows Notebook's icon and the pencil in its ink; on the Lock Screen it is the pencil alone, or with its name.
- Share to Notebook, on the Mac, iPhone and iPad: text, links, pictures and PDFs from any app's share sheet become a
  new note in your default folder, named after the page or the first line, or go at the end of the note you opened
  last. Pictures and files go into the note's `.assets` folder, as when you add them in a note. Notebook writes them
  into your notes as soon as it's open; when that note is open in Notebook, they go in as one step of Undo.
- A Today widget, as Reminders has one: the to-dos for today and the overdue ones, overdue first and in red as in
  To-dos, on the Home Screen and the Lock Screen of iPhone and iPad and on the Mac's desktop. Tick a to-do in the
  widget and it shows ticked at once, its reminder gone; Notebook writes the tick into its note as To-dos would the
  next time it opens, and keeps it until it can. Tap again to untick it before then. A to-do changed meanwhile, on
  another device say, is left as it is, and Notebook tells you. A tap anywhere else opens To-dos or the to-do's note.
  It moves on by itself at midnight and when a to-do's time passes.
- A Note widget that shows a note of your choice, its title and as much of it as fits, with its headings, lists,
  to-dos, links and bold or struck text as in the note. Pick the note under Edit Widget, from the notes you opened
  last or by searching their names. It follows the note when you rename or move it in Notebook, and a tap opens it.
  A note in a folder you hid isn't shown or offered there, and one you throw away says so.
- Sort the notes and files in a folder by date edited or date created, newest first, as well as by name: View › Sort By
  on the Mac, Sort By in the ⋯ menu on iPhone and iPad, where it says how a folder is sorted now, in Settings › Sidebar
  (Settings › Files on iPhone and iPad), and in ⌘K. The order goes for every folder, the sidebar and the lists alike;
  Keep Folders on Top stays a choice of its own, next to it. When the newest come first, the note you write in moves to
  the top of its folder once what you typed is saved, and its folder moves up among the others, as in the Finder: the
  row slides there and stays selected, and the sidebar goes with it if it was on screen. On iPhone and iPad a note's
  date in a list is the one it is sorted by.
- To-dos that repeat, as with Obsidian's Tasks plugin: tick off a to-do with `🔁 every week` (or `every weekday`,
  `every 2 weeks on Friday`, `every month on the last`, `every year`, `… when done` and the other rules Tasks reads), in
  the note, in To-dos or in its notification, and the next one is written above it with its dates moved on, while the
  one you ticked gets the day it was done, `✅ 2026-10-26`, as Tasks writes them. Its due date, time, scheduled and
  start dates keep their distances, a day the next month doesn't have becomes its last day (31 January, every month,
  is next due on 28 February), and its reminder moves to the next one. One Undo takes both back, and unticking it in
  To-dos while it still shows ticked does too; unticking it in the note doesn't make another.
- Import from Apple Notes, on the Mac, iPhone and iPad. Export notes from Notes as Markdown first: on the Mac, select
  the notes of a folder and choose File › Export as › Markdown; on iPhone and iPad, Share › Export as Markdown, one note
  at a time. Then choose File › Import from Apple Notes… in Notebook, or Import from Apple Notes in the ⋯ menu, and pick
  the folder Notes made. Its notes come into the folder you're in, each with its pictures and files in the `.assets`
  folder next to it, so they move with it, as Notebook's own do. Files Notes wrote without an extension get one, links
  between the notes you exported keep finding them, the title Notes repeats as the first line goes, and the folders you
  put the exports in come along. Notes' export itself is only read, nothing in your folders is written over, what
  couldn't come over is listed, and one Undo takes the whole import back.
- Version history: Notebook keeps earlier versions of your notes as you write. It keeps the note as it was when you
  start changing it, a version every ten minutes while you write, and one when you stop. On the Mac, File › Revert To ›
  Browse All Versions… shows them by day next to the one you pick, as the note looks. Show Changes marks what was added
  since then in green and what was taken out in red, word by word where a line changed. Restore puts a version back as
  one change Undo takes back, and keeps the text you had as a version first; Revert To › Last Opened goes back to the
  note as you opened it. On iPhone and iPad, Version History is in the note's ⋯ menu.
  - **Where they're kept:** the versions are plain Markdown copies. Those of notes in iCloud are in Notebook's own
    iCloud folder, which iCloud Drive doesn't show, so they reach your other devices. The rest stay on the device.
  - **How long:** everything from the last hour, then one an hour for a day, one a day for a month and one a week for
    a year.
  - **Merges and conflicts:** before a change from elsewhere is merged in or a conflict is settled, both texts are
    kept, so the one you didn't keep can be brought back.

### Changed

- Notes are saved in the background, on the Mac, iPhone and iPad: a slow disk, or iCloud holding a note while it puts
  in another device's version, no longer makes the window wait when you pause typing, leave a note or switch apps.
  What you type meanwhile is saved right after. A note you have just left is still written, and quitting, renaming,
  moving or putting it in the Trash waits for it, so what you typed goes along.
- Search and ⌘K find names loosely, as Spotlight does, and put the best first: by the starts of their words ("kytr"
  finds Kyoto trip), and with a letter or two wrong ("ryokna" finds Getting to the ryokan, "seting" finds Settings).
  In a big library, names that only have the letters typed somewhere in them ("kyo" in Workout family notes) no longer
  crowd the files above the notes with the words in them: they come last, under Similar Names, and such commands
  under Similar Commands.

### Fixed

- A note open in the main window and in a window of its own no longer makes Notebook hang as you type in one of them.
  Each window now shows what was typed in the other, and quitting with both open quits.
- Leaving a note a moment after another device changed the same lines no longer loses what you typed since the last
  save. Notebook can't ask any more, so it keeps both: the note keeps the other device's version, and what you typed
  goes into a copy next to it, named after your Mac or device, such as "Gift ideas (Anna's iPhone)". The same goes for
  closing a note's own window on the Mac and for quitting.
- A note whose file another app replaces with a new version, the way some apps save, stays open and takes the new
  version in, rather than closing as if it had been deleted.
- Leaving a note you took pictures out of no longer downloads the other notes in its folder from iCloud to see whether
  they use those pictures: with one of them still in iCloud, the pictures stay.
- On the iPad, the Format popover (Aa in the toolbar) cut off Body, the last of the text styles; all four fit now.
- On iPhone and iPad, On My iPhone (On My iPad) chosen itself as a location was called "File Provider Storage", the
  name of its folder on disk, on the first screen, in the sidebar and in Settings. It now has the name the Files app
  gives it, also where you added it before.
- On iPhone and iPad, a note opened from another app, such as with Share in the Files app, couldn't be renamed or take
  pictures and drawings when it isn't in one of your locations, since the system gives Notebook only the file. The
  first time it needs the note's folder, Notebook now asks for it, with the Files app's picker open at that folder, and
  remembers it after that.
- On iPhone and iPad, at the largest text sizes (Settings › Accessibility › Larger Text), the names in the sidebar and in
  the lists of files go on over a few lines, as in the Files app, rather than losing their middle ("Gett…kan").
- On iPhone and iPad, the Files app shows On My iPhone › Notebook (On My iPad › Notebook), the folder Keep Notes on
  This iPhone uses, so its notes can be opened, shared and backed up from there. It was missing.
- The sidebar on the Mac no longer scrolls back to the open note each time it is saved while you look at another part
  of it.
- In the Mac's sidebar, Tab now goes on into the note that is open, with the caret where it was, as Tab goes from the
  list to the note in Notes and Mail. Moving a file to the Trash from the sidebar opens the next file in its folder, or
  the one before it at the end, as Notes shows the next note; before, the note opened before it came back, wherever it
  was, and the sidebar jumped there. VoiceOver calls the outline next to the note "Outline", not "Sidebar".

## [1.0.0] – not released yet

The first version: notes as Markdown files in your own folders, on the Mac, iPhone and iPad. While it was being built,
it was called Folio. What is under Changed and Fixed is against the earlier builds on TestFlight.

### Added

- Drag pictures, drawings and files around a note on the Mac, as on iPhone and iPad: press one and move the mouse, and
  it goes on a line of its own before the line you let go on, or after it when you let go at its end. One Undo puts it
  back, and Option-dragging leaves the picture where it was and drops a copy. Drag one into another note for a copy
  there, with its file, or onto a folder in the sidebar, into the Finder, Mail or another app for a copy of the file;
  the note keeps its own. Photos from Photos and pictures from Safari can be dropped into a note too.
- Notes in Spotlight, on the Mac and in the search of iPhone and iPad: Spotlight finds every note in your locations by
  its name or any word in it, with its first lines and its folder, and picking one opens it in Notebook. Spotlight
  follows as you write, rename, move and delete notes; notes in hidden folders stay out, and so do the notes of a
  location you remove. Search in App takes the words you typed in Spotlight to ⌘K. Notebook gives Spotlight what search
  has already read, in the background, and after a launch only the notes that changed since.
- Try Sample Notes… on the first screen, to look around before you add your own folders: made-up notes, a drawing,
  pictures and PDFs in a new folder Sample Notes, in a folder you pick on the Mac and in Notebook's own folder on iPhone
  and iPad. It shows in the sidebar like any location, and removing it leaves the files where they are.
- Acknowledgements: Notebook's licence and those of BeautifulMermaid, SwiftMath and elk-swift, which it is built with,
  with links to their source code, in Notebook › About Notebook on the Mac and Settings › Acknowledgements on iPhone and
  iPad.
- New Note in Shortcuts, Spotlight and Siri, on the Mac, iPhone and iPad: it opens Notebook with a new note in your
  default folder and the caret in its title, ready to type, as ⌘N does with nothing open. It is there without setting
  anything up ("New note in Notebook"), and on an iPhone with an Action button you can put it there under Settings ›
  Action Button › Shortcut. In a shortcut of your own, New Note takes text for the note to start with.
- Links follow notes, files and folders you move, as they follow a note you rename: drag a note onto another folder,
  choose Move To, or rename or move a folder, on the Mac, iPhone and iPad, and the `[[links]]`, embeds and Markdown
  links to them in your other notes still open the same note or file. A link changes only where it would find
  something else now, such as when another note of the same name comes first, and then says no more than it takes,
  such as `[[Archive/Plan]]`, as in Obsidian. The links in a note you move, and in the notes in a folder you move, keep
  finding what they found too, and so do links in the front matter. Undo puts every link back as it was; a copy
  (Option-drag) or a duplicate changes none. A note from outside your locations, renamed in its own window, takes the
  links to it in the notes next to it along.
- Choose where new notes go when they aren't made in a folder: Settings › General › Default folder on the Mac, Settings
  › Default Folder on iPhone and iPad. That is ⌘N with no note open and no folder selected, and New Note on the
  iPhone's first screen. Every folder of your locations is there, indented as in Move To; until you choose one, it is
  the Inbox at the top of your first location, as before. Rename or move the folder in Notebook and it stays the
  default; throw it away and new notes go to the Inbox again.
- Customize Folder…: right-click a folder in the sidebar, or touch and hold it on iPhone and iPad, and give it a colour
  and a symbol or an emoji in place of the folder. Over 300 symbols and the emoji come in groups, with a few suggested
  for the folder's name, and a search finds them by name or by what they are for. Notebook keeps them where the
  Finder's own Customize Folder does, on the folder and as a colour tag, so they move with the folder, reach your other
  devices through iCloud Drive and show in the Finder too; a folder customized in the Finder shows the same in
  Notebook. Undo takes it all back in one step.
- To-dos, at the top of the sidebar: every open checkbox in your notes in one list, as in Reminders, grouped into
  Overdue, Today, Tomorrow, Next 7 Days, Later and No Date, with the lines indented under each to-do as its notes and
  the note it is in. Notes with a reminder are there too, and the number next to To-dos counts what is due today or
  overdue. Tick a to-do or a sub-to-do off and it is ticked in its note; a to-do ticked off stays three seconds, ticked,
  before it fades away, so you see it done and can untick it. Click the note's name to open the note at it; drag a
  to-do into another group, or choose Today, Tomorrow, This Weekend or Next Week in its menu, to move its date.
  ⇧⌘R and ⌘K go there too. On the iPhone it is the first row of the first screen, on the iPad the first row of the
  sidebar.
- Editing in To-dos, as in Reminders: click a to-do's words to change them where they are, and the lines under it too.
  A Notes line comes in under the words, where what you type becomes an indented line under the to-do, and under it
  capsules for its date, its time and its place, as Reminders has them (once set, the value in the accent colour with an
  × that takes it away; until then a grey symbol), and one for a sub-to-do, sliding in as you click and away when you're
  done.
  Shift-Return starts a line under the words; Return in it starts the next one, Tab and ⇧Tab move it in and out, and
  `[ ] ` or `- ` typed at its start make it a sub-to-do or a point. Sub-to-dos show with circles of their own under
  their to-do.
- A to-do's date, time and place in a dropdown you can type in, as in Issues: on the Mac a glass dropdown under the
  button, on the iPad a popover, on the iPhone a sheet. Type "thursday in 3 weeks", "fri 9am", "the 12th" or "930" and
  pick what it could mean with the arrow keys and Return, or click Today, Tomorrow, This Weekend, Next Week or a day in
  the month; a time of day or one typed; a place by its name in Apple Maps, where you are, Home or Work, or one you used
  before, and whether it's for arriving or leaving. On iPhone and iPad the buttons above the keyboard open them, and so
  does a tap on the date or place under a to-do being edited. Those buttons are a bar of glass across the screen, as in
  a note: a grey symbol for what isn't set, and once it is, the day, the time or the place on a tint of the accent
  colour, as the pills in a note show them (red once it's overdue), with the button that hides the keyboard on its own
  at the right.
- Settings › Sidebar › Show To-dos (on iPhone and iPad, in Settings) turns To-dos off, for when you keep your to-dos in
  another app: the list goes, and Notebook doesn't remind you of to-dos.
- Obsidian's other checkboxes: `[/]` in progress shows a half-filled circle, `[-]` cancelled a grey one with the to-do
  struck through, and the marks of Obsidian's themes and the Tasks plugin, such as `[!]`, `[?]`, `[*]` or `[>]`, their
  sign in the circle. All but done and cancelled are still to do. A to-do's menu in To-dos marks it in progress or
  cancelled.
- Dates written by Obsidian's other plugins count too, and keep their way when they change: the Reminder plugin's
  `(@2026-10-24 14:00)`, the Kanban plugin's `@{2026-10-24} @@{14:00}`, and Dataview's `[due:: 2026-10-24]` and
  `🗓️2026-10-24`. The Tasks plugin's other fields, such as priority (`⏫`), repeating (`🔁 every week`) and scheduled
  (`⏳ 2026-10-26`), show as grey pills and stay as they are.
- A to-do's date, time and place in a note: click the bell that comes up after a to-do as you point at it, or the pill of
  its date or place, for the same dropdown as in To-dos (on iPhone and iPad tap the pill), or right-click it and choose
  Remind Me… for both at once; on iPhone and iPad tap the bell above the keyboard. They show as pills after the to-do's words, red
  once the time has passed, and are written into the note the way Obsidian's Tasks and Reminder plugins write them
  (`⏰ 2026-10-24 14:00`, `📅 2026-11-01`, and a place as a link to Apple Maps), so they go along with the note. At that
  time, or when you arrive at or leave the place, a notification brings the to-do and its notes, with Remind Me in 1
  Hour and Done.
- Reminders at a place: Remind Me… for a note or a to-do can take a place, found in Apple Maps or where you are now, for
  arriving or for leaving, shown on a little map. iPhone and iPad remind you there, once, when you let Notebook use your
  location while you use it; a Mac can set the place, and your iPhone reminds you.
- Home and Work as a reminder's place, as in Reminders. Apps can't read the Home and Work Apple Maps shows, so the first
  time you tap one you choose its address: on iPhone and iPad from your own card in Contacts, where Maps has them, or
  where you are now, or by searching. Notebook sees only the address you tap and keeps it, through iCloud, for your other
  devices too. Touch and hold it, or right-click it on the Mac, to change the address or forget it.
- Notebook on iPhone and iPad, with the editor, search and files of the Mac. On the iPhone, one folder per screen as in
  the Files app, with search and a new note at the bottom as in Notes; on the iPad, the Mac's sidebar, the note and its
  outline.
- A bar above the keyboard with the text styles and formatting, a checklist, a link, and pictures from the camera, the
  document scanner, Photos or the Files app.
- Swipe actions and menus on touch and hold for files, drag and drop of files and pictures, and the Mac's keyboard
  shortcuts and menus on an iPad with a keyboard.
- Notes as a PDF to share, or printed, on iPhone and iPad.
- On iPhone and iPad, the bar above the keyboard floats over the note as in Notes and scrolls a page of tools at a
  time; Settings › Writing Bar chooses its tools and their order. Aa opens the Format panel in the keyboard's place.
- Touch and hold a picture or file in a note and drag it to another place in the note, or let go to copy, cut, share or
  delete it.
- Drawings in notes, as in Notes. The pencil in the toolbar starts drawing where you are without moving the note: in the
  drawing on screen, or in a new one below the line you're writing on (at the end of the note, or in the middle of the
  screen, when you aren't writing), as wide as the text and with no frame around it; it grows as you draw near its lower
  edge, and at the end of the note you can draw anywhere below the text. On iPhone and iPad with Apple Pencil or a
  finger and the system's tool picker, and on the iPhone Undo at the top (touch and hold it for Redo); on the Mac with
  the mouse, the trackpad or a tablet, and a pen, pencil, marker and eraser at the bottom of the note. Each drawing is a
  PNG in `.assets` that other apps show, with its strokes in a `.drawing` file next to it, so it stays a drawing you can
  go on with in Notebook.
- Hide folders you don't want to see, such as the ones other apps keep in iCloud Drive: right-click one and choose
  Hide Folder, or on iPhone and iPad touch and hold it. Hidden folders leave the sidebar, the lists, search and Move
  To, and stay hidden on your other Macs, iPhones and iPads through iCloud. To see them again, dimmed, click the eye
  next to the location's name or press ⇧⌘.; on iPhone and iPad, choose Show Hidden Folders in the ⋯ menu. Links to
  notes in them keep working.
- Add Location at the bottom of the sidebar, to show another folder there. A folder dropped from the Finder on the
  sidebar, between or below its sections, is added the same way.
- New folders from the sidebar, as in Mail and Photos: point at a location's name and click the folder with a plus
  that comes up next to it for a folder at the top of the location, or right-click a folder and choose New Folder for
  one inside it. The folder comes up selected and named New Folder, ready to type over, as in the Finder, at once even
  in a large iCloud Drive; it works in iCloud Drive's Desktop, Documents and app folders too. On the iPhone, New Folder
  is at the bottom of the first screen, as in Notes, and asks which location when you have several; on the iPad the
  button comes up under the pointer.
- Reminders of notes: choose Remind Me… for a note and pick Later Today, This Evening, Tomorrow or a date and time. At
  that time a notification brings the note's name and its first points, what is still to do first, and gets through a
  Focus; tap it to open the note, or choose Remind Me in 1 Hour or Done. A note with a reminder shows a bell and the
  time under its title and in its row, where a click changes or removes it. Remind Me… is in the note's ⋯ menu, the
  sidebar's right-click menu and the inspector on the Mac, and in the ⋯ menu, on touch and hold and, if you add it in
  Settings › Writing Bar, as a bell above the keyboard on iPhone and iPad. Reminders aren't written into the note;
  they follow it when you rename or move it in Notebook, and reach your other devices through iCloud.
- Type the time of a reminder in a few words: Remind Me… has a field at the top that reads "friday evening", "tomorrow
  at 9", "fri 3pm", "in 3 weeks", "in 2 hours", "next monday", "the 12th" or "12.11.", and shows what it could mean as
  you type, with the date and time below following the one that is lit. Return or a click takes it; the arrow keys go
  through the others. A day without a time is at nine in the morning.
- On iPhone and iPad, touch and hold the bar above the keyboard, or tap the sliders after its last tool, to choose its
  tools and their order right there, without going to Settings.
- ⌘K is back: a field over the window, as Spotlight's, that finds everything search finds and runs commands. Commands
  for the note that is open (Rename, Move To…, Duplicate, Add to Favorites, Remind Me…, Drawing, Copy Link, Show in
  Finder, Export, Print, Move to Trash), the text styles, New Note and New Folder, Add Location, Back and Forward, the
  sidebar, the outline, the text size, the typeface and Settings, each with the keys that do it without ⌘K. A few letters
  find a command; `>` first lists only commands. Move To… lists the folders to move into as you type. On an iPad with a
  keyboard too.
- Search finds every kind of thing: folders, the headings in notes, words in any order (with the notes that have them
  together first), the text in pictures in your folders and in notes, in scanned PDFs, and handwriting in drawings.
  Pictures, scans and drawings are read on the device in the background, once each; Settings › General › Search (on
  iPhone and iPad, Settings › Search) turns it off.
- A note found by search opens where the words are, scrolled there with them selected, and on the Mac they bounce as
  Find does in Safari; a PDF opens at the page with them, a heading where it is, and a picture in a note with it
  selected.
- Typing Markdown as in Notion or Bear, on the Mac, iPhone and iPad, the same as in Issues. Bold (⌘B, or the bar)
  inside bold text takes the bold off, and a second press puts it back; at the end of bold text it leaves the bold, so
  you type on plainly, and just behind it it goes back in. The same goes for italics, strikethrough, highlights and
  code.
- Return at the end of bold text goes to the next line and leaves the `**` behind; in the middle of it, the bold goes on
  in the next line. A list goes on with its next bullet, number or checkbox, as before.
- A style's marks go as a pair. Deleting a star takes one from the other end too, so `**bold**` becomes italics and
  then plain text; typing a star there again brings them back the same way, and a star typed at either end of italics
  makes them bold. Other styles lose both marks at once, and a selection that holds one mark takes the other with it.
- `-` at the start of a line makes a bullet with its space, and `-[]` a checkbox; `---` still makes a rule. A closing
  mark typed where the same one already is steps over it.
- Text eases into its new look while you type: bold thickens and thins, a heading grows, italics slant, and new marks
  fade in. Reduce Motion turns it off.
- On iPhone and iPad, buttons for where the caret is come in on the left of the bar above the keyboard, each a circle
  of glass, two at most so the tools keep their room: opening the link the caret is on, a to-do's reminder, the style
  you are in, tinted (a tap takes it off), and moving a list item in or out. A to-do is ticked on its own checkbox in
  the note. On the right of the bar, always, a circle of its own hides the keyboard.
- Marks unfold next to the caret and fold away behind it instead of popping in and out, and the text beside them slides
  along: the stars of bold as you arrow into it, the `##` of a heading, the stars you just closed as you type on.
- Text typed right after `##` gets the space a heading needs, so `##Plan` becomes the heading Plan, and so does a line
  you type `##` in front of. One `#` is left alone, as it may start a tag.
- Typing `**` puts in the closing `**` too, with the caret between them, so you type straight into bold; typing the
  closing stars yourself steps over them, and a space right after `**` leaves them plain stars (`2 ** 3`). The same
  goes for `~~` and `==`.
- Return at the start of a heading puts an empty line above it, and Return on a heading without text makes it body
  text again.
- From the title, Tab, ↓ and → at its end go on into the text, and ←, ↑ or Delete at the very start of the text go back
  to the end of the title, on the Mac and on an iPad or iPhone with a keyboard. Holding Delete stops at the start of
  the text rather than going on into the title.
- Undo and Redo for changes to files, as in the Finder. Edit › Undo (⌘Z) puts a note or folder you moved to the Trash
  back where it was, with its reminders, and opens it again if it was open; it takes back a rename (links to the note
  follow it back), a move, a drop, a copy, a new note or a new folder, and Redo (⇧⌘Z) makes it again. Typing in the
  note and changes to files come back in the order you made them. On iPhone and iPad the same works with a keyboard,
  and a note deleted where there is no Recently Deleted comes back too, while Notebook is open.
- Delete new notes left empty, a switch in Settings › General on the Mac and Settings › Notes on iPhone and iPad. It
  is on at first, so a new note you leave without a title or text is deleted, as if you had never made it; turn it off
  to keep such notes.
- Double-click a note in the sidebar on the Mac to open it in a window of its own, as a note opened from the Finder;
  more of them join it as tabs. Open in New Window in its menu does the same.
- Locations: iCloud Drive or any folder in the sidebar, with favourites, read in place and watched for changes.
- iCloud Drive as the Finder shows it, with Desktop, Documents and the folders of apps such as Pages or Obsidian.
- A live-preview editor: Markdown marks show only next to the caret, and heading levels in the margin.
- Headings, bold, italic, strikethrough, highlights, inline code, links, checklists, lists, quotes, callouts, tables,
  code with highlighting, LaTeX maths, Mermaid diagrams, footnotes and folded front matter.
- A copy button in the corner of the code block under the pointer, and Copy Code when you right-click one.
- Pictures, `[[links]]` and `![[embeds]]` as objects; pictures and files pasted or dropped in go to `.assets`.
- The title is the file name; renaming a note updates the links to it.
- Search with ⌘F across file names, note text and PDF text.
- Back and forward with ⌘[ and ⌘], or with a swipe as in Safari.
- PDFs, pictures and videos in the window as in Preview and QuickTime Player, there at once: PDFs back where you
  left them, pictures to zoom in on with a pinch or a double click. Quick Look for every other file.
  The inspector shows a file's details.
- The outline of a note in the inspector, with a word count.
- Saving as you type, with a three-way merge when a note changed somewhere else, and a choice when both changed the
  same lines.
- Export as PDF or PNG, and printing.
- Markdown files opened from the Finder or with ⌘O in windows of their own; folders opened either way go to the
  sidebar.
- Settings for the typeface, size, line spacing and line width, and for what the sidebar shows.
- A leather notebook as the app icon. Make it your own in Settings › App Icon: the leather, the elastic band, the
  ribbon and the background, shown in the Dock while Notebook is open. A tip in the sidebar points there.
- Ink blue as Notebook's accent colour, for links, the caret and folders, when the accent in System Settings is set
  to Multicolour.

### Changed

- A picture or file copied from a note and pasted, or dropped from another note, in the middle of a line goes on a line
  of its own, as a picture from another app does. Text dragged into a note in another folder brings its pictures along,
  as copied text does. On iPhone and iPad too, a picture dragged to the end of a line now goes after that line.
- Notebook's source code is now under the GNU General Public License, version 3, in place of the MIT License, with a
  permission to link it with elk-swift, which lays out the diagrams. Copies from before 24 October 2026 can still be
  used under the MIT License.
- Remind Me… has Date, Time and Location to turn on, as a reminder's details in Reminders, next to Later Today, This
  Evening and Tomorrow.
- Double-clicking a PDF, a picture or any other file in the sidebar opens it in its own app, such as Preview or
  QuickTime Player, as in the Finder, rather than in Quick Look; Space still opens Quick Look, and the file's menu has
  Open in Preview (or its app) next to it.
- A note from your locations in a window of its own, opened from the sidebar or the Finder, links to notes in every
  folder of the location as the main window does, and renaming it there updates the links to it in other notes, with
  Undo in the main window.
- Checkboxes are circles, as in Notes and Reminders, filled with the accent colour when done. On iPhone and iPad they
  are bigger, for a fingertip.
- Folders are read in the background, on the Mac, iPhone and iPad. A location you add shows at once and its files a
  moment later, together with the folders you had open; a folder opens straight away and fills in as it is read; and
  iCloud syncing thousands of files doesn't hold up the window. Folders on screen are read ahead, so they usually open
  with everything already in them.
- Search has every note and file the moment Notebook opens: what it read is kept between launches, and after launch it
  reads only the notes and PDFs that changed since. Reading all your files the first time is several times quicker
  too.
- On iPhone, a folder that takes a while to read shows a spinner instead of "No Notes".
- A PDF or picture that is read at once shows at once, as in Preview, instead of fading in; it fades in only after a
  wait you could see, such as a download from iCloud.
- On the Mac, the sidebar's icons are the size Notes has: large for a location's own folders and files, smaller inside
  a folder, with the names and the indent where Notes has them.
- Where you pick a text style, each looks as it does in the note: Title, Heading, Subheading and Body in the Mac's Aa
  menu, in the Format panel on iPhone and iPad and behind the heading level in the margin, in the note's typeface. On
  the iPad the heading level opens them next to it. In Settings › Text each typeface is shown in itself, on iPhone and
  iPad in a list of its own.
- On iPhone and iPad, New Note is a button of glass in the accent colour, so it stands out from the buttons around it.
  On the Mac it is a plain button of its own right of Back and Forward, and stays there when the sidebar is hidden.
- More menus have symbols next to their items, as the ⋯ menu has: Move To's folders, Export As, the menu of a picture
  in a note, Copy Code, and the commands of the menu bar on the Mac and the iPad.
- Bold and the other styles at a caret inside a word style the whole word, instead of putting in an empty pair of
  marks. Part of bold text selected loses its bold and the rest keeps it. Italics are written `_like this_`, or with
  `*` inside a word, where `_` doesn't work.
- Markdown marks show next to the caret where you type with keys: on the Mac, and on an iPad or iPhone with a keyboard
  attached. On the touch keyboard they stay hidden and the bar above it shows the styles you are in; there Delete
  takes the letter you see rather than a hidden star, so bold text stays bold, and a tap at the end of bold text types
  on in bold, as in Notes.
- A heading's `#`s show while the caret is on it with a keyboard, as the stars of bold do, next to its level in the
  margin, so the arrow keys reach them and Delete takes them. On the touch keyboard they show while you type them,
  until you leave the line, and a heading picked from the Format panel shows only its level. Two or more `#`s show
  their level at once.
- A new note you type in and then empty again is deleted when you leave it, as one you never typed in is. On the Mac,
  so is a new note left empty when you quit, which before stayed behind for good.

### Fixed

- A picture or file dropped or pasted at the start of a heading or a list item went between its `##` or bullet and its
  words, which broke the heading or the item. It now goes on a line of its own before it, and at the end of a line
  after it, past marks such as the closing `**` of bold text.
- In the App Store build, a note opened from the Finder outside your locations couldn't be renamed or take pictures and
  drawings, since the sandbox gives Notebook only the file. The first time it needs the note's folder, Notebook now
  asks for it, and remembers it after that.
- If you had changed the bar above the keyboard in Settings › Writing Bar, tools that came later, such as Drawing,
  never joined it. They now come in where they stand in the standard bar, once; tools you took out stay out.
- On iPhone and iPad, a location's name over its folders brought up no menu, though it should have: touching and
  holding it did nothing. A tap on the name now brings up New Note, New Folder, Add to Favorites, Share, Show Hidden
  Folders and Remove from Notebook.
- On iPhone and iPad, opening a note could keep Notebook busy for seconds in a location with thousands of folders,
  such as a whole iCloud Drive: the ⋯ menu made an item for every folder under Move To, each time. Move in the ⋯ menu
  and in a file's touch-and-hold menu now asks where to in a sheet, as swiping a file does and as the Files app asks.
- Saving a note took away its Finder tags, and whatever else other apps keep on the file, such as where it was
  downloaded from; so did ticking a to-do off in To-dos and links changing after a rename or a move. They stay now, and
  so does the date the note was made.
- Editing a to-do in To-dos could stop by itself as soon as you moved the pointer after clicking it, so it took a
  second click. Now it goes on until you press Return or Escape or click outside the to-do, also beside the list, on a
  group's name or in the sidebar, which before didn't end it. A to-do given another date while you edit it stays in
  editing in its new group.
- Renaming a note also changed the links to another note of the same name in another folder, and could leave links
  finding a third note of the new name. Now only links to the note renamed change, in every location, and no link
  written in code. Links to a renamed PDF, picture or other file follow it too.
- A note moved into a folder whose `.assets` already had a different picture of the same name showed that picture
  instead of its own, and its own went to the Trash. Its picture now comes along under a name of its own.
- Links in a note opened while Notebook was still reading your folders showed as links to notes that don't exist yet.
- Giving a new note its name could stop Notebook for a long time in a large folder in iCloud Drive. Renaming a note
  still updates the links to it in other notes, now in the background.
- Adding iCloud Drive as a location kept Notebook busy for a few seconds.
- Opening a note that was only in iCloud, not yet downloaded, stopped Notebook until iCloud had brought it down, on the
  Mac, iPhone and iPad. The note now opens at once with its title, and its text fades in when it has come, with
  "Downloading from iCloud…" if that takes a moment. Nothing can be typed into it before then, so nothing is lost or
  saved over it.
- On the Mac, the caret on an empty line left a small piece of itself below the line while it blinked, and under a
  heading it was as tall as the heading. It is now as tall as the text and sits where the text will go, on empty lines
  and at the end of a line too, on the Mac, iPhone and iPad.
- The caret sat about 2 points too high next to the text, ending above the tails of letters such as g and y. It now
  reaches from just above the tallest letters to just below the tails, on the Mac, iPhone and iPad.
- Opening a note was slow in a large location such as a whole iCloud Drive: up to a second, and many seconds for a note
  with dozens of links, because every link was looked for among all the files. Links are now found by their names at
  once.
- Renaming, making, duplicating, moving or deleting a note or folder could stop Notebook for a moment in iCloud Drive,
  while iCloud took the change. Now these are written in the background, on the Mac, iPhone and iPad: what you did
  shows in the sidebar as soon as it is done, a new name stays on the row from the moment you type it, and what you
  type into a note while it is renamed is saved under its new name.
- Moving a note that was still in iCloud stopped Notebook until it had come down. It now moves at once, and its
  pictures follow when it has.
- A renamed folder closed in the sidebar, and a note open in it showed its pictures as not found and its links as
  missing until you opened it again. The folder stays open now, with the folders that were open in it, as in the
  Finder, and the note keeps its pictures and links.
- On iPhone and iPad, choosing the folder a file is already in from Move renamed it with a 2. Now nothing happens.
- Renaming a package, such as a Pages document, dropped its extension.
- Opening a note in a location with thousands of folders also waited for Move To to list them all, in the File menu
  and the ⋯ menu, every time. Move To now lists the folders when you open it, indented as in the sidebar's menu.
- Typing in search with a whole iCloud Drive took most of a second for every letter; it now keeps up with your typing.
- Search could still lag behind your typing in a large iCloud Drive, as every letter went through every file before
  the window could go on. It now runs in the background on every core, a few milliseconds a letter, and the results
  stay until the new ones are there. While Notebook reads your files after launch, search finds what it has read so
  far instead of nothing.
- Lines found by search showed their Markdown, such as a picture's address or a table's bars; they now read as in the
  note.
- A new folder lost its name field in the sidebar a moment after it came up, so it kept the name New Folder. Renaming
  in the sidebar is no longer ended by changes in other folders either; they show once the name is in.
- After renaming the folder selected in the sidebar, ⌘N made the folder again under its old name for the new note. A
  renamed folder now also stays selected, as in the Finder.
- Checkboxes and bullets sat two points above the middle of their text, and so did the heading level in the margin, the
  icons of links and callouts, and maths within a line. They now line up with the text.
- Going back into a table, formula or diagram while typing, such as with Backspace from the line below, could leave
  its Markdown hidden although the caret was in it. It now shows as soon as the caret is back.
- A table, code block, formula or diagram at the very end of a note, with no line after it, had its box cut short while
  you edited it, and a formula's or diagram's picture lay over its last line, or below the end of the page.
- Bold, italic and the other formatting over whole lines, from the menu, a shortcut or by typing a `*` or `_`, also
  wrapped the lines' `- [ ] `, `## ` and `> `, so other apps no longer saw a list, a heading or a quote. Now the words
  of each line get it, code and empty lines are left as they are, and doing it again over the same lines takes it off
  every one.
- Bold or italic over text that ended in an emoji left the emoji outside the formatting.
- On an iPad with a keyboard, the Format menu's shortcuts other than ⌘B and ⌘I, such as ⇧⌘T for a title or ⇧⌘L for a
  checklist, did nothing. They now work in the note you are writing in.
- A space typed at the end of bold text took the bold off until the next letter, so the bold flickered while you typed.
  It stays bold now while you write; leaving the bold with Bold or Return moves such a space out of it, so other apps
  show it bold too.
- On iPhone and iPad, Tab and ↓ in the title did nothing on a keyboard; they now go on into the text, as on the Mac.
- On the Mac, ↑ from the first line into the title selected the whole title, so the next key replaced it; the caret now
  goes to its end.
- Return at the end of a heading could scroll the note by a line.
- On the Mac, the arrows next to folders in the sidebar sat lower than the folder icons, an open folder's most of all.
  They are now level with the icons, open or closed and in subfolders too.
- On the Mac, a name typed in a note's title was lost when you pressed ⌘N or went back or forward before pressing
  Return, and a new note went to the Trash with it. The name is now kept, and the next note's title no longer stays
  selected, ready to be typed over.
