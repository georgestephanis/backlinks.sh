# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Three composable scripts that extract progressively more detail about backlinks to a domain using [Common Crawl](https://commoncrawl.org) data:

| Script | Data source | Output |
|---|---|---|
| `backlinks.sh` | Hyperlink graph (domain or host level) | Linking domains/hosts + link count |
| `cdx-pages.sh` | CDX index API | All crawled pages on linking domains (JSONL) |
| `link-details.sh` | WARC records (byte-range fetch) | Anchor text, `rel` attribute, crawl date per link |

## Usage

```bash
# Domain-level backlinks (downloads ~17 GB on first run)
./backlinks.sh example.com

# Host-level backlinks, subdomain granularity (downloads ~41 GB on first run)
./backlinks.sh --host example.com

# Show cache contents and disk usage
./backlinks.sh --cache-info

# Full pipeline: domain graph → CDX pages → link details
./backlinks.sh example.com          # run first to cache graph data
./cdx-pages.sh example.com | ./link-details.sh example.com

# Re-run link-details from cache (no re-fetching)
./link-details.sh example.com > links.tsv
```

- Default domain is `example.com` for all three scripts
- `CC_RELEASE` controls which Common Crawl snapshot is used (default: `cc-main-2026-jan-feb-mar`)
- See `--help` on any script for full options, env vars, and cache location

## Dependencies

- `duckdb` — required by `backlinks.sh` and `cdx-pages.sh` (`brew install duckdb`)
- `python3` — required by `cdx-pages.sh` and `link-details.sh` (parses JSON; standard on macOS)
- `curl`, `awk` — standard system tools

## Architecture

### Shared design

- **Cache root**: `~/.cache/cc-backlinks/<RELEASE>/`. All three scripts skip already-downloaded files.
- **Domain reversal**: Common Crawl stores names reversed (`roots.io` → `io.roots`). Done with `awk` before querying.
- **`CC_RELEASE` env var**: Controls which snapshot all three scripts use. Update to switch releases.

### `backlinks.sh`

**Domain mode (default):** Two single files, `domain-vertices.txt.gz` (~850 MB, columns: `id, rev_domain, num_hosts`) and `domain-edges.txt.gz` (~16 GB, columns: `from_id, to_id`), downloaded with `curl --progress-bar`. DuckDB reads them directly via `read_csv()` which decompresses gzip on the fly. Results sorted by `num_hosts` descending.

**Host mode (`--host`):** The host-level graph is sharded — the `.paths.gz` files are manifests (one S3 path per line) pointing to the actual data shards. `download_shards()` fetches the manifest, identifies missing shards, then downloads 8 at a time via `xargs -P8`. Each completed curl appends one byte to a temp file; a polling loop counts bytes every 200 ms to drive a live `[####----] N/total` bar. DuckDB queries all shards via a glob. The target CTE matches both the exact host (`rev_host = 'io.roots'`) and all subdomains (`rev_host LIKE 'io.roots.%'`).

### `cdx-pages.sh`

1. Fetches `https://index.commoncrawl.org/graphinfo.json` (cached as `.graphinfo.json`) and uses Python to extract the CDX crawl IDs for the current `CC_RELEASE`. Override with `CDX_CRAWL`.
2. Runs a DuckDB query against the already-cached domain graph to get the list of linking domains, sorted by `num_hosts` descending. Cached as `cdx/<domain>/.linking-domains`.
3. For each linking domain, queries each CDX crawl index (`https://index.commoncrawl.org/<CRAWL>-index`) using `matchType=domain` to cover all subdomains. Limited to `CDX_LIMIT` results per domain/crawl (default 500). Results cached as `cdx/<domain>/<source-domain>.jsonl`.
4. Streams JSONL to stdout. Fields: `url, timestamp, filename, offset, length, digest, status, mime-detected`.

### `link-details.sh`

Reads CDX JSONL from stdin (piped from `cdx-pages.sh`) or from the CDX cache when run interactively.

For each record, checks `link-details/<domain>/<digest>.tsv` before fetching. If not cached:
- Fetches the WARC record via HTTP byte-range (`Range: bytes=offset-(offset+length-1)`) against `https://data.commoncrawl.org/<filename>`. Common Crawl WARC files store records as individually gzip-compressed chunks, so the byte range returns a gzip stream.
- Pipes through a Python script (written to a temp file at startup, shared across all records) that decompresses, splits WARC/HTTP headers from body, and runs `html.parser` to find all `<a href>` tags whose `href` contains the target domain. Extracts anchor text and `rel` attribute.
- Writes per-page TSV to cache; cats to stdout.

Output columns: `source_url`, `crawl_date`, `target_url`, `anchor_text`, `rel`.
