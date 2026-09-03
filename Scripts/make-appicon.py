#!/usr/bin/env python3
"""Draws the app icon at 1024x1024 into App/Assets.xcassets/AppIcon.appiconset.

Drawn rather than resized: the reference was 286x298, and an app icon is
1024x1024 — upscaling that would be visibly soft on a home screen.

Two rules this follows that are easy to get wrong:
  * The image is a FULL SQUARE with no rounded corners and no transparency.
    iOS applies its own corner mask; baking one in gives a double-rounded
    badge with dark corners showing through.
  * Everything is drawn at 4x and downsampled, which is the cheapest way to
    get clean anti-aliased curves out of PIL.

    python3 Scripts/make-appicon.py
"""
from PIL import Image, ImageDraw
import os

S = 1024
F = 4                      # supersampling factor
W = S * F

BG_TOP = (214, 216, 219)   # silver, lit from the top-left
BG_BOTTOM = (150, 153, 158)
BODY = (233, 234, 236)     # the remote's face
BODY_EDGE = (120, 123, 128)
GLYPH = (96, 99, 104)      # engraved marks

img = Image.new("RGB", (W, W), BG_TOP)
d = ImageDraw.Draw(img)

# Diagonal-ish vertical gradient: brushed metal reads as light at the top.
for y in range(W):
    t = y / W
    d.line(
        [(0, y), (W, y)],
        fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
    )

# The remote body: a tall rounded rect, centred, roughly a third of the width.
bw, bh = int(W * 0.30), int(W * 0.62)
bx, by = (W - bw) // 2, (W - bh) // 2
d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=int(bw * 0.22),
                    fill=BODY, outline=BODY_EDGE, width=int(F * 3.5))

cx = W // 2
stroke = int(F * 7)

# Power glyph: a ring with a gap at the top, plus a stem through it.
pr = int(W * 0.045)
py = by + int(bh * 0.13)
d.arc([cx - pr, py - pr, cx + pr, py + pr], start=-60, end=240,
      fill=GLYPH, width=stroke)
d.line([(cx, py - int(pr * 1.25)), (cx, py + int(pr * 0.15))],
       fill=GLYPH, width=stroke)

# D-pad: an outlined cross, the one shape that says "remote" at 40px.
arm, thick = int(W * 0.075), int(W * 0.030)
dy = by + int(bh * 0.36)
cross = [
    (cx - thick, dy - arm), (cx + thick, dy - arm),
    (cx + thick, dy - thick), (cx + arm, dy - thick),
    (cx + arm, dy + thick), (cx + thick, dy + thick),
    (cx + thick, dy + arm), (cx - thick, dy + arm),
    (cx - thick, dy + thick), (cx - arm, dy + thick),
    (cx - arm, dy - thick), (cx - thick, dy - thick),
]
# Fill only — no `outline=`. PIL draws that as a hairline that collides with
# the thick stroke below and leaves a visible notch at the start vertex.
d.polygon(cross, fill=BODY)
d.line(cross + [cross[0], cross[1]], fill=GLYPH, width=stroke, joint="curve")

# Two small marks below: a round button and a plus, as on the reference.
my = by + int(bh * 0.55)
gap = int(W * 0.055)
rr = int(W * 0.016)
d.ellipse([cx - gap - rr, my - rr, cx - gap + rr, my + rr],
          outline=GLYPH, width=stroke)
pl = int(W * 0.020)
d.line([(cx + gap - pl, my), (cx + gap + pl, my)], fill=GLYPH, width=stroke)
d.line([(cx + gap, my - pl), (cx + gap, my + pl)], fill=GLYPH, width=stroke)

icon = img.resize((S, S), Image.LANCZOS)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "App", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(out, exist_ok=True)
icon.save(os.path.join(out, "icon-1024.png"))
print("wrote", os.path.join(out, "icon-1024.png"), icon.size, icon.mode)
