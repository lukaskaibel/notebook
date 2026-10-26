# App Store listing

The Mac, iPhone and iPad apps are one App Store app (`com.lukaskbl.Notebook`, universal purchase), released with
fastlane (see the README's "For contributors"). fastlane uploads:

- the texts in `fastlane/metadata`: name, subtitle, description, keywords, promotional text, URLs, category,
  copyright and the notes for App Review;
- the age rating in `fastlane/rating.json`;
- the screenshots in `Design/screenshots/app-store`: 6.9-inch iPhone and 13-inch iPad from
  `Tools/app-store-screenshots.sh`, Mac at 2880 × 1800 from `Tools/mac-app-store-screenshots.sh`, all on the sample
  notes (`bundle exec fastlane screenshots` runs both).

The contact for App Review is in `fastlane/.env.secret`, which is not checked in.

The links point to the website in `Website/` (published to GitHub Pages): privacy policy
`https://lukaskaibel.github.io/notebook/privacy/`, support `…/support/` and marketing the home page. The license
agreement is Apple's standard EULA.

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
| Certificates, Identifiers & Profiles › Identifiers › App Groups | **`group.com.lukaskbl.Notebook`**, in which the share extension leaves what is shared for the app. Registered here, and given to `com.lukaskbl.Notebook` and `com.lukaskbl.Notebook.Share` under App Groups › Configure on each. fastlane turns App Groups on and registers the Share identifier, but the API key can't make the group or give it to them; without it fastlane stops before building and says so. |
| Users and Access › Integrations | The App Store Connect API key fastlane uses (App Manager or Admin, with access to certificates, identifiers and profiles). |

## Why the answers are what they are

- **The texts** follow the positioning settled on 2026-10-24: the tagline "The ease of Notes. The freedom of files."
  first, then one paragraph each for your files, no vault, and an Apple app. Markdown is the proof, not the headline,
  so it stays in the name for search and goes into the second line everywhere else.
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

The first version has none. From the second version on, write it in `fastlane/metadata/en-US/release_notes.txt`, for
users, from the changelog.

## A new version

While a version of either platform is waiting for review, in review or waiting to be released, App Store Connect keeps
the app's name locked, as both platforms share it, and takes no new version of that platform. fastlane checks this
first and stops with the reason; release the waiting version (or remove it from review) and run it again. TestFlight
builds (`bundle exec fastlane beta`) can go up at any time.
