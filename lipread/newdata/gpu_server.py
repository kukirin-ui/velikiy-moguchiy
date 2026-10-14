"""GPU-сервис сборщика RuTube/VK: SyncNet (синхронность губ и звука) + GigaAM v3 RNNT (метки), один процесс на GPU.

Воркеры (много CPU-процессов) присылают запросы по локальному сокету; крупные массивы идут через /dev/shm (путь к .npy).
Память GPU: SyncNet ~0.4 ГБ + GigaAM ~0.8 ГБ, батчи маленькие: на карте делят место с обучением и feature-воркерами.

Запросы (pickle через multiprocessing.connection):
  ("sync", frames_npy_path, mfcc_npy_path, vshift)  -> dict(offset, conf, minval, medval, n)
  ("asr",  wav_npy_path)                              -> str
  ("ping",)                                           -> "pong"
"""
from __future__ import annotations

import os
import sys
import threading
import time
from multiprocessing.connection import Listener
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
BASE_PORT = 47231
ADDR = ("127.0.0.1", int(os.environ.get("RV_GPU_PORT", BASE_PORT)))
# one server serialises every worker of the pod and leaves the GPU mostly idle, so workers spread over N of them
N_SERVERS = int(os.environ.get("RV_GPU_N", "1"))
AUTH = b"rv-gpu-local"
SYNCNET_W = HERE / "weights" / "syncnet_v2.model"


class SyncNet:
    """SyncNet (Chung & Zisserman) поверх SyncNetModel.S из multivsr/preprocess. Вход: кроп лица 224x224 BGR, 25 к/с,
    MFCC(13, 100 Гц) звука 16 кГц. Как SyncNetInstance.evaluate: 5-кадровые окна, расстояние до окон звука со сдвигом +-vshift."""

    def __init__(self, device="cuda"):
        import torch
        for p in (HERE, HERE.parent / "multivsr" / "preprocess"):
            if str(p) not in sys.path:
                sys.path.append(str(p))
        from SyncNetModel import S
        self.torch = torch
        self.dev = device
        self.m = S(num_layers_in_fc_layers=1024).to(device)
        st = torch.load(str(SYNCNET_W), map_location="cpu")
        own = self.m.state_dict()
        for k, v in st.items():
            own[k].copy_(v)
        self.m.eval()

    def run(self, frames: np.ndarray, mfcc: np.ndarray, vshift=15, batch=32):
        """frames (N,224,224,3) uint8 BGR; mfcc (13,T) float32. -> dict."""
        torch = self.torch
        n_aud = mfcc.shape[1] // 4  # 4 MFCC-кадра на видеокадр
        n = min(len(frames), n_aud)
        last = n - 5
        if last < 10:
            return {"offset": 0, "conf": 0.0, "minval": 0.0, "medval": 0.0, "n": max(last, 0)}
        im_f, cc_f = [], []
        with torch.inference_mode():
            for i in range(0, last, batch):
                idx = range(i, min(last, i + batch))
                im = np.stack([frames[v:v + 5] for v in idx])  # B,5,224,224,3
                im = torch.from_numpy(im).to(self.dev).permute(0, 4, 1, 2, 3).float()  # B,3,5,H,W
                im_f.append(self.m.forward_lip(im).float().cpu())
                cc = np.stack([mfcc[:, v * 4:v * 4 + 20] for v in idx])  # B,13,20
                cc = torch.from_numpy(cc).to(self.dev).float().unsqueeze(1)
                cc_f.append(self.m.forward_aud(cc).float().cpu())
        im_f = torch.cat(im_f)
        cc_f = torch.cat(cc_f)
        ccp = torch.nn.functional.pad(cc_f, (0, 0, vshift, vshift))
        m = len(im_f)
        dists = []
        for s in range(2 * vshift + 1):
            dists.append(torch.nn.functional.pairwise_distance(im_f, ccp[s:s + m]).mean())
        md = torch.stack(dists)
        minval, minidx = torch.min(md, 0)
        return {"offset": int(vshift - minidx.item()), "conf": float(torch.median(md) - minval), "minval": float(minval),
                "medval": float(torch.median(md)), "n": int(m)}


