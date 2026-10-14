"""Generates the Ancient-Rus artwork of «Великий & Могучий»: README banner and ornaments, app icons,
the menu bar icon, the ornaments and paintings the Mac and iOS apps draw, and the parchment texture.

    python3 -m venv .venv && .venv/bin/pip install fonttools pillow numpy
    .venv/bin/python design/old-rus/make_assets.py     # needs rsvg-convert (brew install librsvg)

Original artwork (MIT like the code) in the manner of Ivan Bilibin's book frames, built on public-domain
paintings listed in THIRD_PARTY.md. Fonts (SIL OFL 1.1): Oglavie, Monomakh and Vertograd from fonts-cu, Old Standard TT.
"""
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

from ornament import (CINNABAR, INK, LIGHT, OCHRE, OLIVE, PARCHMENT, ROSE, SERIF, SERIF_BOLD, SERIF_ITALIC,
                      SMOKE, UMBER, f, frame, glyph_box, leaf, rosette, scroll_pair, svg, text_path,
                      text_width, tree, trefoil, vine_band, curl)
import paintings

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
README_DIR = ROOT / "design/readme"
MAC = ROOT / "mac/MacApp/VelikiyMoguchiy"
MAC_ASSETS = MAC / "Assets.xcassets"
IOS_ASSETS = ROOT / "ios/Resources/Assets.xcassets"

TITLE = "Великий & Могучий"
# Drop caps the READMEs use, with Latin file names.
INITIALS = {"Р": "r", "О": "o", "П": "p", "У": "u"}
HEADPIECES = {"family": "Семейство продуктов", "install": "Установка", "layout": "Устройство репозитория",
              "privacy": "Конфиденциальность", "weights": "Веса моделей", "roadmap": "Дорожная карта",
              "community": "Сообщество", "license": "Лицензия и документы",
              "mac": "Диктовка для macOS", "ios": "Клавиатура для iPhone", "lipread": "Чтение по губам",
              "federated": "Общее обучение"}


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def rsvg(svg_text, out, width=None, height=None, fmt="png"):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False, encoding="utf-8") as tmp:
        tmp.write(svg_text)
    cmd = ["rsvg-convert", "-f", fmt, "-o", str(out)]
    if width:
        cmd += ["-w", str(width)]
    if height:
        cmd += ["-h", str(height)]
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd + [tmp.name], check=True)
    Path(tmp.name).unlink()


def png_opaque(path, background):
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, background)
    Image.alpha_composite(bg, im).convert("RGB").save(path, optimize=True)


# ─── README ─────────────────────────────────────────────────────────

def _band_frame(W, H, B, ground=UMBER):
    """A Bilibin band round a W × H rectangle with gilded rosettes on cinnabar in the corners."""
    from ornament import bilibin_band
    out = [bilibin_band(B, 0, W - 2 * B, B, ground=ground), bilibin_band(B, H - B, W - 2 * B, B, ground=ground)]
    for x in (0, W - B):
        g = bilibin_band(0, 0, H - 2 * B, B, ground=ground)
        out.append(f'<g transform="translate({x + B},{B}) rotate(90)">{g}</g>')
    for cx, cy in ((0, 0), (W - B, 0), (0, H - B), (W - B, H - B)):
        out.append(f'<rect x="{cx}" y="{cy}" width="{B}" height="{B}" fill="{CINNABAR}" stroke="url(#gold)" stroke-width="1.5"/>')
        out.append(rosette(cx + B / 2, cy + B / 2, B * 0.42, fill_outer="url(#gold)", fill_inner=ground, core="url(#gold)",
                           stroke=INK, sw=0.6))
    return "".join(out)


