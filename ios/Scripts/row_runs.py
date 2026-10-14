#!/usr/bin/env python3
"""White key runs (pt) of each row at y = row top + 8pt/3. usage: row_runs.py shot.png"""
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('RGB')
for i,top in enumerate((591,645,699,753)):
    y=int((top+8)*3); out=[];prev=False
    for x in range(1206):
        w=min(im.getpixel((x,y)))>=250
        if w and not prev: s=x
        if not w and prev: out.append((round(s/3,1),round(x/3,1),round((x-s)/3,1)))
        prev=w
    print(i,out)
