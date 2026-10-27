# Lays out an App Store screenshot: a caption line and a smaller line under it, and the screen below them, on the
# backdrop of the README pictures, at the size the App Store takes for the device, without alpha.
#   python3 Tools/app-store-media/caption.py <capture.png> <out.png> iphone|ipad|mac light|dark "Caption" "Smaller line"
# iPhone and iPad captures are the simulator's screen (`simctl io screenshot`), which gets the screen's rounded
# corners; a Mac capture is the window as Tools/readme-images/capture.swift takes it, with its own corners and alpha.
import sys

from PIL import Image

from store import SCREENSHOT, SECONDARY, TEXT, THEMES, backdrop, centred, fitted, rounded, scaled, shadow_onto

# Per device: the screen's corner radius in pixels of the capture (55 points at 3x, 18 at 2x), how wide the screen is
# drawn and where its top is, and the caption's sizes and places.
LAYOUT = {
    "iphone": dict(corner=165, width=1100, top=560, size=(104, 56), y=(196, 336), margin=80),
    "ipad": dict(corner=36, width=1640, top=520, size=(116, 62), y=(176, 330), margin=120),
    "mac": dict(corner=0, width=2120, top=420, size=(104, 56), y=(118, 262), margin=200),
}


def caption(capture, out, device, theme, line, smaller):
    W, H = SCREENSHOT[device]
    lay = LAYOUT[device]
    canvas = backdrop((W, H), theme).convert("RGBA")
    screen = Image.open(capture).convert("RGBA")
    k = lay["width"] / screen.width
    screen = scaled(screen, k)
    if lay["corner"]:
        screen = rounded(screen, round(lay["corner"] * k), THEMES[theme]["border"])
    canvas = shadow_onto(canvas, screen, ((W - screen.width) // 2, lay["top"]), theme, rim=True)
    room = W - 2 * lay["margin"]
    centred(canvas, lay["y"][0], line, fitted(line, "Semibold", lay["size"][0], room), TEXT[theme])
    centred(canvas, lay["y"][1], smaller, fitted(smaller, "Regular", lay["size"][1], room), SECONDARY[theme])
    canvas.convert("RGB").save(out)


if __name__ == "__main__":
    if len(sys.argv) != 7 or sys.argv[3] not in LAYOUT or sys.argv[4] not in THEMES:
        sys.exit(__doc__ or "usage: caption.py <capture.png> <out.png> iphone|ipad|mac light|dark <caption> <smaller line>")
    caption(*sys.argv[1:])
