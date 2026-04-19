#!/usr/bin/env python3
"""
Find all domains or hosts that link to a given domain using the
Common Crawl hyperlink graph.
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _cc_common import (
    CC_BASE, CACHE_ROOT, CONFIG_FILE, DEFAULT_RELEASE,
    check_for_newer_release, dir_size, download_file, draw_progress,
    fetch_graphinfo, fmt_size, get_release, reverse_domain, run_with_spinner,
)

try:
    import duckdb
except ImportError:
    sys.exit("error: duckdb not installed. Run: pip install duckdb")


# ---------------------------------------------------------------------------
# Table formatting
# ---------------------------------------------------------------------------

def print_table(columns: list[str], rows: list[tuple]) -> None:
    if not rows:
        print("(no results)")
        return
    str_rows = [[str(v) for v in row] for row in rows]
    widths = [
        max(len(c), max((len(r[i]) for r in str_rows), default=0))
        for i, c in enumerate(columns)
    ]

    def hline(l, m, r, fill="─"):
        return l + m.join(fill * (w + 2) for w in widths) + r

    def row_line(vals: list[str]) -> str:
        return "│" + "│".join(f" {v:<{w}} " for v, w in zip(vals, widths)) + "│"

    print(hline("┌", "┬", "┐"))
    print(row_line(columns))
    print(hline("├", "┼", "┤"))
    for row in str_rows:
        print(row_line(row))
    print(hline("└", "┴", "┘"))


# ---------------------------------------------------------------------------
# Cache info
# ---------------------------------------------------------------------------

def cache_info(release: str) -> None:
    base = CACHE_ROOT
    print(f"Cache: {base}")
    if not base.exists():
        print("Total: (no cache found)\n")
    else:
        print(f"Total: {fmt_size(dir_size(base))}\n")
        found_any = False
        for rel_dir in sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")):
            found_any = True
            tag = "  [active]" if rel_dir.name == release else ""
            print(f"  {rel_dir.name}{tag}")

            dv = rel_dir / "domain-vertices.txt.gz"
            de = rel_dir / "domain-edges.txt.gz"
            print(f"    domain/vertices   {fmt_size(dv.stat().st_size) if dv.exists() else 'not downloaded'}")
            print(f"    domain/edges      {fmt_size(de.stat().st_size) if de.exists() else 'not downloaded'}")

            vm = rel_dir / "host" / ".vertices-manifest"
            em = rel_dir / "host" / ".edges-manifest"
            hv = rel_dir / "host" / "vertices"
            he = rel_dir / "host" / "edges"
            v_total = len(vm.read_text().splitlines()) if vm.exists() else 48
            e_total = len(em.read_text().splitlines()) if em.exists() else 192
            v_count = len(list(hv.glob("*.gz"))) if hv.exists() else 0
            e_count = len(list(he.glob("*.gz"))) if he.exists() else 0

            if v_count:
                print(f"    host/vertices     {v_count}/{v_total} shards, {fmt_size(dir_size(hv))}")
            else:
                print("    host/vertices     not downloaded")
            if e_count:
                print(f"    host/edges        {e_count}/{e_total} shards, {fmt_size(dir_size(he))}")
            else:
                print("    host/edges        not downloaded")
            print(f"    subtotal          {fmt_size(dir_size(rel_dir))}\n")

        if not found_any:
            print("  (no releases cached)\n")

    print(f"To clear one release:  rm -rf {base}/<release>\n")
    print(f"To clear everything:   rm -rf {base}\n")
    print(f"Release config: {CONFIG_FILE}\n")
    print("To switch releases, edit the config or run backlinks.py (it checks for updates).")
    print(f"To override once: CC_RELEASE=cc-main-YYYY-mon-mon-mon ./backlinks.py [domain]\n")
    print("Browse available releases: https://commoncrawl.org/web-graphs")


# ---------------------------------------------------------------------------
# Shard download (host mode)
# ---------------------------------------------------------------------------

import gzip as _gzip  # stdlib gzip, aliased to avoid conflict with variable names


def download_shards(manifest_url: str, dest_dir: Path, manifest_path: Path) -> None:
    if not manifest_path.exists():
        sys.stderr.write(f">> fetching shard manifest: {Path(manifest_url).name} ...\n")
        sys.stderr.flush()
        req = urllib.request.Request(manifest_url, headers={"User-Agent": "cc-backlinks"})
        with urllib.request.urlopen(req) as resp:
            manifest_path.write_text(_gzip.decompress(resp.read()).decode())

    paths = [l.strip() for l in manifest_path.read_text().splitlines() if l.strip()]
    pending = [
        (f"{CC_BASE}/{p}", dest_dir / Path(p).name)
        for p in paths
        if not (dest_dir / Path(p).name).exists()
    ]
    if not pending:
        return

    label = f"{dest_dir.name} shards"
    total = len(pending)
    sys.stderr.write(f">> downloading {total} {label} (8 parallel) ...\n")
    sys.stderr.flush()
    draw_progress(0, total, label)

    completed = 0

    def fetch_shard(url: str, dest: Path) -> None:
        tmp = Path(str(dest) + ".tmp")
        req = urllib.request.Request(url, headers={"User-Agent": "cc-backlinks"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            tmp.write_bytes(resp.read())
        tmp.rename(dest)

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(fetch_shard, url, dest): dest for url, dest in pending}
        for future in as_completed(futures):
            dest = futures[future]
            try:
                future.result()
            except Exception as e:
                sys.stderr.write(f"\n  WARNING: failed to download {dest.name}: {e}\n")
            completed += 1
            draw_progress(completed, total, label)

    sys.stderr.write("\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# DuckDB queries
# ---------------------------------------------------------------------------

def query_domain(cache: Path, domain: str) -> tuple[list[str], list[tuple]]:
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
    SELECT
      array_to_string(list_reverse(string_split(v.rev_domain, '.')), '.') AS linking_domain,
      v.num_hosts
    FROM inbound i
    JOIN vertices v ON v.id = i.from_id
    ORDER BY v.num_hosts DESC, linking_domain
    """

    def run():
        conn = duckdb.connect()
        conn.execute("SET enable_progress_bar = false")
        rel = conn.execute(sql)
        cols = [d[0] for d in rel.description]
        rows = rel.fetchall()
        conn.close()
        return cols, rows

    return run()


