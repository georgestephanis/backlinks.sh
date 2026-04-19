# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`backlinks.sh` is a single Bash script that finds all inbound backlinks to a domain by querying the [Common Crawl hyperlink graph](https://commoncrawl.org/web-graphs). It downloads gzipped vertex/edge data, caches it locally, and uses DuckDB for SQL queries.

## Usage

```bash
./backlinks.sh [--host] [domain]
./backlinks.sh --cache-info
./backlinks.sh --help
```

- Default domain is `example.com`
- `CC_RELEASE` env var controls which Common Crawl snapshot is used (default: `cc-main-2026-jan-feb-mar`)
- `--cache-info` prints disk usage per release and per dataset (domain vertices/edges, host shard counts), plus instructions for clearing or switching releases
- See `--help` output for full usage, examples, and cache location

## Dependencies

- `duckdb` — must be installed (`brew install duckdb`); script checks and errors if missing
- `curl`, `awk` — standard system tools

## Architecture

### Shared design

- **Cache**: `~/.cache/cc-backlinks/<RELEASE>/`. Both `download()` and `download_shards()` skip files that already exist.
- **Domain reversal**: Common Crawl stores names reversed (`roots.io` → `io.roots`). Done with `awk` before querying.
- **DuckDB query**: A heredoc SQL query reads gzipped CSVs directly via `read_csv()` (DuckDB decompresses on the fly), finds the target's ID(s) in vertices, then joins inbound edges back to vertices to resolve names.
- **`CC_RELEASE` env var**: Controls which Common Crawl snapshot is used. Update this when a newer release is available.

### Domain mode (default)

Two single files downloaded via `download()`, which uses `curl --progress-bar` for a clean in-line progress bar:
- `domain-vertices.txt.gz` (~850 MB, columns: `id, rev_domain, num_hosts`)
- `domain-edges.txt.gz` (~16 GB, columns: `from_id, to_id`)

Results sorted by `num_hosts` descending.

### Host mode (`--host`)

The host-level graph is sharded. The `.paths.gz` files from Common Crawl are manifests (one S3 path per line) pointing to the actual data shards, not the data itself:
- Vertices: 48 shards (~2 GB total), columns: `id, rev_host` (no host count column)
- Edges: 192 shards (~39 GB total), columns: `from_id, to_id`

`download_shards()` fetches the manifest, identifies missing shards, then downloads up to 8 in parallel via `xargs -P8`. Each completed curl appends one byte to a temp file; a polling loop counts those bytes every 200 ms to render a live `[####----] N/total` progress bar. DuckDB queries all cached shards via a glob (`vertices/*.gz`, `edges/*.gz`).

The target CTE matches both the exact host (`rev_host = 'io.roots'`) and all subdomains (`rev_host LIKE 'io.roots.%'`).
