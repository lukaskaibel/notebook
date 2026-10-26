<p align="center">
  <img src="Design/icon.png" width="128" height="128" alt="Notebook app icon">
</p>

<h1 align="center">Notebook</h1>

<p align="center">
  <b>The ease of Notes. The freedom of files.</b><br>
  A notes app for Mac, iPhone and iPad that writes like Apple Notes. Every note is a Markdown file in iCloud Drive or
  any folder you choose, right next to your other documents: no vault, no database, no sync to set up.
</p>

<p align="center">
  <img alt="Platform: macOS 27 or later" src="https://img.shields.io/badge/macOS-27%2B-34508F">
  <img alt="Platform: iOS and iPadOS 27 or later" src="https://img.shields.io/badge/iOS%20%26%20iPadOS-27%2B-34508F">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-native-34508F">
  <img alt="Built with Swift, SwiftUI, AppKit and UIKit" src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit%20%2B%20UIKit-F05138">
  <a href="#license"><img alt="License: GPLv3" src="https://img.shields.io/badge/license-GPLv3-34508F"></a>
  <a href="CHANGELOG.md"><img alt="Version 1.0.0" src="https://img.shields.io/badge/version-1.0.0-34508F"></a>
</p>

<p align="center">
  <a href="#a-quick-tour"><b>Tour</b></a> &nbsp;·&nbsp;
  <a href="#how-notes-are-stored"><b>File format</b></a> &nbsp;·&nbsp;
  <a href="#getting-started"><b>Getting started</b></a> &nbsp;·&nbsp;
  <a href="#using-it"><b>Shortcuts</b></a> &nbsp;·&nbsp;
  <a href="CHANGELOG.md"><b>Changelog</b></a> &nbsp;·&nbsp;
  <a href="https://lukaskaibel.github.io/notebook/"><b>Website</b></a>
</p>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/hero-dark.webp">
  <img alt="Notebook showing the note Kyoto trip: links to Budget and Flight tickets.pdf, a picture of a torii gate and a packing checklist; the folders of iCloud Drive in the sidebar and the note's outline on the right" src="Design/screenshots/hero-light.webp">
</picture>

> **Status: on its way to the App Store.** Version 1.0.0 runs on the Mac, iPhone and iPad; until it is in the App Store,
> you build it from source (five minutes, see below). It covers writing, organising and finding notes day to day.

## Why

Apple Notes is a pleasure to write in, but it keeps your notes in its own database. Markdown apps keep them as files,
but most of them feel like a code editor or ask you to move everything into a vault. Notebook does both: it shows the
folders you already have, iCloud Drive first, and turns the Markdown files in them into notes that write like Notes.
Pictures, PDFs and every other file sit right next to them and open in the window: PDFs and pictures as in Preview,
videos as in QuickTime Player, the rest in Quick Look. What Notebook saves is ordinary Markdown that GitHub, Obsidian or
iA Writer read just the same, and with iCloud Drive the same notes are on your Mac, iPhone and iPad.

## A quick tour

### Markdown that gets out of the way

You write Markdown, and Notebook shows the result as you type. On the Mac, and on an iPad or iPhone with a keyboard,
the marks show faintly next to the caret, only for the bit you're on, so the arrow keys reach them and Delete takes
them; they unfold as the caret comes and fold away as you move on, and the text beside them slides along instead of
jumping. On the touch keyboard they stay hidden, and the bar above it shows the styles the caret is in. A heading's `#`s
show the same way, and while the caret is on one its level sits in the margin; a click there turns it into a title,
heading, subheading or body text, each shown as it looks in the note, as in the toolbar's Aa menu. Lists continue on
Return, Tab nests them, and checkboxes tick with a click.

Typing goes as in Notion or Bear. ⌘B inside bold text takes the bold off, and a second press puts it back; at the end
of bold text it steps out, so you type on plainly. Return there goes to the next line without the `**`. Marks go in
pairs: deleting a star takes one from the other end too, so bold becomes italics and then plain text, and typing a star
there brings them back the same way; on the touch keyboard, where the stars don't show, Delete takes the letter you see
and the bold stays. Typing `**` brings the closing `**` along, with the caret between them; type the closing stars
yourself and they are stepped over. `-` at the start of a line makes a bullet, `-[]` a checkbox, and `##` gets its space
whether you type text after it or in front of a line's text, since two `#`s only ever start a heading (one may be a
tag). Return on a heading without text takes the heading
off, and at the start of one puts a line above it. The text eases into its new look as you type: bold thickens, a
heading grows, the marks fade in.

The title of a new note has the caret first, so you type its name straight away. Return, Tab, ↓, or → at its end go on
into the text, and ↑, ←, or Delete at the very start of the text go back up into the title, on the Mac and on an iPad
or iPhone with a keyboard alike. A new note you leave without a title or text is deleted again, as if you had never
made it; turn off Delete new notes left empty in Settings to keep such notes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/typing-dark.webp">
  <img alt="Typing at the end of a note: two hash marks show with the level H2 in the margin while Sunday is typed after them, then fold away into the heading Sunday, a checklist item appears, and the stars around lake and the equals signs around coffee show while the caret is next to them, then fold away into bold and a highlight" src="Design/screenshots/typing-light.webp">
</picture>

Nothing moves while you select text or hold the mouse button, so a selection never jumps. Long notes type and scroll
without a stutter.

### Pictures, links and files are objects

Pictures, `[[links]]` to other notes and files you drop in behave as in Notes: the caret steps over them, Backspace
removes one whole, and their Markdown never shows. Type `[[` for suggestions; a link to a note that doesn't exist yet
is drawn dashed and creates the note with a click. Web links show their text with a small pencil that edits the
address. A PDF or any other file on a line of its own becomes a card with a preview, and Space opens it in Quick Look.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/objects-dark.webp">
  <img alt="Further down the Kyoto note: a plan with a dashed link to the note Nara that doesn't exist yet, a web link with its pencil, a highlight, a Good to know callout, a table of days and areas, and a card for Flight tickets.pdf" src="Design/screenshots/objects-light.webp">
</picture>

Paste or drop a picture, from the Finder, Photos or Safari, and it's saved next to the note, in a hidden `.assets`
folder, as PNG or JPEG so that other apps can show it. Drag a picture or file card to another place in the note to move
it, or into another note, a folder in the sidebar, the Finder or another app for a copy. Delete it from the note and the
file goes to the Trash once you leave the note, unless another note in the folder still uses it. Move a note to another
folder and its pictures move along.

### Drawings

Click the pencil in the toolbar and draw right in the note, as in Notes. Drawing starts where you are, and the note
doesn't move: in the drawing on screen, or in a new one below the line you're writing on, at the end of the note when
it's on screen, or else below the line in the middle of the screen. A new drawing is as wide as the text and grows as
you draw near its lower edge, so you can keep going down. As in Notes, there's no frame around it: you draw in the space
between the lines of text, and at the end of the note anywhere below the text. Text stays text: you draw in the
drawings, never over the words. On iPhone and iPad it is PencilKit with Apple's own tool picker, so Apple Pencil with
its pressure and tilt, the ruler and the lasso work as they do in Notes; one finger draws and two scroll, or, where only
Apple Pencil draws, a finger scrolls. On the iPhone, Undo is in the bar at the top while you draw, as in Notes; touch
and hold it for Redo. On the Mac you draw with the mouse, the trackpad or a tablet's pen, with a pen, pencil, marker or
eraser from a palette at the bottom of the note. Done, Escape or a click in the text puts the drawing back in the text,
as tall as what you drew; start typing and the text goes on below it. Tap a drawing (double-click it on the Mac) to draw
in it again.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/drawing-dark.webp">
  <img alt="The note Getting to the ryokan open for drawing: a sketch of the way from the station over the river to the ryokan, ringed in red, between the lines of text with no frame around it, and the palette with pen, pencil, marker, eraser, width, colours and Done at the bottom" src="Design/screenshots/drawing-light.webp">
