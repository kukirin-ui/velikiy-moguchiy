"""Ornament primitives in the manner of Ivan Bilibin's book frames: herbal vines, trefoils, rosettes, bands.

Everything returns SVG fragments as strings. Text is always converted to paths (fontTools), so the SVGs
render the same everywhere without the fonts installed.
"""
import math
from functools import lru_cache
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "mac/MacApp/VelikiyMoguchiy/Fonts"
SERIF = FONTS / "OldStandard-Regular.ttf"
SERIF_BOLD = FONTS / "OldStandard-Bold.ttf"
SERIF_ITALIC = FONTS / "OldStandard-Italic.ttf"
# fonts-cu (Aleksandr Andreev, Nikita Simmons; SIL OFL 1.1)
OGLAVIE = FONTS / "OglavieUnicode.otf"        # condensed vyaz of headings
MONOMAKH = FONTS / "MonomakhUnicode.otf"      # Old Russian book hand for short text
VERTOGRAD = Path(__file__).resolve().parent / "fonts/VertogradUnicode.otf"  # interlaced drop caps
GOLD_LIGHT = "#F2DC9A"
GOLD = "#C9A24A"
GOLD_DARK = "#8A6420"

# The owner's palette, taken from an aged-varnish painting.
PARCHMENT = "#E8DCC8"
LIGHT = "#CEBAA6"
UMBER = "#32261E"
INK = "#170F0C"
OCHRE = "#9A7A3C"
OLIVE = "#6B6433"
ROSE = "#B98A78"
SMOKE = "#87785C"
CINNABAR = "#9B3A2C"


def f(x):
    return f"{x:.2f}".rstrip("0").rstrip(".")


# ─── text as paths ──────────────────────────────────────────────────

@lru_cache(maxsize=None)
def _font(path):
    return TTFont(str(path))


def _kern(font, left, right):
    if "kern" not in font:
        return 0
    for table in font["kern"].kernTables:
        value = table.kernTable.get((left, right))
        if value:
            return value
    return 0


def text_width(text, font_path, size, tracking=0.0):
    font = _font(font_path)
    cmap, hmtx = font.getBestCmap(), font["hmtx"]
    scale = size / font["head"].unitsPerEm
    names = [cmap[ord(c)] for c in text]
    width = sum(hmtx[n][0] for n in names)
    width += sum(_kern(font, a, b) for a, b in zip(names, names[1:]))
    return width * scale + tracking * size * (len(text) - 1)


def text_path(text, font_path, size, x, y, anchor="start", tracking=0.0):
    """SVG path data for `text` with its baseline at y. anchor: start | middle | end."""
    font = _font(font_path)
    cmap, hmtx, glyphs = font.getBestCmap(), font["hmtx"], font.getGlyphSet()
    scale = size / font["head"].unitsPerEm
    width = text_width(text, font_path, size, tracking)
    pen_x = x - {"start": 0, "middle": width / 2, "end": width}[anchor]
    out = []
    names = [cmap[ord(c)] for c in text]
    for i, name in enumerate(names):
        pen = SVGPathPen(glyphs, ntos=lambda v: f(v))
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, pen_x, y)))
        out.append(pen.getCommands())
        advance = hmtx[name][0]
        if i + 1 < len(names):
            advance += _kern(font, name, names[i + 1])
        pen_x += advance * scale + tracking * size
    return " ".join(out)


def glyph_box(char, font_path, size):
    """(xmin, ymin, xmax, ymax) of one glyph in font units scaled to `size`, y up."""
    font = _font(font_path)
    from fontTools.pens.boundsPen import BoundsPen
    glyphs = font.getGlyphSet()
    pen = BoundsPen(glyphs)
    glyphs[font.getBestCmap()[ord(char)]].draw(pen)
    s = size / font["head"].unitsPerEm
    return tuple(v * s for v in pen.bounds)


# ─── vegetal motifs ─────────────────────────────────────────────────

def rot(px, py, cx, cy, a):
    c, s = math.cos(a), math.sin(a)
    return cx + (px - cx) * c - (py - cy) * s, cy + (px - cx) * s + (py - cy) * c


