# Notebook: Plan

Notebook ist eine native App für Mac, iPhone und iPad. Sie zeigt deine echten Ordner (iCloud Drive und weitere Orte) und
macht Markdown-Dateien darin zu Notizen, die sich so selbstverständlich schreiben wie in Apple Notes. Alle anderen Dateien
zeigt sie mit Quick Look. Die Notizen sind normale `.md`-Dateien neben deinen anderen Dokumenten, ohne Export, ohne eigene
Datenbank und ohne eigenen Sync.

Name: **Notebook** (bis zum 16.10.2026 hieß die App Folio). Stand: Planungssitzung vom 14.10.2026.

---

## 1. Leitlinien

- **Minimal.** Jede Funktion muss die Frage bestehen: *Brauche ich das, um Apple Notes im Alltag zu ersetzen?* Was das
  System schon kann (Quick Look, iCloud Drive, Spotlight, Teilen-Menü, Papierkorb), wird benutzt, nicht nachgebaut.
- **Die Datei ist die Wahrheit.** Der Editor bearbeitet den Markdown-Text der Datei direkt. Was Notebook speichert, liest
  jedes andere Markdown-Programm (Obsidian, GitHub, iA Writer) genauso.
- **Markdown ist ein Speicherformat, kein UI-Thema.** Bilder, Einbettungen und Links sind Objekte wie in Notes. Markdown-Zeichen
  sieht man nur kurz in der Zeile, in der man gerade schreibt.
- **Aussehen wie Issues.** Linear-ruhig, Apple-nativ: dieselben Design-Tokens (`Theme.swift`), dieselbe ⌘K-Leiste,
  dieselben Federn bei Animationen.

## 2. Entscheidungen

