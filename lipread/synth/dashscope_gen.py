"""Talking faces from DashScope (Alibaba Model Studio, Beijing) for comparison with MuseTalk: wan2.2-s2v (portrait +
speech -> video of the whole portrait) and videoretalk (re-lips an existing video to new speech).

Inputs are a pilot clip's speech (data/synth/pilot_wav/NAME.wav) and the same SFHQ face MuseTalk used, so the three
generators can be compared clip by clip. videoretalk needs a video, so the still face becomes a static video.
Local files go to DashScope's temporary storage (oss://, kept 48 h). Keys: config.yaml of the app (~/.velikiy-moguchiy, or ~/.koe before the rename) asr.qwen.api_keys,
never printed. Every task is logged to results/synth/dashscope/tasks.jsonl with submit/run/end times.

  python synth/dashscope_gen.py --model wan2.2-s2v --clip synth_ruls_xxx --key 0 --resolution 480P
  python synth/dashscope_gen.py --model videoretalk --clip synth_ruls_xxx --clip synth_golos_yyy --key 1
  python synth/dashscope_gen.py --model wan2.2-s2v --clip A --clip B --clip C --spread-keys   # one key per clip
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
API = "https://dashscope.aliyuncs.com/api/v1"
OUT = ROOT / "data" / "synth" / "dashscope"
LOG = ROOT / "results" / "synth" / "dashscope" / "tasks.jsonl"
_log_lock = threading.Lock()


def keys() -> list[str]:
    import yaml
    app_dir = Path.home() / ".velikiy-moguchiy"
    if not app_dir.exists() and (Path.home() / ".koe").is_dir():
        app_dir = Path.home() / ".koe"  # the app's data directory from before the rename
    c = yaml.safe_load(open(app_dir / "config.yaml"))
    return list(c["asr"]["qwen"]["api_keys"])


def upload(key: str, model: str, path: Path) -> str:
    """DashScope temporary storage: a policy for this model, then a form POST to its OSS bucket -> oss:// URL."""
    p = requests.get(f"{API}/uploads", params={"action": "getPolicy", "model": model},
                     headers={"Authorization": f"Bearer {key}"}, timeout=30)
    p.raise_for_status()
    d = p.json()["data"]
    obj = f"{d['upload_dir']}/{path.name}"
    with open(path, "rb") as f:
        r = requests.post(d["upload_host"], data={
            "OSSAccessKeyId": d["oss_access_key_id"], "Signature": d["signature"], "policy": d["policy"],
            "x-oss-object-acl": d["x_oss_object_acl"], "x-oss-forbid-overwrite": d["x_oss_forbid_overwrite"],
            "key": obj, "success_action_status": "200"}, files={"file": (path.name, f)}, timeout=300)
    r.raise_for_status()
    return f"oss://{obj}"


def submit(key: str, model: str, inp: dict, params: dict) -> str:
    r = requests.post(f"{API}/services/aigc/image2video/video-synthesis", timeout=60,
                      headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                               "X-DashScope-Async": "enable", "X-DashScope-OssResourceResolve": "enable"},
                      json={"model": model, "input": inp, "parameters": params})
    if r.status_code != 200:
        raise RuntimeError(f"submit {model}: HTTP {r.status_code} {r.text[:300]}")
    return r.json()["output"]["task_id"]


def poll(key: str, task_id: str, every=10, limit_s=3600) -> dict:
    t0 = time.time()
    while True:
        r = requests.get(f"{API}/tasks/{task_id}", headers={"Authorization": f"Bearer {key}"}, timeout=30)
        r.raise_for_status()
        j = r.json()
        st = j["output"]["task_status"]
        if st in ("SUCCEEDED", "FAILED", "CANCELED", "UNKNOWN") or time.time() - t0 > limit_s:
            return j
        time.sleep(every)


