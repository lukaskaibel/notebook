fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### screenshots

```sh
[bundle exec] fastlane screenshots
```

Takes the App Store screenshots of the iPhone, iPad and Mac apps on the sample notes

### metadata

```sh
[bundle exec] fastlane metadata
```

Uploads the texts, the age rating and the screenshots of the Mac, iPhone and iPad apps

screenshots:false uploads the texts alone, leaving the screenshots in App Store Connect as they are

### build

```sh
[bundle exec] fastlane build
```

Builds the Mac, iPhone and iPad apps for the App Store, signed, without uploading them

### beta

```sh
[bundle exec] fastlane beta
```

Builds the Mac, iPhone and iPad apps and uploads them to TestFlight

### submit

```sh
[bundle exec] fastlane submit
```

Submits the newest uploaded builds of the Mac, iPhone and iPad apps for review, with texts and screenshots

Builds nothing: run it after `beta` once the TestFlight builds are tested. automatic_release:true as for release

### release

```sh
[bundle exec] fastlane release
```

Builds the Mac, iPhone and iPad apps, uploads them with texts and screenshots and submits them for review

submit:false stops before the submission, automatic_release:true releases them as soon as they are approved

### store_media

```sh
[bundle exec] fastlane store_media
```

Checks the header, the search result and the app previews against App Store Connect's specs, says where they'd go

version:1.1.0 is required. upload:true uploads them to the app's Asset Library and places them on that version's

English page, once every one has passed; platform:ios or platform:mac takes one platform alone

----


## iOS

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Takes the iPhone and iPad screenshots

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Uploads the texts, the age rating and the screenshots of the iPhone and iPad app

### ios build

```sh
[bundle exec] fastlane ios build
```

Builds the iPhone and iPad app for the App Store, signed, without uploading it

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Builds the iPhone and iPad app and uploads it to TestFlight

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Submits the newest uploaded build of the iPhone and iPad app for review, with texts and screenshots

### ios release

```sh
[bundle exec] fastlane ios release
```

Builds the iPhone and iPad app, uploads it with texts and screenshots and submits it for review

----


## Mac

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Takes the Mac screenshots

### mac metadata

```sh
[bundle exec] fastlane mac metadata
```

Uploads the texts, the age rating and the screenshots of the Mac app

### mac build

```sh
[bundle exec] fastlane mac build
```

Builds the Mac app for the App Store, signed, without uploading it

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Builds the Mac app and uploads it to TestFlight

### mac submit

```sh
[bundle exec] fastlane mac submit
```

Submits the newest uploaded build of the Mac app for review, with texts and screenshots

### mac release

```sh
[bundle exec] fastlane mac release
```

Builds the Mac app, uploads it with texts and screenshots and submits it for review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
