#!/usr/bin/env bash
# Live progress view for an in-progress (or finished) DATA_LAKE → GCS upload.
#
# Usage:
#   ./watch_gcs_upload_progress.sh
#   ./watch_gcs_upload_progress.sh --interval 5
#   watch -n 5 ./watch_gcs_upload_progress.sh --once
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/data_lake_report/gcs_upload"
INTERVAL=5
ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--log-dir DIR] [--interval SEC] [--once]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

python3 - "$LOG_DIR" "$INTERVAL" "$ONCE" <<'PY'
import os
import re
import sys
import time
from pathlib import Path

log_dir = Path(sys.argv[1])
interval = float(sys.argv[2])
once = sys.argv[3] == "1"
jobs_dir = log_dir / "jobs"
state_file = log_dir / ".progress_watch_state"

COPY_RE = re.compile(rb"Copying file://(/[^\s]+) to gs://")
THROUGHPUT_RE = re.compile(rb"Average throughput:\s*([0-9.]+)\s*([kKmMgG]?i?B)/s")
END_RE = re.compile(rb"^end=.*duration_s=(\d+)\s+exit=(\d+)", re.M)
SRC_RE = re.compile(rb"^src=(.+)$", re.M)

# Cache: src_dir -> total file count (avoids re-walking every refresh)
_total_cache: dict[str, int] = {}


def count_files(src_dir: str) -> int:
    src_dir = src_dir.rstrip("/")
    if src_dir in _total_cache:
        return _total_cache[src_dir]
    total = 0
    try:
        for root, _dirs, files in os.walk(src_dir):
            total += len(files)
    except OSError:
        total = 0
    _total_cache[src_dir] = total
    return total


def progress_bar(done: int, total: int, width: int = 20) -> str:
    if total <= 0:
        return "[" + ("?" * width) + "]"
    frac = min(max(done / total, 0.0), 1.0)
    filled = int(round(frac * width))
    return "[" + ("#" * filled) + ("-" * (width - filled)) + f"] {100.0 * frac:5.1f}%"


def human_bytes(n: float) -> str:
    for u, d in (("B", 1), ("KiB", 1024), ("MiB", 1024**2), ("GiB", 1024**3), ("TiB", 1024**4)):
        if u == "TiB" or n < d * 1024:
            return f"{n/d:.1f}{u}" if u != "B" else f"{n:.0f}B"
    return f"{n:.0f}B"


def human_rate(bps: float) -> str:
    return f"{human_bytes(bps)}/s"


def parse_throughput(unit: bytes, val: float) -> float:
    u = unit.decode()
    prefix = u[0].lower()
    if "i" in u.lower():
        mult = {"k": 1024, "m": 1024**2, "g": 1024**3}.get(prefix, 1)
    else:
        mult = {"k": 1000, "m": 1000**2, "g": 1000**3}.get(prefix, 1)
    return val * mult


def count_nonempty_lines(path: Path | None) -> int:
    if not path or not path.exists():
        return 0
    n = 0
    with path.open("rb") as f:
        for line in f:
            if line.strip():
                n += 1
    return n