def query_host(cache: Path, domain: str) -> tuple[list[str], list[tuple]]:
    host_cache = cache / "host"
    rev = reverse_domain(domain)
    vertices_glob = str(host_cache / "vertices" / "*.gz")
    edges_glob = str(host_cache / "edges" / "*.gz")

    sql = f"""
    WITH vertices AS (
      SELECT * FROM read_csv('{vertices_glob}', delim='\\t', header=false,
        columns={{'id':'BIGINT','rev_host':'VARCHAR'}}, ignore_errors=true)
    ),
    target AS (
      SELECT id FROM vertices
      WHERE rev_host = '{rev}' OR rev_host LIKE '{rev}.%'
    ),
    inbound AS (
      SELECT from_id FROM read_csv('{edges_glob}', delim='\\t', header=false,
        columns={{'from_id':'BIGINT','to_id':'BIGINT'}}, ignore_errors=true)
      WHERE to_id IN (SELECT id FROM target)
    )
    SELECT
      array_to_string(list_reverse(string_split(v.rev_host, '.')), '.') AS linking_host
    FROM inbound i
    JOIN vertices v ON v.id = i.from_id
    ORDER BY linking_host
    """

    def run():
        conn = duckdb.connect()
        conn.execute("SET enable_progress_bar = false")
        rel = conn.execute(sql)
        cols = [d[0] for d in rel.description]
        rows = rel.fetchall()
        conn.close()
        return cols, rows

    return run()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="backlinks.py",
        description="Find domains/hosts linking to a target using Common Crawl graph data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Environment:\n"
            f"  CC_RELEASE   Common Crawl release (overrides {CONFIG_FILE})\n"
            f"               Default: {DEFAULT_RELEASE}\n\n"
            "Cache:\n"
            f"  {CACHE_ROOT}/<release>/\n\n"
            "Data:  https://commoncrawl.org/web-graphs\n"
            "Needs: pip install duckdb"
        ),
    )
    parser.add_argument("domain", nargs="?", default="example.com",
                        help="Target domain (default: example.com)")
    parser.add_argument("--host", action="store_true",
                        help="Use host-level graph (shows subdomains, ~41 GB download)")
    parser.add_argument("--cache-info", action="store_true",
                        help="Show cache contents and exit")
    args = parser.parse_args()

    release, was_explicit = get_release()
    release = check_for_newer_release(release, was_explicit)

    if args.cache_info:
        cache_info(release)
        return

    domain = args.domain
    cache = CACHE_ROOT / release
    cache.mkdir(parents=True, exist_ok=True)
    base_url = f"https://data.commoncrawl.org/projects/hyperlinkgraph/{release}"

    if not args.host:
        vertices = cache / "domain-vertices.txt.gz"
        edges = cache / "domain-edges.txt.gz"
        download_file(f"{base_url}/domain/{release}-domain-vertices.txt.gz", vertices)
        download_file(f"{base_url}/domain/{release}-domain-edges.txt.gz", edges)

        rev = reverse_domain(domain)
        sys.stderr.write(f">> querying backlinks to {domain} (reversed: {rev}) ...\n")
        sys.stderr.write(">> first run scans ~16 GB of gzipped edges; expect several minutes\n")
        sys.stderr.flush()

        cols, rows = run_with_spinner("scanning...", query_domain, cache, domain)
        print_table(cols, rows)

    else:
        host_cache = cache / "host"
        host_cache.mkdir(parents=True, exist_ok=True)
        (host_cache / "vertices").mkdir(exist_ok=True)
        (host_cache / "edges").mkdir(exist_ok=True)

        download_shards(
            f"{base_url}/host/{release}-host-vertices.paths.gz",
            host_cache / "vertices",
            host_cache / ".vertices-manifest",
        )
        download_shards(
            f"{base_url}/host/{release}-host-edges.paths.gz",
            host_cache / "edges",
            host_cache / ".edges-manifest",
        )

        sys.stderr.write(f">> querying host-level backlinks to {domain} ...\n")
        sys.stderr.write(">> first run scans ~39 GB of gzipped edge shards; expect many minutes\n")
        sys.stderr.flush()

        cols, rows = run_with_spinner("scanning...", query_host, cache, domain)
        print_table(cols, rows)


if __name__ == "__main__":
    main()
