# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Three composable Python scripts that extract progressively more detail about backlinks to a domain using [Common Crawl](https://commoncrawl.org) data:

| Script | Data source | Output |
|---|---|---|
| `backlinks.py` | Hyperlink graph (domain or host level) | Linking domains/hosts + link count |
| `cdx-pages.py` | CDX index API | All crawled pages on linking domains (JSONL) |
| `link-details.py` | WARC records (byte-range fetch) | Anchor text, `rel` attribute, crawl date per link |

Shared utilities (config loading, spinner, download, release check) live in `_cc_common.py`.

The original bash implementations (`backlinks.sh`, `cdx-pages.sh`, `link-details.sh`) remain in the repo and share the same cache structure.

## Usage

```bash
# Domain-level backlinks (downloads ~17 GB on first run)
./backlinks.py example.com

# Host-level backlinks, subdomain granularity (downloads ~41 GB on first run)
./backlinks.py --host example.com

# Show cache contents and disk usage
./backlinks.py --cache-info

# Full pipeline: domain graph → CDX pages → link details
./backlinks.py example.com          # run first to cache graph data
./cdx-pages.py example.com | ./link-details.py example.com

# Re-run link-details from cache (no re-fetching)
./link-details.py example.com > links.tsv
```

- Default domain is `example.com` for all three scripts
- `CC_RELEASE` controls which Common Crawl snapshot is used (default: `cc-main-2026-jan-feb-mar`)
- See `--help` on any script for full options, env vars, and cache location

## Dependencies

- `duckdb` Python package — `pip install duckdb` (used by `backlinks.py` and `cdx-pages.py`)
- `python3` — standard on macOS

## Architecture

### Shared design (`_cc_common.py`)

- **Cache root**: `~/.cache/cc-backlinks/<RELEASE>/`. All three scripts skip already-downloaded files.
- **Config file**: `~/.config/cc-backlinks/config` — stores `CC_RELEASE=...`. Written automatically when the user accepts a release update prompt.
- **Release precedence**: `CC_RELEASE` env var → config file → hardcoded default.
- **Release check**: On interactive runs, `backlinks.py` fetches `graphinfo.json` (cached 24h) and prompts if a newer release exists. Skipped when `CC_RELEASE` is set explicitly in the environment.
- **Domain reversal**: Common Crawl stores names reversed (`roots.io` → `io.roots`). Done in Python before querying.
- **Download with resume**: `download_file()` uses `Range: bytes=N-` to resume partial `.tmp` files.

### `backlinks.py`

**Domain mode (default):** Downloads `domain-vertices.txt.gz` (~850 MB, columns: `id, rev_domain, num_hosts`) and `domain-edges.txt.gz` (~16 GB, columns: `from_id, to_id`). DuckDB reads them directly via `read_csv()` which decompresses gzip on the fly. Results sorted by `num_hosts` descending, printed as a Unicode box table.

**Host mode (`--host`):** Fetches `.paths.gz` manifests, identifies missing shards, then downloads up to 8 at a time via `ThreadPoolExecutor`. A progress bar tracks completion. DuckDB queries all shards via a glob. The target CTE matches both the exact host (`rev_host = 'io.roots'`) and all subdomains (`rev_host LIKE 'io.roots.%'`).

### `cdx-pages.py`

1. Fetches `https://index.commoncrawl.org/graphinfo.json` (cached as `.graphinfo.json`) and extracts the CDX crawl IDs for the current `CC_RELEASE`. Override with `CDX_CRAWL`.
2. Runs a DuckDB query against the already-cached domain graph to get the list of linking domains, sorted by `num_hosts` descending. Cached as `cdx/<domain>/.linking-domains` (or `.linking-domains.minN` when `CDX_MIN_HOSTS` is set).
3. For each linking domain, queries each CDX crawl index (`https://index.commoncrawl.org/<CRAWL>-index`) using `matchType=domain` to cover all subdomains. Limited to `CDX_LIMIT` results per domain/crawl (default 500). Results cached as `cdx/<domain>/<source-domain>.jsonl`.
4. Streams JSONL to stdout. Fields: `url, timestamp, filename, offset, length, digest, status, mime-detected`.

### `link-details.py`

Reads CDX JSONL from stdin (piped from `cdx-pages.py`) or from the CDX cache when stdin is a terminal.

**Three-phase execution:**
1. **Parse**: All CDX JSON records are parsed in one pass to extract `(url, ts, filename, offset, length, digest)` tuples.
2. **Fetch**: WARC records are fetched in parallel via `ThreadPoolExecutor` (controlled by `CC_PARALLEL`, default 8). Each worker fetches one byte-range from `https://data.commoncrawl.org/<filename>`, decompresses the gzip chunk, splits WARC/HTTP headers from body, and runs `html.parser` to find all `<a href>` tags whose `href` contains the target domain. Results written to `link-details/<domain>/<digest>.tsv`.
3. **Emit**: Results are printed to stdout in original input order by reading from cache files.

Output columns: `source_url`, `crawl_date`, `target_url`, `anchor_text`, `rel`.
