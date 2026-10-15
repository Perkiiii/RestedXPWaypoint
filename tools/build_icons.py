"""Build RestedXP Waypoint marker icons in Waypoint UI's glyph style.

Waypoint UI's context icons (WaypointUI/Art/Icons/*.blp) are glyphs only:
a 64x64 transparent canvas, the symbol filling about 54x54 with a ~5 px margin,
and a soft pure-black outline. Waypoint UI draws the diamond frame around them.
They are stored as BLP2, colour encoding 3 (raw BGRA), 8-bit alpha, no mipmaps:
a 148-byte header, an unused 1024-byte palette, then the pixels.

This script turns small source icons (e.g. WoW's 32x32 minimap tracking icons)
into the same layout and format.

Usage:
    python tools/build_icons.py <source-folder> [<output-folder>]

Source files are matched by name (see ICONS); any format Pillow reads works.
Output defaults to Art/Icons next to this script's parent folder.
"""
import os
import struct
import sys

from PIL import Image, ImageFilter

CANVAS = 64           # Waypoint UI icon size
GLYPH = 52            # glyph box before the outline (~54 with it, like Waypoint UI)
PEEL = 2              # dark rim rings removed from the source before scaling
DARK = 70             # luminance below which an edge pixel counts as rim
OUTLINE = 1           # added outline thickness in pixels (thin, like Waypoint UI)
OUTLINE_ALPHA = 0.55  # outline opacity
BLUR = 0.4            # outline feathering (Gaussian radius)
# Tint-ready output. Waypoint UI desaturates and tints the icon of a custom
# waypoint that has a colour (r/g/b forces recolor on), so what is drawn is
# brightness x marker colour. The glyph is therefore stored as brightness only,
# with a curve that keeps the dark outline and lifts the body towards white, so
# the tinted icon is bright and readable in its service colour.
TINT_READY = True
TINT_LOW = 28         # brightness at/below this stays black (outline)
TINT_HIGH = 200       # brightness at/above this becomes white
TINT_GAMMA = 0.5      # lifts mid-tones

# output name -> accepted source file stems (case-insensitive)
ICONS = {
    "FlightMaster": ["flight master", "flightmaster"],
    "ClassTrainer": ["class trainer", "classtrainer"],
    "ProfessionTrainer": ["profession trainer", "professiontrainer"],
    "FoodAndDrink": ["food and drink", "foodanddrink", "food"],
    "Repair": ["repair", "repairicon"],
    "Innkeeper": ["inn", "innkeeper"],
    "StableMaster": ["stable", "stable master", "stablemaster"],
    "Bags": ["bankbags", "bank bags", "bags", "bank", "vendor"],  # general vendor + banker
    "Grind": ["grind"],
}

# Per-icon tweaks. strip_glow: remove the light outer halo some minimap icons
# have (e.g. the crossed swords); brighten: lift a dim glyph that relied on
# that halo for contrast; peel: override PEEL (the swords' outline is part of
# the glyph, so it is kept).
ICON_OPTIONS = {
    "Grind": {"strip_glow": True, "brighten": 1.8, "peel": 0},
}


def peel_rim(im, rings):
    """Remove dark rim pixels that touch transparency, one ring per pass.

    WoW's minimap tracking icons carry a baked-in black rim; scaled up it reads
    much thicker than Waypoint UI's thin glyph edge.
    """
    w, h = im.size
    for _ in range(rings):
        px = im.load()
        clear = []
        for y in range(h):
            for x in range(w):
                r, g, b, a = px[x, y]
                if a == 0 or (r * 299 + g * 587 + b * 114) / 1000 >= DARK:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if nx < 0 or ny < 0 or nx >= w or ny >= h or px[nx, ny][3] < 24:
                        clear.append((x, y))
                        break
        for x, y in clear:
            px[x, y] = (0, 0, 0, 0)
    return im


def strip_glow(im, outline_luminance=60, outline_alpha=200):
    """Remove an outer glow: flood-fill from the canvas border through every
    pixel that is not part of the dark outline, and clear it. The glyph inside
    the outline is untouched."""
    from collections import deque
    px = im.load()
    w, h = im.size

    def is_outline(x, y):
        r, g, b, a = px[x, y]
        return a >= outline_alpha and (r * 299 + g * 587 + b * 114) / 1000 < outline_luminance

    seen = set()
    queue = deque((x, y) for x in range(w) for y in (0, h - 1)) + deque((x, y) for y in range(h) for x in (0, w - 1))
    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or not (0 <= x < w and 0 <= y < h) or is_outline(x, y):
            continue
        seen.add((x, y))
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    for x, y in seen:
        px[x, y] = (0, 0, 0, 0)
    return im


