"""Шаг 1b: потоково читает multivsr.tar (42 ГБ) с Hugging Face и сохраняет только русские ролики.
Для каждого русского ролика: data/public_meta/tracks/<vid>.npz (bbox лиц по кадрам, int16) +
data/public_meta/txt/<vid>/<track>.txt (расшифровка с таймингами слов). Остальное отбрасывается.
Tar целиком на диск не пишется. Переподключается по Range при обрывах. pickle читается ограниченным
unpickler'ом (только numpy). Возобновление: уже готовые ролики пропускаются (но поток читается заново)."""
import io, json, os, pickle, sys, tarfile, time, urllib.request
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
META = ROOT / "data/public_meta"
URL = "https://huggingface.co/datasets/sindhuhegde/multivsr/resolve/main/multivsr.tar"
SIZE = 42083102720


class SafeUnpickler(pickle.Unpickler):
    ALLOWED = {("numpy", "ndarray"), ("numpy", "dtype"), ("numpy.core.multiarray", "_reconstruct"),
               ("numpy.core.multiarray", "scalar"), ("numpy._core.multiarray", "_reconstruct"),
               ("numpy._core.multiarray", "scalar")}

    def find_class(self, module, name):
        if (module, name) in self.ALLOWED:
            return super().find_class(module, name)
        raise pickle.UnpicklingError(f"forbidden {module}.{name}")


class RangeStream(io.RawIOBase):
    def __init__(self, url, pos=0):
        self.url, self.pos, self.r = url, pos, None
        self.t0 = time.time()

    def readable(self):
        return True

    def _open(self):
        for attempt in range(1000):
            try:
                req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-", "User-Agent": "lipread-ru-research"})
                self.r = urllib.request.urlopen(req, timeout=60)
                return
            except Exception as e:
                print("reconnect failed", e, file=sys.stderr, flush=True); time.sleep(min(60, 2 + attempt * 3))
        raise RuntimeError("cannot reconnect")

    def readinto(self, b):
        while True:
            if self.r is None:
                self._open()
            try:
                n = self.r.readinto(b)
                if n == 0 and self.pos < SIZE:
                    raise IOError("early EOF")
                self.pos += n
                return n
            except Exception as e:
                print(f"stream error at {self.pos}: {e}; reconnecting", file=sys.stderr, flush=True)
                try: self.r.close()
                except Exception: pass
                self.r = None
                time.sleep(3)


def main():
    ru = {}
    for l in open(META / "ru_csv.jsonl"):
        ru[json.loads(l)["video_id"]] = 1
    (META / "tracks").mkdir(parents=True, exist_ok=True)
    (META / "txt").mkdir(parents=True, exist_ok=True)
    rs = RangeStream(URL)
    br = io.BufferedReader(rs, buffer_size=1 << 20)
    tf = tarfile.open(fileobj=br, mode="r|")
    cur, bbox, nvid, ntr, t0, last = None, {}, 0, 0, time.time(), 0

    def flush():
        nonlocal bbox, nvid
        if cur and bbox:
            np.savez_compressed(META / "tracks" / f"{cur}.tmp.npz", **bbox)
            os.replace(META / "tracks" / f"{cur}.tmp.npz", META / "tracks" / f"{cur}.npz")
            nvid += 1
        bbox = {}

    for m in tf:
        if not m.isfile():
            continue
        parts = m.name.split("/")
        if len(parts) != 3 or parts[1] not in ru:
            continue
        vid, fn = parts[1], parts[2]
        if vid != cur:
            flush(); cur = vid
        if (META / "tracks" / f"{vid}.npz").exists():
            continue
        data = tf.extractfile(m).read()
        trk, ext = fn.rsplit(".", 1)
        if ext == "pckl":
            d = SafeUnpickler(io.BytesIO(data)).load()
            fr = np.asarray(d["frame"]); bb = np.asarray(d["bbox"], dtype=np.float32)
            bbox[f"{trk}_frame0"] = np.int64(fr[0]); bbox[f"{trk}_n"] = np.int64(len(fr))
            bbox[f"{trk}_contig"] = np.bool_(len(fr) == fr[-1] - fr[0] + 1)
            bbox[f"{trk}_bbox"] = np.rint(bb).astype(np.int16)
            ntr += 1
        elif ext == "txt":
            p = META / "txt" / vid; p.mkdir(exist_ok=True)
            (p / fn).write_bytes(data)
        if time.time() - last > 30:
            last = time.time()
            print(f"{time.strftime('%H:%M:%S')} {rs.pos/1e9:.2f}/{SIZE/1e9:.1f} GB  ru videos {nvid} tracks {ntr}  "
                  f"{rs.pos/(last-t0)/1e6:.1f} MB/s", flush=True)
    flush()
    (META / "tar_done").write_text(f"videos={nvid} tracks={ntr}\n")
    print("DONE", nvid, ntr, flush=True)


if __name__ == "__main__":
    main()
