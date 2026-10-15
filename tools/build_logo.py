"""Build the RestedXP Waypoint logo texture for the settings page.

Two kinds of source artwork are handled:
  * With its own transparency (RGBA with transparent pixels, the current
    logo): that alpha is used as-is. The image is cropped to its visible
    artwork (square, centred, small margin) so the logo fills the texture,
    and downscaled in premultiplied alpha so edges get no dark fringe.
  * Drawn on a near-black background without transparency: "screen" keying
    treats it as light added over black, so each pixel's alpha is its
    brightest channel (after removing the background floor) and its colour is
    un-premultiplied; a glow then fades into the panel instead of showing a
    black square. Not suitable for art with dark parts inside the logo.

The result is written as a 128x128 BLP2, encoding 3 (raw BGRA), 8-bit alpha,
no mipmaps, with the same writer as the marker icons. The settings page draws
it at 80x80 (SettingsPanel.lua LOGO_SIZE), so it stays sharp at large UI scales.

Usage:
    python tools/build_logo.py [<source-image>] [<output.blp>]

Defaults: tools/logo_source.png -> Art/Logo.blp
"""
import os
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_icons import read_blp, write_blp  # noqa: E402

SIZE = 128
BACKGROUND_FLOOR = 12  # keyed sources: background about (8, 9, 11); below this = empty
MARGIN = 0.02          # transparent sources: margin around the visible artwork
DISPLAY = 80           # on-screen size, for the preview


def key_to_alpha(image):
    """Light-over-black RGB -> straight RGBA."""
    out = Image.new("RGBA", image.size)
    src = image.load()
    dst = out.load()
    floor = BACKGROUND_FLOOR
    for y in range(image.size[1]):
        for x in range(image.size[0]):
            r, g, b = src[x, y][:3]
            r, g, b = max(0, r - floor), max(0, g - floor), max(0, b - floor)
            peak = max(r, g, b)
            if peak == 0:
                dst[x, y] = (0, 0, 0, 0)
                continue
            scale = 255.0 / peak
            alpha = round(peak * 255.0 / (255 - floor))
            dst[x, y] = (min(255, round(r * scale)), min(255, round(g * scale)),
                         min(255, round(b * scale)), min(255, alpha))
    return out


def square_crop(image, box):
    left, top, right, bottom = box
    side = max(right - left, bottom - top)
    side = int(round(side * (1 + 2 * MARGIN)))
    cx, cy = (left + right) / 2.0, (top + bottom) / 2.0
    left, top = int(round(cx - side / 2.0)), int(round(cy - side / 2.0))
    canvas = Image.new(image.mode, (side, side), (0, 0, 0, 0))
    canvas.paste(image.crop((left, top, left + side, top + side)), (0, 0))
    return canvas


def from_alpha(image):
    """Transparent source: crop to the artwork, downscale premultiplied."""
    box = image.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox() or (0, 0) + image.size
    square = square_crop(image, box)
    return square.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")


def from_dark_background(image):
    """Opaque source on near-black: centre square, downscale, then key."""
    side = min(image.size)
    left, top = (image.size[0] - side) // 2, (image.size[1] - side) // 2
    image = image.crop((left, top, left + side, top + side))
    # Downscale while still premultiplied (light over black), then key.
    return key_to_alpha(image.resize((SIZE, SIZE), Image.LANCZOS))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "logo_source.png")
    target = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "Art", "Logo.blp")
    image = Image.open(source)
    rgba = image.convert("RGBA")
    if rgba.getchannel("A").getextrema()[0] < 255:
        logo = from_alpha(rgba)
    else:
        logo = from_dark_background(image.convert("RGB"))
    write_blp(logo, target)
    check = read_blp(target)
    assert check.size == (SIZE, SIZE)
    preview = os.path.join(tempfile.gettempdir(), "rxpw_logo_preview.png")
    sheet = Image.new("RGBA", (SIZE * 2, SIZE), (24, 22, 20, 255))  # settings-like dark background
    sheet.alpha_composite(check, (0, 0))
    offset = (SIZE - DISPLAY) // 2
    sheet.alpha_composite(check.resize((DISPLAY, DISPLAY), Image.LANCZOS), (SIZE + offset, offset))
    sheet.save(preview)
    print("wrote %s (%d bytes); preview %s" % (target, os.path.getsize(target), preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