def _krin_column(cx, top, bottom, width):
    """A tree of lilies on a dark panel: a gilded stem with paired lilies and a crowning one."""
    from ornament import krin
    out = [f'<path d="M{f(cx)},{f(bottom)} L{f(cx)},{f(top + width * 0.6)}" stroke="url(#gold)" stroke-width="3" stroke-linecap="round"/>']
    tiers = 3
    for t in range(tiers):
        y = bottom - (t + 0.7) * (bottom - top - width * 0.9) / tiers
        size = width * (0.42 - 0.05 * t)
        for sdir in (-1, 1):
            d = (f"M{f(cx)},{f(y + size * 0.4)} C{f(cx + sdir * size * 0.5)},{f(y + size * 0.35)} "
                 f"{f(cx + sdir * size * 0.75)},{f(y + size * 0.1)} {f(cx + sdir * size * 0.8)},{f(y - size * 0.05)}")
            out.append(f'<path d="{d}" fill="none" stroke="url(#gold)" stroke-width="2.2" stroke-linecap="round"/>')
            out.append(f'<g transform="translate({f(cx + sdir * size * 0.8)},0)">{krin(0, y, size * 0.9, sw=0.8)}</g>')
            out.append(f'<path d="{leaf(cx, y + size * 0.55, size * 0.55, size * 0.18, -math.pi / 2 + sdir * 1.1)}" '
                       f'fill="{OLIVE}" stroke="{INK}" stroke-width="0.7"/>')
    out.append(krin(cx, top + width * 0.95, width * 0.75, sw=0.9))
    return "".join(out)


def banner():
    from ornament import gold_gradient
    from lettering import logo
    W, H, B = 1280, 560, 30
    side = 132
    inner_x, inner_y, inner_w = B, B, W - 2 * B
    pic_x, pic_w = inner_x + side, inner_w - 2 * side
    pic_y, pic_h = inner_y, 330
    band_y = pic_y + pic_h
    band_h = H - B - band_y

    painting = paintings.grade(paintings.crop(paintings.load("bogatyri"), (0.0, 0.02, 1.0, 0.6),
                                              (int(pic_w * 1.5), int(pic_h * 1.5))), strength=0.38)
    body = [f'<rect width="{W}" height="{H}" fill="{PARCHMENT}"/>']
    body.append(_band_frame(W, H, B))
    for x0 in (inner_x, inner_x + inner_w - side):
        body.append(f'<rect x="{x0}" y="{inner_y}" width="{side}" height="{pic_h}" fill="{UMBER}"/>')
        body.append(f'<rect x="{x0 + 7}" y="{inner_y + 7}" width="{side - 14}" height="{pic_h - 14}" fill="none" stroke="url(#gold)" stroke-width="2"/>')
        body.append(_krin_column(x0 + side / 2, inner_y + 18, inner_y + pic_h - 16, side * 0.82))
    body.append(f'<image x="{pic_x}" y="{pic_y}" width="{pic_w}" height="{pic_h}" preserveAspectRatio="xMidYMid slice" '
                f'xlink:href="{paintings.data_uri(painting, 70)}"/>')
    body.append(f'<rect x="{pic_x}" y="{pic_y}" width="{pic_w}" height="{pic_h}" fill="none" stroke="url(#gold)" stroke-width="3"/>')
    body.append(f'<rect x="{inner_x}" y="{band_y}" width="{inner_w}" height="{band_h}" fill="{PARCHMENT}"/>')
    body.append(f'<rect x="{inner_x}" y="{band_y}" width="{inner_w}" height="3" fill="url(#gold)"/>')
    body.append(f'<rect x="{inner_x}" y="{band_y + 6}" width="{inner_w}" height="1" fill="{CINNABAR}"/>')
    cx = W / 2
    g, tw = logo(cx, band_y + 112, 58, rules=False)
    body.append(g)
    from ornament import krin
    for side_ in (-1, 1):
        x = cx + side_ * (tw / 2 + 60)
        body.append(krin(x, band_y + 116, 64, sw=1.0))
        body.append(f'<g transform="translate({f(x + side_ * 34)},{band_y + 88}) scale({side_},1)">'
                    f'{scroll_pair(42, 0, 84, 26, OCHRE, 2.6)}</g>')
    sub = "русская голосовая диктовка для Mac, iPhone, Android и Windows"
    from ornament import MONOMAKH
    body.append(f'<path d="{text_path(sub, MONOMAKH, 27, cx, band_y + 158, "middle")}" fill="{UMBER}"/>')
    write(README_DIR / "banner.svg", svg(W, H, "".join(body), gold_gradient(),
                                         extra=' role="img" aria-label="Великий &amp; Могучий"'))


