#!/usr/bin/env python3
"""
Fetch WARC records for CDX pages and extract links to the target domain,
including anchor text and rel attributes.

Reads CDX JSONL from stdin (piped from cdx-pages.py), or from the local
CDX cache when stdin is a terminal. Output is TSV.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _cc_common import CACHE_ROOT, CONFIG_FILE, DEFAULT_RELEASE, get_release


CC_BASE = "https://data.commoncrawl.org"


# ---------------------------------------------------------------------------
# WARC parsing
# ---------------------------------------------------------------------------

class _LinkParser(HTMLParser):
    def __init__(self, target_domain: str) -> None:
        super().__init__()
        self.target = target_domain
        self.links: list[tuple[str, str, str]] = []
        self._in_a = False
        self._cur: dict = {}

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag == "a":
            d = dict(attrs)
            href = d.get("href", "")
            if self.target in href:
                self._in_a = True
                self._cur = {"href": href, "rel": d.get("rel", ""), "text": []}

    def handle_data(self, data: str) -> None:
        if self._in_a:
            self._cur["text"].append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._in_a:
            text = re.sub(r"\s+", " ", " ".join(self._cur["text"])).strip()
            self.links.append((self._cur["href"], text, self._cur["rel"]))
            self._in_a = False


def parse_warc(
    raw: bytes, target_domain: str, source_url: str, crawl_ts: str
) -> list[list[str]]:
    try:
        content = gzip.decompress(raw).decode("utf-8", errors="replace")
    except Exception:
        content = raw.decode("utf-8", errors="replace")

    sep = "\r\n\r\n" if "\r\n\r\n" in content else "\n\n"
    parts = content.split(sep, 2)
    if len(parts) < 3:
        return []
    body = parts[2]

    parser = _LinkParser(target_domain)
    try:
        parser.feed(body)
    except Exception:
        pass

    date = (
        f"{crawl_ts[:4]}-{crawl_ts[4:6]}-{crawl_ts[6:8]}"
        if len(crawl_ts) >= 8 else crawl_ts
    )
    return [
        [
            source_url,
            date,
            href,
            text.replace("\t", " ").replace("\n", " "),
            rel,
        ]
        for href, text, rel in parser.links
    ]


# ---------------------------------------------------------------------------
# WARC fetch + cache
# ---------------------------------------------------------------------------

def fetch_warc(
    url: str,
    ts: str,
    filename: str,
    offset: str,
    length: str,
    digest: str,
    target_domain: str,
    details_cache: Path,
) -> None:
    cache_file = details_cache / f"{digest}.tsv"
    if cache_file.exists():
        return
    end = int(offset) + int(length) - 1
    req = urllib.request.Request(
        f"{CC_BASE}/{filename}",
        headers={"Range": f"bytes={offset}-{end}", "User-Agent": "cc-backlinks"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except Exception:
        cache_file.touch()  # empty sentinel so we don't retry
        return

    rows = parse_warc(raw, target_domain, url, ts)
    tmp = details_cache / f"{digest}.tsv.tmp"
    with open(tmp, "w") as f:
        for row in rows:
            f.write("\t".join(row) + "\n")
    tmp.rename(cache_file)


# ---------------------------------------------------------------------------
# CDX record parsing
# ---------------------------------------------------------------------------

def parse_cdx_line(line: str) -> tuple[str, str, str, str, str, str] | None:
    """Parse a CDX JSON line → (url, ts, filename, offset, length, digest)."""
    try:
        d = json.loads(line)
        url = d.get("url", "")
        ts = d.get("timestamp", "")
        fn = d.get("filename", "")
        offset = str(d.get("offset", "0"))
        length = str(d.get("length", "0"))
        raw_digest = d.get("digest", "") or hashlib.sha1(url.encode()).hexdigest()
        digest = raw_digest.replace("sha1:", "").replace("/", "_")
        if fn:
            return url, ts, fn, offset, length, digest
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="link-details.py",
        description=(
            "Fetch WARC records for CDX pages and extract links to the target domain.\n"
            "Reads CDX JSONL from stdin or from the local CDX cache.\n"
            "Output is TSV: source_url, crawl_date, target_url, anchor_text, rel"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Environment:\n"
            f"  CC_RELEASE    Common Crawl release (overrides {CONFIG_FILE})\n"
            f"                Default: {DEFAULT_RELEASE}\n"
            "  CC_PARALLEL   Parallel WARC fetches (default: 8)\n\n"
            "Cache:\n"
            f"  {CACHE_ROOT}/<release>/link-details/<domain>/"
        ),
    )
    parser.add_argument("domain", nargs="?", default="example.com",
                        help="Target domain (default: example.com)")
    args = parser.parse_args()

    release, _ = get_release()
    parallel = int(os.environ.get("CC_PARALLEL", 8))
    domain = args.domain

    cache = CACHE_ROOT / release
    cdx_cache = cache / "cdx" / domain
    details_cache = cache / "link-details" / domain
    details_cache.mkdir(parents=True, exist_ok=True)

    # --- Collect input ---
    if sys.stdin.isatty():
        if not cdx_cache.is_dir():
            sys.exit(f"error: no CDX cache for {domain}. Run cdx-pages.py first.")
        raw_lines: list[str] = []
        for jsonl_file in sorted(cdx_cache.glob("*.jsonl")):
            raw_lines.extend(jsonl_file.read_text().splitlines())
    else:
        raw_lines = sys.stdin.read().splitlines()

    # --- Phase 1: parse all CDX records ---
    records = [r for line in raw_lines if line.strip() and (r := parse_cdx_line(line))]
    total = len(records)
    sys.stderr.write(f">> fetching {total} pages ({parallel} parallel)...\n")
    sys.stderr.flush()

    # --- Phase 2: parallel WARC fetches ---
    with ThreadPoolExecutor(max_workers=parallel) as pool:
        futures = {
            pool.submit(fetch_warc, *rec, domain, details_cache): rec
            for rec in records
        }
        done = 0
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as e:
                rec = futures[future]
                sys.stderr.write(f"\n  WARNING: fetch failed for {rec[0]}: {e}\n")
            done += 1
            sys.stderr.write(f"\r  {done}/{total} fetched")
            sys.stderr.flush()
    sys.stderr.write("\n")
    sys.stderr.flush()

    # --- Phase 3: emit in input order ---
    print("source_url\tcrawl_date\ttarget_url\tanchor_text\trel")
    found = 0
    for _url, _ts, _fn, _off, _len, digest in records:
        cache_file = details_cache / f"{digest}.tsv"
        if cache_file.exists() and cache_file.stat().st_size > 0:
            text = cache_file.read_text()
            sys.stdout.write(text)
            found += len(text.splitlines())

    sys.stderr.write(f"\n  {total} pages, {found} links found\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
