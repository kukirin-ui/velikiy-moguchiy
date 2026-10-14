"""Build video-SFT zips for Model Studio: 10 fps retimed 224px clips (every 25 fps frame kept) + data.jsonl."""
import json, subprocess, shutil, zipfile, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from common import *

PROMPT = "Прочитай по губам, что говорит человек на беззвучном видео. Ответ: только фраза по-русски."
W = ROOT / "work" / "dashscope_ft"


def retime(cid, dst):
    if not dst.exists():
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(PUB / f"{cid}.mp4"), "-an", "-vf", "setpts=2.5*PTS", "-r", "10",
                        "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", str(dst)], check=True)


def build(name, rows):
    d = W / name
    d.mkdir(parents=True, exist_ok=True)
    lines = []
    for r in rows:
        fn = r["id"].replace("-", "m", 1) if r["id"].startswith("-") else r["id"]
        retime(r["id"], d / f"{fn}.mp4")
        lines.append(json.dumps({"messages": [
            {"role": "user", "content": [{"video": f"{fn}.mp4", "fps": 10.0}, {"text": PROMPT}]},
            {"role": "assistant", "content": [{"text": r["ref"]}]}]}, ensure_ascii=False))
    (d / "data.jsonl").write_text("\n".join(lines) + "\n")
    z = W / f"{name}.zip"
    with zipfile.ZipFile(z, "w", zipfile.ZIP_STORED) as zf:
        zf.write(d / "data.jsonl", "data.jsonl")
        for r in rows:
            fn = r["id"].replace("-", "m", 1) if r["id"].startswith("-") else r["id"]
            zf.write(d / f"{fn}.mp4", f"{fn}.mp4")
    print(name, len(rows), round(z.stat().st_size / 1e6, 1), "MB")


if __name__ == "__main__":
    pool = json.load(open(OUT / "ft_train_pool.json"))
    build("pilot20", pool[:20])
    build("train187", pool[:187])
    test = json.load(open(OUT / "clips_pool100.json"))[:50]
    (W / "test").mkdir(parents=True, exist_ok=True)
    for r in test:
        retime(r["id"], W / "test" / f"{r['id']}.mp4")
