#!/usr/bin/env python3
"""Key, split and pad the nano-banana cast sheets into the board sprites.

Two `gemini-2.5-flash-image` renders are committed under `scripts/art/source/`,
both anchored on the shipped `data/soldier_red_front.png` master so the whole
cast is one style:

  crafter_cast_sheet.png    cog(south) | cow | zombie | skeleton
  crafter_cog_facings.png   cog(north) | cog(east) | cog(south) | (discarded)

Gemini does not return alpha and the "pure green" backdrop comes back as *some*
green with a tinted edge, so the backdrop colour is taken as the MEDIAN of the
border and flood-filled from the border inwards — green accents inside a
character survive. The row is then split on empty columns, each part padded to
a square and resized to 128 px.

The WEST facing is the EAST render mirrored horizontally: the fourth slot of
the facings sheet came back as a second skeleton, and a mirror of the same
render keeps the style identical across all four facings, which is the whole
point of one sheet per family.

    python3 scripts/art/split_cog_sheet.py

Outputs (committed; CI does not regenerate art):
  data/art/cog_north.png  cog_east.png  cog_south.png  cog_west.png
  data/art/cow.png  zombie.png  skeleton.png

`src/crafter/global.nim` still owns the TERRAIN bake (grass, sand, water,
stone, path, tree, ore seams, lava, table, furnace, saplings) — those are pixie
composites over the starter's shipped `arena_floor.png` and `wall_*.jpg`, and
this script does not produce them.
"""
import os
import sys
from collections import deque

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "scripts", "art", "source")
OUT = os.path.join(ROOT, "data", "art")
SIZE = 128
TOLERANCE = 60
TIGHT = 48

SHEETS = [
    ("crafter_cog_facings.png", ["cog_north", "cog_east", "cog_south", None]),
    ("crafter_cast_sheet.png", [None, "cow", "zombie", "skeleton"]),
]


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def backdrop(image):
    """The median border colour: corners sometimes carry a smudge."""
    w, h = image.size
    pixels = []
    for x in range(w):
        pixels.append(image.getpixel((x, 0)))
        pixels.append(image.getpixel((x, h - 1)))
    for y in range(h):
        pixels.append(image.getpixel((0, y)))
        pixels.append(image.getpixel((w - 1, y)))
    return tuple(median([p[i] for p in pixels]) for i in range(3))


def key(image):
    """Flood-fill the backdrop from the border so inner greens survive."""
    image = image.convert("RGBA")
    w, h = image.size
    target = backdrop(image)
    pixels = image.load()
    seen = bytearray(w * h)
    queue = deque()

    def near(p):
        return (abs(p[0] - target[0]) + abs(p[1] - target[1]) +
                abs(p[2] - target[2])) <= TOLERANCE * 3

    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        if not near(pixels[x, y]):
            continue
        seen[y * w + x] = 1
        pixels[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    ## A second, TIGHT global pass. The border flood cannot reach backdrop
    ## enclosed by a silhouette — the gap between the cog's wheels and its
    ## chassis is a hole full of chroma — so any pixel that is still within a
    ## few units of the EXACT backdrop colour is keyed too. The tolerance is
    ## deliberately a fraction of the flood's: the zombie's sickly green is
    ## far enough from the backdrop to survive it, and a test render of all
    ## seven chips is how that was checked.
    for y in range(h):
        for x in range(w):
            pixel = pixels[x, y]
            if pixel[3] == 0:
                continue
            if (abs(pixel[0] - target[0]) + abs(pixel[1] - target[1]) +
                    abs(pixel[2] - target[2])) <= TIGHT:
                pixels[x, y] = (0, 0, 0, 0)
    return image


def columns(image):
    """Split on runs of fully transparent columns."""
    w, h = image.size
    alpha = image.split()[3].load()
    filled = []
    for x in range(w):
        for y in range(h):
            if alpha[x, y] > 8:
                filled.append(x)
                break
    spans = []
    start = None
    previous = None
    for x in filled:
        if start is None:
            start = x
        elif x - previous > 12:
            spans.append((start, previous))
            start = x
        previous = x
    if start is not None:
        spans.append((start, previous))
    return spans


def rows(image, x0, x1):
    alpha = image.split()[3].load()
    top, bottom = None, None
    for y in range(image.size[1]):
        for x in range(x0, x1 + 1):
            if alpha[x, y] > 8:
                if top is None:
                    top = y
                bottom = y
                break
    return top, bottom


def square(image, box):
    part = image.crop(box)
    side = max(part.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(part, ((side - part.size[0]) // 2, (side - part.size[1]) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    written = []
    for sheet, names in SHEETS:
        path = os.path.join(SOURCE, sheet)
        if not os.path.exists(path):
            print("missing source sheet: %s" % path, file=sys.stderr)
            return 1
        image = key(Image.open(path))
        spans = columns(image)
        if len(spans) != len(names):
            print("%s: found %d sprites, expected %d"
                  % (sheet, len(spans), len(names)), file=sys.stderr)
            return 1
        for (x0, x1), name in zip(spans, names):
            if name is None:
                continue
            top, bottom = rows(image, x0, x1)
            chip = square(image, (x0, top, x1 + 1, bottom + 1))
            chip.save(os.path.join(OUT, name + ".png"))
            written.append(name)
    east = Image.open(os.path.join(OUT, "cog_east.png"))
    east.transpose(Image.FLIP_LEFT_RIGHT).save(os.path.join(OUT, "cog_west.png"))
    written.append("cog_west (mirror of cog_east)")
    print("wrote: " + ", ".join(written))
    return 0


if __name__ == "__main__":
    sys.exit(main())
