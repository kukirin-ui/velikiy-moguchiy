"""Artwork the Mac and iOS apps draw: the page frame of the Settings window, the logo, lilies, tailpieces and the
sidebar pictograms. Every image comes as a parchment / lacquer pair: the asset catalog picks the dark one in the
dark appearance (a black Palekh lacquer page with gold).
"""
import math
import shutil

from lettering import logo
from ornament import (CINNABAR, GOLD, INK, OLIVE, PARCHMENT, UMBER, bilibin_band, f, gold_gradient, kokoshnik, krin,
                      leaf, rosette, svg, curl)

LACQUER = "#0E0A08"
VELLUM = "#F4ECDD"
LACQUER_PLATE = "#16100D"
CINNABAR_LIGHT = "#C0503A"

# Geometry of the Settings window (pt); SPTheme.m uses the same numbers.
WINDOW_W, WINDOW_H, SIDEBAR_W = 940, 726, 208
PAGE_W = WINDOW_W - SIDEBAR_W
BAND = 12          # frame band width
BAND_INSET = 8     # from the page edge to the band
ARCH_W, ARCH_H, ARCH_BASE = 400, 84, 96


def _contents(name, light, dark, template=False):
    props = '"preserves-vector-representation" : true'
    if template:
        props += ',\n    "template-rendering-intent" : "template"'
    images = [f'    {{\n      "filename" : "{light}",\n      "idiom" : "universal"\n    }}']
    if dark:
        images.append(f'    {{\n      "appearances" : [\n        {{\n          "appearance" : "luminosity",\n'
                      f'          "value" : "dark"\n        }}\n      ],\n      "filename" : "{dark}",\n'
                      f'      "idiom" : "universal"\n    }}')
    return ('{\n  "images" : [\n' + ",\n".join(images) + '\n  ],\n  "info" : {\n    "author" : "xcode",\n'
            f'    "version" : 1\n  }},\n  "properties" : {{\n    {props}\n  }}\n}}\n')


def imageset_pair(rsvg, catalog, name, light_svg, dark_svg=None, template=False):
    folder = catalog / f"{name}.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    rsvg(light_svg, folder / f"{name}.pdf", fmt="pdf")
    dark = None
    if dark_svg:
        dark = f"{name}-dark.pdf"
        rsvg(dark_svg, folder / dark, fmt="pdf")
    (folder / "Contents.json").write_text(_contents(name, f"{name}.pdf", dark, template))


def _palette(dark):
    return dict(ground=LACQUER if dark else UMBER, plate=LACQUER_PLATE if dark else VELLUM,
                petal=CINNABAR_LIGHT if dark else CINNABAR, hair=CINNABAR_LIGHT if dark else CINNABAR)


def page_frame(dark):
    """The page of the Settings window right of the sidebar: a Bilibin band round the edge, lily corner plates,
    and a kokoshnik arch at the top for the page title, standing on a gilded base rule."""
    p = _palette(dark)
    w, h, b, i = PAGE_W, WINDOW_H, BAND, BAND_INSET
    out = []
    # bands: top and bottom horizontal, sides drawn as rotated horizontal runs
    out.append(bilibin_band(i + b, i, w - 2 * (i + b), b, ground=p["ground"], petal=p["petal"]))
    out.append(bilibin_band(i + b, h - i - b, w - 2 * (i + b), b, ground=p["ground"], petal=p["petal"]))
    side = h - 2 * (i + b)
    for x in (i, w - i - b):
        g = bilibin_band(0, 0, side, b, ground=p["ground"], petal=p["petal"])
        out.append(f'<g transform="translate({f(x + b)},{f(i + b)}) rotate(90)">{g}</g>')
    for cx, cy in ((i, i), (w - i - b, i), (i, h - i - b), (w - i - b, h - i - b)):
        out.append(f'<rect x="{f(cx)}" y="{f(cy)}" width="{b}" height="{b}" fill="{p["petal"]}" stroke="url(#gold)" stroke-width="1"/>')
        out.append(rosette(cx + b / 2, cy + b / 2, b * 0.42, fill_outer="url(#gold)", fill_inner=p["ground"],
                           core="url(#gold)", stroke=INK, sw=0.35))
    # the base rule the arch stands on
    x0, x1 = i + b + 10, w - i - b - 10
    out.append(f'<rect x="{f(x0)}" y="{ARCH_BASE}" width="{f(x1 - x0)}" height="1.6" fill="url(#gold)"/>')
    out.append(f'<rect x="{f(x0)}" y="{ARCH_BASE + 3.5}" width="{f(x1 - x0)}" height="0.7" fill="{p["hair"]}"/>')
    for x in (x0, x1):
        out.append(f'<circle cx="{f(x)}" cy="{ARCH_BASE + 0.8}" r="2.4" fill="url(#gold)" stroke="{INK}" stroke-width="0.4"/>')
    # the arch: gold outer line, plate, cinnabar hairline; lilies at its feet
    cx = w / 2
    out.append(f'<path d="{kokoshnik(cx, ARCH_BASE, ARCH_W + 6, ARCH_H + 6)}" fill="url(#gold)" stroke="{INK}" stroke-width="0.6"/>')
    out.append(f'<path d="{kokoshnik(cx, ARCH_BASE, ARCH_W, ARCH_H)}" fill="{p["plate"]}"/>')
    out.append(f'<path d="{kokoshnik(cx, ARCH_BASE - 3, ARCH_W - 10, ARCH_H - 9)}" fill="none" stroke="{p["hair"]}" stroke-width="0.8"/>')
    for s in (-1, 1):
        out.append(f'<g transform="translate({f(cx + s * (ARCH_W / 2 + 22))},0)">'
                   f'{krin(0, ARCH_BASE - 1, 26, petal=p["petal"], stroke=INK, sw=0.5)}</g>')
    # a finial on the crown of the arch
    out.append(f'<circle cx="{f(cx)}" cy="{f(ARCH_BASE - ARCH_H - 6)}" r="3.2" fill="url(#gold)" stroke="{INK}" stroke-width="0.4"/>')
    return svg(w, h, "".join(out), gold_gradient())


