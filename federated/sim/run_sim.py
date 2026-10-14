"""Сквозная симуляция на этом Mac без реальных данных губ.

10 честных клиентов с не-IID шардами + 1 злоумышленник, 5 раундов, ВСЁ через настоящие компоненты:
сервер uvicorn (HTTPS на localhost с закреплением ключа), клиентский FederatedClient (планировщик, упаковка, подпись,
отправка с повторами, загрузка и проверка адаптера), агрегатор `python -m server.aggregate`.
Заменено только обучение: крошечный трансформер из sim/tiny_model.py вместо MultiVSR.

Запуск (под охранником памяти):
  python3 ../tools/mem_guard.py -- .venv/bin/python -m sim.run_sim [--rounds 5] [--no-ablation]
"""
from __future__ import annotations

import argparse
import copy
import json
import shutil
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from client import consent  # noqa: E402
from client.config import ClientConfig, ServerCfg  # noqa: E402
from client.downloader import ModelSync  # noqa: E402
from client.power import Snapshot  # noqa: E402
from client.runner import FederatedClient  # noqa: E402
from client.trainer import TrainResult  # noqa: E402
from client.transport import Transport  # noqa: E402
from protocol.adapter_io import load_adapter, save_adapter  # noqa: E402
from protocol.modelsig import public_b64  # noqa: E402
from protocol.spec import save_spec  # noqa: E402
from server.store import Store  # noqa: E402
from sim import tiny_model as tm  # noqa: E402
from sim.tls import make_selfsigned  # noqa: E402

LOCAL_STEPS, LOCAL_LR = 10, 3e-3
N_HONEST = 10
ATTACKS = {  # раунд -> (название, описание)
    1: ("scale x1000", "дельта умножена на 1000 (грубая атака)"),
    2: ("scale x6", "дельта x6: норма ниже порога приёма, но выше типичной"),
    3: ("sign-flip x5", "обратный знак x5 (пытается увести модель назад)"),
    4: ("label-flip x5", "обучение на сдвинутых метках (y+1) и усиление x5 (целевое отравление)"),
    5: ("scale x1000", "дельта умножена на 1000"),
}


class TinyTrainer:
    """Реализация интерфейса Trainer на крошечной модели. Честная: обучает на своём шарде. Злоумышленник: портит дельту."""
    in_process = True

    def __init__(self, shard: tm.Shard, base_model: tm.Tiny, seed: int, attack_for_round=None, round_ref=None):
        self.shard, self.model, self.seed = shard, base_model, seed
        self.attack_for_round, self.round_ref = attack_for_round, round_ref

    def train_lora(self, features_dir, base_adapter, steps, out, *, should_stop=None) -> TrainResult:
        base = load_adapter(base_adapter)
        tm.set_adapter(self.model, base)
        rnd = self.round_ref[0] if self.round_ref else 0
        atk = self.attack_for_round(rnd) if self.attack_for_round else None
        y_over = (self.shard.y_train + 1) % tm.K if atk == "label-flip x5" else None
        done = tm.train_local(self.model, self.shard, steps, LOCAL_LR, self.seed * 1000 + rnd, should_stop=should_stop, y_override=y_over)
        new = tm.get_adapter(self.model)
        if atk:
            mult = {"scale x1000": 1000.0, "scale x6": 6.0, "sign-flip x5": -5.0, "label-flip x5": 5.0}[atk]
            new = {k: base[k] + mult * (new[k] - base[k]) for k in new}
        save_adapter(new, out)
        return TrainResult(Path(out), len(self.shard.y_train), done, steps, None, 0.0)


@dataclass
class Scenario:
    name: str
    defenses: bool
    results: list = field(default_factory=list)


def free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def server_toml(defenses: bool) -> str:
    if defenses:
        return ("[aggregation]\nmethod = \"trimmed_mean\"\ntrim_ratio = 0.1\nmin_clients = 8\nclip_median_mult = 1.5\n"
                "[limits]\nmax_update_norm = 8.0\nmax_updates_per_client_per_day = 10\n")
    return ("[aggregation]\nmethod = \"mean\"\nmin_clients = 8\nclip_norm = 1e12\n"
            "[limits]\nmax_update_norm = 1e12\nmax_updates_per_client_per_day = 10\n")


