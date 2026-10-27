#!/bin/bash
# Takes the Mac App Store screenshots on the sample notes, 2880 x 1800, into Design/screenshots/app-store/mac: ten
# slots, each a caption line and a smaller one above the window.
#   Tools/mac-app-store-screenshots.sh
# Builds a Debug copy under a bundle identifier of its own, so it shares no settings with a Notebook you have running,
# runs it on a fresh copy of the sample notes (Files/DemoLibrary.swift) and drives it through its debug remote
# (Debug/DebugRemote.swift), as Tools/readme-images.sh does. Each window is taken as it is on screen with
# Tools/readme-images/capture.swift and laid out with its caption by Tools/app-store-media/caption.py. The app comes
# to the front for each picture, so its window is drawn active, with coloured traffic lights: this needs an awake,
# unlocked screen nobody is working at, and Screen Recording for the terminal, and takes about three minutes.
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

# shot <name> <theme> <caption> <smaller line> <command>…: sets the scene up in front, lets it settle, takes the
# window and lays it out with its caption.
shot() {
  local name=$1 theme=$2 line=$3 smaller=$4
  shift 4
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
  python3 Tools/app-store-media/caption.py "$work/$name.png" "$work/framed/$name.png" mac "$theme" "$line" "$smaller"
  echo "$out/$name.png"
}

# typing: the commands that type a to-do at the end of Weekend, a key at a time, and put the caret back inside the bold
# word, where its marks show.
typing() {
  python3 - "$library/Personal/Weekend.md" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
end = len(text.encode("utf-16-le")) // 2
typed = "\n\n## Sunday\n- [ ] A long walk by the **lake**, then ==coffee== at Mia's"
lines = [f"caret {end}"]
for ch in typed:
    lines.extend(["key return" if ch == "\n" else f"type {ch}", "wait 0.03"])
# The caret after "la" of lake: the end, less what follows it in the typed line.
after = typed[typed.index("**lake**") + 4:]
lines.append(f"caret {end + len(typed) - len(after)}")
print("\n".join(lines))
EOF
}

echo "Taking screenshots…"
# Framed in the work folder and moved over the old pictures only once every one is taken, so a run that stops (a
# locked screen, say) leaves the old ones.
mkdir -p "$work/framed"
# The order is the store's: the note, its folders and how it writes, then to-dos, reminders, versions, search, what a
# note holds, and a PDF in the window. Two digits, since fastlane takes them in the order of their names.
shot 01-note light "The ease of Notes." "Every note a Markdown file in your iCloud Drive." "open Travel/Kyoto trip.md"
# Customize Folder… from Travel, with the symbols suggested for its name, over a note of words only: the popover's
# glass shows what is behind it.
shot 02-folders light "Your folders, as they are." "With symbols and colours the Finder shows too." \
  "open Personal/Weekend.md" "wait 1" "customize Travel"
say "customize close"
# A line typed at the end of Weekend, the caret back inside the bold word, so its marks show.
front
say "open Personal/Weekend.md"
sleep 1
typing >> "$work/cmd"
sleep 7
shot 03-typing light "Markdown that gets out of the way." "The marks show only where you are writing." "showcaret 1"
say "showcaret 0"
# To-dos, the dry cleaning edited in place, with a day typed into its date.
shot 04-todos light "Every to-do in one list." "Type “thursday in 3 weeks”, and it’s a date." \
  "showtodos" "wait 1" "edittodo end dry cleaning" "wait 1" "todopick date" "wait 0.6" "todopicktype thursday in 3 weeks" "wait 1.5"
say "todopick none" "key escape"
# Remind Me for the to-do at a place, from its pill, once the map has loaded.
shot 05-reminders light "Reminders, right in the note." "At a time you type, or when you get somewhere." \
  "open Inbox/Errands.md" "wait 1" "remindtodo plasters" "wait 3"
say "remindme close"
# Browse All Versions… over the Kyoto trip, the iPhone's version from Sunday picked, Show Changes on.
shot 06-versions light "Every version, kept." "Go back to any earlier version, with the changes marked." \
  "open Travel/Kyoto trip.md" "wait 1" "browseversions" "wait 1" "pickversion 2" "wait 1" "showchanges 1" "wait 1"
say "closeversions"
# ⌘K finding a word in notes and PDFs, in the middle of the window (the search field's menu reaches past its edge).
shot 07-search light "Finds it from a few letters." "⌘K searches notes, PDFs and pictures, and runs any command." \
  "open Personal/Weekend.md" "wait 1" "palette" "wait 0.6" "type kyoto" "wait 1.5"
say "key escape"
shot 08-blocks dark "Tables, code, maths, diagrams." "Drawn right in the note." "open Projects/Notebook roadmap.md"
shot 09-drawing light "Draw right in the note." "With the trackpad or the mouse, next to your words." \
  "open Travel/Getting to the ryokan.md" "wait 1" "drawing 0"
say "drawing end"
shot 10-pdf light "PDFs and pictures, in the window." "Everything else opens in Quick Look." "open Travel/Flight tickets.pdf" "wait 1"
mkdir -p "$out"
rm -f "$out"/*.png
mv "$work/framed"/*.png "$out"/
echo "Done: $out. Look at every picture before committing them."
