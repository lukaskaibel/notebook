#!/bin/bash
# Takes the README's pictures of the app on the sample notes and lays them out as Design/screenshots/*.webp and
# Design/social-preview.png.
#   Tools/readme-images.sh            all of them
#   Tools/readme-images.sh devices    only the iPhone and iPad picture, which needs no screen
# The Mac app runs in the background on a fresh copy of the sample notes (Debug/DemoLibrary.swift), under a bundle
# identifier of its own so your Notebook's settings stay as they are. It never comes to the front and leaves keyboard
# and mouse alone; only the search suggestions show on screen for a moment. The iPhone and iPad pictures come from two
# simulators of the script's own ("Notebook README iPhone" and "… iPad"), which run without the Simulator app's
# window.
# Takes about three minutes. Needs Screen Recording permission for the terminal, a Retina display, Python 3 with
# Pillow and NumPy, ffmpeg and img2webp (brew install ffmpeg webp), and the iOS Simulator runtime of Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

work=build/readme-images
raw=$work/raw
library=$work/Notes
app=$work/DerivedData/Build/Products/Debug/Notebook.app
bundle_id=com.lukaskbl.Notebook.readme

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
for tool in ffmpeg img2webp; do
  command -v $tool >/dev/null || { echo "Needs $tool: brew install ffmpeg webp" >&2; exit 1; }
done

only=${1:-}
mkdir -p "$raw"

# The Mac's scenes, left out with "devices". (Not indented: the typing scene's here-document must end at the
# start of a line.)
if [ "$only" != devices ]; then
echo "Building…"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work/DerivedData" PRODUCT_BUNDLE_IDENTIFIER=$bundle_id build -quiet
mkdir -p "$raw"
swiftc -O Tools/readme-images/capture.swift -o "$work/capture" 2>/dev/null

pid=""
finish() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}
trap finish EXIT

# say <command>…: drives the app through its debug remote (Debug/DebugRemote.swift).
say() { for line in "$@"; do echo "$line" >> "$work/cmd"; done; }

# shot <name>: the window, without anything in front of or behind it.
shot() { "$work/capture" shot "$pid" "$raw/$1.png" > /dev/null; }

launch() {
  # Fresh notes and settings every time: the typing scene changes a note, and the sidebar remembers what was open.
  rm -rf "${library:?}"
  defaults delete $bundle_id 2>/dev/null || true
  : > "$work/cmd"
  rm -f "$work/cmd.log"
  # Scroll bars only while scrolling, as with a trackpad, even when a mouse is connected.
  open -n -g "$app" --args -NotebookLibrary "$PWD/$library" -NotebookLibraryName "iCloud Drive" -NotebookDemo YES \
    -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO -AppleShowScrollBars WhenScrolling \
    -NotebookTips hide -debugCommandFile "$PWD/$work/cmd" "-NSWindow Frame main" "160 80 1280 820 0 0 1512 949"
  for _ in $(seq 40); do
    pid=$(pgrep -nf "$PWD/$app/Contents/MacOS" || true)
    [ -n "$pid" ] && break
    sleep 0.25
  done
  [ -n "$pid" ] || { echo "The app didn't start." >&2; exit 1; }
  for _ in $(seq 40); do
    say "open Travel/Kyoto trip.md" "dump"
    sleep 0.5
    grep -q "Kyoto trip.md" "$work/cmd.log" 2>/dev/null && return 0
  done
  echo "The app didn't open the sample notes." >&2
  exit 1
}

# typing <seconds>: the commands that type a few lines at the end of "Weekend", a key at a time.
typing() {
  python3 - "$library/Personal/Weekend.md" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
end = len(text.encode("utf-16-le")) // 2
lines = [f"caret {end}", "showcaret 1", "wait 0.8"]
def typed(s, delay=0.07):
    for ch in s:
        lines.extend(["key return" if ch == "\n" else f"type {ch}", f"wait {delay}"])
typed("\n\n## Sunday")
lines.append("wait 0.5")
typed("\n- [ ] A long walk by the **lake**")
lines.append("wait 0.6")
typed(", then ==coffee== at Mia's")
print("\n".join(lines))
EOF
}

