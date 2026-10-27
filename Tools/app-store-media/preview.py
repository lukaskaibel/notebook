# Edits an App Store app preview from recordings of the app: the clips one after another with a short cross-fade,
# at the size the App Store takes for the device, H.264 (High, level 4.0) at 30 fps and 11 Mbps, with the silent
# stereo track App Store Connect requires (previews have to have audio). 15 to 30 seconds. The bitrate stays at 11 Mbps
# where little moves, as Apple asks.
#   python3 Tools/app-store-media/preview.py <out.mp4> iphone|ipad <clip> [<clip> …]
#   python3 Tools/app-store-media/preview.py <out.mp4> mac light|dark <window.png> <clip> [<clip> …]
# A clip is <recording>:<start>:<end>, in seconds; :<start>:<end> may be left out for all of it. iPhone and iPad
# recordings are the simulator's screen (`simctl io recordVideo`), scaled to fill the preview. Mac recordings are the
# window (`capture rec` of Tools/readme-images/capture.swift); they are laid on the README pictures' backdrop with the
# window's shadow, and <window.png>, a still of the same window, gives its rounded corners.
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

from store import PREVIEW, THEMES, backdrop, shadow_onto

FPS = 30
FADE = 0.4


def parse(clip):
    path, _, times = clip.partition(":")
    start, _, end = times.partition(":")
    return path, float(start or 0), float(end) if end else None


def length(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                         capture_output=True, check=True).stdout
    return float(json.loads(out)["format"]["duration"])


def frames(path, start, end, size):
    """The clip's frames at 30 fps, scaled to cover `size` and cropped to it, as RGB bytes."""
    w, h = size
    end = end if end is not None else length(path)
    command = ["ffmpeg", "-v", "error", "-ss", str(start), "-to", str(end), "-i", path, "-vf",
               f"fps={FPS},scale={w}:{h}:force_original_aspect_ratio=increase:flags=lanczos,crop={w}:{h}",
               "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    with subprocess.Popen(command, stdout=subprocess.PIPE) as p:
        while True:
            data = p.stdout.read(w * h * 3)
            if len(data) < w * h * 3:
                break
            yield data


class Window:
    """Puts the Mac window's frames on the backdrop, centred, with its shadow and corners. While a window is recorded,
    macOS draws a badge over its traffic lights; each frame gets them back from a still of the window taken at the end
    of a scene (the recording's name with .png), made as light or dark as the frame around the badge. A sheet or ⌘K
    dims the window while it is open, and a still has it either open or closed, so the still is the one that needs the
    least of that: the same scene's if it is near enough, else another scene's, else <window.png>."""

    CORNER = (0, 0, 200, 110)  # the traffic lights, in pixels of a capture at 2x
    BADGE = (25, 25, 175, 80)  # what the badge covers; the rest of the corner, less its rounded tip, is compared

    def __init__(self, still, theme, size):
        W, H = size
        window = Image.open(still).convert("RGBA")
        self.still = still
        self.capture_width = window.width
        k = min(1640 / window.width, 940 / window.height)
        self.size = (round(window.width * k) // 2 * 2, round(window.height * k) // 2 * 2)
        mask = window.getchannel("A").resize(self.size, Image.LANCZOS)
        shape = Image.new("RGBA", self.size, (0, 0, 0, 255))
        shape.putalpha(mask)
        self.pos = ((W - self.size[0]) // 2, (H - self.size[1]) // 2 - 8)
        self.base = shadow_onto(backdrop(size, theme).convert("RGBA"), shape, self.pos, theme)
        self.mask = mask

    def frames(self, path, start, end, others=()):
        stills = [os.path.splitext(each)[0] + ".png" for each in (path, *others)] + [self.still]
        k = self.size[0] / self.capture_width
        corners = []
        for name in dict.fromkeys(p for p in stills if os.path.exists(p)):
            corner = Image.open(name).convert("RGB").crop(self.CORNER)
            corner = corner.resize((round(corner.width * k), round(corner.height * k)), Image.LANCZOS)
            corners.append(np.asarray(corner).astype(float))
        h, w = corners[0].shape[:2]
        around = np.ones((h, w), bool)
        x0, y0, x1, y1 = (round(v * k) for v in self.BADGE)
        around[y0:y1, x0:x1] = False
        around[:round(40 * k), :round(40 * k)] = False
        levels = [corner[around].mean(axis=0) for corner in corners]
        for data in frames(path, start, end, self.size):
            frame = Image.frombuffer("RGB", self.size, data).copy()
            level = np.asarray(frame.crop((0, 0, w, h))).astype(float)[around].mean(axis=0)
            gains = [level / np.maximum(each, 1) for each in levels]
            change = [np.abs(np.log(gain)).sum() for gain in gains]
            best = next(i for i, each in enumerate(change) if each <= min(change) + 0.15)
            patch = np.clip(corners[best] * gains[best], 0, 255).astype(np.uint8)
            frame.paste(Image.fromarray(patch), (0, 0))
            img = self.base.copy()
            img.paste(frame, self.pos, self.mask)
            yield img.convert("RGB").tobytes()


def edit(out, device, clips, window=None):
    size = PREVIEW[device]
    w, h = size
    n = round(FADE * FPS)
    encoder = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(FPS),
         "-i", "-", "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
         "-map", "0:v", "-map", "1:a", "-shortest",
         "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-preset", "slow", "-x264-params", "nal-hrd=cbr",
         "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "22M", "-pix_fmt", "yuv420p", "-r", str(FPS),
         "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", out],
        stdin=subprocess.PIPE)
    before = []  # the last frames of the clip before, held back to fade into this one
    count = 0
    for index, clip in enumerate(clips):
        path, start, end = parse(clip)
        others = [parse(each)[0] for each in clips if each != clip]
        source = window.frames(path, start, end, others) if window else frames(path, start, end, size)
        last = index == len(clips) - 1
        held = []
        for k, data in enumerate(source):
            if k < len(before):
                a = (k + 1) / (len(before) + 1)
                data = Image.blend(Image.frombuffer("RGB", size, before[k]), Image.frombuffer("RGB", size, data),
                                   a).tobytes()
            if last:
                encoder.stdin.write(data)
                count += 1
            else:
                held.append(data)
                if len(held) > n:
                    encoder.stdin.write(held.pop(0))
                    count += 1
        before = held
    encoder.stdin.close()
    encoder.wait()
    seconds = count / FPS
    print(f"{out}: {w} x {h}, {seconds:.1f} s")
    if not 15 <= seconds <= 30:
        sys.exit(f"{out} is {seconds:.1f} s long; the App Store takes 15 to 30.")


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 3 or args[1] not in PREVIEW:
        sys.exit("usage: preview.py <out.mp4> iphone|ipad <clip>… | preview.py <out.mp4> mac light|dark <window.png> <clip>…")
    out, device = args[0], args[1]
    if device == "mac":
        if args[2] not in THEMES:
            sys.exit("mac previews need light or dark")
        edit(out, device, args[4:], Window(args[3], args[2], PREVIEW["mac"]))
    else:
        edit(out, device, args[2:])
