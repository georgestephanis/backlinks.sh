#!/usr/bin/env bash
set -euo pipefail

# Fetches individual WARC records for CDX pages and extracts all links
# pointing to the target domain, including anchor text and rel attributes.
#
# Reads CDX JSONL from stdin (piped from cdx-pages.sh) or, when stdin
# is a terminal, reads from the cached CDX data for the domain.
#
# Output is TSV: source_url, crawl_date, target_url, anchor_text, rel

DOMAIN="example.com"

usage() {
  cat <<'EOF'
Usage: cdx-pages.sh [domain] | link-details.sh [domain]
   or: link-details.sh [domain]   (reads from CDX cache)

Fetches WARC records for each CDX page via HTTP byte-range request
and extracts all links pointing to the target domain, along with
anchor text and rel attributes (nofollow, sponsored, ugc, etc.).

Reads CDX JSONL from stdin (output of cdx-pages.sh), or from the
local CDX cache when no pipe is present.

Output is tab-separated: source_url, crawl_date, target_url, anchor_text, rel

Arguments:
  domain         Target domain (default: example.com)

Options:
  -h, --help     Show this help message and exit

Environment:
  CC_RELEASE     Common Crawl release (overrides ~/.config/cc-backlinks/config)
                 Default: cc-main-2026-jan-feb-mar

Cache:
  ~/.cache/cc-backlinks/<release>/link-details/<domain>/

Examples:
  ./cdx-pages.sh example.com | ./link-details.sh example.com
  ./link-details.sh example.com        # re-run from cache without re-fetching
  ./link-details.sh example.com > links.tsv
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $arg" >&2; exit 1 ;;
    *) DOMAIN="$arg" ;;
  esac
done

_CC_CONFIG="${HOME}/.config/cc-backlinks/config"
[[ -z "${CC_RELEASE:-}" && -f "$_CC_CONFIG" ]] && source "$_CC_CONFIG"
RELEASE="${CC_RELEASE:-cc-main-2026-jan-feb-mar}"
CACHE="${HOME}/.cache/cc-backlinks/${RELEASE}"
CDX_CACHE="${CACHE}/cdx/${DOMAIN}"
DETAILS_CACHE="${CACHE}/link-details/${DOMAIN}"
CC_BASE="https://data.commoncrawl.org"

mkdir -p "$DETAILS_CACHE"

# --- Write the Python WARC parser to a temp file ---
# Written once, reused for every record. Parses gzip-compressed WARC
# records and extracts links pointing to the target domain.

PARSER=$(mktemp /tmp/cc-link-parser-XXXXXX.py)
trap "rm -f '$PARSER'" EXIT

cat > "$PARSER" << 'PYEOF'
import sys, gzip, re
from html.parser import HTMLParser

target_domain = sys.argv[1]
source_url    = sys.argv[2]
crawl_ts      = sys.argv[3]

# WARC records fetched from Common Crawl are individually gzip-compressed.
raw = sys.stdin.buffer.read()
try:
    content = gzip.decompress(raw).decode('utf-8', errors='replace')
except Exception:
    content = raw.decode('utf-8', errors='replace')

# WARC record structure: WARC headers / HTTP headers / body,
# each section separated by a blank line (\r\n\r\n or \n\n).
sep   = '\r\n\r\n' if '\r\n\r\n' in content else '\n\n'
parts = content.split(sep, 2)
if len(parts) < 3:
    sys.exit(0)
body = parts[2]

class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.in_a  = False
        self.cur   = {}

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            d    = dict(attrs)
            href = d.get('href', '')
            if target_domain in href:
                self.in_a = True
                self.cur  = {'href': href, 'rel': d.get('rel', ''), 'text': []}

    def handle_data(self, data):
        if self.in_a:
            self.cur['text'].append(data)

    def handle_endtag(self, tag):
        if tag == 'a' and self.in_a:
            text = re.sub(r'\s+', ' ', ' '.join(self.cur['text'])).strip()
            self.links.append((self.cur['href'], text, self.cur['rel']))
            self.in_a = False

p = LinkParser()
try:
    p.feed(body)
except Exception:
    pass

date = f"{crawl_ts[:4]}-{crawl_ts[4:6]}-{crawl_ts[6:8]}" if len(crawl_ts) >= 8 else crawl_ts
for href, text, rel in p.links:
    cols = [source_url, date, href,
            text.replace('\t', ' ').replace('\n', ' '),
            rel]
    print('\t'.join(cols))
PYEOF

# --- Process a single CDX record ---

process_record() {
  local record="$1"

  # Extract all needed fields from the CDX JSON in one python3 call.
  local fields
  fields=$(python3 -c '
import json, sys, hashlib
d      = json.loads(sys.argv[1])
url    = d.get("url", "")
ts     = d.get("timestamp", "")
fn     = d.get("filename", "")
offset = d.get("offset", "0")
length = d.get("length", "0")
# Use the CDX content digest as cache key; fall back to a hash of the URL.
digest = d.get("digest", "") or hashlib.sha1(url.encode()).hexdigest()
# Sanitise digest for use as a filename (CDX digests are "sha1:HASH" or just "HASH").
digest = digest.replace("sha1:", "").replace("/", "_")
print("\t".join([url, ts, fn, str(offset), str(length), digest]))
' "$record") || return 0

  local url ts filename offset length digest
  IFS=$'\t' read -r url ts filename offset length digest <<<"$fields"

  [[ -z "$filename" ]] && return 0

  local cache_file="${DETAILS_CACHE}/${digest}.tsv"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  # Show the URL being fetched before the network call — stderr passes
  # through even inside a $() subshell, so this updates the terminal live.
  printf '\r  [%d pages, %d links] fetching %-60s' "$DONE" "$FOUND" "$url" >&2

  # WARC files on S3 contain individually gzip-compressed records.
  # The CDX offset+length pinpoint the exact compressed record bytes.
  local end=$(( offset + length - 1 ))
  curl -sf -H "Range: bytes=${offset}-${end}" \
    "${CC_BASE}/${filename}" \
    | python3 "$PARSER" "$DOMAIN" "$url" "$ts" \
    > "$cache_file" 2>/dev/null || true

  cat "$cache_file"
}

# --- Determine input source ---
# If stdin is a terminal (no pipe), read from the local CDX cache instead.

if [[ -t 0 ]]; then
  if [[ ! -d "$CDX_CACHE" ]]; then
    echo "error: no CDX cache found for ${DOMAIN}. Run cdx-pages.sh first." >&2
    exit 1
  fi
  INPUT="cache"
else
  INPUT="stdin"
fi

# --- Main loop ---

printf 'source_url\tcrawl_date\ttarget_url\tanchor_text\trel\n'

DONE=0
FOUND=0

run_loop() {
  while IFS= read -r record; do
    [[ -z "$record" ]] && continue
    DONE=$(( DONE + 1 ))
    printf '\r  [%d pages, %d links found]' "$DONE" "$FOUND" >&2
    local results
    results=$(process_record "$record") || true
    if [[ -n "$results" ]]; then
      printf '%s\n' "$results"
      FOUND=$(( FOUND + $(printf '%s\n' "$results" | wc -l | tr -d ' ') ))
      printf '\r  [%d pages, %d links found]' "$DONE" "$FOUND" >&2
    fi
  done
}

if [[ "$INPUT" == "stdin" ]]; then
  run_loop
else
  for cdx_file in "${CDX_CACHE}"/*.jsonl; do
    [[ -f "$cdx_file" ]] || continue
    run_loop < "$cdx_file"
  done
fi

printf '\n' >&2
