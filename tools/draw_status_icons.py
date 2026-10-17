"""Draw the settings page's connection-status glyphs and write them as BLPs.

Original vector artwork (no source images): a check, a cross and a pause sign
inside a circle, and an exclamation mark inside a triangle. White only, so the
settings page colours them with SetVertexColor (green, red, grey, amber). The
badge is a faint disc with a solid ring, the glyph is solid, and a thin soft
black edge keeps them readable on Waypoint UI's grey containers at 16 px.

    python tools/draw_status_icons.py

Writes Art/Icons/StatusCheck.blp, StatusCross.blp, StatusPause.blp and
StatusWarning.blp (64x64, BLP2 raw BGRA like the other icons). New texture
files need a client restart, not just /reload.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_icons import write_blp  # noqa: E402

CANVAS = 64
SCALE = 8                      # supersampling factor
S = CANVAS * SCALE
DISC_ALPHA = 70                # faint fill inside the ring
RING = 5.0                     # ring width at 64 px
STROKE = 7.0                   # glyph stroke width at 64 px
EDGE_ALPHA = 0.55              # soft black edge, like Waypoint UI's icons
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def px(v):
    return v * SCALE


def circle_badge(draw):
    pad = px(4)
    draw.ellipse((pad, pad, S - pad, S - pad), fill=(255, 255, 255, DISC_ALPHA))
    draw.ellipse((pad, pad, S - pad, S - pad), outline=(255, 255, 255, 255), width=int(px(RING)))


def line(draw, points, width=STROKE):
    pts = [(px(x), px(y)) for x, y in points]
    draw.line(pts, fill=(255, 255, 255, 255), width=int(px(width)), joint="curve")
    r = px(width) / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))


def check(draw):
    circle_badge(draw)
    line(draw, [(19.5, 33.5), (28, 42), (44.5, 23.5)])


def cross(draw):
    circle_badge(draw)
    line(draw, [(22.5, 22.5), (41.5, 41.5)])
    line(draw, [(41.5, 22.5), (22.5, 41.5)])


def pause(draw):
    circle_badge(draw)
    line(draw, [(26.5, 22), (26.5, 42)])
    line(draw, [(37.5, 22), (37.5, 42)])


def warning(draw):
    top, left, right = (32, 9.5), (6.5, 54.5), (57.5, 54.5)
    tri = [(px(x), px(y)) for x, y in (top, left, right)]
    draw.polygon(tri, fill=(255, 255, 255, DISC_ALPHA))
    draw.line(tri + [tri[0]], fill=(255, 255, 255, 255), width=int(px(RING)), joint="curve")
    line(draw, [(32, 25), (32, 37.5)], 6.5)
    r = px(3.8)
    cx, cy = px(32), px(46.5)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))


def render(shape):
    big = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shape(ImageDraw.Draw(big))
    glyph = big.resize((CANVAS, CANVAS), Image.LANCZOS)
    alpha = glyph.getchannel("A")
    edge = alpha.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    edge = edge.point(lambda v: int(v * EDGE_ALPHA))
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.putalpha(edge)
    out.alpha_composite(glyph)
    return out


def main():
    target = os.path.join(ROOT, "Art", "Icons")
    for name, shape in (("StatusCheck", check), ("StatusCross", cross),
                        ("StatusPause", pause), ("StatusWarning", warning)):
        path = os.path.join(target, name + ".blp")
        write_blp(render(shape), path)
        print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