def brighten(im, factor):
    """Lift a dim glyph's colours (keeps alpha)."""
    from PIL import ImageEnhance
    rgb = ImageEnhance.Brightness(im.convert("RGB")).enhance(factor)
    rgb.putalpha(im.getchannel("A"))
    return rgb


def tint_ready(im):
    """Brightness-only version of the glyph for Waypoint UI's tint (see TINT_READY)."""
    from PIL import ImageOps

    def curve(v):
        x = max(0.0, min(1.0, (v - TINT_LOW) / float(TINT_HIGH - TINT_LOW)))
        return int(round(255 * (x ** TINT_GAMMA)))

    gray = ImageOps.grayscale(im.convert("RGB")).point(curve)
    out = Image.merge("RGB", (gray, gray, gray))
    out.putalpha(im.getchannel("A"))
    return out


def make_glyph(source, options=None):
    """Return a 64x64 RGBA glyph in Waypoint UI's style."""
    options = options or {}
    im = source.convert("RGBA")
    if options.get("strip_glow"):
        im = strip_glow(im)
    if options.get("brighten"):
        im = brighten(im, options["brighten"])
    im = peel_rim(im, options.get("peel", PEEL))
    bbox = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox:
        im = im.crop(bbox)
    scale = GLYPH / max(im.size)
    size = (max(1, round(im.size[0] * scale)), max(1, round(im.size[1] * scale)))
    im = im.resize(size, Image.LANCZOS)

    glyph = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    glyph.alpha_composite(im, ((CANVAS - size[0]) // 2, (CANVAS - size[1]) // 2))

    if OUTLINE <= 0 or OUTLINE_ALPHA <= 0:
        # (MaxFilter(1) crashes Pillow, so skip the outline entirely)
        return tint_ready(glyph) if options.get("tint_ready", TINT_READY) else glyph

    # Soft black outline: dilate the alpha, feather it, keep it under the glyph.
    alpha = glyph.getchannel("A")
    dilated = alpha.filter(ImageFilter.MaxFilter(OUTLINE * 2 + 1))
    if BLUR > 0:
        dilated = dilated.filter(ImageFilter.GaussianBlur(BLUR))
    dilated = dilated.point(lambda v: int(v * OUTLINE_ALPHA))
    outline = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    outline.putalpha(dilated)
    outline.alpha_composite(glyph)
    return tint_ready(outline) if options.get("tint_ready", TINT_READY) else outline


def write_blp(image, path):
    """Write BLP2, encoding 3 (raw BGRA), 8-bit alpha, no mipmaps, like Waypoint UI."""
    w, h = image.size
    pixels = image.convert("RGBA").tobytes("raw", "BGRA")
    header_size = 148
    palette_size = 1024
    offsets = [header_size + palette_size] + [0] * 15
    sizes = [len(pixels)] + [0] * 15
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<IBBBBII", 1, 3, 8, 8, 0, w, h))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(b"\x00" * palette_size)
        f.write(pixels)


def read_blp(path):
    """Read a BLP2 encoding-3 file (for verification)."""
    data = open(path, "rb").read()
    assert data[:4] == b"BLP2"
    _, encoding, _, _, _, w, h = struct.unpack_from("<IBBBBII", data, 4)
    assert encoding == 3
    offset = struct.unpack_from("<16I", data, 20)[0]
    return Image.frombytes("RGBA", (w, h), data[offset:offset + w * h * 4], "raw", "BGRA")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    source_dir = sys.argv[1]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "Art", "Icons")
    os.makedirs(out_dir, exist_ok=True)

    files = {os.path.splitext(f)[0].lower(): os.path.join(source_dir, f) for f in os.listdir(source_dir)}
    missing = []
    for name, stems in ICONS.items():
        source = next((files[s] for s in stems if s in files), None)
        if not source:
            missing.append(name)
            continue
        glyph = make_glyph(Image.open(source), ICON_OPTIONS.get(name))
        target = os.path.join(out_dir, name + ".blp")
        write_blp(glyph, target)
        assert read_blp(target).tobytes() == glyph.tobytes()
        print("wrote", target)
    if missing:
        print("no source found for:", ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
