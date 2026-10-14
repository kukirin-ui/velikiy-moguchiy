#!/usr/bin/env python3
"""Protocol smoke test of the DashScope Qwen-Omni realtime dictation flow.
usage: DASHSCOPE_KEY=... [DASHSCOPE_HOST=dashscope.aliyuncs.com] dashscope_smoke.py file16k.wav ru|en
(needs `websockets`; the default host is the international one)"""
import asyncio, json, os, base64, wave, sys, websockets
KEY=os.environ["DASHSCOPE_KEY"]  # never commit a real key
LANG=sys.argv[2]; WAV=sys.argv[1]
INS={"ru":"Ты — модуль диктовки. Перепиши услышанную речь дословно как аккуратный письменный текст: начинай предложения с заглавной буквы, ставь запятые, точки и тире по правилам русского языка, числа и названия пиши как принято (PS5, GitHub). Не отвечай на содержание и ничего не добавляй. Пример: «привет как дела у меня всё хорошо» → «Привет, как дела? У меня всё хорошо.»",
"en":"You are a dictation module. Rewrite the speech you hear verbatim as clean written text: capitalize sentences, add commas, periods and dashes per English rules, write numbers and names as usual (PS5, GitHub). Do not answer the content and add nothing. Example: \"hi how are you i am fine\" -> \"Hi, how are you? I am fine.\""}
async def main():
    host=os.environ.get("DASHSCOPE_HOST","dashscope-intl.aliyuncs.com")
    url=f"wss://{host}/api-ws/v1/realtime?model=qwen3.8-omni-flash-realtime"
    async with websockets.connect(url, additional_headers={"Authorization":"Bearer "+KEY}) as ws:
        async def ev():
            return json.loads(await asyncio.wait_for(ws.recv(), 30))
        e=await ev(); print("<-",e["type"]); assert e["type"]=="session.created"
        await ws.send(json.dumps({"type":"session.update","session":{"modalities":["text"],"voice":"Serena","input_audio_format":"pcm","sample_rate":16000,"turn_detection":None,"input_audio_transcription":{"language":LANG},"instructions":INS[LANG]}}))
        e=await ev(); print("<-",e["type"]); assert e["type"]=="session.updated", e
        w=wave.open(WAV); pcm=w.readframes(w.getnframes()); assert w.getframerate()==16000
        step=3200
        for i in range(0,len(pcm),step):
            await ws.send(json.dumps({"type":"input_audio_buffer.append","audio":base64.b64encode(pcm[i:i+step]).decode()}))
            await asyncio.sleep(0.02)
        await ws.send(json.dumps({"type":"input_audio_buffer.commit"}))
        await ws.send(json.dumps({"type":"response.create"}))
        final=""; 
        while True:
            e=await ev(); t=e["type"]
            if t=="conversation.item.input_audio_transcription.delta": print("preview:",e.get("text"),"|",e.get("stash"))
            elif t=="response.text.delta": final+=e["delta"]; print("delta:",repr(e["delta"]))
            elif t=="response.text.done": print("text.done:",repr(e.get("text")))
            elif t=="error": print("ERR",e); break
            else: print("<-",t)
            if t=="response.done": break
        print("FINAL:",final)
asyncio.run(main())