def leaf(cx, cy, length, width, angle):
    """A pointed leaf / petal from (cx, cy) toward `angle` (radians)."""
    tip = rot(cx + length, cy, cx, cy, angle)
    c1 = rot(cx + length * 0.45, cy - width, cx, cy, angle)
    c2 = rot(cx + length * 0.45, cy + width, cx, cy, angle)
    return (f"M{f(cx)},{f(cy)} Q{f(c1[0])},{f(c1[1])} {f(tip[0])},{f(tip[1])} "
            f"Q{f(c2[0])},{f(c2[1])} {f(cx)},{f(cy)}Z")


def trefoil(cx, cy, r, angle):
    """Three-lobed bud (трилистник) pointing toward `angle`."""
    parts = []
    for da, k in ((0, 1.0), (-0.75, 0.72), (0.75, 0.72)):
        parts.append(leaf(cx, cy, r * 1.6 * k, r * 0.62 * k, angle + da))
    return " ".join(parts)


def rosette(cx, cy, r, petals=8, fill_outer=OCHRE, fill_inner=CINNABAR, core=PARCHMENT, stroke=UMBER, sw=None):
    sw = sw if sw is not None else max(r * 0.06, 0.6)
    outer = " ".join(leaf(cx, cy, r, r * 0.42, 2 * math.pi * i / petals) for i in range(petals))
    inner = " ".join(leaf(cx, cy, r * 0.62, r * 0.26, 2 * math.pi * (i + 0.5) / petals) for i in range(petals))
    return (f'<path d="{outer}" fill="{fill_outer}" stroke="{stroke}" stroke-width="{f(sw)}" stroke-linejoin="round"/>'
            f'<path d="{inner}" fill="{fill_inner}" stroke="{stroke}" stroke-width="{f(sw * 0.8)}" stroke-linejoin="round"/>'
            f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r * 0.24)}" fill="{core}" stroke="{stroke}" stroke-width="{f(sw)}"/>'
            f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r * 0.09)}" fill="{stroke}"/>')


def curl(x, y, r, direction, up):
    """A spiral tendril starting at (x, y). direction ±1 = which way it rolls, up ±1 = which side."""
    pts = []
    turns = 1.35
    for i in range(0, 41):
        t = i / 40
        a = math.pi * 2 * turns * t
        rr = r * (1 - 0.78 * t)
        pts.append((x + direction * rr * math.sin(a), y - up * (r - rr * math.cos(a))))
    d = f"M{f(pts[0][0])},{f(pts[0][1])} " + " ".join(f"L{f(px)},{f(py)}" for px, py in pts[1:])
    return d


def vine_band(x, y, w, h, stem=OCHRE, leaf_fill=OCHRE, bud=PARCHMENT, stroke=UMBER, period=None, sw=None):
    """A horizontal running vine filling the box: a wavy stem, curls, leaves and trefoil buds."""
    period = period or h * 2.2
    n = max(1, round(w / period))
    p = w / n
    cy, amp = y + h / 2, h * 0.24
    sw = sw if sw is not None else max(h * 0.05, 0.8)
    d = [f"M{f(x)},{f(cy)}"]
    for i in range(n * 2):
        x0 = x + i * p / 2
        s = -1 if i % 2 == 0 else 1
        d.append(f"C{f(x0 + p * 0.16)},{f(cy + s * amp * 1.33)} {f(x0 + p * 0.34)},{f(cy + s * amp * 1.33)} {f(x0 + p / 2)},{f(cy)}")
    curls, leaves, buds, berries = [], [], [], []
    for i in range(n * 2):
        x0 = x + i * p / 2 + p / 4
        s = -1 if i % 2 == 0 else 1
        py = cy + s * amp
        rolls = 1 if i % 2 == 0 else -1
        curls.append(curl(x0, py, h * 0.3, rolls, -s))
        leaves.append(leaf(x0, py, h * 0.42, h * 0.15, -s * math.pi / 2 + rolls * 1.05))
        leaves.append(leaf(x0 - rolls * p * 0.14, cy + s * amp * 0.55, h * 0.3, h * 0.11, s * math.pi / 2 - rolls * 0.7))
        bx, by = x0 + rolls * p * 0.2, cy - s * h * 0.1
        buds.append(trefoil(bx, by, h * 0.14, s * math.pi / 2 + rolls * 0.35))
        cx_, cy_ = x0 - rolls * p * 0.22, cy - s * h * 0.28
        berries.append(f'<circle cx="{f(cx_)}" cy="{f(cy_)}" r="{f(h * 0.06)}"/>')
    parts = [f'<path d="{" ".join(d)}" fill="none" stroke="{stroke}" stroke-width="{f(sw * 3.2)}" stroke-linecap="round"/>',
             f'<path d="{" ".join(d)}" fill="none" stroke="{stem}" stroke-width="{f(sw * 1.9)}" stroke-linecap="round"/>',
             f'<path d="{" ".join(curls)}" fill="none" stroke="{stroke}" stroke-width="{f(sw * 2.4)}" stroke-linecap="round"/>',
             f'<path d="{" ".join(curls)}" fill="none" stroke="{stem}" stroke-width="{f(sw * 1.2)}" stroke-linecap="round"/>',
             f'<path d="{" ".join(leaves)}" fill="{leaf_fill}" stroke="{stroke}" stroke-width="{f(sw * 0.7)}"/>',
             f'<path d="{" ".join(buds)}" fill="{bud}" stroke="{stroke}" stroke-width="{f(sw * 0.7)}"/>',
             f'<g fill="{bud}" stroke="{stroke}" stroke-width="{f(sw * 0.6)}">{"".join(berries)}</g>']
    return "".join(parts)