def divider(kind="krin", width=720, height=48):
    """Section dividers in three kinds, so the page does not repeat one ornament."""
    from ornament import bilibin_band, gold_gradient, krin
    cx, cy = width / 2, height / 2
    body = []
    if kind == "band":
        w = width * 0.7
        body.append(bilibin_band((width - w) / 2, cy - 9, w, 18))
        for s_ in (-1, 1):
            body.append(f'<circle cx="{f(cx + s_ * (w / 2 + 12))}" cy="{f(cy)}" r="4" fill="url(#gold)" stroke="{INK}" stroke-width="0.6"/>')
    elif kind == "rosette":
        for s_ in (-1, 1):
            x0, x1 = (cx + 34, width - 30) if s_ > 0 else (30, cx - 34)
            body.append(f'<rect x="{f(x0)}" y="{f(cy - 2.5)}" width="{f(x1 - x0)}" height="1.6" fill="url(#gold)"/>')
            body.append(f'<rect x="{f(x0)}" y="{f(cy + 1.5)}" width="{f(x1 - x0)}" height="0.8" fill="{CINNABAR}"/>')
            body.append(f'<path d="{leaf(cx + s_ * 26, cy, 22, 7, 0 if s_ > 0 else math.pi)}" fill="{CINNABAR}" stroke="{INK}" stroke-width="0.8"/>')
        body.append(rosette(cx, cy, 20, fill_outer="url(#gold)", fill_inner=CINNABAR, core=PARCHMENT, stroke=INK, sw=0.9))
    else:
        for s_ in (-1, 1):
            d = (f"M{f(cx + s_ * 18)},{f(cy + 8)} C{f(cx + s_ * 80)},{f(cy + 22)} {f(cx + s_ * 150)},{f(cy - 10)} "
                 f"{f(cx + s_ * 260)},{f(cy + 4)}")
            body.append(f'<path d="{d}" fill="none" stroke="url(#gold)" stroke-width="2.4" stroke-linecap="round"/>')
            for k, t in enumerate((0.25, 0.5, 0.75)):
                lx, ly = cx + s_ * (18 + 242 * t), cy + 8 - 10 * math.sin(t * math.pi)
                body.append(f'<path d="{leaf(lx, ly, 14, 4.6, -math.pi / 2 + s_ * 0.8 if k % 2 else math.pi / 2 - s_ * 0.6)}" '
                            f'fill="{OLIVE}" stroke="{INK}" stroke-width="0.6"/>')
            body.append(f'<circle cx="{f(cx + s_ * 264)}" cy="{f(cy + 4)}" r="3.4" fill="{CINNABAR}" stroke="url(#gold)" stroke-width="0.8"/>')
        body.append(krin(cx, cy + 18, 38, sw=0.8))
    write(README_DIR / f"divider-{kind}.svg", svg(width, height, "".join(body), gold_gradient(), extra=' role="presentation"'))


def headpiece(title, filename, width=760, height=118):
    """A section heading as a Bilibin headpiece: vyaz with a gilded capital inside a kokoshnik arch on a band."""
    from ornament import bilibin_band, gold_gradient, kokoshnik, krin
    from lettering import title as lettering_title
    cx = width / 2
    base = height - 22
    probe, tw = lettering_title(title, 0, 0, 30)
    size = min(34.0, 34.0 * (width * 0.62) / max(tw * 34.0 / 30, 1))
    arch_w = min(width - 120, tw * size / 30 + 120)
    body = [f'<rect x="0" y="0" width="{width}" height="{height}" rx="6" fill="{PARCHMENT}"/>']
    body.append(bilibin_band(10, base, width - 20, 14))
    body.append(f'<path d="{kokoshnik(cx, base, arch_w + 8, 92)}" fill="url(#gold)" stroke="{INK}" stroke-width="0.8"/>')
    body.append(f'<path d="{kokoshnik(cx, base, arch_w, 86)}" fill="#F4ECDD"/>')
    body.append(f'<path d="{kokoshnik(cx, base - 4, arch_w - 12, 78)}" fill="none" stroke="{CINNABAR}" stroke-width="1"/>')
    g, _ = lettering_title(title, cx, base - 18, size, anchor="middle")
    body.append(g)
    for s_ in (-1, 1):
        body.append(krin(cx + s_ * (arch_w / 2 + 34), base, 40, sw=0.8))
    write(README_DIR / filename, svg(width, height, "".join(body), gold_gradient(), extra=f' role="img" aria-label="{title}"'))


