# Lays out the App Store's creative assets of iOS 27 from the captures Tools/app-store-media.sh takes:
#   the product page header, 3840 x 1646: a note being typed, its Markdown marks folding away as you go on;
#   the search result, 3840 x 2560: Kyoto trip.md in a row of the files of its folder, opening into the note.
# Each is a still (PNG, the video's poster) and a looping video, H.264 at 30 fps, whose end fades or comes back to
# its first frame.
#   python3 Tools/app-store-media/creative.py <captures folder> <out folder> [header|search]
# The row of files is drawn, not captured: real thumbnails of the sample files (macOS's Quick Look for the PDFs and the
# photo, the Markdown text drawn as a page), with their names. It is a picture of files, not the Finder.
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

from store import (HEADER, HEADER_SAFE, INK, SEARCH, SEARCH_SAFE, TEXT, THEMES, backdrop, centred, font,
                   paper, rounded, scaled, shadow_onto)

FPS = 30
THEME = "dark"  # one asset serves the App Store's light and dark appearance; the dark one sits well on both
PHRASE = "Right next to your documents."


# ---------------------------------------------------------------------------------------------------------------
# Measuring the captures

def bands(img, x0, x1, top, bg):
    """Rows of text (start, end) between x0 and x1 below `top`: where some pixel differs from the paper."""
    a = np.asarray(img.convert("RGB")).astype(int)[:, x0:x1]
    ink = (np.abs(a - np.array(bg)).sum(2) > 60).any(1)
    out, start = [], None
    for y in range(top, len(ink)):
        if ink[y] and start is None:
            start = y
        elif not ink[y] and start is not None:
            out.append((start, y))
            start = None
    return out


def columns(img, y0, y1, bg, x0=0, x1=None):
    """Leftmost and rightmost column with something on it between rows y0 and y1, looking between x0 and x1."""
    a = np.asarray(img.convert("RGB")).astype(int)[y0:y1, x0:x1]
    ink = np.nonzero((np.abs(a - np.array(bg)).sum(2) > 60).any(0))[0]
    return x0 + int(ink.min()), x0 + int(ink.max()) + 1


def note_area(img, bg):
    """The note's column in a window capture: the widest run of paper along a row near the bottom."""
    a = np.asarray(img.convert("RGB")).astype(int)
    row = (np.abs(a[a.shape[0] - 60] - np.array(bg)).sum(1) < 6)
    best, start = (0, 0), None
    for x, on in enumerate(list(row) + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start > best[1] - best[0]:
                best = (start, x)
            start = None
    return best


def encoder(out, size, crf=16):
    w, h = size
    return subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(FPS),
         "-i", "-", "-c:v", "libx264", "-profile:v", "high", "-level", "5.1", "-preset", "slow", "-crf", str(crf),
         "-maxrate", "40M", "-bufsize", "80M", "-pix_fmt", "yuv420p", "-r", str(FPS), "-movflags", "+faststart", out],
        stdin=subprocess.PIPE)


