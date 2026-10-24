# Changelog

Everything users would notice, newest first. The format follows [Keep a Changelog](https://keepachangelog.com), and
versions follow [semantic versioning](https://semver.org).

## [Unreleased]

### Added

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
  the month; a time of day or one typed; a place by its name in Apple Maps, where you are, or one you used before, and
  whether it's for arriving or leaving. On iPhone and iPad the buttons above the keyboard open them, and so does a tap
  on the date or place under a to-do being edited.
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
  of glass: the style you are in, tinted (a tap takes it off), the checkbox of the line, moving a list item out or in,
  and opening the link the caret is on.
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

### Changed

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

## [0.1.0] – not released yet

The first version: a Mac app for Markdown notes in your own folders. While it was being built, it was called Folio.

### Added

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