def initial(letter, size=160):
    """A drop cap: an interlaced Vertograd letter, cinnabar and gold, in a gilded frame on vellum."""
    from ornament import VERTOGRAD, bilibin_band, gold_gradient
    s = size
    body = [f'<rect x="0" y="0" width="{s}" height="{s}" fill="{UMBER}"/>',
            f'<rect x="7" y="7" width="{s - 14}" height="{s - 14}" fill="#F4ECDD" stroke="url(#gold)" stroke-width="3"/>',
            f'<rect x="12" y="12" width="{s - 24}" height="{s - 24}" fill="none" stroke="{CINNABAR}" stroke-width="1"/>']
    for k, (cx, cy) in enumerate(((0, 0), (s - 14, 0), (0, s - 14), (s - 14, s - 14))):
        body.append(f'<rect x="{cx}" y="{cy}" width="14" height="14" fill="{CINNABAR}" stroke="url(#gold)" stroke-width="1"/>')
    xmin, ymin, xmax, ymax = glyph_box(letter, VERTOGRAD, s * 0.78)
    gx = s / 2 - (xmin + xmax) / 2
    gy = s / 2 + (ymin + ymax) / 2
    d = text_path(letter, VERTOGRAD, s * 0.78, gx, gy)
    body.append(f'<path d="{d}" fill="url(#gold)" stroke="{UMBER}" stroke-width="5" stroke-linejoin="round" paint-order="stroke"/>')
    body.append(f'<path d="{d}" fill="{CINNABAR}" fill-opacity="0.85"/>')
    return svg(s, s, "".join(body), gold_gradient(), extra=f' role="img" aria-label="{letter}"')


def section_painting(name, box, size, out, quality=76):
    """A lightly graded crop in a thin ruled frame, saved as JPEG for the README."""
    w, h = size
    pad = 10
    img = paintings.grade(paintings.crop(paintings.load(name), box, (w - 2 * pad, h - 2 * pad)), strength=0.3)
    canvas = Image.new("RGB", (w, h), UMBER)
    inner = Image.new("RGB", (w - 6, h - 6), OCHRE)
    canvas.paste(inner, (3, 3))
    canvas.paste(Image.new("RGB", (w - 12, h - 12), UMBER), (6, 6))
    canvas.paste(img, (pad, pad))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(paintings.jpeg_bytes(canvas, quality))


def readme_assets():
    import app_art
    banner()
    for kind in ("krin", "band", "rosette"):
        divider(kind)
    for key, title in HEADPIECES.items():
        headpiece(title, f"h-{key}.svg")
    for letter, latin in INITIALS.items():
        write(README_DIR / f"initial-{latin}.svg", initial(letter))
    write(README_DIR / "tailpiece.svg", app_art.tailpiece(False))
    section_painting("guests", (0.0, 0.0, 1.0, 1.0), (880, 400), README_DIR / "guests.jpg")
    section_painting("messenger", (0.0, 0.05, 1.0, 1.0), (880, 400), README_DIR / "messenger.jpg")
    section_painting("wedding", (0.0, 0.0, 1.0, 1.0), (880, 380), README_DIR / "wedding.jpg")
    section_painting("firebird", (0.0, 0.0, 0.982, 0.985), (880, 246), README_DIR / "firebird.jpg")


