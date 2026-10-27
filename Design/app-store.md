# App Store listing

The Mac, iPhone and iPad apps are one App Store app (`com.lukaskbl.Notebook`, universal purchase), released with
fastlane (see the README's "For contributors"). fastlane uploads:

- the texts in `fastlane/metadata`: name, subtitle, description, keywords, promotional text, What's New
  (`release_notes.txt`), URLs, category, copyright and the notes for App Review;
- the age rating in `fastlane/rating.json`;
- the screenshots in `Design/screenshots/app-store`, ten per device, each with a caption line and a smaller one above
  the screen: 6.9-inch iPhone and 13-inch iPad from `Tools/app-store-screenshots.sh`, Mac at 2880 × 1800 from
  `Tools/mac-app-store-screenshots.sh`, all on the sample notes (`bundle exec fastlane screenshots` runs both). The
  captions are in the scripts, next to each scene; `Tools/app-store-media/caption.py` lays them out.

deliver can't upload the header and search-result assets of iOS 27 or the app previews; `bundle exec fastlane
store_media` does, below.

The contact for App Review is in `fastlane/.env.secret`, which is not checked in.

The links point to the website in `Website/` (published to GitHub Pages): privacy policy
`https://lukaskaibel.github.io/notebook/privacy/`, support `…/support/` and marketing the home page. The license
agreement is Apple's standard EULA.

## Header, search result and app previews

The App Store of iOS 27 and iPadOS 27 shows two pictures of its own above the screenshots, each a still or a looping,
muted video: the **product page header** (21:9, 3840 × 1646), at the top of the product page, and the **search result**
(3:2, up to 3840 × 2560), what people see in search before they tap. The Mac App Store has neither. Both are made by
`Tools/app-store-media.sh`, on the sample notes, with the Mac app in the background:

| | Picture | Video | What it shows |
|---|---|---|---|
| Header | `creative/header.png` | `creative/header.mp4`, 12 s | "Weekend" being typed: a heading, a to-do, a bold word and a highlight, their Markdown marks showing while they are typed and folding away after. The finished lines are the poster. |
| Search result | `creative/search.png` | `creative/search.mp4`, 16 s | "Right next to your documents." over the files of the folder Travel: Kyoto trip.md, shown as its plain text, opens into the note in Notebook between a PDF, a photo and another note, scrolls a little and closes again. |

(`creative/` is `Design/screenshots/app-store/creative`.) The row of files is a picture of files, not of the Finder:
the PDFs and the photo are macOS's own Quick Look thumbnails of the sample files, the Markdown files are drawn as a page
of their text, and the note is Notebook's window. `Tools/app-store-media/creative.py` lays them out from the captures;
it measures where the text is in them rather than counting on fixed places.

The **app previews**, one per device, play before the screenshots: iPhone (886 × 1920) and iPad (1200 × 1600) from
`Tools/app-store-previews.sh` in the simulator, Mac (1920 × 1080) from `Tools/mac-app-store-preview.sh`, put together
by `Tools/app-store-media/preview.py`. They are 25 to 28 seconds of the app itself, H.264 at 30 fps and 11 Mbps, with a
silent stereo track: App Store Connect turns down previews without one. They go to `build/app-store-media/previews`
and aren't checked in (about 40 MB each); make them again before uploading. The Mac's scripts bring the app to the
front, so its window is drawn active: run them when nobody is working at the Mac, with the screen unlocked.

**What App Store Connect takes**, as its reference data says (`GET /v1/appAssetLibraryRefData`), and Apple's templates
(developer.apple.com/app-store/asset-best-practices):

- Header: a 3840 × 1646 PNG, or a 3840 × 1646 video at 30 or 60 fps of 10 to 30 seconds. Search result: a 3:2 JPEG or
  PNG from 1920 × 1280 to 3840 × 2560, or a 3:2 video of 15 to 30 seconds. One 5244 × 2950 PNG may serve both; there
  is no such video. No alpha, at most 500 MB, one of each per language.
- The art safe area, which every device shows: x 1097–2743, y 493–1154 on the header (an iPhone shows little more),
  x 836–3004, y 765–1795 on the search result. The text and the note are inside it.
- One picture for both appearances: there is no light and dark pair, so both are dark, which sits well on a light App
  Store and doesn't glare on a dark one.
- App previews: 15 to 30 seconds at up to 30 fps, with audio.

**Uploading.** They go to the app's Asset Library through the App Store Connect API (fastlane 2.240 has nothing for
it) and are placed on a version's English page, from where they go to App Review with the version.

```
bundle exec fastlane store_media version:1.1.0               # checks each file against the specs, says what it would do
bundle exec fastlane store_media version:1.1.0 upload:true   # uploads them and places them on 1.1.0
```

Without `upload:true` the lane only reads: App Store Connect's specs, the library and the version. With it, each video
is reserved in the library, uploaded, committed and placed (`fastlane/asset_library.rb`), in place of what that
placement shows there now; the version must exist and still be open for changes. Check the result in App Store
Connect's Preview (iPhone and iPad, portrait and landscape) before submitting the version. The posters are set in
`STORE_MEDIA` in the Fastfile: the header's finished lines 1.5 seconds before its end, the search result's open note
at 4 seconds, and 5 seconds into each preview.

## Once, in App Store Connect

fastlane can't do these; they are set by hand.

