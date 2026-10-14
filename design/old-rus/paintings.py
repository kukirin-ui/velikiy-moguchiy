"""Public-domain paintings used by the README and the apps, and the aged-varnish colour grade.

Every source file is on Wikimedia Commons with a page that states it is in the public domain both in
Russia and in the United States; THIRD_PARTY.md lists them. The originals are downloaded into
design/old-rus/.cache (not committed); only graded crops are.
"""
import base64
import io
import time
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from ornament import CINNABAR, INK, LIGHT, PARCHMENT, SMOKE, UMBER

CACHE = Path(__file__).resolve().parent / ".cache"
USER_AGENT = "velikiy-moguchiy-design/0.1 (https://github.com/zigansh1n/velikiy-moguchiy)"

PAINTINGS = {
    "bogatyri": {
        "author": "Виктор Васнецов", "title": "Богатыри", "year": "1881–1898",
        "page": "https://commons.wikimedia.org/wiki/File:Viktor_Vasnetsov_-_Богатыри_-_Google_Art_Project.jpg",
        "url": "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/Viktor_Vasnetsov_-_%D0%91%D0%BE%D0%B3%D0%B0%D1%82%D1%8B%D1%80%D0%B8_-_Google_Art_Project.jpg/1920px-Viktor_Vasnetsov_-_%D0%91%D0%BE%D0%B3%D0%B0%D1%82%D1%8B%D1%80%D0%B8_-_Google_Art_Project.jpg",
    },
    "guests": {
        "author": "Николай Рерих", "title": "Заморские гости", "year": "1901",
        "page": "https://commons.wikimedia.org/wiki/File:Nicholas_Roerich,_Guests_from_Overseas_(corrected_colour).jpg",
        "url": "https://upload.wikimedia.org/wikipedia/commons/a/a6/Nicholas_Roerich%2C_Guests_from_Overseas_%28corrected_colour%29.jpg",
    },
    "messenger": {
        "author": "Николай Рерих", "title": "Гонец. Восстал род на род", "year": "1897",
        "page": "https://commons.wikimedia.org/wiki/File:Messenger_(1897)_by_Nikolai_Roerich.jpg",
        "url": "https://upload.wikimedia.org/wikipedia/commons/6/63/Messenger_%281897%29_by_Nikolai_Roerich.jpg",
    },
    "wedding": {
        "author": "Андрей Рябушкин", "title": "Свадебный поезд в Москве (XVII столетие)", "year": "1901",
        "page": "https://commons.wikimedia.org/wiki/File:Ryabushkin_Wedding_train_in_Moscow_1901_gtg.jpg",
        "url": "https://upload.wikimedia.org/wikipedia/commons/3/3d/Ryabushkin_Wedding_train_in_Moscow_1901_gtg.jpg",
    },
    "firebird": {
        "author": "Иван Билибин", "title": "Заставка к «Сказке об Иване-царевиче, Жар-птице и о Сером волке»", "year": "1899",
        "page": "https://commons.wikimedia.org/wiki/File:Сказка_об_Иване-царевиче,_Жар-птице_и_Сером_Волке_1.jpg",
        "url": "https://upload.wikimedia.org/wikipedia/commons/1/18/%D0%A1%D0%BA%D0%B0%D0%B7%D0%BA%D0%B0_%D0%BE%D0%B1_%D0%98%D0%B2%D0%B0%D0%BD%D0%B5-%D1%86%D0%B0%D1%80%D0%B5%D0%B2%D0%B8%D1%87%D0%B5%2C_%D0%96%D0%B0%D1%80-%D0%BF%D1%82%D0%B8%D1%86%D0%B5_%D0%B8_%D0%A1%D0%B5%D1%80%D0%BE%D0%BC_%D0%92%D0%BE%D0%BB%D0%BA%D0%B5_1.jpg",
    },
}


def load(name):
    CACHE.mkdir(exist_ok=True)
    path = CACHE / f"{name}.jpg"
    if not path.exists():
        req = urllib.request.Request(PAINTINGS[name]["url"], headers={"User-Agent": USER_AGENT})
        path.write_bytes(urllib.request.urlopen(req).read())
        time.sleep(2)
    return Image.open(path).convert("RGB")


def _rgb(hexcolor):
    return np.array([int(hexcolor[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float32) / 255


def grade(img, strength=0.55):
    """Aged varnish: a gradient map through the palette blended with the warmed, desaturated original."""
    a = np.asarray(img, dtype=np.float32) / 255
    lum = a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    stops = [(0.0, INK), (0.22, UMBER), (0.5, SMOKE), (0.78, LIGHT), (1.0, PARCHMENT)]
    xs = [s[0] for s in stops]
    cols = np.stack([_rgb(c) for _, c in stops])
    mapped = np.stack([np.interp(lum, xs, cols[:, k]) for k in range(3)], axis=-1)
    grey = lum[..., None]
    desat = grey + (a - grey) * 0.62
    warm = desat * np.array([1.04, 0.98, 0.86], dtype=np.float32)
    out = mapped * strength + warm * (1 - strength)
    # lifted blacks and a soft vignette, like an old canvas under varnish
    h, w = lum.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    v = ((xx / w - 0.5) ** 2 + (yy / h - 0.5) ** 2) ** 0.5
    out *= (1 - 0.28 * np.clip(v - 0.25, 0, 1))[..., None]
    out = np.clip(out * 0.94 + _rgb(INK) * 0.06, 0, 1)
    return Image.fromarray((out * 255).astype(np.uint8))


def crop(img, box_frac, size):
    """box_frac = (left, top, right, bottom) as fractions; resized to size (w, h) keeping aspect by cropping."""
    w, h = img.size
    l, t, r, b = box_frac
    region = img.crop((int(l * w), int(t * h), int(r * w), int(b * h)))
    tw, th = size
    rw, rh = region.size
    if rw / rh > tw / th:
        nw = int(rh * tw / th)
        region = region.crop(((rw - nw) // 2, 0, (rw - nw) // 2 + nw, rh))
    else:
        nh = int(rw * th / tw)
        region = region.crop((0, (rh - nh) // 2, rw, (rh - nh) // 2 + nh))
    return region.resize(size, Image.LANCZOS).filter(ImageFilter.UnsharpMask(radius=1.2, percent=40, threshold=2))


def jpeg_bytes(img, quality=78):
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, optimize=True, progressive=True)
    return buf.getvalue()


def data_uri(img, quality=78):
    return "data:image/jpeg;base64," + base64.b64encode(jpeg_bytes(img, quality)).decode()