def icon_body(size=1024, detailed=True):
    """Parchment in a Bilibin frame with a cinnabar, gold-edged «В» in the Old Russian book hand (Monomakh).
    `detailed=False` is the 16–32 px drawing: a heavy frame and the bare letter."""
    from ornament import MONOMAKH, GOLD, bilibin_band, gold_gradient
    s = size
    defs = (f'<radialGradient id="vellum" cx="0.5" cy="0.45" r="0.72">'
            f'<stop offset="0" stop-color="#F6EEDF"/><stop offset="0.65" stop-color="{PARCHMENT}"/>'
            f'<stop offset="1" stop-color="{LIGHT}"/></radialGradient>' + gold_gradient()
            + f'<filter id="lift" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="{s * 0.008}"/></filter>')
    body = [f'<rect width="{s}" height="{s}" fill="url(#vellum)"/>']
    if detailed:
        # inside the rounded-corner mask of macOS and iOS (radius ~22 %)
        band = s * 0.095
        m = s * 0.085
        inner = s - 2 * m
        body.append(f'<rect x="{m}" y="{m}" width="{inner}" height="{inner}" fill="{UMBER}"/>')
        for y in (m, s - m - band):
            body.append(bilibin_band(m + band, y, inner - 2 * band, band, ground=UMBER, sw=s * 0.0035))
        for x in (m, s - m - band):
            g = bilibin_band(0, 0, inner - 2 * band, band, ground=UMBER, sw=s * 0.0035)
            body.append(f'<g transform="translate({x + band},{m + band}) rotate(90)">{g}</g>')
        for cx, cy in ((m, m), (s - m - band, m), (m, s - m - band), (s - m - band, s - m - band)):
            body.append(f'<rect x="{cx}" y="{cy}" width="{band}" height="{band}" fill="{CINNABAR}" stroke="url(#gold)" stroke-width="{s * 0.004}"/>')
            body.append(rosette(cx + band / 2, cy + band / 2, band * 0.4, fill_outer="url(#gold)", fill_inner=UMBER,
                                core="url(#gold)", stroke=INK, sw=s * 0.0015))
        f0 = m + band
        body.append(f'<rect x="{f0}" y="{f0}" width="{s - 2 * f0}" height="{s - 2 * f0}" fill="url(#vellum)"/>')
        body.append(f'<rect x="{f0 + s * 0.012}" y="{f0 + s * 0.012}" width="{s - 2 * f0 - s * 0.024}" height="{s - 2 * f0 - s * 0.024}" '
                    f'fill="none" stroke="url(#gold)" stroke-width="{s * 0.006}"/>')
        body.append(f'<rect x="{f0 + s * 0.026}" y="{f0 + s * 0.026}" width="{s - 2 * f0 - s * 0.052}" height="{s - 2 * f0 - s * 0.052}" '
                    f'fill="none" stroke="{CINNABAR}" stroke-width="{s * 0.0025}"/>')
        gsize, stroke = s * 0.66, s * 0.004
    else:
        body.append(f'<rect x="{s * 0.04}" y="{s * 0.04}" width="{s * 0.92}" height="{s * 0.92}" fill="none" stroke="{UMBER}" stroke-width="{s * 0.09}"/>')
        body.append(f'<rect x="{s * 0.12}" y="{s * 0.12}" width="{s * 0.76}" height="{s * 0.76}" fill="none" stroke="{GOLD}" stroke-width="{s * 0.035}"/>')
        gsize, stroke = s * 0.86, s * 0.012
    xmin, ymin, xmax, ymax = glyph_box("В", MONOMAKH, gsize)
    gx = s / 2 - (xmin + xmax) / 2
    gy = s / 2 + (ymin + ymax) / 2
    d = text_path("В", MONOMAKH, gsize, gx, gy)
    if detailed:
        body.append(f'<path d="{d}" transform="translate({s * 0.01},{s * 0.014})" fill="{INK}" fill-opacity="0.35" filter="url(#lift)"/>')
        body.append(f'<path d="{d}" fill="none" stroke="{UMBER}" stroke-width="{s * 0.04}" stroke-linejoin="round"/>')
        body.append(f'<path d="{d}" fill="none" stroke="url(#gold)" stroke-width="{s * 0.028}" stroke-linejoin="round"/>')
    body.append(f'<path d="{d}" fill="{CINNABAR}" stroke="{UMBER}" stroke-width="{stroke}" stroke-linejoin="round"/>')
    return defs, "".join(body)


def icon_ios():
    defs, body = icon_body(1024, True)
    return svg(1024, 1024, body, defs)


def icon_macos(detailed=True):
    # macOS grid: an 824 pt rounded square centred on the 1024 canvas, with a soft shadow.
    inner = 824
    off = (1024 - inner) / 2
    radius = 185
    defs, body = icon_body(inner, detailed)
    defs += (f'<clipPath id="squircle"><rect x="0" y="0" width="{inner}" height="{inner}" rx="{radius}"/></clipPath>'
             f'<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14"/></filter>')
    if not detailed:
        # the 16/32 px drawing fills the canvas: at that size Apple's margin would waste a third of the pixels
        off, inner, radius = 40, 944, 200
        defs, body = icon_body(inner, detailed)
        defs += f'<clipPath id="squircle"><rect x="0" y="0" width="{inner}" height="{inner}" rx="{radius}"/></clipPath>'
        return svg(1024, 1024, f'<g transform="translate({off},{off})"><g clip-path="url(#squircle)">{body}</g>'
                   f'<rect x="0" y="0" width="{inner}" height="{inner}" rx="{radius}" fill="none" stroke="{UMBER}" stroke-width="12"/></g>', defs)
    out = (f'<rect x="{off}" y="{off + 12}" width="{inner}" height="{inner}" rx="{radius}" fill="{INK}" fill-opacity="0.45" filter="url(#shadow)"/>'
           f'<g transform="translate({off},{off})"><g clip-path="url(#squircle)">{body}</g>'
           f'<rect x="1.5" y="1.5" width="{inner - 3}" height="{inner - 3}" rx="{radius}" fill="none" stroke="{UMBER}" stroke-width="3"/></g>')
    return svg(1024, 1024, out, defs)