for theme in dark light; do
  echo "Scenes in ${theme}…"
  launch
  say "appearance $theme"
  sleep 1.5
  shot "note-$theme"

  say "open Projects/Notebook roadmap.md"; sleep 1.5; shot "blocks-$theme"
  say "open University/Linear algebra/Week 3.md"; sleep 1.5; shot "math-$theme"
  say "open Travel/Flight tickets.pdf"; sleep 2; shot "quicklook-$theme"
  # Further down the trip: the plan with its link, the callout, the table and the embedded PDF.
  say "open Travel/Kyoto trip.md"; sleep 1.2; say "scroll 640"; sleep 1; shot "objects-$theme"
  # Drawing in a note: the way to the ryokan, open for drawing, with the palette at the bottom.
  say "open Travel/Getting to the ryokan.md" "wait 1" "drawing 0"; sleep 2; shot "drawing-$theme"; say "drawing end"
  # The questions for the doctor, with Remind Me… open under the title, where the sample reminder's bell is, and a
  # day typed in its field.
  say "open Personal/Questions for Dr. Weber.md"; sleep 1.2
  say "remindme Personal/Questions for Dr. Weber.md"; sleep 1.2
  say "remindtype fri"; sleep 1; shot "reminder-$theme"
  say "remindme close"; sleep 0.5
  # Customize Folder… open from Travel in the sidebar, with the symbols suggested for its name; the other sample
  # folders with a look of their own around it. Travel is far enough down for the popover to fit in the window.
  say "customize Travel"; sleep 1.5; shot "customize-$theme"
  say "customize close"; sleep 0.5
  # To-dos: every open to-do of the sample notes, by when it's due.
  say "showtodos"; sleep 1.5; shot "todos-$theme"
  # The dry cleaning edited in place: the line for notes, its points, and the capsules for its day, time and place
  # under them, with the day's dropdown open below them and a day typed in it.
  say "edittodo end dry cleaning"; sleep 1.5
  say "todopick date"; sleep 1; say "todopicktype thursday in 3 weeks"; sleep 2; shot "todo-editing-$theme"
  say "todopick none"; sleep 0.5; say "key escape"; sleep 0.8
  # The pills after the errands' to-dos, and Remind Me for the one at a place, from its pill, once the map has loaded.
  say "open Inbox/Errands.md"; sleep 1.2
  say "remindtodo plasters"; sleep 3; shot "todo-reminder-$theme"
  say "remindme close"; sleep 0.5

  say "open Personal/Weekend.md"; sleep 1.5
  rm -f "$raw/typing-$theme.mov"
  "$work/capture" rec "$pid" "$raw/typing-$theme.mov" 11 > "$work/rec.log" &
  recorder=$!
  for _ in $(seq 40); do grep -q recording "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
  typing >> "$work/cmd"
  wait $recorder
  say "showcaret 0"

  # ⌘K with nothing typed yet: what was opened last, then what can be done with the note that is open.
  say "open Travel/Kyoto trip.md" "wait 1" "palette"; sleep 1.5; shot "palette-$theme"
  say "key escape"; sleep 0.5

  # Last, since the suggestions menu shows on screen even though the app is in the background. The reading of the
  # pictures has had time by now, so the receipt in Budget is found too.
  say "searchfocus" "wait 0.4" "type kyoto"; sleep 2
  "$work/capture" all "$pid" "$raw/search-$theme.png" > "$raw/search-$theme.txt"
  say "key escape"

  kill "$pid"
  pid=""
  sleep 1
done
fi

echo "Building for iPhone and iPad…"
ios_app=$work/DerivedData-iOS/Build/Products/Debug-iphonesimulator/Notebook.app
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/DerivedData-iOS" PRODUCT_BUNDLE_IDENTIFIER=$bundle_id build -quiet

# simulator <name> <device type>: a simulator of the script's own, made the first time and booted, by its UDID.
simulator() {
  local udid runtime
  udid=$(xcrun simctl list devices available -j | python3 -c "import json, sys
devices = json.load(sys.stdin)['devices'].values()
print(next((d['udid'] for group in devices for d in group if d['name'] == '$1'), ''))")
  if [ -z "$udid" ]; then
    runtime=$(xcrun simctl list runtimes available -j | python3 -c "import json, sys
runtimes = [r for r in json.load(sys.stdin)['runtimes'] if r['platform'] == 'iOS']
print(max(runtimes, key=lambda r: [int(n) for n in r['version'].split('.')])['identifier'])")
    udid=$(xcrun simctl create "$1" "$2" "$runtime")
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  echo "$udid"
}

# device <udid> <name> <theme> <commands>…: a fresh install on the sample notes, driven by its debug remote
# (Debug/DebugRemote+UIKit.swift), then a screenshot.
device() {
  local udid=$1 name=$2 theme=$3 container
  shift 3
  xcrun simctl ui "$udid" appearance "$theme"
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl uninstall "$udid" $bundle_id 2>/dev/null || true
  xcrun simctl install "$udid" "$ios_app"
  container=$(xcrun simctl get_app_container "$udid" $bundle_id data)
  mkdir -p "$container/Documents"
  : > "$container/Documents/cmd"
  for line in "$@"; do echo "$line" >> "$container/Documents/cmd"; done
  xcrun simctl launch "$udid" $bundle_id -NotebookLibrary "~/Documents/Notes" -NotebookLibraryName "iCloud Drive" -NotebookDemo YES \
    -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO -debugCommandFile "~/Documents/cmd" > /dev/null
  for _ in $(seq 60); do
    grep -q "^> done" "$container/Documents/cmd.log" 2>/dev/null && break
    sleep 0.5
  done
  sleep 1
  xcrun simctl io "$udid" screenshot "$raw/$name-$theme.png" > /dev/null 2>&1
  xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
}

echo "iPhone and iPad…"
iphone=$(simulator "Notebook README iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
ipad=$(simulator "Notebook README iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)
for theme in dark light; do
  device "$iphone" iphone $theme "wait 2" "open Travel/Kyoto trip.md" "wait 2.5" "done"
  device "$ipad" ipad $theme "wait 2" "open Travel/Kyoto trip.md" "outline" "wait 2.5" "done"
done
xcrun simctl shutdown "$iphone" "$ipad" 2>/dev/null || true

if [ "$only" != devices ]; then
  size=$(sips -g pixelWidth -g pixelHeight "$raw/note-dark.png" | awk '/pixel/ { printf "%s ", $2 }')
  if [ "$size" != "2560 1640 " ]; then
    echo "The window came out ${size% }px; the layout expects 1280 x 820 points on a Retina display." >&2
    exit 1
  fi
fi

echo "Laying out…"
python3 Tools/readme-images/build.py "$raw" $only
echo "Done. Check the images, then commit them with the change they show."