</picture>

Each drawing is a PNG in `.assets`, which every Markdown app shows, with white behind the ink so it reads in dark
mode too. Next to it, a `.drawing` file keeps the strokes, so you can go on drawing in it later, on any of your
devices; the picture is made again from them a moment after every stroke.

### Tables, diagrams, code and maths

Tables are drawn as tables, Mermaid diagrams as diagrams (natively, without a web view), code with highlighting for
about forty languages, and LaTeX maths as typeset formulas. Click into one and its source appears, with a live
preview for diagrams and formulas. Point at a code block and a button in its corner copies the code. Callouts in
GitHub's and Obsidian's `> [!note]` style get their colour and symbol.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/blocks-dark.webp">
  <img alt="The note Notebook roadmap with a Mermaid diagram from Files to Markdown, Editor, Index and Search, a table of milestones and a Swift code block with highlighting" src="Design/screenshots/blocks-light.webp">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/math-dark.webp">
  <img alt="The note Week 3 with inline maths, the typeset formula A x = lambda x, and an Exam callout" src="Design/screenshots/math-light.webp">
</picture>

### Find anything

The search field in the toolbar (⌘F) finds notes, files and folders by name, the headings in notes, and words in notes
and PDFs, with the page they're on. It also reads the words in pictures, in scanned PDFs and in the handwriting of
drawings, so a photographed receipt or a scanned letter turns up too. Type several words in any order; notes that have
them together come first. A result opens where it was found: the note scrolled to the words with them selected (they
bounce as Find does in Safari), a PDF at its page, a heading, or the picture in a note. Return opens the first match,
and the last suggestion is always a new note with what you typed as its name. With an empty field, it lists what you
opened last.

Search runs in the background on every core, a few milliseconds a letter even in a whole iCloud Drive, so typing never
waits for it; the results stay until the new ones are there. Notebook keeps what it has read between launches, so search
finds everything the moment it opens, and then reads only the notes and PDFs that changed since; the very first time,
while it is still reading your files, it finds what it has read so far. Pictures, scans and drawings are read on your
Mac, iPhone or iPad with Apple's own text recognition, in the background and once each; Settings › General › Search
turns it off.

Your notes are in Spotlight too, on the Mac and on iPhone and iPad: it finds a note by its name or any word in it, with
its first lines and its folder, and picking it opens it in Notebook. Search in App takes the words to ⌘K. Notes in
hidden folders stay out of Spotlight, and it follows as you write, rename, move and delete notes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/search-dark.webp">
  <img alt="The search field with kyoto typed in: the note Kyoto trip under Files, and under In Notes and PDFs a match on page 1 of Flight tickets.pdf and one in the note Budget, then New Note kyoto" src="Design/screenshots/search-light.webp">
</picture>

### Everything with ⌘K

⌘K opens a field over the window, as Spotlight does. It finds everything search finds, and runs what the menus do:
for the note that is open (rename it, move it, duplicate it, set a reminder, draw, export, print, move it to the
Trash), the text styles, a new note or folder, back and forward, the sidebar and outline, the text size, the typeface,
and Settings, each with the keys that do it without ⌘K. Type a few letters of a command, or `>` first to see only
commands. Move To… lists the folders as you type their names. The arrow keys and Return pick, Escape closes. On an iPad
with a keyboard, ⌘K works the same.

### To-dos

Every open checkbox in your notes is a to-do, and To-dos at the top of the sidebar shows them all in one list, as
Reminders does: what is overdue, then today's, tomorrow's, the next seven days', later ones, and those without a date,
each with the lines indented under it (its sub-to-dos, points and notes) and the note it is in. Notes with a reminder
are in the list too, and the number next to To-dos counts what is due today or overdue. Tick a to-do off in the list,
or a sub-to-do under it, and it is ticked in its note; a to-do stays three seconds, ticked, before it fades away, in case
you want to untick it. Click the note's name to open the note at it. Drag a to-do into
another group, or choose Today, Tomorrow, This Weekend or Next Week in its menu, and its date moves; Undo (⌘Z) puts it
back. If you keep your to-dos in another app, turn off Show To-dos in Settings › Sidebar (on iPhone and iPad, in
Settings): the list goes, and Notebook doesn't remind you of to-dos either.

Click a to-do's words to change them where they are, as in Reminders. A Notes line slides in under them, in smaller
letters: what you type there becomes a line indented under the to-do, its notes. Shift-Return starts a line under the
words; Return in that line starts the next one of the same kind, Tab and ⇧Tab move it in and out, and `[ ] ` or `- `
typed at its start make it a sub-to-do or a point, as in a note. Return on the to-do's words, Return on an empty line,
Escape or a click outside the to-do is done; what you type goes into the note as you go, and a line you leave empty
goes. Under the to-do are capsules for its day, its time and its place, as Reminders has them: a grey symbol until it is
set, then the value in the accent colour with an × that takes it away; and one for a sub-to-do. Each opens a dropdown,
as in Issues, that you can type in at once: "thursday in 3 weeks", "fri 9am", "the 12th" or "12.11." for a day, "930" or
"evening" for a time, a name for a place in Apple Maps. It shows what that could mean, Return or a click takes the one
that is lit, and the arrow keys go through the others; without typing, pick Today, Tomorrow, This Weekend, Next Week or
a day in the month, a time of day, Current Location, Home, Work or a place you used before, and whether it's for
arriving or leaving. On iPhone and iPad the same buttons are in a bar of glass above the keyboard, across the screen
as the bar in a note is: a grey symbol until it is set, then the value on a tint of the accent colour, as the pills in a
note show it; a line in and out while you're in one; and on its own at the right, the button that hides the keyboard
and is done. They open the same in a popover (a sheet on the iPhone); a tap on the date or place under the to-do does
too.

Home and Work are there as in Reminders. Apps can't read the Home and Work that Apple Maps shows, so the first time you
tap one you choose its address: on iPhone and iPad from your own card in Contacts, which is where Maps has them, or
where you are now, or by searching. Notebook sees only the address you tap, keeps it for your other devices through
iCloud, and names the place Home or Work in the to-do. Touch and hold it, or right-click it on the Mac, to change the
address or forget it.

In a note, a to-do gets a date, a time and a place as a reminder in Reminders does: point at it and click the bell after
its words for the date's dropdown, or right-click it and choose Remind Me… for all of them at once; on iPhone and iPad
tap the bell above the keyboard while you're in it. Remind Me offers Later Today, This Evening or Tomorrow, or turn on
Date, Time and Location: search Apple Maps for a place, or take Current Location, Home or Work, and say whether it's for
arriving or leaving. The day, the time and the place then show as small pills after the to-do's words, red once the time has
passed; a click or a tap on one opens its date or its place to type or pick, as in To-dos. At that time, or when you get there,
a notification brings the to-do and its notes, with Remind Me in 1 Hour and Done. A day without a time reminds you at
9 in the morning, and a place once, the first time you get there.

