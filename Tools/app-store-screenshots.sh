#!/bin/bash
# Takes the App Store screenshots of the iPhone and iPad app on the sample notes, ten each, with a caption above the
# screen: a 6.9-inch iPhone (1320 x 2868) and a 13-inch iPad (2064 x 2752), mostly light and a few dark, with a clean
# status bar. They end up in Design/screenshots/app-store/{iphone,ipad} as 01-… to 10-…, in the store's order.
#   Tools/app-store-screenshots.sh            both
#   Tools/app-store-screenshots.sh iphone     one of them
# Builds a Debug copy under a bundle identifier of its own and installs it afresh for every picture, on simulators of
# the script's own (made the first time, on iOS 27.0, which has the iPhone 17 Pro Max), each time on new sample notes
# (Files/DemoLibrary.swift). The scene is set up through the debug remote (Debug/DebugRemote+UIKit.swift), as in
# Tools/readme-images.sh, and taken with `simctl io screenshot` into build/app-store-screenshots/ios/raw; then
# Tools/app-store-media/caption.py lays each out with its caption on the backdrop of the README pictures. The widgets
# live on the Home Screen, which the app can't drive: a UI test (NotebookUITests/StoreMediaRemote.swift) adds them there
# as a person would. One simulator runs at a time. Runs in the background; about twenty minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }

only=${1:-}
work=build/app-store-screenshots/ios
raw=$work/raw
out=Design/screenshots/app-store
products=$work/DerivedData/Build/Products/Debug-iphonesimulator
app=$products/Notebook.app
bundle_id=com.lukaskbl.Notebook.screenshots
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0

xcrun simctl list runtimes available | grep -q "iOS 27.0 " || {
  echo "No iOS 27.0 simulator runtime. Install it in Xcode › Settings › Components." >&2
  exit 1
}

echo "Building…"
mkdir -p "$work"
# The app with its widgets, and the UI test that puts them on the Home Screen.
xcodebuild -project Notebook.xcodeproj -scheme NotebookUITests -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/DerivedData" \
  NOTEBOOK_BUNDLE_IDENTIFIER=$bundle_id ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing -quiet

# simulator <name> <device type>: a simulator of the script's own, made the first time and booted, by its UDID.
simulator() {
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c "import json, sys
devices = json.load(sys.stdin)['devices'].get('$runtime', [])
print(next((d['udid'] for d in devices if d['name'] == '$1'), ''))")
  [ -n "$udid" ] || udid=$(xcrun simctl create "$1" "$2" "$runtime")
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  # In English and the US region, whatever the Mac's are, so the status bar says 9:41 and dates are written the US way.
  if [ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null)" != en_US ]; then
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b > /dev/null
  fi
  # A new simulator's keyboard first shows a tip about sliding to type, over the keys.
  xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
  echo "$udid"
}

# launch <udid> <theme> <command>…: a fresh install on new sample notes, the scene set up by the debug remote; returns
# once the remote has run `done`.
launch() {
  local udid=$1 theme=$2 container line
  shift 2
  xcrun simctl ui "$udid" appearance "$theme"
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl uninstall "$udid" $bundle_id 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
  container=$(xcrun simctl get_app_container "$udid" $bundle_id data)
  mkdir -p "$container/Documents"
  : > "$container/Documents/cmd"
  rm -f "$container/Documents/cmd.log"
  for line in "$@" "done"; do echo "$line" >> "$container/Documents/cmd"; done
  xcrun simctl launch "$udid" $bundle_id -NotebookLibrary "~/Documents/Notes" -NotebookLibraryName "iCloud Drive" \
    -NotebookDemo YES -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO \
    -debugCommandFile "~/Documents/cmd" > /dev/null
  for _ in $(seq 120); do
    grep -q "^> done" "$container/Documents/cmd.log" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "The scene didn't finish: $*" >&2
  exit 1
}

# layout <device> <name> <theme> <caption> <smaller line>: the raw picture with its caption, as the store takes it.
layout() {
  python3 Tools/app-store-media/caption.py "$raw/$1/$2.png" "$out/$1/$2.png" "$1" "$3" "$4" "$5"
  echo "$out/$1/$2.png"
}

# shot <udid> <device> <name> <theme> <caption> <smaller line> <command>…: the scene, a screenshot, its layout.
shot() {
  local udid=$1 device=$2 name=$3 theme=$4 line=$5 smaller=$6
  shift 6
  launch "$udid" "$theme" "$@"
  sleep 1
  xcrun simctl io "$udid" screenshot "$raw/$device/$name.png" > /dev/null 2>&1
  xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
  layout "$device" "$name" "$theme" "$line" "$smaller"
}

