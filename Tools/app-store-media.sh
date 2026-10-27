#!/bin/bash
# Makes the App Store's creative assets of iOS 27 on the sample notes: the product page header (a note being typed,
# its Markdown marks folding away) and the search result (Kyoto trip.md among the files of its folder, opening into
# the note), each as a still and a looping video, into Design/screenshots/app-store/creative.
#   Tools/app-store-media.sh            both
#   Tools/app-store-media.sh header     or search: one of them
# The Mac app runs in the background on a fresh copy of the sample notes (Files/DemoLibrary.swift), under a bundle
# identifier of its own, at a large text size, driven by its debug remote (Debug/DebugRemote.swift). It never comes
# to the front; its window is captured with Tools/readme-images/capture.swift and laid out by
# Tools/app-store-media/creative.py. Needs an awake screen, Screen Recording for the terminal, a Retina display,
# Python 3 with Pillow and NumPy, and ffmpeg. About five minutes, most of it laying out the search video.
set -euo pipefail
cd "$(dirname "$0")/.."

work=build/app-store-media
raw=$work/raw
library=$work/Notes
app=$work/DerivedData/Build/Products/Debug/Notebook.app
bundle_id=com.lukaskbl.Notebook.storemedia
stills=Design/screenshots/app-store/creative
only=${1:-}

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "Needs ffmpeg: brew install ffmpeg" >&2; exit 1; }

echo "Building…"
mkdir -p "$raw/thumbs"
xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work/DerivedData" NOTEBOOK_BUNDLE_IDENTIFIER=$bundle_id build -quiet
swiftc -O Tools/readme-images/capture.swift -o "$work/capture" 2>/dev/null

pid=""
finish() { [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; defaults delete $bundle_id 2>/dev/null || true; }
trap finish EXIT

# say <command>…: drives the app through its debug remote.
say() { for line in "$@"; do echo "$line" >> "$work/cmd"; done; }

# launch: the app on fresh sample notes and settings, in the background, dark, its window 1400 x 880 points.
launch() {
  rm -rf "${library:?}"
  defaults delete $bundle_id 2>/dev/null || true
  : > "$work/cmd"
  rm -f "$work/cmd.log"
  open -n -g "$app" --args -NotebookLibrary "$PWD/$library" -NotebookLibraryName "iCloud Drive" -NotebookDemo YES \
    -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO -AppleShowScrollBars WhenScrolling \
    -NotebookTips hide -debugCommandFile "$PWD/$work/cmd" "-NSWindow Frame main" "40 40 1400 880 0 0 1512 949"
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
  say "appearance dark" "window 1400 880"
  sleep 1
}

quit() { kill "$pid"; pid=""; sleep 1; }

# shot <name>: the window as it is, with its corners.
shot() { "$work/capture" shot "$pid" "$raw/$1.png" > /dev/null || { echo "No picture of $1. Is the screen asleep?" >&2; exit 1; }; }

if [ "$only" != search ]; then
  echo "Header: typing…"
  launch
  # A short Weekend, so everything fits at this size: the typed lines come under Saturday's.
  printf '## Saturday\n- [ ] Tomatoes and basil\n- [x] Bags\n' > "$library/Personal/Weekend.md"
  say "set size 38" "set width wide" "open Personal/Weekend.md"
  sleep 2
  rm -f "$raw/typing.mov"
  "$work/capture" rec "$pid" "$raw/typing.mov" 18 > "$work/rec.log" &
  recorder=$!
  for _ in $(seq 40); do grep -q recording "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
  python3 - "$library/Personal/Weekend.md" >> "$work/cmd" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
end = len(text.encode("utf-16-le")) // 2
lines = [f"caret {end}", "showcaret 1", "wait 1.5"]
def typed(s, delay=0.09):
    for ch in s:
        lines.extend(["key return" if ch == "\n" else f"type {ch}", f"wait {delay}"])
typed("\n\n## Sunday")
lines.append("wait 0.7")
typed("\n- [ ] A long walk by the **lake**")
lines.append("wait 0.8")
typed(", then ==coffee== at Mia's")
print("\n".join(lines))
EOF
  wait $recorder
  say "showcaret 0"
  sleep 0.8
  shot typing-end
  quit
fi

if [ "$only" != header ]; then
  echo "Search: Kyoto trip and the files next to it…"
  launch
  say "set size 22" "set width medium" "open Personal/Weekend.md" "wait 1" "open Travel/Kyoto trip.md"
  sleep 2
  shot kyoto-top
  say "scroll 520"
  sleep 1.5
  shot kyoto-scrolled
  quit
  cp "$library/Travel/Kyoto trip.md" "$library/Travel/Budget.md" "$raw/"
  # macOS's own thumbnails of the PDFs and the photo, as the Finder shows them.
  qlmanage -t -s 1024 -o "$raw/thumbs" "$library/Travel/Flight tickets.pdf" "$library/Travel/ryokan.jpg" \
    "$library/Travel/Ryokan confirmation.pdf" > /dev/null 2>&1
  for name in "Flight tickets.pdf" ryokan.jpg "Ryokan confirmation.pdf"; do
    [ -s "$raw/thumbs/$name.png" ] || { echo "No thumbnail of $name." >&2; exit 1; }
  done
fi

echo "Laying out…"
python3 Tools/app-store-media/creative.py "$raw" "$stills" ${only:+"$only"}
echo "Done: $stills. Look at both stills and watch both videos before using them."