def run_scenario(name: str, defenses: bool, out: Path, world, base_model: tm.Tiny, shards, rounds: int, seed: int) -> Scenario:
    sc = Scenario(name, defenses)
    root = out / name
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    spec = tm.tiny_spec()
    save_spec(spec, root / "spec.json")
    ad0 = tm.get_adapter(base_model)
    save_adapter(ad0, root / "init.safetensors")
    srv = root / "server"
    run = lambda *a: subprocess.run([sys.executable, "-m", *a], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    run("server.admin", "init", "--data-dir", str(srv), "--spec", str(root / "spec.json"), "--from-adapter", str(root / "init.safetensors"))
    (srv / "server.toml").write_text(server_toml(defenses))
    sign_pub = run("server.admin", "keys", "--data-dir", str(srv)).strip()
    cert, key, pin = make_selfsigned(root / "tls")
    port = free_port()
    proc = subprocess.Popen([sys.executable, "-m", "server.run", "--data-dir", str(srv), "--port", str(port),
                             "--tls-cert", str(cert), "--tls-key", str(key)], cwd=ROOT, start_new_session=True)
    try:
        scfg = ServerCfg(url=f"https://127.0.0.1:{port}", signing_public_key=sign_pub, tls_spki_sha256=pin, tls_ca_file=str(cert),
                         retry_attempts=3, retry_base_seconds=0.2)
        for _ in range(100):
            try:
                Transport(scfg).request("GET", "/v1/health")
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.1)
        else:
            raise RuntimeError("сервер не поднялся")
        sim_time, rnd_ref = [1_000_000.0], [0]
        attack = lambda r: ATTACKS[r][0] if r in ATTACKS else None
        fcs = []
        for i in range(N_HONEST + 1):
            mal = i == N_HONEST
            cfg = ClientConfig(home=root / "clients" / ("evil" if mal else f"c{i:02d}"))
            consent.record(cfg.home, True)   # simulated participants have opted in
            cfg.server, cfg.training.backend = scfg, "stub"
            cfg.schedule.min_examples, cfg.schedule.steps = 10, LOCAL_STEPS
            model = copy.deepcopy(base_model)
            shard = shards[i if not mal else 0]
            tr = TinyTrainer(shard, model, seed + i, attack if mal else None, rnd_ref if mal else None)
            probe = type("P", (), {"snapshot": lambda self: Snapshot(True, False, 3600)})()
            fcs.append(FederatedClient(cfg, spec=spec, trainer=tr, probe=probe, transport=Transport(scfg), clock=lambda: sim_time[0], log=lambda s: None))
        evcfg = ClientConfig(home=root / "eval"); evcfg.server = scfg
        ev = ModelSync(evcfg, spec, Transport(scfg))
        eval_model = copy.deepcopy(base_model)
        honest = shards[:N_HONEST]
        xb, yb = torch.cat([s.x_bal for s in honest]), torch.cat([s.y_bal for s in honest])

        def evaluate(label: int):
            ev.sync()
            v, ad = ev.load_current()
            tm.set_adapter(eval_model, ad)
            per = [tm.accuracy(eval_model, s.x_test, s.y_test) for s in honest]
            return v, tm.accuracy(eval_model, xb, yb), per

        v, g, per = evaluate(0)
        sc.results.append(dict(round=0, version=v, global_acc=g, client_mean=float(np.mean(per)), client_min=float(np.min(per)), client_max=float(np.max(per)),
                               per_client=per, uploads={}, malicious=None))
        for r in range(1, rounds + 1):
            rnd_ref[0] = r
            sim_time[0] += 25 * 3600
            uploads = {}
            for i, fc in enumerate(fcs):
                res = fc.run_cycle()
                uploads["evil" if i == N_HONEST else f"c{i:02d}"] = f"{res.status}" + (f" ({res.detail[:90]})" if res.status != "uploaded" else "")
            agg_out = run("server.aggregate", "--data-dir", str(srv))
            v, g, per = evaluate(r)
            with Store(srv).db() as db:
                row = db.execute("SELECT stats_json FROM rounds WHERE round_version=?", (v,)).fetchone()
            st = json.loads(row["stats_json"]) if row else None
            evil = None
            if st and fcs[-1].identity.client_id[:8] in st["clients"]:
                j = st["clients"].index(fcs[-1].identity.client_id[:8])
                evil = dict(norm=st["norms"][j], clip_scale=st["clip_scales"][j], trimmed_frac=st["trimmed_frac"][j])
            honest_norms = [n for c, n in zip(st["clients"], st["norms"]) if c != fcs[-1].identity.client_id[:8]] if st else []
            sc.results.append(dict(round=r, version=v, global_acc=g, client_mean=float(np.mean(per)), client_min=float(np.min(per)),
                                   client_max=float(np.max(per)), per_client=per, uploads=uploads, malicious=evil,
                                   attack=ATTACKS.get(r), clip_norm=st["clip_norm"] if st else None, honest_norm_median=float(np.median(honest_norms)) if honest_norms else None,
                                   n_aggregated=st["n"] if st else 0, agg_log=agg_out))
        return sc
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


