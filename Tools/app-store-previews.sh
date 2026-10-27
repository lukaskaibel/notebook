#!/bin/bash
# Records the App Store app previews of the iPhone and iPad app on the sample notes: 886 x 1920 for the 6.9-inch
# iPhone and 1200 x 1600 for the 13-inch iPad, 25 to 28 seconds each, in build/app-store-media/previews.
#   Tools/app-store-previews.sh            both
#   Tools/app-store-previews.sh iphone     one of them
# Each preview is one session of the app on new sample notes (Files/DemoLibrary.swift), driven through its debug
# remote (Debug/DebugRemote+UIKit.swift) and recorded with `simctl io recordVideo`. The script keeps the time of each
# scene it plays, and Tools/app-store-media/preview.py cuts those scenes out and joins them with short cross-fades,
# at the store's size, with the silent sound track App Store Connect requires. Only the app's own screen is in them,
# as App Review asks of previews. Uses the build and the simulators of Tools/app-store-screenshots.sh, one at a time.
# Runs in the background; about five minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import PIL" 2>/dev/null || { echo "Needs Pillow: pip3 install pillow" >&2; exit 1; }

only=${1:-}
build=build/app-store-screenshots/ios
work=build/app-store-previews
out=build/app-store-media/previews
app=$build/DerivedData/Build/Products/Debug-iphonesimulator/Notebook.app
bundle_id=com.lukaskbl.Notebook.screenshots
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0

echo "Building…"
mkdir -p "$work" "$out"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$build/DerivedData" NOTEBOOK_BUNDLE_IDENTIFIER=$bundle_id ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build -quiet

# simulator <name> <device type>: the screenshot script's simulator, made the first time and booted, by its UDID.
simulator() {
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c "import json, sys
devices = json.load(sys.stdin)['devices'].get('$runtime', [])
print(next((d['udid'] for d in devices if d['name'] == '$1'), ''))")
  [ -n "$udid" ] || udid=$(xcrun simctl create "$1" "$2" "$runtime")
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  if [ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null)" != en_US ]; then
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b > /dev/null
  fi
  xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
  echo "$udid"
}

now() { python3 -c "import time; print(f'{time.time():.3f}')"; }

# On the way out, also when a step fails: no recording left running, and the simulator with its own status bar again
# and shut down.
udid="" recorder=""
finish() {
  if [ -n "$recorder" ]; then
    kill -INT "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true
  fi
  if [ -n "$udid" ]; then
    xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
    xcrun simctl status_bar "$udid" clear 2>/dev/null || true
    xcrun simctl shutdown "$udid" 2>/dev/null || true
  fi
}
trap finish EXIT

# session <udid> <name>: the app installed afresh on new sample notes, in light, with a clean status bar, waiting
# for commands; then the recording starts.
session() {
  udid=$1 name=$2
  video=$work/$name.mp4
  clips=()
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl uninstall "$udid" $bundle_id 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
  container=$(xcrun simctl get_app_container "$udid" $bundle_id data)
  mkdir -p "$container/Documents"
  : > "$container/Documents/cmd"
  rm -f "$container/Documents/cmd.log"
  xcrun simctl launch "$udid" $bundle_id -NotebookLibrary "~/Documents/Notes" -NotebookLibraryName "iCloud Drive" \
    -NotebookDemo YES -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO \
    -debugCommandFile "~/Documents/cmd" > /dev/null
  # Until the sample notes are made, read and their links found.
  sleep 8
}

# say <command>…: drives the app, at once.
say() { for line in "$@"; do echo "$line" >> "$container/Documents/cmd"; done; }

# typed <text>: types it a key at a time, as a person would (\n for Return).
typed() {
  local text=$1 i ch
  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    if [ "$ch" = $'\n' ]; then say "key return"; else say "type $ch"; fi
    sleep 0.08
  done
}

# record <command>…: starts recording, then gives the commands. The simulator writes a frame only when the screen
# changes, so the recording begins with what they set moving, and its times count from them.
record() {
  rm -f "$video"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$video" 2> "$work/rec.log" &
  recorder=$!
  for _ in $(seq 50); do grep -q "Recording started" "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
  say "$@"
  start=$(now)
}

# from / to: the start and end of a scene to keep, in the recording's time.
from() { clip_start=$(python3 -c "print(f'{$(now) - $start:.2f}')"); }
to() { clips+=("$video:$clip_start:$(python3 -c "print(f'{$(now) - $start:.2f}')")"); }