def sidebar_band(dark):
    """A vertical band along the right edge of the sidebar."""
    p = _palette(dark)
    h = WINDOW_H
    g = bilibin_band(0, 0, h, 12, ground=p["ground"], petal=p["petal"])
    return svg(12, h, f'<g transform="translate(12,0) rotate(90)">{g}</g>', gold_gradient())


def logo_art(dark, height=40):
    g, w = logo(0, 0, height, anchor="start",
                letter=(CINNABAR_LIGHT if dark else CINNABAR), stroke=(INK if dark else UMBER),
                rule_color=GOLD)
    pad = height * 0.25
    top = height * 1.42
    return svg(w + 2 * pad, top + height * 0.42, f'<g transform="translate({f(pad)},{f(top)})">{g}</g>', gold_gradient())


def krin_icon(dark, size=24):
    p = _palette(dark)
    return svg(size, size, krin(size / 2, size * 0.95, size * 0.9, petal=p["petal"], stroke=INK, sw=size * 0.03),
               gold_gradient())


def tailpiece(dark):
    """A концовка: a lily in a vase between two branches, closing a page."""
    p = _palette(dark)
    w, h = 240, 56
    cx = w / 2
    out = []
    for s in (-1, 1):
        d = (f"M{f(cx + s * 14)},{f(h * 0.62)} C{f(cx + s * 50)},{f(h * 0.9)} {f(cx + s * 86)},{f(h * 0.2)} "
             f"{f(cx + s * 112)},{f(h * 0.5)}")
        out.append(f'<path d="{d}" fill="none" stroke="url(#gold)" stroke-width="2" stroke-linecap="round"/>')
        out.append(f'<path d="{curl(cx + s * 112, h * 0.5, 7, -s, -1)}" fill="none" stroke="url(#gold)" stroke-width="1.6"/>')
        for k, t in enumerate((0.3, 0.55, 0.8)):
            lx = cx + s * (14 + 98 * t)
            ly = h * (0.7 - 0.25 * t)
            out.append(f'<path d="{leaf(lx, ly, 13, 4.5, -math.pi / 2 + s * 0.9 if k % 2 else math.pi / 2 - s * 0.6)}" '
                       f'fill="{OLIVE}" stroke="{INK}" stroke-width="0.5"/>')
        out.append(f'<circle cx="{f(cx + s * 70)}" cy="{f(h * 0.3)}" r="2.6" fill="{p["petal"]}" stroke="url(#gold)" stroke-width="0.6"/>')
    out.append(krin(cx, h * 0.72, 40, petal=p["petal"], stroke=INK, sw=0.6))
    vase = (f"M{f(cx - 10)},{f(h * 0.72)} Q{f(cx - 12)},{f(h * 0.9)} {f(cx - 4)},{f(h * 0.96)} L{f(cx + 4)},{f(h * 0.96)} "
            f"Q{f(cx + 12)},{f(h * 0.9)} {f(cx + 10)},{f(h * 0.72)}Z")
    out.append(f'<path d="{vase}" fill="url(#gold)" stroke="{INK}" stroke-width="0.6"/>')
    return svg(w, h, "".join(out), gold_gradient())


# ─── sidebar pictograms (templates, 20 pt) ─────────────────────────

def _pict(body):
    return svg(20, 20, f'<g fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">{body}</g>')