# widgets <udid> <device> <name> <caption> <smaller line> <remote command>…: the Home Screen with Notebook's widgets.
# The Home Screen starts as a new simulator's, with Apple's widgets, which the steps take away. The app runs once
# first, so the widgets have the sample notes' to-dos; then the UI test adds them as a person would.
widgets() {
  local udid=$1 device=$2 name=$3 line=$4 smaller=$5 commands=$work/remote
  shift 5
  xcrun simctl shutdown "$udid"
  rm -f ~/Library/Developer/CoreSimulator/Devices/"$udid"/data/Library/SpringBoard/IconState.plist
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  sleep 5
  launch "$udid" light "wait 8" "showtodos" "wait 3"
  xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
  : > "$commands"
  rm -f "$commands.log"
  for command in "$@" "done"; do echo "$command" >> "$commands"; done
  TEST_RUNNER_STORE_MEDIA_COMMANDS="$PWD/$commands" xcodebuild test-without-building -project Notebook.xcodeproj \
    -scheme NotebookUITests -destination "id=$udid" -derivedDataPath "$work/DerivedData" \
    -only-testing:NotebookUITests/StoreMediaRemote/testRemote > "$work/remote-test.log" 2>&1 || true
  if grep -q "^? " "$commands.log" || ! grep -q "^> done" "$commands.log"; then
    echo "The widgets didn't go on the Home Screen; see $commands.log and $work/remote-test.log." >&2
    exit 1
  fi
  xcrun simctl io "$udid" screenshot "$raw/$device/$name.png" > /dev/null 2>&1
  layout "$device" "$name" light "$line" "$smaller"
}