Unlike a note's reminder, a to-do's date and place are written into the note, after its words, the way Obsidian's
Tasks and Reminder plugins write them: `⏰ 2026-10-24 14:00` for a day and a time, `📅 2026-11-01` for a day, and
`📍 [Pharmacy](https://maps.apple.com/?ll=…)` for a place, a link any app opens in Maps. So they go with the note to
your other devices and other apps, and a to-do keeps its date however and wherever you edit it. Notebook reads what
Obsidian's other plugins write too, and keeps their way when a date changes: the Reminder plugin's
`(@2026-10-24 14:00)`, the Kanban plugin's `@{2026-10-24} @@{14:00}` and Dataview's `[due:: 2026-10-24]`. The Tasks
plugin's other fields, such as how important a to-do is (`⏫`), how it repeats (`🔁 every week`) and when it is
scheduled (`⏳ 2026-10-26`), show as grey pills and stay as they are.

A to-do repeats as it does with the Tasks plugin: write `🔁` and a rule after it, such as `every day`, `every weekday`,
`every 2 weeks`, `every Monday`, `every month on the 1st`, `every month on the last Friday` or `every year`, and `when
done` at the end to count from the day you tick it rather than from its date. Ticking it off, in the note, in To-dos or
in its notification, writes the next one on the line above, open, and marks the one you ticked with the day,
`✅ 2026-10-26`, as Tasks writes them, so the note goes on the same in Obsidian. Its dates move
on together: the day it is due (`📅`) or its time (`⏰`), and when it is scheduled (`⏳`) or starts (`🛫`), each as far
from the next day as it was. `every month` from 31 January is 28 February, as in Tasks. The lines under it stay with the
one that is done. One Undo takes both back, and so does unticking it in To-dos while it still shows ticked; its
reminder moves to the next one.

A checkbox can hold more than a space or an x, as in Obsidian: `[/]` is in progress and shows a half-filled circle,
`[-]` is cancelled, grey and struck through, and the marks Obsidian's themes draw, such as `[!]`, `[?]`, `[*]` or `[>]`,
show their sign in the circle. As in the Tasks plugin, all but done and cancelled are still to do. Right-click a to-do
in To-dos to mark it in progress or cancelled.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/todos-dark.webp">
  <img alt="To-dos selected at the top of the sidebar, with 4 next to it. The list shows Overdue with Return the library books from yesterday in red; Today with Water the plants, every week, Pick up the dry cleaning at 5:30 PM, its two notes under it, and Send the map to Mia at 7:00 PM; Tomorrow with the note Questions for Dr. Weber and Market shopping, with its sub-to-dos Tomatoes and basil, Burrata and Bags, ticked, under it; then Next 7 Days and Later. Each row has a circle to tick it and the note it is in" src="Design/screenshots/todos-light.webp">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/todo-editing-dark.webp">
  <img alt="Pick up the dry cleaning being edited in To-dos: a Notes line in small grey letters under its words, its two points, and below them capsules: Today and 5:30 PM in blue, each with an ×, and grey symbols for a place and a sub-to-do, with the note Errands at the end of the row. Under Today a glass dropdown is open with “thursday in 3 weeks” typed in its field and Thursday in 3 Weeks lit under it, with its date" src="Design/screenshots/todo-editing-light.webp">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/todo-reminder-dark.webp">
  <img alt="The note Errands, its to-dos followed by pills: Yesterday in red, Today 5:30 PM, the pharmacy at Rosenthaler Platz and a day next month on Renew the passport, which is half done, with a sub-to-do ticked and one not under it; every week and Today on Water the plants; Sell the old bike is cancelled, grey and struck through. Remind Me is open for Buy plasters, with Date and Time off and Location on: the pharmacy on a map with the circle around it, and Arriving or Leaving" src="Design/screenshots/todo-reminder-light.webp">
</picture>

### Remind me of a note

Questions for the doctor, points for a meeting: Remind Me… brings a note back at the time you choose, or when you
arrive at or leave a place. Pick Later Today, This Evening or Tomorrow, type the time in a few words, set a date and a
time, a place, or both, in a popover like a reminder's details in Reminders. It reads "friday evening", "tomorrow at
9", "fri 3pm", "in 3 weeks", "in 2 hours", "next monday", "the 12th" or "12.11."; as you type it shows what that could
mean, and the date and time below follow the one that is lit. Return or a click takes it, and the arrow keys go through
the others. A day without a time is at nine in the morning. The note then shows a bell and the time under its title
("Tomorrow 8:30") and a bell in its row; a click on it changes the time or removes the reminder, and once the time has
passed it turns red. At that time a notification comes with the note's name, the time and its first points: what is
still to do first, then the rest, without pictures or front matter. It is Time Sensitive, so it gets through a Focus.
Tap it to open the note, or choose Remind Me in 1 Hour or Done. A to-do's Remind Me reads typed times the same way.

On the Mac, Remind Me… is in the note's ⋯ menu, the sidebar's right-click menu and the inspector; on iPhone and iPad it
is in the ⋯ menu, on touch and hold, and, once you add it in Settings › Writing Bar, as a bell above the keyboard. The
reminder isn't written into the note, so the file stays as it was and the time or the place doesn't go along when you
share it. Places remind you on iPhone and iPad, which watch them while Notebook may use your location ("While Using");
a Mac can set one, and your iPhone reminds you.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/reminder-dark.webp">
  <img alt="The note Questions for Dr. Weber with a bell and Tomorrow 8:30 under its title, a bell in its row in the sidebar and a Reminder section in the inspector; Remind Me is open below the title with fri typed in its field, and Friday, Friday Afternoon and Friday Evening to choose from above Date and its day, Time, and Location" src="Design/screenshots/reminder-light.webp">
</picture>

### A symbol and a colour for a folder

Folders start out as plain folders. To find one at a glance, right-click it and choose Customize Folder…, or on iPhone
and iPad touch and hold it, and give it a colour and a symbol or an emoji instead of the folder. It shows in the
sidebar as soon as you pick it. There are over 300 symbols and the emoji in groups, a few suggested for the folder's
name (a plane for Travel, a fork and knife for Recipes), and a search that finds them by their names and by what they
are for ("recipe", "japan"). The folder among the symbols brings back the plain folder, and the crossed-out circle takes
the colour away; Undo (⌘Z) takes back everything you changed in one go.

Notebook keeps them where the Finder keeps what its own Customize Folder chooses: the symbol or emoji on the folder,
and the colour as one of the Finder's colour tags, which tint folders in the Finder. They stay with the folder when you
rename or move it, iCloud Drive takes them along to your other devices, and a folder you customized in the Finder
shows the same in Notebook.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/customize-dark.webp">
  <img alt="The sidebar with Travel as a blue plane, Cooking as an orange fork and knife, Design as a palette emoji and University as a purple mortarboard, and Customize Folder open next to Travel: the plane in blue, a row of colours, Symbols and Emoji, a search field, and the symbols suggested for Travel above the groups of symbols" src="Design/screenshots/customize-light.webp">
</picture>

### PDFs, pictures and every other file

Notebook is a browser for your folders, not only for notes. A PDF opens right in the window the way Preview shows it, its
pages one under the other: there at once, and back where you left it when you return. A picture fits the window on the
same grey, never larger than it is; pinch or double-click to zoom in on a spot. A video plays with the system's
controls, as in QuickTime Player. A spreadsheet or any other file opens in Quick Look. The inspector shows a file's
details, and "Open in" hands it to its own app, as a double-click on it in the sidebar does.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/quicklook-dark.webp">
  <img alt="Flight tickets.pdf open in the window, its page on grey as in Preview, with its kind, size, page count, dates and folder in the inspector" src="Design/screenshots/quicklook-light.webp">