PICTOGRAMS = {
    # a bell: the voice
    "PictBell": '<path d="M10,2.5 V4"/><path d="M5,14.5 C5,8 6.2,4.6 10,4.6 C13.8,4.6 15,8 15,14.5 Z" fill="#000" fill-opacity="0.18"/>'
                '<path d="M3.5,14.5 H16.5"/><circle cx="10" cy="16.7" r="1.4" fill="#000"/>'
                '<path d="M7.4,8.6 C7.8,7.4 8.6,6.8 10,6.7"/>',
    # a quill: correcting the text
    "PictQuill": '<path d="M16.5,2.5 C10,4 6,9 4.5,16.5"/><path d="M16.5,2.5 C16.5,8 13,12.5 7.5,13.2 L5.6,14"/>'
                 '<path d="M9.2,9.6 L12.2,8.4"/><path d="M3.2,17.6 L5,15.6"/>',
    # an old key: controls
    "PictKey": '<circle cx="6" cy="6" r="3.4"/><circle cx="6" cy="6" r="1.1" fill="#000"/><path d="M8.4,8.4 L16.8,16.8"/>'
               '<path d="M13.6,13.6 L15.6,11.6"/><path d="M15.4,15.4 L17.2,13.6"/>',
    # a terem window under a kokoshnik: the overlay
    "PictWindow": '<path d="M4,18 V9 C4,6.4 6.4,5.6 8,5 C9,4.6 10,3.6 10,2.4 C10,3.6 11,4.6 12,5 C13.6,5.6 16,6.4 16,9 V18 Z"/>'
                  '<path d="M10,8 V18"/><path d="M4,12.8 H16"/>',
    # a book with clasps: the dictionary
    "PictBook": '<rect x="4" y="2.8" width="12" height="14.6" rx="1.2"/><path d="M6.4,2.8 V17.4"/>'
                '<path d="M16,7 H17.6 M16,13.2 H17.6"/><path d="M10.6,7.4 L11.8,9.6 L10.6,11.8 L9.4,9.6 Z" fill="#000"/>',
    # a scroll: snippets
    "PictScroll": '<path d="M5,4 H14.6 C16,4 16,6.4 14.6,6.4 H13.6 V15.6 C13.6,17.4 12,17.4 11.4,17.4 H4.6 C3,17.4 3,15 4.6,15 H11.4"/>'
                  '<path d="M5,4 C3.4,4 3.4,6.4 5,6.4 H6.4 V15"/><path d="M8.4,9 H11.6 M8.4,11.6 H11.6"/>',
    # an inkwell with a pen: the prompt
    "PictInkwell": '<path d="M4.5,11 H13.5 L14.5,17.5 H3.5 Z"/><path d="M6.5,11 V9.4 H11.5 V11"/>'
                   '<path d="M9,9.4 L16.6,2"/><path d="M15,3.6 L16.6,5.2"/>',
    # a seal: templates
    "PictSeal": '<circle cx="10" cy="8.4" r="5.6"/><path d="M10,5.4 C11.4,6.8 11.4,8.6 10,10.6 C8.6,8.6 8.6,6.8 10,5.4 Z" fill="#000"/>'
                '<path d="M7.2,13.4 L5.6,18 L8,16.8 L9,18.6 L10,14 M12.8,13.4 L14.4,18 L12,16.8 L11,18.6 L10,14"/>',
    # a lily in a ring: about
    "PictKrin": '<circle cx="10" cy="10" r="7.6"/><path d="M10,4.6 C11.6,6.6 11.6,8.8 10,11 C8.4,8.8 8.4,6.6 10,4.6 Z" fill="#000"/>'
                '<path d="M10,11 C12.6,10 14,8 13.8,6 C12.6,8 11.4,9.4 10,11 C8.6,9.4 7.4,8 6.2,6 C6,8 7.4,10 10,11 Z"/>'
                '<path d="M8,13.6 H12 M10,11 V15.4"/>',
}


def build(rsvg, mac_assets, ios_assets):
    imageset_pair(rsvg, mac_assets, "PageFrame", page_frame(False), page_frame(True))
    imageset_pair(rsvg, mac_assets, "SidebarBand", sidebar_band(False), sidebar_band(True))
    imageset_pair(rsvg, mac_assets, "Tailpiece", tailpiece(False), tailpiece(True))
    for catalog in (mac_assets, ios_assets):
        imageset_pair(rsvg, catalog, "Logo", logo_art(False), logo_art(True))
        imageset_pair(rsvg, catalog, "Krin", krin_icon(False), krin_icon(True))
    for name, body in PICTOGRAMS.items():
        imageset_pair(rsvg, mac_assets, name, _pict(body), template=True)
