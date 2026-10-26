#!/bin/bash
# Builds Notebook's app icon (Notebook/AppIcon.icon), the passes Settings › App Icon colours at runtime
# (Packages/NotebookKit/Sources/NotebookKit/Resources/NotebookIcon), the icon on the New Note widget
# (NotebookWidgets/Assets.xcassets/NotebookIcon.imageset) and the leather of the website's button
# (Website/images/leather.webp). Run it after changing Tools/AppIcon/notebook.py.
#   Tools/AppIcon/make.sh
# Needs Xcode (for Icon Composer's ictool), Python 3 with NumPy and Pillow, and rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/../.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
work=build/app-icon
passes=Packages/NotebookKit/Sources/NotebookKit/Resources/NotebookIcon

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "Needs rsvg-convert: brew install librsvg" >&2; exit 1; }

rm -rf Notebook/AppIcon.icon "$work"
mkdir -p "$work" "$passes"
python3 Tools/AppIcon/notebook.py icon Notebook
python3 Tools/AppIcon/notebook.py passes "$work"
python3 Tools/AppIcon/notebook.py leather Website/images/leather.webp

# Each pass at 512 px, light and dark, in 8 bits: plenty for the Dock and the preview in Settings.
for part in base ground cover band ribbon; do
  for look in Default Dark; do
    name=$([ $look = Default ] && echo light || echo dark)-$part
    "$ictool" "$work/pass-$part.icon" --export-image --output-file "$work/$name.png" \
      --platform macOS --rendition $look --width 512 --height 512 --scale 1 >/dev/null
    python3 - "$work/$name.png" "$passes/$name.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], optimize=True, icc_profile=im.info.get("icc_profile"))
EOF
  done
done

# The icon as the Home Screen shows it, 48 pt on the New Note widget, light and dark.
widget=NotebookWidgets/Assets.xcassets/NotebookIcon.imageset
for look in Default Dark; do
  name=$([ $look = Default ] && echo light || echo dark)
  for scale in 1 2 3; do
    "$ictool" Notebook/AppIcon.icon --export-image --output-file "$work/widget-$name@${scale}x.png" \
      --platform iOS --rendition $look --width $((48 * scale)) --height $((48 * scale)) --scale 1 >/dev/null
    python3 - "$work/widget-$name@${scale}x.png" "$widget/$name@${scale}x.png" <<'EOF2'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], optimize=True, icc_profile=im.info.get("icc_profile"))
EOF2
  done
done
echo "Wrote Notebook/AppIcon.icon and $(ls "$passes" | wc -l | tr -d ' ') passes to $passes"
echo "Wrote the widget's icon to $widget"
echo "Wrote Website/images/leather.webp"
