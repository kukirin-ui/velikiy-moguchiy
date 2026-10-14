import sys, glob, subprocess
sys.path.insert(0, "multivsr"); a = sys.argv; sys.argv = a[:1]
from tokenizer import get_tokenizer
tok = get_tokenizer()
import re
nw = nt = 0; secs = 0.0; mx = 0
for t in sorted(glob.glob("clips/*.txt")):
    s = open(t, encoding="utf-8").read().strip()
    n = len(tok.encode(s.lower())); nt += n; nw += len(s.split()); mx = max(mx, n)
    d = float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",t[:-4]+".mp4"],capture_output=True,text=True).stdout)
    secs += d
print(f"50 clips: {secs:.1f} s video (avg {secs/50:.2f} s), words {nw}, tokens {nt}: {nt/nw:.2f} tok/word, {nt/secs:.2f} tok/s, max {mx}")
full = tok.encode("<|startoftranscript|><|ru|><|transcribe|><|notimestamps|>привет как дела<|endoftext|>")
print("target format ids:", full)