def still_video(img: Path, sec: float, dst: Path, side=768):
    """Static video of a face still (videoretalk wants a 640-2048 px video, 2-120 s)."""
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", str(img), "-t", f"{sec + 0.5:.2f}",
                    "-vf", f"scale={side}:{side},format=yuv420p", "-r", "25", "-c:v", "libx264", "-crf", "16",
                    str(dst)], check=True)


def run_one(model: str, clip: str, key_i: int, key: str, resolution: str, faces_dir: Path, wav_dir: Path,
            pilot_dir: Path):
    meta = json.loads((pilot_dir / f"{clip}.json").read_text())
    face = next(faces_dir.rglob(meta["face_file"]))
    wav = wav_dir / f"{clip}.wav"
    tag = f"{clip}__{model}{'_' + resolution if model.startswith('wan') else ''}"
    OUT.mkdir(parents=True, exist_ok=True)
    rec = dict(model=model, clip=clip, key=key_i, resolution=resolution if model.startswith("wan") else None,
               audio_s=meta["end"], face=meta["face_file"])
    t_up = time.time()
    if model.startswith("wan"):
        inp = {"image_url": upload(key, model, face), "audio_url": upload(key, model, wav)}
        params = {"resolution": resolution}
    else:
        vid = OUT / f"{clip}__still.mp4"
        still_video(face, meta["end"], vid)
        inp = {"video_url": upload(key, model, vid), "audio_url": upload(key, model, wav)}
        params = {"video_extension": False}
    rec["upload_s"] = round(time.time() - t_up, 1)
    t_sub = time.time()
    rec["submitted"] = time.strftime("%F %T")
    try:
        tid = submit(key, model, inp, params)
    except RuntimeError as e:
        rec["error"] = str(e)
        _write(rec)
        print(f"{tag}: {e}", flush=True)
        return rec
    rec["task_id"] = tid
    print(f"{tag}: submitted on key {key_i}", flush=True)
    j = poll(key, tid)
    out = j["output"]
    rec.update(status=out["task_status"], wall_s=round(time.time() - t_sub, 1),
               submit_time=out.get("submit_time"), scheduled_time=out.get("scheduled_time"),
               end_time=out.get("end_time"), usage=j.get("usage"), code=out.get("code"), message=out.get("message"))
    url = out.get("video_url") or (out.get("results") or {}).get("video_url")
    if out["task_status"] == "SUCCEEDED" and url:
        dst = OUT / f"{tag}.mp4"
        with requests.get(url, stream=True, timeout=300) as r:
            r.raise_for_status()
            with open(dst, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
        rec["file"] = str(dst.relative_to(ROOT))
    _write(rec)
    print(f"{tag}: {rec['status']} in {rec['wall_s']} s (scheduled {rec['scheduled_time']}, end {rec['end_time']})",
          flush=True)
    return rec


def _write(rec):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with _log_lock, open(LOG, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=["wan2.2-s2v", "videoretalk"])
    ap.add_argument("--clip", action="append", required=True)
    ap.add_argument("--key", type=int, default=0)
    ap.add_argument("--spread-keys", action="store_true", help="clip i on key i %% 3, all at once")
    ap.add_argument("--resolution", default="480P", choices=["480P", "720P"])
    ap.add_argument("--faces", default=str(ROOT / "data" / "synth" / "src" / "faces"))
    ap.add_argument("--wav", default=str(ROOT / "data" / "synth" / "pilot_wav"))
    ap.add_argument("--pilot", default=str(ROOT / "data" / "synth" / "pilot"))
    a = ap.parse_args()
    ks = keys()
    jobs = [(c, (i % len(ks)) if a.spread_keys else a.key) for i, c in enumerate(a.clip)]
    th = [threading.Thread(target=run_one, args=(a.model, c, ki, ks[ki], a.resolution, Path(a.faces), Path(a.wav),
                                                  Path(a.pilot))) for c, ki in jobs]
    for t in th:
        t.start()
        time.sleep(1)
    for t in th:
        t.join()


if __name__ == "__main__":
    main()
