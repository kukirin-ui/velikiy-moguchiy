"""Shared helpers for the DashScope capability probes: key loading, clip selection, API calls."""
import base64, json, os, random, time, glob
from pathlib import Path
import requests, yaml

ROOT = Path(__file__).resolve().parent.parent
PUB = ROOT / "data" / "public_pod"
BASE = "https://dashscope.aliyuncs.com"
OUT = ROOT / "results" / "dashscope"
OUT.mkdir(parents=True, exist_ok=True)

# The app's config: ~/.velikiy-moguchiy, or ~/.koe from before the rename while only that one exists.
_app_dir = Path.home() / ".velikiy-moguchiy"
if not _app_dir.exists() and (Path.home() / ".koe").is_dir():
    _app_dir = Path.home() / ".koe"
_cfg = yaml.safe_load(open(_app_dir / "config.yaml"))
KEYS = _cfg["asr"]["qwen"]["api_keys"]


def hdr(i=0):
    return {"Authorization": f"Bearer {KEYS[i % len(KEYS)]}"}


def read_clip(cid):
    d = json.load(open(PUB / f"{cid}.json"))
    return d, (PUB / f"{cid}.txt").read_text().strip()


def data_uri(path, mime="video/mp4"):
    return f"data:{mime};base64," + base64.b64encode(Path(path).read_bytes()).decode()


def _sse(r):
    text, usage = "", None
    for line in r.iter_lines():
        if not line.startswith(b"data:") or line.endswith(b"[DONE]"):
            continue
        j = json.loads(line[5:])
        if j.get("usage"):
            usage = j["usage"]
        for c in j.get("choices", []):
            text += (c.get("delta") or {}).get("content") or ""
    return {"choices": [{"message": {"content": text}}], "usage": usage}


def chat(model, content, key_i=0, retries=3, stream=None, **kw):
    """Omni models only answer in streaming mode; the result is normalised to a non-stream shape."""
    stream = "omni" in model if stream is None else stream
    body = {"model": model, "messages": [{"role": "user", "content": content}], **kw}
    if stream:
        body.update(stream=True, stream_options={"include_usage": True}, modalities=["text"])
    for k in range(retries):
        r = requests.post(f"{BASE}/compatible-mode/v1/chat/completions", headers=hdr(key_i + k), json=body,
                          timeout=180, stream=stream)
        if r.status_code == 200:
            return _sse(r) if stream else r.json()
        if r.status_code in (429, 500, 502, 503):
            time.sleep(2 + 3 * k)
            continue
        return {"error": r.status_code, "body": r.text[:500]}
    return {"error": r.status_code, "body": r.text[:500]}
