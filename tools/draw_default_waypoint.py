"""Draw the source artwork for the DefaultWaypoint marker icon.

The silhouette is the inner arrow of the RestedXP Waypoint logo (rounded tip,
inward V notch at the bottom), redrawn for icon size rather than copied:

  * slightly narrower than the logo and with a slightly deeper notch, so it
    still reads as an arrow (not a rounded triangle) at the 13-20 px Waypoint
    UI draws context icons;
  * separate fillet radii for the tip, the bottom corners and the notch, so
    the corners stay clean instead of turning into blobs when scaled down;
  * neutral, light grey only. Like the service icons it is tinted in game:
    the bridge sends it with requestRecolor, so Waypoint UI desaturates it
    and colours it with the marker colour. The logo's purple/blue halves are
    kept only as a subtle brightness split (left half a little darker), which
    survives any tint.

No outline is drawn here; tools/build_icons.py adds the family's thin, soft
black edge, applies the brightness curve and writes the 64x64 BLP:

    python tools/draw_default_waypoint.py
    python tools/build_icons.py tools/icon_sources
"""
import math
import os
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SUPERSAMPLE = 4
# Geometry, in units of the sharp (unrounded) arrow's height.
WIDTH = 0.93          # sharp width (the logo's is about 1.06); 40x40 px at glyph 40, so it centres on x = 32
NOTCH = 0.31          # notch depth from the bottom edge; the logo's is about 0.24
TIP_RADIUS = 0.10
CORNER_RADIUS = 0.075
NOTCH_RADIUS = 0.035
# Body brightness before build_icons' tint curve (TINT_LOW 28, TINT_HIGH 200,
# gamma 0.5): 255 stays white, 150 becomes about 215 (84%).
RIGHT_LEVEL = 255
LEFT_LEVEL = 150


def fillet(points, radii, steps=48):
    """Polygon outline with every corner replaced by a circular arc of its own
    radius (convex corners round outward, the concave notch inward)."""
    out = []
    n = len(points)
    for i, p in enumerate(points):
        a, b = points[i - 1], points[(i + 1) % n]
        ux, uy = a[0] - p[0], a[1] - p[1]
        vx, vy = b[0] - p[0], b[1] - p[1]
        lu, lv = math.hypot(ux, uy), math.hypot(vx, vy)
        ux, uy, vx, vy = ux / lu, uy / lu, vx / lv, vy / lv
        phi = math.acos(max(-1.0, min(1.0, ux * vx + uy * vy)))
        r = radii[i]
        t = r / math.tan(phi / 2)
        bx, by = ux + vx, uy + vy
        lb = math.hypot(bx, by)
        cx = p[0] + bx / lb * r / math.sin(phi / 2)
        cy = p[1] + by / lb * r / math.sin(phi / 2)
        t1 = (p[0] + ux * t, p[1] + uy * t)
        t2 = (p[0] + vx * t, p[1] + vy * t)
        a1 = math.atan2(t1[1] - cy, t1[0] - cx)
        a2 = math.atan2(t2[1] - cy, t2[0] - cx)
        delta = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi  # the short way round
        for k in range(steps + 1):
            angle = a1 + delta * k / steps
            out.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return out


def arrow_outline():
    # tip, right corner, notch, left corner (y grows downwards)
    sharp = [(0.0, 0.0), (WIDTH / 2, 1.0), (0.0, 1.0 - NOTCH), (-WIDTH / 2, 1.0)]
    return fillet(sharp, [TIP_RADIUS, CORNER_RADIUS, NOTCH_RADIUS, CORNER_RADIUS])


def draw():
    big = SIZE * SUPERSAMPLE
    scale = big * 0.8
    origin = (big / 2.0, big * 0.1)
    pts = [(origin[0] + x * scale, origin[1] + y * scale) for x, y in arrow_outline()]
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    shade = Image.new("L", (big, big), LEFT_LEVEL)
    shade.paste(RIGHT_LEVEL, (big // 2, 0, big, big))
    art = Image.merge("RGBA", (shade, shade, shade, mask))
    # Downscale with premultiplied alpha so edges get no dark fringe.
    return art.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "icon_sources", "DefaultWaypoint.png")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    draw().save(target)
    print("wrote", target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
