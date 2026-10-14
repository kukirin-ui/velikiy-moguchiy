"""The «Великий & Могучий» lettering: Oglavie vyaz with gilded Monomakh capitals, as SVG paths."""
from ornament import CINNABAR, GOLD, MONOMAKH, OGLAVIE, UMBER, _font, f, glyph_box, text_path, text_width


def _in_vyaz(word):
    cmap = _font(OGLAVIE).getBestCmap()
    return all(ord(c) in cmap for c in word.upper())


def cap_height(font, size):
    return glyph_box("Е", font, size)[3]


def title(text, x, baseline, height, anchor="start", letter=CINNABAR, initial="url(#gold)", stroke=UMBER,
          rules=False, rule_color=GOLD):
    """Any heading in the house style: a gilded Monomakh capital, then Oglavie vyaz in capitals.

    `height` is the cap height of the vyaz. Words starting with a capital in `text` get a gilded capital
    (so «Великий & Могучий» gilds В, & and М). Returns (svg, width).
    """
    vyaz = height / cap_height(OGLAVIE, 1.0)
    cap = height * 1.34 / cap_height(MONOMAKH, 1.0)
    parts = []
    for i, word in enumerate(text.split(" ")):
        if i:
            parts.append((" ", OGLAVIE, vyaz))
        if not _in_vyaz(word):
            # Latin names (macOS, iPhone) are not in the vyaz; set them in the book hand
            parts.append((word, MONOMAKH, cap * 0.78))
        elif word == "&" or (word[:1].isupper() and word[:1].isalpha()):
            parts.append((word[0], MONOMAKH, cap * (0.8 if word == "&" else 1.0)))
            if word[1:]:
                parts.append((word[1:].upper(), OGLAVIE, vyaz))
        else:
            parts.append((word.upper(), OGLAVIE, vyaz))
    widths = [text_width(t, fnt, sz) for t, fnt, sz in parts]
    total = sum(widths)
    pen = x - {"start": 0, "middle": total / 2, "end": total}[anchor]
    sw = max(height * 0.03, 0.4)
    out, spans = [], []
    for (t, fnt, sz), w in zip(parts, widths):
        if t.strip():
            fill = initial if fnt == MONOMAKH else letter
            out.append(f'<path d="{text_path(t, fnt, sz, pen, baseline)}" fill="{fill}" stroke="{stroke}" '
                       f'stroke-width="{f(sw)}" stroke-linejoin="round"/>')
            if fnt == OGLAVIE:
                spans.append((pen, pen + w))
        pen += w
    if rules:
        for x0, x1 in spans:
            for y in (baseline - height * 1.16, baseline + height * 0.1):
                out.append(f'<rect x="{f(x0)}" y="{f(y)}" width="{f(x1 - x0)}" height="{f(height * 0.05)}" fill="{rule_color}"/>')
    return "".join(out), total


def logo(x, baseline, height, anchor="middle", **kw):
    return title("Великий & Могучий", x, baseline, height, anchor=anchor, **kw)
