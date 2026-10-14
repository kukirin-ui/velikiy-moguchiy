import sys; sys.path.insert(0,'.')
from common import *
cid=json.load(open(OUT/'clips_pool100.json'))[0]['id']
p="Прочитай по губам, что говорит человек на беззвучном видео. Ответ: только фраза по-русски."
for name,src,fps in [('orig',PUB,None),('orig fps10',PUB,10),('slow fps10',ROOT/'work'/'dashscope_slow',10)]:
    v={"type":"video_url","video_url":{"url":data_uri(src/f"{cid}.mp4")}}
    if fps: v["fps"]=fps
    r=chat('qwen3-vl-plus',[v,{"type":"text","text":p}])
    print(name,r.get('usage',{}).get('prompt_tokens_details'),r.get('error'),r['choices'][0]['message']['content'][:80] if 'choices' in r else r)
