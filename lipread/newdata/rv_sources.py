"""Источники кандидатов: RuTube (публичный JSON API) и VK Video (yt-dlp, без входа и токенов).

Вежливость: общий для процесса лимитер на домен (мин. интервал между запросами), при 429/403 пауза с растущим ожиданием.
VK: на 2026-10-13 анонимный листинг сообществ закрыт (редирект на VK ID, yt-dlp vk:uservideos: "Unable to extract cursor data"),
поэтому vk_discover раз в несколько часов пробует листинг одного сообщества; если заработает - источник включается сам.
Отдельные видео VK (vk.com/video-OID_ID) yt-dlp скачивает без входа: их можно подать файлом vk_urls.txt.
"""
from __future__ import annotations

import json
import re
import subprocess
import threading
import time
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

RT_CATEGORIES_OK = [58, 17, 8, 51, 50, 52, 67, 71, 43, 63, 64, 54, 73, 45, 72, 13, 57, 69, 68, 78, 55, 62]  # интервью, обучение, новости...
RT_BAD_CATEGORY_IDS = {6, 7, 5, 4, 41, 22, 42, 10, 70, 48, 60, 16, 19, 59, 53, 61, 2}
RT_BAD_CATEGORY_NAMES = {"Музыка", "Мультфильмы", "Сериалы", "Фильмы", "Аниме", "Видеоигры", "Детям", "Животные", "Природа", "Аудио",
                         "Аудиокниги", "Спорт", "Юмор", "Еда", "Охота и рыбалка", "Сад и огород", "Авто-мото"}

GENRES = ["интервью", "лекция", "подкаст", "влог", "обзор", "новости", "выступление", "урок", "разбор", "монолог", "вебинар",
          "ток-шоу", "беседа", "разговор", "доклад", "мастер-класс", "стрим разговорный", "пресс-конференция", "рассказываю",
          "ответы на вопросы", "мнение эксперта", "публичная лекция", "откровенный разговор", "эфир", "консультация"]
TOPICS = ["психология", "экономика", "история", "наука", "политика", "технологии", "здоровье", "бизнес", "образование", "философия",
          "искусство", "литература", "медицина", "право", "путешествия", "отношения", "карьера", "дети и воспитание", "религия",
          "космос", "программирование", "маркетинг", "инвестиции", "иностранные языки", "архитектура", "психотерапия",
          "предпринимательство", "общество", "культура", "финансы", "недвижимость", "саморазвитие", "красота", "журналистика",
          "музыка и музыканты", "кино и актёры", "наука и техника", "армия и безопасность", "женщины", "мужчины"]

VK_SEEDS = ["rbc", "ria", "tvrain", "meduzaproject", "lentach", "pravdaru", "vesti", "mash", "1tv", "russia1", "ntv_ru", "tvzvezda",
            "ren_tv", "vgudkov", "dudy", "kommersant", "tass_agency", "pozneronline", "lectoriumtv", "postnauka", "arzamas",
            "polit_ru", "thetheoryandpractice", "tproger", "podcast_ru", "ykt_podcast", "hsetv", "mgu", "spbu", "skolkovo"]


class Limiter:
    """Мин. интервал между запросами к домену + общая пауза при блокировке (потокобезопасно)."""

    def __init__(self, min_gap: float):
        self.gap = min_gap
        self.lock = threading.Lock()
        self.next = 0.0
        self.pause_until = 0.0
        self.strikes = 0

    def wait(self):
        with self.lock:
            now = time.time()
            t = max(self.next, self.pause_until, now)
            self.next = t + self.gap
        if t > now:
            time.sleep(t - now)

    def blocked(self):
        with self.lock:
            self.strikes += 1
            d = min(900, 30 * 2 ** (self.strikes - 1))
            self.pause_until = time.time() + d
            return d

    def ok(self):
        with self.lock:
            self.strikes = 0


RT = Limiter(1.2)
VK = Limiter(5.0)
_sess = requests.Session()
_sess.headers.update({"User-Agent": UA, "Accept": "application/json"})


