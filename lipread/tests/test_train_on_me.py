"""«Обучить на мне» without weights, GPU or a Mac: clip discovery, the hold-out split, install/rollback, the R11
allowance and the memory guard, and the whole job end to end with stub model steps.

  python -m pytest tests/test_train_on_me.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import personal as P  # noqa: E402
import train_on_me as T  # noqa: E402

TOOLS_GUARD = ROOT.parent / "tools" / "mem_guard.py"


# --- helpers ---------------------------------------------------------------------------------------------------
def make_clip(d: Path, cid, text, dur=3.0, mp4=True, txt=True, meta=None):
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{cid}.json").write_text(json.dumps(meta if meta is not None else {"id": cid, "duration_s": dur}))
    if txt:
        (d / f"{cid}.txt").write_text(text + "\n", encoding="utf8")
    if mp4:
        (d / f"{cid}.mp4").write_bytes(f"video {cid} {text}".encode())


def make_clips(d: Path, n: int, start=1700000000000, prefix="фраза номер"):
    for i in range(n):
        make_clip(d, start + i, f"{prefix} {i}", dur=2.0 + (i % 5))


def clip(cid, text, dur=3.0):
    return P.Clip(str(cid), Path(f"/x/{cid}.mp4"), text, dur)


def load_tools_guard():
    spec = importlib.util.spec_from_file_location("tools_mem_guard", TOOLS_GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- data discovery --------------------------------------------------------------------------------------------
def test_app_data_dir_prefers_new_and_keeps_legacy(tmp_path):
    assert P.app_data_dir(tmp_path) == tmp_path / ".velikiy-moguchiy"
    (tmp_path / ".koe").mkdir()
    assert P.app_data_dir(tmp_path) == tmp_path / ".koe"
    (tmp_path / ".velikiy-moguchiy").mkdir()
    assert P.app_data_dir(tmp_path) == tmp_path / ".velikiy-moguchiy"
    assert P.default_clips_dir(tmp_path / ".koe") == tmp_path / ".koe" / "lipdata" / "voiced"


def test_discover_clips_counts_like_the_app_and_filters(tmp_path):
    d = tmp_path / "voiced"
    make_clip(d, 1, "Привет, как дела?", 3.0)
    make_clip(d, 2, "вторая фраза", 4.5)
    make_clip(d, 3, "в полёте", 3.0, mp4=False)              # the app has not moved the video in yet: not counted
    make_clip(d, 4, "битый", meta={"duration_s": "3"})       # no numeric duration: the app does not count it either
    make_clip(d, 5, "без текста", 3.0, txt=False)
    make_clip(d, 6, "   ", 3.0)
    make_clip(d, 7, "коротко", 0.5)
    make_clip(d, 8, "длинная диктовка", 25.0)
    make_clip(d, 9, "Тестовая фраза!", 3.0)
    (d / ".10.json").write_text(json.dumps({"duration_s": 3}))
    (d / ".10.mp4").write_bytes(b"x")
    disc = P.discover_clips(d, test_keys={P.normalize("тестовая фраза")})
    assert [c.id for c in disc.usable] == ["1", "2"]
    assert disc.usable[0].text == "Привет, как дела?" and disc.usable[0].key == "привет как дела"
    assert disc.total == 7                                      # 1, 2, 5, 6, 7, 8, 9
    assert disc.total_seconds == pytest.approx(3 + 4.5 + 3 + 3 + 0.5 + 25 + 3)
    assert disc.usable_seconds == pytest.approx(7.5)
    assert disc.skipped == {"нет текста": 1, "пустой текст": 1, "короче 1 с": 1, "длиннее 12 с": 1,
                            "фраза из теста": 1}


def test_discover_missing_dir(tmp_path):
    disc = P.discover_clips(tmp_path / "nope")
    assert disc.usable == [] and disc.total == 0


def test_test_phrase_keys(tmp_path):
    (tmp_path / "001.txt").write_text("Ёлка, зелёная.\n", encoding="utf8")
    assert P.test_phrase_keys(tmp_path) == {"елка зеленая"}


# --- the hold-out split ----------------------------------------------------------------------------------------
def test_holdout_is_ten_percent_deterministic_and_order_free():
    clips = [clip(i, f"фраза {i}") for i in range(200)]
    pool, hold = P.holdout_split(clips)
    assert len(hold) == 20 and len(pool) == 180
    assert not {c.id for c in pool} & {c.id for c in hold}
    pool2, hold2 = P.holdout_split(list(reversed(clips)))
    assert {c.id for c in hold2} == {c.id for c in hold}
    assert P.holdout_split([]) == ([], [])


def test_holdout_keeps_a_phrase_on_one_side():
    clips = [clip(i, f"фраза {i % 30}") for i in range(120)]  # every phrase said 4 times
    pool, hold = P.holdout_split(clips)
    assert {c.key for c in pool}.isdisjoint({c.key for c in hold})
    assert 12 <= len(hold) <= 24
    # punctuation and case do not make a different phrase
    clips = [clip(1, "Привет!"), clip(2, "привет")] + [clip(i, f"другое {i}") for i in range(3, 40)]
    pool, hold = P.holdout_split(clips)
    sides = {c.id: ("hold" if c in hold else "pool") for c in clips}
    assert sides["1"] == sides["2"]


def test_holdout_is_not_swallowed_by_one_frequent_phrase():
    clips = [clip(i, "одна и та же фраза") for i in range(60)] + [clip(100 + i, f"фраза {i}") for i in range(40)]
    pool, hold = P.holdout_split(clips)
    assert 10 <= len(hold) <= 20
    assert all(c.key != "одна и та же фраза" for c in hold)


def test_dev_split_and_e2e_folder():
    clips = [clip(i, f"фраза {i}") for i in range(90)]
    train, dev = P.dev_split(clips)
    assert len(dev) == 14 and len(train) == 76
    stems = [str(1700000000000 + i) for i in range(80)]
    from split import split_for
    name, n_train, n_dev = P.e2e_personal_folder(stems)
    assert n_dev >= P.E2E_MIN_DEV and n_train + n_dev == 80
    assert n_dev == sum(split_for(f"me:{name}/{s}", 15) == "dev" for s in stems)  # what train_e2e.py will see
    assert P.e2e_personal_repeat(76) == 2 and P.e2e_personal_repeat(150) == 1
    with pytest.raises(ValueError):
        P.e2e_personal_folder(stems[:5])


def test_step_counts():
    assert P.light_steps(76) == 95          # ceil(20 * 76 / 16), as train.py computes it with --mix voiced=1
    assert P.light_steps(5000) == P.LIGHT["max_steps"]
    assert P.full_steps(10) == P.FULL["min_steps"] and P.full_steps(10_000) == P.FULL["max_steps"]


# --- install and rollback --------------------------------------------------------------------------------------
def fake_root(tmp_path, factory=True) -> Path:
    r = tmp_path / "lipread"
    if factory:
        run = r / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"
        run.mkdir(parents=True)
        (run / "best.pt").write_bytes(b"factory lora")
        (run / "best_venc.pth").write_bytes(b"factory venc")
    for f in ("train_e2e.py", "train.py", "mvsr.py", "lora.py"):
        (r / f).parent.mkdir(parents=True, exist_ok=True)
        (r / f).write_text(f"# {f}\n")
    return r


def new_model(tmp_path, tag) -> tuple[Path, Path]:
    d = tmp_path / f"new-{tag}"
    d.mkdir()
    (d / "best.pt").write_bytes(f"lora {tag}".encode())
    (d / "best_venc.pth").write_bytes(f"venc {tag}".encode())
    return d / "best.pt", d / "best_venc.pth"


def test_store_install_and_rollback(tmp_path):
    root, app = fake_root(tmp_path), tmp_path / "app"
    s = P.ModelStore(app, root)
    assert s.active() == {"current": None, "previous": None}
    assert s.current().kind == "factory" and s.current().lora.read_bytes() == b"factory lora"
    assert s.previous() is None and s.service_run_dir() is None
    with pytest.raises(P.NothingToRollBack):
        s.rollback()

    a = s.install(*new_model(tmp_path, "a"), {"mode": "light", "new_wer": 0.7})
    assert s.active() == {"current": a, "previous": P.FACTORY}
    cur = s.current()
    assert cur.kind == "personal" and cur.lora.read_bytes() == b"lora a" and cur.venc.read_bytes() == b"venc a"
    assert cur.info["mode"] == "light" and cur.info["id"] == a and "installed_at" in cur.info
    assert s.service_run_dir() == app / "lips_model" / "models" / a
    assert s.previous().kind == "factory"

    # «Вернуть прежнюю модель» goes back to the factory model; a second rollback undoes the first
    s.rollback()
    assert s.active() == {"current": None, "previous": a} and s.current().kind == "factory"
    s.rollback()
    assert s.active() == {"current": a, "previous": P.FACTORY}

    b = s.install(*new_model(tmp_path, "b"), {"mode": "full"})
    assert s.active() == {"current": b, "previous": a}
    c = s.install(*new_model(tmp_path, "c"), {"mode": "light"})
    assert s.active() == {"current": c, "previous": b}
    assert sorted(p.name for p in (app / "lips_model" / "models").iterdir()) == sorted([b, c])  # a is gone
    s.rollback()
    assert s.current().lora.read_bytes() == b"lora b" and s.previous().lora.read_bytes() == b"lora c"


def test_store_survives_a_deleted_model_and_base_fallback(tmp_path):
    root, app = fake_root(tmp_path, factory=False), tmp_path / "app"
    s = P.ModelStore(app, root)
    assert s.current().kind == "base" and s.current().lora is None
    a = s.install(*new_model(tmp_path, "a"), {"mode": "light"})
    import shutil
    shutil.rmtree(app / "lips_model" / "models" / a)
    assert s.active() == {"current": None, "previous": None} and s.current().kind == "base"
    (app / "lips_model" / "active.json").write_text("{broken")
    assert s.active() == {"current": None, "previous": None}


def test_lips_service_follows_the_installed_model(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    import lips_service
    assert lips_service.installed_run() == lips_service.DEFAULT_RUN
    s = P.ModelStore(tmp_path / ".velikiy-moguchiy")
    a = s.install(*new_model(tmp_path, "a"), {"mode": "light"})
    assert lips_service.installed_run() == tmp_path / ".velikiy-moguchiy" / "lips_model" / "models" / a
    s.rollback()
    assert lips_service.installed_run() == lips_service.DEFAULT_RUN


def test_decide_installs_only_a_better_model():
    old = {"wer": 0.741, "cer": 0.47, "n": 12}
    ok, msg = P.decide(old, {"wer": 0.702, "cer": 0.44, "n": 12})
    assert ok and "70,2%" in msg and "74,1%" in msg and "Установлена" in msg
    assert not P.decide(old, {"wer": 0.741, "n": 12})[0]          # a tie keeps the installed model
    assert not P.decide(old, {"wer": 0.80, "n": 12})[0]
    assert not P.decide(old, {"wer": 0.5, "n": 11})[0]            # not the same clips
    assert not P.decide(None, {"wer": 0.5, "n": 12})[0]


# --- the R11 allowance and the memory guard --------------------------------------------------------------------
R11_CASES = [
    ("Linux", {}, ["train.py"], True),
    ("Darwin", {}, ["train.py"], False),
    ("Darwin", {}, ["lips_service.py"], False),
    ("Darwin", {"LIPREAD_MAC_OK": "1"}, ["evaluate.py"], True),
    ("Darwin", {}, ["synth/vsr_check.py"], True),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["/x/lipread/train.py", "--run", "light"], True),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["train_e2e.py"], True),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["train_on_me_worker.py", "evaluate"], True),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["../tools/mem_guard.py", "--", "python", "train.py"], True),
    # the allowance is for this job's scripts only: R11 keeps everything else off the Mac
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["evaluate.py"], False),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["lips_service.py"], False),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["dataset.py"], False),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, ["exams.py", "run"], False),
    ("Darwin", {P.APP_JOB_ENV: "1"}, ["train.py"], False),
    ("Darwin", {"LIPREAD_MAC_OK": "0"}, ["train.py"], False),
    ("Darwin", {P.APP_JOB_ENV: P.APP_JOB}, [], False),
    # the app's lips mode: the service script only
    ("Darwin", {P.APP_JOB_ENV: "lips-service"}, ["/x/lips/service/lips_service.py", "--port", "8766"], True),
    ("Darwin", {P.APP_JOB_ENV: "lips-service"}, ["train.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "lips-service"}, ["evaluate.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "lips-service"}, ["../tools/mem_guard.py", "--", "python", "train.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "lips-service"}, [], False),
    # «Помочь обучить»: the worker's prepare step and train.py only
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["/x/lipread/train_on_me_worker.py", "prepare", "--job", "j"], True),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["train.py", "--run", "help"], True),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["../tools/mem_guard.py", "--", "python", "train.py"], True),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["train_on_me_worker.py", "evaluate"], False),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["train_on_me_worker.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["train_e2e.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["evaluate.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, ["lips_service.py"], False),
    ("Darwin", {P.APP_JOB_ENV: "help-train"}, [], False),
]


@pytest.mark.parametrize("system,env,argv,allowed", R11_CASES)
def test_r11_allowance_is_narrow_and_the_same_in_both_guards(system, env, argv, allowed):
    import memguard
    assert memguard.r11_allowed(system, env, argv) is allowed
    assert load_tools_guard().r11_allowed(system, env, argv) is allowed


def test_r11_allows_exactly_the_job_scripts():
    import memguard
    env = {P.APP_JOB_ENV: P.APP_JOB}
    for script in P.APP_JOB_SCRIPTS:
        assert memguard.r11_allowed("Darwin", env, [script])
    assert not memguard.r11_allowed("Darwin", env, ["train_on_me.py"])  # the orchestrator loads no model


@pytest.mark.parametrize("script,env,code", [
    ("train.py", {}, 1),
    ("train.py", {P.APP_JOB_ENV: P.APP_JOB}, 0),
    ("lips_service.py", {P.APP_JOB_ENV: P.APP_JOB}, 1),
    ("lips_service.py", {P.APP_JOB_ENV: "lips-service"}, 0),
    ("train.py", {P.APP_JOB_ENV: "lips-service"}, 1),
    ("evaluate.py", {P.APP_JOB_ENV: "lips-service"}, 1),
])
def test_memguard_exits_on_a_mac_without_the_allowance(script, env, code):
    """The real import-time check, with platform.system() pretending to be macOS."""
    prog = (f"import platform, sys; platform.system = lambda: 'Darwin'; sys.argv = [{script!r}]; "
            f"sys.path.insert(0, {str(ROOT)!r}); import memguard")
    clean = {k: v for k, v in os.environ.items() if k not in ("LIPREAD_MAC_OK", P.APP_JOB_ENV)}
    r = subprocess.run([sys.executable, "-c", prog], env={**clean, **env}, capture_output=True, text=True)
    assert r.returncode == code, r.stderr
    if code:
        assert "[R11]" in r.stderr


def test_guard_command_caps_the_budget():
    cmd = P.guard_command(["py", "train.py", "--run", "x"], Path("/repo/tools/mem_guard.py"), 36.0, "python3")
    assert cmd[:2] == ["python3", "/repo/tools/mem_guard.py"]
    i = cmd.index("--")
    assert cmd[i + 1:] == ["py", "train.py", "--run", "x"]
    opts = dict(zip(cmd[2:i:2], cmd[3:i:2]))
    assert opts == {"--reserve-gb": "7.2", "--max-budget-gb": "16", "--min-free-pct": "15",
                    "--max-swap-growth-mb": "256"}
    assert P.guard_budget_gb(16) == 7.2 and P.guard_budget_gb(128) == 16.0
    assert P.guard_reserve_gb(16) == 3.2 and P.guard_reserve_gb(64) == 8.0   # the reserve scales with the RAM


def test_setup_refuses_a_mac_with_too_little_memory(tmp_path):
    def too_small(ram):
        return any("нужно не меньше 16 ГБ" in x for x in P.check_setup(tmp_path, ram_gb=ram))
    assert too_small(8) and not too_small(16) and not too_small(36)


def test_warmup_is_shorter_than_the_run():
    assert P.warmup_steps(95) == 9 and P.warmup_steps(30) == 5 and P.warmup_steps(600) == 60
    for steps in (30, 95, 100, 400, 600):
        assert P.warmup_steps(steps) < steps / 2


def test_only_a_missing_face_is_remembered():
    import subprocess as sp
    import train_on_me_worker as W
    assert W.no_face(RuntimeError("лицо не найдено или трек короче 10 кадров (кадров 80, с лицом 0)"))
    assert not W.no_face(RuntimeError("ffmpeg не извлёк кадры из x.mp4"))
    assert not W.no_face(RuntimeError("cv2.VideoWriter XVID не открылся"))
    assert not W.no_face(sp.CalledProcessError(1, ["ffmpeg"]))
    assert not W.no_face(FileNotFoundError("ffmpeg"))


def test_lips_service_waits_for_requests_in_flight():
    import lips_service
    reader = type("R", (), {"work_lock": threading.Lock()})()
    app = lips_service.App(reader, idle_limit=600, parent_pid=0, follow_installed=True)
    assert not app.busy()
    app.begin()                                               # e.g. the Qwen rescoring, outside the work lock
    assert app.busy()
    app.end()
    assert not app.busy()
    with reader.work_lock:
        assert app.busy()


def test_stop_kills_a_step_that_outlives_its_guard(tmp_path):
    """A guard that dies on the stop signal must not leave its step (in its own session) running."""
    guard = tmp_path / "guard.py"
    guard.write_text(textwrap.dedent("""
        import signal, subprocess, sys, time
        c = subprocess.Popen([sys.executable, "-c", "import time; [time.sleep(0.1) for _ in iter(int, 1)]"],
                             start_new_session=True)
        print(c.pid, flush=True)
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))   # exits without stopping the step
        time.sleep(60)
    """))
    proc = subprocess.Popen([sys.executable, str(guard)], stdout=subprocess.PIPE, text=True)
    step = int(proc.stdout.readline())
    t0 = time.monotonic()
    T.stop_guarded(proc, grace=1.0)
    assert time.monotonic() - t0 < 10
    time.sleep(0.3)
    stat = Path(f"/proc/{step}/stat")
    assert not stat.exists() or stat.read_text().split()[2] == "Z", "the step is still running"


FAKE_TOOLS = {
    # macOS tools tools/mem_guard.py reads, faked from files in the same folder
    "vm_stat": 'echo "Pages free:                               1600000."\n'
               'echo "Pages inactive:                           500000."\n'
               'echo "Swapouts:                                 $(cat "$(dirname "$0")/swapouts")."',
    "memory_pressure": 'echo "System-wide memory free percentage: $(cat "$(dirname "$0")/free")%"',
    "sysctl": 'case "$2" in hw.memsize) echo 38654705664;; vm.swapusage) echo "total = 0.00M  used = 0.00M";; esac',
}


def fake_mac_tools(tmp_path) -> Path:
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    for name, body in FAKE_TOOLS.items():
        (bin_ / name).write_text("#!/bin/sh\n" + body + "\n")
        (bin_ / name).chmod(0o755)
    (bin_ / "free").write_text("80")
    (bin_ / "swapouts").write_text("0")
    return bin_


def test_real_mem_guard_stops_its_step_on_an_early_sigint(tmp_path):
    """The stop signal lands while the guard is still setting up right after starting the step (made slow here: the
    second vm_stat call takes 1.5 s). The guard must stop the step itself, not die and leave it running."""
    bin_ = fake_mac_tools(tmp_path)
    (bin_ / "vm_stat").write_text(
        "#!/bin/sh\n"
        'n=$(cat "$(dirname "$0")/calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$(dirname "$0")/calls"\n'
        '[ "$n" -ge 1 ] && sleep 1.5\n' + FAKE_TOOLS["vm_stat"] + "\n")
    ticks = tmp_path / "ticks"
    child = tmp_path / "child.py"
    child.write_text(f"import time\nn = 0\nwhile True:\n    n += 1\n    open({str(ticks)!r}, 'w').write(str(n))\n"
                     f"    time.sleep(0.05)\n")
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}")
    proc = subprocess.Popen(P.guard_command([sys.executable, str(child)], TOOLS_GUARD, 36.0), env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):                                      # the step has started: the window is open
        if ticks.exists():
            break
        time.sleep(0.02)
    assert ticks.exists()
    proc.send_signal(signal.SIGINT)                           # not stop_guarded: the guard alone must handle it
    proc.wait(timeout=20)
    time.sleep(0.3)
    a = ticks.read_text()
    time.sleep(0.4)
    assert ticks.read_text() == a, "the guard exited and left its step running"


def test_real_mem_guard_budget_and_pause(tmp_path):
    """tools/mem_guard.py itself, with macOS's memory tools faked: the budget cap reaches the step as the MPS ratio,
    and the step is paused (SIGSTOP) while free memory is low and resumed after."""
    bin_ = fake_mac_tools(tmp_path)
    ticks = tmp_path / "ticks"
    child = tmp_path / "child.py"
    child.write_text(textwrap.dedent(f"""
        import os, time
        print("ratio", os.environ["PYTORCH_MPS_HIGH_WATERMARK_RATIO"], flush=True)
        n = 0
        while n < 400:
            n += 1
            open({str(ticks)!r} + ".tmp", "w").write(str(n))
            os.replace({str(ticks)!r} + ".tmp", {str(ticks)!r})  # atomic: the test never reads a half-written file
            time.sleep(0.05)
    """))
    cmd = P.guard_command([sys.executable, str(child)], TOOLS_GUARD, 36.0)
    cmd.insert(cmd.index("--"), "--interval")
    cmd.insert(cmd.index("--"), "0.2")
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stdout), daemon=True)
    reader.start()
    try:
        time.sleep(1.0)
        (bin_ / "free").write_text("5")                       # memory pressure: the guard must pause the step
        time.sleep(1.0)
        a = int(ticks.read_text())
        time.sleep(0.6)
        b = int(ticks.read_text())
        assert a == b, "the step kept running while memory was low"
        (bin_ / "free").write_text("90")
        time.sleep(1.0)
        assert int(ticks.read_text()) > b, "the step was not resumed"
    finally:
        proc.send_signal(signal.SIGINT)                       # how train_on_me.py stops a step
        proc.wait(timeout=10)
        reader.join(timeout=5)
    out = "".join(lines)
    assert "budget 16.0 GB" in out
    assert "ratio 0.59" in out                                # 16 GB of 0.75 x 36 GB
    assert "[mem_guard] paused" in out and "[mem_guard] resumed" in out
    assert [P.parse_line(ln)[0] for ln in out.splitlines() if P.parse_line(ln)] == ["paused", "resumed"]


def test_parse_line():
    assert P.parse_line("шаг 15/97  loss 1.2  lr 1e-4") == ("steps", 15, 97)
    assert P.parse_line("step 30/150 loss 0.9 12.00 s/step") == ("steps", 30, 150)
    assert P.parse_line("step 100 dev loss 1.1 best") is None
    assert P.parse_line("@@progress 3 40\n") == ("steps", 3, 40)
    assert P.parse_line("@@stage features") == ("stage", "features")
    assert P.parse_line("[mem_guard] paused: free 5%, swapped out 0 MB") == ("paused",)
    assert P.parse_line("[mem_guard] resumed: free 40%") == ("resumed",)
    assert P.parse_line("[mem_guard] budget 16.0 GB") is None


def test_progress_and_eta_ignore_guard_pauses():
    now = [0.0]
    pr = P.Progress([P.Stage("a", "А", 100), P.Stage("b", "Б", 300)], clock=lambda: now[0])
    pr.start("a")
    assert pr.fraction() == 0 and pr.eta() == pytest.approx(400)
    now[0] = 50
    pr.update(0.5)
    assert pr.fraction() == pytest.approx(50 / 400)
    assert pr.eta() == pytest.approx(50 + 300)
    pr.pause()
    now[0] = 1000                                             # a long guard pause
    assert pr.paused and pr.eta() == pytest.approx(350)
    pr.resume()
    now[0] = 1050
    pr.update(1.0)
    pr.start("b")                                             # "a" took 100 s of active time, as expected
    assert pr.done["a"] == pytest.approx(100)
    assert pr.fraction() == pytest.approx(0.25) and pr.eta() == pytest.approx(300)
    now[0] = 1110
    pr.update(0.1)                                            # b runs twice as fast as its prior
    assert pr.eta() == pytest.approx(60 / 0.1 * 0.9)
    pr.ensure(P.Stage("s", "С", 100), before="b")             # a stage the plan did not expect
    assert [s.name for s in pr.stages] == ["a", "s", "b"]
    pr.ensure(P.Stage("s", "С", 999), before="b")
    assert len(pr.stages) == 3
    pr.update(1.0)
    pr.finish()
    assert pr.fraction() == pytest.approx(400 / 500)


# --- the job, end to end, with stub model steps ----------------------------------------------------------------
STUB_GUARD = r'''
import json, os, sys
i = sys.argv.index("--")
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps({"guard": sys.argv[1:i], "cmd": sys.argv[i + 1:],
                        "app_job": os.environ.get("VELIKIY_MOGUCHIY_APP_JOB")}) + "\n")
print("[mem_guard] budget 16.0 GB (MPS ratio 0.59), swap used 0 MB", flush=True)
print("[mem_guard] paused: free 5%, swapped out 0 MB in last 1 checks", flush=True)
print("[mem_guard] resumed: free 40%", flush=True)
os.execv(sys.argv[i + 1], sys.argv[i + 1:])
'''

STUB_WORKER = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
opt = lambda k: args[args.index(k) + 1] if k in args else None
if args[0] == "prepare":
    job = json.loads(Path(opt("--job")).read_text())
    faces = Path(job["faces_dir"]); faces.mkdir(parents=True, exist_ok=True)
    noface = set(os.environ.get("STUB_NO_FACE", "").split(","))
    out = {}
    print("@@stage prepare", flush=True)
    for k, c in enumerate(job["clips"], 1):
        print(f"@@progress {k} {len(job['clips'])}", flush=True)
        if c["id"] in noface:
            out[c["id"]] = dict(face=None, frames=0, feats=None, skip="no face")
            continue
        f = faces / (c["hash"] + ".avi"); f.write_bytes(b"crop")
        out[c["id"]] = dict(face=str(f), frames=100, feats=None, skip=None)
    if job["feats_dir"]:
        print("@@stage features", flush=True)
        fd = Path(job["feats_dir"]); fd.mkdir(parents=True, exist_ok=True)
        for c in job["clips"]:
            if c["feats"] and out[c["id"]]["face"]:
                p = fd / (c["hash"] + ".npy"); p.write_bytes(b"feats"); out[c["id"]]["feats"] = str(p)
    if job["init_e2e"]:
        Path(job["init_e2e"]).write_bytes(b"init")
    Path(opt("--out")).write_text(json.dumps({"clips": out}))
else:
    clips = json.loads(Path(opt("--clips")).read_text())
    lora = opt("--lora") or ""
    wer = float(os.environ["STUB_NEW_WER"]) if "/work/" in lora else 0.74
    for k in range(len(clips)):
        print(f"@@progress {k + 1} {len(clips)}", flush=True)
    Path(opt("--out")).write_text(json.dumps(dict(wer=wer, cer=wer / 2, n=len(clips), lora=lora)))
'''

STUB_TRAIN = r'''
import os, sys, time
from pathlib import Path
args = sys.argv[1:]
opt = lambda k: args[args.index(k) + 1] if k in args else None
e2e = Path(sys.argv[0]).name == "train_e2e.py"
run = opt("--run")
if e2e and run == "full" and os.environ.get("STUB_R4_ONCE"):
    marker = Path(os.environ["STUB_R4_ONCE"])
    if not marker.exists():
        marker.write_text("x")
        print("[R4] no smoke run for this code/GPU/batch", flush=True)
        sys.exit("[R4] no smoke run")
n = 5
for k in range(1, n + 1):
    print((f"step {k}/{n} loss 1.0" if e2e else f"шаг {k}/{n}  loss 1.0"), flush=True)
    time.sleep(float(os.environ.get("STUB_SLEEP", "0")))
d = Path(opt("--ckpt-dir")) / run
d.mkdir(parents=True, exist_ok=True)
(d / "best.pt").write_bytes(f"new lora {run}".encode())
if e2e and not os.environ.get("STUB_NO_BEST"):
    (d / "best_venc.pth").write_bytes(b"new venc")
elif e2e:
    (d / "best.pt").unlink()
'''


@pytest.fixture
def job_env(tmp_path, monkeypatch):
    root = fake_root(tmp_path)
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    (stubs / "mem_guard.py").write_text(STUB_GUARD)
    (stubs / "train_on_me_worker.py").write_text(STUB_WORKER)
    (stubs / "train.py").write_text(STUB_TRAIN)
    (stubs / "train_e2e.py").write_text(STUB_TRAIN)
    monkeypatch.setattr(T, "MEM_GUARD", stubs / "mem_guard.py")
    monkeypatch.setattr(T, "WORKER", stubs / "train_on_me_worker.py")
    monkeypatch.setattr(T, "TRAIN_PY", stubs / "train.py")
    monkeypatch.setattr(T, "TRAIN_E2E_PY", stubs / "train_e2e.py")
    monkeypatch.setattr(P, "check_setup", lambda root=None: [])
    monkeypatch.setenv("STUB_LOG", str(tmp_path / "stub.log"))
    monkeypatch.setenv("STUB_NEW_WER", "0.70")
    monkeypatch.setenv(P.APP_JOB_ENV, P.APP_JOB)
    app, clips = tmp_path / "app", tmp_path / "app" / "lipdata" / "voiced"
    make_clips(clips, 60)
    (root / "clips").mkdir()
    (root / "clips" / "001.txt").write_text("фраза номер 7\n", encoding="utf8")  # a test phrase: never used

    def run(mode="light", **kw):
        job = T.Job(mode, app, clips, min_clips=kw.pop("min_clips", 20), lipread_root=root)
        rc = job.main()
        return rc, P.read_json(P.JobPaths(app).status), job

    def stub_calls():
        return [json.loads(ln) for ln in (tmp_path / "stub.log").read_text().splitlines()]

    return dict(root=root, app=app, clips=clips, run=run, calls=stub_calls, tmp=tmp_path)


def test_job_light_installs_a_better_model(job_env):
    rc, st, job = job_env["run"]("light")
    assert rc == 0, st
    assert st["state"] == "done" and st["progress"] == 1.0
    res = st["result"]
    assert res["installed"] and res["old_wer"] == 0.74 and res["new_wer"] == 0.70
    assert res["holdout"] == 6 and res["train_clips"] == 53          # 59 usable (one test phrase), 10% held out
    store = P.ModelStore(job_env["app"], job_env["root"])
    assert store.active() == {"current": res["model_id"], "previous": P.FACTORY}
    cur = store.current()
    assert cur.lora.read_bytes() == b"new lora light"
    assert cur.venc.read_bytes() == b"factory venc"                  # light mode keeps the installed front-end
    assert cur.info["old_wer"] == 0.74 and cur.info["mode"] == "light"

    calls = job_env["calls"]()
    steps = [Path(c["cmd"][1]).name + (":" + c["cmd"][2] if c["cmd"][1].endswith("worker.py") else "") for c in calls]
    assert steps == ["train_on_me_worker.py:prepare", "train.py", "train_on_me_worker.py:evaluate",
                     "train_on_me_worker.py:evaluate"]
    for c in calls:                                                   # every model step under the guard, capped
        assert c["guard"][c["guard"].index("--max-budget-gb") + 1] == f"{P.guard_budget_gb(P.total_ram_gb()):g}"
        assert c["app_job"] == P.APP_JOB
    train = calls[1]["cmd"]
    assert train[train.index("--init-lora") + 1].endswith("me1/best.pt")  # starts from the installed model
    assert train[train.index("--mix") + 1] == "voiced=1"
    rows = [json.loads(ln) for ln in (job.work / "manifest.jsonl").read_text().splitlines()]
    held = {c["id"] for c in json.loads((job.work / "holdout.json").read_text())}
    assert len(held) == 6 and not held & {r["id"].split("/")[1] for r in rows}   # the hold-out is never trained on
    assert all(r["text"] != "фраза номер 7" for r in rows)
    assert {r["split"] for r in rows} == {"train", "dev"}
    steps = P.light_steps(sum(r["split"] == "train" for r in rows))
    assert train[train.index("--max-steps") + 1] == str(steps)
    assert train[train.index("--warmup") + 1] == str(P.warmup_steps(steps))
    assert not (job.work / "checkpoints").exists()                    # cleaned up; the model was copied out


def test_job_keeps_the_old_model_when_the_new_one_is_not_better(job_env, monkeypatch):
    monkeypatch.setenv("STUB_NEW_WER", "0.80")
    rc, st, _ = job_env["run"]("light")
    assert rc == 0 and st["state"] == "done"
    assert not st["result"]["installed"] and "не лучше" in st["result"]["message"]
    assert P.ModelStore(job_env["app"], job_env["root"]).active() == {"current": None, "previous": None}


def test_job_full_runs_the_short_run_first_and_installs_the_front_end(job_env):
    rc, st, _ = job_env["run"]("full")
    assert rc == 0, st
    assert st["result"]["installed"]
    runs = [c["cmd"][c["cmd"].index("--run") + 1] for c in job_env["calls"]() if "--run" in c["cmd"]]
    assert runs == ["smoke", "full"]
    e2e = [c["cmd"] for c in job_env["calls"]() if "--run" in c["cmd"]][-1]
    assert e2e[e2e.index("--init") + 1].endswith("init_e2e.pt")
    assert int(e2e[e2e.index("--max-steps") + 1]) == P.FULL["min_steps"]   # 53 clips: the floor of the recipe
    assert e2e[e2e.index("--batch") + 1] == "2" and e2e[e2e.index("--accum") + 1] == "8"
    assert e2e[e2e.index("--warmup") + 1] == str(P.warmup_steps(P.FULL["min_steps"]))
    cur = P.ModelStore(job_env["app"], job_env["root"]).current()
    assert cur.venc.read_bytes() == b"new venc" and cur.info["mode"] == "full"


def test_job_full_retries_after_an_r4_refusal(job_env, monkeypatch):
    stamp = P.e2e_smoke_stamp(job_env["root"])
    stamp.parent.mkdir(parents=True)
    stamp.write_text("x")
    monkeypatch.setenv("STUB_R4_ONCE", str(job_env["tmp"] / "r4"))
    rc, st, _ = job_env["run"]("full")
    assert rc == 0, st
    runs = [c["cmd"][c["cmd"].index("--run") + 1] for c in job_env["calls"]() if "--run" in c["cmd"]]
    assert runs == ["full", "smoke", "full"]


def test_job_full_without_a_dev_improvement_installs_nothing(job_env, monkeypatch):
    monkeypatch.setenv("STUB_NO_BEST", "1")
    rc, st, _ = job_env["run"]("full")
    assert rc == 0 and not st["result"]["installed"] and "не улучшило" in st["result"]["message"]
    assert not [c for c in job_env["calls"]() if "evaluate" in c["cmd"]]


def test_job_refuses_too_few_clips_and_a_second_job(job_env):
    rc, st, _ = job_env["run"]("light", min_clips=100)
    assert rc == 1 and st["state"] == "failed" and "Мало клипов" in st["message"]
    paths = P.JobPaths(job_env["app"])
    with P.JobLock(paths.lock):
        assert P.job_running(paths) == os.getpid()
        before = paths.status.read_text()
        job = T.Job("light", job_env["app"], job_env["clips"], 20, job_env["root"])
        assert job.main() == 1
        assert paths.status.read_text() == before                       # the running job's status is untouched
    assert P.job_running(paths) is None


def test_job_without_faces_in_the_holdout_fails_cleanly(job_env, monkeypatch):
    clips = sorted(p.stem for p in job_env["clips"].glob("*.mp4"))
    monkeypatch.setenv("STUB_NO_FACE", ",".join(clips))
    rc, st, _ = job_env["run"]("light")
    assert rc == 1 and st["state"] == "failed" and "лицо" in st["message"].lower()


def test_cancel_stops_the_step_and_installs_nothing(job_env, monkeypatch):
    monkeypatch.setenv("STUB_SLEEP", "5")
    holder = {}

    def cancel_when_training():
        for _ in range(200):
            st = P.read_json(P.JobPaths(job_env["app"]).status) or {}
            if st.get("stage") == "train" and holder.get("job") and holder["job"].child:
                holder["job"].cancel()
                return
            time.sleep(0.05)

    orig = T.Job.__init__

    def init(self, *a, **kw):
        orig(self, *a, **kw)
        holder["job"] = self
    monkeypatch.setattr(T.Job, "__init__", init)
    threading.Thread(target=cancel_when_training, daemon=True).start()
    t0 = time.monotonic()
    rc, st, _ = job_env["run"]("light")
    assert rc == 1 and st["state"] == "cancelled" and "Модель не менялась" in st["message"]
    assert time.monotonic() - t0 < 20
    assert P.ModelStore(job_env["app"], job_env["root"]).active()["current"] is None


def test_stale_running_status_reads_as_failed(tmp_path):
    paths = P.JobPaths(tmp_path)
    P.write_json_atomic(paths.status, {"state": "running", "pid": 999999, "progress": 0.3})
    st = P.read_status(paths)
    assert st["state"] == "failed" and "прервалось" in st["message"]


# --- the CLI the app calls -------------------------------------------------------------------------------------
def cli(*args, env=None):
    r = subprocess.run([sys.executable, str(ROOT / "train_on_me.py"), *map(str, args)], capture_output=True,
                       text=True, env={**os.environ, **(env or {})})
    return r.returncode, json.loads(r.stdout) if r.stdout.strip() else None


def test_cli_scan_rollback_cancel(tmp_path):
    app = tmp_path / "app"
    make_clips(app / "lipdata" / "voiced", 120)
    rc, scan = cli("scan", "--app-data", app)
    assert rc == 0
    assert scan["usable"] == 120 and scan["total"] == 120 and scan["min_clips"] == P.MIN_CLIPS
    assert scan["holdout"] == 12 and scan["usable_minutes"] == pytest.approx(round(sum(2 + i % 5 for i in range(120)) / 60, 1))
    assert scan["estimates"]["light"] < scan["estimates"]["full"]
    assert scan["share"]["available"] is False and scan["rollback"]["available"] is False
    assert scan["job"] is None and scan["model"]["kind"] in ("factory", "base")

    rc, out = cli("rollback", "--app-data", app)
    assert rc == 1 and not out["ok"]
    rc, out = cli("cancel", "--app-data", app)
    assert rc == 1 and not out["ok"]

    s = P.ModelStore(app)
    s.install(*new_model(tmp_path, "a"), {"mode": "light"})
    rc, scan = cli("scan", "--app-data", app)
    assert scan["model"]["kind"] == "personal" and scan["rollback"]["available"]
    rc, out = cli("rollback", "--app-data", app)
    assert rc == 0 and out["ok"] and out["model"]["kind"] in ("factory", "base")


def test_estimates_for_the_pr():
    """The numbers quoted in the PR (M3 Max, estimates): light is minutes, full is hours."""
    for n in (100, 300):
        assert 5 * 60 < P.estimate_seconds("light", n) < 30 * 60
    assert 45 * 60 < P.estimate_seconds("full", 100) < 2 * 3600
    assert 1.5 * 3600 < P.estimate_seconds("full", 300) < 3 * 3600
