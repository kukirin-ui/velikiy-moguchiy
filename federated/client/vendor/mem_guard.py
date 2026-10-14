#!/usr/bin/env python3
"""Run a heavy ML command with a memory budget that keeps macOS out of swap.

Usage: mem_guard.py [--reserve-gb 6] [--max-budget-gb N] [--min-free-pct 15] [--max-swap-growth-mb 256] -- <cmd...>

Before start the GPU budget is set from currently available memory minus the reserve
(PYTORCH_MPS_HIGH_WATERMARK_RATIO is relative to the device's recommended working set).
While running, the child process group is paused (SIGSTOP) when swap grows or free memory
drops below the threshold, and resumed (SIGCONT) once memory is back.
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

PAGE = 16384


def vm_pages():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    pages = {}
    for line in out.splitlines():
        m = re.match(r"(.+?):\s+(\d+)\.", line)
        if m:
            pages[m.group(1)] = int(m.group(2))
    return pages


def available_gb():
    p = vm_pages()
    avail = p.get("Pages free", 0) + p.get("Pages inactive", 0) + p.get("Pages speculative", 0) + p.get("Pages purgeable", 0)
    return avail * PAGE / 2**30


def free_pct():
    out = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout
    m = re.search(r"free percentage:\s*(\d+)%", out)
    return int(m.group(1)) if m else 100


def swapouts_mb():
    return vm_pages().get("Swapouts", 0) * PAGE / 2**20


def swap_used_mb():
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    m = re.search(r"used = ([\d.]+)M", out)
    return float(m.group(1)) if m else 0.0


def total_gb():
    return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) / 2**30


def signal_group(pid, sig):
    # the group may already be gone between poll() and the signal
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reserve-gb", type=float, default=6.0)
    ap.add_argument("--min-free-pct", type=int, default=15)
    ap.add_argument("--max-swap-growth-mb", type=float, default=256, help="swap-out MB within 30 s that pauses the job")
    ap.add_argument("--max-budget-gb", type=float, default=None,
                    help="hard cap; set it when several guarded jobs share the Mac, each would otherwise claim all free memory")
    ap.add_argument("--interval", type=float, default=3)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        ap.error("command required after --")

    budget_gb = max(2.0, available_gb() - a.reserve_gb)
    if a.max_budget_gb:
        budget_gb = min(budget_gb, a.max_budget_gb)
    # MPS caps allocations at ratio × recommendedMaxWorkingSetSize (~75% of RAM on Apple Silicon).
    ratio = min(0.95, budget_gb / (total_gb() * 0.75))
    env = dict(os.environ)
    env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = f"{ratio:.2f}"
    env["PYTORCH_MPS_LOW_WATERMARK_RATIO"] = f"{min(ratio, 0.25) * 0.7:.2f}"
    print(f"[mem_guard] budget {budget_gb:.1f} GB (MPS ratio {ratio:.2f}), swap used {swap_used_mb():.0f} MB", flush=True)

    child = subprocess.Popen(cmd, env=env, start_new_session=True)
    paused = False
    # Swap *used* is a bad signal: macOS keeps stale pages there and swaps out a
    # SIGSTOPped child too, so pausing on it flaps forever. Pause on active
    # swap-out traffic while free memory is low-ish, resume when both calm down.
    window = []
    last_out = swapouts_mb()
    try:
        while child.poll() is None:
            time.sleep(a.interval)
            out = swapouts_mb()
            window = (window + [out - last_out])[-max(1, round(30 / a.interval)):]
            last_out = out
            swapping = sum(window)
            fp = free_pct()
            pressured = fp < a.min_free_pct or swapping > a.max_swap_growth_mb
            if pressured and not paused:
                signal_group(child.pid, signal.SIGSTOP)
                paused = True
                print(f"[mem_guard] paused: free {fp}%, swapped out {swapping:.0f} MB in last {len(window)} checks", flush=True)
            elif paused and fp >= a.min_free_pct + 10 and window[-1] < 64:
                signal_group(child.pid, signal.SIGCONT)
                paused = False
                window = []
                print(f"[mem_guard] resumed: free {fp}%", flush=True)
    except KeyboardInterrupt:
        signal_group(child.pid, signal.SIGCONT)
        signal_group(child.pid, signal.SIGTERM)
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
