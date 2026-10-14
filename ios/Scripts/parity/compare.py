#!/usr/bin/env python3
"""Keyboard parity: compares screenshots of Великий & Могучий RU/EN with Apple's system
keyboard taken in the same simulator, plus screenshots from a real iPhone.

usage: compare.py --reference DIR --ours DIR --device DIR --out DIR
Exit code 1 when any layout is off by more than TOLERANCE_PT.

Geometry comes from pixels, the same way for both keyboards: key rectangles
(the drawn caps), rows, the keyboard's top edge, the suggestion strip and the
bounding box of each key's glyph. Apple's accessibility key zones (touch areas,
not caps) are compared with our key centres as an extra check; a third-party
keyboard runs in its own process, so its keys are not in the app's tree.
"""
import argparse
import html
import json
import os
import sys

import numpy as np
from PIL import Image

TOLERANCE_PT = 1.0
IOS_BAND_PT = 17.0
SCALE = 3.0
PIXEL_DIFF_LEVEL = 24


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int32)


def luminance(rgb):
    return (rgb[..., 0] * 299 + rgb[..., 1] * 587 + rgb[..., 2] * 114) // 1000


def is_dark(rgb):
    return luminance(rgb[int(rgb.shape[0] * 0.9):]).mean() < 100


def key_mask(rgb):
    lum = luminance(rgb)
    blue = (rgb[..., 2] > 200) & (rgb[..., 0] < 90)
    if is_dark(rgb):
        return ((lum > 45) & (lum < 140)) | blue
    return (lum > 245) | blue


def runs(flags, min_len, bridge=0):
    out, start = [], None
    for i, v in enumerate(flags):
        if v and start is None:
            start = i
        if not v and start is not None:
            out.append([start, i])
            start = None
    if start is not None:
        out.append([start, len(flags)])
    merged = []
    for r in out:
        if merged and r[0] - merged[-1][1] < bridge:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return [r for r in merged if r[1] - r[0] >= min_len]


def detect(rgb):
    """Rows of key rectangles (px), the keyboard's top edge (px) and glyph boxes."""
    h, w, _ = rgb.shape
    mask = key_mask(rgb)
    top_limit = 0
    row_on = mask.mean(axis=1) > 0.2
    spans = runs(row_on, min_len=int(30 * SCALE))
    # Keyboard rows sit 8-12 pt apart; anything further up (a text field, a
    # messenger's input bar) is not part of the keyboard.
    while len(spans) > 1 and spans[-1][0] - spans[-2][1] > 20 * SCALE:
        spans.pop()
    block = [spans[-1]] if spans else []
    for span in reversed(spans[:-1]):
        if block[0][0] - span[1] > 20 * SCALE:
            break
        block.insert(0, span)
    rows = []
    for y0, y1 in block:
        band = mask[y0 + 8:y0 + 16].mean(axis=0) > 0.5
        keys = [(x0, x1, y0, y1) for x0, x1 in runs(band, min_len=int(10 * SCALE), bridge=9)]
        rows.append(keys)
    if not rows:
        return None
    top_limit = max(0, rows[0][0][2] - int(120 * SCALE))
    first_top = rows[0][0][2]
    lum = luminance(rgb)
    # The keyboard's top edge: walk up from just above the first row until the
    # colour leaves the keyboard backdrop, in a few columns clear of the
    # suggestion text and dividers; the median ignores one unlucky column.
    edges = []
    for fraction in (0.27, 0.42, 0.58, 0.73):
        x = int(w * fraction)
        y = first_top - int(3 * SCALE)
        panel = int(lum[y, x])
        while y > top_limit and abs(int(lum[y - 1, x]) - panel) <= 6:
            y -= 1
        edges.append(y)
    panel_top = int(np.median(edges))
    glyphs = []
    dark = is_dark(rgb)
    for row in rows:
        row_glyphs = []
        for (x0, x1, y0, y1) in row:
            inner = lum[y0 + 2:y1 - 2, x0 + 2:x1 - 2]
            base = np.median(inner)
            ink = inner > base + 70 if dark else inner < base - 70
            ys, xs = np.nonzero(ink)
            row_glyphs.append(
                None if len(xs) < 4 else
                (x0 + 2 + xs.min(), x0 + 2 + xs.max(), y0 + 2 + ys.min(), y0 + 2 + ys.max()))
        glyphs.append(row_glyphs)
    return {"rows": rows, "panel_top": panel_top, "glyphs": glyphs, "height": h, "width": w}


def pt(v):
    return v / SCALE


def glyph_excluded(row_index, key_index, rows):
    """Keys whose content differs by design: our dictation key sits in Apple's
    emoji slot, and the space bar's corner mark follows the phone's settings."""
    last = len(rows) - 1
    if row_index != last or len(rows[last]) < 3 or len(rows) < 4:
        return False
    widths = [k[1] - k[0] for k in rows[last]]
    return key_index == 1 or key_index == widths.index(max(widths))