# stop <command>…: one more change on screen after the last scene, so the recording has a frame after it and the
# scene keeps its length; then the end.
stop() {
  say "$@"
  sleep 0.8
  kill -INT "$recorder"
  wait "$recorder" 2>/dev/null || true
  recorder=""
  xcrun simctl terminate "$udid" $bundle_id 2>/dev/null || true
  xcrun simctl status_bar "$udid" clear
}

if [ "$only" != ipad ]; then
  echo "iPhone…"
  session "$(simulator "Notebook App Store iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max)" iphone
  # The trip's folder, its notes among a PDF and a photo; the trip's note opens.
  record "push Travel"
  from; sleep 2.5; say "open Travel/Kyoto trip.md"; sleep 5.5; to
  # Writing at the end of a note, with the bar above the keyboard: a checklist and two to-dos.
  say "open Personal/Weekend.md"; sleep 1.2
  from; say "focus end"; sleep 1.6; say "key return" "format checklist"; sleep 0.6
  typed "Flowers for Mia"; sleep 0.5; say "key return"; typed "Call the ryokan"; sleep 1.8; to
  # To-dos: the first one ticked; it shows ticked for a moment, then goes.
  say "blur" "showtodos"; sleep 1.5
  from; sleep 1.5; say "ticktodo Return the library books"; sleep 4; to
  # Search: a few letters, found in names, notes, a PDF and a photographed receipt.
  say "home"; sleep 1
  from; for query in k ky kyo; do say "search $query"; sleep 0.35; done; sleep 1; say "resign"; sleep 4; to
  stop "endsearch"
  python3 Tools/app-store-media/preview.py "$out/iphone.mp4" iphone "${clips[@]}"
  xcrun simctl shutdown "$udid"
fi

if [ "$only" != iphone ]; then
  echo "iPad…"
  session "$(simulator "Notebook App Store iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)" ipad
  say "open Travel/Kyoto trip.md"
  sleep 2
  # The trip's note, and the sidebar coming in with its folder: notes, PDFs and a photo side by side.
  record "sidebar"
  from; sleep 4; to
  # Typing with a keyboard attached (and its shortcuts bar off): the marks show while you type and fold away.
  say "sidebar hide" "keyboard on" "open Personal/Weekend.md"; sleep 1.2; say "focus end" "touchkeyboard hide"; sleep 1
  from; sleep 0.5; typed $'\n## Sunday\n- [ ] A long walk by the **lake**, then ==coffee=='; sleep 1.5; to
  # Drawing in the note: a sun over the way to the ryokan, a stroke at a time, in the drawing's empty corner.
  say "blur" "touchkeyboard show" "keyboard auto" "open Travel/Getting to the ryokan.md"; sleep 1.5
  say "drawing 0"; sleep 1.5
  from; sleep 0.8
  python3 -c "
from math import cos, sin, pi
cx, cy = 600, 52
ring = [(cx + 22 * cos(2 * pi * k / 12), cy + 22 * sin(2 * pi * k / 12)) for k in range(13)]
for a, b in zip(ring, ring[1:]):
    print(f'drawstroke {a[0]:.0f} {a[1]:.0f} {b[0]:.0f} {b[1]:.0f}')
for k in range(6):
    t = 2 * pi * k / 6 + pi / 6
    print(f'drawstroke {cx + 31 * cos(t):.0f} {cy + 31 * sin(t):.0f} {cx + 42 * cos(t):.0f} {cy + 42 * sin(t):.0f}')
" | while read -r line; do say "$line"; sleep 0.07; done
  sleep 1.8; to
  # Maths, as it is written.
  say "drawing end" "open University/Linear algebra/Week 3.md"; sleep 1.5
  from; sleep 2.8; to
  # Version History: Sunday's version from the iPhone, with what changed since marked.
  say "open Travel/Kyoto trip.md"; sleep 1.2
  from; say "browseversions"; sleep 1.6; say "pickversion 2"; sleep 1.2; say "showchanges 1"; sleep 2.2; to
  # To-dos, every open checkbox of every note.
  say "closeversions" "showtodos"; sleep 1.5
  from; sleep 3; to
  stop "sidebar"
  python3 Tools/app-store-media/preview.py "$out/ipad.mp4" ipad "${clips[@]}"
  xcrun simctl shutdown "$udid"
fi

echo "Done: $out. Watch them before uploading."
