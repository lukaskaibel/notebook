#!/usr/bin/env python3
"""Draws Notebook's app icon: the cover of a leather notebook filling the icon, with its elastic band and a ribbon
hanging from the top, the way Apple's book icons (Contacts, Dictionary, Font Book) fill theirs.

  notebook.py icon <out dir>       <out dir>/AppIcon.icon, the oxblood notebook in light, dark and tinted (the app's own)
  notebook.py passes <out dir>     the neutral passes behind Settings › App Icon (see NotebookIcon.swift)
  notebook.py leather <out>        the cover's grain alone as a seamless tile, for the website's leather buttons
                                   (Website/images/leather.webp; needs only NumPy and Pillow)
  notebook.py framed <in> <out> <size>
                                   an ictool render on Apple's icon grid with the Dock's shadow, for the README and the
                                   website
  notebook.py touch <AppIcon.icon> <out> <size>
                                   the icon's layers flat and square, for the website's apple-touch-icon

Tools/AppIcon/make.sh runs them and renders the passes with Apple's ictool. Needs Python 3 with NumPy and Pillow,
and rsvg-convert (brew install librsvg).

The layers are drawn as SVG, the leather grain is added to the cover with NumPy, and Icon Composer's file format puts
them together, so the system adds the glass and the shadows. The tinted and clear looks get images of their own: a
near-black cover with a white ribbon and a grey band, so the notebook still shows when the system recolours the icon.
"""
import colorsys, json, os, subprocess, sys
import numpy as np
from PIL import Image

# On the 1024 canvas: the cover fills it; the band runs from top to bottom near the right edge, the hinge is a line
# near the left, and the ribbon hangs from the top edge with a swallowtail end.
BAND_X, BAND_W = 794, 58
HINGE_X, HINGE_W = 78, 12
RIBBON_X, RIBBON_W, RIBBON_END, RIBBON_NOTCH = 212, 72, 236, 30

# The notebook the app ships with. Keep in step with NotebookLook.standard in NotebookIcon.swift.
STANDARD = {"leather": "#A8403F", "ribbon": "#E9B04A", "band": "leather"}

# The tinted and clear looks: the system keeps only how light each part is.
TINTED = {"cover": "#141414", "band": "#5C5C5C", "ribbon": "#FFFFFF"}

# The albedo a part gets in its pass; below white so the grain's highlights never clip.
PASS_GREY = "#B4B4B4"


# Colours. The app derives the same shades from the same base colours (NotebookIcon.swift).

def rgb(hex_):
    return tuple(int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))

def hex_(c):
    return "#" + "".join(f"{round(min(max(v, 0), 1) * 255):02X}" for v in c)

def scaled(hex_colour, saturation, brightness):
    h, s, v = colorsys.rgb_to_hsv(*rgb(hex_colour))
    return hex_(colorsys.hsv_to_rgb(h, min(s * saturation, 1), min(v * brightness, 1)))

def leather_shades(c):
    """Cover gradient (top, bottom) in light and in dark, a little deeper in dark to sit with the other dark icons,
    and the elastic band's tone."""
    return {"light": (c, scaled(c, 1.18, 0.64)), "dark": (scaled(c, 1.0, 0.9), scaled(c, 1.2, 0.55)),
            "band": scaled(c, 1.25, 0.45)}


# Drawing.

def rect(x, y, w, h, r, fill):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r:.1f}" fill="{fill}"/>'

def faded(colour, opacity):
    return f'{colour}" fill-opacity="{opacity}'

# The parts run past the canvas, so the icon's rounded corners are the only edges.
def cover(fill): return rect(-60, -60, 1144, 1144, 0, fill)
def band(fill): return rect(BAND_X, -10, BAND_W, 1044, 0, fill)
def hinge(opacity): return rect(HINGE_X, -10, HINGE_W, 1044, 0, faded("#000000", opacity))

def ribbon(fill):
    x, w, end = RIBBON_X, RIBBON_W, RIBBON_END
    return f'<path d="M{x},-40 H{x + w} V{end} L{x + w / 2},{end - RIBBON_NOTCH} L{x},{end} Z" fill="{fill}"/>'

def linear_gradient(id_, top, bottom):
    return (f'<linearGradient id="{id_}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1024">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>')