def slim_vine(x, y, w, h, stem=OCHRE, leaf_fill=OLIVE, berry=CINNABAR, stroke=UMBER, sw=0.8):
    """A light running vine for thin rules: a gentle wave, alternating leaves, a berry at each crest."""
    period = h * 4.0
    n = max(1, round(w / period))
    p = w / n
    cy, amp = y + h / 2, h * 0.22
    d = [f"M{f(x)},{f(cy)}"]
    for i in range(n * 2):
        x0 = x + i * p / 2
        s = -1 if i % 2 == 0 else 1
        d.append(f"C{f(x0 + p * 0.16)},{f(cy + s * amp * 1.33)} {f(x0 + p * 0.34)},{f(cy + s * amp * 1.33)} {f(x0 + p / 2)},{f(cy)}")
    leaves, berries, tendrils = [], [], []
    for i in range(n * 2):
        x0 = x + i * p / 2 + p / 4
        s = -1 if i % 2 == 0 else 1
        py = cy + s * amp
        leaves.append(leaf(x0 - p * 0.06, py, h * 0.5, h * 0.17, s * math.pi / 2 - 0.55))
        leaves.append(leaf(x0 + p * 0.06, py, h * 0.42, h * 0.14, s * math.pi / 2 + 0.75))
        berries.append(f'<circle cx="{f(x0 + p * 0.2)}" cy="{f(cy - s * h * 0.22)}" r="{f(h * 0.1)}"/>')
        tendrils.append(curl(x0 - p * 0.2, cy - s * h * 0.12, h * 0.22, -1 if i % 2 == 0 else 1, -s))
    return (f'<path d="{" ".join(d)}" fill="none" stroke="{stem}" stroke-width="{f(sw * 1.6)}" stroke-linecap="round"/>'
            f'<path d="{" ".join(tendrils)}" fill="none" stroke="{stem}" stroke-width="{f(sw)}" stroke-linecap="round"/>'
            f'<path d="{" ".join(leaves)}" fill="{leaf_fill}" stroke="{stroke}" stroke-width="{f(sw * 0.5)}"/>'
            f'<g fill="{berry}" stroke="{stroke}" stroke-width="{f(sw * 0.5)}">{"".join(berries)}</g>')


def scroll_pair(cx, cy, w, h, color, sw, flip=False):
    """Two mirrored S-scrolls meeting at the centre: the classic headpiece flourish."""
    s = -1 if flip else 1
    out = []
    for side in (-1, 1):
        x1 = cx + side * w * 0.5
        d = (f"M{f(cx)},{f(cy)} C{f(cx + side * w * 0.18)},{f(cy - s * h * 0.55)} "
             f"{f(cx + side * w * 0.36)},{f(cy + s * h * 0.55)} {f(x1)},{f(cy)}")
        out.append(d)
        out.append(curl(x1, cy, h * 0.42, side, s))
    return f'<path d="{" ".join(out)}" fill="none" stroke="{color}" stroke-width="{f(sw)}" stroke-linecap="round"/>'


