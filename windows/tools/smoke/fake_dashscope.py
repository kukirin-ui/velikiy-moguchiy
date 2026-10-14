"""A stand-in for the DashScope realtime ASR WebSocket, for the Windows smoke
test. It speaks just enough of the protocol the app's Qwen provider uses
(non-Omni model, manual turns) and answers every session with one fixed
phrase, whatever audio it got. Listens on 127.0.0.1 only.

Writes a summary of each finished session to --summary as JSON, so the test
can check that the app sent the key it was configured with and real audio.
"""

import argparse
import asyncio
import base64
import json
import sys
from pathlib import Path

from websockets.asyncio.server import serve

PHRASE = "Проверка диктовки на Windows прошла успешно."


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--key", required=True, help="the API key the app must send")
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()

    sessions = []

    def log(message: str) -> None:
        print(message, flush=True)

    async def handler(ws) -> None:
        auth = ws.request.headers.get("Authorization", "")
        session = {
            "path": ws.request.path,
            "auth_ok": auth == f"Bearer {args.key}",
            "updates": 0,
            "audio_chunks": 0,
            "audio_bytes": 0,
            "committed": False,
            "finished": False,
        }
        log(f"connect {ws.request.path} auth_ok={session['auth_ok']}")
        await ws.send(json.dumps({"type": "session.created", "session": {"id": "smoke"}}))
        async for raw in ws:
            event = json.loads(raw)
            kind = event.get("type")
            if kind == "session.update":
                session["updates"] += 1
                await ws.send(json.dumps({"type": "session.updated", "session": {"id": "smoke"}}))
            elif kind == "input_audio_buffer.append":
                session["audio_chunks"] += 1
                session["audio_bytes"] += len(base64.b64decode(event.get("audio", "")))
            elif kind == "input_audio_buffer.commit":
                session["committed"] = True
                await ws.send(json.dumps({"type": "input_audio_buffer.committed"}))
            elif kind == "session.finish":
                session["finished"] = True
                await ws.send(
                    json.dumps(
                        {
                            "type": "conversation.item.input_audio_transcription.completed",
                            "transcript": PHRASE,
                        }
                    )
                )
                await ws.send(json.dumps({"type": "session.finished"}))
                break
            else:
                log(f"ignored {kind}")
        log(f"session done: {json.dumps(session)}")
        sessions.append(session)
        summary = {"phrase": PHRASE, "sessions": sessions}
        args.summary.write_text(json.dumps(summary, ensure_ascii=False), encoding="utf-8")

    async def run() -> None:
        async with serve(handler, "127.0.0.1", args.port) as server:
            log(f"listening on 127.0.0.1:{args.port}")
            await server.serve_forever()

    asyncio.run(run())


if __name__ == "__main__":
    sys.exit(main())
