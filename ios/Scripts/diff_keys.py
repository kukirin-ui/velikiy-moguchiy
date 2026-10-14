#!/usr/bin/env python3
"""Side-by-side + difference image of the keyboard area of two simulator screenshots.
usage: diff_keys.py apple.png ours.png out.png"""
import sys
from PIL import Image, ImageChops
a=Image.open(sys.argv[1]).convert('RGB'); b=Image.open(sys.argv[2]).convert('RGB')
box=(0,1560,1206,2420)
ca,cb=a.crop(box),b.crop(box)
d=ImageChops.difference(ca,cb).convert('L').point(lambda v:255 if v>24 else 0)
w=Image.new('RGB',(1206*3//2,(box[3]-box[1])//2))
half=lambda im: im.resize((603,(box[3]-box[1])//2))
w.paste(half(ca),(0,0)); w.paste(half(cb),(603,0)); w.paste(half(d.convert('RGB')),(1206,0))
w.save(sys.argv[3])
import statistics
print('diff pixels %:',round(100*sum(1 for p in d.getdata() if p)/ (d.size[0]*d.size[1]),2))