def icons():
    write(HERE / "icon.svg", icon_ios())
    write(HERE / "icon-macos.svg", icon_macos(True))
    write(HERE / "icon-macos-small.svg", icon_macos(False))
    ios = IOS_ASSETS / "AppIcon.appiconset/AppIcon.png"
    rsvg(icon_ios(), ios, 1024, 1024)
    png_opaque(ios, PARCHMENT)
    mac_set = MAC_ASSETS / "AppIcon.appiconset"
    files = {16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"], 64: ["icon_32x32@2x.png"],
             128: ["icon_128x128.png"], 256: ["icon_128x128@2x.png", "icon_256x256.png"],
             512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"]}
    for px, names in files.items():
        art = icon_macos(px >= 64)
        for name in names:
            rsvg(art, mac_set / name, px, px)


# ─── menu bar and in-app ornaments ──────────────────────────────────

def imageset(name, svg_text, template, catalog=MAC_ASSETS):
    folder = catalog / f"{name}.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    rsvg(svg_text, folder / f"{name}.pdf", fmt="pdf")
    props = '"preserves-vector-representation" : true'
    if template:
        props += ',\n    "template-rendering-intent" : "template"'
    (folder / "Contents.json").write_text(
        '{\n  "images" : [\n    {\n      "filename" : "%s.pdf",\n      "idiom" : "universal"\n    }\n  ],\n'
        '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "properties" : {\n    %s\n  }\n}\n' % (name, props))


def menubar_icon():
    """18 × 18 pt template: a «В» in a square frame with notched corners."""
    s = 18
    k = 0.5
    body = [f'<path d="M{3 + k},{1.2} H{s - 3 - k} L{s - 1.2},{3 + k} V{s - 3 - k} L{s - 3 - k},{s - 1.2} H{3 + k} L1.2,{s - 3 - k} V{3 + k} Z" '
            f'fill="none" stroke="#000" stroke-width="1.5" stroke-linejoin="round"/>']
    for x, y in ((s / 2, 0.2), (s / 2, s - 0.2), (0.2, s / 2), (s - 0.2, s / 2)):
        body.append(f'<circle cx="{x}" cy="{y}" r="1.05" fill="#000"/>')
    from ornament import MONOMAKH
    xmin, ymin, xmax, ymax = glyph_box("В", MONOMAKH, 14.5)
    gx = s / 2 - (xmin + xmax) / 2
    gy = s / 2 + (ymin + ymax) / 2
    body.append(f'<path d="{text_path("В", MONOMAKH, 14.5, gx, gy)}" fill="#000" stroke="#000" stroke-width="0.35"/>')
    imageset("MenuBarIcon", svg(s, s, "".join(body)), template=True)


def app_ornaments():
    # centre piece of the Settings dividers: rosette between scrolls (template, tinted in code)
    w, h = 132, 20
    body = [rosette(w / 2, h / 2, 9, fill_outer="#000", fill_inner="#000", core="#fff", stroke="#000", sw=0.6)]
    for s in (-1, 1):
        body.append(f'<g transform="translate({f(w / 2 + s * 12)},{h / 2}) scale({s},1)">{scroll_pair(26, 0, 52, 12, "#000", 1.4)}</g>')
        body.append(f'<path d="{trefoil(w / 2 + s * 60, h / 2, 3.4, 0 if s > 0 else math.pi)}" fill="#000"/>')
    imageset("OrnamentDivider", svg(w, h, "".join(body)), template=True)


def about_painting():
    """The About pane's picture: Vasnetsov's «Богатыри» in a Bilibin frame, as a PNG pair (1x, 2x)."""
    W, H, B = 560, 236, 18
    pic = paintings.grade(paintings.crop(paintings.load("bogatyri"), (0.02, 0.04, 0.98, 0.66), ((W - 2 * B) * 2, (H - 2 * B) * 2)))
    body = frame(0, 0, W, H, B, sw=0.9)
    body += (f'<image x="{B}" y="{B}" width="{W - 2 * B}" height="{H - 2 * B}" preserveAspectRatio="xMidYMid slice" '
             f'xlink:href="{paintings.data_uri(pic, 82)}"/>')
    body += f'<rect x="{B}" y="{B}" width="{W - 2 * B}" height="{H - 2 * B}" fill="none" stroke="{UMBER}" stroke-width="1.5"/>'
    folder = MAC_ASSETS / "AboutPainting.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    text = svg(W, H, body)
    rsvg(text, folder / "AboutPainting.png", W, H)
    rsvg(text, folder / "AboutPainting@2x.png", W * 2, H * 2)
    for p in folder.glob("*.png"):
        Image.open(p).convert("RGB").save(p.with_suffix(".jpg"), quality=84, optimize=True)
        p.unlink()
    (folder / "Contents.json").write_text(
        '{\n  "images" : [\n    {\n      "filename" : "AboutPainting.jpg",\n      "idiom" : "universal",\n      "scale" : "1x"\n    },\n'
        '    {\n      "filename" : "AboutPainting@2x.jpg",\n      "idiom" : "universal",\n      "scale" : "2x"\n    }\n  ],\n'
        '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')


def parchment_texture(size=384):
    """A seamless grain for the window background: periodic noise from the frequency domain."""
    rng = np.random.default_rng(1898)

    def periodic(scale, power):
        spectrum = np.fft.fft2(rng.standard_normal((size, size)))
        fy = np.fft.fftfreq(size)[:, None]
        fx = np.fft.fftfreq(size)[None, :]
        r = np.sqrt(fx ** 2 + fy ** 2) + 1.0 / size
        field = np.real(np.fft.ifft2(spectrum / r ** power * np.exp(-(r * scale) ** 2)))
        return (field - field.mean()) / field.std()

    blotches = periodic(6, 1.6)
    grain = periodic(0.5, 0.4)
    fibres = periodic(1.2, 0.9)
    value = 0.55 * blotches + 0.25 * grain + 0.2 * np.abs(fibres)
    value = (value - value.min()) / (value.max() - value.min())
    alpha = (np.clip(value - 0.35, 0, 1) / 0.65) ** 1.4
    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[..., 0], rgba[..., 1], rgba[..., 2] = 0x32, 0x26, 0x1E
    rgba[..., 3] = (alpha * 255).astype(np.uint8)
    folder = MAC_ASSETS / "ParchmentGrain.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    Image.fromarray(rgba, "RGBA").save(folder / "ParchmentGrain.png", optimize=True)
    (folder / "Contents.json").write_text(
        '{\n  "images" : [\n    {\n      "filename" : "ParchmentGrain.png",\n      "idiom" : "universal"\n    }\n  ],\n'
        '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')


def accent_color():
    """AccentColor: cinnabar in light, dusty rose in the dark 'ink' appearance."""
    def comp(hexcolor):
        return {k: f"0x{hexcolor[i:i + 2]}" for k, i in (("red", 1), ("green", 3), ("blue", 5))}

    def entry(hexcolor, dark):
        c = comp(hexcolor)
        appearance = ('      "appearances" : [\n        {\n          "appearance" : "luminosity",\n'
                      '          "value" : "dark"\n        }\n      ],\n') if dark else ""
        return ('    {\n%s      "color" : {\n        "color-space" : "srgb",\n        "components" : {\n'
                '          "alpha" : "1.000",\n          "blue" : "%s",\n          "green" : "%s",\n          "red" : "%s"\n'
                '        }\n      },\n      "idiom" : "universal"\n    }' % (appearance, c["blue"], c["green"], c["red"]))

    for catalog in (MAC_ASSETS, IOS_ASSETS):
        folder = catalog / "AccentColor.colorset"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "Contents.json").write_text(
            '{\n  "colors" : [\n%s,\n%s\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
            % (entry(CINNABAR, False), entry("#C9826E", True)))


if __name__ == "__main__":
    import app_art
    app_art.build(rsvg, MAC_ASSETS, IOS_ASSETS)
    readme_assets()
    icons()
    menubar_icon()
    app_ornaments()
    about_painting()
    parchment_texture()
    accent_color()
