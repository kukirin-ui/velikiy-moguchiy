"""Cut the audio of each test clip from its YouTube source (anonymous yt-dlp, 16 kHz mono wav)."""
import subprocess, sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
from common import *

D = ROOT / "work" / "dashscope_asr"
clips = json.load(open(OUT / "clips_pool100.json"))[:50]
for c in clips:
    out = D / f"{c['id']}.wav"
    if out.exists():
        continue
    d = json.load(open(PUB / f"{c['id']}.json"))
    s, e = d["start"], d["end"]
    pad = 1.0
    s0 = max(0, s - pad)
    raw = D / f"raw_{c['id']}.wav"
    r = subprocess.run(["yt-dlp", "--no-warnings", "-f", "ba", "--download-sections", f"*{s0:.2f}-{e + pad:.2f}", "--force-keyframes-at-cuts",
                        "-x", "--audio-format", "wav", "-o", str(D / f"raw_{c['id']}.%(ext)s"),
                        f"https://www.youtube.com/watch?v={d['video_id'].removeprefix('yt_')}"], capture_output=True, text=True)
    if not raw.exists():
        print("FAIL", c["id"], r.stderr[-200:]); continue
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-ss", f"{s - s0:.2f}", "-t", f"{e - s:.2f}", "-ac", "1", "-ar", "16000", str(out)], check=True)
    raw.unlink()
    time.sleep(1.5)
print(len(list(D.glob("*.wav"))))