def tree(cx, bottom, top, width, stem=OCHRE, leaf_fill=OLIVE, flower=CINNABAR, stroke=UMBER, sw=2.0):
    """A vertical 'tree of life' growing upward: stem, paired curls with leaves, a rosette on top."""
    h = bottom - top
    parts = [f'<path d="M{f(cx)},{f(bottom)} L{f(cx)},{f(top + width * 0.5)}" stroke="{stem}" stroke-width="{f(sw * 1.8)}" stroke-linecap="round"/>']
    tiers = max(2, int(h / (width * 0.95)))
    curls, leaves, buds = [], [], []
    for i in range(tiers):
        y = bottom - (i + 0.6) * (h - width * 0.6) / tiers
        r = width * 0.32 * (1 - 0.25 * i / tiers)
        for side in (-1, 1):
            d = (f"M{f(cx)},{f(y)} C{f(cx + side * r * 0.6)},{f(y - r * 0.2)} {f(cx + side * r * 1.1)},{f(y - r * 0.9)} "
                 f"{f(cx + side * r * 1.2)},{f(y - r * 1.4)}")
            curls.append(d)
            curls.append(curl(cx + side * r * 1.2, y - r * 1.4, r * 0.5, -side, 1))
            leaves.append(leaf(cx, y, r * 1.1, r * 0.3, math.pi / 2 + side * 1.1))
            buds.append(trefoil(cx + side * r * 1.25, y - r * 0.35, r * 0.28, side * 0.3 if side > 0 else math.pi - 0.3))
    parts.append(f'<path d="{" ".join(curls)}" fill="none" stroke="{stem}" stroke-width="{f(sw)}" stroke-linecap="round"/>')
    parts.append(f'<path d="{" ".join(leaves)}" fill="{leaf_fill}" stroke="{stroke}" stroke-width="{f(sw * 0.5)}"/>')
    parts.append(f'<path d="{" ".join(buds)}" fill="{flower}" stroke="{stroke}" stroke-width="{f(sw * 0.5)}"/>')
    parts.append(rosette(cx, top + width * 0.42, width * 0.36, fill_outer=OCHRE, fill_inner=flower, sw=sw * 0.5))
    return "".join(parts)


def frame(x, y, w, h, band, band_fill=CINNABAR, vine=OCHRE, corner_fill=OLIVE, rule=OCHRE, stroke=UMBER, sw=None):
    """A Bilibin-style rectangular frame: outer and inner rules, a vine band, rosettes in corner squares."""
    sw = sw if sw is not None else max(band * 0.06, 0.8)
    ring = (f"M{f(x)},{f(y)} h{f(w)} v{f(h)} h{f(-w)}Z "
            f"M{f(x + band)},{f(y + band)} v{f(h - 2 * band)} h{f(w - 2 * band)} v{f(-(h - 2 * band))}Z")
    out = [f'<path d="{ring}" fill="{band_fill}" fill-rule="evenodd"/>',
           f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" fill="none" stroke="{stroke}" stroke-width="{f(sw * 2)}"/>']
    inner = 0.16 * band
    bh = band - 2 * inner
    # horizontal runs
    for yy in (y + inner, y + h - band + inner):
        out.append(vine_band(x + band, yy, w - 2 * band, bh, stem=vine, leaf_fill=vine, bud=PARCHMENT, stroke=stroke, sw=sw))
    # vertical runs: draw a horizontal band and rotate it
    for xx in (x, x + w - band):
        g = vine_band(0, 0, h - 2 * band, bh, stem=vine, leaf_fill=vine, bud=PARCHMENT, stroke=stroke, sw=sw)
        out.append(f'<g transform="translate({f(xx + inner)},{f(y + band)}) rotate(90 0 0) translate(0,{f(-bh)})">{g}</g>')
    for cx, cy in ((x, y), (x + w - band, y), (x, y + h - band), (x + w - band, y + h - band)):
        out.append(f'<rect x="{f(cx)}" y="{f(cy)}" width="{f(band)}" height="{f(band)}" fill="{corner_fill}" stroke="{stroke}" stroke-width="{f(sw * 1.4)}"/>')
        out.append(rosette(cx + band / 2, cy + band / 2, band * 0.4, sw=sw * 0.7))
    # rules
    out.append(f'<rect x="{f(x + band)}" y="{f(y + band)}" width="{f(w - 2 * band)}" height="{f(h - 2 * band)}" fill="none" stroke="{rule}" stroke-width="{f(sw * 2.4)}"/>')
    out.append(f'<rect x="{f(x + band - sw * 2)}" y="{f(y + band - sw * 2)}" width="{f(w - 2 * band + sw * 4)}" height="{f(h - 2 * band + sw * 4)}" fill="none" stroke="{stroke}" stroke-width="{f(sw)}"/>')
    return "".join(out)


def gold_gradient(gid="gold", angle=90):
    """Gold leaf: a bright band across a warm gradient."""
    return (f'<linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1" gradientTransform="rotate({angle - 90} .5 .5)">'
            f'<stop offset="0" stop-color="{GOLD_LIGHT}"/><stop offset="0.38" stop-color="{GOLD}"/>'
            f'<stop offset="0.55" stop-color="#E7C878"/><stop offset="0.8" stop-color="{GOLD_DARK}"/>'
            f'<stop offset="1" stop-color="#B08A3A"/></linearGradient>')


def svg(w, h, body, defs="", extra=""):
    for key, art in _KRIN_DEFS.items():
        if f'href="#{key}"' in body:
            defs += f'<g id="{key}">{art}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'width="{f(w)}" height="{f(h)}" viewBox="0 0 {f(w)} {f(h)}"{extra}>'
            f'<defs>{defs}</defs>{body}</svg>\n')


