"""Shared utilities for cc-backlinks tools."""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_RELEASE = "cc-main-2026-jan-feb-mar"
CC_BASE = "https://data.commoncrawl.org"
GRAPHINFO_URL = "https://index.commoncrawl.org/graphinfo.json"
CACHE_ROOT = Path.home() / ".cache" / "cc-backlinks"
CONFIG_FILE = Path.home() / ".config" / "cc-backlinks" / "config"


# ---------------------------------------------------------------------------
# Config / release
# ---------------------------------------------------------------------------

def load_config() -> dict[str, str]:
    cfg: dict[str, str] = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip()
    return cfg


def get_release() -> tuple[str, bool]:
    """Return (release_id, was_explicit).  Explicit = set in environment."""
    env = os.environ.get("CC_RELEASE")
    if env:
        return env, True
    cfg = load_config()
    if "CC_RELEASE" in cfg:
        return cfg["CC_RELEASE"], False
    return DEFAULT_RELEASE, False


def reverse_domain(domain: str) -> str:
    return ".".join(reversed(domain.split(".")))


# ---------------------------------------------------------------------------
# Terminal progress
# ---------------------------------------------------------------------------

def run_with_spinner(msg: str, func, *args, **kwargs):
    """Run func in a background thread; animate a spinner on stderr."""
    result: list = [None]
    error: list = [None]

    def target():
        try:
            result[0] = func(*args, **kwargs)
        except Exception as e:
            error[0] = e

    t = threading.Thread(target=target, daemon=True)
    t.start()
    frames = r"-\|/"
    i = 0
    while t.is_alive():
        sys.stderr.write(f"\r  {frames[i % 4]} {msg}")
        sys.stderr.flush()
        time.sleep(0.1)
        i += 1
    sys.stderr.write("\r" + " " * (len(msg) + 10) + "\r")
    sys.stderr.flush()
    t.join()
    if error[0]:
        raise error[0]
    return result[0]


def draw_progress(done: int, total: int, label: str = "") -> None:
    width = 40
    filled = int(done * width / total) if total else 0
    bar = "#" * filled + "-" * (width - filled)
    sys.stderr.write(f"\r  [{bar}] {done}/{total} {label}")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Disk utilities
# ---------------------------------------------------------------------------

def dir_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def fmt_size(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T", "P"):
        if abs(n) < 1024.0:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}P"


# ---------------------------------------------------------------------------
# HTTP download with resume + progress
# ---------------------------------------------------------------------------

def download_file(url: str, dest: Path) -> None:
    """Download url → dest, resuming from a .tmp partial if present."""
    if dest.exists():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(dest) + ".tmp")
    resume_pos = tmp.stat().st_size if tmp.exists() else 0

    req = urllib.request.Request(url, headers={"User-Agent": "cc-backlinks"})
    if resume_pos:
        req.add_header("Range", f"bytes={resume_pos}-")

    sys.stderr.write(f">> downloading {dest.name} ...\n")
    sys.stderr.flush()

    try:
        with urllib.request.urlopen(req) as resp:
            is_partial = resp.getcode() == 206
            written = resume_pos if is_partial else 0
            cl = resp.headers.get("Content-Length")
            total = (written + int(cl)) if (cl and is_partial) else (int(cl) if cl else 0)
            mode = "ab" if is_partial else "wb"
            with open(tmp, mode) as f:
                while True:
                    chunk = resp.read(1 << 20)  # 1 MB chunks
                    if not chunk:
                        break
                    f.write(chunk)
                    written += len(chunk)
                    if total:
                        pct = written * 100 // total
                        sys.stderr.write(
                            f"\r  {pct:3d}%  {fmt_size(written)} / {fmt_size(total)}"
                        )
                        sys.stderr.flush()
    except urllib.error.HTTPError as e:
        if e.code == 416:  # Range Not Satisfiable — file already complete
            tmp.rename(dest)
            sys.stderr.write("\n")
            return
        raise

    sys.stderr.write("\n")
    sys.stderr.flush()
    tmp.rename(dest)


# ---------------------------------------------------------------------------
# Release update check
# ---------------------------------------------------------------------------

def fetch_graphinfo() -> list:
    """Fetch graphinfo.json (cached 24 h at CACHE_ROOT/.graphinfo.json)."""
    path = CACHE_ROOT / ".graphinfo.json"
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    stale = not path.exists() or (time.time() - path.stat().st_mtime > 86400)
    if stale:
        try:
            req = urllib.request.Request(
                GRAPHINFO_URL, headers={"User-Agent": "cc-backlinks"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                path.write_bytes(resp.read())
        except Exception:
            pass
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text())
    except Exception:
        return []


def check_for_newer_release(release: str, was_explicit: bool) -> str:
    """Prompt interactively if a newer release exists; update config if accepted."""
    if was_explicit or not sys.stderr.isatty():
        return release
    data = fetch_graphinfo()
    if not data:
        return release
    latest = data[-1].get("id", "")
    if not latest or latest == release:
        return release
    sys.stderr.write(f"\nNewer Common Crawl release available: {latest}\n")
    sys.stderr.write(f"Current release: {release}\n")
    sys.stderr.write("Update config to use newer release? [Y/n] ")
    sys.stderr.flush()
    try:
        with open("/dev/tty") as tty:
            answer = tty.readline().strip().lower()
    except Exception:
        return release
    if answer in ("", "y", "yes"):
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(f"CC_RELEASE={latest}\n")
        sys.stderr.write(f"Switched to {latest}.\n")
        return latest
    return release
