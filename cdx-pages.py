#!/usr/bin/env python3
"""
Query the Common Crawl CDX index for crawled HTML pages on every domain
that links to a target. Requires the domain-level graph to be cached first
(run backlinks.py). Streams JSONL to stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _cc_common import (
    CACHE_ROOT, CONFIG_FILE, DEFAULT_RELEASE,
    fetch_graphinfo, get_release, reverse_domain, run_with_spinner,
)

try:
    import duckdb
except ImportError:
    sys.exit("error: duckdb not installed. Run: pip install duckdb")


# ---------------------------------------------------------------------------
# CDX crawl ID resolution
# ---------------------------------------------------------------------------

def resolve_crawl_ids(release: str, graphinfo_path: Path) -> list[str]:
    """Return CDX crawl IDs for release from graphinfo.json."""
    override = os.environ.get("CDX_CRAWL")
    if override:
        return [l.strip() for l in override.splitlines() if l.strip()]

    if not graphinfo_path.exists():
        sys.stderr.write(">> fetching release index ...\n")
        sys.stderr.flush()
        req = urllib.request.Request(
            "https://index.commoncrawl.org/graphinfo.json",
            headers={"User-Agent": "cc-backlinks"},
        )
        with urllib.request.urlopen(req) as resp:
            graphinfo_path.write_bytes(resp.read())

    data = json.loads(graphinfo_path.read_text())
    for entry in data:
        if entry.get("id") == release:
            return entry.get("crawls", [])

    sys.exit(
        f"error: release '{release}' not found in graphinfo.json\n"
        "       Set CDX_CRAWL=CC-MAIN-YYYY-WW to specify a crawl manually."
    )


# ---------------------------------------------------------------------------
# Linking domains (from cached domain graph via DuckDB)
# ---------------------------------------------------------------------------

def get_linking_domains(
    cache: Path, cdx_cache: Path, domain: str, min_hosts: int
) -> list[str]:
    cache_file = cdx_cache / (
        f".linking-domains.min{min_hosts}" if min_hosts > 0 else ".linking-domains"
    )
    if cache_file.exists():
        return [l for l in cache_file.read_text().splitlines() if l.strip()]

    vertices = str(cache / "domain-vertices.txt.gz")
    edges = str(cache / "domain-edges.txt.gz")
    rev = reverse_domain(domain)

    sql = f"""
    WITH vertices AS (
      SELECT * FROM read_csv('{vertices}', delim='\\t', header=false,
        columns={{'id':'BIGINT','rev_domain':'VARCHAR','num_hosts':'BIGINT'}})
    ),
    target AS (
      SELECT id FROM vertices WHERE rev_domain = '{rev}'
    ),
    inbound AS (
      SELECT from_id FROM read_csv('{edges}', delim='\\t', header=false,
        columns={{'from_id':'BIGINT','to_id':'BIGINT'}})
      WHERE to_id = (SELECT id FROM target)
    )
    SELECT array_to_string(list_reverse(string_split(v.rev_domain, '.')), '.') AS domain
    FROM inbound i
    JOIN vertices v ON v.id = i.from_id
    WHERE v.num_hosts >= {min_hosts}
    ORDER BY v.num_hosts DESC, domain
    """

    sys.stderr.write(f">> finding domains linking to {domain} ...\n")
    sys.stderr.flush()

    def run() -> list[str]:
        conn = duckdb.connect()
        conn.execute("SET enable_progress_bar = false")
        rows = conn.execute(sql).fetchall()
        conn.close()
        return [row[0] for row in rows]

    domains = run_with_spinner(
        "scanning edges (this takes several minutes on first run)...", run
    )
    sys.stderr.write(f"   found {len(domains)} linking domain(s)\n")
    sys.stderr.flush()

    cache_file.write_text("\n".join(domains) + ("\n" if domains else ""))
    return domains


# ---------------------------------------------------------------------------
# CDX API query
# ---------------------------------------------------------------------------

def query_cdx(
    crawl_id: str,
    domain: str,
    limit: int,
    timeout: int,
    debug: bool,
) -> list[str]:
    """Query one CDX crawl index for HTML pages on domain. Returns JSON lines."""
    params = [
        ("url", domain),
        ("matchType", "domain"),
        ("output", "json"),
        ("fl", "url,timestamp,filename,offset,length,digest,status,mime-detected"),
        ("filter", "status:200"),
        ("filter", "mime-detected:text/html"),
        ("limit", str(limit)),
    ]
    url = f"https://index.commoncrawl.org/{crawl_id}-index?{urllib.parse.urlencode(params)}"

    if debug:
        sys.stderr.write(f"    GET {url}\n")
        sys.stderr.flush()

    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cc-backlinks"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            lines = resp.read().decode("utf-8", errors="replace").splitlines()
            elapsed = time.monotonic() - t0
            results = [l for l in lines if l.strip()]
            if debug:
                sys.stderr.write(f"    OK ({elapsed:.1f}s), {len(results)} results\n")
            return results
    except urllib.error.HTTPError as e:
        elapsed = time.monotonic() - t0
        if e.code in (400, 404):
            if debug:
                sys.stderr.write(f"    no results ({elapsed:.1f}s)\n")
            return []
        sys.stderr.write(
            f"\r  WARNING: CDX request failed (HTTP {e.code}, {elapsed:.1f}s)"
            f" for {domain} [{crawl_id}]{' ' * 20}\n"
        )
        return []
    except Exception as e:
        elapsed = time.monotonic() - t0
        sys.stderr.write(
            f"\r  WARNING: CDX request failed ({elapsed:.1f}s)"
            f" for {domain} [{crawl_id}]: {e}{' ' * 20}\n"
        )
        return []


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="cdx-pages.py",
        description=(
            "Query the Common Crawl CDX index for HTML pages on all domains\n"
            "that link to the target. Requires backlinks.py to have been run first.\n"
            "Output is JSONL, one record per line. Pipe into link-details.py."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Environment:\n"
            f"  CC_RELEASE       Common Crawl release (overrides {CONFIG_FILE})\n"
            f"                   Default: {DEFAULT_RELEASE}\n"
            "  CDX_CRAWL        Override CDX crawl IDs (newline-separated)\n"
            "  CDX_LIMIT        Max pages per domain per crawl (default: 500)\n"
            "  CDX_MAX_DOMAINS  Query only top N linking domains (default: all)\n"
            "  CDX_MIN_HOSTS    Skip domains with fewer than N hosts (default: 0)\n"
            "  CDX_TIMEOUT      Seconds per CDX request (default: 60)\n"
            "  CDX_DEBUG        Set to 1 for verbose request logging\n\n"
            "Cache:\n"
            f"  {CACHE_ROOT}/<release>/cdx/<domain>/"
        ),
    )
    parser.add_argument("domain", nargs="?", default="example.com",
                        help="Target domain (default: example.com)")
    parser.add_argument("--clear-cdx", action="store_true",
                        help="Delete cached CDX results for this domain before querying")
    args = parser.parse_args()

    release, _ = get_release()
    limit = int(os.environ.get("CDX_LIMIT", 500))
    max_domains = int(os.environ.get("CDX_MAX_DOMAINS", 0))
    min_hosts = int(os.environ.get("CDX_MIN_HOSTS", 0))
    timeout = int(os.environ.get("CDX_TIMEOUT", 60))
    debug = bool(os.environ.get("CDX_DEBUG"))

    domain = args.domain
    cache = CACHE_ROOT / release
    cdx_cache = cache / "cdx" / domain
    graphinfo = cache / ".graphinfo.json"

    if args.clear_cdx and cdx_cache.exists():
        sys.stderr.write(f">> clearing CDX cache for {domain} ...\n")
        for f in cdx_cache.glob("*.jsonl"):
            f.unlink()

    cdx_cache.mkdir(parents=True, exist_ok=True)

    if not (cache / "domain-vertices.txt.gz").exists() or \
       not (cache / "domain-edges.txt.gz").exists():
        sys.exit(f"error: domain graph not cached. Run: ./backlinks.py {domain}")

    crawl_ids = resolve_crawl_ids(release, graphinfo)
    sys.stderr.write(f">> crawl(s): {' '.join(crawl_ids)}\n")
    sys.stderr.flush()

    domains = get_linking_domains(cache, cdx_cache, domain, min_hosts)
    total = min(len(domains), max_domains) if max_domains > 0 else len(domains)
    crawl_total = len(crawl_ids)
    sys.stderr.write(f">> querying CDX for pages on {total} linking domain(s) ...\n")
    sys.stderr.flush()

    for idx, src_domain in enumerate(domains[:total], 1):
        page_cache = cdx_cache / f"{src_domain}.jsonl"

        if page_cache.exists():
            count = sum(1 for _ in page_cache.open())
            sys.stderr.write(
                f"  [{idx}/{total}] {src_domain:<50}  {count:4d} pages (cached)\n"
            )
            sys.stderr.flush()
            sys.stdout.write(page_cache.read_text())
            sys.stdout.flush()
            continue

        lines: list[str] = []
        for n, crawl_id in enumerate(crawl_ids, 1):
            if debug:
                sys.stderr.write(
                    f"\n  [{idx}/{total}] {src_domain}  crawl {n}/{crawl_total} ({crawl_id})\n"
                )
            else:
                sys.stderr.write(
                    f"\r  [{idx}/{total}] {src_domain:<40}  "
                    f"querying crawl {n}/{crawl_total} ({crawl_id}){' ' * 10}"
                )
            sys.stderr.flush()
            lines.extend(query_cdx(crawl_id, src_domain, limit, timeout, debug))

        page_cache.write_text("\n".join(lines) + ("\n" if lines else ""))
        sys.stderr.write(
            f"\r  [{idx}/{total}] {src_domain:<50}  {len(lines):4d} pages\n"
        )
        sys.stderr.flush()
        if lines:
            print("\n".join(lines))


if __name__ == "__main__":
    main()