def write_png(path, body, defs=""):
    svg = path[:-4] + ".svg"
    with open(svg, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<defs>{defs}</defs>{body}</svg>')
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", "-o", path, svg], check=True)
    os.remove(svg)


# The leather grain: soft pebbles at two sizes, lit from the top left, with faint mottling.

def pebbles(size, cell, rng, wrap=False):
    """wrap: the cells fitted to the size and wrapped around its edges, so the result tiles without a seam."""
    if wrap:
        n = round(size / cell)
        cell = size / n
    else:
        n = int(size / cell) + 3
    points = rng.random((n, n, 2))
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    cx, cy = np.floor(xx / cell).astype(int), np.floor(yy / cell).astype(int)
    d1 = np.full((size, size), 1e9, np.float32)
    d2 = np.full((size, size), 1e9, np.float32)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            if wrap:
                gx, gy = cx + ox, cy + oy
                px, py = gx % n, gy % n
            else:
                gx, gy = np.clip(cx + ox, 0, n - 1), np.clip(cy + oy, 0, n - 1)
                px, py = gx, gy
            d = np.hypot(xx - (gx + points[py, px, 0]) * cell, yy - (gy + points[py, px, 1]) * cell)
            closer = d < d1
            d2 = np.where(closer, d1, np.minimum(d2, d))
            d1 = np.where(closer, d, d1)
    t = np.clip((d2 - d1) / (cell * 0.55), 0, 1)
    return t * t * (3 - 2 * t)

def grain(size=1024, seed=7, wrap=False):
    rng = np.random.default_rng(seed)
    e = 0.6 * pebbles(size, 8.5, rng, wrap) + 0.4 * pebbles(size, 15.0, rng, wrap)
    if wrap:
        gx = (np.roll(e, -1, 1) - np.roll(e, 1, 1)) / 2
        gy = (np.roll(e, -1, 0) - np.roll(e, 1, 0)) / 2
        # The mottling at the icon's scale, from noise tiled three by three so that its middle wraps too.
        k = max(2, round(24 * size / 1024))
        low = Image.fromarray((np.tile(rng.random((k, k)), (3, 3)) * 255).astype(np.uint8))
        low = low.resize((size * 3, size * 3), Image.BICUBIC).crop((size, size, size * 2, size * 2))
    else:
        gy, gx = np.gradient(e)
        low = Image.fromarray((rng.random((24, 24)) * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
    mottle = (np.asarray(low).astype(np.float32) / 255 - 0.5) * 0.05
    return 0.93 + 0.08 * e - (gx + gy) * 0.9 + mottle + rng.normal(0, 1, (size, size)).astype(np.float32) * 0.01

GRAIN = None

def add_grain(path):
    global GRAIN
    if GRAIN is None:
        GRAIN = grain()
    a = np.asarray(Image.open(path).convert("RGBA")).astype(np.float32)
    a[..., :3] = np.clip(a[..., :3] * GRAIN[..., None], 0, 255)
    Image.fromarray(a.astype(np.uint8), "RGBA").save(path)


# Icon Composer documents.

def srgb(hex_colour, alpha=1.0):
    r, g, b = rgb(hex_colour)
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"

def fill(top, bottom):
    return {"linear-gradient": [srgb(top), srgb(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}

def document(path, grounds, layers, defs="", grained=(), tinted=None):
    """grounds: {"light": (top, bottom), "dark": (top, bottom)}, behind everything.
    layers: [(group, [(layer, light svg, dark svg, glass)], shadow opacity)], front first.
    tinted: {layer: svg} for the tinted and clear looks; a layer without one shows its light image there."""
    assets = os.path.join(path, "Assets")
    os.makedirs(assets, exist_ok=True)
    tinted = tinted or {}
    groups = []
    for group, group_layers, shadow in layers:
        out = []
        for name, light, dark, glass in group_layers:
            looks = [("light", light), ("dark", dark)] + ([("tinted", tinted[name])] if name in tinted else [])
            for look, body in looks:
                png = os.path.join(assets, f"{name}-{look}.png")
                write_png(png, body, defs)
                if name in grained and look != "tinted":
                    add_grain(png)
            specializations = [{"value": f"{name}-light.png"}, {"value": f"{name}-dark.png", "appearance": "dark"}]
            if name in tinted:
                specializations.append({"value": f"{name}-tinted.png", "appearance": "tinted"})
            out.append({"name": name, "glass": glass, "image-name-specializations": specializations})
        groups.append({"name": group, "layers": out,
                       "shadow": {"kind": "neutral" if shadow else "none", "opacity": shadow or 0.5},
                       "translucency": {"enabled": False, "value": 0.4}})
    doc = {"fill-specializations": [{"value": fill(*grounds["light"])},
                                    {"appearance": "dark", "value": fill(*grounds["dark"])}],
           "groups": groups, "supported-platforms": {"squares": "shared"}}
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)

def notebook(path, leather, ribbon_colour, band_colour, tinted=False):
    """leather: {"light": (top, bottom), "dark": (top, bottom)} or one flat colour for a pass."""
    if isinstance(leather, str):
        defs, covers, ground = "", (cover(leather), cover(leather)), (leather, leather)
        grounds = {"light": ground, "dark": ground}
    else:
        defs = linear_gradient("light", *leather["light"]) + linear_gradient("dark", *leather["dark"])
        covers = (cover("url(#light)"), cover("url(#dark)"))
        grounds = {"light": leather["light"], "dark": leather["dark"]}
    document(path, grounds, [
        ("Ribbon", [("ribbon", ribbon(ribbon_colour), ribbon(ribbon_colour), True)], 0.45),
        ("Band", [("band", band(band_colour), band(band_colour), True)], 0.35),
        ("Cover", [("cover-detail", hinge(0.18), hinge(0.24), False), ("cover", *covers, True)], 0.55),
    ], defs, grained=("cover",), tinted={
        "ribbon": ribbon(TINTED["ribbon"]), "band": band(TINTED["band"]), "cover": cover(TINTED["cover"]),
    } if tinted else None)


def standard_icon(out):
    leather = leather_shades(STANDARD["leather"])
    tone = leather["band"] if STANDARD["band"] == "leather" else "#FFFFFF"
    notebook(os.path.join(out, "AppIcon.icon"), leather, STANDARD["ribbon"], tone, tinted=True)

def passes(out):
    """One document per part: that part in grey, the rest black. The app adds them up in linear light."""
    for part in ("base", "cover", "band", "ribbon"):
        def colour(p): return PASS_GREY if p == part else "#000000"
        notebook(os.path.join(out, f"pass-{part}.icon"), colour("cover"), colour("ribbon"), colour("band"))

def leather(out):
    """The grain at half its contrast, lifted so that its highlights just reach white: the website multiplies it
    over the button's colour, at 2x."""
    g = 1 + (grain(256, wrap=True) - 1) * 0.5
    # A high percentile rather than the maximum, so that a few bright outliers don't darken the whole tile.
    g = np.clip(g / np.percentile(g, 99.5), 0, 1)
    Image.fromarray((g * 255).round().astype(np.uint8), "L").save(out, quality=82, method=6)


def framed(source, out, size):
    """The icon as the Dock shows it: on Apple's icon grid (824 of 1024) with the Dock's soft shadow, as
    NotebookRenderer.dockImage draws it."""
    from PIL import ImageFilter
    size = int(size)
    icon = Image.open(source).convert("RGBA")
    content = round(size * 824 / 1024)
    k = content / 824
    icon = icon.resize((content, content), Image.LANCZOS)
    at = (size - content) // 2
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    alpha = Image.new("L", (size, size), 0)
    alpha.paste(icon.split()[3], (at, at + round(10 * k)))
    shadow.putalpha(alpha.point(lambda v: round(v * 0.28)).filter(ImageFilter.GaussianBlur(12 * k)))
    shadow.alpha_composite(icon, (at, at))
    shadow.save(out, optimize=True)

def touch(icon, out, size):
    """The light layers stacked, square and opaque: a web page's apple-touch-icon is rounded by iOS itself, so an
    ictool render, rounded already, would show its rim inside iOS's corners."""
    doc = json.load(open(os.path.join(icon, "icon.json")))
    flat = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255))
    for group in reversed(doc["groups"]):
        for layer in reversed(group["layers"]):
            flat.alpha_composite(Image.open(os.path.join(icon, "Assets", f"{layer['name']}-light.png")).convert("RGBA"))
    flat.convert("RGB").resize((int(size), int(size)), Image.LANCZOS).save(out, optimize=True)


if __name__ == "__main__":
    what, args = sys.argv[1], sys.argv[2:]
    {"icon": standard_icon, "passes": passes, "leather": leather, "framed": framed, "touch": touch}[what](*args)
