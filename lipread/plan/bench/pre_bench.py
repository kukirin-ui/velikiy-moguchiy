"""Cost of the S3FD+crop preprocessing per second of video on CPU (1 thread vs all), per-stage timing."""
import sys, time, os, glob, subprocess, tempfile, cv2, torch
sys.path.insert(0, "."); 
import preprocess as P
src = "clips/005.mp4"
tmp = tempfile.mkdtemp()
t0 = time.perf_counter(); subprocess.run(["ffmpeg","-y","-v","error","-i",src,"-qscale:v","2","-async","1","-r","25",tmp+"/v.avi"],check=True)
os.makedirs(tmp+"/f"); subprocess.run(["ffmpeg","-y","-v","error","-i",tmp+"/v.avi","-qscale:v","2","-threads","1","-f","image2",tmp+"/f/%06d.jpg"],check=True)
t_ff = time.perf_counter()-t0
fl = sorted(glob.glob(tmp+"/f/*.jpg")); n = len(fl); print("frames", n, "size", cv2.imread(fl[0]).shape)
det = P._detector("cpu")
for thr in (1, torch.get_num_threads()):
    torch.set_num_threads(thr)
    t0 = time.perf_counter()
    for f in fl[:40]:
        im = cv2.cvtColor(cv2.imread(f), cv2.COLOR_BGR2RGB); det.detect_faces(im, conf_th=0.9, scales=[0.25])
    d = (time.perf_counter()-t0)/40
    print(f"S3FD threads={thr}: {d*1000:.0f} ms/frame -> {1/(25*d):.2f}x realtime")
print(f"ffmpeg(avi+jpg) {t_ff:.2f}s for {n/25:.1f}s video = {n/25/t_ff:.1f}x rt")
