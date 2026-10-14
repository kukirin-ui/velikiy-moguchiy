"""Запуск сервера: python -m server.run --data-dir DIR [--port 8765] [--tls-cert C --tls-key K].

Привязка ТОЛЬКО к loopback (127.0.0.1/::1/localhost): наружу сервис не выставляется, переопределения нет.
"""
from __future__ import annotations

import argparse
import ipaddress
import sys
from pathlib import Path

import uvicorn

from server.app import create_app

LOOPBACK_NAMES = {"localhost"}


def is_loopback(host: str) -> bool:
    if host in LOOPBACK_NAMES:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--tls-cert")
    ap.add_argument("--tls-key")
    a = ap.parse_args(argv)
    if not is_loopback(a.host):
        print(f"отказ: {a.host} не loopback. Сервис слушает только localhost.", file=sys.stderr)
        return 2
    app = create_app(Path(a.data_dir))
    uvicorn.run(app, host=a.host, port=a.port, log_level="warning", ssl_certfile=a.tls_cert, ssl_keyfile=a.tls_key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
