#!/bin/bash
# Records the Mac App Store's app preview on the sample notes: 1920 x 1080, about 28 seconds, into
# build/app-store-media/previews/mac.mp4 (not checked in; Design/app-store.md says how it is uploaded).
#   Tools/mac-app-store-preview.sh
# Six scenes, each recorded on its own: a note opened from among the files of its folder, a to-do typed with its
# marks folding away, ⌘K, Browse All Versions, a to-do's date typed in To-dos, and a PDF in the window. The app runs
# under a bundle identifier of its own on a fresh copy of the sample notes (Files/DemoLibrary.swift), driven by its
# debug remote (Debug/DebugRemote.swift); its window is recorded with Tools/readme-images/capture.swift and the scenes
# are put together by Tools/app-store-media/preview.py. The app comes to the front for each scene, so its window is
# drawn active: this needs an awake, unlocked screen nobody is working at, and Screen Recording for the terminal.
# About two minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "Needs ffmpeg: brew install ffmpeg" >&2; exit 1; }

work=build/app-store-media/mac-preview
raw=$work/raw
library=$work/Notes
app=$work/DerivedData/Build/Products/Debug/Notebook.app
bundle_id=com.lukaskbl.Notebook.storepreview
out=build/app-store-media/previews/mac.mp4
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
mkdir -p "$raw" "$(dirname "$out")"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work/DerivedData" NOTEBOOK_BUNDLE_IDENTIFIER=$bundle_id build -quiet
swiftc -O Tools/readme-images/capture.swift -o "$work/capture" 2>/dev/null

# say <command>…: drives the app through its debug remote.
say() { for line in "$@"; do echo "$line" >> "$work/cmd"; done; }

rm -rf "${library:?}"
defaults delete $bundle_id 2>/dev/null || true
: > "$work/cmd"
rm -f "$work/cmd.log" "$raw"/*
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
say "window $width $height" "appearance light"

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

# scene <name> <seconds> <command>…: records the window for that long while the commands run, then takes a still of
# how the scene ends, whose traffic lights replace the badge macOS draws over them while recording.
scene() {
  local name=$1 seconds=$2
  shift 2
  front
  sleep 0.5
  "$work/capture" rec "$pid" "$raw/$name.mov" "$seconds" > "$work/rec.log" &
  local recorder=$!
  for _ in $(seq 40); do grep -q recording "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
  say "$@"
  wait $recorder
  "$work/capture" shot "$pid" "$raw/$name.png" > /dev/null
}

# typing: a to-do typed at the end of Weekend, a key at a time.
typing() {
  python3 - "$library/Personal/Weekend.md" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
end = len(text.encode("utf-16-le")) // 2
lines = [f"caret {end}", "showcaret 1", "wait 0.6"]
for ch in "\n\n## Sunday\n- [ ] A long walk by the **lake**, then ==coffee== at Mia's":
    lines.extend(["key return" if ch == "\n" else f"type {ch}", "wait 0.06"])
print("\n".join(lines))
EOF
}

echo "Recording…"
front
say "open Travel/Budget.md"
sleep 1.5
"$work/capture" shot "$pid" "$raw/window.png" > /dev/null
# The note among the PDFs and the photo of its folder, picked in the sidebar.
scene 1-open 4.5 "wait 1.2" "selectrow Kyoto trip"
say "open Personal/Weekend.md"
sleep 1
front
"$work/capture" rec "$pid" "$raw/2-typing.mov" 8 > "$work/rec.log" &
recorder=$!
for _ in $(seq 40); do grep -q recording "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
typing >> "$work/cmd"
wait $recorder
"$work/capture" shot "$pid" "$raw/2-typing.png" > /dev/null
say "showcaret 0"
# ⌘K finding "kyoto" in notes, the PDF and the receipt's picture.
scene 3-search 5 "wait 0.6" "palette" "wait 0.7" "type k" "wait 0.12" "type y" "wait 0.12" "type o" "wait 0.12" \
  "type t" "wait 0.12" "type o"
say "key escape"
# Browse All Versions…: the iPhone's version from Sunday, then Show Changes.
scene 4-versions 6 "open Travel/Kyoto trip.md" "wait 0.8" "browseversions" "wait 1.4" "pickversion 2" "wait 1.4" "showchanges 1"
say "closeversions"
# To-dos, the dry cleaning edited in place, a day typed into its date.
scene 5-todos 6 "showtodos" "wait 1" "edittodo end dry cleaning" "wait 1" "todopick date" "wait 0.8" \
  "todopicktype thursday in 3 weeks"
say "todopick none" "key escape"
scene 6-pdf 4 "open Personal/Weekend.md" "wait 1" "open Travel/Flight tickets.pdf"

echo "Editing…"
python3 Tools/app-store-media/preview.py "$out" mac light "$raw/window.png" "$raw/1-open.mov:0:4.3" \
  "$raw/2-typing.mov:0.2:8" "$raw/3-search.mov:0.3:5" "$raw/4-versions.mov:0.3:6" "$raw/5-todos.mov:0.4:6" \
  "$raw/6-pdf.mov:0.6:4"
echo "Done: $out. Watch it before using it."
