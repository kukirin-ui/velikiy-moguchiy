import sys; sys.path.insert(0,'.')
from common import *
cid='-Ulmfbh23Ew__00000_000791'
p="Это беззвучное видео: человек говорит по-русски, звука нет. Прочитай по губам и напиши, что он говорит, одной фразой по-русски, без пояснений."
c=[{"type":"video_url","video_url":{"url":data_uri(PUB/f"{cid}.mp4")}},{"type":"text","text":p}]
t=time.time()
r=chat('qwen3.8-omni-flash',c)
print(time.time()-t,json.dumps(r,ensure_ascii=False)[:800])