# check <device> <width> <height>: ten pictures, each the size the App Store asks for.
check() {
  local picture size count=0
  for picture in "$out/$1"/*.png; do
    size=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$picture" | awk '/pixel|hasAlpha/ { printf "%s ", $2 }')
    [ "$size" = "$2 $3 no " ] || { echo "$picture is ${size% }, not $2 x $3 without alpha." >&2; exit 1; }
    count=$((count + 1))
  done
  [ $count = 10 ] || { echo "$out/$1 has $count pictures, not 10." >&2; exit 1; }
}

notes="Every note a Markdown file in your iCloud Drive."
files="Right next to the PDFs and photos they go with."
todos="Dates, places and repeats, written in the note."
widget="New Note, today's to-dos, or a note you pick."
versions="Go back to an earlier one, changes marked."
# The steps that put Notebook's New Note and Today widgets on a new iPhone's Home Screen, in points. Home, twice, goes to
# its first page (the app just ran from the second); Apple's Maps widget and Calendar stack go first, so Notebook's
# are the only ones. The gallery's button is called " Add Widget".
iphone_widgets=("home" "wait 1.5" "home" "wait 2" "pressat 1.6 119 193" "wait 2" "tap Remove Widget" "wait 1.5" "tap Remove" "wait 3"
  "pressat 1.6 320 182" "wait 2" "tap Remove Stack" "wait 1.5" "tap Remove" "wait 3"
  "pressat 1.6 69 128" "wait 2" "tap Edit Home Screen" "wait 2"
  "tap Edit" "wait 1.5" "tap Add Widget" "wait 2.5" "tapcell Notebook" "wait 2.5" "swipe left" "wait 1.5" "swipe left"
  "wait 1.5" "tap  Add Widget" "wait 2.5"
  "tap Edit" "wait 1.5" "tap Add Widget" "wait 2.5" "tapcell Notebook" "wait 2.5" "tap  Add Widget" "wait 2.5"
  "tap Done" "wait 2")
# The same on a new 13-inch iPad, whose Home Screen starts with Apple's Calendar widget and News and Reminders stacks;
# Today is the large one there, the gallery's fourth page.
ipad_widgets=("home" "wait 1.5" "home" "wait 2" "pressat 1.6 317 538" "wait 2" "tap Remove Widget" "wait 1.5" "tap Remove" "wait 3"
  "pressat 1.6 715 240" "wait 2" "tap Remove Stack" "wait 1.5" "tap Remove" "wait 3"
  "pressat 1.6 317 244" "wait 2" "tap Remove Stack" "wait 1.5" "tap Remove" "wait 3"
  "pressat 1.6 188 138" "wait 2" "tap Edit Home Screen" "wait 2"
  "tap Edit" "wait 1.5" "tap Add Widget" "wait 2.5" "tapcell Notebook" "wait 2.5" "tap  Add Widget" "wait 2.5"
  "tap Edit" "wait 1.5" "tap Add Widget" "wait 2.5" "tapcell Notebook" "wait 2.5" "swipe left" "wait 1.2"
  "swipe left" "wait 1.2" "swipe left" "wait 1.5" "tap  Add Widget" "wait 2.5"
  "tap Done" "wait 2")

if [ "$only" != ipad ]; then
  echo "iPhone…"
  iphone=$(simulator "Notebook App Store iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max)
  mkdir -p "$out/iphone" "$raw/iphone"
  rm -f "$out/iphone"/*.png
  # Each scene waits a few seconds first, until the sample notes are read and their links found.
  shot "$iphone" iphone 01-note light "The ease of Notes." "$notes" "wait 6" "open Travel/Kyoto trip.md" "wait 3"
  # One folder per screen, as in the Files app: the notes among the trip's PDFs and photo.
  shot "$iphone" iphone 02-folder light "Your notes are files." "$files" "wait 6" "push Travel" "wait 3"
  # Writing, with the bar above the keyboard; scrolled back to the top, which the keyboard moved.
  shot "$iphone" iphone 03-writing light "Writes like Notes." "Checklists, links and photos from the bar." \
    "wait 6" "open Personal/Weekend.md" "wait 2" "focus end" "wait 3" "scroll 0" "wait 3"
  shot "$iphone" iphone 04-todos light "Every to-do in one list." "$todos" "wait 8" "showtodos" "wait 3"
  # Version History from the note's ⋯ menu, the iPhone's version from Sunday open, with its changes marked.
  shot "$iphone" iphone 06-versions light "Every version, kept." "$versions" "wait 6" "open Travel/Kyoto trip.md" \
    "wait 2" "browseversions" "wait 3" "pickversion 2" "wait 3" "showchanges 1" "wait 2"
  # Search, the keyboard put away: a few letters found in a name, in notes, in a PDF and in a photographed receipt.
  shot "$iphone" iphone 07-search light "Finds it from a few letters." "In names, notes, PDFs and pictures." \
    "wait 12" "search kyo" "wait 3" "resign" "wait 2"
  shot "$iphone" iphone 08-blocks dark "Tables, code and diagrams." "Drawn right in the note." \
    "wait 6" "open Projects/Notebook roadmap.md" "wait 3"
  shot "$iphone" iphone 09-drawing light "Draw right in the note." "Sketch a map or a thought with your finger." \
    "wait 6" "open Travel/Getting to the ryokan.md" "wait 3"
  # Further down the trip: links, a callout, a table and the flight tickets, a PDF in the note.
  shot "$iphone" iphone 10-objects light "Links, tables and PDFs in the note." "The PDF stays a file, right beside it." \
    "wait 6" "open Travel/Kyoto trip.md" "wait 3" "scroll 700" "wait 4"
  # Last, since it starts the Home Screen afresh.
  widgets "$iphone" iphone 05-widgets "Notes on your Home Screen." "$widget" "${iphone_widgets[@]}"
  check iphone 1320 2868
  xcrun simctl status_bar "$iphone" clear
  xcrun simctl shutdown "$iphone"
fi

if [ "$only" != iphone ]; then
  echo "iPad…"
  ipad=$(simulator "Notebook App Store iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)
  mkdir -p "$out/ipad" "$raw/ipad"
  rm -f "$out/ipad"/*.png
  # In portrait the note fills the screen; it shows its outline where it has headings.
  shot "$ipad" ipad 01-note light "The ease of Notes." "$notes" "wait 8" "open Travel/Kyoto trip.md" "outline" "wait 3"
  # The sidebar next to the note, the trip's folder open with its PDFs and photo among the notes.
  shot "$ipad" ipad 02-folder light "Your notes are files." "$files" "wait 8" "open Travel/Kyoto trip.md" "wait 2" \
    "sidebar" "wait 3"
  # Typing with a keyboard attached (and its shortcuts bar off), the caret right after a word just made bold, its marks
  # still showing. A simulator run without the Simulator app's window has no keyboard, so the debug remote stands in.
  shot "$ipad" ipad 03-typing light "Markdown that gets out of the way." "The marks fade as you type." \
    "wait 8" "keyboard on" "open Personal/Weekend.md" "wait 2" "focus end" "wait 0.5" "touchkeyboard hide" "wait 1" \
    "type \\n## Sunday" "wait 0.5" "key return" "type - [ ] A long walk by the **lake" "wait 0.5" "type **" "wait 2"
  shot "$ipad" ipad 04-todos light "Every to-do in one list." "$todos" "wait 10" "showtodos" "wait 3"
  shot "$ipad" ipad 06-versions light "Every version, kept." "$versions" "wait 8" "open Travel/Kyoto trip.md" \
    "wait 2" "browseversions" "wait 3" "pickversion 2" "wait 3" "showchanges 1" "wait 2"
  # ⌘K over the note, with a few letters typed and the keyboard put away.
  shot "$ipad" ipad 07-palette light "Finds it from a few letters." "⌘K searches everything and runs any command." \
    "wait 10" "open Travel/Kyoto trip.md" "wait 2" "palette" "wait 1" "palettetype kyo" "wait 2" "resign" "wait 2"
  shot "$ipad" ipad 08-math dark "Maths, as you write it." "LaTeX in dollar signs, drawn in the note." \
    "wait 8" "open University/Linear algebra/Week 3.md" "outline" "wait 3"
  # Drawing, with the system's tools at the bottom.
  shot "$ipad" ipad 09-drawing light "Draw right in the note." "With Apple Pencil, next to your words." \
    "wait 8" "open Travel/Getting to the ryokan.md" "wait 2" "drawing 0" "wait 3"
  shot "$ipad" ipad 10-blocks light "Tables, code and diagrams." "Drawn right in the note." \
    "wait 8" "open Projects/Notebook roadmap.md" "outline" "wait 3"
  widgets "$ipad" ipad 05-widgets "Notes on your Home Screen." "$widget" "${ipad_widgets[@]}"
  check ipad 2064 2752
  xcrun simctl status_bar "$ipad" clear
  xcrun simctl shutdown "$ipad"
fi

echo "Done: $out/iphone and $out/ipad. Look at every picture before committing them."