def compare(ref_path, ours_path, align_rows=False, ax_path=None):
    ref_img, ours_img = load(ref_path), load(ours_path)
    ref, ours = detect(ref_img), detect(ours_img)
    result = {"problems": [], "keys": [], "max_rect": 0.0, "max_glyph": 0.0}
    if ref is None or ours is None:
        result["problems"].append("no keyboard found" + (" in ours" if ours is None else " in Apple's"))
        result["max_rect"] = 99
        return result, ref, ours
    dy = 0
    if align_rows:  # device screenshots are cropped: line the first rows up
        dy = ref["rows"][0][0][2] - ours["rows"][0][0][2]
    if len(ref["rows"]) != len(ours["rows"]):
        result["problems"].append(f"rows: Apple {len(ref['rows'])}, ours {len(ours['rows'])}")
        result["max_rect"] = 99
    for ri, (rrow, orow) in enumerate(zip(ref["rows"], ours["rows"])):
        if len(rrow) != len(orow):
            result["problems"].append(f"row {ri + 1}: Apple {len(rrow)} keys, ours {len(orow)}")
            result["max_rect"] = 99
            continue
        for ki, (rk, ok) in enumerate(zip(rrow, orow)):
            d = max(abs(rk[0] - ok[0]), abs(rk[1] - ok[1]),
                    abs(rk[2] - ok[2] - dy), abs(rk[3] - ok[3] - dy)) / SCALE
            rg, og = ref["glyphs"][ri][ki], ours["glyphs"][ri][ki]
            excluded = glyph_excluded(ri, ki, ref["rows"])
            gw = 0.0
            if rg is None and og is None:
                gd = 0.0
            elif rg is None or og is None:
                gd = 99.0
            else:
                # Position, not shape: the centre and the top and bottom edges.
                # Apple draws keys with a private cut of San Francisco whose
                # round letters are narrower; apps only get the public one, so
                # glyph widths are reported (glyph_width) but not gated.
                gd = max(abs((rg[0] + rg[1]) - (og[0] + og[1])) / 2,
                         abs(rg[2] - og[2] - dy), abs(rg[3] - og[3] - dy)) / SCALE
                gw = abs((rg[1] - rg[0]) - (og[1] - og[0])) / SCALE
            result["keys"].append({
                "row": ri + 1, "key": ki + 1, "rect_delta": round(d, 2),
                "glyph_delta": None if excluded else round(gd, 2),
                "glyph_width": None if excluded else round(gw, 2),
                "apple": [round(pt(v), 2) for v in rk], "ours": [round(pt(v), 2) for v in ok],
            })
            result["max_rect"] = max(result["max_rect"], d)
            if not excluded:
                result["max_glyph"] = max(result["max_glyph"], gd)
    ref_strip = ref["rows"][0][0][2] - ref["panel_top"]
    ours_strip = ours["rows"][0][0][2] - ours["panel_top"]
    result["strip"] = {"apple": round(pt(ref_strip), 2), "ours": round(pt(ours_strip), 2)}
    # iOS 26 sometimes frames a third-party keyboard 17 pt taller than the view
    # the extension asked for and draws its backdrop over the extra band (the
    # host app gets a 352 pt keyboard frame instead of 335; the extension's own
    # window stays at its height). The extension cannot see or remove it, so it
    # is reported apart and the keyboard itself is compared without it.
    band = (ours_strip - ref_strip) / SCALE
    result["ios_band"] = round(band, 2) if IOS_BAND_PT - 1 <= band <= IOS_BAND_PT + 1 else 0.0
    # Only the band itself is taken off; anything beyond 17 pt counts as ours.
    band_px = IOS_BAND_PT * SCALE if result["ios_band"] else 0.0
    result["strip_delta"] = abs(ref_strip - (ours_strip - band_px)) / SCALE
    if not align_rows:
        result["total"] = {"apple": round(pt(ref["height"] - ref["panel_top"]), 2),
                           "ours": round(pt(ours["height"] - ours["panel_top"]), 2)}
        result["total_delta"] = abs(ref["panel_top"] - (ours["panel_top"] + band_px)) / SCALE
    else:
        result["total_delta"] = 0.0
    if ax_path and os.path.exists(ax_path):
        centres = [((k[0] + k[1]) / 2 / SCALE, (k[2] + k[3]) / 2 / SCALE)
                   for row in ours["rows"] for k in row]
        worst = 0.0
        lines = open(ax_path, encoding="utf-8").read().splitlines()
        # Zones are in screen points; the screenshot keeps only the bottom.
        screen = next((float(l.split("\t")[1]) for l in lines if l.startswith("#screen")), None)
        offset = screen - ours["height"] / SCALE if screen else 0.0
        for line in lines:
            parts = line.split("\t")
            if len(parts) != 5 or line.startswith("#"):
                continue
            x, y, w, h = map(float, parts[1:])
            y -= offset
            if w > 60:  # wide zones (space, return) reach into neighbours' gaps
                continue
            cx, cy = x + w / 2, y + h / 2
            if not centres:
                break
            nearest = min(centres, key=lambda c: (c[0] - cx) ** 2 + (c[1] - cy) ** 2)
            worst = max(worst, abs(nearest[0] - cx))
        result["ax_centre_delta"] = round(worst, 2)
    return result, ref, ours


