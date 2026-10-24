# Frames a picture of Notebook's window for the Mac App Store: centred on the backdrop of the README pictures
# (readme-images/compose.py), with the shadows and hairline of a macOS window, 2880 x 1800 without alpha.
#   python3 Tools/store-frame.py <window.png> <out.png> light|dark
# The window is a capture of it on screen (Tools/readme-images/capture.swift), with its own rounded corners and the
# coloured traffic lights of the active app; see Tools/mac-app-store-screenshots.sh.
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "readme-images"))
import compose  # noqa: E402

WIDTH, HEIGHT = 2880, 1800

if len(sys.argv) != 4 or sys.argv[3] not in compose.THEMES:
    sys.exit("usage: python3 Tools/store-frame.py <window.png> <out.png> light|dark")
source, out, theme = sys.argv[1:]

window = Image.open(source).convert("RGBA")
# A window too large for the picture is made smaller, keeping room for its shadow.
room = min(1, (WIDTH - 240) / window.width, (HEIGHT - 200) / window.height)
if room < 1:
    window = compose.scaled(window, room)

canvas = compose.backdrop((WIDTH, HEIGHT), theme).convert("RGBA")
# A little above the middle: the shadow falls below the window and would make it look low.
pos = ((WIDTH - window.width) // 2, (HEIGHT - window.height) // 2 - 16)
canvas = compose.shadow_onto(canvas, window, pos, theme, rim=True)
canvas.convert("RGB").save(out)
