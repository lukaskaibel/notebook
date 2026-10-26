#!/bin/bash
# Takes the Mac App Store screenshots on the sample notes, 2880 x 1800, into Design/screenshots/app-store/mac.
#   Tools/mac-app-store-screenshots.sh
# Builds a Debug copy under a bundle identifier of its own, so it shares no settings with a Notebook you have running,
# runs it on a fresh copy of the sample notes (Files/DemoLibrary.swift) and drives it through its debug remote
# (Debug/DebugRemote.swift), as Tools/readme-images.sh does. Each window is taken as it is on screen with
# Tools/readme-images/capture.swift and framed on the README pictures' backdrop by Tools/store-frame.py. The app comes
# to the front for each picture, so its window is drawn active, with coloured traffic lights: this needs an awake,
# unlocked screen and Screen Recording for the terminal, and takes about two minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }

work=build/app-store-screenshots/mac
out=Design/screenshots/app-store/mac
library=$work/Notes
app=$work/DerivedData/Build/Products/Debug/Notebook.app
bundle_id=com.lukaskbl.Notebook.screenshots
# The window in points; on a Retina display twice that in pixels, with room around it in 2880 x 1800.
width=1240
height=780

pid=""
previous=$(lsappinfo info -only bundlepath "$(lsappinfo front)" | sed -nE 's/.*"(.+)".*/\1/p')
finish() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  defaults delete $bundle_id 2>/dev/null || true
  # Gives the front back to the app that had it.
  [ -n "$previous" ] && open -a "$previous" 2>/dev/null || true
}
trap finish EXIT

echo "Building…"
mkdir -p "$work"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work/DerivedData" NOTEBOOK_BUNDLE_IDENTIFIER=$bundle_id build -quiet
swiftc -O Tools/readme-images/capture.swift -o "$work/capture" 2>/dev/null

# say <command>…: drives the app through its debug remote.
say() { for line in "$@"; do echo "$line" >> "$work/cmd"; done; }

rm -rf "${library:?}"
defaults delete $bundle_id 2>/dev/null || true
: > "$work/cmd"
rm -f "$work/cmd.log"
open -n -g "$app" --args -NotebookLibrary "$PWD/$library" -NotebookLibraryName "iCloud Drive" -NotebookDemo YES \
  -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO -AppleShowScrollBars WhenScrolling \
  -NotebookTips hide -debugCommandFile "$PWD/$work/cmd" "-NSWindow Frame main" "120 60 $width $height 0 0 1512 949"
for _ in $(seq 40); do
  pid=$(pgrep -nf "$PWD/$app/Contents/MacOS" || true)
  [ -n "$pid" ] && break
  sleep 0.25
done
[ -n "$pid" ] || { echo "The app didn't start." >&2; exit 1; }
for _ in $(seq 40); do
  say "open Travel/Kyoto trip.md" "dump"
  sleep 0.5
  grep -q "Kyoto trip.md" "$work/cmd.log" 2>/dev/null && break
done
grep -q "Kyoto trip.md" "$work/cmd.log" 2>/dev/null || { echo "The app didn't open the sample notes." >&2; exit 1; }
say "window $width $height"

# front: brings the app to the front, so its window is drawn as the active one.
front() {
  for _ in $(seq 10); do
    [ "$(lsappinfo info -only pid "$(lsappinfo front)" | sed -nE 's/.*pid ?= ?([0-9]+).*/\1/p')" = "$pid" ] && return 0
    open "$app"
    sleep 0.5
  done
  echo "The app doesn't come to the front. Is the screen locked?" >&2
  exit 1
}

# active <picture>: whether the window was drawn as the active one: the close button's red is in its top left corner,
# and nothing else red is.
active() {
  python3 - "$1" <<'EOF'
import sys
import numpy as np
from PIL import Image
corner = np.asarray(Image.open(sys.argv[1]).convert("RGB").crop((0, 0, 140, 140))).astype(int)
red = ((corner[..., 0] > 180) & (corner[..., 1] < 140) & (corner[..., 2] < 140)).sum()
sys.exit(0 if red > 80 else 1)
EOF
}

# shot <name> <theme> <command>…: sets the scene up in front, lets it settle, and takes and frames the window.
shot() {
  local name=$1 theme=$2
  shift 2
  front
  say "appearance $theme"
  for command in "$@"; do say "$command"; sleep 0.6; done
  sleep 1.5
  front
  sleep 0.8
  local tries
  for tries in 1 2 3 4; do
    "$work/capture" shot "$pid" "$work/$name.png" > /dev/null || { echo "No picture of $name. Is the screen asleep?" >&2; exit 1; }
    active "$work/$name.png" && break
    # Drawn inactive, with grey traffic lights, as when a panel such as ⌘K took the keyboard: asking the app to come
    # forward again makes the window the active one.
    [ "$tries" = 4 ] && { echo "The window stayed inactive for $name." >&2; exit 1; }
    open "$app"
    sleep 1
  done
  local size
  size=$(sips -g pixelWidth -g pixelHeight "$work/$name.png" | awk '/pixel/ { printf "%s ", $2 }')
  if [ "$size" != "$((width * 2)) $((height * 2)) " ]; then
    echo "$name came out ${size% }px, not $((width * 2)) x $((height * 2)): is the window on a Retina display?" >&2
    exit 1
  fi
  python3 Tools/store-frame.py "$work/$name.png" "$work/framed/$name.png" "$theme"
  echo "$out/$name.png"
}

echo "Taking screenshots…"
# Framed in the work folder and moved over the old pictures only once every one is taken, so a run that stops (a
# locked screen, say) leaves the old ones.
mkdir -p "$work/framed"
# The order is the store's: the note first, then what it holds, finding, to-dos, drawing and folders.
shot 1-note light "open Travel/Kyoto trip.md"
shot 2-blocks dark "open Projects/Notebook roadmap.md"
shot 3-todos light "showtodos"
shot 4-drawing light "open Travel/Getting to the ryokan.md" "wait 1" "drawing 0"
say "drawing end"
# Customize Folder… from Travel, with the symbols suggested for its name, over a note of words only: the popover's
# glass shows what is behind it.
shot 5-folders light "open Personal/Weekend.md" "wait 1" "customize Travel"
say "customize close"
# ⌘K finding a word in notes and PDFs, in the middle of the window (the search field's menu reaches past its edge).
shot 6-search light "open Personal/Weekend.md" "wait 1" "palette" "wait 0.6" "type kyoto" "wait 1.5"
say "key escape"
mkdir -p "$out"
rm -f "$out"/*.png
mv "$work/framed"/*.png "$out"/
echo "Done: $out. Look at every picture before committing them."