def outline(img, det, color):
    out = img.copy()
    if det is None:
        return out
    for row in det["rows"]:
        for (x0, x1, y0, y1) in row:
            out[y0, x0:x1] = color
            out[y1 - 1, x0:x1] = color
            out[y0:y1, x0] = color
            out[y0:y1, x1 - 1] = color
    return out


def write_images(name, ref_path, ours_path, ref, ours, out_dir, align_rows):
    ref_img, ours_img = load(ref_path), load(ours_path)
    top = min(d["panel_top"] for d in (ref, ours) if d) - 10 if ref and ours else 0
    if align_rows and ref and ours:
        dy = ref["rows"][0][0][2] - ours["rows"][0][0][2]
        ours_img = np.roll(ours_img, dy, axis=0)
    h = min(ref_img.shape[0], ours_img.shape[0])
    w = min(ref_img.shape[1], ours_img.shape[1])
    a, b = ref_img[top:h, :w], ours_img[top:h, :w]
    diff = np.abs(a - b).max(axis=2)
    heat = (a * 0.35).astype(np.uint8)
    hot = diff > PIXEL_DIFF_LEVEL
    heat[hot] = np.stack([np.full(hot.sum(), 255), 40 + 0 * diff[hot], 40 + 0 * diff[hot]], axis=1)
    pane = np.concatenate([
        outline(a, None, (255, 0, 0)), np.full((a.shape[0], 12, 3), 128),
        b, np.full((a.shape[0], 12, 3), 128), heat], axis=1).astype(np.uint8)
    image = Image.fromarray(pane)
    image = image.resize((image.width // 3, image.height // 3), Image.LANCZOS)
    path = os.path.join(out_dir, f"{name}.png")
    image.save(path, optimize=True)
    return os.path.basename(path), round(float(hot.mean() * 100), 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", required=True)
    parser.add_argument("--ours", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    cases = []
    for name in sorted(os.listdir(args.reference)):
        if not (name.startswith("apple-") and name.endswith(".png")):
            continue
        ours = os.path.join(args.ours, "ours-" + name[len("apple-"):])
        cases.append((name[len("apple-"):-4], os.path.join(args.reference, name), ours,
                      os.path.join(args.reference, name[:-4] + ".ax.tsv"), False))
    device_map = {"iphone-393-en-dark.jpg": "en-dark-text-return-ac1",
                  "iphone-393-ru-dark.jpg": "ru-dark-text-return-ac1"}
    for name, ours_case in device_map.items():
        path = os.path.join(args.device, name)
        if os.path.exists(path):
            cases.append(("device " + name[:-4], path,
                          os.path.join(args.ours, f"ours-{ours_case}.png"),
                          os.path.join(args.reference, f"apple-{ours_case}.png"), True))

    rows, failed, offenders = [], False, []
    for label, ref_path, ours_path, ax_path, align in cases:
        if not os.path.exists(ours_path):
            rows.append({"case": label, "status": "FAIL", "problems": ["ours missing"]})
            failed = True
            continue
        allowance = 0.0
        if align:
            # A screenshot from a real iPhone (another iOS build, JPEG): Apple's
            # own keyboard differs from its simulator capture by a little, and
            # that difference is added to the tolerance.
            apple_sim = ax_path
            ax_path = None
            baseline, _, _ = compare(ref_path, apple_sim, True)
            allowance = round(max(baseline["max_rect"], baseline["max_glyph"]), 2)
        result, ref, ours = compare(ref_path, ours_path, align, ax_path)
        image, diff_pct = write_images(label.replace(" ", "_"), ref_path, ours_path, ref, ours,
                                       args.out, align)
        worst = max(result["max_rect"], result["max_glyph"], result.get("strip_delta", 0),
                    result.get("total_delta", 0))
        ok = worst <= TOLERANCE_PT + allowance and not result["problems"]
        if allowance:
            result["problems"].append(f"tolerance {TOLERANCE_PT} + {allowance} pt (Apple phone vs Apple simulator)")
        failed |= not ok
        for k in result["keys"]:
            offenders.append((max(k["rect_delta"], k["glyph_delta"] or 0), label, k))
        rows.append({
            "case": label, "status": "ok" if ok else "FAIL", "worst": round(worst, 2),
            "rect": round(result["max_rect"], 2), "glyph": round(result["max_glyph"], 2),
            "strip": result.get("strip"), "total": result.get("total"),
            "ax": result.get("ax_centre_delta"), "pixels": diff_pct, "image": image,
            "ios_band": result.get("ios_band"),
            "problems": result["problems"],
        })

    offenders.sort(key=lambda o: -o[0])
    summary = {"tolerance_pt": TOLERANCE_PT, "passed": not failed, "cases": rows,
               "worst_keys": [{"case": c, "delta": round(d, 2), **k} for d, c, k in offenders[:15]]}
    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)

    def cell(v):
        return html.escape("—" if v is None else str(v))
    lines = [
        "<!doctype html><meta charset=utf-8><title>Keyboard parity</title>",
        "<style>body{font:14px -apple-system,sans-serif;margin:16px;background:#fff;color:#111}"
        "table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:3px 6px;text-align:left}"
        ".FAIL{background:#fdd}.ok{background:#dfd}img{max-width:100%;border:1px solid #ccc}</style>",
        f"<h1>Keyboard parity: {'passed' if not failed else 'FAILED'}</h1>",
        f"<p>Tolerance {TOLERANCE_PT} pt per key rectangle, glyph box, strip height and "
        "keyboard height; glyphs are compared by position (centre, top, bottom). Glyph widths "
        "are not gated: Apple draws its keys with a private cut of San Francisco whose round "
        "letters (O, Q, C, Ю) are up to 2 pt narrower than the public system font. "
        "Images: Apple | ours | pixels that differ (red).</p>"
        "<p><b>iOS band:</b> in some apps iOS frames a third-party keyboard 17 pt taller than "
        "the keyboard asked for (the host app gets a 352 pt keyboard frame instead of Apple's "
        "335; the extension's own window is the same 260 pt as Apple's keyboard) and draws "
        "empty backdrop over the extra band above the keys. It also shows on a real iPhone, e.g. in "
        "Telegram, never in Safari, and the extension can neither see nor remove it "
        "(Apple Developer Forums, FB24460699). Cases where it appeared are marked with its "
        "size; strip and height are compared without it.</p>",
        "<table><tr><th>layout</th><th>result</th><th>worst, pt</th><th>key rect</th>"
        "<th>glyph</th><th>strip Apple/ours</th><th>height Apple/ours</th><th>AX centre</th>"
        "<th>pixels differ</th><th>iOS band</th><th>problems</th></tr>",
    ]
    for r in rows:
        strip = r.get("strip") or {}
        total = r.get("total") or {}
        lines.append(
            f"<tr class={r['status']}><td><a href='#{html.escape(r['case'])}'>{html.escape(r['case'])}</a></td>"
            f"<td>{r['status']}</td><td>{cell(r.get('worst'))}</td><td>{cell(r.get('rect'))}</td>"
            f"<td>{cell(r.get('glyph'))}</td><td>{cell(strip.get('apple'))} / {cell(strip.get('ours'))}</td>"
            f"<td>{cell(total.get('apple'))} / {cell(total.get('ours'))}</td><td>{cell(r.get('ax'))}</td>"
            f"<td>{cell(r.get('pixels'))} %</td><td>{cell(r.get('ios_band'))}</td>"
            f"<td>{html.escape('; '.join(r.get('problems', [])))}</td></tr>")
    lines.append("</table><h2>Worst keys</h2><table><tr><th>layout</th><th>row</th><th>key</th>"
                 "<th>Δ pt</th><th>Apple x0,x1,y0,y1</th><th>ours</th></tr>")
    for d, c, k in offenders[:15]:
        lines.append(f"<tr><td>{html.escape(c)}</td><td>{k['row']}</td><td>{k['key']}</td>"
                     f"<td>{d:.2f}</td><td>{k['apple']}</td><td>{k['ours']}</td></tr>")
    lines.append("</table>")
    for r in rows:
        if r.get("image"):
            lines.append(f"<h3 id='{html.escape(r['case'])}'>{html.escape(r['case'])} — {r['status']}</h3>"
                         f"<img src='{r['image']}'>")
    with open(os.path.join(args.out, "report.html"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    for r in rows:
        print(f"{r['status']:4s} {r['case']:34s} worst {cell(r.get('worst')):>5s} pt  band {cell(r.get('ios_band'))}  "
              f"rect {cell(r.get('rect'))} glyph {cell(r.get('glyph'))} "
              f"pixels {cell(r.get('pixels'))}%  {'; '.join(r.get('problems', []))}")
    print(f"report: {os.path.join(args.out, 'report.html')}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
