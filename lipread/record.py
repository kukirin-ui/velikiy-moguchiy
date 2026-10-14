"""Рекордер: показывает русскую фразу, вы беззвучно проговариваете её, скрипт пишет clips/NNN.mp4 + NNN.txt.

Управление (окно с камерой должно быть в фокусе):
    Пробел  начать запись / закончить запись (клип сохраняется, показывается следующая фраза)
    R       повторить: во время записи отбросить дубль; в ожидании вернуться к предыдущей фразе
            и перезаписать её (старый клип удаляется)
    N       пропустить фразу (клип не пишется)
    F       полноэкранный режим
    Esc / Q выход (идущая запись отбрасывается; повторный запуск продолжит с первой незаписанной фразы)

Порции: `--out data/silent --phrases phrases_train_ru.txt --batch 50` пишет по 50 клипов за сеанс и останавливается
(экран «порция записана»); следующий запуск продолжает с первой незаписанной фразы.

Шёпот: `--whisper` пишет то же видео со звуком микрофона Mac (16 кГц моно, без потерь, ALAC внутри mp4); по умолчанию
фразы phrases_whisper_ru.txt и папка data/whisper. Фразу нужно проговорить шёпотом, а не беззвучно.

Запись: камера Mac (встроенная, не iPhone), 1280x720, видео пересэмплируется в ровные 25 fps (как ждёт
MultiVSR), без зеркала (зеркалится только превью), кодек H.264 через ffmpeg. Без `--whisper` звука нет.
macOS спросит доступ к камере (и с `--whisper` к микрофону) для приложения, из которого запущен скрипт
(Terminal, iTerm, Claude, VS Code).
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
WIN = "lipread-ru"
FPS = 25

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def find_font(size: int) -> ImageFont.FreeTypeFont:
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


# --- камера: выбор встроенной (идея из lipflow/camera.py) --------------------------------------------
def list_cameras() -> list[dict]:
    """Камеры в порядке индексов OpenCV. AVFoundation в OpenCV сортирует устройства по uniqueID, поэтому
    Continuity Camera (iPhone) часто оказывается под индексом 0."""
    if sys.platform != "darwin":
        return []
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeMuxed, AVMediaTypeVideo
    except ImportError:
        return []
    devs = list(AVCaptureDevice.devicesWithMediaType_(AVMediaTypeVideo)) + \
        list(AVCaptureDevice.devicesWithMediaType_(AVMediaTypeMuxed))
    devs.sort(key=lambda d: d.uniqueID())
    return [{"index": i, "name": str(d.localizedName()), "id": str(d.uniqueID()),
             "builtin": "BuiltIn" in str(d.deviceType())} for i, d in enumerate(devs)]


def resolve_camera(pref: str) -> int:
    if pref.isdigit():
        return int(pref)
    cams = list_cameras()
    if not cams:
        return 0
    if pref != "auto":
        for c in cams:
            if pref == c["id"] or pref.lower() in c["name"].lower():
                return c["index"]
    for c in cams:
        if c["builtin"]:
            return c["index"]
    non_phone = [c for c in cams if "iphone" not in c["name"].lower()]
    return (non_phone or cams)[0]["index"]


def open_camera(pref: str, width: int, height: int) -> cv2.VideoCapture:
    if os.path.exists(pref):  # видеофайл вместо камеры: для проверки без камеры (воспроизводится по кругу)
        cap = cv2.VideoCapture(pref)
        ok, frame = cap.read()
        if not ok:
            raise SystemExit(f"Не удалось прочитать {pref}")
        print(f"Источник: файл {pref}, {frame.shape[1]}x{frame.shape[0]}")
        return cap
    idx = resolve_camera(pref)
    backend = cv2.CAP_AVFOUNDATION if sys.platform == "darwin" else cv2.CAP_ANY
    cap = cv2.VideoCapture(idx, backend)
    if not cap.isOpened():
        raise SystemExit(
            "Камера не открылась. Если macOS ещё не спрашивала разрешение: System Settings -> Privacy & "
            "Security -> Camera -> включите приложение, из которого запущен скрипт (Terminal / iTerm / Claude / "
            "VS Code), и запустите снова.")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, 30)
    ok = False
    for _ in range(60):  # первые кадры камеры бывают чёрными / приходят с задержкой
        ok, frame = cap.read()
        if ok and frame is not None and frame.mean() > 1:
            break
        time.sleep(0.05)
    if not ok or frame is None:
        raise SystemExit("Камера открылась, но кадры не приходят. Проверьте разрешение на камеру "
                         "(см. README) и что её не занимает другое приложение.")
    names = {c["index"]: c["name"] for c in list_cameras()}
    print(f"Камера [{idx}] {names.get(idx, '?')}: {frame.shape[1]}x{frame.shape[0]}")
    return cap


# --- запись в mp4 ровными 25 fps -----------------------------------------------------------------------
class ClipWriter:
    """Принимает кадры с временными метками, пишет ровные 25 fps: для каждого тика 1/25 с берётся последний
    полученный кадр. Кодирование в потоке, чтобы не тормозить превью."""

    def __init__(self, path: Path, width: int, height: int):
        self.path = path
        self.q: queue.Queue = queue.Queue(maxsize=300)
        self.proc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{width}x{height}",
             "-r", str(FPS), "-i", "-", "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "16",
             "-pix_fmt", "yuv420p", str(path)],
            stdin=subprocess.PIPE)
        self.t0: float | None = None
        self.n_out = 0
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    def _pump(self):
        while True:
            fr = self.q.get()
            if fr is None:
                break
            try:
                self.proc.stdin.write(fr)
            except (BrokenPipeError, ValueError):
                break

    def add(self, frame: np.ndarray, t: float):
        if self.t0 is None:
            self.t0 = t
        while self.t0 + self.n_out / FPS <= t:
            try:
                self.q.put_nowait(frame.tobytes())
            except queue.Full:
                pass  # кодер не успевает: пропускаем (в ролике будет дубль соседнего кадра, редкость)
            self.n_out += 1

    @property
    def seconds(self) -> float:
        return self.n_out / FPS

    def close(self, keep=True) -> bool:
        self.q.put(None)
        self.thread.join(timeout=30)
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        rc = self.proc.wait(timeout=60)
        if not keep or rc != 0:
            self.path.unlink(missing_ok=True)
        return rc == 0 and keep


# --- микрофон -----------------------------------------------------------------------------------------
def list_mics() -> list[tuple[int, str]]:
    out = subprocess.run(["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                         capture_output=True, text=True).stderr
    mics, in_audio = [], False
    for line in out.splitlines():
        if "audio devices" in line:
            in_audio = True
        elif in_audio and (m := re.search(r"\[(\d+)\] (.+)$", line)):
            mics.append((int(m.group(1)), m.group(2).strip()))
    return mics


def resolve_mic(pref: str) -> int:
    if pref.isdigit():
        return int(pref)
    mics = list_mics()
    if pref != "auto":
        for i, name in mics:
            if pref.lower() in name.lower():
                return i
        raise SystemExit(f"Микрофон '{pref}' не найден: {mics}")
    for i, name in mics:
        if "macbook" in name.lower() or "built-in" in name.lower() or "встроен" in name.lower():
            return i
    non_phone = [i for i, name in mics if "iphone" not in name.lower()]
    return (non_phone or [i for i, _ in mics] or [0])[0]


class AudioTap:
    """Микрофон пишется весь сеанс, дубль вырезается по времени: у дубля нет задержки на открытие устройства.
    Куски по 40 мс с монотонным временем прихода; хранится последние 2 минуты."""
    RATE = 16000
    CHUNK = 1280  # байт: 40 мс s16le моно

    def __init__(self, pref: str):
        if os.path.exists(pref):  # аудиофайл вместо микрофона (тест), в реальном темпе по кругу
            inp = ["-re", "-stream_loop", "-1", "-i", pref]
            self.name = f"файл {pref}"
        else:
            idx = resolve_mic(pref)
            inp = ["-f", "avfoundation", "-i", f":{idx}"]
            self.name = f"[{idx}] " + dict(list_mics()).get(idx, "?")
        self.proc = subprocess.Popen(["ffmpeg", "-v", "error", "-nostdin", *inp, "-ac", "1", "-ar", str(self.RATE),
                                      "-f", "s16le", "-"], stdout=subprocess.PIPE)
        self.chunks: collections.deque = collections.deque(maxlen=120 * 25)
        self.level = 0.0
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        while True:
            b = self.proc.stdout.read(self.CHUNK)
            if not b:
                break
            self.chunks.append((time.monotonic(), b))
            x = np.frombuffer(b, np.int16).astype(np.float32)
            self.level = float(np.sqrt(np.mean(x * x)) / 32768) if len(x) else 0.0

    def alive(self) -> bool:
        return self.proc.poll() is None and bool(self.chunks) and time.monotonic() - self.chunks[-1][0] < 1.0

    def take(self, t0: float, t1: float) -> bytes:
        return b"".join(b for t, b in list(self.chunks) if t0 < t <= t1)

    def close(self):
        self.proc.kill()
        self.proc.wait()


def mux_audio(video: Path, pcm: bytes, seconds: float, dst: Path) -> bool:
    """video (без звука) + PCM s16le 16 кГц -> dst с дорожкой ALAC. Звук обрезается или добивается тишиной до длины видео
    (ffmpeg -shortest режет неточно, на кадр ALAC)."""
    n = int(round(seconds * AudioTap.RATE)) * 2
    raw = video.with_suffix(".pcm")
    raw.write_bytes(pcm[:n] + bytes(max(0, n - len(pcm))))
    rc = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-f", "s16le", "-ar", str(AudioTap.RATE),
                         "-ac", "1", "-i", str(raw), "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "alac",
                         str(dst)]).returncode
    raw.unlink(missing_ok=True)
    return rc == 0


# --- интерфейс ----------------------------------------------------------------------------------------
def wrap(text: str, font, max_w: int) -> list[str]:
    lines, cur = [], ""
    for w in text.split():
        trial = (cur + " " + w).strip()
        if font.getlength(trial) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


class UI:
    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.f_big = find_font(max(34, w // 24))
        self.f_mid = find_font(max(22, w // 48))
        self.f_small = find_font(max(18, w // 64))
        self._band_cache: tuple | None = None

    def phrase_band(self, text: str, header: str, recording: bool) -> np.ndarray:
        """RGBA-плашка вверху кадра (близко к объективу, чтобы глаза не уходили вниз)."""
        key = (text, header, recording)
        if self._band_cache and self._band_cache[0] == key:
            return self._band_cache[1]
        pad = 24
        lines = wrap(text, self.f_big, self.w - 2 * pad)
        lh = int(self.f_big.size * 1.25)
        band_h = pad * 2 + lh * len(lines) + int(self.f_small.size * 1.6)
        img = Image.new("RGBA", (self.w, band_h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.text((pad, 10), header, font=self.f_small, fill=(200, 200, 200, 255))
        y = 10 + int(self.f_small.size * 1.6)
        color = (255, 120, 120, 255) if recording else (255, 255, 255, 255)
        for ln in lines:
            d.text((pad, y), ln, font=self.f_big, fill=color)
            y += lh
        arr = np.array(img)
        self._band_cache = (key, arr)
        return arr

    def footer(self, text: str, color=(255, 255, 255)) -> np.ndarray:
        img = Image.new("RGBA", (self.w, int(self.f_mid.size * 2)), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.text((24, int(self.f_mid.size * 0.4)), text, font=self.f_mid, fill=(*color, 255))
        return np.array(img)

    @staticmethod
    def blend(frame: np.ndarray, overlay_rgba: np.ndarray, y: int, dim: float = 0.55):
        h = overlay_rgba.shape[0]
        y = max(0, min(y, frame.shape[0] - h))
        roi = frame[y:y + h]
        roi[:] = (roi * (1 - dim)).astype(np.uint8)  # затемнение под текстом
        a = overlay_rgba[..., 3:4].astype(np.float32) / 255.0
        rgb = overlay_rgba[..., :3][..., ::-1]  # RGB -> BGR
        roi[:] = (roi * (1 - a) + rgb * a).astype(np.uint8)


def load_phrases(path: Path) -> list[str]:
    ph = [l.strip() for l in path.read_text(encoding="utf8").splitlines() if l.strip() and not l.startswith("#")]
    if not ph:
        raise SystemExit(f"{path}: нет фраз")
    return ph


def count_clips(out: Path) -> int:
    return sum(1 for p in out.glob("*.mp4") if not p.name.startswith("."))


def first_missing(out: Path, n: int) -> int:
    for i in range(n):
        if not (out / f"{i + 1:03d}.mp4").exists():
            return i
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phrases", help="файл с фразами, по одной в строке (по умолчанию phrases_ru.txt, "
                                      "с --whisper phrases_whisper_ru.txt)")
    ap.add_argument("--out", help="папка для NNN.mp4 и NNN.txt (по умолчанию clips, с --whisper data/whisper)")
    ap.add_argument("--whisper", action="store_true", help="режим шёпота: видео + звук микрофона")
    ap.add_argument("--mic", default="auto",
                    help="auto (встроенный) | номер | часть названия микрофона | путь к аудиофайлу (тест)")
    ap.add_argument("--camera", default="auto", help="auto (встроенная) | номер | часть названия камеры | путь к видеофайлу (тест)")
    ap.add_argument("--dump-ui", metavar="PNG", help="без окна: сохранить кадр интерфейса в PNG и выйти (тест)")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--start", type=int, default=0, help="начать с фразы N (1..); по умолчанию с первой незаписанной")
    ap.add_argument("--batch", type=int, default=0,
                    help="порция: после N новых клипов за этот сеанс запись останавливается (0 = без лимита). "
                         "Повторный запуск продолжает с первой незаписанной фразы")
    ap.add_argument("--no-mirror", action="store_true", help="не зеркалить превью")
    ap.add_argument("--list-cameras", action="store_true", help="показать камеры и выйти")
    ap.add_argument("--check", action="store_true",
                    help="без окна: открыть камеру, записать 1 с в work/camera_check.mp4, выйти (проверка доступа)")
    a = ap.parse_args()
    a.phrases = a.phrases or str(ROOT / ("phrases_whisper_ru.txt" if a.whisper else "phrases_ru.txt"))
    a.out = a.out or str(ROOT / ("data/whisper" if a.whisper else "clips"))

    if a.list_cameras:
        for c in list_cameras():
            print(c)
        for i, name in list_mics():
            print({"mic": i, "name": name})
        return

    phrases = load_phrases(Path(a.phrases))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    cap = open_camera(a.camera, a.width, a.height)
    is_file = os.path.exists(a.camera)
    ok, frame = cap.read()
    fh, fw = frame.shape[:2]
    mic = AudioTap(a.mic) if a.whisper else None
    if mic:
        time.sleep(0.5)
        if not mic.alive():
            raise SystemExit("Микрофон не отдаёт звук. Разрешите доступ: System Settings -> Privacy & Security -> "
                             "Microphone -> приложение, из которого запущен скрипт, и запустите снова.")
        print(f"Микрофон {mic.name}")

    if a.check:
        p = ROOT / "work" / "camera_check.mp4"
        p.parent.mkdir(exist_ok=True)
        wr = ClipWriter(p.with_name(".check.mp4") if mic else p, fw, fh)
        t_start = time.monotonic()
        t_end = t_start + 1.0
        n = 0
        while time.monotonic() < t_end:
            ok, frame = cap.read()
            if is_file:
                time.sleep(1 / 30)
            if ok:
                wr.add(frame, time.monotonic())
                n += 1
        wr.close()
        cap.release()
        if mic:
            pcm = mic.take(t_start, time.monotonic())
            mic.close()
            ok = mux_audio(wr.path, pcm, wr.seconds, p)
            wr.path.unlink(missing_ok=True)
            print(f"Микрофон: {len(pcm) // 2 / AudioTap.RATE:.2f} с звука, уровень {mic.level:.4f}" + ("" if ok else ", ОШИБКА склейки"))
        print(f"Камера работает: {n} кадров за 1 с, записано {wr.n_out} кадров в {p}")
        return

    face_det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    ui = UI(fw, fh)
    idx = (a.start - 1) if a.start > 0 else first_missing(out, len(phrases))
    writer: ClipWriter | None = None
    rec_started = 0.0
    tmp_path = out / ".take.mp4"
    toast, toast_until = "", 0.0
    face_ok, frame_i = False, 0
    saved_now: set[int] = set()  # индексы фраз, записанных в этом сеансе (для лимита порции)

    if a.dump_ui:
        view = frame if a.no_mirror else cv2.flip(frame, 1)
        view = view.copy()
        ui.blend(view, ui.phrase_band(phrases[idx], f"Фраза {idx + 1} из {len(phrases)}", False), 0)
        foot = ui.footer("Пробел: начать.   Подождите ~0,5 с, затем проговорите, паузу ~0,5 с в конце.   R: назад   N: пропуск")
        ui.blend(view, foot, fh - foot.shape[0])
        cv2.imwrite(a.dump_ui, view)
        cap.release()
        print("UI ->", a.dump_ui)
        return

    cv2.namedWindow(WIN, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(WIN, min(fw, 1280), min(fh, 720))
    fullscreen = False

    def clip_paths(i):
        return out / f"{i + 1:03d}.mp4", out / f"{i + 1:03d}.txt"

    def stop_and_save():
        nonlocal writer, idx, toast, toast_until
        assert writer is not None
        t_stop = time.monotonic()
        secs = writer.seconds
        good = writer.close(keep=True)
        writer = None
        if not good:
            toast, toast_until = "Ошибка записи (ffmpeg), дубль не сохранён", time.monotonic() + 3
            return
        mp4, txt = clip_paths(idx)
        if mic:
            pcm = mic.take(rec_started, t_stop)
            good = mux_audio(tmp_path, pcm, secs, mp4)
            tmp_path.unlink(missing_ok=True)
            if not good:
                toast, toast_until = "Ошибка склейки звука, дубль не сохранён", time.monotonic() + 3
                return
        else:
            os.replace(tmp_path, mp4)
        txt.write_text(phrases[idx] + "\n", encoding="utf8")
        toast, toast_until = f"Сохранено {mp4.name} ({secs:.1f} с)", time.monotonic() + 2.0
        saved_now.add(idx)
        idx += 1

    def discard():
        nonlocal writer
        if writer is not None:
            writer.close(keep=False)
            writer = None

    print(f"Фраз: {len(phrases)}. Начинаю с {idx + 1}. Пробел: старт/стоп, R: повтор, N: пропуск, Esc: выход.")
    try:
        while True:
            ok, frame = cap.read()
            now = time.monotonic()
            if is_file:
                time.sleep(1 / 30)
                if not ok:
                    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
            if not ok:
                time.sleep(0.01)
                continue
            if writer is not None:
                writer.add(frame, now)
            frame_i += 1
            if frame_i % 6 == 0:  # лёгкий индикатор лица (Haar), не влияет на запись
                small = cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (fw // 4, fh // 4))
                faces = face_det.detectMultiScale(small, 1.2, 5, minSize=(40, 40))
                face_ok = len(faces) > 0

            view = frame if a.no_mirror else cv2.flip(frame, 1)
            view = view.copy()
            done = idx >= len(phrases) or (a.batch > 0 and len(saved_now) >= a.batch and writer is None)
            recording = writer is not None
            if idx >= len(phrases):
                band = ui.phrase_band("Готово! Все фразы записаны.", f"{len(phrases)} клипов в {out}", False)
            elif done:
                band = ui.phrase_band(f"Порция из {a.batch} клипов записана. Отдохните!",
                                      f"Всего записано {count_clips(out)} из {len(phrases)}. Esc: выход, "
                                      f"следующий запуск продолжит с фразы {idx + 1}", False)
            else:
                header = f"Фраза {idx + 1} из {len(phrases)}"
                if a.batch > 0:
                    header += f"     порция {len(saved_now)}/{a.batch}"
                if recording:
                    header += f"     ● ЗАПИСЬ {now - rec_started:4.1f} с"
                band = ui.phrase_band(phrases[idx], header, recording)
            ui.blend(view, band, 0)

            if recording:
                status = ("Шёпотом" if mic else "Беззвучно") + " проговорите фразу. Пробел: стоп.   R: отбросить дубль"
                col = (255, 140, 140)
            elif done:
                status, col = "Esc: выход.   R: перезаписать последнюю", (200, 255, 200)
            else:
                status = "Пробел: начать.   Подождите ~0,5 с, затем проговорите, паузу ~0,5 с в конце.   R: назад   N: пропуск"
                col = (255, 255, 255)
            foot = ui.footer(status, col)
            ui.blend(view, foot, fh - foot.shape[0])
            if not face_ok:
                cv2.putText(view, "no face detected", (20, fh - foot.shape[0] - 14), cv2.FONT_HERSHEY_SIMPLEX,
                            0.8, (0, 165, 255), 2)
            if recording:
                cv2.circle(view, (fw - 40, 40 + band.shape[0] // 2 - 20), 14, (0, 0, 255), -1)
            if mic:  # индикатор громкости: шёпот должен заметно двигать полоску
                y0 = band.shape[0] + 10
                lvl = min(1.0, (max(mic.level, 1e-5) / 0.1) ** 0.5)
                cv2.rectangle(view, (fw - 40, y0), (fw - 24, y0 + 200), (80, 80, 80), 1)
                cv2.rectangle(view, (fw - 39, y0 + 200 - int(199 * lvl)), (fw - 25, y0 + 199),
                              (0, 200, 0) if mic.alive() else (0, 0, 255), -1)
            if now < toast_until:
                cv2.putText(view, toast, (20, fh - foot.shape[0] - 48), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2)

            cv2.imshow(WIN, view)
            k = cv2.waitKey(1)
            if k == -1:
                continue
            k &= 0xFFFF
            if k in (27, ord("q"), ord("Q"), 0x439, 0x419):  # Esc, q, й
                break
            elif k == 32 and not done:  # Пробел
                if writer is None:
                    writer = ClipWriter(tmp_path, fw, fh)
                    rec_started = now
                else:
                    stop_and_save()
            elif k in (ord("r"), ord("R"), 0x43A, 0x41A):  # r, к
                if writer is not None:
                    discard()
                    toast, toast_until = "Дубль отброшен", now + 1.5
                elif idx > 0:
                    idx -= 1
                    saved_now.discard(idx)
                    for p in clip_paths(idx):
                        p.unlink(missing_ok=True)
                    toast, toast_until = f"Перезаписываем фразу {idx + 1}", now + 1.5
            elif k in (ord("n"), ord("N"), 0x442, 0x422) and writer is None and not done:  # n, т
                idx += 1
            elif k in (ord("f"), ord("F"), 0x430, 0x410):  # f, а
                fullscreen = not fullscreen
                cv2.setWindowProperty(WIN, cv2.WND_PROP_FULLSCREEN,
                                      cv2.WINDOW_FULLSCREEN if fullscreen else cv2.WINDOW_NORMAL)
            try:
                if cv2.getWindowProperty(WIN, cv2.WND_PROP_VISIBLE) < 1:
                    break
            except cv2.error:
                break
    finally:
        discard()
        cap.release()
        if mic:
            mic.close()
        cv2.destroyAllWindows()
        tmp_path.unlink(missing_ok=True)
    n = count_clips(out)
    print(f"Готово. Клипов в {out}: {n} из {len(phrases)}, в этом сеансе новых: {len(saved_now)}.")
    if n < len(phrases):
        print("Продолжить: той же командой, запись пойдёт с первой незаписанной фразы.")
    if Path(a.out).resolve() == (ROOT / "data" / "silent").resolve():
        print("Дальше: ./run.sh dataset.py (лицо + признаки), потом train.py или nightly.sh")
    elif a.whisper:
        print("Дальше: ./run.sh whisper_eval.py all")
    else:
        print("Дальше: uv run evaluate.py")


if __name__ == "__main__":
    main()
