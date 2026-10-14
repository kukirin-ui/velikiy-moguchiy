import sys, time; sys.path.insert(0, '.')
from ft_api import *
jid = sys.argv[1]
while True:
    j = job(jid)['output']
    if j['status'] in ('SUCCEEDED', 'FAILED', 'CANCELED'):
        print(json.dumps({k: j.get(k) for k in ('status', 'finetuned_output', 'usage', 'message', 'end_time', 'create_time')}, ensure_ascii=False)); break
    time.sleep(30)
