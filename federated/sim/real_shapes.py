"""Дымовой прогон с РЕАЛЬНЫМИ формами LoRA MultiVSR (r=16 на q,v, 144 тензора, 1 769 472 параметра), веса случайные.

Обучения нет: клиенты «производят» случайную дельту заданной нормы. Проверяется вся труба: упаковка fp16 + подпись ->
HTTPS с закреплением -> проверка схемы/подписи/форм на сервере -> агрегация (настоящий `python -m server.aggregate`) ->
загрузка и проверка новой версии. Печатает размеры в МБ и сверяет результат агрегации с независимым расчётом.
Только numpy (torch не нужен); все равно запускать под охранником памяти.
"""
from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from client.config import ClientConfig, ServerCfg  # noqa: E402
from client.downloader import ModelSync  # noqa: E402
from client.transport import Transport  # noqa: E402
from client.uploader import upload_update  # noqa: E402
from protocol.adapter_io import loads_adapter, validate_against_spec  # noqa: E402
from protocol.identity import Identity  # noqa: E402
from protocol.package import pack_update  # noqa: E402
from protocol.spec import load_spec  # noqa: E402
from sim.tls import make_selfsigned  # noqa: E402

SPEC = ROOT / "protocol" / "specs" / "multivsr_lora_r16.json"
MB = 1e6


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "sim_out" / "real_shapes"))
    ap.add_argument("--clients", type=int, default=3)
    ap.add_argument("--norm", type=float, default=1.0)
    a = ap.parse_args()
    out = Path(a.out)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    spec = load_spec(SPEC)
    run = lambda *x: subprocess.run([sys.executable, "-m", *x], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    srv = out / "server"
    print(run("server.admin", "init", "--data-dir", str(srv), "--spec", str(SPEC), "--seed", "0").strip())
    (srv / "server.toml").write_text(f"[aggregation]\nmin_clients = {a.clients}\nclip_norm = 2.0\nmethod = \"trimmed_mean\"\n[limits]\nmax_update_norm = 50.0\n")
    pub = run("server.admin", "keys", "--data-dir", str(srv)).strip()
    cert, key, pin = make_selfsigned(out / "tls")
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    proc = subprocess.Popen([sys.executable, "-m", "server.run", "--data-dir", str(srv), "--port", str(port), "--tls-cert", str(cert),
                             "--tls-key", str(key)], cwd=ROOT, start_new_session=True)
    try:
        scfg = ServerCfg(url=f"https://127.0.0.1:{port}", signing_public_key=pub, tls_spki_sha256=pin, tls_ca_file=str(cert),
                         retry_attempts=3, retry_base_seconds=0.2)
        for _ in range(100):
            try:
                Transport(scfg).request("GET", "/v1/health"); break
            except Exception:  # noqa: BLE001
                time.sleep(0.1)
        cfg = ClientConfig(home=out / "client"); cfg.server = scfg
        sync = ModelSync(cfg, spec, Transport(scfg))
        r = sync.sync()
        v1, g1 = sync.load_current()
        validate_against_spec(g1, spec, delta=False, dtype=np.float32)
        size_global = sync.store.path(v1).stat().st_size
        print(f"v{v1}: скачан и проверен, {len(g1)} тензоров, файл {size_global / MB:.3f} МБ (fp32)")

        rng = np.random.default_rng(1)
        sent, expected = [], []
        c_norm = 2.0
        for i in range(a.clients):
            delta = {t.name: rng.standard_normal(t.shape).astype(np.float32) for t in spec.delta_tensors}
            nrm = np.sqrt(sum(float((x.astype(np.float64) ** 2).sum()) for x in delta.values()))
            delta = {k: x * (a.norm * (1 + 0.2 * i) / nrm) for k, x in delta.items()}   # нормы 1.0, 1.2, 1.4...
            t0 = time.perf_counter()
            p = pack_update(delta, spec=spec, base_version=v1, num_examples=100 + 50 * i, identity=Identity.generate())
            t_pack = time.perf_counter() - t0
            t0 = time.perf_counter()
            rec = upload_update(Transport(scfg), p.envelope, p.payload)
            t_up = time.perf_counter() - t0
            sent.append((len(p.envelope), len(p.payload), t_pack, t_up))
            expected.append(({k: x.astype(np.float32) for k, x in loads_adapter(p.payload).items()}, 100 + 50 * i))
        print(run("server.aggregate", "--data-dir", str(srv)).strip())
        r2 = sync.sync()
        v2, g2 = sync.load_current()
        validate_against_spec(g2, spec, delta=False, dtype=np.float32)
        # независимая проверка: n=3 -> k=floor(0.1*3)=0 -> взвешенное среднее клиппированных (C=2.0, все нормы < 2.0 -> без клиппинга)
        w = np.array([n for _, n in expected], np.float64)
        err = 0.0
        for k in g1:
            exp = sum(wi * d[k].astype(np.float64) for (d, _), wi in zip(expected, w)) / w.sum()
            err = max(err, float(np.abs((g2[k] - g1[k]) - exp).max()))
        env, pay, tp, tu = sent[0]
        print(f"\nреальные формы MultiVSR LoRA r=16 (q,v во всех 36 вниманиях): {spec.num_params} параметров, {len(spec.tensors)} тензоров")
        print(f"дельта fp16 (safetensors): {pay} Б = {pay / MB:.3f} МБ ({pay / 2**20:.3f} МиБ); манифест с подписью: {env} Б")
        print(f"глобальный адаптер fp32: {size_global / MB:.3f} МБ ({size_global / 2**20:.3f} МиБ)")
        print(f"упаковка+подпись: {tp * 1000:.0f} мс; отправка по HTTPS localhost (включая проверку на сервере): {tu * 1000:.0f} мс")
        print(f"версия после агрегации: v{v2}; максимальное расхождение с независимым расчётом: {err:.2e}")
        print(f"за раунд на клиента: {(pay + env) / MB:.3f} МБ вверх, {size_global / MB:.3f} МБ вниз")
        assert v2 == v1 + 1 and err < 1e-6
        (out / "result.json").write_text(json.dumps(dict(params=spec.num_params, tensors=len(spec.tensors), delta_bytes=pay,
                                                         envelope_bytes=env, global_bytes=size_global, max_err=err)))
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