</picture>

### A Mac app, made of the Mac's parts

The window is built from the system's own pieces: a source-list sidebar, a toolbar with the system's search field and
share menu, an inspector, Settings, alerts, PDFKit, AVKit and Quick Look. It follows the system's light or dark
appearance. The inspector shows a note's outline, with the section you're reading marked and a word count; a click on
a heading scrolls there. In Settings › Text you pick the typeface (San Francisco, New York, Rounded or Monospaced,
each shown in itself), the size, the line spacing and the line width. The icon is a leather notebook, and Settings › App Icon makes it yours:
pick the leather, the elastic band, the ribbon and the background, and the Dock shows your notebook while the app is
open. Links, the caret and folders are in ink blue to go with it, or in the accent colour you chose in System Settings.

### On iPhone and iPad

The same notes in the same editor, laid out the way each device works. On the iPhone you go into one folder per screen,
as in the Files app, and a note opens on a screen of its own; swipe from the edge to go back. The first screen has your
favourites, what you opened last and the folders of each location. New Folder, search and a new note sit at the bottom,
as in Notes, and search finds everything it finds on the Mac. While you write, a bar floats above the keyboard with
Aa, a checklist, attachments, a link, undo and the formatting, a page of tools at a time. On its left, up to two
buttons for where the caret is come and go: opening the link you are on, a to-do's bell, the style you are in, tinted,
to take it off with a tap, and moving a list item in or out; you tick a to-do on its own checkbox. On its right, always,
a circle of its own hides the keyboard. Which tools and in what order is yours to choose: touch and hold
the bar, or tap the sliders after its last tool, or go to Settings › Writing Bar. Aa brings up the Format panel in the
keyboard's place, as in Notes: the text styles, bold, italic and the rest, lists, indenting and quotes. Pictures come
from the camera, the document scanner, your photos or the Files app. The pencil, at the bottom of the screen or in the
bar, draws in the note with Apple's tool picker. Tap a checkbox to tick it, a link to
follow it, a picture to look at it, a drawing to draw in it; touch and hold a picture and drag it to move it in the
note, or let go to copy, share or delete it. Swipe a file to move or delete it, or to make it a favourite; touch and
hold it for everything else.

The iPad has the Mac's layout: the sidebar with its folders opening in place, the note next to it, and the outline in
an inspector. In portrait the sidebar steps aside once you have picked a note. With a keyboard, the Mac's shortcuts
work, the menu bar has New Note, Go and Format, and the marks show next to the caret as on the Mac. Drag pictures from Photos into a note, or files onto a folder in
the sidebar. A window as narrow as a phone gets the iPhone's screens.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/screenshots/devices-dark.webp">
  <img alt="Notebook on an iPad, with the note Kyoto trip and its outline next to it, and on an iPhone in front of it, with the same note on a screen of its own and a checklist and attachment button at the bottom; in its packing list, Power adapter, type A has a Monday pill after it" src="Design/screenshots/devices-light.webp">
</picture>

## What it does

- **Notes are files.** The title is the file name: rename a note by editing its title, and links to it in other notes
  follow, as they do when you move it or rename or move its folder. New notes go into the folder you're in; made
  anywhere else, they go to the default folder you choose in Settings, an Inbox at the top of your first location
  until you do. One you leave empty goes away again.