def rt_get(url, params=None, tries=4):
    """-> (json|None, kind) kind: ok|blocked|error."""
    for _ in range(tries):
        RT.wait()
        try:
            r = _sess.get(url, params=params, timeout=25)
        except requests.RequestException:
            time.sleep(3)
            continue
        if r.status_code in (429, 403):
            RT.blocked()
            continue
        if r.status_code == 200:
            try:
                d = r.json()
                RT.ok()
                return d, "ok"
            except ValueError:
                RT.blocked()
                continue
        if r.status_code == 404:
            return None, "error"
        time.sleep(3)
    return None, "blocked"


def rt_entry(x: dict):
    cat = x.get("category") or {}
    a = x.get("author") or {}
    if x.get("is_livestream") or x.get("is_adult") or x.get("is_paid") or x.get("is_audio") or x.get("is_hidden") or x.get("is_deleted"):
        return None
    return {"id": "rt_" + x["id"], "raw_id": x["id"], "title": x.get("title") or "", "description": (x.get("description") or "")[:600],
            "duration": x.get("duration"), "channel": str(a.get("id") or a.get("name") or ""), "channel_name": a.get("name"),
            "category": cat.get("name") or "", "category_id": cat.get("id"), "hits": x.get("hits"),
            "url": f"https://rutube.ru/video/{x['id']}/", "site": "rutube"}


def rt_search(query: str, order: str | None = None):
    p = {"query": query}
    if order:
        p["order"] = order
    d, kind = rt_get("https://rutube.ru/api/search/video/", p)
    if d is None:
        return [], kind
    return [e for e in (rt_entry(x) for x in d.get("results", [])) if e], "ok"


def rt_person(author_id, page: int):
    d, kind = rt_get(f"https://rutube.ru/api/video/person/{author_id}/", {"page": page})
    if d is None:
        return [], False, kind
    return [e for e in (rt_entry(x) for x in d.get("results", [])) if e], bool(d.get("has_next")), "ok"


def rt_category(cat_id, page: int):
    d, kind = rt_get(f"https://rutube.ru/api/video/category/{cat_id}/", {"page": page})
    if d is None:
        return [], False, kind
    return [e for e in (rt_entry(x) for x in d.get("results", [])) if e], bool(d.get("has_next")), "ok"


def search_queries():
    import random
    qs = [f"{g} {t}" for g in GENRES for t in TOPICS]
    random.Random(11).shuffle(qs)
    return qs


# ------------------------------------------------------------------------------------------------------------- VK
def vk_list(slug: str, n=60):
    """yt-dlp --flat-playlist по странице сообщества. -> (entries, kind). kind: ok|unavailable|blocked."""
    VK.wait()
    p = subprocess.run(["yt-dlp", "--no-warnings", "--flat-playlist", "-J", "--playlist-end", str(n), f"https://vkvideo.ru/@{slug}"],
                       capture_output=True, text=True, timeout=180)
    err = p.stderr
    if p.returncode != 0 or not p.stdout.strip() or p.stdout.strip() == "null":
        if any(k in err for k in ("429", "403", "Too Many")):
            VK.blocked()
            return [], "blocked"
        return [], "unavailable"
    VK.ok()
    out = []
    for e in json.loads(p.stdout).get("entries") or []:
        vid = e.get("id") or ""
        m = re.match(r"^(-?\d+)_(\d+)$", vid)
        if not m or not e.get("duration"):
            continue
        out.append({"id": "vk_" + vid.replace("-", "m"), "raw_id": vid, "title": e.get("title") or "", "description": "",
                    "duration": e.get("duration"), "channel": "vk" + m.group(1), "channel_name": slug, "category": "", "category_id": None,
                    "hits": e.get("view_count"), "url": f"https://vk.com/video{vid}", "site": "vk"})
    return out, "ok"


def vk_file_entries(path: Path):
    """vk_urls.txt: по строке на видео (https://vk.com/video-OID_ID или OID_ID). Длительность неизвестна: проверит s2."""
    out = []
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        m = re.search(r"(-?\d+_\d+)", line)
        if m:
            vid = m.group(1)
            out.append({"id": "vk_" + vid.replace("-", "m"), "raw_id": vid, "title": "", "description": "", "duration": 600,
                        "channel": "vk" + vid.split("_")[0], "channel_name": "", "category": "", "category_id": None, "hits": None,
                        "url": f"https://vk.com/video{vid}", "site": "vk"})
    return out
