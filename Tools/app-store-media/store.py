# What the App Store pictures and videos share: their sizes, Apple's safe areas, Notebook's type and colours, and the
# backdrop, shadows and rounded corners of the README pictures (Tools/readme-images/compose.py).
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Tools", "readme-images"))
from compose import THEMES, backdrop, rounded, scaled, shadow_onto  # noqa: E402,F401

# The creative assets of iOS 27 and their art safe areas, as Apple's templates draw them
# (developer.apple.com/app-store/asset-best-practices).
HEADER = (3840, 1646)
HEADER_SAFE = (1097, 493, 2743, 1154)
SEARCH = (3840, 2560)
SEARCH_SAFE = (836, 765, 3004, 1795)

# Screenshots and app previews, per device.
SCREENSHOT = {"iphone": (1320, 2868), "ipad": (2064, 2752), "mac": (2880, 1800)}
PREVIEW = {"iphone": (886, 1920), "ipad": (1200, 1600), "mac": (1920, 1080)}

TEXT = {"light": (28, 28, 30), "dark": (242, 242, 247)}
SECONDARY = {"light": (106, 106, 114), "dark": (164, 164, 172)}
INK = {"light": (52, 80, 143), "dark": (147, 171, 227)}


def font(weight, size, face="SFNS"):
    f = ImageFont.truetype(f"/System/Library/Fonts/{face}.ttf", round(size))
    try:
        f.set_variation_by_name(weight)
    except (OSError, ValueError):
        pass
    return f


def fitted(text, weight, size, width, face="SFNS"):
    """The font at `size`, or smaller until the text fits `width`."""
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    while size > 10 and probe.textlength(text, font=font(weight, size, face)) > width:
        size -= 2
    return font(weight, size, face)


def centred(img, y, text, f, fill):
    d = ImageDraw.Draw(img)
    w = d.textlength(text, font=f)
    d.text(((img.width - w) / 2, y), text, font=f, fill=fill)


def paper(theme):
    """The note's background in Notebook."""
    return (255, 255, 255) if theme == "light" else (30, 30, 30)


def run(*command, **kwargs):
    return subprocess.run([str(c) for c in command], check=True, **kwargs)
