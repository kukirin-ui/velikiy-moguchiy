#!/usr/bin/env python3
"""Measure key edges (points) on a simulator screenshot of a light-mode keyboard.
usage: measure_keys.py shot.png   (assumes 1206x2622 @3x)"""
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
S = 3
def is_white(c): return min(c) >= 250
def is_bg(c): return not is_white(c) and min(c) >= 215 and max(c) - min(c) < 14
rows=[]
def runs_at(x):
    out=[];prev=False
    for y in range(1450,2622):
        w=is_white(im.getpixel((x,y)))
        if w and not prev: top=y
        if not w and prev: out.append((top,y))
        prev=w
    return out
# merge runs from several columns: glyphs split runs, so take the union
cols=[int(c*S) for c in (8.5,9.5,10.5,11.5)]
spans=[]
for x in cols: spans+=runs_at(x)
spans.sort()
merged=[]
for a,b in spans:
    if merged and a<=merged[-1][1]+1: merged[-1]=(merged[-1][0],max(b,merged[-1][1]))
    else: merged.append((a,b))
rows=[(a/S,b/S) for a,b in merged if (b-a)/S>20]
print('rows(top,bottom):',[(round(a,2),round(b,2)) for a,b in rows])
for (t,b) in rows:
    y=int((t+6)*S)
    xs=[];prev=False
    for xx in range(1206):
        w=is_white(im.getpixel((xx,y)))
        if w and not prev: start=xx
        if not w and prev: xs.append((round(start/S,1),round(xx/S,1)))
        prev=w
    print(round(t,1),xs)