| Where | What |
|---|---|
| Apps › New App | Platforms **iOS** and **macOS**, name **Notebook – Markdown Notes** (under the icon the app is called Notebook), primary language English (U.S.), bundle ID `com.lukaskbl.Notebook`. |
| App Privacy | **Data Not Collected.** Notebook has no server, analytics or ads, and nothing of the user's reaches the developer. Place search goes to Apple Maps, hidden folders and reminders to the user's own iCloud key-value store, and earlier versions of notes in iCloud to Notebook's folder in the user's own iCloud; Apple runs all of them, and data Apple's own services handle isn't the developer's to declare. |
| Pricing and Availability | **Free**, all countries and regions. |
| Business › Digital Services Act | The account's trader status, which App Store Connect asks for before an app is offered in the EU. Set once for all apps of the account. |
| Certificates, Identifiers & Profiles › Identifiers › `com.lukaskbl.Notebook` | **iCloud** (with CloudKit support) and **Time Sensitive Notifications**. fastlane turns them on before it fetches the App Store profiles, if they are off. |
| Certificates, Identifiers & Profiles › Identifiers › iCloud Containers | **`iCloud.com.lukaskbl.Notebook`**, description "Notebook": "+" › iCloud Containers › Register. Then, under the App ID `com.lukaskbl.Notebook`, iCloud › Configure › tick the container › Save. Version history keeps the earlier versions of notes in iCloud there. The App Store Connect API can't make a container or give it to an App ID; without it fastlane stops before exporting and says so. A container can't be deleted or renamed. |
| Certificates, Identifiers & Profiles › Identifiers › `com.lukaskbl.Notebook.Widgets` | The widgets' extension, for iOS and macOS, with no capabilities. fastlane registers it the first time it builds the app, and makes its App Store profiles with the app's. |
| Certificates, Identifiers & Profiles › Identifiers › App Groups | **`group.com.lukaskbl.Notebook`**, in which the share extension leaves what is shared for the app. Registered here, and given to `com.lukaskbl.Notebook`, `com.lukaskbl.Notebook.Widgets` and `com.lukaskbl.Notebook.Share` under App Groups › Configure on each. fastlane turns App Groups on and registers the Share identifier, but the API key can't make the group or give it to them; without it fastlane stops before building and says so. |
| Users and Access › Integrations | The App Store Connect API key fastlane uses (App Manager or Admin, with access to certificates, identifiers and profiles). |

## Why the answers are what they are

- **The texts** follow the positioning settled on 2026-10-24: the tagline "The ease of Notes. The freedom of files."
  first, then one paragraph each for your files, no vault, and an Apple app. Markdown is the proof, not the headline,
  so it stays in the name for search and goes into the second line everywhere else. For 1.1 the description is
  shorter (about 2,100 characters rather than 3,400): the story in two paragraphs, what's new, then trimmed lists.
- **The subtitle**, "Your notes, in any folder", is the user's own wording (2026-10-27), in place of 1.0's "Your notes,
  your files": it says the "no vault" claim plainly, and "folder" helps search.
- **The search result's phrase**, "Right next to your documents.", sits right above the app's name and the subtitle,
  so it doesn't start with "Your notes" too. The header has no words: the app's name is right under it.
- **The header and the search result** say the tagline between them: the header the ease (writing, the marks fading as
  in Notes), the search result the freedom (the note is a file among the others). Of the three ideas tried, a note on
  the Mac, iPad and iPhone together was too busy for the safe area; it is the app previews' job.
- **The promotional text** names what 1.1 brings, as long as it is new; it can change without review, so it goes back
  to the tagline later.
- **The keywords** leave out what the name has (Markdown, notes) and what few search for (md, reminder, search,
  drawing), and add widget, wiki, offline and private.
- **The screenshots' captions** are short, so a first-time visitor scrolling past ten pictures gets the story from
  them; the screens stay real and unchanged under them.
- **Name, subtitle and keywords** name no other app or company (Guideline 2.3.7). The description names Obsidian once,
  as an app that reads the same files: compatibility, not a comparison.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `NO` in the Info.plist; Notebook has no encryption of its
  own.
- **Content rights:** no third-party content. The app shows the user's own files, and the sample notes, their pictures
  and drawing are made by the app.
- **Age rating:** none of the content questions apply. "User-generated content" is no: notes are the user's own files
  and aren't shared with other people through the app. "Unrestricted web access" is no: links open in the browser.
- **Privacy manifest:** `Notebook/PrivacyInfo.xcprivacy` says the app tracks no one, collects nothing, and why it reads
  UserDefaults and file dates.
- **Trying it for App Review:** "Try Sample Notes" on the first screen makes a folder of sample notes, on the Mac where
  the reviewer chooses, on iPhone and iPad in the app's own folder. Guideline 4.8 doesn't apply: there are no accounts.
- **Permissions** are asked for when first needed and described in the review notes: notifications for the first
  reminder, location (While Using) for a reminder's place, the camera for a photo or scan.

## Languages

The app and the listing are in English (U.S.) only, for now (#27).

## What's New

`fastlane/metadata/en-US/release_notes.txt`, for users, from the changelog: what a version brings first, then the
fixes most would notice. The first version had none.

## A new version

While a version of either platform is waiting for review, in review or waiting to be released, App Store Connect keeps
the app's name locked, as both platforms share it, and takes no new version of that platform. fastlane checks this
first and stops with the reason; release the waiting version (or remove it from review) and run it again. TestFlight
builds (`bundle exec fastlane beta`) can go up at any time.