| Thema | Entscheidung |
| --- | --- |
| Plattformen | Mac, iPhone und iPad aus einem Multiplatform-Projekt. Der Mac gibt das Design vor. |
| Mindest-OS | iOS, iPadOS und macOS 27 |
| Vertrieb | Erst für dich, aber von Anfang an sandboxed und App-Store-tauglich. Übersetzungen, Website und Screenshots kommen später. |
| Orte | Mehrere Orte in der Sidebar: iCloud Drive als Standard, weitere Ordner hinzufügbar. Der Zugriff bleibt über Security-Scoped Bookmarks erhalten. |
| Layout Mac/iPad | Zwei Spalten: links ein Baum mit Ordnern **und** Dateien, rechts das Dokument |
| Layout iPhone | Drill-down: ein Ordner pro Bildschirm wie in der Dateien-App. Unten Suche und „Neue Notiz“. |
| Editor | Live-Preview, nativ auf TextKit 2. Markdown-Zeichen von Inline-Formatierung und Überschriften sind nur in der Cursor-Zeile sichtbar. |
| Objekte | Bilder, Einbettungen `![[…]]` und `[[Links]]` sind feste Objekte. Ihr Markdown ist nie sichtbar. |
| Blöcke | Tabellen, Mathe und Mermaid sind gerendert. Ihren Markdown-Text sieht man erst, wenn der Cursor im Block steht. |
| Markdown-Umfang | GFM (Tabellen, Checklisten, Durchstreichen, Code mit Hervorhebung, Fußnoten), Bilder, Mermaid, Mathe (LaTeX), Callouts, Einbetten mit `![[…]]` |
| Frontmatter | Keine eigene Eigenschaftsleiste. Der YAML-Block wird zu einer dezenten Zeile eingeklappt. |
| Links | `[[Wiki-Links]]`, aufgelöst über den Dateinamen. Benennt man in der App um, zieht sie alle Links nach. |
| Titel | Dateiname = Titel. Er steht groß über dem Text und lässt sich dort umbenennen. In der Datei gibt es keine doppelte Überschrift. |
| ⌘K | Eine Leiste für alles: Dateien nach Name, Treffer im Text und Befehle. Mit `>` nur Befehle. |
| Suche | Markdown-Text, Text in PDFs, Text in Bildern und Scans (OCR), zusätzlich systemweit in Spotlight |
| Ordnen | Ordner, Favoriten, Zuletzt geöffnet. Keine Tags und keine Backlinks. |
| Fenster | Ein Dokument mit Vor/Zurück. Mehr Fenster und macOS-Fenstertabs gibt es vom System. Keine eigenen Tabs. |
| Schnell notieren | Widget, Kontrollzentrum, Sperrbildschirm und Action-Taste (alle über einen App Intent), dazu das Teilen-Menü |
| Neue Notizen | Landen im aktuellen Ordner. Von außen (Widget, Teilen-Menü) landen sie im Ordner „Inbox“. |
| Anhänge | `.assets/` in jedem Ordner, unsichtbar in Notebook, im Finder und in der Dateien-App. Wer ein Bild in der Notiz löscht, löscht auch die Datei. |
| Andere Dateien | Quick Look für alles, was nicht Markdown ist, auch für PDF, Bild und Video |
| Offline | Markdown-Dateien bleiben auf jedem Gerät geladen. PDFs und Bilder werden durchsucht, sobald sie lokal sind, bis dahin zeigt der Baum ein Wolken-Symbol. |
| Aufgaben | Jede offene Checkbox ist eine Aufgabe; „To-dos“ ganz oben in der Sidebar zeigt alle wie Erinnerungen, nach Fälligkeit gruppiert (Überfällig, Heute, Morgen, Nächste 7 Tage, Später, Ohne Datum), mit den eingerückten Zeilen darunter als Notizen der Aufgabe, dazu die Notizen mit Erinnerung. Abhaken, öffnen und per Ziehen verschieben ändert die Notiz. Datum, Uhrzeit und Ort einer Aufgabe stehen **in der Notiz** hinter ihrem Text, so wie Obsidians Tasks- und Reminder-Plugins sie schreiben (`⏰ 2026-10-24 14:00`, `📅 2026-11-01`, ein Ort als Link zu Apple Maps), damit sie mit der Datei überall hin wandern; Notebook zeigt sie als kleine Kapseln. |
| Erinnerungen | „Erinnern…“ an eine Notiz zu einer Uhrzeit (#57) oder an einem Ort (#58), später zu einem Kalendertermin und als Live-Aktivität (Epic #55). Orte erinnern auf iPhone und iPad („Beim Verwenden“ genügt), der Mac kann sie nur setzen. Die Erinnerung einer Notiz steht nicht in der Notiz, sondern wie ausgeblendete Ordner im iCloud-Key-Value-Store, ein Schlüssel pro Erinnerung; jedes Gerät plant seine Mitteilungen selbst. Die Mitteilung zeigt die ersten Punkte der Notiz (offene Aufgaben zuerst), ist „Dringend“ (Time Sensitive) und bietet „In 1 Stunde erinnern“ und „Erledigt“. Erledigte Erinnerungen verschwinden aus dem Store. Keine Wiederholungen. |
| Versionen | Frühere Fassungen jeder Notiz als einfache Markdown-Kopien (#106): beim ersten Ändern nach dem Öffnen, alle 10 Minuten beim Schreiben, beim Aufhören, beide Seiten vor dem Zusammenführen oder einem Konflikt, und vor dem Wiederherstellen. Die Kopien von Notizen in iCloud liegen in Notebooks eigenem iCloud-Container (`iCloud.com.lukaskbl.Notebook`, Ordner `History` außerhalb von `Documents`, also unsichtbar in iCloud Drive), nach dem Pfad ab `Mobile Documents`, der auf jedem Gerät gleich ist; alle anderen und die von Debug- und Release-Builds in Application Support (`History.noindex`, damit Spotlight sie nicht findet). Nichts liegt neben den Notizen. Ausgedünnt wie bei Time Machine (alles der letzten Stunde, dann eine pro Stunde, Tag und Woche, in UTC gezählt), nach einem Jahr gelöscht; jedes Gerät dünnt nur seine eigenen Kopien aus (der Name sagt welches, „iPhone 3f9a2c“) und behält die neueste, damit eine falsch gestellte Uhr nicht alles löscht. Sie folgen Umbenennen und Verschieben in Notebook, nicht im Finder (#148). Mac: Ablage › Zurücksetzen auf; iPhone und iPad: Versionsverlauf im ⋯-Menü. |
| Symbol und Farbe | Ein Notizbuch aus Ochsenblut-Leder als App-Symbol, in den Einstellungen selbst einzufärben. Akzentfarbe ist Tintenblau (`#34508F` hell, `#93ABE3` dunkel), wenn in den Systemeinstellungen „Mehrfarbig“ gewählt ist. |

## 3. Wie es sich anfühlt

### Mac und iPad

```
┌──────────────────────┬──────────────────────────────────────────────────┐
│ ⌕ Suchen        ⌘K   │ ‹ ›   iCloud Drive › Projekte › Notes-App Idee  ⋯ │
│                      │                                                  │
│ Favoriten            │  Notes-App Idee                    ← Dateiname    │
│   ★ Inbox            │                                                  │
│   ★ Wochenende       │  Ersetzt Apple Notes, baut auf  Roadmap  auf.     │
│ Zuletzt              │  ┌────────────────────────────┐                   │
│   Roadmap            │  │         skizze.jpg         │  ← Objekt         │
│                      │  └────────────────────────────┘                   │
│ iCloud Drive         │  ☐ Editor-Spike                                   │
│ ▾ Projekte           │  ☑ Name finden                                    │
│     Notes-App Idee   │  ┌ Mermaid ───────────────────┐                   │
│     Roadmap          │  │  Ordner → Datei → Viewer   │  ← Block          │
│     Angebot.pdf      │  └────────────────────────────┘                   │
│ ▸ Uni                │                                                  │
│ ▸ Privat             │                                                  │
│ + Ort hinzufügen     │                                                  │
└──────────────────────┴──────────────────────────────────────────────────┘
```

- **Sidebar** (220 pt wie in Issues): Suchfeld, Favoriten, Zuletzt, dann ein Abschnitt pro Ort mit dem Baum. Er zeigt
  alle Dateien außer versteckten (`.assets`, `.DS_Store`). Nicht geladene Dateien tragen ein Wolken-Symbol.
  Ordner werden erst beim Aufklappen gelesen.
- **Baum-Aktionen:** Drag and Drop zum Verschieben. Im Kontextmenü: Neue Notiz, Neuer Ordner, Umbenennen, Verschieben,
  Zu Favoriten, Im Finder zeigen, In den Papierkorb.
- **Dokumentbereich:** Markdown im Live-Preview-Editor, alles andere in Quick Look (`QLPreviewView` auf dem Mac,
  `QLPreviewController` auf iPad und iPhone).
- **Toolbar:** Vor und Zurück, Pfad als Breadcrumb (anklickbar), Teilen und ein ⋯-Menü.
- **Tastatur:** ⌘K Leiste, ⌘N neue Notiz im aktuellen Ordner, ⌘⇧N neuer Ordner, ⌘[ und ⌘] zurück und vor,
  ⌘B, ⌘I und ⌘E (Code) im Editor, ⌘⇧M verschieben. Im Baum: ↑↓, → und ← zum Auf- und Zuklappen, ↵ umbenennen.

### iPhone

- **Startseite:** Favoriten, Zuletzt und die Orte. Ein Tipp auf einen Ort führt in den Ordner, ein Ordner pro
  Bildschirm, mit Zurück-Wischen.
- **Unten:** ein Suchfeld (öffnet dieselbe Suche wie ⌘K) und ein Knopf für eine neue Notiz, wie in Notes unter iOS 26+.
- **In einer Notiz:** eine Schreibleiste über der Tastatur mit Überschrift, Checkliste, Liste, Link (`[[`),
  Kamera, Dokumentenscanner und Fotos.

### ⌘K

Eine Leiste, drei Abschnitte, die beim Tippen gefüllt werden:

1. **Dateien**, unscharf nach Namen sortiert (wie in der Befehlsleiste von Issues). Der Pfad steht rechts.
2. **Im Text**: Treffer aus Notizen, PDFs (mit Seitenzahl) und Bildtexten, mit hervorgehobenem Ausschnitt.
3. **Befehle**: Neue Notiz „…“, Verschieben, Umbenennen, Zu Favoriten, Ort hinzufügen. Mit `>` nur Befehle.

Ist das Feld leer, zeigt die Leiste die zuletzt geöffneten Dateien. ↵ öffnet die Auswahl.

## 4. Dateiformat und Konventionen

Alles bleibt normales Markdown, damit andere Programme die Dateien weiter lesen können.

| Element | Syntax in der Datei | In Notebook |
| --- | --- | --- |
| Titel | Dateiname `Wochenende.md` | Große Titelzeile über dem Text, Umbenennen beim Bearbeiten |
| Bild | `![](.assets/Wochenende%202026-10-14%2015.32.10.jpg)` | Objekt, Größe an Breite angepasst, nie als Text sichtbar |
| Zeichnung | `![Drawing](.assets/Wochenende%20drawing%202026-10-16%20at%2010.20.15.png)`, daneben `… .drawing` mit den Strichen | So breit wie der Text, mit dem Stift-Knopf oder einem Tippen darauf bemalbar |
| Link | `[[Rezepte]]`, `[[Rezepte\|Text]]`, `[[Angebot.pdf]]` | Link-Objekt. `[[` öffnet Vorschläge. Ein Ziel, das es nicht gibt, ist blass und bietet „Erstellen“ an. |
| Einbettung | `![[Rezepte]]`, `![[Angebot.pdf]]` | Notiz: gerendert und nur lesbar. Andere Dateien: Quick-Look-Vorschaubild, ein Klick öffnet Quick Look. |
| Mathe | `$x^2$`, `$$ … $$` | Gerenderte Formel, Quelltext nur mit Cursor darin |
| Mermaid | ```` ```mermaid ```` | Gerendertes Diagramm, Quelltext nur mit Cursor darin |
| Callout | `> [!note] Titel` (die fünf von GitHub, die gängigen Obsidian-Typen werden darauf abgebildet) | Farbige Box mit Symbol |
| Checkliste | `- [ ]`, `- [x]` | Antippbare Checkbox, erledigt wird blass und durchgestrichen |
| Aufgabe mit Termin | `- [ ] Anrufen ⏰ 2026-10-24 14:00`, `📅 2026-11-01`, `📍 [Apotheke](https://maps.apple.com/?ll=…)` | Kapsel mit Tag, Uhrzeit oder Ort, rot wenn überfällig; ein Klick ändert sie |
| Frontmatter | `---` YAML `---` am Anfang | Dezente eingeklappte Zeile, Klick zeigt den YAML-Text |

**Links auflösen:** `[[Name]]` sucht zuerst im selben Ordner, dann im selben Ort und nimmt bei mehreren Treffern den
kürzesten Pfad (wie Obsidian). `[[Ordner/Name]]` entscheidet eindeutig. Benennt oder verschiebt man in Notebook,
werden alle Links nachgezogen. Benennt man im Finder um, bricht der Link sichtbar, und Notebook bietet „Erstellen“ an.

**Neue Notiz:** Der Cursor steht im Titel. Tippen und ↵ legt `Titel.md` an, dann geht es im Text weiter. Bleibt der
Titel leer, heißt die Datei „Unbenannt“, „Unbenannt 2“ usw. Zeichen, die in Dateinamen nicht erlaubt sind (`/`, `:`),
werden ersetzt.

**Anhänge:**
- Einfügen (Einsetzen, Drag and Drop, Kamera, Fotos, Scanner) schreibt nach `<Ordner>/.assets/<Notiz> <Datum Uhrzeit>.jpg`,
  als JPEG oder PNG statt HEIC, damit GitHub und andere sie anzeigen. Gescannte Seiten werden einzelne Bilder, die OCR
  macht sie durchsuchbar.
- Wird ein Bild aus der Notiz gelöscht, kommt die Datei in den Papierkorb, sobald die Notiz geschlossen wird und keine
  andere Notiz im Ordner sie benutzt. Bis dahin funktioniert ⌘Z.
- Verschiebt man eine Notiz in Notebook in einen anderen Ordner, wandern ihre Bilder in dessen `.assets` mit, und die
  Pfade werden angepasst. Kopiert man ein Bild in eine Notiz in einem anderen Ordner, wird die Datei kopiert.
- Zeichnungen (seit Oktober 2026, auf Wunsch): ein PNG in `.assets`, das jede Markdown-App zeigt (Tinte auf Weiß, damit
  es auch im Dunkelmodus lesbar ist), daneben eine gleichnamige `.drawing`-Datei mit den PencilKit-Strichen (Property
  List: Format, Breite, Höhe, `PKDrawing`-Daten). Notebook malt aus den Strichen und schreibt das PNG nach jeder
  Änderung neu. Beide wandern beim Verschieben, Kopieren und Aufräumen zusammen. iPhone und iPad zeichnen mit
  `PKCanvasView` und `PKToolPicker`; der Mac hat in PencilKit keine Zeichenfläche, dort erzeugt eine eigene Fläche
  PencilKit-Striche aus Maus, Trackpad oder Grafiktablett.

## 5. Architektur

Aufbau wie bei Issues: eine schlanke App und ein lokales Swift-Paket, das die eigentliche Arbeit macht.

```
Notebook.xcodeproj
├── Notebook/                  App (Mac, iPhone, iPad): App-Einstieg, Szenen, Einstellungen
├── NotebookWidgets/           Widget, Control-Center-Control, Sperrbildschirm (WidgetKit + App Intents)
├── NotebookShare/             Share Extension (iOS und Mac)
└── Packages/NotebookKit/Sources/NotebookKit/
    ├── Files/                 Orte, Bookmarks, Baum, Datei-Operationen, Koordination, iCloud-Status
    ├── Markdown/              Parser (cmark-gfm) + Notebook-Erweiterungen, Link-Auflösung
    ├── Editor/                TextKit-2-Editor: Styling, Ausblenden, Objekte, Blöcke, Eingabehilfen
    ├── Render/                Mermaid, Mathe, Code-Hervorhebung, Quick-Look-Vorschaubilder
    ├── Index/                 SQLite FTS5 (GRDB), PDF-Text, OCR, Spotlight, Favoriten, Zuletzt
    └── UI/                    Theme, Sidebar/Baum, Drill-down, ⌘K, Dokumentbereich, Quick Look
```

### Files

- **Orte:** Auf dem Mac wählt man sie per `NSOpenPanel`, auf iOS per `.fileImporter(allowedContentTypes: [.folder])`.
  Gespeichert werden Security-Scoped Bookmarks in einer App Group, damit Widget und Share Extension sie mitnutzen
  können. iCloud Drive wird beim ersten Start vorgeschlagen.
- **Lesen und Schreiben** laufen immer über `NSFileCoordinator`. Speichern geschieht automatisch, kurz nach der letzten
  Eingabe sowie beim Schließen und beim Wechsel in den Hintergrund, atomar geschrieben.
- **Änderungen von außen:** Die offene Notiz und die aufgeklappten Ordner hören per `NSFilePresenter` mit (auf dem Mac
  zusätzlich FSEvents). Hat sich eine Notiz ohne lokale Änderungen geändert, wird sie still neu geladen, der Cursor
  bleibt stehen. Haben beide Seiten geändert (auch iCloud-Konflikte über `NSFileVersion`), erscheint ein Banner:
  „Auf einem anderen Gerät geändert: Diese behalten · Andere nehmen · Beide behalten“.
- **iCloud-Status** kommt aus den URL-Resource-Keys (`ubiquitousItemDownloadingStatus`). Nicht geladene `.md`-Dateien
  werden mit `startDownloadingUbiquitousItem` geholt, damit Notizen immer lokal sind.

### Markdown

- **Parser:** cmark-gfm über `swift-cmark` (wie in Issues) mit Tabellen, Task-Listen, Durchstreichen, Autolinks und
  Fußnoten. Wichtig sind die **Quellpositionen** jedes Knotens: Der Editor stylt damit genau die Zeichen im Text.
- **Notebook-Erweiterungen** als eigener Durchlauf über den Baum: `[[…]]` und `![[…]]` in Text-Knoten, `$…$`, `$$…$$`,
  Callouts (Blockquote mit `[!typ]`), Frontmatter am Dateianfang.
- Bei jeder Änderung wird neu geparst (kurz verzögert). cmark ist für Notizgrößen schnell genug, und neu gestylt werden
  nur die betroffenen Absätze.

### Editor (das Herzstück)

`NSTextView` (Mac) und `UITextView` (iOS) mit TextKit 2, jeweils in einem Representable verpackt. Der Kern, also Styling,
Objekte und Blöcke, ist geteilt.

1. **Text = Markdown-Quelltext.** Die `NSTextContentStorage` enthält exakt den Dateiinhalt, gestylt wird nur über
   Attribute. So bleibt die Datei Zeichen für Zeichen erhalten, und Undo, Diktat, Autokorrektur, Writing Tools und
   Scribble verhalten sich wie im System.
2. **Inline-Formatierung** (`**`, `_`, `` ` ``, `~~`, `#` vor Überschriften): Die Zeichen sind außerhalb des Absatzes
   mit dem Cursor ausgeblendet und darin blass sichtbar. Listenpunkte und Checkboxen sind immer gerendert, wie in Notes.
3. **Objekte** (Bilder, `[[Links]]`, `![[Einbettungen]]`): Der Quelltext wird durch einen `NSTextAttachment` mit
   View-Provider ersetzt dargestellt. Der Cursor springt darüber, Backspace löscht das ganze Objekt, Kopieren nimmt
   das Markdown mit.
4. **Blöcke** (Tabelle, `$$`, Mermaid, Code): Steht der Cursor außerhalb, sieht man die gerenderte Ansicht als Attachment.
   Kommt der Cursor hinein, erscheint der blasse Quelltext mit Hervorhebung. Callouts sind gestylte Absätze mit
   Hintergrund und Symbol.
5. **Eingabehilfen:** `[[` öffnet Vorschläge, ↵ in Listen setzt die Liste fort, Tab und ⇧Tab rücken ein, ⌘B und ⌘I
   setzen Markdown, und Einsetzen von Bildern oder Dateien legt Anhänge an.

### Render

- **Mermaid:** `beautiful-mermaid-swift` (in Issues erprobt, exakte Version wie dort)
- **Mathe:** eine native LaTeX-Bibliothek (Kandidat: SwiftMath), kein WebView
- **Code-Hervorhebung:** eine kleine Bibliothek, Entscheidung in M2 (Kandidaten: Highlightr oder Tree-sitter über Neon)
- **Vorschaubilder** für Einbettungen und Baum: `QLThumbnailGenerator`, Bilder mit ImageIO verkleinert

### Index

- **SQLite mit FTS5 über GRDB** (wie in Issues), als Cache pro Gerät in Application Support. Er lässt sich jederzeit
  neu aufbauen und wird nie synchronisiert.
- **Tabellen:** Dateien (Ort, Pfad, Art, Änderungsdatum, Größe, lokal ja/nein), Volltext (Titel, Inhalt, Quelle,
  Seite), Links (von, Ziel-Name) für das Nachziehen beim Umbenennen.
- **Hintergrundarbeit mit niedriger Priorität**, gemerkt pro Pfad, Datum und Größe: Markdown-Text, PDF-Text über PDFKit
  (pro Seite), OCR über Vision für Bilder in den Orten und in `.assets`.
- **Spotlight:** Notizen gehen über `CSSearchableIndex` hinein, ein Tipp öffnet die Notiz in Notebook.
- **Favoriten und Zuletzt** werden als Pfade relativ zum Ort im iCloud-Key-Value-Store gespeichert, so sind sie auf allen
  Geräten gleich.

### Schnell notieren

- **Ein App Intent „Neue Notiz“** steckt hinter dem Widget, dem Control im Kontrollzentrum und auf dem Sperrbildschirm
  sowie der Action-Taste. Er öffnet Notebook mit einer neuen Notiz in der Inbox, der Cursor steht im Titel.
  (Kurzbefehle bekommen ihn nebenbei mit. Eigene Siri- und Kurzbefehle-Aktionen sind bewusst nicht geplant.)
- **Share Extension:** Text, Links, Bilder und PDFs werden zu einer neuen Notiz in der Inbox (oder per Auswahl zu
  „An zuletzt geöffnete Notiz anhängen“). Kommt die Extension nicht direkt an den Ort, legt sie den Inhalt in der App
  Group ab, und die App verschiebt ihn beim nächsten Start in die Inbox.
- **Inbox** ist ein normaler Ordner, standardmäßig `iCloud Drive/Inbox`, in den Einstellungen änderbar. Er steht
  automatisch in den Favoriten.

## 6. Meilensteine

Jeder Meilenstein endet mit etwas, das du selbst benutzen kannst.

### M0: Spikes (Risiken zuerst)

Zwei Wegwerf-Prototypen, bevor die eigentliche App entsteht:

**Editor-Spike** (Mac und iPhone):
- Markdown-Quelltext in TextKit 2, gestylt aus dem cmark-Baum (Überschriften, fett, kursiv, Code, Listen)
- Markdown-Zeichen außerhalb des Cursor-Absatzes ausblenden, ohne dass Cursor, Auswahl, Undo, Diktat und Autokorrektur
  hakeln
- Ein Bild als festes Objekt und ein Mermaid-Block, der beim Hineinklicken zu Quelltext wird
- Writing Tools direkt im Text, Tippverzögerung bei einer 50-KB-Notiz
- **Ergebnis ist eine Entscheidung:** Kann TextKit 2 Zeichen sauber ausblenden? Erster Kandidat ist eine fast unsichtbare
  Schrift für die Zeichen, die die Zeichen-Positionen 1:1 lässt. Zweiter Kandidat sind eigene Layout-Fragmente.
  Ausweg wäre TextKit 1 mit ausgeblendeten Glyphen über `NSLayoutManagerDelegate`, das bewährt ist, aber Writing Tools
  nur eingeschränkt unterstützt.

**Datei-Spike** (iPhone und Mac):
- Auf iOS ganz iCloud Drive als Ort wählen, das Bookmark speichern und nach einem Neustart wieder auflösen
- Änderungen vom Mac kommen per `NSFilePresenter` in einem Ordner außerhalb des App-Containers an
- Nicht geladene Dateien erkennen (dataless oder `.icloud`-Platzhalter) und `.md` gezielt laden
- Bookmarks in der Share Extension über die App Group auflösen (oder die Queue als Ausweg bestätigen)
- `trashItem` auf iCloud Drive unter iOS, und wie schnell der Baum bei tausenden Dateien liest

### M1: Gerüst, Finder-Ersatz

- Multiplatform-Projekt, `NotebookKit`, Theme aus Issues übernommen
- Orte hinzufügen und entfernen, Baum auf Mac und iPad, Drill-down auf dem iPhone, Favoriten, Zuletzt
- Datei-Operationen: neue Notiz und neuer Ordner, Umbenennen, Verschieben per Drag and Drop, Papierkorb
- Quick Look für alles, was nicht Markdown ist
- Editor in der ersten Stufe: Markdown gestylt, Zeichen sichtbar, aber blass (die Stufe vor Live-Preview), Titel =
  Dateiname, automatisches Speichern, Neuladen bei Änderungen von außen

*Ergebnis:* Notebook zeigt alles in iCloud Drive an, und man kann darin schon Notizen schreiben.

### M2: Live-Preview, Notizen schreiben sich gut

- Zeichen außerhalb der Cursor-Zeile ausgeblendet, Checkboxen antippbar, Listen setzen sich fort
- `[[Links]]` als Objekte mit Vorschlägen und Auflösung, nicht vorhandene Ziele mit „Erstellen“
- Bilder als Objekte: Einsetzen und Drag and Drop nach `.assets`, Aufräumen ungenutzter Bilder in den Papierkorb
- Blöcke: Code mit Hervorhebung, Tabellen, Mermaid, Mathe, Callouts, Fußnoten, Frontmatter eingeklappt
- `![[Einbettungen]]` für Notizen und Dateien
- Konflikt-Banner

*Ergebnis:* Am Mac ersetzt Notebook Notes zum Schreiben.

### M3: Finden

- Index (GRDB, FTS5) mit Hintergrundaufbau
- ⌘K mit Dateien, Treffern im Text und Befehlen, das Suchfeld auf dem iPhone öffnet dieselbe Suche
- Links werden beim Umbenennen und Verschieben nachgezogen
- PDF-Text, OCR für Bilder und Scans, Spotlight

*Ergebnis:* Alles ist schneller gefunden als in Notes.

### M4: Notes-Ersatz auf dem iPhone

- Schreibleiste über der Tastatur, Kamera, Fotos und Dokumentenscanner in `.assets`
- Widget, Control im Kontrollzentrum und auf dem Sperrbildschirm, Action-Taste über den App Intent „Neue Notiz“
- Share Extension, Inbox
- Feinschliff von Gesten und Wischaktionen im Drill-down (Favorit, Verschieben, Löschen)

*Ergebnis:* Notes kann vom Home-Bildschirm.

### M5: Alltag

Ein paar Wochen nur Notebook benutzen, Reibung sammeln und abbauen. Danach entscheiden, ob und wann es in den App Store
geht (Übersetzungen, Onboarding, Website, Screenshots wie bei Issues).

## 7. Bewusst nicht drin

Tags, Backlinks, eigene Tabs und Split View, Eigenschaftsleiste für Frontmatter, eigene Viewer für PDF, Bild und Video,
PDFs markieren, Handschrifterkennung, Audio und Transkription, Bearbeiten von Text- und Code-Dateien, Schnellnotiz-
Fenster am Mac, eigene Kurzbefehle- und Siri-Aktionen, Notizen sperren, Zusammenarbeit, Plugins, eigener Sync.

Das meiste davon lässt sich später ergänzen, ohne das Dateiformat zu ändern.

## 8. Risiken

| Risiko | Umgang |
| --- | --- |
| Markdown-Zeichen in TextKit 2 sauber ausblenden | Editor-Spike in M0, TextKit 1 als Ausweg |
| Feste Objekte und Blöcke in einem Quelltext-Editor (Cursor, Auswahl, Undo) | Im Spike mit einem Bild und einem Mermaid-Block nachweisen |
| Ganz iCloud Drive als Ort auf iOS, Benachrichtigungen für fremde Ordner | Datei-Spike in M0 |
| Große iCloud Drives (tausende Dateien, viel nicht geladen) | Baum liest erst beim Aufklappen, Index im Hintergrund, nur `.md` wird erzwungen geladen |
| Umbenennen im Finder bricht Links | Gebrochene Links sichtbar machen, „Erstellen“ und Vorschläge anbieten |
| Bilder löschen, die noch gebraucht werden | Erst beim Schließen und nur, wenn keine Notiz im Ordner sie nutzt, dann in den Papierkorb statt endgültig |

## 9. Noch offen

- **Import aus Apple Notes:** Reicht der Markdown-Export, den Notes seit iOS und macOS 26 selbst hat, oder lohnt sich ein
  kleines Werkzeug, das alle Notizen samt Ordnern auf einmal holt?
- **Sortierung im Baum:** nach Name oder nach Änderungsdatum, Ordner zuerst?
- **Typografie des Dokuments:** SF Pro oder New York, Lesebreite (Vorschlag: etwa 680 pt, mittig)
