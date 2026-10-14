"""Цикл клиента и CLI.

  python -m client.runner init              создать ~/.velikiy-moguchiy-federated, ключи установки, config.toml
  python -m client.runner consent on|off    отдельное согласие на участие в общем обучении (по умолчанию выключено)
  python -m client.runner status            согласие, состояние, условия запуска сейчас, последний отправленный манифест
  python -m client.runner once [--force] [--dry-run]   один проход: условия -> синхронизация -> обучение -> отправка
  python -m client.runner daemon            проход каждые poll_seconds

Без согласия (client/consent.py) проход сразу заканчивается: ни синхронизации, ни обучения, ни отправки, и --force этого
не меняет. Порядок прохода с согласием: (1) условия планировщика (питание, простой, интервал); (2) повторная отправка из outbox, если база
ещё актуальна; (3) синхронизация глобального адаптера; (4) обучение на локальных данных (под охранником памяти) с
пере-проверкой условий; (5) дельта = обученный минус глобальный, fp16, подпись, отправка с повторами.
Каждая отправка пишется в upload-log.jsonl (что именно ушло).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from client import consent
from client.config import ClientConfig, load_config, write_default_config
from client.downloader import ModelSync
from client.power import SystemProbe
from client.scheduler import ActiveClock, Monitor, evaluate
from client.trainer import Trainer, make_trainer
from client.transport import Transport
from client.uploader import log_upload, upload_update
from protocol.adapter_io import compute_delta, load_adapter
from protocol.errors import PERMANENT, ProtocolError
from protocol.identity import Identity
from protocol.package import PackedUpdate, pack_update, parse_envelope
from protocol.schema import UpdateReceipt
from protocol.spec import AdapterSpec, load_spec

BUNDLED_SPEC = Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json"


@dataclass
class CycleResult:
    status: str           # no_consent | skipped | uploaded | duplicate | nothing_new | not_enough_data | too_little_training | stale | error | dry_run
    detail: str = ""
    receipt: Optional[UpdateReceipt] = None


class State:
    def __init__(self, path: Path):
        self.path = path
        self.d = json.loads(path.read_text()) if path.exists() else {}

    def get(self, k, default=None):
        return self.d.get(k, default)

    def update(self, **kw) -> None:
        self.d.update(kw)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.d))
        tmp.replace(self.path)


class FederatedClient:
    def __init__(self, cfg: ClientConfig, *, spec: AdapterSpec | None = None, trainer: Trainer | None = None,
                 probe: SystemProbe | None = None, transport: Transport | None = None,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] = print):
        self.cfg = cfg
        self.spec = spec or load_spec(Path(cfg.training.spec_path).expanduser() if cfg.training.spec_path else BUNDLED_SPEC)
        self.identity = Identity.load_or_create(cfg.home)
        self.trainer = trainer or make_trainer(cfg)
        self.probe = probe or SystemProbe()
        self.transport = transport or Transport(cfg.server)
        self.sync = ModelSync(cfg, self.spec, self.transport)
        self.state = State(cfg.state_path)
        self.clock = clock
        self.log = log

    # --- outbox: обновление упаковано, но отправка не удалась ---
    def _outbox_paths(self, base: int) -> tuple[Path, Path]:
        d = self.cfg.outbox_dir
        return d / f"v{base:06d}.envelope.json", d / f"v{base:06d}.payload.safetensors"

    def _save_outbox(self, packed: PackedUpdate) -> None:
        env, pay = self._outbox_paths(packed.manifest.base_version)
        env.parent.mkdir(parents=True, exist_ok=True)
        env.write_bytes(packed.envelope)
        pay.write_bytes(packed.payload)

    def _clear_outbox(self) -> None:
        for p in self.cfg.outbox_dir.glob("v*.*"):
            p.unlink(missing_ok=True)

    def _send(self, packed: PackedUpdate) -> CycleResult:
        try:
            receipt = upload_update(self.transport, packed.envelope, packed.payload)
        except ProtocolError as e:
            log_upload(self.cfg.upload_log, packed, None, error=e.code)
            if e.code in ("stale_base", "unknown_base"):
                self._clear_outbox()
                return CycleResult("stale", f"база устарела, актуальна v{e.extra.get('latest_version')}")
            if e.code in PERMANENT:
                self._clear_outbox()
                return CycleResult("error", f"сервер отклонил обновление: {e}")
            self._save_outbox(packed)  # временная ошибка: попробуем на следующем проходе
            return CycleResult("error", f"отправка не удалась, оставлено в outbox: {e}")
        log_upload(self.cfg.upload_log, packed, receipt)
        self._clear_outbox()
        self.state.update(last_run_ts=self.clock(), last_base=packed.manifest.base_version)
        return CycleResult("uploaded" if receipt.status == "accepted" else "duplicate", "", receipt)

    def _resend_outbox(self, current_version: int) -> Optional[CycleResult]:
        env_p, pay_p = self._outbox_paths(current_version)
        if env_p.exists() and pay_p.exists():
            env, pay = env_p.read_bytes(), pay_p.read_bytes()
            return self._send(PackedUpdate(envelope=env, payload=pay, manifest=parse_envelope(env).manifest))
        self._clear_outbox()  # база уже не актуальна
        return None

    def run_cycle(self, *, force: bool = False, dry_run: bool = False) -> CycleResult:
        cfg, sc = self.cfg, self.cfg.schedule
        if not consent.granted(cfg.home):
            return CycleResult("no_consent", "участие в общем обучении выключено (python -m client.runner consent on)")
        now = self.clock()
        if not force:
            d = evaluate(self.probe.snapshot(), sc, self.state.get("last_run_ts"), now)
            if not d.run:
                return CycleResult("skipped", "; ".join(d.reasons))
        try:
            sync = self.sync.sync()
        except ProtocolError as e:
            return CycleResult("error", f"синхронизация модели: {e}")
        except Exception as e:  # noqa: BLE001
            return CycleResult("error", f"синхронизация модели: {type(e).__name__}: {e}")
        if sync.skipped_reason or sync.version == 0:
            return CycleResult("nothing_new", sync.skipped_reason or "нет установленного адаптера")
        base_version = sync.version
        if not dry_run:
            r = self._resend_outbox(base_version)
            if r is not None:
                return r
        if self.state.get("last_base") == base_version and not force:
            return CycleResult("nothing_new", f"уже участвовали в раунде на базе v{base_version}")

        out = cfg.work_dir / "trained.safetensors"
        out.parent.mkdir(parents=True, exist_ok=True)
        aclock = ActiveClock(sc.max_runtime_minutes * 60) if getattr(self.trainer, "in_process", False) else None
        monitor = Monitor(self.probe, sc, aclock) if not force else Monitor(self.probe, _no_conditions(sc), aclock)
        res = self.trainer.train_lora(Path(cfg.training.features_dir).expanduser(), sync.path, sc.steps, out, should_stop=monitor)
        if res.num_examples < sc.min_examples:
            return CycleResult("not_enough_data", f"локальных примеров {res.num_examples} < {sc.min_examples}")
        if res.steps_done < sc.min_steps_fraction * sc.steps:
            return CycleResult("too_little_training", f"сделано {res.steps_done} из {sc.steps} шагов ({res.stopped_reason or monitor.reason})")
        base = load_adapter(sync.path)
        delta = compute_delta(load_adapter(out), base, self.spec)
        packed = pack_update(delta, spec=self.spec, base_version=base_version, num_examples=res.num_examples, identity=self.identity)
        if dry_run:
            return CycleResult("dry_run", f"упаковано {len(packed.payload)} Б (не отправлено); манифест: {packed.envelope.decode()}")
        return self._send(packed)


def _no_conditions(sc):
    from dataclasses import replace
    return replace(sc, require_ac_power=False, forbid_low_power_mode=False, idle_minutes=0.0)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["init", "consent", "status", "once", "daemon"])
    ap.add_argument("value", nargs="?", choices=["on", "off"], help="consent: включить или выключить участие")
    ap.add_argument("--home", help="по умолчанию ~/.velikiy-moguchiy-federated (или прежний ~/.govorun-federated) либо $VELIKIY_MOGUCHIY_FED_HOME")
    ap.add_argument("--force", action="store_true", help="игнорировать условия планировщика")
    ap.add_argument("--dry-run", action="store_true", help="обучить и упаковать, но не отправлять")
    ap.add_argument("--parent-pid", type=int, help="daemon: выйти, когда процесс с этим pid исчезнет (как у mic-warm)")
    a = ap.parse_args(argv)
    cfg = load_config(Path(a.home) if a.home else None)
    if a.cmd == "init":
        p = write_default_config(cfg.home)
        ident = Identity.load_or_create(cfg.home)
        print(f"конфиг: {p}\nclient_id: {ident.client_id}\nпубличный ключ: {ident.public_b64}")
        print("участие в общем обучении: " + ("включено" if consent.granted(cfg.home) else
                                             "выключено (включить: python -m client.runner consent on)"))
        return 0
    if a.cmd == "consent":
        if a.value:
            consent.record(cfg.home, a.value == "on")
        print("участие в общем обучении: " + ("включено" if consent.granted(cfg.home) else "выключено"))
        return 0
    fc = FederatedClient(cfg)
    if a.cmd == "status":
        snap = fc.probe.snapshot()
        d = evaluate(snap, cfg.schedule, fc.state.get("last_run_ts"), time.time())
        print(f"участие в общем обучении: {'включено' if consent.granted(cfg.home) else 'выключено'}\n"
              f"client_id: {fc.identity.client_id}\nустановленный адаптер: v{fc.sync.store.current()}\n"
              f"питание от сети: {snap.on_ac}; экономия энергии: {snap.low_power}; простой: {snap.idle_seconds / 60:.1f} мин\n"
              f"запуск сейчас: {'да' if d.run else 'нет (' + '; '.join(d.reasons) + ')'}")
        if cfg.upload_log.exists():
            last = cfg.upload_log.read_text().strip().splitlines()[-1]
            print("последняя отправка (манифест):", last)
        return 0
    if a.cmd == "once":
        r = fc.run_cycle(force=a.force, dry_run=a.dry_run)
        print(f"{r.status}: {r.detail}")
        return 0 if r.status in ("uploaded", "duplicate", "skipped", "nothing_new", "dry_run", "no_consent") else 1
    return daemon(fc, a.parent_pid)


def parent_alive(pid: Optional[int]) -> bool:
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def daemon(fc: FederatedClient, parent_pid: Optional[int], sleep: Callable[[float], None] = time.sleep) -> int:
    """Проход каждые poll_seconds; при ошибках пауза растёт вдвое до 6 часов. Выходит вместе с родительским приложением."""
    fails = 0
    while parent_alive(parent_pid):
        r = fc.run_cycle()
        fc.log(f"[{time.strftime('%H:%M:%S')}] {r.status}: {r.detail}")
        fails = fails + 1 if r.status == "error" else 0
        wait = min(6 * 3600, fc.cfg.schedule.poll_seconds * (2 ** fails))
        waited = 0.0
        while waited < wait and parent_alive(parent_pid):  # спим кусками, чтобы быстро заметить выход родителя
            sleep(min(5.0, wait - waited))
            waited += 5.0
    return 0


if __name__ == "__main__":
    sys.exit(main())
