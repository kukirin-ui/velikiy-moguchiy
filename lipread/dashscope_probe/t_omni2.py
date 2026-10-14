import sys; sys.path.insert(0,'.')
from common import *
cid='-Ulmfbh23Ew__00000_000791'
p="Это беззвучное видео: человек говорит по-русски, звука нет. Прочитай по губам и напиши, что он говорит, одной фразой по-русски, без пояснений."
c=[{"type":"video_url","video_url":{"url":data_uri(PUB/f"{cid}.mp4")}},{"type":"text","text":p}]
for model,kw in [('qwen3.8-omni-flash',{'enable_thinking':False}),('qwen3.5-omni-flash',{}),('qwen3-omni-flash',{'enable_thinking':False}),('qwen3-vl-plus',{'enable_thinking':True})]:
    t=time.time()
    r=chat(model,c,**kw)
    print(model,kw,round(time.time()-t,1),json.dumps(r,ensure_ascii=False)[:500],flush=True)