def krin(cx, base, h, petal=CINNABAR, stroke=INK, sw=1.0, gold="url(#gold)"):
    """A krin (stylised lily) standing on `base`: three petals, a gilded calyx and two curls."""
    w = h * 0.62
    top = base - h
    mid = (f"M{f(cx)},{f(top)} C{f(cx + w * 0.26)},{f(top + h * 0.28)} {f(cx + w * 0.2)},{f(base - h * 0.42)} {f(cx)},{f(base - h * 0.3)} "
           f"C{f(cx - w * 0.2)},{f(base - h * 0.42)} {f(cx - w * 0.26)},{f(top + h * 0.28)} {f(cx)},{f(top)}Z")
    sides = []
    for s in (-1, 1):
        sides.append(f"M{f(cx)},{f(base - h * 0.32)} C{f(cx + s * w * 0.55)},{f(base - h * 0.5)} {f(cx + s * w * 0.62)},{f(top + h * 0.22)} "
                     f"{f(cx + s * w * 0.5)},{f(top + h * 0.12)} C{f(cx + s * w * 0.32)},{f(top + h * 0.36)} {f(cx + s * w * 0.22)},{f(base - h * 0.44)} "
                     f"{f(cx)},{f(base - h * 0.32)}Z")
    calyx = (f"M{f(cx - w * 0.3)},{f(base - h * 0.34)} Q{f(cx)},{f(base - h * 0.18)} {f(cx + w * 0.3)},{f(base - h * 0.34)} "
             f"L{f(cx + w * 0.14)},{f(base)} L{f(cx - w * 0.14)},{f(base)}Z")
    curls = curl(cx - w * 0.16, base - h * 0.06, h * 0.16, 1, -1) + " " + curl(cx + w * 0.16, base - h * 0.06, h * 0.16, -1, -1)
    return (f'<path d="{" ".join(sides)}" fill="{petal}" stroke="{stroke}" stroke-width="{f(sw)}" stroke-linejoin="round"/>'
            f'<path d="{mid}" fill="{gold}" stroke="{stroke}" stroke-width="{f(sw)}" stroke-linejoin="round"/>'
            f'<path d="{calyx}" fill="{gold}" stroke="{stroke}" stroke-width="{f(sw)}" stroke-linejoin="round"/>'
            f'<path d="{curls}" fill="none" stroke="{gold}" stroke-width="{f(sw * 1.2)}" stroke-linecap="round"/>')


