#!/bin/bash
# Takes the App Store screenshots of the iPhone and iPad app on the sample notes: a 6.9-inch iPhone (1320 x 2868) and
# a 13-inch iPad (2064 x 2752), mostly light and one dark each, with a clean status bar. They end up in
# Design/screenshots/app-store/{iphone,ipad}.
#   Tools/app-store-screenshots.sh
# Builds a Debug copy under a bundle identifier of its own and installs it afresh for every picture, on simulators of
# the script's own (made the first time, on iOS 27.0, which has the iPhone 17 Pro Max), each time on new sample notes
# (Files/DemoLibrary.swift). The scene is set up through the debug remote (Debug/DebugRemote+UIKit.swift), as in
# Tools/readme-images.sh, and taken with `simctl io screenshot`. Runs in the background; about ten minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import PIL" 2>/dev/null || { echo "Needs Pillow: pip3 install pillow" >&2; exit 1; }

work=build/app-store-screenshots/ios
out=Design/screenshots/app-store
app=$work/DerivedData/Build/Products/Debug-iphonesimulator/Notebook.app
bundle_id=com.lukaskbl.Notebook.screenshots
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0

xcrun simctl list runtimes available | grep -q "iOS 27.0 " || {
  echo "No iOS 27.0 simulator runtime. Install it in Xcode › Settings › Components." >&2
  exit 1
}

echo "Building…"
mkdir -p "$work"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/DerivedData" PRODUCT_BUNDLE_IDENTIFIER=$bundle_id build -quiet

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

# shot <udid> <folder> <name> <theme> <command>…: a fresh install on new sample notes, the scene set up by the debug
# remote, then a screenshot as <folder>/<name>.png.
shot() {
  local udid=$1 folder=$2 name=$3 theme=$4 container
  shift 4
  xcrun simctl ui "$udid" appearance "$theme"
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl uninstall "$udid" $bundle_id 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
  container=$(xcrun simctl get_app_container "$udid" $bundle_id data)
  mkdir -p "$container/Documents"
  : > "$container/Documents/cmd"
  for line in "$@" "done"; do echo "$line" >> "$container/Documents/cmd"; done
  xcrun simctl launch "$udid" $bundle_id -NotebookLibrary "~/Documents/Notes" -NotebookLibraryName "iCloud Drive" \
    -NotebookDemo YES -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO \
    -debugCommandFile "~/Documents/cmd" > /dev/null
  for _ in $(seq 120); do
    grep -q "^> done" "$container/Documents/cmd.log" 2>/dev/null && break
    sleep 0.5
  done
  grep -q "^> done" "$container/Documents/cmd.log" 2>/dev/null || { echo "The scene $name didn't finish." >&2; exit 1; }
  sleep 1
  xcrun simctl io "$udid" screenshot "$out/$folder/$name.png" > /dev/null 2>&1
  xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
  # The App Store takes no pictures with an alpha channel, which the simulator's have.
  python3 -c "import sys; from PIL import Image; Image.open(sys.argv[1]).convert('RGB').save(sys.argv[1])" "$out/$folder/$name.png"
  echo "$out/$folder/$name.png"
}

# check <folder> <width> <height>: every picture in the folder has the size the App Store asks for.
check() {
  local picture size
  for picture in "$out/$1"/*.png; do
    size=$(sips -g pixelWidth -g pixelHeight "$picture" | awk '/pixel/ { printf "%s ", $2 }')
    [ "$size" = "$2 $3 " ] || { echo "$picture is ${size% }px, not $2 x $3." >&2; exit 1; }
  done
}

echo "iPhone…"
iphone=$(simulator "Notebook App Store iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max)
mkdir -p "$out/iphone"
rm -f "$out/iphone"/*.png
# Each scene waits a few seconds first, until the sample notes are read and their links found.
shot "$iphone" iphone 1-note light "wait 6" "open Travel/Kyoto trip.md" "wait 3"
# Writing, with the bar above the keyboard; scrolled back to the top, which the keyboard moved.
shot "$iphone" iphone 2-writing light "wait 6" "open Personal/Weekend.md" "wait 2" "focus end" "wait 3" "scroll 0" "wait 3"
# No search here: the keyboard covers the results, and what it finds in pictures depends on how far reading has got.
# The Mac's pictures show search.
shot "$iphone" iphone 3-todos light "wait 8" "showtodos" "wait 3"
shot "$iphone" iphone 4-drawing light "wait 6" "open Travel/Getting to the ryokan.md" "wait 3"
# One folder per screen, as in the Files app.
shot "$iphone" iphone 5-folder light "wait 6" "push Travel" "wait 3"
shot "$iphone" iphone 6-blocks dark "wait 6" "open Projects/Notebook roadmap.md" "wait 3"
check iphone 1320 2868
xcrun simctl status_bar "$iphone" clear

echo "iPad…"
ipad=$(simulator "Notebook App Store iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)
mkdir -p "$out/ipad"
rm -f "$out/ipad"/*.png
# In portrait the sidebar comes over the note, so these show the note, with its outline where it has headings.
shot "$ipad" ipad 1-note light "wait 8" "open Travel/Kyoto trip.md" "outline" "wait 3"
shot "$ipad" ipad 2-blocks light "wait 8" "open Projects/Notebook roadmap.md" "outline" "wait 3"
shot "$ipad" ipad 3-todos light "wait 10" "showtodos" "wait 3"
# Drawing, with the system's tools at the bottom.
shot "$ipad" ipad 4-drawing light "wait 8" "open Travel/Getting to the ryokan.md" "wait 2" "drawing 0" "wait 3"
shot "$ipad" ipad 5-math dark "wait 8" "open University/Linear algebra/Week 3.md" "outline" "wait 3"
check ipad 2064 2752
xcrun simctl status_bar "$ipad" clear

xcrun simctl shutdown "$iphone" "$ipad" 2>/dev/null || true
echo "Done: $out/iphone and $out/ipad. Look at every picture before committing them."