def latest(glob_pat: str) -> Path | None:
    files = sorted(log_dir.glob(glob_pat), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def pid_alive() -> bool:
    pid_file = log_dir / "upload.pid"
    if not pid_file.exists():
        return False
    try:
        pid = int(pid_file.read_text().strip().splitlines()[0])
        os.kill(pid, 0)
        return True
    except (ValueError, IndexError, OSError):
        return False


def quick_finished_meta(path: Path) -> dict | None:
    """Only read the tail of finished job logs."""
    try:
        size = path.stat().st_size
        with path.open("rb") as f:
            if size > 16384:
                f.seek(-16384, os.SEEK_END)
            tail = f.read()
    except OSError:
        return None
    if b"\nend=" not in tail and not tail.startswith(b"end="):
        # might still be active, or end marker not flushed
        if END_RE.search(tail) is None:
            return None
    m_end = None
    for m in END_RE.finditer(tail):
        m_end = m
    if not m_end:
        return None
    tp = None
    m_tp = None
    for m in THROUGHPUT_RE.finditer(tail):
        m_tp = m
    if m_tp:
        tp = parse_throughput(m_tp.group(2), float(m_tp.group(1)))
    copies = tail.count(b"Copying file://")
    # rough: also count in whole file cheaply via one pass only if small
    return {
        "name": path.stem.replace("__", "/"),
        "path": path,
        "done": True,
        "exit": int(m_end.group(2)),
        "duration": int(m_end.group(1)),
        "copies": copies,  # from tail only — ok for display of recent
        "throughput": tp,
        "mtime": path.stat().st_mtime,
        "active": False,
        "bytes_seen": 0,
        "last_file": "",
    }


def parse_active(path: Path) -> dict:
    """Full-ish parse for active jobs only (usually few)."""
    info = {
        "name": path.stem.replace("__", "/"),
        "path": path,
        "done": False,
        "exit": None,
        "duration": None,
        "copies": 0,
        "total_files": 0,
        "bytes_seen": 0,
        "last_file": "",
        "last_file_path": "",
        "last_file_size": 0,
        "src_dir": "",
        "throughput": None,
        "mtime": path.stat().st_mtime,
        "active": True,
    }
    try:
        data = path.read_bytes()
    except OSError:
        return info
    if END_RE.search(data):
        info["active"] = False
        info["done"] = True
        m = list(END_RE.finditer(data))[-1]
        info["duration"] = int(m.group(1))
        info["exit"] = int(m.group(2))
    m_src = SRC_RE.search(data)
    if m_src:
        info["src_dir"] = m_src.group(1).decode("utf-8", "replace").strip().rstrip("/")
        info["total_files"] = count_files(info["src_dir"])
    for m in COPY_RE.finditer(data):
        info["copies"] += 1
        src = m.group(1).decode("utf-8", "replace")
        info["last_file"] = os.path.basename(src)
        info["last_file_path"] = src
        try:
            sz = os.path.getsize(src)
            info["last_file_size"] = sz
            info["bytes_seen"] += sz
        except OSError:
            info["last_file_size"] = 0
    m_tp = None
    for m in THROUGHPUT_RE.finditer(data):
        m_tp = m
    if m_tp:
        info["throughput"] = parse_throughput(m_tp.group(2), float(m_tp.group(1)))
    return info


def load_state():
    if not state_file.exists():
        return {}, {}, time.time()
    try:
        raw = state_file.read_text(encoding="utf-8")
        copies, bytes_, t0 = {}, {}, time.time()
        for line in raw.splitlines():
            kind, key, val = line.split("\t", 2)
            if kind == "t":
                t0 = float(val)
            elif kind == "c":
                copies[key] = int(val)
            elif kind == "b":
                bytes_[key] = int(val)
        return copies, bytes_, t0
    except Exception:
        return {}, {}, time.time()


def save_state(copies, bytes_, t0):
    try:
        with state_file.open("w", encoding="utf-8") as f:
            f.write(f"t\t_\t{t0}\n")
            for k, v in copies.items():
                f.write(f"c\t{k}\t{v}\n")
            for k, v in bytes_.items():
                f.write(f"b\t{k}\t{v}\n")
    except OSError:
        pass


def render():
    ok_f = latest("success_*.tsv")
    fail_f = latest("failed_*.tsv")
    ready_f = latest("ready_*.tsv")
    main_f = latest("upload_*.log")
    ok_n = count_nonempty_lines(ok_f)
    fail_n = count_nonempty_lines(fail_f)
    ready_n = count_nonempty_lines(ready_f)
    done_n = ok_n + fail_n
    pct = (100.0 * done_n / ready_n) if ready_n else 0.0
    alive = pid_alive()

    job_files = list(jobs_dir.glob("*.log")) if jobs_dir.is_dir() else []
    # Prefer recently touched logs for active detection.
    job_files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    active = []
    recent_done = []
    # Scan newest ~40 logs for actives; collect a few finished from newest.
    for p in job_files[:60]:
        # cheap: check if end marker in last 4k
        try:
            size = p.stat().st_size
            with p.open("rb") as f:
                if size > 4096:
                    f.seek(-4096, os.SEEK_END)
                tail = f.read()
        except OSError:
            continue
        has_end = END_RE.search(tail) is not None
        if not has_end:
            active.append(parse_active(p))
            if len(active) >= 8:
                # still collect recent done from remaining? break after enough
                pass
        else:
            meta = quick_finished_meta(p)
            if meta and len(recent_done) < 5:
                recent_done.append(meta)
        if len(active) >= 8 and len(recent_done) >= 5:
            break

    # If we didn't fill recent_done, scan a bit more finished only
    if len(recent_done) < 5:
        for p in job_files[:80]:
            if any(j["path"] == p for j in active + recent_done):
                continue
            meta = quick_finished_meta(p)
            if meta:
                recent_done.append(meta)
            if len(recent_done) >= 5:
                break

    prev_copies, prev_bytes, prev_t = load_state()
    now = time.time()
    dt = max(now - prev_t, 0.001)
    inst_files = 0
    inst_bytes = 0
    new_copies, new_bytes = {}, {}
    for j in active:
        key = str(j["path"])
        pc = prev_copies.get(key, j["copies"])
        pb = prev_bytes.get(key, j["bytes_seen"])
        inst_files += max(0, j["copies"] - pc)
        inst_bytes += max(0, j["bytes_seen"] - pb)
        new_copies[key] = j["copies"]
        new_bytes[key] = j["bytes_seen"]
    save_state(new_copies, new_bytes, now)

    file_rate = inst_files / dt
    byte_rate = inst_bytes / dt
    finished_tp = [j["throughput"] for j in recent_done if j.get("throughput")]
    avg_tp = sum(finished_tp) / len(finished_tp) if finished_tp else None

    lines = []
    lines.append("=" * 72)
    lines.append(f"DATA_LAKE upload progress  |  runner={'RUNNING' if alive else 'stopped'}")
    if main_f:
        lines.append(f"log: {main_f.name}")
    lines.append(
        f"folders: {done_n}/{ready_n} ({pct:.1f}%)  ok={ok_n}  fail={fail_n}  active={len(active)}"
    )
    rate_bits = [f"~{file_rate:.1f} files/s (active delta)"]
    if byte_rate > 0:
        rate_bits.append(f"~{human_rate(byte_rate)} est.")
    if avg_tp:
        rate_bits.append(f"recent avg {human_rate(avg_tp)}")
    lines.append("speed: " + " | ".join(rate_bits))
    lines.append("-" * 72)

    if not active:
        lines.append("  (no active folder uploads right now)")
    now = time.time()
    for j in active:
        last = j["last_file"] or "-"
        if len(last) > 42:
            last = "…" + last[-41:]
        total = j.get("total_files") or 0
        copied = j["copies"]
        last_sz = j.get("last_file_size") or 0
        idle_s = max(0, int(now - j["mtime"]))
        if total > 0:
            bar = progress_bar(copied, total)
            files_s = f"{copied}/{total} files {bar}"
        else:
            files_s = f"{copied}/? files"

        # gcloud logs "Copying" when a transfer *starts*, so at ~100% the last
        # (often large) file may still be uploading, or rsync is finalizing.
        near_done = total > 0 and copied >= total
        status = ""
        if near_done:
            if last_sz >= 50 * 1024 * 1024:  # >= 50 MiB
                status = f"      ... finishing: last file still uploading ({human_bytes(last_sz)}; log idle {idle_s}s)"
            elif idle_s >= 5:
                status = f"      ... finishing: rsync wrapping up (log idle {idle_s}s)"
            else:
                status = "      ... finishing last transfer / checksum"
        elif last_sz >= 50 * 1024 * 1024 and idle_s >= 3:
            status = f"      ... large file in flight ({human_bytes(last_sz)}; {idle_s}s since last log line)"

        lines.append(f"  ▶ {j['name']}")
        lines.append(
            f"      {files_s}  ~{human_bytes(j['bytes_seen'])} started  last={last}"
        )
        if status:
            lines.append(status)

    if recent_done:
        lines.append("-" * 72)
        lines.append("recently finished:")
        for j in recent_done[:5]:
            status = "OK" if j["exit"] == 0 else f"FAIL(rc={j['exit']})"
            tp = human_rate(j["throughput"]) if j["throughput"] else "n/a"
            dur = f"{j['duration']}s" if j["duration"] is not None else "?"
            lines.append(f"  {status:10s} {j['name']}  {dur}  avg={tp}")
    lines.append("=" * 72)
    return "\n".join(lines)


while True:
    if not once and sys.stdout.isatty():
        print("\033[2J\033[H", end="")
    print(render(), flush=True)
    if once:
        break
    time.sleep(interval)
PY