def bilibin_band(x, y, w, h, ground=INK, petal=CINNABAR, leaf_fill=OLIVE, stroke=INK, gold="url(#gold)", sw=None,
                 rule=True):
    """A dense frame band on a dark ground: a gilded wave with a lily in every hollow, as in Bilibin's borders."""
    sw = sw if sw is not None else max(h * 0.04, 0.45)
    p = h * 2.0
    n = max(1, round(w / p))
    p = w / n
    cy = y + h / 2
    amp = h * 0.17
    out = [f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" fill="{ground}"/>']
    d = [f"M{f(x)},{f(cy)}"]
    for i in range(n * 2):
        x0 = x + i * p / 2
        s = -1 if i % 2 == 0 else 1
        d.append(f"C{f(x0 + p * 0.16)},{f(cy + s * amp * 1.33)} {f(x0 + p * 0.34)},{f(cy + s * amp * 1.33)} {f(x0 + p / 2)},{f(cy)}")
    stem = " ".join(d)
    out.append(f'<path d="{stem}" fill="none" stroke="{gold}" stroke-width="{f(sw * 2.4)}" stroke-linecap="round"/>')
    leaves, flowers, berries = [], [], []
    for i in range(n * 2):
        xq = x + i * p / 2 + p / 4
        s = -1 if i % 2 == 0 else 1     # the crest of this half-wave is on side s
        # the hollow opens toward -s: a lily stands on the stem and points to that edge
        flowers.append(krin_in_band(xq, cy + s * amp * 0.9, h * 0.5, -s, petal, stroke, sw * 0.7, gold))
        for side in (-1, 1):
            leaves.append(leaf(xq + side * p * 0.2, cy + s * amp * 0.35, h * 0.26, h * 0.09,
                               (math.pi / 2) * s + side * 1.0 * s))
        berries.append(f'<circle cx="{f(x + i * p / 2)}" cy="{f(cy)}" r="{f(h * 0.07)}"/>')
    out.append(f'<path d="{" ".join(leaves)}" fill="{leaf_fill}" stroke="{stroke}" stroke-width="{f(sw * 0.6)}"/>')
    out.extend(flowers)
    out.append(f'<g fill="{petal}" stroke="{gold}" stroke-width="{f(sw * 0.8)}">{"".join(berries)}</g>')
    if rule:
        inset = sw * 1.5
        out.append(f'<rect x="{f(x + inset)}" y="{f(y + inset)}" width="{f(w - 2 * inset)}" height="{f(h - 2 * inset)}" '
                   f'fill="none" stroke="{gold}" stroke-width="{f(sw * 1.4)}"/>')
    return "".join(out)


def krin_in_band(cx, base_y, h, direction, petal, stroke, sw, gold):
    """A lily standing at (cx, base_y) and pointing up (direction -1) or down (+1).

    Drawn as a reference to one unit lily per colouring (see `svg`), so a long band stays small."""
    key = f"krin-{petal.strip('#').replace('url(', '').replace(')', '')}"
    _KRIN_DEFS[key] = krin(0, 0, 1.0, petal=petal, stroke=stroke, sw=sw / max(h, 0.01), gold=gold)
    return (f'<use href="#{key}" xlink:href="#{key}" transform="translate({f(cx)},{f(base_y)}) '
            f'scale({f(h)},{f(-direction * h)})"/>')


_KRIN_DEFS = {}


def kokoshnik(cx, base, w, h):
    """Path of an ogee arch (kokoshnik / zakomara) standing on `base`, `w` wide and `h` tall."""
    l, r, top = cx - w / 2, cx + w / 2, base - h
    return (f"M{f(l)},{f(base)} L{f(l)},{f(base - h * 0.32)} "
            f"C{f(l)},{f(base - h * 0.78)} {f(cx - w * 0.3)},{f(base - h * 0.86)} {f(cx - w * 0.12)},{f(top + h * 0.34)} "
            f"C{f(cx - w * 0.04)},{f(top + h * 0.18)} {f(cx)},{f(top + h * 0.1)} {f(cx)},{f(top)} "
            f"C{f(cx)},{f(top + h * 0.1)} {f(cx + w * 0.04)},{f(top + h * 0.18)} {f(cx + w * 0.12)},{f(top + h * 0.34)} "
            f"C{f(cx + w * 0.3)},{f(base - h * 0.86)} {f(r)},{f(base - h * 0.78)} {f(r)},{f(base - h * 0.32)} L{f(r)},{f(base)}Z")