def ease(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------------------------------------------------------
# The header: typing in a note

class Header:
    def __init__(self, raw):
        self.raw = raw
        end = Image.open(f"{raw}/typing-end.png").convert("RGB")
        bg = paper(THEME)
        self.area = note_area(end, bg)
        lines = bands(end, *self.area, 110, bg)
        # The last two bands are what was typed: "Sunday" and its to-do.
        heading, todo = lines[-2], lines[-1]
        left, right = columns(end, todo[0], todo[1], bg, *self.area)
        left = min(left, columns(end, heading[0], heading[1], bg, *self.area)[0])
        self.scale = min(1.0, 1500 / (right - left))
        self.centre_x = (left + right) / 2
        self.anchor_y = (heading[0] + todo[1]) / 2
        # From under the title and its date, which keep their own size whatever the text size and would look small.
        self.crop = (self.area[0], lines[1][1] + 6, self.area[1], min(end.height, todo[1] + 420))
        s = self.scale
        x0, y0, x1, y1 = HEADER_SAFE
        # The typed lines a little below the middle of the safe area, and the card running off the top, with more
        # paper above the note's title where the note is short.
        top = round((y0 + y1) / 2 + 40 - (self.anchor_y - self.crop[1]) * s)
        self.above = max(0, top + 80)
        self.card_size = (2400, round((self.crop[3] - self.crop[1]) * s) + self.above)
        self.pos = ((HEADER[0] - self.card_size[0]) // 2, top - self.above)
        shape = rounded(Image.new("RGB", self.card_size, bg), 44)
        self.mask = shape.getchannel("A")
        self.base = shadow_onto(backdrop(HEADER, THEME).convert("RGBA"), shape, self.pos, THEME)
        self.line = rounded(Image.new("RGBA", self.card_size, (0, 0, 0, 0)), 44, THEMES[THEME]["border"])

    def card(self, crop, bg):
        """The crop (already scaled) on a card of paper, with the typed text in its middle."""
        card = Image.new("RGB", self.card_size, bg)
        card.paste(crop, (round(self.card_size[0] / 2 - (self.centre_x - self.crop[0]) * self.scale), self.above))
        return card

    def frame(self, card):
        img = self.base.copy()
        img.paste(card, self.pos, self.mask)
        img.alpha_composite(self.line, self.pos)
        return img.convert("RGB")

    def still(self):
        end = Image.open(f"{self.raw}/typing-end.png").convert("RGB")
        crop = scaled(end.crop(self.crop), self.scale)
        return self.frame(self.card(crop, paper(THEME)))

    def video(self, out, fade=0.7):
        x0, y0, x1, y1 = self.crop
        w, h = round((x1 - x0) * self.scale), round((y1 - y0) * self.scale)
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{self.raw}/typing.mov", "-vf",
                              f"fps={FPS},crop={x1 - x0}:{y1 - y0}:{x0}:{y0},scale={w}:{h}:flags=lanczos",
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
        count = len(raw) // (w * h * 3)
        crops = [Image.frombuffer("RGB", (w, h), raw[i * w * h * 3:(i + 1) * w * h * 3]) for i in range(count)]
        # From a second before the typing to two and a half after it.
        small = [np.asarray(c.resize((w // 8, h // 8)).convert("L")).astype(int) for c in crops]
        moving = [i for i in range(1, count) if np.abs(small[i] - small[i - 1]).mean() > 0.05]
        crops = crops[max(0, moving[0] - FPS):min(count, moving[-1] + round(2.5 * FPS))]
        count = len(crops)
        # The recording's paper isn't quite the PNG's: take it from the frames.
        frames = (self.frame(self.card(c, c.getpixel((c.width - 4, c.height // 2)))) for c in crops)
        loop(frames, count, out, HEADER, fade)


def loop(frames, count, out, size, fade):
    """Writes the frames, the last `fade` seconds blending into the first frame, so the loop shows no jump."""
    n = round(fade * FPS)
    p = encoder(out, size)
    first = None
    for i, f in enumerate(frames):
        if first is None:
            first = f
        j = i - (count - n)
        if j >= 0:
            f = Image.blend(f, first, ease((j + 1) / n))
        p.stdin.write(f.tobytes())
    p.stdin.close()
    if p.wait() != 0:
        sys.exit(f"ffmpeg failed on {out}")
    print(f"  {out} ({count / FPS:.1f} s)")


# ---------------------------------------------------------------------------------------------------------------
# The search result: a note among the files of its folder

def text_page(path, size=(723, 1024)):
    """A Markdown file as a page of its plain text, as a file's thumbnail shows it."""
    text = open(path, encoding="utf-8").read()
    img = Image.new("RGB", size, (38, 38, 40) if THEME == "dark" else (255, 255, 255))
    d = ImageDraw.Draw(img)
    f = font("Regular", 19, "SFNSMono")
    y = 44
    for line in text.splitlines():
        if not line:
            y += 28
        while line and y < size[1] - 40:
            cut = len(line)
            while d.textlength(line[:cut], font=f) > size[0] - 80:
                cut -= 1
            d.text((40, y), line[:cut], font=f, fill=(220, 220, 224) if THEME == "dark" else (40, 40, 44))
            line = line[cut:]
            y += 28
    return img


def sprite(item, rim=False, pad=240):
    canvas = Image.new("RGBA", (item.width + 2 * pad, item.height + 2 * pad), (0, 0, 0, 0))
    return shadow_onto(canvas, item, (pad, pad), THEME, rim=rim), pad


class Search:
    """The row of files, Kyoto trip.md in the middle. `opened` 0 shows its text as a page, 1 the note in Notebook."""
    # Sizes in pixels of the 3840 x 2560 picture; the phrase, the card and the names share the safe area's 1030 rows.
    ICON, CARD_W, VIEW, NAME, GAP = 420, 1180, 0.6, 56, 84
    FILES = ["Budget.md", "Flight tickets.pdf", None, "ryokan.jpg", "Ryokan confirmation.pdf"]

    def __init__(self, raw):
        self.raw = raw
        self.note = self.stitched()
        self.page = text_page(f"{raw}/Kyoto trip.md")
        self.thumbs = {}
        for name in self.FILES:
            if name is None:
                continue
            img = text_page(f"{raw}/{name}") if name.endswith(".md") else Image.open(f"{raw}/thumbs/{name}.png")
            img = img.convert("RGBA")
            img = scaled(img, min(self.ICON / img.width, self.ICON / img.height))
            img = rounded(img, 10, THEMES[THEME]["border"]) if img.width < img.height * 1.2 else rounded(img, 16)
            self.thumbs[name] = (img, sprite(img))
        self.view_h = round(self.CARD_W * self.VIEW)  # the card's height: the note's top, into the picture
        self.sprites = {}
        bg = backdrop(SEARCH, THEME).convert("RGBA")
        x0, y0, x1, y1 = SEARCH_SAFE
        centred(bg, y0 + 12, PHRASE, font("Semibold", 124), TEXT[THEME])
        self.bg = bg
        self.bottom = y1 - 105  # the files stand on this line, their names under it, in the safe area

    def stitched(self):
        """Kyoto trip in Notebook as one tall page: the window's view at the top, and scrolled further down."""
        top = Image.open(f"{self.raw}/kyoto-top.png").convert("RGB")
        down = Image.open(f"{self.raw}/kyoto-scrolled.png").convert("RGB")
        bg = paper(THEME)
        x0, x1 = note_area(top, bg)
        a = np.asarray(top).astype(int)[:, x0:x1]
        b = np.asarray(down).astype(int)[:, x0:x1]
        # Where the scrolled view's rows are in the top one: the shift that matches best.
        best = min(range(200, a.shape[0] - 300),
                   key=lambda d: np.abs(a[d + 120:a.shape[0] - 40:7] - b[120:a.shape[0] - d - 40:7]).mean())
        page = Image.new("RGB", (x1 - x0, a.shape[0] + best), bg)
        page.paste(down.crop((x0, 0, x1, down.height)), (0, best))
        page.paste(top.crop((x0, 0, x1, top.height - 40)), (0, 0))
        # Under the toolbar only, centred on the note's own column (its picture spans the column).
        page = page.crop((0, 112, page.width, page.height - 40))
        left, right = columns(page, 450, 1000, bg)
        centre = (left + right) / 2
        width = round((right - left) * 1.22)
        card = Image.new("RGB", (width, page.height), bg)
        card.paste(page, (round(width / 2 - centre), 0))
        return card

    def middle(self, e, scroll):
        """The middle file's picture: its text page at e 0, the note at 1, cross-faded between."""
        w0, h0 = self.ICON * 723 / 1024, self.ICON
        k = self.CARD_W / self.note.width
        w1, h1 = self.CARD_W, self.view_h
        w, h = round(w0 + (w1 - w0) * e), round(h0 + (h1 - h0) * e)
        view = self.note.crop((0, round(scroll / k), self.note.width, round(scroll / k + h1 / k)))
        rendered = view.resize((w, h), Image.LANCZOS)
        page = self.page.resize((w, round(w * 1024 / 723)), Image.LANCZOS).crop((0, 0, w, h))
        img = Image.blend(page, rendered, min(1.0, max(0.0, (e - 0.15) / 0.7))).convert("RGBA")
        return rounded(img, round(10 + 30 * e), THEMES[THEME]["border"])

    def label(self, img, cx, y, name, selected):
        d = ImageDraw.Draw(img)
        f = font("Semibold" if selected > 0.5 else "Medium", self.NAME)
        w = d.textlength(name, font=f)
        colour = tuple(round(a + (b - a) * selected) for a, b in zip(TEXT[THEME], INK[THEME]))
        d.text((cx - w / 2, y), name, font=f, fill=colour)

    def frame(self, opened=1.0, selected=1.0, scroll=0.0):
        img = self.bg.copy()
        e = ease(opened)
        middle = self.middle(e, scroll)
        key = (middle.width, middle.height)
        if key not in self.sprites:
            shape = Image.new("RGBA", middle.size, (0, 0, 0, 0))
            shape.putalpha(middle.getchannel("A"))
            self.sprites = {key: sprite(shape, rim=e > 0.5)}  # one size at a time: the hold reuses it
        shadow, pad = self.sprites[key]
        cx = img.width // 2
        x, y = cx - middle.width // 2, self.bottom - middle.height
        img.alpha_composite(shadow, (x - pad, y - pad))
        img.alpha_composite(middle, (x, y))
        self.label(img, cx, self.bottom + 30, "Kyoto trip.md", selected)
        probe = ImageDraw.Draw(img)
        for side, names in ((-1, self.FILES[:2][::-1]), (1, self.FILES[3:])):
            at = cx + side * (middle.width / 2 + self.GAP)
            for name in names:
                thumb, (spr, pad) = self.thumbs[name]
                slot = max(self.ICON, probe.textlength(name, font=font("Medium", self.NAME)))
                tx = at + side * slot / 2
                img.alpha_composite(spr, (round(tx - thumb.width / 2 - pad), round(self.bottom - thumb.height - pad)))
                self.label(img, tx, self.bottom + 30, name, 0)
                at += side * (slot + self.GAP)
        return img.convert("RGB")

    def still(self):
        return self.frame(1.0, 1.0, 0.0)

    def video(self, out, length=16.0):
        most = self.note.height * self.CARD_W / self.note.width - self.view_h
        travel = min(330, most)
        count = round(length * FPS)

        def frames():
            for i in range(count):
                t = i / FPS
                selected = ease((t - 1.0) / 0.3) - ease((t - 13.0) / 0.3)
                opened = ease((t - 1.5) / 1.2) - ease((t - 11.6) / 1.2)
                scroll = travel * ease((t - 5.0) / 4.0)
                yield self.frame(opened, selected, scroll)
        loop(frames(), count, out, SEARCH, fade=0.2)


def check_size(path, size):
    img = Image.open(path)
    if img.size != size or img.mode != "RGB":
        sys.exit(f"{path} is {img.size} {img.mode}, not {size} RGB")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: creative.py <captures folder> <out folder> [header|search]")
    raw, out = sys.argv[1:3]
    which = sys.argv[3:] or ["header", "search"]
    os.makedirs(out, exist_ok=True)
    if "header" in which:
        header = Header(raw)
        header.still().save(f"{out}/header.png")
        check_size(f"{out}/header.png", HEADER)
        print(f"  {out}/header.png")
        header.video(f"{out}/header.mp4")
    if "search" in which:
        search = Search(raw)
        search.still().save(f"{out}/search.png")
        check_size(f"{out}/search.png", SEARCH)
        print(f"  {out}/search.png")
        search.video(f"{out}/search.mp4")
