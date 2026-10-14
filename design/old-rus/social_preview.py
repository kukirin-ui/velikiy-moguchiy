"""The 1280 × 640 cover of the repository (GitHub → Settings → Social preview), shown wherever a link to
it is pasted: Bilibin's headpiece to the Firebird tale in the README frame, with the lettering and the
tagline under it.

    .venv/bin/python design/old-rus/social_preview.py     # same setup as make_assets.py

Writes docs/assets/social-preview.png. The painting has no people in it, so the card shows no faces.
"""
from ornament import (CINNABAR, MONOMAKH, OCHRE, PARCHMENT, SERIF_ITALIC, UMBER, f, gold_gradient, krin,
                      scroll_pair, svg, text_path)
from lettering import logo
from make_assets import ROOT, _band_frame, png_opaque, rsvg
import paintings

OUT = ROOT / "docs/assets/social-preview.png"


def social_preview():
    W, H, B = 1280, 640, 30
    inner_x, inner_w = B, W - 2 * B
    pic_y, pic_h = B, 322
    band_y = pic_y + pic_h

    painting = paintings.grade(paintings.crop(paintings.load("firebird"), (0.0, 0.0, 0.982, 0.985),
                                              (int(inner_w * 1.5), int(pic_h * 1.5))), strength=0.3)
    body = [f'<rect width="{W}" height="{H}" fill="{PARCHMENT}"/>', _band_frame(W, H, B)]
    body.append(f'<image x="{inner_x}" y="{pic_y}" width="{inner_w}" height="{pic_h}" preserveAspectRatio="xMidYMid slice" '
                f'xlink:href="{paintings.data_uri(painting, 82)}"/>')
    body.append(f'<rect x="{inner_x}" y="{band_y}" width="{inner_w}" height="3" fill="url(#gold)"/>')
    body.append(f'<rect x="{inner_x}" y="{band_y + 6}" width="{inner_w}" height="1" fill="{CINNABAR}"/>')

    cx = W / 2
    g, tw = logo(cx, band_y + 124, 70, rules=False)
    body.append(g)
    for side in (-1, 1):
        x = cx + side * (tw / 2 + 66)
        body.append(krin(x, band_y + 128, 72, sw=1.0))
        body.append(f'<g transform="translate({f(x + side * 38)},{band_y + 96}) scale({side},1)">'
                    f'{scroll_pair(46, 0, 92, 28, OCHRE, 2.8)}</g>')
    body.append(f'<path d="{text_path("русская голосовая диктовка для Mac, iPhone, Android и Windows", MONOMAKH, 34, cx, band_y + 186, "middle")}" '
                f'fill="{UMBER}"/>')
    body.append(f'<path d="{text_path("распознавание речи · чтение по губам · открытый код", SERIF_ITALIC, 24, cx, band_y + 232, "middle")}" '
                f'fill="{CINNABAR}"/>')

    rsvg(svg(W, H, "".join(body), gold_gradient()), OUT, W, H)
    png_opaque(OUT, PARCHMENT)


if __name__ == "__main__":
    social_preview()
