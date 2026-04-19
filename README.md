# backlinks.sh

> Built atop the original Common Crawl backlink work by [@retlehs](https://github.com/retlehs) — see the [original gist](https://gist.github.com/retlehs/cf0ac6c74476e766fba2f14076fff501).

Find backlinks to any domain using [Common Crawl](https://commoncrawl.org/web-graphs) data — no third-party API keys, no rate limits, no monthly fees. Three composable scripts cover progressively more detail:

| Script | What it answers | Data downloaded |
|---|---|---|
| `backlinks.sh` | Which domains (or subdomains) link to mine? | ~17 GB (domain) or ~41 GB (host) |
| `cdx-pages.sh` | Which specific pages on those domains were crawled? | None — CDX is a free API |
| `link-details.sh` | What anchor text and `rel` attributes do those links use? | A few KB per page (WARC byte-range) |

Each script caches its results, so re-runs and follow-up queries against the same domain are instant.

## Requirements

- [`duckdb`](https://duckdb.org) — `brew install duckdb` (used by `backlinks.sh` and `cdx-pages.sh`)
- `python3` — standard on macOS (used by `cdx-pages.sh` and `link-details.sh`)
- `curl`, `awk` — standard system tools

## Quick start

```bash
# Clone and make executable
git clone https://github.com/georgestephanis/backlinks.sh
cd backlinks.sh
chmod +x backlinks.sh cdx-pages.sh link-details.sh

# Find all domains linking to yours (~17 GB download on first run)
./backlinks.sh yourdomain.com
```

## Scripts

### `backlinks.sh` — domain and host-level backlinks

Queries the Common Crawl [hyperlink graph](https://commoncrawl.org/web-graphs) to find every domain that links to yours. Results include a host count (how many distinct hosts on that domain link to you), sorted highest first.

```bash
./backlinks.sh yourdomain.com
```

```
┌──────────────────────┬───────────┐
│    linking_domain    │ num_hosts │
│       varchar        │   int64   │
├──────────────────────┼───────────┤
│ github.com           │     18432 │
│ reddit.com           │      9105 │
│ stackoverflow.com    │      4821 │
│ …                    │       … │
└──────────────────────┴───────────┘
```

**Host-level mode** (`--host`) shows individual subdomains instead of just top-level domains — useful for distinguishing `blog.example.com` from `docs.example.com`. This dataset is sharded (~41 GB) and downloads in parallel.

```bash
./backlinks.sh --host yourdomain.com
```

```
┌───────────────────────────────┐
│         linking_host          │
│            varchar            │
├───────────────────────────────┤
│ answers.github.com            │
│ api.reddit.com                │
│ old.reddit.com                │
│ …                             │
└───────────────────────────────┘
```

**Cache info** shows what's downloaded, how much space it uses, and how to clear or upgrade to a newer release:

```bash
./backlinks.sh --cache-info
```

```
Cache: /Users/you/.cache/cc-backlinks
Total: 17.2 GB

  cc-main-2026-jan-feb-mar  [active]
    domain/vertices   851 MB
    domain/edges       16 GB
    host/vertices     not downloaded
    host/edges        not downloaded
    subtotal          16.8 GB

To clear a release:
  rm -rf /Users/you/.cache/cc-backlinks/cc-main-2026-jan-feb-mar
…
```

**Options**

| Flag | Description |
|---|---|
| `--host` | Use the host-level graph (subdomain granularity) |
| `--cache-info` | Show local cache contents and disk usage |
| `-h`, `--help` | Show usage |

**Environment variables**

| Variable | Default | Description |
|---|---|---|
| `CC_RELEASE` | `cc-main-2026-jan-feb-mar` | Which Common Crawl snapshot to use. Browse available releases at [commoncrawl.org/web-graphs](https://commoncrawl.org/web-graphs). |

---

### `cdx-pages.sh` — find crawled pages on linking domains

Takes the linking domains discovered by `backlinks.sh` and queries the [Common Crawl CDX index](https://index.commoncrawl.org) for every HTML page it has crawled on those domains. No large downloads — it's a web API.

**Run `backlinks.sh` first** to cache the domain graph, then:

```bash
./cdx-pages.sh yourdomain.com
```

Output is JSONL (one record per line) streamed to stdout. Each record contains the page URL, crawl timestamp, and the exact WARC file location needed to fetch its content:

```json
{"url":"https://blog.example.com/post","timestamp":"20260115102345","filename":"crawl-data/CC-MAIN-2026-04/.../CC-MAIN-...warc.gz","offset":"12345678","length":"45210","digest":"sha1:ABC123...","status":"200","mime-detected":"text/html"}
```

Results are cached per source domain, so piping into `link-details.sh` twice doesn't re-query the CDX.

**Options**

| Variable | Default | Description |
|---|---|---|
| `CC_RELEASE` | `cc-main-2026-jan-feb-mar` | Release to use (must match `backlinks.sh`) |
| `CDX_CRAWL` | *(derived from release)* | Override which CDX crawl(s) to query, newline-separated |
| `CDX_LIMIT` | `500` | Max pages to fetch per domain per crawl |
| `CDX_MAX_DOMAINS` | *(all)* | Only query the top N linking domains by host count |

---

### `link-details.sh` — extract anchor text and rel attributes

Fetches individual WARC records for each CDX page and parses the HTML to extract every link pointing to your domain — including anchor text, `rel` attributes (`nofollow`, `sponsored`, `ugc`), and the crawl date.

Each WARC record is fetched with an HTTP byte-range request (a few KB), not a bulk download.

**Pipe from `cdx-pages.sh`:**

```bash
./cdx-pages.sh yourdomain.com | ./link-details.sh yourdomain.com
```

**Or run standalone** against the cached CDX data (no re-fetching of CDX results):

```bash
./link-details.sh yourdomain.com
```

Output is tab-separated with a header row:

```
source_url	crawl_date	target_url	anchor_text	rel
https://blog.example.com/post	2026-01-15	https://yourdomain.com/page	check out this tool	
https://old.reddit.com/r/foo	2026-02-03	https://yourdomain.com/	yourdomain.com	nofollow
…
```

Redirect to a file for further processing:

```bash
./link-details.sh yourdomain.com > links.tsv
```

---

## Full pipeline

```bash
# Step 1 — cache the domain graph (one-time, ~17 GB download)
./backlinks.sh yourdomain.com

# Step 2 — find crawled pages on linking domains (CDX API, no download)
./cdx-pages.sh yourdomain.com

# Step 3 — extract link details from WARC records
./link-details.sh yourdomain.com > links.tsv

# Or run steps 2 and 3 together as a pipeline
./cdx-pages.sh yourdomain.com | ./link-details.sh yourdomain.com > links.tsv
```

After the first run, all three scripts read from cache. Re-querying a different domain only downloads what's new.

## Switching to a newer Common Crawl release

Common Crawl publishes new graph releases a few times per year. To use a newer one, set `CC_RELEASE` before running any script:

```bash
CC_RELEASE=cc-main-2026-apr-may-jun ./backlinks.sh yourdomain.com
```

Each release has its own cache directory, so switching doesn't invalidate existing data. Find available releases at [commoncrawl.org/web-graphs](https://commoncrawl.org/web-graphs).

To free disk space from an old release:

```bash
./backlinks.sh --cache-info       # see what's cached and how large
rm -rf ~/.cache/cc-backlinks/cc-main-2026-jan-feb-mar
```
