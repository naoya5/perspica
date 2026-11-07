#!/usr/bin/env python3
"""Measure an app's CPU as a percentage over a short window.

`ps -o %cpu` is an average over the process's whole lifetime, so it is useless
for "what is it doing right now". This samples the cumulative CPU time
(`ps -o cputime`) and divides the delta by the wall-clock delta, which is what
the prototype's measure.py did.
"""
import subprocess
import sys
import time


def cputime_seconds(pid: int) -> float | None:
    out = subprocess.run(
        ["ps", "-o", "cputime=", "-p", str(pid)],
        capture_output=True, text=True
    ).stdout.strip()
    if not out:
        return None
    # Formats: MM:SS, MM:SS.ss, HH:MM:SS, D-HH:MM:SS
    days = 0
    if "-" in out:
        day_part, out = out.split("-", 1)
        days = int(day_part)
    parts = out.split(":")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def measure(pid: int, seconds: float) -> tuple[float, float]:
    start_wall = time.monotonic()
    start_cpu = cputime_seconds(pid)
    if start_cpu is None:
        raise SystemExit(f"pid {pid} not found")
    time.sleep(seconds)
    end_cpu = cputime_seconds(pid)
    end_wall = time.monotonic()
    if end_cpu is None:
        raise SystemExit(f"pid {pid} disappeared")
    cpu = (end_cpu - start_cpu) / (end_wall - start_wall) * 100
    return cpu, end_wall - start_wall


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure_cpu.py <pid> <seconds>")
    pid = int(sys.argv[1])
    seconds = float(sys.argv[2])
    cpu, window = measure(pid, seconds)
    print(f"pid={pid} window={window:.1f}s cpu={cpu:.2f}%")


if __name__ == "__main__":
    main()
