#!/usr/bin/env python3
"""Dark-glyph bounding boxes (pt) inside given key cells of a screenshot (3x).
usage: glyph_bbox.py shot.png row col [row col ...]  with RU geometry (11 keys, tops 591/645/699/753)"""
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('L')
tops=[591,645,699,753]
def cell(row,col,n=11):
    W=(402-14-(n-1)*20/3)/n
    x=7+col*(W+20/3)
    return x,tops[row],W,43
def bbox(x,y,w,h,th=110):
    xs=[];ys=[]
    for yy in range(int((y+2)*3),int((y+h-2)*3)):
        for xx in range(int((x+2)*3),int((x+w-2)*3)):
            if im.getpixel((xx,yy))<th: xs.append(xx);ys.append(yy)
    if not xs: return None
    return tuple(round(v/3,1) for v in (min(xs)-x*3, min(ys)-y*3, max(xs)-x*3, max(ys)-y*3))+(round((max(xs)-min(xs))/3,1),round((max(ys)-min(ys))/3,1))
args=sys.argv[2:]
for i in range(0,len(args),2):
    r,c=int(args[i]),int(args[i+1])
    print(r,c,bbox(*cell(r,c)))
