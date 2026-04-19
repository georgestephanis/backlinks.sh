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
  CC_PARALLEL    Parallel WARC fetches (default: 8)

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
PARALLEL="${CC_PARALLEL:-8}"

mkdir -p "$DETAILS_CACHE"
export DETAILS_CACHE CC_BASE DOMAIN

# --- Write the Python WARC parser to a temp file ---
# Written once, reused for every record. Parses gzip-compressed WARC
# records and extracts links pointing to the target domain.

PARSER=$(mktemp /tmp/cc-link-parser-XXXXXX.py)
FETCHER=$(mktemp /tmp/cc-link-fetcher-XXXXXX.sh)
trap "rm -f '$PARSER' '$FETCHER'" EXIT
export PARSER

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

# --- Write the parallel WARC fetcher to a temp file ---
# Called by xargs -P; receives parsed fields as positional args.
# Writes output to the per-digest cache file, skipping if already present.

cat > "$FETCHER" << 'FETCHEOF'
#!/usr/bin/env bash
url="$1" ts="$2" filename="$3" offset="$4" length="$5" digest="$6"
cache_file="${DETAILS_CACHE}/${digest}.tsv"
[[ -f "$cache_file" ]] && exit 0
end=$(( offset + length - 1 ))
tmp="${cache_file}.tmp.$$"
curl -sf --max-time 30 -H "Range: bytes=${offset}-${end}" \
  "${CC_BASE}/${filename}" \
  | python3 "$PARSER" "$DOMAIN" "$url" "$ts" > "$tmp" 2>/dev/null || true
[[ -f "$tmp" ]] && mv "$tmp" "$cache_file" 2>/dev/null || true
FETCHEOF
chmod +x "$FETCHER"

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

# --- Three-phase execution ---

# Phase 1: parse all CDX records to tab-separated fields in one Python call.
# Fields: url, timestamp, filename, offset, length, digest

PARSED=$(mktemp /tmp/cc-parsed-XXXXXX)
trap "rm -f '$PARSER' '$FETCHER' '$PARSED'" EXIT

collect_input() {
  if [[ "$INPUT" == "stdin" ]]; then
    cat
  else
    cat "${CDX_CACHE}"/*.jsonl 2>/dev/null || true
  fi
}

collect_input | python3 -c '
import json, sys, hashlib
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        url = d.get("url",""); ts = d.get("timestamp","")
        fn = d.get("filename",""); offset = d.get("offset","0")
        length = d.get("length","0")
        digest = d.get("digest","") or hashlib.sha1(url.encode()).hexdigest()
        digest = digest.replace("sha1:","").replace("/","_")
        if fn: print("\t".join([url, ts, fn, str(offset), str(length), digest]))
    except Exception: pass
' > "$PARSED"

TOTAL=$(wc -l < "$PARSED" | tr -d ' ')
printf '>> fetching %s pages (%s parallel)...\n' "$TOTAL" "$PARALLEL" >&2

# Phase 2: fetch WARCs in parallel, each worker writing to its own cache file.
xargs -P "$PARALLEL" -L 1 bash "$FETCHER" < "$PARSED" || true

# Phase 3: emit results in input order by reading from cache files.
printf 'source_url\tcrawl_date\ttarget_url\tanchor_text\trel\n'
FOUND=0
while IFS=$'\t' read -r _url _ts _fn _off _len digest; do
  cache_file="${DETAILS_CACHE}/${digest}.tsv"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    FOUND=$(( FOUND + $(wc -l < "$cache_file" | tr -d ' ') ))
  fi
done < "$PARSED"

printf '\n  %s pages, %s links found\n' "$TOTAL" "$FOUND" >&2