def local_only_baseline(base_model: tm.Tiny, shards, steps_total: int, seed: int) -> list[float]:
    accs = []
    for i, s in enumerate(shards[:N_HONEST]):
        m = copy.deepcopy(base_model)
        tm.train_local(m, s, steps_total, LOCAL_LR, seed + i)
        accs.append(tm.accuracy(m, s.x_test, s.y_test))
    return accs


def print_scenario(sc: Scenario) -> None:
    print(f"\n=== {sc.name} ({'ЗАЩИТА ВКЛ: клиппинг + усечённое среднее + лимит нормы' if sc.defenses else 'ЗАЩИТЫ НЕТ: простое среднее, без клиппинга и лимита'}) ===")
    print("раунд  версия  глобальная_acc  acc_клиентов(среднее/мин/макс)   злоумышленник")
    for r in sc.results:
        mal = ""
        if r["round"]:
            up = r["uploads"].get("evil", "")
            atk = r["attack"][0] if r.get("attack") else "-"
            if r["malicious"]:
                m = r["malicious"]
                mal = f"{atk}: принят, норма {m['norm']:.2f}, множитель клиппинга {m['clip_scale']:.3f}, отброшен в {100 * m['trimmed_frac']:.0f}% координат"
            else:
                mal = f"{atk}: {up.split('(')[0].strip()} {up[up.find('(') :][:80] if '(' in up else ''}"
        print(f"{r['round']:>5}  v{r['version']:<5} {100 * r['global_acc']:>12.1f}%   "
              f"{100 * r['client_mean']:>6.1f} / {100 * r['client_min']:>5.1f} / {100 * r['client_max']:>5.1f}%     {mal}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(ROOT / "sim_out"))
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-ablation", action="store_true", help="не запускать вариант без защиты")
    a = ap.parse_args()
    torch.set_num_threads(2)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    world = tm.make_world(a.seed)
    base = tm.pretrain_base(world, a.seed)
    rng = np.random.default_rng(a.seed + 5)
    shards = [tm.make_shard(world, f"c{i:02d}", int(rng.integers(150, 400)), 0.5, rng) for i in range(N_HONEST)]
    tm.add_lora(base)
    n_ad = sum(int(np.prod(v.shape)) for v in tm.get_adapter(base).values())
    print(f"модель-заменитель: LoRA r={tm.RANK} на q,v в {tm.LAYERS} блоках, {n_ad} обучаемых параметров; клиентов {N_HONEST}+1 злоумышленник; "
          f"шагов локально {LOCAL_STEPS}, lr {LOCAL_LR}; размеры шардов {[len(s.y_train) for s in shards]}")
    scen = [run_scenario("defended", True, out, world, base, shards, a.rounds, a.seed)]
    if not a.no_ablation:
        scen.append(run_scenario("undefended", False, out, world, base, shards, a.rounds, a.seed))
    for sc in scen:
        print_scenario(sc)
    lo = local_only_baseline(base, shards, a.rounds * LOCAL_STEPS, a.seed)
    print(f"\nдля сравнения: каждый клиент обучается ОДИН ({a.rounds * LOCAL_STEPS} шагов): acc на своём тесте среднее {100 * np.mean(lo):.1f}% мин {100 * np.min(lo):.1f}%")
    d = scen[0].results
    print("\nлоги агрегатора (с защитой), раунды 2-3:")
    for r in d[2:4]:
        print(f"-- раунд {r['round']}:\n{r['agg_log']}")
    (out / "results.json").write_text(json.dumps({"scenarios": {s.name: s.results for s in scen}, "local_only": lo}, indent=1, ensure_ascii=False))
    print(f"\nрезультаты: {out / 'results.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