class ASR:
    def __init__(self, device="cuda"):
        import gigaam
        import torch
        self.torch = torch
        self.m = gigaam.load_model("v3_rnnt", fp16_encoder=True, device=device)
        self.dev = self.m._device

    def run(self, audio: np.ndarray) -> str:
        torch = self.torch
        if len(audio) < 1600:
            return ""
        with torch.inference_mode():
            wav = torch.from_numpy(np.ascontiguousarray(audio, np.float32)).to(self.dev).to(self.m._dtype).unsqueeze(0)
            length = torch.full([1], wav.shape[-1], device=self.dev)
            enc, enc_len = self.m.forward(wav, length)
            text, _ = self.m._decode(enc, enc_len, length, False)[0]
        return text


def serve():
    import torch
    torch.backends.cudnn.benchmark = False
    sn = SyncNet()
    asr = ASR()
    sync_lock = threading.Lock()
    asr_lock = threading.Lock()
    lst = Listener(ADDR, authkey=AUTH, backlog=128)
    print(f"{time.strftime('%F %T')} gpu_server готов {ADDR}, GPU mem {torch.cuda.memory_allocated()/1e6:.0f} МБ", flush=True)

    def handle(conn):
        try:
            while True:
                try:
                    req = conn.recv()
                except EOFError:
                    return
                try:
                    kind = req[0]
                    if kind == "ping":
                        conn.send("pong")
                    elif kind == "sync":
                        frames = np.load(req[1], mmap_mode="r")
                        mfcc = np.load(req[2])
                        with sync_lock:
                            r = sn.run(np.asarray(frames), mfcc, req[3] if len(req) > 3 else 15)
                        conn.send(r)
                    elif kind == "asr":
                        a = np.load(req[1])
                        with asr_lock:
                            r = asr.run(a)
                        conn.send(r)
                    else:
                        conn.send({"error": f"unknown {kind}"})
                except Exception as e:  # noqa
                    import traceback
                    traceback.print_exc()
                    conn.send({"error": f"{type(e).__name__}: {e}"})
        finally:
            conn.close()

    while True:
        c = lst.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


class Client:
    """Клиент в воркере: одно соединение на процесс."""

    def __init__(self, port=None):
        from multiprocessing.connection import Client as C
        if port is None:
            port = BASE_PORT + os.getpid() % N_SERVERS
        self.c = C(("127.0.0.1", port), authkey=AUTH)
        self.shm = Path("/dev/shm/rv")
        self.shm.mkdir(exist_ok=True)
        self.tag = f"{os.getpid()}"

    def _call(self, *req):
        self.c.send(req)
        r = self.c.recv()
        if isinstance(r, dict) and "error" in r and len(r) == 1:
            raise RuntimeError(r["error"])
        return r

    def sync(self, frames: np.ndarray, mfcc: np.ndarray, vshift=15):
        fp, mp = self.shm / f"f_{self.tag}.npy", self.shm / f"m_{self.tag}.npy"
        np.save(fp, frames)
        np.save(mp, mfcc.astype(np.float32))
        try:
            return self._call("sync", str(fp), str(mp), vshift)
        finally:
            fp.unlink(missing_ok=True)
            mp.unlink(missing_ok=True)

    def asr(self, audio: np.ndarray) -> str:
        ap = self.shm / f"a_{self.tag}.npy"
        np.save(ap, audio.astype(np.float32))
        try:
            return self._call("asr", str(ap))
        finally:
            ap.unlink(missing_ok=True)


def mfcc_of(audio_f32: np.ndarray) -> np.ndarray:
    """MFCC(13, T) как в SyncNetInstance: python_speech_features.mfcc от int16 16 кГц."""
    import python_speech_features
    a = np.clip(audio_f32 * 32768.0, -32768, 32767).astype(np.int16)
    return python_speech_features.mfcc(a, 16000).T.astype(np.float32)


if __name__ == "__main__":
    serve()