- **Moving from Apple Notes.** Export notes from Notes as Markdown, then Import from Apple Notes brings them in,
  each with its pictures and files next to it and its links to the others working, in the folders you exported them
  into. See [Moving from Apple Notes](#moving-from-apple-notes).
- **A new note from anywhere.** New Note is in Shortcuts, Spotlight and Siri ("New note in Notebook"), a widget for the
  Home Screen, the Lock Screen and the Mac's desktop, and a control for Control Center, the Lock Screen and the iPhone's
  Action button: Notebook opens with a new note in the default folder, the caret in its title. In a shortcut of your
  own it takes text for the note to start with.
- **Share to Notebook.** Text, links, pictures and PDFs from any app's share sheet become a new note in the default
  folder, named after the page or the first line, or go at the end of the note you opened last. Pictures and files go
  into `.assets` next to the note. The share sheet hands them to Notebook, which writes them as soon as it's open, with
  the same care as everything else it saves.
- **Folders as they are.** Add iCloud Drive or any folder as a location with Add Location at the bottom of the
  sidebar, or drop the folder from the Finder below the sidebar's sections. iCloud Drive shows what the Finder shows
  in it: Desktop and Documents when they are kept in iCloud, and the folders of apps such as Pages or Obsidian.
  Folders are read and changes to files written in the background, so even a large iCloud Drive shows at once and
  nothing waits for it. Create, rename, duplicate and move notes and folders, by drag and drop or with Move To;
  Option-drag copies. The New Folder button next to a location's name makes a folder at its top, New Folder in a
  folder's menu one inside it, named in place as in the Finder. Deleting moves to the Trash, never further, and Undo
  (⌘Z) puts it back, as it takes back a rename, a move or a new file. Favourites sit at the top of the sidebar.
- **Sorted by name or by date.** View › Sort By, or Sort By in the ⋯ menu on iPhone and iPad, sorts every folder's
  notes and files by name, as the Finder does, or newest first by when they were last edited or made, as Notes does.
  Sorted by date, the note you write in moves to the top of its folder once it is saved, still selected; Keep Folders
  on Top keeps folders above the files either way. The dates come with the folder as it is read, so a large folder
  sorts at once.
- **iPhone and iPad.** The same editor, search and file handling, with screens made for each: one folder per screen
  on the iPhone, the sidebar on the iPad. Pick iCloud Drive or any folder in the Files app's picker, or keep notes on
  the device, in On My iPhone › Notebook. A bar above the keyboard, whose tools you choose, formats, links and adds
  photos, scans and files, with buttons for where the caret is on its left; Aa opens the Format panel as in Notes.
  Deleting moves to Recently Deleted; where a place has none, Notebook asks before it deletes, and Undo (⌘Z) still
  brings it back while Notebook is open.
- **Hidden folders.** Right-click a folder you don't want to see, such as one another app keeps in iCloud Drive, and
  choose Hide Folder, or on iPhone and iPad touch and hold it. It leaves the sidebar, search and Move To, and stays
  hidden on your other Macs, iPhones and iPads through iCloud. The eye next to the location's name, or ⇧⌘., shows
  hidden folders again, dimmed, until you click it again; on iPhone and iPad, Show Hidden Folders is in the ⋯ menu.
- **Folders with a symbol and a colour.** Customize Folder… gives a folder a colour and a symbol or an emoji, found in
  groups, suggested for its name or searched for, kept on the folder as the Finder keeps them, so the Finder shows them
  too.
- **To-dos.** Every open checkbox in every note, in one list at the top of the sidebar, grouped by when it's due, with
  the lines indented under it as its sub-to-dos and notes. Tick them off there, edit them in place as in Reminders with
  a line for notes and dates typed in a few words ("thursday in 3 weeks"), open their note, or drag them to another day. A to-do takes a date, a time and a place, written after its words where
  other apps read them too, and shows them as pills; Obsidian's Tasks, Reminder, Kanban and Dataview dates and its
  `[/]` and `[-]` checkboxes are understood. A to-do with the Tasks plugin's `🔁 every week` makes the next one when
  you tick it, as the plugin does. Settings turns To-dos off.
- **Reminders.** Remind Me… brings a note or a to-do back at a time you choose, picked or typed in a few words ("friday
  evening", "in 3 weeks"), or when you arrive at or leave a place, with a notification of its first points or the
  to-do's notes that gets through a Focus. A note's reminder follows it when you rename or move it in Notebook, goes
  when you delete it, and reaches your other Macs, iPhones and iPads through iCloud; a to-do's goes with its note. Each
  device shows the notification itself; places remind you on iPhone and iPad.
- **Live preview editor.** Headings, bold, italic, strikethrough, `==highlight==`, inline code, links, checklists,
  bulleted and numbered lists, quotes, callouts, tables, code blocks, maths, Mermaid, footnotes and front matter, which
  folds into a small "properties" pill. Styles turn on and off where the caret is, their marks come and go as a pair,
  and the text eases into each new look. With a keyboard the marks next to the caret unfold and fold away; on the touch
  keyboard they stay hidden.
- **Pictures and files in notes.** Paste or drop them in, and drag them around the note or out of it;
  `![[embeds]]` of other notes show an excerpt, of files a card with a preview.
- **Drawings in notes,** with PencilKit: Apple Pencil, a finger, the mouse, the trackpad or a tablet. Each is a PNG
  that other apps show, with its strokes kept next to it so it stays a drawing in Notebook.
- **PDFs, pictures, videos and other files** open in the window: PDFs and pictures as in Preview, videos as in
  QuickTime Player, the rest in Quick Look. Double-click one in the sidebar to open it in its own app, such as Preview.
- **Search** for the names of notes, files and folders, headings, words in notes and PDFs, and the text in pictures,
  scans and handwriting, in the background as you type. ⌘K finds the same and runs commands.
- **Spotlight** finds your notes by their names and words too, on the Mac, iPhone and iPad, and opens them in
  Notebook. It gets what search has already read, in the background, and after a launch only what changed.
- **Saves as you type,** and never overwrites a change made somewhere else (see below).
- **Export** a note as a PDF or a PNG image, or print it (on iPhone and iPad: as a PDF to share, or print).
- **Notes in windows of their own.** Double-click a note in the sidebar, or open any Markdown file from the Finder or
  with ⌘O, and it gets a plain window of its own; more of them join it as tabs. A note from your locations links to
  every note there, as in the main window.

## How notes are stored

Everything is plain Markdown, so other apps keep reading your notes. Notebook adds no files of its own besides the
`.assets` folders for pictures and files you add to notes, and in them, next to each drawing's picture, a `.drawing`
file with its strokes. A folder's symbol and colour are kept on the folder, as the Finder keeps them, not in a file.
What isn't part of a note or a folder, such as the folders you hide, the reminders of notes you set and your Home and
Work, is kept in the app's settings and iCloud's key-value store, not in your folders. A to-do's date and place are part of the
to-do, so they are in the note. What search knows, the text of your notes and
PDFs and the words read in pictures, is kept in the app's caches on each device, from where it can always be read again.
The list of the notes Spotlight has is kept in the app's own folder on each device.

| What | In the file | In Notebook |
| --- | --- | --- |
| Title | The file name, `Weekend.md` | A large title above the text; editing it renames the file |
| Picture | `![](.assets/Weekend%202026-10-14%20at%2015.32.10.png)` | The picture, fitted to the width |
| Drawing | `![Drawing](.assets/Weekend%20drawing%202026-10-16%20at%2010.20.15.png)`, with `Weekend drawing 2026-10-16 at 10.20.15.drawing` next to the picture | The drawing, as wide as the text, to draw in again |
| Link to a note or file | `[[Recipes]]`, `[[Recipes\|text]]`, `[[Offer.pdf]]` | A link you click; dashed when the target doesn't exist yet |
| Embed | `![[Recipes]]`, `![[Offer.pdf]]` | An excerpt of the note, or a card for the file |
| Web link | `[text](https://…)` | The text, with a pencil to edit the address |
| Checklist | `- [ ]`, `- [x]` | A round checkbox, filled when done; done items turn grey |
| In progress, cancelled | `- [/]`, `- [-]` | A half-filled circle; a grey one with a cross, the to-do struck through |
| Obsidian's other marks | `- [!]`, `- [?]`, `- [*]`, `- [>]` and others | Their sign in the circle; still to do |
| To-do's date | `- [ ] Call Dr. Weber ⏰ 2026-10-24 14:00`, `📅 2026-11-01` for a day; also `(@2026-10-24 14:00)`, `@{2026-10-24}`, `[due:: 2026-10-24]` | A pill: "Tomorrow 2:00 PM", red once it has passed |
| To-do's place | `📍 [Pharmacy](https://maps.apple.com/?ll=52.53,13.4&q=Pharmacy)`, `📍 Leaving [Home](…)` | A pill with the place's name |
| A to-do's notes | Lines indented under it | Shown under the to-do in To-dos, sub-to-dos with circles to tick, and in its notification |
| Tasks' other fields | `⏫`, `🔁 every week`, `⏳ 2026-10-26`, `[priority:: high]` | Grey pills: "High", "every week", "Scheduled Monday" |
| A repeating to-do, ticked | `- [ ] Water the plants 🔁 every week 📅 2026-11-02` above `- [x] Water the plants 🔁 every week 📅 2026-10-26 ✅ 2026-10-26` | The next one, open, and the one done, ticked |
| Highlight | `==text==` | A yellow highlight |
| Callout | `> [!tip] Title` | A coloured box with a symbol |
| Maths | `$x^2$`, `$$ … $$` | A typeset formula |
| Diagram | ```` ```mermaid ```` | The diagram |
| Front matter | `---` YAML `---` at the start | A small pill; click to see the YAML |
| A folder's look | `{"sym":"airplane"}` or `{"emoji":"🍕"}` in the folder's `com.apple.icon.folder#S` attribute, and a colour tag such as Blue | The symbol or emoji in the sidebar, in the tag's colour |

`[[Name]]` finds the note by its name, ignoring case and accents: one in the same folder first, then the one with the
shortest path. `[[Folder/Name]]` says exactly which. When you rename or move a note, a file or a folder in Notebook,
the links that would find something else afterwards, in other notes and in the ones moved, are rewritten to find what
they found, with no more of the path than it takes; the rest stay as you wrote them, and Undo puts them back. A file
renamed or moved in the Finder or another app isn't followed: a link that no longer finds it shows as a link to a note
that doesn't exist yet. Remote pictures (`![](https://…)`) are not downloaded; Notebook shows their address instead.

## When a note changes somewhere else

Notes are often open on more than one Mac, or in more than one app. Notebook watches the open note and the folders in the
sidebar. If a note changes elsewhere while you haven't typed, it reloads quietly, and your caret and scroll position
stay where they were. If both sides changed, Notebook merges the two line by line, before every save as well, so it never
writes over a change it hasn't seen. Only when both changed the same lines does it ask: keep this version, use the
other one, or keep both as two files. Conflicts that iCloud Drive reports are handled the same way. If you have left
the note by then, or quit, there is no one to ask, so Notebook keeps both: what you typed goes into a copy next to the
note, named after your Mac or device, such as "Groceries (Anna's iPhone)".

Notes are saved in the background, so a slow disk or iCloud holding a note never makes the window wait. What you typed
in a note you have just left is still written, and Notebook doesn't quit before it is. A note open in the main window
and in a window of its own is one note: what you type in either shows in the other.

Notes in iCloud Drive that aren't downloaded yet are fetched so that search finds them; other files that live only in
iCloud show a cloud in the sidebar and download when you open them. A note that isn't on your Mac, iPhone or iPad yet
opens at once with its title, and its text follows when iCloud has brought it down, with "Downloading from iCloud…" if
that takes a moment. Until then nothing can be typed into it, so nothing is saved over the note in iCloud.

## Getting started

### Requirements

- A Mac with Apple silicon and macOS 27 or later
- An iPhone or iPad with iOS or iPadOS 27 or later, or the Simulator
- Xcode 27 or later, to build it

### Build and run

```bash
git clone https://github.com/lukaskaibel/notebook.git
```

```bash
open notebook/Notebook.xcodeproj
```

Choose the **Notebook** scheme, then **My Mac** or an iPhone or iPad simulator as the destination, and press ⌘R. A local
build needs no Apple developer account: without a team, Xcode signs it to run on your Mac and in the Simulator. To run
it on your own iPhone or iPad, or to sign with your own team, create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM =
<your team ID>`; it isn't checked in. With a team of your own, give the app an identifier of yours there too,
`NOTEBOOK_BUNDLE_IDENTIFIER = com.example.Notebook`; the extensions take it with `.Widgets` and `.Share` after it. A
local build keeps hidden folders and reminders on the device; only the App Store build, signed with a team, has the
iCloud entitlement that takes them to your other devices, and the one for Time Sensitive notifications. The share
extension hands what you share to the app through an App Group, which only the App Store build and the Simulator
have; in other builds it says it can't keep anything.

### Adding your notes

On first launch, Notebook asks for a folder: **Open iCloud Drive**, or **Choose another folder…**. Add more later with
**Add Location** at the bottom of the sidebar, by dropping a folder on the sidebar or on Notebook in the Dock, or with
File › Open… (⌘O), File › Add Location… and Settings › General. Notebook works on the files in place; nothing is
copied or imported. A new location shows in the sidebar straight away, and its files a moment later, however many
there are.

On iPhone and iPad, **Choose a Folder** opens the Files app's picker: pick iCloud Drive itself to have everything you
write on the Mac, or any folder in it or on the device. **Keep Notes on This iPhone** (or iPad) uses Notebook's own
folder, which the Files app shows under On My iPhone › Notebook. Add more in Settings, from the ⋯ menu.

To look around without your own notes, choose **Try Sample Notes…** on the first screen. It writes made-up notes, a
drawing, pictures and PDFs to a new folder Sample Notes, in the folder you pick on the Mac and in Notebook's own folder
on iPhone and iPad, and adds it as a location. Remove it in Settings when you're done; the files stay where they are.

For development, a Debug build run with the arguments `-NotebookLibrary /tmp/NotebookSample -NotebookDemo YES`
(Product › Scheme › Edit Scheme › Arguments) writes the same notes to that folder and shows only them, for that run,
with a hidden folder and a reminder. In the Simulator, use `-NotebookLibrary ~/Documents/Sample`, which is in the app's
own folder there.

### Moving from Apple Notes

Notes exports Markdown itself, and Notebook brings that in:

1. **Export from Notes.** On the Mac, open a folder in Notes, select its notes (⌘A) and choose File › Export as ›
   Markdown; Notes asks where, and makes a folder there, named Archive unless you name it. Notes has no command that
   exports everything at once, so do it folder by folder; to keep your folders, save each export into a folder of the
   same name, for example `From Notes/Work`, `From Notes/Recipes`. On iPhone and iPad, open a note, tap Share › Export as
   Markdown and save it to Files; that is one note at a time.
2. **Import into Notebook.** Choose **File › Import from Apple Notes…** (on iPhone and iPad, **Import from Apple Notes**
   in the ⋯ menu) and pick the folder Notes made, or the folder you saved the exports into. On the Mac the panel says
   where the notes will go: the folder selected in the sidebar, else the one of the note you have open, else the default
   folder. On the iPhone they go into the folder whose ⋯ menu you used, or from the first screen into the default
   folder; on the iPad, into the folder of the note you have open, else the default folder.

Each folder you pick becomes a folder, with the folders in it; the folder Notes makes for a single note becomes just the
note. Notes puts the pictures and files of all the notes it exports in one Attachments folder; the import puts each
note's own into the `.assets` folder next to it, as Notebook does with yours, so they move with the note, and gives
those Notes wrote without an extension one. Links between the notes you exported keep finding them: `[[links]]` to
notes in the same folder, relative Markdown links to the others. The title Notes repeats as each note's first line goes,
since the file's name is the title, and a file no note links to comes along as a file next to the notes rather than
being left behind. Notes' export is only read, nothing already in your folders is written over, and what couldn't come
over, such as a picture that couldn't be read, is listed when the import is done. Undo (⌘Z) takes everything the
import added back to the Trash.

What comes over is what Notes' export has: headings, bold and italic, lists, checklists, links and attachments, but no
colours or fonts, and #tags as plain text. Each note keeps the dates of the file Notes wrote, which may be when you
exported it rather than when you wrote it.

## Using it

| Shortcut | Action |
| --- | --- |
| ⌘N | New note in the current folder, or with none, in the default folder |
| ⇧⌘N | New folder in the current folder, named in place |
| ⌘Z, ⇧⌘Z | Undo and redo: typing, and changes to files (the Trash, a rename, a move, a new note or folder), newest first |
| ⌘F | Search |
| ⌘K | Search and run commands; `>` for commands only |
| ⇧⌘R | To-dos |
| ⌘[ and ⌘], or swipe between pages | Back and forward; the swipe follows System Settings, as in Safari |
| ⌘O | Open a Markdown file in a window of its own, or a folder in the sidebar |
| ⌃⌘S | Show or hide the sidebar |
| ⌃⌘I | Show or hide the outline |
| ⇧⌘. | Show or hide hidden folders |
| ⌘+, ⌘− and ⌘0 | Bigger, smaller and actual text size |
| ⌥⌘E | Export as PDF |
| ⌘P | Print |
| ⌘, | Settings |

While writing:

| Shortcut | Action |
| --- | --- |
| ⌘B, ⌘I | Bold, italic; inside bold text it comes off (again: back on), at its end you step out of it |
| ⇧⌘X | Strikethrough |
| ⌃⌘H | Highlight |
| ⌘E | Inline code |
| ⌘L | Link: wraps the selection, or starts a `[[link]]` |
| ⇧⌘T, ⇧⌘H, ⇧⌘J, ⇧⌘B | Title, heading, subheading, body |
| ⇧⌘L | Checklist |
| ⇧⌘U | Mark as checked |
| ⇧⌘7, ⇧⌘9 | Bulleted list, numbered list |
| ⌘' | Block quote |
| Tab, ⇧Tab | Nest or un-nest a list item (in code: indent) |
| ⌥⌘] and ⌥⌘[ | Increase and decrease indent |
| `*`, `_`, `` ` ``, `~` or `=` with text selected | Wrap the selection in that mark |
| Return at the end of bold text | The next line, without the bold; in the middle of it, the bold goes on |
| Delete behind `**bold**` | A star from each end: italics, then plain text; `*` there brings them back (on the touch keyboard, where the stars don't show: the last letter) |
| `*` at either end of `*italics*` | One at the other end too: bold |
| `-` at the start of a line | A bullet; `-[]` a checkbox, `---` a rule |
| `##` and then text, or `##` in front of a line | The space a heading needs goes in for you |
| `**` (also `~~`, `==`) | The closing pair comes along, the caret between; a space next makes them plain stars |
| Return on a heading | At its start: a line above it; on one without text: back to body text |
| `[[` | Suggestions for a link; ↑↓ and Return or Tab to pick |
| Space on a selected picture | Quick Look |
| Drag a picture or file in a note | Move it to another line; ⌥ drops a copy. Into another note, the sidebar, the Finder or another app: a copy |
| Double-click a drawing | Draw in it |
| Esc, or start typing | Stop drawing; typing goes on below the drawing |
| ↑ on the first line, ← or Delete at the very start | Into the title, at its end |
| Return, Tab, ↓, or → at the end of the title | Into the text |

Editing a to-do in To-dos:

| Shortcut | Action |
| --- | --- |
| Click its words | Edit it, the caret where you clicked |
| Shift-Return on its words | A line under them: a sub-to-do, or a point where points are |
| Return in a line under it | The next line of the same kind; on an empty line, done |
| Tab, ⇧Tab | Move the line in or out |
| `[ ] ` or `- ` at the start of a line | A sub-to-do or a point |
| Delete at the start of a line | A sub-to-do or point becomes words; words join the line above |
| ↑ and ↓ at either end of a line | The line above or below |
| Return on its words, Escape, a click outside it | Done |
| Typing in its date, time or location dropdown | What it could mean, the first lit; ↑ and ↓ light another, Return takes it, Escape closes |

In the sidebar: a double-click opens a note in a window of its own and any other file in its own app, as in the Finder;
Return renames, ⌘⌫ moves to the Trash, and Space opens a file in Quick Look. Right-click a file or folder for everything
else, including Open in New Window, New Folder, Copy Link, which copies a `[[link]]` to it, Remind Me…, Customize
Folder… and Hide Folder. In a note, right-click a to-do for Remind Me…, or click the bell that comes up after it as you
point at it; in To-dos, right-click a row to move it to another day, mark it in progress or cancelled, or open its
note. As you point at a location's name, a folder with a plus comes up next to it for a new folder at its top, and, when
the location has hidden folders, an eye that shows them.

On an iPad with a keyboard, ⌘N, ⌘Z and ⇧⌘Z, ⌘F, ⌘K, ⇧⌘R, ⌘[ and ⌘], ⌃⌘I, ⇧⌘. and the shortcuts for writing work as
on the Mac. On iPhone and iPad:

| Gesture | Action |
| --- | --- |
| Swipe from the left edge | Back to the folder or the note you came from (iPhone) |
| Swipe a file to the left or right | Move or delete it, add it to your favourites, or hide a folder |
| Touch and hold a file or folder | Set a reminder, rename, move, duplicate, copy a link, customize or hide a folder, share and more |
| Tap a location's name | New note or folder at its top, add to favourites, share, show hidden folders, remove from Notebook |
| Pull a list down | Read the folder again |
| Tap a checkbox, a link or a picture | Tick it, follow it, or look at it in Quick Look |
| Tap a to-do's pill | Its date or its place, to type or tap, as in To-dos |
| Tap the bell above the keyboard in a to-do | Remind Me: its date, time and place |
| Tap a to-do's words in To-dos | Edit it, with a Notes line under it; the bar above the keyboard opens its day, time and place to type or tap, adds a sub-to-do and moves a line in or out |
| Touch and hold a row in To-dos, or drag it | Today, Tomorrow, This Weekend, Next Week, Remind Me…, or another group |
| Tap a drawing | Draw in it |
| While drawing: one finger, two fingers | Draw, scroll (where only Apple Pencil draws, a finger scrolls) |
| While drawing on the iPhone: Undo at the top, or touch and hold it | Take back the last stroke, or Redo |
| Touch and hold a picture or file in a note, then drag | Move it to another place in the note, or into another app |
| Touch and hold a picture or file, then let go | Select it: Quick Look, copy, cut, share or delete |
| Tap the heading level in the margin | Title, heading, subheading or body, each as it looks (iPad) |
| Touch and hold the bar above the keyboard | Choose its tools and their order |
| Drag down over a note | Put the keyboard away |

## Not there yet

Planned, and not built yet:

- **Reminders when a calendar event starts,** and on the iPhone a Live Activity that keeps the note on the Lock Screen.
  A reminder set on another device reaches an iPhone or iPad the next time Notebook runs there or gets time in the
  background. Reminders of notes don't repeat, and a Mac doesn't remind you at places.
- Footnotes are styled but don't jump to their text.
- On iPhone and iPad there is no Settings › App Icon (iOS only switches between icons built into the app), no PNG
  export and no window of its own for a single file.
- **Sketches** as files of their own, next to your notes rather than in one.
- Translations: the app is in English only.

The full plan, with what is deliberately left out (tags, backlinks, a database, sync of its own), is in
[PLAN.md](PLAN.md), in German.

## For contributors

```
Notebook/                    The app target (Mac, iPhone and iPad): the entry point, the icon and the App Shortcuts
NotebookWidgets/             The widgets' extension: the New Note widget and control
NotebookShare/               The share extension: the sheet, and what it leaves for the app to write
NotebookUITests/             UI tests on iPhone and iPad simulators, for what only a real keyboard or touch reaches
Packages/NotebookKit/
  Sources/NotebookCapture/   What the extensions share with the app: the New Note intent and the notes shared to it
  Sources/NotebookKit/
    Editor/                  The live-preview editor on TextKit 1: styling, hidden marks, objects, typing, export;
                             the Mac's text view, and iPhone's and iPad's in the "+UIKit" files
    Markdown/                Notebook's Markdown parser, which keeps every character's position in the file
    Render/                  Tables, maths, diagrams and code highlighting
    Drawing/                 Drawings: the strokes file and its picture, and drawing them in notes
    Files/                   Locations, the file tree read in the background, file operations, saving, watching, the
                             three-way merge, the hidden folders and reminders kept in iCloud's key-value store,
                             folders' symbols and colours kept where the Finder keeps them, the sample notes, and
                             Import from Apple Notes
    Index/                   Search: the index of every file and how it is kept between launches, the corpus a
                             search goes through on every core, the text read in pictures, scans and drawings, and
                             how [[links]] resolve and follow files renamed or moved; the to-dos of every note, and
                             what Spotlight gets of each note
    Platform/                The few names and calls that differ between AppKit and UIKit
    UI/                      The Mac's window, sidebar, inspector, search field, Settings and file windows; PDFs,
                             pictures, videos and Quick Look; what both share, such as the outline and search results
    UI/iOS/                  The iPhone's and iPad's screens: folders, the sidebar, the note, search and Settings
    Debug/                   The debug remotes (Debug builds only)
  Tests/                     Parser, editor, merge, smoothness, search index, Spotlight, link, drawing, reminder,
                             to-do, folder look, app icon and Apple Notes import tests
Config/                      Build settings, Info.plist and entitlements
Design/                      The icon, the README pictures, the social preview, and the App Store screenshots and
                             what is set in App Store Connect (app-store.md)
Website/                     The website, published to GitHub Pages by .github/workflows/website.yml
Tools/                       The app icon, the README pictures and the App Store screenshots
fastlane/                    Building for the App Store, TestFlight, and the App Store listing's texts
PLAN.md                      The plan: decisions, file format, architecture and milestones (in German)
```

The editor is the heart of the app. The text view holds the file's Markdown exactly, character for character, and
everything you see is styling on top: marks are hidden as zero-width glyphs and objects are drawn in place of a
character, so undo, dictation and spell checking behave as everywhere else on the Mac. Start reading at
`Editor/EditorController.swift` and `Editor/NotebookLayoutManager.swift`. On iPhone and iPad the same storage, layout
manager and styling sit under UIKit's text view; only what talks to the text view differs (`Editor/*+AppKit.swift`
and `Editor/*+UIKit.swift`), plus an undo history of the editor's own, since UIKit's goes wrong when the editor
changes the text itself. Changes to files are kept for Undo in the window's undo manager (`UI/Workspace+Undo.swift`):
on the Mac next to the text's own, in the order they were made; on iPhone and iPad the editor's history weighs them
against its own by when each was made.

Run the tests (they use off-screen windows and temporary folders, and touch none of your files):

```bash
cd Packages/NotebookKit && swift test
```

The UI tests start the app on fresh sample notes in the simulator's own folders. Each is for an iPad or an iPhone and
is skipped on the other, so run them on a simulator of each of your own, here ones called Notebook iPad and Notebook
iPhone:

```bash
xcodebuild test -project Notebook.xcodeproj -scheme NotebookUITests -destination "platform=iOS Simulator,name=Notebook iPad"
xcodebuild test -project Notebook.xcodeproj -scheme NotebookUITests -destination "platform=iOS Simulator,name=Notebook iPhone"
```

The pictures in this README are made by a script. It builds the app, runs it in the background on the sample notes,
takes the scenes in light and dark, and lays them out together with `Design/social-preview.png`; the website uses the
window and the iPhone's screen from them too. The iPhone and iPad pictures come from two simulators of its own, without
the Simulator app's window. It doesn't take over your Mac (only the search suggestions show on screen for a moment) and
leaves your own Notebook's settings alone. Run it again when a change shows in one of them (`devices` takes only the
iPhone and iPad picture, which works with the screen asleep):

```bash
Tools/readme-images.sh
```

The app icon is drawn by `Tools/AppIcon/notebook.py`. After changing it, run the script below: it writes
`Notebook/AppIcon.icon` and renders, with Icon Composer's `ictool`, the grey passes that Settings › App Icon colours in
any leather, the icon on the New Note widget, and the cover's grain for the website's button (it needs Python 3 with NumPy and Pillow, and
`brew install librsvg`):

```bash
Tools/AppIcon/make.sh
```

Debug builds can be driven from a file: launch with `-debugCommandFile <path>` and append commands such as `open
Travel/Kyoto trip.md`, `type Hello`, `key return` or `snapshot <file>` to it, one per line. The commands are listed in
`Debug/DebugRemote.swift`, and for iPhone and iPad in `Debug/DebugRemote+UIKit.swift`; those for reminders, such as
`remind 2 Personal/Questions for Dr. Weber.md` (in two minutes) and `notifications`, are in
`Debug/DebugReminders.swift`, those for to-dos, such as `todos`, `ticktodo dry cleaning`, `firetodo dry cleaning` and
`edittodo end market` (edits it in To-dos; `todoediting` says what is typed, `todopick date` and `todopicktype fri`
open its date's dropdown and type in it), in `Debug/DebugTodos.swift`, and those
for folders' looks, such as `customize Travel`, `iconpick 🍕` and `setfoldericon Travel symbol=airplane color=blue`, in
`Debug/DebugFolderIcons.swift`. In the Simulator the file is in the app's own folder (`-debugCommandFile
~/Documents/cmd`), where `xcrun simctl get_app_container` finds it, and `xcrun simctl io <device> screenshot` takes the
pictures. `-NotebookSlowFolders 2` makes every folder take two seconds to read, as a slow iCloud might, to see that
nothing waits for it, `-NotebookSlowFiles 2` does the same for every note, PDF, picture and video you open, and
`-NotebookSlowWrites 2` for every change to files: a new note or folder, a rename, a move, a copy, the Trash. On the
Mac, `mainthread` logs how many folders were read and files changed on the main thread, which should be none, and
`fakekey` makes the test window say it is key, as the window you click in is, while the app stays in the background.
`timeopen <note>` logs how long opening a note keeps the window busy (on iPhone and iPad too), `search <text>` how
long search takes, and `index` when after launch the kept index was read, search had every file and the files were
checked, and how many notes that read. macOS shows notifications only from an app in a lasting place, not from one in
`/tmp`.

Builds for TestFlight are made and uploaded with [fastlane](https://fastlane.tools), signed in with an App Store
Connect API key, so Xcode needs no account. Copy `fastlane/.env.secret.example` to `fastlane/.env.secret` (it stays out
of git) and fill in the key and your team, run `bundle install` once, and then upload the iPhone and iPad app, the Mac
app or both:

```bash
bundle exec fastlane ios beta
```

The App Store listing is kept here too: its texts in `fastlane/metadata`, the age rating in `fastlane/rating.json` and
the screenshots in `Design/screenshots/app-store`, taken on the sample notes by `bundle exec fastlane screenshots`.
`bundle exec fastlane metadata` uploads them, `submit` sends the builds TestFlight has for review, and `release`
builds, uploads and submits in one go. [Design/app-store.md](Design/app-store.md) lists what is set once in App Store
Connect, and why the answers are what they are.

Every change to the app on `main` also goes to TestFlight by itself, for the iPhone and iPad and for the Mac:
[`.github/workflows/testflight.yml`](.github/workflows/testflight.yml) runs `ios beta` and `mac beta` on GitHub side by
side, signed with certificates made for it (the workflow lists the secrets it needs). There the Mac app is signed for
the App Store from the start, so the Macs GitHub runs it on don't have to be registered with the team. A TestFlight
build carries the version it's on its way to and the date and time in Germany: `1.0.0 (2026.1017.1047)` is the build of
17 October 2026 at 10:47, and once `v1.0.0` is tagged, the builds after it are `1.1.0`. Its "What to Test" names the
commit.

The team's own testers get every build straight away; the external testers in the TestFlight group "Family and
friends" get it once Apple's Beta App Review has passed it. That group, its test information and the reviewer's contact
are set up on App Store Connect.

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes.

## Versions

The project follows [semantic versioning](https://semver.org). Every release is tagged (`v1.0.0`) and described in
the [changelog](CHANGELOG.md). Until 1.0, minor versions may change behaviour.

## Acknowledgements

Built with [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift), which lays diagrams out with
[elk-swift](https://github.com/lukilabs/elk-swift) (Eclipse Public License 2.0; its source is at that link), and
[SwiftMath](https://github.com/mgriebling/SwiftMath). The way notes write is inspired by Apple Notes.

Notebook is an independent project and is not affiliated with, endorsed by, or sponsored by Apple.

## License

Copyright © 2026 Lukas Kaibel

Notebook is free software: you can redistribute it and modify it under the terms of the
[GNU General Public License, version 3](LICENSE), as published by the Free Software Foundation. It comes with no
warranty of any kind; the licence has the details.

**Additional permission under GNU GPL version 3 section 7.** If you modify this program, or any covered work, by
linking or combining it with [elk-swift](https://github.com/lukilabs/elk-swift) (or a modified version of that
library), containing parts covered by the terms of the Eclipse Public License 2.0, the licensors of this program grant
you additional permission to convey the resulting work. Corresponding Source for a non-source form of such a
combination shall include the source code for the parts of elk-swift used as well as that of the covered work.

Notebook was released under the [MIT License](https://github.com/lukaskaibel/notebook/blob/e4b72a6/LICENSE) until
24 October 2026. Copies from before then, up to commit `e4b72a6`, can still be used under that licence.

Contributions come with terms of their own, so that Notebook can be published on the App Store: see
[CONTRIBUTING.md](CONTRIBUTING.md#licensing-your-contribution).
